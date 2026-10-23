require "./cluster"

module Matter
  module Cluster
    # Matter 1.6 Smoke CO Alarm (0x005C), revision 2. The host reports sensor
    # conditions; this server publishes the corresponding attributes and events.
    # The constructor's expression order is a manufacturer certification choice.
    class SmokeCOAlarm < Base
      cluster 0x005C, revision: 2

      feature :smoke_alarm, bit: 0
      feature :co_alarm, bit: 1

      enum AlarmState : UInt8
        Normal   = 0
        Warning  = 1
        Critical = 2
      end

      enum ContaminationState : UInt8
        Normal   = 0
        Low      = 1
        Warning  = 2
        Critical = 3
      end

      enum EndOfService : UInt8
        Normal  = 0
        Expired = 1
      end

      enum ExpressedState : UInt8
        Normal            = 0
        SmokeAlarm        = 1
        COAlarm           = 2
        BatteryAlert      = 3
        Testing           = 4
        HardwareFault     = 5
        EndOfService      = 6
        InterconnectSmoke = 7
        InterconnectCO    = 8
        Inoperative       = 9
      end

      enum MuteState : UInt8
        NotMuted = 0
        Muted    = 1
      end

      enum Sensitivity : UInt8
        High     = 0
        Standard = 1
        Low      = 2
      end

      # One field at context tag 0, per the cluster's alarm event schema.
      struct AlarmEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter alarm_severity_level : AlarmState

        def initialize(@alarm_severity_level : AlarmState)
        end
      end

      struct EmptyEvent
        include TLV::Serializable

        def initialize
        end
      end

      DEFAULT_EXPRESSION_PRIORITY = [
        ExpressedState::Inoperative,
        ExpressedState::SmokeAlarm,
        ExpressedState::COAlarm,
        ExpressedState::InterconnectSmoke,
        ExpressedState::InterconnectCO,
        ExpressedState::Testing,
        ExpressedState::HardwareFault,
        ExpressedState::BatteryAlert,
        ExpressedState::EndOfService,
      ]

      attribute 0x0000, :expressed_state, ExpressedState,
        default: ExpressedState::Normal, persist: true,
        validate: :validate_expressed_state!, on_change: :report_expressed_state
      attribute 0x0001, :smoke_state, AlarmState,
        default: AlarmState::Normal, persist: true, requires: :smoke_alarm,
        validate: :validate_smoke_state!, on_change: :report_smoke_state
      attribute 0x0002, :co_state, AlarmState,
        default: AlarmState::Normal, persist: true, requires: :co_alarm,
        validate: :validate_co_state!, on_change: :report_co_state
      attribute 0x0003, :battery_alert, AlarmState,
        default: AlarmState::Normal, persist: true,
        validate: :validate_alarm_state!, on_change: :report_battery_alert
      attribute 0x0004, :device_muted, MuteState,
        default: MuteState::NotMuted, persist: true, optional: true,
        validate: :validate_device_muted!, on_change: :report_device_muted
      attribute 0x0005, :test_in_progress, Bool,
        default: false, persist: false, on_change: :report_test_progress
      attribute 0x0006, :hardware_fault_alert, Bool,
        default: false, persist: true,
        validate: :validate_hardware_fault!, on_change: :report_hardware_fault
      attribute 0x0007, :end_of_service_alert, EndOfService,
        default: EndOfService::Normal, persist: true,
        validate: :validate_end_of_service!, on_change: :report_end_of_service
      attribute 0x0008, :interconnect_smoke_alarm, AlarmState,
        default: AlarmState::Normal, persist: false, optional: true,
        requires: :smoke_alarm, validate: :validate_smoke_state!,
        on_change: :report_interconnect_smoke
      attribute 0x0009, :interconnect_co_alarm, AlarmState,
        default: AlarmState::Normal, persist: false, optional: true,
        requires: :co_alarm, validate: :validate_co_state!,
        on_change: :report_interconnect_co
      attribute 0x000A, :contamination_state, ContaminationState,
        default: ContaminationState::Normal, persist: false, optional: true,
        requires: :smoke_alarm, validate: :validate_contamination!,
        on_change: :report_contamination
      attribute 0x000B, :smoke_sensitivity_level, Sensitivity,
        default: Sensitivity::Standard, writable: true, write_access: :manage,
        persist: false, optional: true, requires: :smoke_alarm,
        validate: :validate_sensitivity!
      attribute 0x000C, :expiry_date, UInt32,
        default: 0_u32, fixed: true, optional: true,
        present_if: :expiry_date_present?, validate: :reject_fixed_expiry_date!
      attribute 0x000D, :unmounted, Bool,
        default: false, persist: false, optional: true, on_change: :report_unmounted

      command 0x00, :self_test_request, access: :operate, optional: true,
        present_if: :self_test_supported?

      event 0x00, :smoke_alarm, priority: :critical,
        requires: :smoke_alarm, payload: AlarmEvent
      event 0x01, :co_alarm, priority: :critical,
        requires: :co_alarm, payload: AlarmEvent
      event 0x02, :low_battery, priority: :info, payload: AlarmEvent
      event 0x03, :hardware_fault, priority: :info, payload: EmptyEvent
      event 0x04, :end_of_service, priority: :info, payload: EmptyEvent
      event 0x05, :self_test_complete, priority: :info, payload: EmptyEvent
      event 0x06, :alarm_muted, priority: :info, payload: EmptyEvent
      event 0x07, :mute_ended, priority: :info, payload: EmptyEvent
      event 0x08, :interconnect_smoke_alarm, priority: :critical,
        requires: :smoke_alarm, payload: AlarmEvent
      event 0x09, :interconnect_co_alarm, priority: :critical,
        requires: :co_alarm, payload: AlarmEvent
      event 0x0A, :all_clear, priority: :info, payload: EmptyEvent

      before_write :smoke_sensitivity_level do |level|
        InteractionModel::Status.constraint_error unless {
                                                           Sensitivity::High, Sensitivity::Standard, Sensitivity::Low,
                                                         }.includes?(level)
      end

      @self_test_callback : Proc(InteractionModel::Status)?
      @last_expressed_state : ExpressedState = ExpressedState::Normal
      @last_test_in_progress : Bool = false
      @inoperative_sensor : Bool = false
      @expiry_date_present : Bool = false
      @restoring : Bool = false

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @feature_map : Feature = Feature::SmokeAlarm,
                     @self_test_supported : Bool = false,
                     expiry_date : UInt32? = nil,
                     expression_priority : Array(ExpressedState) = DEFAULT_EXPRESSION_PRIORITY)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        valid_features = Feature::SmokeAlarm.value | Feature::CoAlarm.value
        if @feature_map == Feature::None || (@feature_map.value & ~valid_features) != 0
          raise ArgumentError.new("Smoke CO Alarm requires SmokeAlarm or COAlarm")
        end
        unless expression_priority.size == DEFAULT_EXPRESSION_PRIORITY.size &&
               expression_priority.uniq.size == DEFAULT_EXPRESSION_PRIORITY.size &&
               expression_priority.all? { |state| DEFAULT_EXPRESSION_PRIORITY.includes?(state) }
          raise ArgumentError.new("expression priority must contain each non-Normal state once")
        end
        @expression_priority = expression_priority.dup
        @expiry_date_present = !expiry_date.nil?
        @expiry_date = expiry_date || 0_u32
      end

      def self_test_supported?(_command_id : UInt32 = CMD_SELF_TEST_REQUEST) : Bool
        @self_test_supported
      end

      def expiry_date_present? : Bool
        @expiry_date_present
      end

      def on_self_test(&block : -> InteractionModel::Status) : Nil
        @self_test_callback = block
      end

      def self_test_request : InteractionModel::Status
        return InteractionModel::Status.busy if @test_in_progress ||
                                                {ExpressedState::SmokeAlarm, ExpressedState::COAlarm,
                                                 ExpressedState::Testing, ExpressedState::InterconnectSmoke,
                                                 ExpressedState::InterconnectCO}.includes?(@expressed_state)
        return InteractionModel::Status.invalid_in_state if @inoperative_sensor
        callback = @self_test_callback || return InteractionModel::Status.invalid_in_state
        status = callback.call
        if status.success?
          self.test_in_progress = true
          self.expressed_state = ExpressedState::Testing
        end
        status
      end

      # The host calls this after the physical self test, including a failed test.
      # It must report any resulting faults through the normal attribute setters.
      def complete_self_test : Nil
        self.test_in_progress = false if @test_in_progress
      end

      # The host reports whether a persisted fault or Unmounted condition makes
      # sensing impossible. The cluster cannot infer physical sensor capability.
      def report_inoperative(value : Bool) : Nil
        if value && !(@hardware_fault_alert || @unmounted || @battery_alert != AlarmState::Normal)
          raise ArgumentError.new("Inoperative requires a hardware, mounting, or battery fault")
        end
        @inoperative_sensor = value
        recompute_expression
      end

      # The host's clock integration calls this when the fixed expiry date is
      # reached. A background clock is intentionally not implied by this API.
      def refresh_expiry(now : UInt32) : Nil
        self.end_of_service_alert = EndOfService::Expired if @expiry_date_present &&
                                                             now >= @expiry_date && @end_of_service_alert != EndOfService::Expired
      end

      # Interconnect events describe a received alarm, including repeated
      # messages with unchanged severity.
      def receive_interconnect_smoke(value : AlarmState) : Nil
        validate_smoke_state!(value)
        if @interconnect_smoke_alarm == value
          emit_interconnect_smoke_alarm(AlarmEvent.new(value)) if value != AlarmState::Normal
        else
          self.interconnect_smoke_alarm = value
        end
      end

      def receive_interconnect_co(value : AlarmState) : Nil
        validate_co_state!(value)
        if @interconnect_co_alarm == value
          emit_interconnect_co_alarm(AlarmEvent.new(value)) if value != AlarmState::Normal
        else
          self.interconnect_co_alarm = value
        end
      end

      private def validate_alarm_state!(value : AlarmState) : Nil
        unless {AlarmState::Normal, AlarmState::Warning, AlarmState::Critical}.includes?(value)
          raise ArgumentError.new("unsupported alarm state")
        end
      end

      private def validate_smoke_state!(value : AlarmState) : Nil
        raise ArgumentError.new("SmokeAlarm feature is disabled") unless @feature_map.smoke_alarm?
        validate_alarm_state!(value)
      end

      private def validate_co_state!(value : AlarmState) : Nil
        raise ArgumentError.new("COAlarm feature is disabled") unless @feature_map.co_alarm?
        validate_alarm_state!(value)
      end

      private def validate_end_of_service!(value : EndOfService) : Nil
        unless {EndOfService::Normal, EndOfService::Expired}.includes?(value)
          raise ArgumentError.new("unsupported end of service state")
        end
        if @end_of_service_alert == EndOfService::Expired && value == EndOfService::Normal
          raise ArgumentError.new("end of service cannot be cleared")
        end
      end

      private def validate_contamination!(value : ContaminationState) : Nil
        raise ArgumentError.new("SmokeAlarm feature is disabled") unless @feature_map.smoke_alarm?
        unless {ContaminationState::Normal, ContaminationState::Low,
                ContaminationState::Warning, ContaminationState::Critical}.includes?(value)
          raise ArgumentError.new("unsupported contamination state")
        end
      end

      private def validate_sensitivity!(value : Sensitivity) : Nil
        raise ArgumentError.new("SmokeAlarm feature is disabled") unless @feature_map.smoke_alarm?
        unless {Sensitivity::High, Sensitivity::Standard, Sensitivity::Low}.includes?(value)
          raise ArgumentError.new("unsupported smoke sensitivity")
        end
      end

      private def validate_expressed_state!(value : ExpressedState) : Nil
        unless value == selected_expression
          raise ArgumentError.new("ExpressedState must reflect the highest priority active condition")
        end
      end

      private def validate_device_muted!(value : MuteState) : Nil
        if value == MuteState::Muted && critical_alarm?
          raise ArgumentError.new("a critical alarm cannot be muted")
        end
      end

      private def validate_hardware_fault!(value : Bool) : Nil
        if !value && @contamination_state == ContaminationState::Critical
          raise ArgumentError.new("critical smoke contamination requires HardwareFaultAlert")
        end
      end

      private def reject_fixed_expiry_date!(_value : UInt32) : Nil
        raise ArgumentError.new("ExpiryDate is fixed")
      end

      private def report_expressed_state(value : ExpressedState) : Nil
        previous = @last_expressed_state
        @last_expressed_state = value
        if !@restoring && previous != ExpressedState::Normal && value == ExpressedState::Normal
          emit_all_clear(EmptyEvent.new)
        end
      end

      private def report_smoke_state(value : AlarmState) : Nil
        emit_smoke_alarm(AlarmEvent.new(value)) if value != AlarmState::Normal
        clear_mute_for_critical if value == AlarmState::Critical
        recompute_expression
      end

      private def report_co_state(value : AlarmState) : Nil
        emit_co_alarm(AlarmEvent.new(value)) if value != AlarmState::Normal
        clear_mute_for_critical if value == AlarmState::Critical
        recompute_expression
      end

      private def report_battery_alert(value : AlarmState) : Nil
        emit_low_battery(AlarmEvent.new(value)) if value != AlarmState::Normal
        clear_mute_for_critical if value == AlarmState::Critical
        @inoperative_sensor = false if value == AlarmState::Normal && !@hardware_fault_alert && !@unmounted
        recompute_expression
      end

      private def report_device_muted(value : MuteState) : Nil
        if value == MuteState::Muted
          emit_alarm_muted(EmptyEvent.new)
        else
          emit_mute_ended(EmptyEvent.new)
        end
      end

      private def report_test_progress(value : Bool) : Nil
        was_running = @last_test_in_progress
        @last_test_in_progress = value
        emit_self_test_complete(EmptyEvent.new) if was_running && !value
        recompute_expression
      end

      private def report_hardware_fault(value : Bool) : Nil
        emit_hardware_fault(EmptyEvent.new) if value
        @inoperative_sensor = false if !value && @battery_alert == AlarmState::Normal && !@unmounted
        recompute_expression
      end

      private def report_end_of_service(value : EndOfService) : Nil
        emit_end_of_service(EmptyEvent.new) if value == EndOfService::Expired
        recompute_expression
      end

      private def report_interconnect_smoke(value : AlarmState) : Nil
        emit_interconnect_smoke_alarm(AlarmEvent.new(value)) if value != AlarmState::Normal
        clear_mute_for_critical if value == AlarmState::Critical
        recompute_expression
      end

      private def report_interconnect_co(value : AlarmState) : Nil
        emit_interconnect_co_alarm(AlarmEvent.new(value)) if value != AlarmState::Normal
        clear_mute_for_critical if value == AlarmState::Critical
        recompute_expression
      end

      private def report_contamination(value : ContaminationState) : Nil
        self.hardware_fault_alert = true if value == ContaminationState::Critical
      end

      private def report_unmounted(_value : Bool) : Nil
        @inoperative_sensor = false unless @hardware_fault_alert || @unmounted || @battery_alert != AlarmState::Normal
        recompute_expression
      end

      private def clear_mute_for_critical : Nil
        self.device_muted = MuteState::NotMuted if @device_muted == MuteState::Muted
      end

      private def critical_alarm? : Bool
        @smoke_state == AlarmState::Critical || @co_state == AlarmState::Critical ||
          @interconnect_smoke_alarm == AlarmState::Critical ||
          @interconnect_co_alarm == AlarmState::Critical || @battery_alert == AlarmState::Critical
      end

      private def expression_active?(state : ExpressedState) : Bool
        case state
        when ExpressedState::Normal            then false
        when ExpressedState::SmokeAlarm        then @feature_map.smoke_alarm? && @smoke_state != AlarmState::Normal
        when ExpressedState::COAlarm           then @feature_map.co_alarm? && @co_state != AlarmState::Normal
        when ExpressedState::BatteryAlert      then @battery_alert != AlarmState::Normal
        when ExpressedState::Testing           then @test_in_progress
        when ExpressedState::HardwareFault     then @hardware_fault_alert
        when ExpressedState::EndOfService      then @end_of_service_alert == EndOfService::Expired
        when ExpressedState::InterconnectSmoke then @feature_map.smoke_alarm? && @interconnect_smoke_alarm != AlarmState::Normal
        when ExpressedState::InterconnectCO    then @feature_map.co_alarm? && @interconnect_co_alarm != AlarmState::Normal
        when ExpressedState::Inoperative       then @inoperative_sensor
        else                                        false
        end
      end

      private def selected_expression : ExpressedState
        return ExpressedState::Testing if @test_in_progress
        @expression_priority.find { |state| expression_active?(state) } || ExpressedState::Normal
      end

      private def recompute_expression : Nil
        self.expressed_state = selected_expression
      end

      private def after_restore_state : Nil
        @last_test_in_progress = false
        @inoperative_sensor = @expressed_state == ExpressedState::Inoperative &&
                              (@hardware_fault_alert || @unmounted || @battery_alert != AlarmState::Normal)
        @last_expressed_state = @expressed_state
        @restoring = true
        recompute_expression
        @restoring = false
      end
    end
  end
end
