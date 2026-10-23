require "./cluster"

module Matter
  module Cluster
    # Matter 1.6 Dishwasher Alarm (0x005D), derived from Alarm Base.
    # The appliance reports physical conditions; controllers can enable, suppress,
    # or reset the alarms permitted by the configured capability bitmap.
    class DishwasherAlarm < Base
      cluster 0x005D, revision: 1

      feature :reset, bit: 0

      @[Flags]
      enum AlarmBitmap : UInt8
        None            =  0
        InflowError     =  1
        DrainError      =  2
        DoorError       =  4
        TempTooLow      =  8
        TempTooHigh     = 16
        WaterLevelError = 32
      end

      ALL_ALARMS = 0x3F_u8

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
        validate: :validate_bitmap!, on_change: :clear_disabled_alarms
      attribute 0x0001, :latch, AlarmBitmap, default: AlarmBitmap::None,
        fixed: true, requires: :reset, validate: :reject_fixed_alarm_attribute!
      attribute 0x0002, :state, AlarmBitmap, default: AlarmBitmap::None,
        validate: :validate_state!
      attribute 0x0003, :supported, AlarmBitmap, default: AlarmBitmap::None,
        fixed: true, validate: :reject_fixed_alarm_attribute!

      command 0x00, :reset, request: ResetRequest, access: :operate, requires: :reset
      command 0x01, :modify_enabled_alarms, request: ModifyEnabledAlarmsRequest,
        access: :operate, optional: true, present_if: :modify_enabled_alarms_supported?

      event 0x00, :notify, priority: :info, payload: NotifyEvent

      @reported_conditions : AlarmBitmap = AlarmBitmap::None
      @reset_callback : Proc(AlarmBitmap, InteractionModel::Status)?
      @modify_enabled_alarms_callback : Proc(AlarmBitmap, InteractionModel::Status)?

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @supported : AlarmBitmap = AlarmBitmap::DoorError,
                     @feature_map : Feature = Feature::None,
                     @latch : AlarmBitmap = AlarmBitmap::None,
                     @modify_enabled_alarms_supported : Bool = true)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        unless @supported != AlarmBitmap::None && (@supported.value & ~ALL_ALARMS) == 0
          raise ArgumentError.new("at least one known dishwasher alarm must be supported")
        end
        validate_bitmap!(@latch)
        raise ArgumentError.new("Latch requires Reset") if !@feature_map.reset? && @latch != AlarmBitmap::None
        @mask = @supported
        @state = AlarmBitmap::None
      end

      def modify_enabled_alarms_supported?(_command_id : UInt32 = CMD_MODIFY_ENABLED_ALARMS) : Bool
        @modify_enabled_alarms_supported
      end

      def on_reset(&block : AlarmBitmap -> InteractionModel::Status) : Nil
        @reset_callback = block
      end

      def on_modify_enabled_alarms(&block : AlarmBitmap -> InteractionModel::Status) : Nil
        @modify_enabled_alarms_callback = block
      end

      # Report the currently active physical conditions. Enabled alarms with
      # Latch remain active until explicitly reset even if their condition ends.
      def report_alarms(active : AlarmBitmap) : Nil
        validate_bitmap!(active)
        @reported_conditions = active
        publish_reported_conditions
      end

      def reset(request : ResetRequest) : InteractionModel::Status
        return InteractionModel::Status.invalid_command unless valid_bitmap?(request.alarms)
        if callback = @reset_callback
          status = callback.call(request.alarms)
          return status unless status.success?
        end
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
        InteractionModel::Status.success
      end

      private def clear_disabled_alarms(_mask : AlarmBitmap) : Nil
        publish_reported_conditions
      end

      private def publish_reported_conditions : Nil
        next_bits = @reported_conditions.value & @mask.value
        next_bits |= @state.value & @latch.value & @mask.value if @feature_map.reset?
        publish_state(AlarmBitmap.new(next_bits))
      end

      private def validate_bitmap!(value : AlarmBitmap) : Nil
        raise ArgumentError.new("unsupported dishwasher alarm bits") unless valid_bitmap?(value)
      end

      private def validate_state!(value : AlarmBitmap) : Nil
        validate_bitmap!(value)
        unless (@mask.value & value.value) == value.value
          raise ArgumentError.new("State contains disabled dishwasher alarm bits")
        end
      end

      private def reject_fixed_alarm_attribute!(_value : AlarmBitmap) : Nil
        raise ArgumentError.new("fixed dishwasher alarm attribute cannot change after construction")
      end

      private def valid_bitmap?(value : AlarmBitmap) : Bool
        (value.value & ~@supported.value) == 0
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
