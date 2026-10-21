require "./cluster"

module Matter
  module Cluster
    # Matter 1.6 Valve Configuration and Control server for a basic valve.
    class ValveConfigurationControl < Base
      cluster 0x0081, revision: 1

      feature :time_sync, bit: 0
      feature :level, bit: 1

      enum ValveState : UInt8
        Closed        = 0
        Open          = 1
        Transitioning = 2
      end

      @[Flags]
      enum ValveFault : UInt16
        None            = 0
        GeneralFault    = 1 << 0
        Blocked         = 1 << 1
        Leaking         = 1 << 2
        NotConnected    = 1 << 3
        ShortCircuit    = 1 << 4
        CurrentExceeded = 1 << 5
      end

      struct OpenRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0, optional: true)]
        property open_duration : UInt32?

        @[TLV::Field(tag: 1, optional: true)]
        property target_level : UInt8?

        def initialize(@open_duration : UInt32? = nil, @target_level : UInt8? = nil)
        end
      end

      struct ValveStateChangedEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property valve_state : ValveState

        @[TLV::Field(tag: 1, optional: true)]
        property valve_level : UInt8?

        def initialize(@valve_state : ValveState, @valve_level : UInt8? = nil)
        end
      end

      struct ValveFaultEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property valve_fault : ValveFault

        def initialize(@valve_fault : ValveFault)
        end
      end

      attribute 0x0000, :open_duration, UInt32, nullable: true
      attribute 0x0001, :default_open_duration, UInt32, nullable: true,
        writable: true, write_access: :operate, min: 1
      attribute 0x0002, :auto_close_time, UInt64, nullable: true, requires: :time_sync
      attribute 0x0003, :remaining_duration, UInt32, nullable: true
      attribute 0x0004, :current_state, ValveState, nullable: true
      attribute 0x0005, :target_state, ValveState, nullable: true
      attribute 0x0006, :current_level, UInt8, nullable: true, requires: :level, max: 100
      attribute 0x0007, :target_level, UInt8, nullable: true, requires: :level, max: 100
      attribute 0x0008, :default_open_level, UInt8, default: 100_u8,
        writable: true, write_access: :operate, optional: true, requires: :level,
        min: 1, max: 100
      attribute 0x0009, :valve_fault, ValveFault, default: ValveFault::None, optional: true
      attribute 0x000A, :level_step, UInt8, default: 1_u8, fixed: true,
        optional: true, requires: :level, min: 1, max: 50

      before_write :default_open_duration do |duration|
        InteractionModel::Status.constraint_error if duration == 0_u32
      end

      command 0x00, :open, request: OpenRequest, access: :operate
      command 0x01, :close, access: :operate

      event 0x00, :valve_state_changed, priority: :info,
        payload: ValveStateChangedEvent
      event 0x01, :valve_fault, priority: :info,
        payload: ValveFaultEvent

      @auto_close_generation = 0_u64

      # Supply Matter epoch microseconds when the endpoint has a trusted UTC source.
      property utc_time_micros : Proc(UInt64)?

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @feature_map : Feature = Feature::None,
                     @default_open_duration : UInt32? = nil,
                     @default_open_level : UInt8 = 100_u8,
                     @level_step : UInt8 = 1_u8,
                     @valve_fault : ValveFault = ValveFault::None,
                     @open_duration : UInt32? = nil,
                     @auto_close_time : UInt64? = nil,
                     @remaining_duration : UInt32? = nil,
                     @current_state : ValveState? = ValveState::Closed,
                     @target_state : ValveState? = ValveState::Closed,
                     @current_level : UInt8? = nil,
                     @target_level : UInt8? = nil)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        if (duration = @default_open_duration) && duration == 0_u32
          raise ArgumentError.new("default_open_duration must be at least one second")
        end
        unless (1_u8..100_u8).includes?(@default_open_level)
          raise ArgumentError.new("default_open_level must be 1..100")
        end
        unless (1_u8..50_u8).includes?(@level_step)
          raise ArgumentError.new("level_step must be 1..50")
        end
        if level = @current_level
          validate_level!(level, allow_closed: true)
        end
        if level = @target_level
          validate_level!(level, allow_closed: true)
        end
        if !@feature_map.level? && (@current_level || @target_level)
          raise ArgumentError.new("valve levels require Level feature")
        end
        if !@feature_map.time_sync? && @auto_close_time
          raise ArgumentError.new("auto_close_time requires TimeSync feature")
        end
        @current_level = 0_u8 if @feature_map.level? && @current_level.nil?
        @target_level = 0_u8 if @feature_map.level? && @target_level.nil?
        @utc_time_micros = nil
      end

      def open(request : OpenRequest) : InteractionModel::Status
        if (duration = request.open_duration) && duration == 0_u32
          return InteractionModel::Status.constraint_error
        end
        if level = request.target_level
          return InteractionModel::Status.constraint_error unless @feature_map.level?
          return InteractionModel::Status.constraint_error unless (1_u8..100_u8).includes?(level)
        end
        level = request.target_level || @default_open_level
        duration = request.open_duration || @default_open_duration
        self.open_duration = duration
        self.remaining_duration = duration
        self.target_state = ValveState::Open
        self.current_state = ValveState::Open
        if @feature_map.level?
          self.target_level = level
          self.current_level = level
        end
        emit_event(EVENT_VALVE_STATE_CHANGED,
          ValveStateChangedEvent.new(ValveState::Open, @feature_map.level? ? level : nil))
        schedule_auto_close(duration)
        InteractionModel::Status.success
      end

      def close : InteractionModel::Status
        @auto_close_generation += 1_u64
        self.open_duration = nil
        self.remaining_duration = nil
        self.auto_close_time = nil if @feature_map.time_sync?
        self.target_state = ValveState::Closed
        self.current_state = ValveState::Closed
        if @feature_map.level?
          self.target_level = 0_u8
          self.current_level = 0_u8
        end
        emit_event(EVENT_VALVE_STATE_CHANGED,
          ValveStateChangedEvent.new(ValveState::Closed, @feature_map.level? ? 0_u8 : nil))
        InteractionModel::Status.success
      end

      def update_fault(fault : ValveFault) : Nil
        return if @valve_fault == fault
        self.valve_fault = fault
        emit_event(EVENT_VALVE_FAULT, ValveFaultEvent.new(fault))
      end

      private def schedule_auto_close(duration : UInt32?) : Nil
        @auto_close_generation += 1_u64
        self.auto_close_time = nil if @feature_map.time_sync?
        return unless seconds = duration
        if @feature_map.time_sync? && (utc_time = @utc_time_micros)
          self.auto_close_time = utc_time.call + seconds.to_u64 * 1_000_000_u64
        end
        generation = @auto_close_generation
        deadline = Time.instant + seconds.seconds
        spawn do
          loop do
            break if generation != @auto_close_generation
            remaining = deadline - Time.instant
            if remaining <= Time::Span.zero
              close
              break
            end
            sleep({remaining, 1.second}.min)
            next if generation != @auto_close_generation
            left = deadline - Time.instant
            self.remaining_duration = left <= Time::Span.zero ? 0_u32 : left.total_seconds.ceil.to_u32
          end
        end
      end

      private def validate_level!(level : UInt8, allow_closed : Bool = false) : Nil
        minimum = allow_closed ? 0_u8 : 1_u8
        raise ArgumentError.new("valve level must be #{minimum}..100") unless (minimum..100_u8).includes?(level)
      end
    end
  end
end
