require "./cluster"

module Matter
  module Cluster
    # Matter 1.6 Pump Configuration and Control (0x0200), Constant Speed profile.
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

      MAX_LIFETIME_HOURS = 0xFF_FFFF_u32

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
                     @effective_control_mode : ControlMode = ControlMode::ConstantSpeed,
                     @capacity : Int16? = nil,
                     @speed : UInt16? = nil,
                     @lifetime_running_hours : UInt32? = 0_u32,
                     @power : UInt32? = nil,
                     @lifetime_energy_consumed : UInt32? = 0_u32,
                     @operation_mode : OperationMode = OperationMode::Normal,
                     @control_mode : ControlMode = ControlMode::ConstantSpeed)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        unless @feature_map == Feature::ConstantSpeed
          raise ArgumentError.new("only the ConstantSpeed pump profile is supported")
        end
        if (minimum = @min_const_speed) && (maximum = @max_const_speed) && minimum > maximum
          raise ArgumentError.new("min_const_speed exceeds max_const_speed")
        end
        if (maximum = @max_speed) && (constant_maximum = @max_const_speed) && constant_maximum > maximum
          raise ArgumentError.new("max_const_speed exceeds max_speed")
        end
      end

      def on_apply_mode(&block : OperationMode, ControlMode -> InteractionModel::Status) : Nil
        @apply_mode = block
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
        raise ArgumentError.new("unsupported operation mode") if mode.local?
        raise ArgumentError.new("unsupported control mode") unless control.constant_speed?
        if (maximum = @max_speed) && speed && speed > maximum
          raise ArgumentError.new("reported speed exceeds max_speed")
        end
        self.effective_operation_mode = mode
        self.effective_control_mode = control
        self.speed = speed
        self.capacity = capacity
      end

      private def apply_requested_mode(mode : OperationMode, control : ControlMode) : InteractionModel::Status?
        return InteractionModel::Status.constraint_error if mode.local? || !control.constant_speed?
        callback = @apply_mode
        return InteractionModel::Status.invalid_in_state unless callback
        status = callback.call(mode, control)
        status.success? ? nil : status
      end
    end
  end
end
