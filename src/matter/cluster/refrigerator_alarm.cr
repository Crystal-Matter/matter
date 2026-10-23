require "./cluster"

module Matter
  module Cluster
    # Matter 1.6 Refrigerator Alarm (0x0057), derived from Alarm Base.
    # The appliance reports the door condition; Reset and ModifyEnabledAlarms
    # are disallowed for this derived cluster.
    class RefrigeratorAlarm < Base
      cluster 0x0057, revision: 1

      @[Flags]
      enum AlarmBitmap : UInt8
        None     = 0
        DoorOpen = 1
      end

      DOOR_OPEN_ALARM = AlarmBitmap::DoorOpen

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

      attribute 0x0000, :mask, AlarmBitmap, default: DOOR_OPEN_ALARM,
        validate: :validate_bitmap!, on_change: :publish_reported_condition
      attribute 0x0002, :state, AlarmBitmap, default: AlarmBitmap::None,
        validate: :validate_state!, on_change: :notify_state_change
      attribute 0x0003, :supported, AlarmBitmap, default: DOOR_OPEN_ALARM,
        fixed: true, validate: :reject_fixed_supported!

      event 0x00, :notify, priority: :info, payload: NotifyEvent

      @reported_condition : AlarmBitmap = AlarmBitmap::None
      @last_notified_state : AlarmBitmap = AlarmBitmap::None

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @supported : AlarmBitmap = DOOR_OPEN_ALARM)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        raise ArgumentError.new("Refrigerator Alarm requires DoorOpen support") unless @supported == DOOR_OPEN_ALARM
        @mask = @supported
        @state = AlarmBitmap::None
      end

      # Report whether the appliance door has remained open long enough to alarm.
      # The host decides that vendor-defined duration.
      def report_alarms(active : AlarmBitmap) : Nil
        validate_bitmap!(active)
        @reported_condition = active
        publish_reported_condition
      end

      private def publish_reported_condition(_mask : AlarmBitmap = @mask) : Nil
        self.state = AlarmBitmap.new(@reported_condition.value & @mask.value)
      end

      private def validate_bitmap!(value : AlarmBitmap) : Nil
        raise ArgumentError.new("unsupported refrigerator alarm bits") unless (value.value & ~DOOR_OPEN_ALARM.value) == 0
      end

      private def validate_state!(value : AlarmBitmap) : Nil
        validate_bitmap!(value)
        unless (value.value & @mask.value) == value.value
          raise ArgumentError.new("State contains disabled refrigerator alarm bits")
        end
      end

      private def reject_fixed_supported!(_value : AlarmBitmap) : Nil
        raise ArgumentError.new("fixed refrigerator alarm support cannot change after construction")
      end

      private def notify_state_change(next_state : AlarmBitmap) : Nil
        previous = @last_notified_state
        @last_notified_state = next_state
        emit_notify(NotifyEvent.new(
          AlarmBitmap.new(next_state.value & ~previous.value),
          AlarmBitmap.new(previous.value & ~next_state.value),
          next_state, @mask))
      end
    end
  end
end
