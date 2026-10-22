require "./cluster"

module Matter
  module Cluster
    # Provisional Matter 1.6 Ambient Context Sensing server (0x0431).
    # This implementation supports the HumanActivity feature with one active
    # detection. The host owns the physical sensor and classifies observations.
    class AmbientContextSensing < Base
      cluster 0x0431, revision: 1

      feature :human_activity, bit: 0
      feature :object_counting, bit: 1
      feature :object_identification, bit: 2
      feature :sound_identification, bit: 3
      feature :predicted_activity, bit: 4

      HUMAN_ACTIVITY_NAMESPACE    = 0x4b_u8
      MAX_SUPPORTED_TYPES         =      50
      MAX_SENSED_TYPES            =       2
      MAX_SIMULTANEOUS_DETECTIONS =   10_u8
      SINGLE_DETECTION_LIMIT      =    1_u8

      enum HumanActivity : UInt8
        Unknown          = 0
        Fall             = 1
        Sleeping         = 2
        Walking          = 3
        Workout          = 4
        Sitting          = 5
        Standing         = 6
        Dancing          = 7
        PackageDelivery  = 8
        PackageRetrieval = 9
      end

      # Core SemanticTagStruct, rather than Mode Select's separate two-field
      # SemanticTagStruct. Standard human-activity tags use a null MfgCode.
      struct SemanticTag
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter mfg_code : UInt16?

        @[TLV::Field(tag: 1)]
        getter namespace_id : UInt8

        @[TLV::Field(tag: 2)]
        getter tag : UInt8

        @[TLV::Field(tag: 3, optional: true)]
        getter label : String?

        def initialize(@mfg_code : UInt16?, @namespace_id : UInt8, @tag : UInt8,
                       @label : String? = nil)
        end

        def self.human_activity(activity : HumanActivity) : self
          new(nil, HUMAN_ACTIVITY_NAMESPACE, activity.value)
        end
      end

      struct AmbientContextTypeStruct
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter ambient_context_sensed : Array(SemanticTag)

        def initialize(tags : Array(SemanticTag))
          unless (1..MAX_SENSED_TYPES).includes?(tags.size)
            raise ArgumentError.new("ambient_context_sensed must contain one or two tags")
          end
          @ambient_context_sensed = tags.dup
        end

        def copy : self
          self.class.new(@ambient_context_sensed)
        end
      end

      struct HoldTimeLimits
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter hold_time_min : UInt16

        @[TLV::Field(tag: 1)]
        getter hold_time_max : UInt16

        @[TLV::Field(tag: 2)]
        getter hold_time_default : UInt16

        def initialize(@hold_time_min : UInt16 = 1_u16,
                       @hold_time_max : UInt16 = 600_u16,
                       @hold_time_default : UInt16 = 60_u16)
          raise ArgumentError.new("hold_time_min must be at least 1") if @hold_time_min < 1_u16
          minimum_max = Math.max(@hold_time_min, 10_u16)
          raise ArgumentError.new("hold_time_max must be at least #{minimum_max}") if @hold_time_max < minimum_max
          unless (@hold_time_min..@hold_time_max).includes?(@hold_time_default)
            raise ArgumentError.new("hold_time_default must be within hold time limits")
          end
        end
      end

      struct AmbientContextDetectStartedEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter ambient_context_detected : AmbientContextTypeStruct

        def initialize(@ambient_context_detected : AmbientContextTypeStruct)
        end
      end

      struct AmbientContextDetectEndedEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter event_start_time : UInt64

        def initialize(@event_start_time : UInt64)
        end
      end

      attribute 0x0000, :human_activity_detected, Bool, computed: true, requires: :human_activity
      attribute 0x0003, :ambient_context_type, Array(AmbientContextTypeStruct), computed: true, requires: :human_activity
      attribute 0x0004, :ambient_context_type_supported, Array(SemanticTag), computed: true,
        requires: :human_activity
      attribute 0x0008, :simultaneous_detection_limit, UInt8,
        default: SINGLE_DETECTION_LIMIT, writable: true, write_access: :operate,
        min: SINGLE_DETECTION_LIMIT, max: MAX_SIMULTANEOUS_DETECTIONS,
        validate: :validate_detection_limit
      attribute 0x0009, :hold_time, UInt16, default: 60_u16,
        writable: true, write_access: :manage, persist: true,
        validate: :validate_hold_time, on_change: :reschedule_expiry
      attribute 0x000A, :hold_time_limits, HoldTimeLimits,
        default: HoldTimeLimits.new, fixed: true,
        validate: :reject_fixed_attribute_change!

      event 0x00, :ambient_context_detect_started, priority: :info,
        requires: :human_activity, payload: AmbientContextDetectStartedEvent
      event 0x01, :ambient_context_detect_ended, priority: :info,
        requires: :human_activity, payload: AmbientContextDetectEndedEvent

      before_write :simultaneous_detection_limit do |value|
        InteractionModel::Status.constraint_error unless value == SINGLE_DETECTION_LIMIT
      end

      before_write :hold_time do |value|
        InteractionModel::Status.constraint_error unless (@hold_time_limits.hold_time_min..@hold_time_limits.hold_time_max).includes?(value)
      end

      @state_mutex = Mutex.new(:reentrant)
      @human_activity_detected = false
      @current_type : Array(AmbientContextTypeStruct)
      @supported_activity_tags : Array(SemanticTag)
      @last_observed_at : Time::Instant? = nil
      @event_start_time = 0_u64
      @expiry_generation = 0_u64

      def initialize(endpoint_id : DataType::EndpointNumber,
                     supported_activity_tags : Array(SemanticTag) = [SemanticTag.human_activity(HumanActivity::Unknown)],
                     @hold_time_limits : HoldTimeLimits = HoldTimeLimits.new,
                     hold_time : UInt16? = nil,
                     @simultaneous_detection_limit : UInt8 = SINGLE_DETECTION_LIMIT,
                     @feature_map : Feature = Feature::HumanActivity)
        unless @feature_map == Feature::HumanActivity
          raise ArgumentError.new("only the HumanActivity feature is implemented")
        end
        validate_detection_limit(@simultaneous_detection_limit)
        @hold_time = hold_time || @hold_time_limits.hold_time_default
        validate_hold_time(@hold_time)
        validate_supported_tags!(supported_activity_tags)
        @supported_activity_tags = supported_activity_tags.dup
        @current_type = [AmbientContextTypeStruct.new([SemanticTag.human_activity(HumanActivity::Unknown)])]
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
      end

      def human_activity_detected? : Bool
        @state_mutex.synchronize { @human_activity_detected }
      end

      def ambient_context_type : Array(AmbientContextTypeStruct)
        @state_mutex.synchronize { @current_type.map(&.copy) }
      end

      def ambient_context_type_supported : Array(SemanticTag)
        @supported_activity_tags.dup
      end

      # Record one physical human-activity observation. Repeated observations
      # of the same tag refresh HoldTime without emitting another start event.
      def observe_human_activity(tag : SemanticTag) : Nil
        if tag == SemanticTag.human_activity(HumanActivity::Unknown)
          raise ArgumentError.new("Unknown is the inactive state, not a detected activity")
        end
        unless @supported_activity_tags.includes?(tag)
          raise ArgumentError.new("human activity tag is not supported by this sensor")
        end
        @state_mutex.synchronize do
          current = @current_type.first.ambient_context_sensed.first
          if @human_activity_detected && current != tag
            finish_detection
          end
          unless @human_activity_detected
            @current_type = [AmbientContextTypeStruct.new([tag])]
            @human_activity_detected = true
            @event_start_time = Time.utc.to_unix_ms.to_u64
            increment_version_and_notify(ATTR_AMBIENT_CONTEXT_TYPE)
            increment_version_and_notify(ATTR_HUMAN_ACTIVITY_DETECTED)
            emit_ambient_context_detect_started(
              AmbientContextDetectStartedEvent.new(@current_type.first.copy))
          end
          @last_observed_at = Time.instant
          schedule_expiry
        end
      end

      private def validate_supported_tags!(tags : Array(SemanticTag)) : Nil
        unless (1..MAX_SUPPORTED_TYPES).includes?(tags.size)
          raise ArgumentError.new("supported_activity_tags must contain 1..#{MAX_SUPPORTED_TYPES} tags")
        end
        unless tags.includes?(SemanticTag.human_activity(HumanActivity::Unknown))
          raise ArgumentError.new("supported_activity_tags must include the Unknown human activity tag")
        end
        if tags.uniq.size != tags.size || tags.any? do |tag|
             !tag.mfg_code.nil? || tag.namespace_id != HUMAN_ACTIVITY_NAMESPACE ||
             HumanActivity.from_value?(tag.tag).nil? || !tag.label.nil?
           end
          raise ArgumentError.new("supported_activity_tags must be unique standard human activity tags")
        end
      end

      private def validate_detection_limit(value : UInt8) : Nil
        raise ArgumentError.new("this sensor supports exactly one simultaneous detection") unless value == SINGLE_DETECTION_LIMIT
      end

      private def validate_hold_time(value : UInt16) : Nil
        unless (@hold_time_limits.hold_time_min..@hold_time_limits.hold_time_max).includes?(value)
          raise ArgumentError.new("hold_time must be within configured limits")
        end
      end

      private def reject_fixed_attribute_change!(_value) : Nil
        raise ArgumentError.new("fixed ambient context limits cannot change after construction")
      end

      private def reschedule_expiry(_value : UInt16) : Nil
        @state_mutex.synchronize { schedule_expiry if @human_activity_detected }
      end

      private def schedule_expiry : Nil
        @expiry_generation &+= 1
        generation = @expiry_generation
        observed_at = @last_observed_at || Time.instant
        delay = observed_at + @hold_time.seconds - Time.instant
        delay = 0.seconds if delay < 0.seconds
        spawn do
          sleep delay
          expire_if_current(generation)
        end
      end

      private def expire_if_current(generation : UInt64) : Nil
        @state_mutex.synchronize do
          return unless @human_activity_detected && generation == @expiry_generation
          if observed_at = @last_observed_at
            remaining = observed_at + @hold_time.seconds - Time.instant
            if remaining > 0.seconds
              spawn do
                sleep remaining
                expire_if_current(generation)
              end
              return
            end
          end
          finish_detection
        end
      end

      private def finish_detection : Nil
        @human_activity_detected = false
        @current_type = [AmbientContextTypeStruct.new([SemanticTag.human_activity(HumanActivity::Unknown)])]
        @last_observed_at = nil
        increment_version_and_notify(ATTR_HUMAN_ACTIVITY_DETECTED)
        increment_version_and_notify(ATTR_AMBIENT_CONTEXT_TYPE)
        emit_ambient_context_detect_ended(AmbientContextDetectEndedEvent.new(@event_start_time))
      end
    end
  end
end
