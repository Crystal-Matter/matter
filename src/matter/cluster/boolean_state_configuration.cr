require "./cluster"

module Matter
  module Cluster
    # Alarm, sensitivity and fault reporting for Boolean State sensors.
    # Matter 1.6 Boolean State Configuration (0x0080), revision 2.
    class BooleanStateConfiguration < Base
      cluster 0x0080, revision: 2

      feature :visual, bit: 0
      feature :audible, bit: 1
      feature :alarm_suppress, bit: 2
      feature :sensitivity_level, bit: 3
      feature :fault_events, bit: 4

      @[Flags]
      enum AlarmMode : UInt8
        None    = 0
        Visual  = 1
        Audible = 2
      end

      @[Flags]
      enum SensorFault : UInt8
        None         = 0
        GeneralFault = 1
      end

      MIN_SUPPORTED_SENSITIVITY_LEVELS =  2_u8
      MAX_SUPPORTED_SENSITIVITY_LEVELS = 10_u8

      struct SuppressAlarmRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter alarms_to_suppress : AlarmMode

        def initialize(@alarms_to_suppress : AlarmMode)
        end
      end

      struct EnableDisableAlarmRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter alarms_to_enable_disable : AlarmMode

        def initialize(@alarms_to_enable_disable : AlarmMode)
        end
      end

      struct AlarmsStateChangedEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter alarms_active : AlarmMode

        @[TLV::Field(tag: 1, optional: true)]
        getter alarms_suppressed : AlarmMode?

        def initialize(@alarms_active : AlarmMode, @alarms_suppressed : AlarmMode? = nil)
        end
      end

      struct SensorFaultEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter sensor_fault : SensorFault

        def initialize(@sensor_fault : SensorFault)
        end
      end

      attribute 0x0000, :current_sensitivity_level, UInt8, default: 0_u8,
        writable: true, write_access: :operate, requires: :sensitivity_level
      attribute 0x0001, :supported_sensitivity_levels, UInt8,
        default: MIN_SUPPORTED_SENSITIVITY_LEVELS, fixed: true, requires: :sensitivity_level
      attribute 0x0002, :default_sensitivity_level, UInt8, default: 0_u8,
        fixed: true, optional: true, requires: :sensitivity_level,
        present_if: :default_sensitivity_level_present?
      attribute 0x0003, :alarms_active, AlarmMode, default: AlarmMode::None,
        requires: [:visual, :audible], validate: :validate_alarms_active!,
        on_change: :report_alarms_state_change
      attribute 0x0004, :alarms_suppressed, AlarmMode, default: AlarmMode::None,
        requires: :alarm_suppress, validate: :validate_alarms_suppressed!,
        on_change: :report_alarms_state_change
      attribute 0x0005, :alarms_enabled, AlarmMode, default: AlarmMode::None,
        persist: true, optional: true, requires: [:visual, :audible],
        validate: :validate_alarm_mode!
      attribute 0x0006, :alarms_supported, AlarmMode, default: AlarmMode::None,
        fixed: true, requires: [:visual, :audible]
      attribute 0x0007, :sensor_fault, SensorFault, default: SensorFault::None,
        optional: true, requires: :fault_events, on_change: :report_sensor_fault_change

      before_write :current_sensitivity_level do |level|
        InteractionModel::Status.constraint_error if level >= @supported_sensitivity_levels
      end

      command 0x00, :suppress_alarm, request: SuppressAlarmRequest, requires: :alarm_suppress
      command 0x01, :enable_disable_alarm, request: EnableDisableAlarmRequest,
        requires: [:visual, :audible]

      event 0x00, :alarms_state_changed, priority: :info,
        requires: [:visual, :audible], payload: AlarmsStateChangedEvent
      event 0x01, :sensor_fault, priority: :info,
        requires: :fault_events, payload: SensorFaultEvent

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @feature_map : Feature = Feature::None,
                     @current_sensitivity_level : UInt8 = 0_u8,
                     @supported_sensitivity_levels : UInt8 = MIN_SUPPORTED_SENSITIVITY_LEVELS,
                     default_sensitivity_level : UInt8? = nil)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        if @feature_map.alarm_suppress? && !@feature_map.visual? && !@feature_map.audible?
          raise ArgumentError.new("AlarmSuppress requires Visual or Audible")
        end
        if @feature_map.sensitivity_level?
          unless (MIN_SUPPORTED_SENSITIVITY_LEVELS..MAX_SUPPORTED_SENSITIVITY_LEVELS).includes?(@supported_sensitivity_levels)
            raise ArgumentError.new("SupportedSensitivityLevels must be between 2 and 10")
          end
          if @current_sensitivity_level >= @supported_sensitivity_levels
            raise ArgumentError.new("CurrentSensitivityLevel exceeds SupportedSensitivityLevels")
          end
          if default_sensitivity_level && default_sensitivity_level >= @supported_sensitivity_levels
            raise ArgumentError.new("DefaultSensitivityLevel exceeds SupportedSensitivityLevels")
          end
        end
        @default_sensitivity_level_present = !default_sensitivity_level.nil?
        @default_sensitivity_level = default_sensitivity_level || 0_u8
        @alarms_supported = supported_alarm_modes
        @alarms_enabled = @alarms_supported
      end

      def default_sensitivity_level_present? : Bool
        @default_sensitivity_level_present
      end

      # A device reports the underlying alarm condition independently of
      # acknowledgement or suppression.
      def update_alarms_active(value : AlarmMode) : Nil
        self.alarms_active = value
        self.alarms_suppressed = AlarmMode.new(@alarms_suppressed.value & value.value) if @feature_map.alarm_suppress?
      end

      def report_sensor_fault(value : SensorFault) : Nil
        raise ArgumentError.new("FaultEvents feature is not enabled") unless @feature_map.fault_events?
        raise ArgumentError.new("Unsupported sensor fault bits") unless (value.value & ~SensorFault::GeneralFault.value) == 0
        self.sensor_fault = value
      end

      def suppress_alarm(request : SuppressAlarmRequest) : InteractionModel::Status
        value = request.alarms_to_suppress
        return InteractionModel::Status.constraint_error unless valid_alarm_mode?(value)
        return InteractionModel::Status.invalid_in_state unless (value.value & ~@alarms_active.value) == 0
        self.alarms_suppressed = AlarmMode.new(@alarms_suppressed.value | value.value)
        InteractionModel::Status.success
      end

      def enable_disable_alarm(request : EnableDisableAlarmRequest) : InteractionModel::Status
        value = request.alarms_to_enable_disable
        return InteractionModel::Status.constraint_error unless valid_alarm_mode?(value)
        self.alarms_enabled = value
        self.alarms_active = AlarmMode.new(@alarms_active.value & value.value)
        if @feature_map.alarm_suppress?
          self.alarms_suppressed = AlarmMode.new(@alarms_suppressed.value & value.value)
        end
        InteractionModel::Status.success
      end

      private def supported_alarm_modes : AlarmMode
        bits = 0_u8
        bits |= AlarmMode::Visual.value if @feature_map.visual?
        bits |= AlarmMode::Audible.value if @feature_map.audible?
        AlarmMode.new(bits)
      end

      private def valid_alarm_mode?(value : AlarmMode) : Bool
        (value.value & ~@alarms_supported.value) == 0
      end

      private def validate_alarm_mode!(value : AlarmMode) : Nil
        raise ArgumentError.new("Unsupported alarm mode bits") unless valid_alarm_mode?(value)
      end

      private def validate_alarms_active!(value : AlarmMode) : Nil
        validate_alarm_mode!(value)
        unless (value.value & ~@alarms_enabled.value) == 0
          raise ArgumentError.new("Cannot activate a disabled alarm mode")
        end
      end

      private def validate_alarms_suppressed!(value : AlarmMode) : Nil
        validate_alarm_mode!(value)
        unless (value.value & ~@alarms_active.value) == 0
          raise ArgumentError.new("Cannot suppress an inactive alarm mode")
        end
      end

      private def report_alarms_state_change(_value : AlarmMode) : Nil
        suppressed = @feature_map.alarm_suppress? ? @alarms_suppressed : nil
        emit_alarms_state_changed(AlarmsStateChangedEvent.new(@alarms_active, suppressed))
      end

      private def report_sensor_fault_change(value : SensorFault) : Nil
        emit_sensor_fault(SensorFaultEvent.new(value))
      end
    end
  end
end
