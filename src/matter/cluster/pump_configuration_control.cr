require "./cluster"

module Matter
  module Cluster
    # Matter 1.6 Pump Configuration and Control (0x0200).
    # A host callback must accept remote mode requests; only the host reports
    # effective operation and measured telemetry after changing the pump.
    class PumpConfigurationControl < Base
      cluster 0x0200, revision: 5

      feature :constant_pressure, bit: 0
      feature :compensated_pressure, bit: 1
      feature :constant_flow, bit: 2
      feature :constant_speed, bit: 3
      feature :constant_temperature, bit: 4
      feature :automatic, bit: 5
      feature :local_operation, bit: 6

      enum ControlMode : UInt8
        ConstantSpeed        = 0
        ConstantPressure     = 1
        ProportionalPressure = 2
        ConstantFlow         = 3
        ConstantTemperature  = 5
        Automatic            = 7
      end

      enum OperationMode : UInt8
        Normal  = 0
        Minimum = 1
        Maximum = 2
        Local   = 3
      end

      enum Fault : UInt32
        SupplyVoltageLow          = 0x00
        SupplyVoltageHigh         = 0x01
        PowerMissingPhase         = 0x02
        SystemPressureLow         = 0x03
        SystemPressureHigh        = 0x04
        DryRunning                = 0x05
        MotorTemperatureHigh      = 0x06
        PumpMotorFatalFailure     = 0x07
        ElectronicTemperatureHigh = 0x08
        PumpBlocked               = 0x09
        SensorFailure             = 0x0A
        ElectronicNonFatalFailure = 0x0B
        ElectronicFatalFailure    = 0x0C
        GeneralFault              = 0x0D
        Leakage                   = 0x0E
        AirDetection              = 0x0F
        TurbineOperation          = 0x10
      end

      @[Flags]
      enum PumpStatus : UInt16
        None              = 0
        DeviceFault       = 1 << 0
        SupplyFault       = 1 << 1
        SpeedLow          = 1 << 2
        SpeedHigh         = 1 << 3
        LocalOverride     = 1 << 4
        Running           = 1 << 5
        RemotePressure    = 1 << 6
        RemoteFlow        = 1 << 7
        RemoteTemperature = 1 << 8
      end

      MAX_LIFETIME_HOURS       = 0xFF_FFFF_u32
      MIN_ABSOLUTE_TEMPERATURE =    -27315_i16
      REGULATION_FEATURES      = Feature::ConstantPressure | Feature::CompensatedPressure |
                                 Feature::ConstantFlow | Feature::ConstantSpeed | Feature::ConstantTemperature
      SUPPORTED_FEATURES = REGULATION_FEATURES | Feature::Automatic | Feature::LocalOperation

      attribute 0x0000, :max_pressure, Int16, nullable: true, fixed: true
      attribute 0x0001, :max_speed, UInt16, nullable: true, fixed: true
      attribute 0x0002, :max_flow, UInt16, nullable: true, fixed: true
      attribute 0x0003, :min_const_pressure, Int16, nullable: true, fixed: true, requires: :constant_pressure
      attribute 0x0004, :max_const_pressure, Int16, nullable: true, fixed: true, requires: :constant_pressure
      attribute 0x0005, :min_comp_pressure, Int16, nullable: true, fixed: true, requires: :compensated_pressure
      attribute 0x0006, :max_comp_pressure, Int16, nullable: true, fixed: true, requires: :compensated_pressure
      attribute 0x0007, :min_const_speed, UInt16, nullable: true, fixed: true, requires: :constant_speed
      attribute 0x0008, :max_const_speed, UInt16, nullable: true, fixed: true, requires: :constant_speed
      attribute 0x0009, :min_const_flow, UInt16, nullable: true, fixed: true, requires: :constant_flow
      attribute 0x000A, :max_const_flow, UInt16, nullable: true, fixed: true, requires: :constant_flow
      attribute 0x000B, :min_const_temp, Int16, nullable: true, fixed: true, requires: :constant_temperature, min: -27315
      attribute 0x000C, :max_const_temp, Int16, nullable: true, fixed: true, requires: :constant_temperature, min: -27315
      attribute 0x0010, :pump_status, PumpStatus, default: PumpStatus::None, optional: true
      attribute 0x0011, :effective_operation_mode, OperationMode, default: OperationMode::Normal, persist: true
      attribute 0x0012, :effective_control_mode, ControlMode, default: ControlMode::ConstantSpeed, persist: true
      attribute 0x0013, :capacity, Int16, nullable: true
      attribute 0x0014, :speed, UInt16, nullable: true, optional: true
      attribute 0x0015, :lifetime_running_hours, UInt32, nullable: true, default: 0_u32,
        writable: true, write_access: :manage, optional: true, max: MAX_LIFETIME_HOURS
      attribute 0x0016, :power, UInt32, nullable: true, optional: true, max: MAX_LIFETIME_HOURS
      attribute 0x0017, :lifetime_energy_consumed, UInt32, nullable: true, default: 0_u32,
        writable: true, write_access: :manage, optional: true
      attribute 0x0020, :operation_mode, OperationMode, default: OperationMode::Normal,
        writable: true, write_access: :manage
      attribute 0x0021, :control_mode, ControlMode, default: ControlMode::ConstantSpeed,
        writable: true, write_access: :manage, optional: true

      event 0x00, :supply_voltage_low, priority: :info, present_if: :fault_event_enabled?
      event 0x01, :supply_voltage_high, priority: :info, present_if: :fault_event_enabled?
      event 0x02, :power_missing_phase, priority: :info, present_if: :fault_event_enabled?
      event 0x03, :system_pressure_low, priority: :info, present_if: :fault_event_enabled?
      event 0x04, :system_pressure_high, priority: :info, present_if: :fault_event_enabled?
      event 0x05, :dry_running, priority: :critical, present_if: :fault_event_enabled?
      event 0x06, :motor_temperature_high, priority: :info, present_if: :fault_event_enabled?
      event 0x07, :pump_motor_fatal_failure, priority: :critical, present_if: :fault_event_enabled?
      event 0x08, :electronic_temperature_high, priority: :info, present_if: :fault_event_enabled?
      event 0x09, :pump_blocked, priority: :critical, present_if: :fault_event_enabled?
      event 0x0A, :sensor_failure, priority: :info, present_if: :fault_event_enabled?
      event 0x0B, :electronic_non_fatal_failure, priority: :info, present_if: :fault_event_enabled?
      event 0x0C, :electronic_fatal_failure, priority: :critical, present_if: :fault_event_enabled?
      event 0x0D, :general_fault, priority: :info, present_if: :fault_event_enabled?
      event 0x0E, :leakage, priority: :info, present_if: :fault_event_enabled?
      event 0x0F, :air_detection, priority: :info, present_if: :fault_event_enabled?
      event 0x10, :turbine_operation, priority: :info, present_if: :fault_event_enabled?

      @apply_mode : Proc(OperationMode, ControlMode, InteractionModel::Status)? = nil

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @feature_map : Feature = Feature::ConstantSpeed,
                     @max_pressure : Int16? = nil,
                     @max_speed : UInt16? = nil,
                     @max_flow : UInt16? = nil,
                     @min_const_pressure : Int16? = nil,
                     @max_const_pressure : Int16? = nil,
                     @min_comp_pressure : Int16? = nil,
                     @max_comp_pressure : Int16? = nil,
                     @min_const_speed : UInt16? = nil,
                     @max_const_speed : UInt16? = nil,
                     @min_const_flow : UInt16? = nil,
                     @max_const_flow : UInt16? = nil,
                     @min_const_temp : Int16? = nil,
                     @max_const_temp : Int16? = nil,
                     @pump_status : PumpStatus = PumpStatus::None,
                     @effective_operation_mode : OperationMode = OperationMode::Normal,
                     effective_control_mode : ControlMode? = nil,
                     @capacity : Int16? = nil,
                     @speed : UInt16? = nil,
                     @lifetime_running_hours : UInt32? = 0_u32,
                     @power : UInt32? = nil,
                     @lifetime_energy_consumed : UInt32? = 0_u32,
                     @operation_mode : OperationMode = OperationMode::Normal,
                     control_mode : ControlMode? = nil,
                     fault_events : Set(Fault) = Set(Fault).new)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        raise ArgumentError.new("at least one regulation profile is required") if (@feature_map & REGULATION_FEATURES).none?
        raise ArgumentError.new("unknown pump feature") unless (@feature_map & SUPPORTED_FEATURES) == @feature_map
        @control_mode = control_mode || default_control_mode
        @effective_control_mode = effective_control_mode || @control_mode
        raise ArgumentError.new("unsupported requested control mode") unless control_supported?(@control_mode)
        raise ArgumentError.new("unsupported effective control mode") unless control_supported?(@effective_control_mode)
        raise ArgumentError.new("unsupported operation mode") unless operation_supported?(@operation_mode)
        raise ArgumentError.new("unsupported effective operation mode") unless operation_supported?(@effective_operation_mode)
        @fault_events = fault_events.dup
        validate_fixed_ranges!
      end

      def on_apply_mode(&block : OperationMode, ControlMode -> InteractionModel::Status) : Nil
        @apply_mode = block
      end

      protected def validate_feature_map_change(value : Feature) : Nil
        raise ArgumentError.new("pump feature profile is fixed after construction") unless value == @feature_map
      end

      before_write :operation_mode do |mode|
        apply_requested_mode(mode, @control_mode)
      end

      before_write :control_mode do |mode|
        apply_requested_mode(@operation_mode, mode)
      end

      before_write :lifetime_running_hours do |hours|
        InteractionModel::Status.constraint_error if hours && hours > MAX_LIFETIME_HOURS
      end

      # Called by the host after it observes the physical pump state.
      def report_operation(mode : OperationMode, control : ControlMode,
                           speed : UInt16?, capacity : Int16?) : Nil
        raise ArgumentError.new("unsupported operation mode") unless operation_supported?(mode)
        raise ArgumentError.new("unsupported control mode") unless control_supported?(control)
        if (maximum = @max_speed) && speed && speed > maximum
          raise ArgumentError.new("reported speed exceeds max_speed")
        end
        self.effective_operation_mode = mode
        self.effective_control_mode = control
        self.speed = speed
        self.capacity = capacity
      end

      # The host reports a detected condition; the event has an empty Matter
      # payload and its declared severity determines its journal priority.
      def report_fault(fault : Fault) : Nil
        raise ArgumentError.new("fault event is not enabled") unless @fault_events.includes?(fault)
        emit_event(fault.value, TLV::Any.new(TLV::Structure.new))
      end

      private def fault_event_enabled?(event_id : UInt32) : Bool
        @fault_events.any? { |fault| fault.value == event_id }
      end

      private def apply_requested_mode(mode : OperationMode, control : ControlMode) : InteractionModel::Status?
        return InteractionModel::Status.constraint_error unless operation_supported?(mode) && control_supported?(control)
        callback = @apply_mode
        return InteractionModel::Status.invalid_in_state unless callback
        status = callback.call(mode, control)
        status.success? ? nil : status
      end

      private def default_control_mode : ControlMode
        return ControlMode::ConstantSpeed if @feature_map.includes?(Feature::ConstantSpeed)
        return ControlMode::ConstantPressure if @feature_map.includes?(Feature::ConstantPressure)
        return ControlMode::ProportionalPressure if @feature_map.includes?(Feature::CompensatedPressure)
        return ControlMode::ConstantFlow if @feature_map.includes?(Feature::ConstantFlow)
        ControlMode::ConstantTemperature
      end

      private def control_supported?(mode : ControlMode) : Bool
        feature = case mode
                  in .constant_speed?        then Feature::ConstantSpeed
                  in .constant_pressure?     then Feature::ConstantPressure
                  in .proportional_pressure? then Feature::CompensatedPressure
                  in .constant_flow?         then Feature::ConstantFlow
                  in .constant_temperature?  then Feature::ConstantTemperature
                  in .automatic?             then Feature::Automatic
                  end
        @feature_map.includes?(feature)
      end

      private def operation_supported?(mode : OperationMode) : Bool
        case mode
        in .normal?             then true
        in .minimum?, .maximum? then @feature_map.includes?(Feature::ConstantSpeed)
        in .local?              then @feature_map.includes?(Feature::LocalOperation)
        end
      end

      private def validate_fixed_ranges! : Nil
        validate_range(@min_const_pressure, @max_const_pressure, "constant pressure")
        validate_range(@min_comp_pressure, @max_comp_pressure, "compensated pressure")
        validate_range(@min_const_speed, @max_const_speed, "constant speed")
        validate_range(@min_const_flow, @max_const_flow, "constant flow")
        validate_range(@min_const_temp, @max_const_temp, "constant temperature")
        [@min_const_temp, @max_const_temp].each do |temperature|
          raise ArgumentError.new("constant temperature below absolute zero") if temperature && temperature < MIN_ABSOLUTE_TEMPERATURE
        end
        if (maximum = @max_speed) && (constant_maximum = @max_const_speed) && constant_maximum > maximum
          raise ArgumentError.new("max_const_speed exceeds max_speed")
        end
        if (maximum = @max_flow) && (constant_maximum = @max_const_flow) && constant_maximum > maximum
          raise ArgumentError.new("max_const_flow exceeds max_flow")
        end
        if maximum = @max_pressure
          [@max_const_pressure, @max_comp_pressure].each do |pressure_maximum|
            raise ArgumentError.new("pressure profile maximum exceeds max_pressure") if pressure_maximum && pressure_maximum > maximum
          end
        end
      end

      private def validate_range(minimum : T?, maximum : T?, name : String) : Nil forall T
        raise ArgumentError.new("#{name} minimum exceeds maximum") if minimum && maximum && minimum > maximum
      end
    end
  end
end
