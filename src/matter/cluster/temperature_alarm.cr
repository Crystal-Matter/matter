require "./cluster"

module Matter
  module Cluster
    # Matter 1.6 Temperature Alarm (0x0064), derived from Alarm Base.
    # Temperatures and thresholds are hundredths of a degree Celsius.
    class TemperatureAlarm < Base
      cluster 0x0064, revision: 1

      feature :reset, bit: 0
      feature :over_temperature, bit: 20
      feature :under_temperature, bit: 21
      feature :major_threshold, bit: 22
      feature :minor_threshold, bit: 23
      feature :over_critical_adjustable, bit: 24
      feature :over_major_adjustable, bit: 25
      feature :over_minor_adjustable, bit: 26
      feature :under_minor_adjustable, bit: 27
      feature :under_major_adjustable, bit: 28
      feature :under_critical_adjustable, bit: 29

      @[Flags]
      enum AlarmBitmap : UInt8
        None                     =  0
        CriticalOverTemperature  =  1
        MajorOverTemperature     =  2
        MinorOverTemperature     =  4
        MinorUnderTemperature    =  8
        MajorUnderTemperature    = 16
        CriticalUnderTemperature = 32
      end

      MIN_TEMPERATURE = -27_315_i16
      MAX_TEMPERATURE =  32_767_i16

      struct ResetRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter alarms : AlarmBitmap

        def initialize(@alarms : AlarmBitmap)
        end
      end

      struct ModifyEnabledAlarmsRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter mask : AlarmBitmap

        def initialize(@mask : AlarmBitmap)
        end
      end

      struct SetTemperatureAlarmThresholdsRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0, optional: true)]
        getter critical_over_temperature_threshold : Int16?

        @[TLV::Field(tag: 1, optional: true)]
        getter major_over_temperature_threshold : Int16?

        @[TLV::Field(tag: 2, optional: true)]
        getter minor_over_temperature_threshold : Int16?

        @[TLV::Field(tag: 3, optional: true)]
        getter minor_under_temperature_threshold : Int16?

        @[TLV::Field(tag: 4, optional: true)]
        getter major_under_temperature_threshold : Int16?

        @[TLV::Field(tag: 5, optional: true)]
        getter critical_under_temperature_threshold : Int16?

        def initialize(@critical_over_temperature_threshold : Int16? = nil,
                       @major_over_temperature_threshold : Int16? = nil,
                       @minor_over_temperature_threshold : Int16? = nil,
                       @minor_under_temperature_threshold : Int16? = nil,
                       @major_under_temperature_threshold : Int16? = nil,
                       @critical_under_temperature_threshold : Int16? = nil)
        end
      end

      struct NotifyEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter active : AlarmBitmap

        @[TLV::Field(tag: 1)]
        getter inactive : AlarmBitmap

        @[TLV::Field(tag: 2)]
        getter state : AlarmBitmap

        @[TLV::Field(tag: 3)]
        getter mask : AlarmBitmap

        def initialize(@active : AlarmBitmap, @inactive : AlarmBitmap,
                       @state : AlarmBitmap, @mask : AlarmBitmap)
        end
      end

      attribute 0x0000, :mask, AlarmBitmap, default: AlarmBitmap::None,
        validate: :validate_bitmap!
      attribute 0x0001, :latch, AlarmBitmap, default: AlarmBitmap::None,
        fixed: true, requires: :reset, validate: :reject_fixed_alarm_attribute!
      attribute 0x0002, :state, AlarmBitmap, default: AlarmBitmap::None,
        validate: :validate_state!
      attribute 0x0003, :supported, AlarmBitmap, default: AlarmBitmap::None,
        fixed: true, validate: :reject_fixed_alarm_attribute!
      attribute 0x0080, :critical_over_temperature_threshold, Int16,
        default: 5000_i16, requires: :over_temperature
      attribute 0x0081, :major_over_temperature_threshold, Int16,
        default: 4000_i16, requires: [:over_temperature, :major_threshold],
        present_if: :major_over_threshold_supported?
      attribute 0x0082, :minor_over_temperature_threshold, Int16,
        default: 3000_i16, requires: [:over_temperature, :minor_threshold],
        present_if: :minor_over_threshold_supported?
      attribute 0x0083, :minor_under_temperature_threshold, Int16,
        default: 1000_i16, requires: [:under_temperature, :minor_threshold],
        present_if: :minor_under_threshold_supported?
      attribute 0x0084, :major_under_temperature_threshold, Int16,
        default: 0_i16, requires: [:under_temperature, :major_threshold],
        present_if: :major_under_threshold_supported?
      attribute 0x0085, :critical_under_temperature_threshold, Int16,
        default: -1000_i16, requires: :under_temperature

      command 0x00, :reset, request: ResetRequest, access: :operate, requires: :reset
      command 0x01, :modify_enabled_alarms, request: ModifyEnabledAlarmsRequest,
        access: :operate, optional: true, present_if: :modify_enabled_alarms_supported?
      command 0x80, :set_temperature_alarm_thresholds,
        request: SetTemperatureAlarmThresholdsRequest, access: :operate,
        handler: :apply_temperature_alarm_thresholds,
        requires: [:over_critical_adjustable, :over_major_adjustable, :over_minor_adjustable, :under_minor_adjustable, :under_major_adjustable, :under_critical_adjustable]

      event 0x00, :notify, priority: :info, payload: NotifyEvent

      @last_temperature : Int16?
      @set_thresholds_callback : Proc(SetTemperatureAlarmThresholdsRequest, InteractionModel::Status)?
      @reset_callback : Proc(AlarmBitmap, InteractionModel::Status)?
      @modify_enabled_alarms_callback : Proc(AlarmBitmap, InteractionModel::Status)?

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @feature_map : Feature = Feature::OverTemperature | Feature::UnderTemperature,
                     @critical_over_temperature_threshold : Int16 = 5000_i16,
                     @major_over_temperature_threshold : Int16 = 4000_i16,
                     @minor_over_temperature_threshold : Int16 = 3000_i16,
                     @minor_under_temperature_threshold : Int16 = 1000_i16,
                     @major_under_temperature_threshold : Int16 = 0_i16,
                     @critical_under_temperature_threshold : Int16 = -1000_i16,
                     @latch : AlarmBitmap = AlarmBitmap::None,
                     @modify_enabled_alarms_supported : Bool = true)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        validate_features!
        validate_thresholds!
        @supported = supported_alarms
        validate_bitmap!(@latch)
        raise ArgumentError.new("Latch requires Reset") if !@feature_map.reset? && @latch != AlarmBitmap::None
        @mask = @supported
        @state = AlarmBitmap::None
      end

      def major_over_threshold_supported? : Bool
        @feature_map.over_temperature? && @feature_map.major_threshold?
      end

      def minor_over_threshold_supported? : Bool
        @feature_map.over_temperature? && @feature_map.minor_threshold?
      end

      def minor_under_threshold_supported? : Bool
        @feature_map.under_temperature? && @feature_map.minor_threshold?
      end

      def major_under_threshold_supported? : Bool
        @feature_map.under_temperature? && @feature_map.major_threshold?
      end

      def modify_enabled_alarms_supported?(_command_id : UInt32 = CMD_MODIFY_ENABLED_ALARMS) : Bool
        @modify_enabled_alarms_supported
      end

      def on_set_thresholds(&block : SetTemperatureAlarmThresholdsRequest -> InteractionModel::Status) : Nil
        @set_thresholds_callback = block
      end

      def on_reset(&block : AlarmBitmap -> InteractionModel::Status) : Nil
        @reset_callback = block
      end

      def on_modify_enabled_alarms(&block : AlarmBitmap -> InteractionModel::Status) : Nil
        @modify_enabled_alarms_callback = block
      end

      # A physical sensor calls this when its measured temperature changes.
      def update_temperature(value : Int16?) : Nil
        if value && !(MIN_TEMPERATURE..MAX_TEMPERATURE).includes?(value)
          raise ArgumentError.new("temperature is outside physical range")
        end
        @last_temperature = value
        active = alarms_for(value).value & @mask.value
        latched = @feature_map.reset? ? (@state.value & @latch.value) : 0_u8
        publish_state(AlarmBitmap.new(active | latched))
      end

      def reset(request : ResetRequest) : InteractionModel::Status
        return InteractionModel::Status.invalid_command unless valid_bitmap?(request.alarms)
        if callback = @reset_callback
          status = callback.call(request.alarms)
          return status unless status.success?
        end
        # Reset explicitly clears selected State bits, including currently
        # active alarms. A later physical report may activate them again.
        publish_state(AlarmBitmap.new(@state.value & ~request.alarms.value))
        InteractionModel::Status.success
      end

      def modify_enabled_alarms(request : ModifyEnabledAlarmsRequest) : InteractionModel::Status
        return InteractionModel::Status.invalid_command unless valid_bitmap?(request.mask)
        if callback = @modify_enabled_alarms_callback
          status = callback.call(request.mask)
          return status unless status.success?
        end
        self.mask = request.mask
        # Disabling an alarm clears its State bit even when latched. Enabling
        # it does not synthesize a new condition without a sensor update.
        publish_state(AlarmBitmap.new(@state.value & @mask.value))
        InteractionModel::Status.success
      end

      def apply_temperature_alarm_thresholds(request : SetTemperatureAlarmThresholdsRequest) : InteractionModel::Status
        values = {
          request.critical_over_temperature_threshold,
          request.major_over_temperature_threshold,
          request.minor_over_temperature_threshold,
          request.minor_under_temperature_threshold,
          request.major_under_temperature_threshold,
          request.critical_under_temperature_threshold,
        }
        return InteractionModel::Status.invalid_command if values.all?(Nil)
        allowed = {
          @feature_map.over_critical_adjustable?, @feature_map.over_major_adjustable?,
          @feature_map.over_minor_adjustable?, @feature_map.under_minor_adjustable?,
          @feature_map.under_major_adjustable?, @feature_map.under_critical_adjustable?,
        }
        values.each_with_index do |value, index|
          return InteractionModel::Status.invalid_command if value && !allowed[index]
        end
        next_values = {
          values[0] || @critical_over_temperature_threshold,
          values[1] || @major_over_temperature_threshold,
          values[2] || @minor_over_temperature_threshold,
          values[3] || @minor_under_temperature_threshold,
          values[4] || @major_under_temperature_threshold,
          values[5] || @critical_under_temperature_threshold,
        }
        return InteractionModel::Status.constraint_error unless valid_thresholds?(*next_values)
        return InteractionModel::Status.invalid_in_state unless callback = @set_thresholds_callback
        status = callback.call(request)
        return status unless status.success?
        self.critical_over_temperature_threshold = next_values[0] if values[0]
        self.major_over_temperature_threshold = next_values[1] if values[1]
        self.minor_over_temperature_threshold = next_values[2] if values[2]
        self.minor_under_temperature_threshold = next_values[3] if values[3]
        self.major_under_temperature_threshold = next_values[4] if values[4]
        self.critical_under_temperature_threshold = next_values[5] if values[5]
        update_temperature(@last_temperature)
        status
      end

      private def validate_features! : Nil
        unless @feature_map.over_temperature? || @feature_map.under_temperature?
          raise ArgumentError.new("Temperature Alarm requires OverTemperature or UnderTemperature")
        end
        if @feature_map.minor_threshold? && !@feature_map.major_threshold?
          raise ArgumentError.new("MinorThreshold requires MajorThreshold")
        end
        feature_pairs = {
          {@feature_map.over_critical_adjustable?, @feature_map.over_temperature?},
          {@feature_map.over_major_adjustable?, major_over_threshold_supported?},
          {@feature_map.over_minor_adjustable?, minor_over_threshold_supported?},
          {@feature_map.under_minor_adjustable?, minor_under_threshold_supported?},
          {@feature_map.under_major_adjustable?, major_under_threshold_supported?},
          {@feature_map.under_critical_adjustable?, @feature_map.under_temperature?},
        }
        raise ArgumentError.new("adjustable threshold feature requires its threshold") if feature_pairs.any? { |enabled, supported| enabled && !supported }
      end

      private def supported_alarms : AlarmBitmap
        bits = 0_u8
        bits |= AlarmBitmap::CriticalOverTemperature.value if @feature_map.over_temperature?
        bits |= AlarmBitmap::MajorOverTemperature.value if major_over_threshold_supported?
        bits |= AlarmBitmap::MinorOverTemperature.value if minor_over_threshold_supported?
        bits |= AlarmBitmap::MinorUnderTemperature.value if minor_under_threshold_supported?
        bits |= AlarmBitmap::MajorUnderTemperature.value if major_under_threshold_supported?
        bits |= AlarmBitmap::CriticalUnderTemperature.value if @feature_map.under_temperature?
        AlarmBitmap.new(bits)
      end

      private def validate_thresholds! : Nil
        unless valid_thresholds?(@critical_over_temperature_threshold,
                 @major_over_temperature_threshold, @minor_over_temperature_threshold,
                 @minor_under_temperature_threshold, @major_under_temperature_threshold,
                 @critical_under_temperature_threshold)
          raise ArgumentError.new("temperature alarm thresholds are outside range or out of order")
        end
      end

      private def valid_thresholds?(critical_over : Int16, major_over : Int16, minor_over : Int16,
                                    minor_under : Int16, major_under : Int16, critical_under : Int16) : Bool
        configured = [] of Int16
        configured << critical_under if @feature_map.under_temperature?
        configured << major_under if major_under_threshold_supported?
        configured << minor_under if minor_under_threshold_supported?
        configured << minor_over if minor_over_threshold_supported?
        configured << major_over if major_over_threshold_supported?
        configured << critical_over if @feature_map.over_temperature?
        configured.all? { |value| (MIN_TEMPERATURE..MAX_TEMPERATURE).includes?(value) } &&
          configured.each_cons(2).all? { |pair| pair[0] < pair[1] }
      end

      private def validate_bitmap!(value : AlarmBitmap) : Nil
        raise ArgumentError.new("unsupported alarm bits") unless valid_bitmap?(value)
      end

      private def validate_state!(value : AlarmBitmap) : Nil
        validate_bitmap!(value)
        raise ArgumentError.new("State contains disabled alarm bits") unless (@mask.value & value.value) == value.value
      end

      private def reject_fixed_alarm_attribute!(_value : AlarmBitmap) : Nil
        raise ArgumentError.new("fixed alarm attribute cannot change after construction")
      end

      private def valid_bitmap?(value : AlarmBitmap) : Bool
        (value.value & ~@supported.value) == 0
      end

      private def alarms_for(value : Int16?) : AlarmBitmap
        return AlarmBitmap::None unless value
        bits = 0_u8
        bits |= AlarmBitmap::CriticalOverTemperature.value if @feature_map.over_temperature? && value > @critical_over_temperature_threshold
        bits |= AlarmBitmap::MajorOverTemperature.value if major_over_threshold_supported? && value > @major_over_temperature_threshold
        bits |= AlarmBitmap::MinorOverTemperature.value if minor_over_threshold_supported? && value > @minor_over_temperature_threshold
        bits |= AlarmBitmap::MinorUnderTemperature.value if minor_under_threshold_supported? && value < @minor_under_temperature_threshold
        bits |= AlarmBitmap::MajorUnderTemperature.value if major_under_threshold_supported? && value < @major_under_temperature_threshold
        bits |= AlarmBitmap::CriticalUnderTemperature.value if @feature_map.under_temperature? && value < @critical_under_temperature_threshold
        AlarmBitmap.new(bits)
      end

      private def publish_state(next_state : AlarmBitmap) : Nil
        old_state = @state
        return if next_state == old_state
        self.state = next_state
        emit_notify(NotifyEvent.new(
          AlarmBitmap.new(next_state.value & ~old_state.value),
          AlarmBitmap.new(old_state.value & ~next_state.value),
          next_state, @mask))
      end
    end
  end
end
