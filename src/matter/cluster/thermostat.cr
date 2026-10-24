require "./cluster"

module Matter
  module Cluster
    # Thermostat Cluster (0x0201)
    #
    # Provides an interface to thermostat functionality, including configuration
    # of setpoints, scheduling, and mode control.
    #
    # Specification: Matter 1.4 § 4.3
    class Thermostat < Base
      cluster 0x0201, revision: 9

      @last_running_state : RelayState

      feature :heating, bit: 0                       # HEAT - Heating capability
      feature :cooling, bit: 1                       # COOL - Cooling capability
      feature :automode, bit: 5                      # AUTO - Automatic setpoint management
      feature :local_temperature_not_exposed, bit: 6 # LTNE - Measured temperature is private
      feature :events, bit: 9                        # TEVT - Thermostat change events

      TEMPERATURE_EVENT_INTERVAL     = 60.seconds
      SIGNIFICANT_TEMPERATURE_CHANGE = 50_i16 # 0.5°C

      # System mode values
      enum SystemMode : UInt8
        Off           = 0
        Auto          = 1
        Cool          = 3
        Heat          = 4
        EmergencyHeat = 5
        Precooling    = 6
        FanOnly       = 7
        Dry           = 8
        Sleep         = 9
      end

      # Thermostat running mode
      enum ThermostatRunningMode : UInt8
        Off  = 0
        Cool = 3
        Heat = 4
      end

      @[Flags]
      enum RelayState : UInt16
        Heat = 1
        Cool = 2
      end

      struct SystemModeChangeEvent
        include TLV::Serializable

        @[TLV::Field(tag: 1)]
        getter current_system_mode : SystemMode

        def initialize(@current_system_mode : SystemMode)
        end
      end

      struct LocalTemperatureChangeEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0, optional: false)]
        getter current_local_temperature : Int16?

        def initialize(@current_local_temperature : Int16?)
        end
      end

      struct SetpointChangeEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter system_mode : SystemMode

        @[TLV::Field(tag: 3)]
        getter current_setpoint : Int16

        def initialize(@system_mode : SystemMode, @current_setpoint : Int16)
        end
      end

      struct RunningStateChangeEvent
        include TLV::Serializable

        @[TLV::Field(tag: 1)]
        getter current_running_state : RelayState

        def initialize(@current_running_state : RelayState)
        end
      end

      struct RunningModeChangeEvent
        include TLV::Serializable

        @[TLV::Field(tag: 1)]
        getter current_running_mode : ThermostatRunningMode

        def initialize(@current_running_mode : ThermostatRunningMode)
        end
      end

      # Control sequence of operation
      enum ControlSequenceOfOperation : UInt8
        CoolingOnly                 = 0
        CoolingWithReheat           = 1
        HeatingOnly                 = 2
        HeatingWithReheat           = 3
        CoolingAndHeating           = 4
        CoolingAndHeatingWithReheat = 5
      end

      # Default temperature limits (in 0.01°C)
      DEFAULT_ABS_MIN_HEAT =  700_i16 #  7.00°C
      DEFAULT_ABS_MAX_HEAT = 3000_i16 # 30.00°C
      DEFAULT_ABS_MIN_COOL = 1600_i16 # 16.00°C
      DEFAULT_ABS_MAX_COOL = 3200_i16 # 32.00°C

      # Default setpoints (in 0.01°C)
      DEFAULT_COOLING_SETPOINT = 2600_i16 # 26.00°C
      DEFAULT_HEATING_SETPOINT = 2000_i16 # 20.00°C

      # MinSetpointDeadBand is in 0.1°C steps, bounded by the spec
      DEFAULT_DEAD_BAND =  25_i8 # 2.5°C
      MIN_DEAD_BAND     =   0_i8
      MAX_DEAD_BAND     = 127_i8

      # Setpoint deltas (SetpointRaiseLower amount, MinSetpointDeadBand) are
      # in 0.1°C; the setpoints in 0.01°C
      DECI_TO_CENTI_DEGREES = 10_i16

      enum SetpointAdjustMode : UInt8
        Heat = 0
        Cool = 1
        Both = 2
      end

      # Input to the Thermostat setpointRaiseLower command
      struct SetpointRaiseLowerRequest
        include TLV::Serializable
        @[TLV::Field(tag: 0)]
        property mode : SetpointAdjustMode
        @[TLV::Field(tag: 1)]
        property amount : Int8

        def initialize(@mode : SetpointAdjustMode, @amount : Int8)
        end
      end

      # This represents a single transition in a Thermostat schedule
      struct ThermostatScheduleTransition
        include TLV::Serializable

        # This field represents the start time of the schedule transition during the associated day. The time will be
        # represented by a 16 bits unsigned integer to designate the minutes since midnight. For example, 6am will be
        # represented by 360 minutes since midnight and 11:30pm will be represented by 1410 minutes since midnight.
        @[TLV::Field(tag: 0)]
        property transition_time : UInt16

        @[TLV::Field(tag: 1)]
        property heat_setpoint : UInt16?

        @[TLV::Field(tag: 2)]
        property cool_setpoint : UInt16?
      end

      # Input to the Thermostat setWeeklySchedule command
      struct SetWeeklyScheduleRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property number_of_transitions_for_sequence : UInt8

        @[TLV::Field(tag: 1)]
        property day_of_week_for_sequence : UInt8

        @[TLV::Field(tag: 2)]
        property mode_for_sequence : UInt8

        @[TLV::Field(tag: 3)]
        property transitions : Array(ThermostatScheduleTransition)
      end

      # Input to the Thermostat getWeeklySchedule command
      struct GetWeeklyScheduleRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property days_to_return : UInt8

        @[TLV::Field(tag: 1)]
        property mode_to_return : UInt8
      end

      struct GetWeeklyScheduleResponse
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property number_of_transitions_for_sequence : UInt8

        @[TLV::Field(tag: 1)]
        property day_of_week_for_sequence : UInt8

        @[TLV::Field(tag: 2)]
        property mode_for_sequence : UInt8

        @[TLV::Field(tag: 3)]
        property transitions : Array(ThermostatScheduleTransition)
      end

      attribute 0x0000, :local_temperature, Int16, nullable: true, validate: :validate_local_temperature, on_change: :local_temperature_changed
      attribute 0x0003, :abs_min_heat_setpoint_limit, Int16, default: DEFAULT_ABS_MIN_HEAT, fixed: true, optional: true, requires: :heating
      attribute 0x0004, :abs_max_heat_setpoint_limit, Int16, default: DEFAULT_ABS_MAX_HEAT, fixed: true, optional: true, requires: :heating
      attribute 0x0005, :abs_min_cool_setpoint_limit, Int16, default: DEFAULT_ABS_MIN_COOL, fixed: true, optional: true, requires: :cooling
      attribute 0x0006, :abs_max_cool_setpoint_limit, Int16, default: DEFAULT_ABS_MAX_COOL, fixed: true, optional: true, requires: :cooling
      attribute 0x0011, :occupied_cooling_setpoint, Int16, default: DEFAULT_COOLING_SETPOINT, writable: true, requires: :cooling, on_change: :cooling_setpoint_changed
      attribute 0x0012, :occupied_heating_setpoint, Int16, default: DEFAULT_HEATING_SETPOINT, writable: true, requires: :heating, on_change: :heating_setpoint_changed
      attribute 0x0015, :min_heat_setpoint_limit, Int16, default: DEFAULT_ABS_MIN_HEAT, writable: true, write_access: :manage, optional: true, requires: :heating
      attribute 0x0016, :max_heat_setpoint_limit, Int16, default: DEFAULT_ABS_MAX_HEAT, writable: true, write_access: :manage, optional: true, requires: :heating
      attribute 0x0017, :min_cool_setpoint_limit, Int16, default: DEFAULT_ABS_MIN_COOL, writable: true, write_access: :manage, optional: true, requires: :cooling
      attribute 0x0018, :max_cool_setpoint_limit, Int16, default: DEFAULT_ABS_MAX_COOL, writable: true, write_access: :manage, optional: true, requires: :cooling
      attribute 0x0019, :min_setpoint_dead_band, Int8, default: DEFAULT_DEAD_BAND, writable: true, write_access: :manage, min: MIN_DEAD_BAND, max: MAX_DEAD_BAND, requires: :automode
      attribute 0x001B, :control_sequence_of_operation, ControlSequenceOfOperation, default: ControlSequenceOfOperation::CoolingAndHeating, writable: true, write_access: :manage
      attribute 0x001C, :system_mode, SystemMode, default: SystemMode::Off, writable: true, write_access: :manage, on_change: :system_mode_changed
      attribute 0x001E, :thermostat_running_mode, ThermostatRunningMode, default: ThermostatRunningMode::Off, optional: true, requires: :automode, on_change: :running_mode_changed
      attribute 0x0029, :thermostat_running_state, RelayState, computed: true, optional: true, requires: :events

      event 0x00, :system_mode_change, priority: :info, requires: :events, payload: SystemModeChangeEvent
      event 0x01, :local_temperature_change, priority: :info,
        requires: {events: true, local_temperature_not_exposed: false}, payload: LocalTemperatureChangeEvent
      event 0x03, :setpoint_change, priority: :info, requires: :events, payload: SetpointChangeEvent
      event 0x04, :running_state_change, priority: :info, requires: :events, payload: RunningStateChangeEvent
      event 0x05, :running_mode_change, priority: :info,
        requires: {events: true, automode: true}, payload: RunningModeChangeEvent

      command 0x00, :setpoint_raise_lower, request: SetpointRaiseLowerRequest

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @feature_map : Feature = Feature::Cooling | Feature::Heating,
                     @local_temperature : Int16? = nil,
                     @occupied_cooling_setpoint : Int16 = DEFAULT_COOLING_SETPOINT,
                     @occupied_heating_setpoint : Int16 = DEFAULT_HEATING_SETPOINT,
                     @abs_min_heat_setpoint_limit : Int16 = DEFAULT_ABS_MIN_HEAT,
                     @abs_max_heat_setpoint_limit : Int16 = DEFAULT_ABS_MAX_HEAT,
                     @abs_min_cool_setpoint_limit : Int16 = DEFAULT_ABS_MIN_COOL,
                     @abs_max_cool_setpoint_limit : Int16 = DEFAULT_ABS_MAX_COOL,
                     @min_heat_setpoint_limit : Int16 = DEFAULT_ABS_MIN_HEAT,
                     @max_heat_setpoint_limit : Int16 = DEFAULT_ABS_MAX_HEAT,
                     @min_cool_setpoint_limit : Int16 = DEFAULT_ABS_MIN_COOL,
                     @max_cool_setpoint_limit : Int16 = DEFAULT_ABS_MAX_COOL,
                     @min_setpoint_dead_band : Int8 = DEFAULT_DEAD_BAND,
                     @control_sequence_of_operation : ControlSequenceOfOperation = ControlSequenceOfOperation::CoolingAndHeating,
                     @system_mode : SystemMode = SystemMode::Off,
                     @thermostat_running_mode : ThermostatRunningMode = ThermostatRunningMode::Off)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))

        @measured_temperature = @local_temperature
        @local_temperature = nil if @feature_map.local_temperature_not_exposed?
        @last_reported_temperature = @local_temperature
        @last_temperature_event_at = nil.as(Time::Instant?)
        @last_running_state = thermostat_running_state

        if @feature_map.heating?
          raise ArgumentError.new("min_heat_setpoint_limit must be >= abs minimum") if @min_heat_setpoint_limit < @abs_min_heat_setpoint_limit
          raise ArgumentError.new("max_heat_setpoint_limit must be <= abs maximum") if @max_heat_setpoint_limit > @abs_max_heat_setpoint_limit
        end

        if @feature_map.cooling?
          raise ArgumentError.new("min_cool_setpoint_limit must be >= abs minimum") if @min_cool_setpoint_limit < @abs_min_cool_setpoint_limit
          raise ArgumentError.new("max_cool_setpoint_limit must be <= abs maximum") if @max_cool_setpoint_limit > @abs_max_cool_setpoint_limit
        end

        unless mode_allowed?(@system_mode)
          raise ArgumentError.new("SystemMode #{@system_mode} not supported with current features")
        end
      end

      def thermostat_running_state : RelayState
        case @thermostat_running_mode
        when ThermostatRunningMode::Heat then RelayState::Heat
        when ThermostatRunningMode::Cool then RelayState::Cool
        else                                  RelayState::None
        end
      end

      # ------------------------------------------------------------------------
      # Write hooks
      # ------------------------------------------------------------------------

      before_write :occupied_cooling_setpoint do |setpoint|
        return InteractionModel::Status.constraint_error unless setpoint.in?(@min_cool_setpoint_limit..@max_cool_setpoint_limit)
        keep_heating_below(setpoint)
      end

      before_write :occupied_heating_setpoint do |setpoint|
        return InteractionModel::Status.constraint_error unless setpoint.in?(@min_heat_setpoint_limit..@max_heat_setpoint_limit)
        keep_cooling_above(setpoint)
      end

      before_write :min_heat_setpoint_limit do |limit|
        InteractionModel::Status.constraint_error unless limit.in?(@abs_min_heat_setpoint_limit..@max_heat_setpoint_limit)
      end

      before_write :max_heat_setpoint_limit do |limit|
        InteractionModel::Status.constraint_error unless limit.in?(@min_heat_setpoint_limit..@abs_max_heat_setpoint_limit)
      end

      before_write :min_cool_setpoint_limit do |limit|
        InteractionModel::Status.constraint_error unless limit.in?(@abs_min_cool_setpoint_limit..@max_cool_setpoint_limit)
      end

      before_write :max_cool_setpoint_limit do |limit|
        InteractionModel::Status.constraint_error unless limit.in?(@min_cool_setpoint_limit..@abs_max_cool_setpoint_limit)
      end

      before_write :system_mode do |mode|
        InteractionModel::Status.constraint_error unless mode_allowed?(mode)
      end

      # ------------------------------------------------------------------------
      # Commands
      # ------------------------------------------------------------------------

      def setpoint_raise_lower(request : SetpointRaiseLowerRequest) : InteractionModel::Status
        delta = request.amount.to_i32 * DECI_TO_CENTI_DEGREES

        case request.mode
        when SetpointAdjustMode::Heat
          return InteractionModel::Status.invalid_command unless @feature_map.heating?
          raise_lower_heating(delta)
        when SetpointAdjustMode::Cool
          return InteractionModel::Status.invalid_command unless @feature_map.cooling?
          raise_lower_cooling(delta)
        when SetpointAdjustMode::Both
          if @feature_map.heating? && @feature_map.cooling?
            raise_lower_both(delta)
          elsif @feature_map.heating?
            raise_lower_heating(delta)
          elsif @feature_map.cooling?
            raise_lower_cooling(delta)
          else
            InteractionModel::Status.invalid_command
          end
        else
          InteractionModel::Status.invalid_command
        end
      end

      # ------------------------------------------------------------------------
      # Public Interface
      # ------------------------------------------------------------------------

      # Update local temperature (typically called from a paired temperature sensor)
      def update_local_temperature(value : Int16?) : Nil
        if @feature_map.local_temperature_not_exposed?
          @measured_temperature = value
          update_running_mode
        else
          self.local_temperature = value
        end
      end

      # Programmatic setpoint updates; ignored outside the configured limits
      def cooling_setpoint=(value : Int16) : Nil
        return unless @feature_map.cooling?
        return unless value.in?(@min_cool_setpoint_limit..@max_cool_setpoint_limit)

        self.occupied_cooling_setpoint = value
        update_running_mode
      end

      def heating_setpoint=(value : Int16) : Nil
        return unless @feature_map.heating?
        return unless value.in?(@min_heat_setpoint_limit..@max_heat_setpoint_limit)

        self.occupied_heating_setpoint = value
        update_running_mode
      end

      # Programmatic mode change; ignored when the mode needs an absent feature
      def mode=(mode : SystemMode) : Nil
        return unless mode_allowed?(mode)

        self.system_mode = mode
        update_running_mode
      end

      # Called with `:cool` or `:heat`, the previous and the new value whenever
      # an occupied setpoint changes
      def on_setpoint_changed(&block : Symbol, Int16, Int16 -> Nil) : Nil
        on_occupied_cooling_setpoint_changed { |old_value, new_value| block.call(:cool, old_value, new_value) }
        on_occupied_heating_setpoint_changed { |old_value, new_value| block.call(:heat, old_value, new_value) }
      end

      # ------------------------------------------------------------------------
      # Helpers
      # ------------------------------------------------------------------------

      private def raise_lower_heating(delta : Int32) : InteractionModel::Status
        heating = (@occupied_heating_setpoint.to_i32 + delta).clamp(@min_heat_setpoint_limit.to_i32, @max_heat_setpoint_limit.to_i32)
        if @feature_map.automode? && @feature_map.cooling?
          lowest_cooling = heating + deadband
          if @occupied_cooling_setpoint < lowest_cooling
            return InteractionModel::Status.invalid_command if lowest_cooling > @max_cool_setpoint_limit
            self.occupied_cooling_setpoint = lowest_cooling.to_i16
          end
        end

        self.occupied_heating_setpoint = heating.to_i16
        update_running_mode
        InteractionModel::Status.success
      end

      private def raise_lower_cooling(delta : Int32) : InteractionModel::Status
        cooling = (@occupied_cooling_setpoint.to_i32 + delta).clamp(@min_cool_setpoint_limit.to_i32, @max_cool_setpoint_limit.to_i32)
        if @feature_map.automode? && @feature_map.heating?
          highest_heating = cooling - deadband
          if @occupied_heating_setpoint > highest_heating
            return InteractionModel::Status.invalid_command if highest_heating < @min_heat_setpoint_limit
            self.occupied_heating_setpoint = highest_heating.to_i16
          end
        end

        self.occupied_cooling_setpoint = cooling.to_i16
        update_running_mode
        InteractionModel::Status.success
      end

      # A Both command translates the pair by the same amount. Restrict the
      # translation to the intersection of their limits so the separation is
      # preserved even when one setpoint reaches a limit first.
      private def raise_lower_both(delta : Int32) : InteractionModel::Status
        minimum_shift = {@min_heat_setpoint_limit.to_i32 - @occupied_heating_setpoint,
                         @min_cool_setpoint_limit.to_i32 - @occupied_cooling_setpoint}.max
        maximum_shift = {@max_heat_setpoint_limit.to_i32 - @occupied_heating_setpoint,
                         @max_cool_setpoint_limit.to_i32 - @occupied_cooling_setpoint}.min
        return InteractionModel::Status.invalid_command if minimum_shift > maximum_shift
        return InteractionModel::Status.invalid_command if @feature_map.automode? &&
                                                           @occupied_cooling_setpoint - @occupied_heating_setpoint < deadband

        shift = delta.clamp(minimum_shift, maximum_shift)
        self.occupied_heating_setpoint = (@occupied_heating_setpoint + shift).to_i16
        self.occupied_cooling_setpoint = (@occupied_cooling_setpoint + shift).to_i16
        update_running_mode
        InteractionModel::Status.success
      end

      # The deadband the setpoints keep between them; only enforced with Automode
      private def deadband : Int16
        @feature_map.automode? ? @min_setpoint_dead_band.to_i16 * DECI_TO_CENTI_DEGREES : 0_i16
      end

      # Raises the cooling setpoint to keep the deadband above a new heating
      # setpoint; rejected when that would exceed the cooling limit.
      private def keep_cooling_above(heating : Int16) : InteractionModel::Status?
        return unless @feature_map.cooling?
        lowest_cooling = heating + deadband
        return if @occupied_cooling_setpoint >= lowest_cooling
        return InteractionModel::Status.constraint_error if lowest_cooling > @max_cool_setpoint_limit

        self.occupied_cooling_setpoint = lowest_cooling
        nil
      end

      # Lowers the heating setpoint to keep the deadband below a new cooling
      # setpoint; rejected when that would fall under the heating limit.
      private def keep_heating_below(cooling : Int16) : InteractionModel::Status?
        return unless @feature_map.heating?
        highest_heating = cooling - deadband
        return if @occupied_heating_setpoint <= highest_heating
        return InteractionModel::Status.constraint_error if highest_heating < @min_heat_setpoint_limit

        self.occupied_heating_setpoint = highest_heating
        nil
      end

      private def update_running_mode : Nil
        self.thermostat_running_mode = case @system_mode
                                       in .cool?, .precooling?
                                         ThermostatRunningMode::Cool
                                       in .heat?, .emergency_heat?
                                         ThermostatRunningMode::Heat
                                       in .auto?
                                         auto_running_mode
                                       in .off?, .fan_only?, .dry?, .sleep?
                                         ThermostatRunningMode::Off
                                       end
      end

      # In Auto the running mode follows the local temperature against the setpoints
      private def auto_running_mode : ThermostatRunningMode
        temperature = @measured_temperature
        return ThermostatRunningMode::Off unless temperature

        if temperature > @occupied_cooling_setpoint
          ThermostatRunningMode::Cool
        elsif temperature < @occupied_heating_setpoint
          ThermostatRunningMode::Heat
        else
          ThermostatRunningMode::Off
        end
      end

      private def mode_allowed?(mode : SystemMode) : Bool
        case mode
        in .off?, .fan_only?, .dry?, .sleep?
          true
        in .cool?, .precooling?
          @feature_map.cooling?
        in .heat?, .emergency_heat?
          @feature_map.heating?
        in .auto?
          @feature_map.automode?
        end
      end

      private def validate_local_temperature(value : Int16?) : Nil
        if @feature_map.local_temperature_not_exposed? && !value.nil?
          raise ArgumentError.new("LocalTemperature must remain null when LTNE is enabled")
        end
      end

      private def local_temperature_changed(value : Int16?) : Nil
        @measured_temperature = value
        update_running_mode
        return if !@feature_map.events? || @feature_map.local_temperature_not_exposed?

        previous = @last_reported_temperature
        significant = previous.nil? != value.nil? ||
                      (!previous.nil? && !value.nil? && (value.to_i32 - previous.to_i32).abs >= SIGNIFICANT_TEMPERATURE_CHANGE)
        return unless significant

        now = Time.instant
        last = @last_temperature_event_at
        return if last && now - last < TEMPERATURE_EVENT_INTERVAL

        emit_local_temperature_change(LocalTemperatureChangeEvent.new(value))
        @last_temperature_event_at = now
        @last_reported_temperature = value
      end

      private def cooling_setpoint_changed(value : Int16) : Nil
        emit_setpoint_change(SetpointChangeEvent.new(SystemMode::Cool, value)) if @feature_map.events?
        update_running_mode
      end

      private def heating_setpoint_changed(value : Int16) : Nil
        emit_setpoint_change(SetpointChangeEvent.new(SystemMode::Heat, value)) if @feature_map.events?
        update_running_mode
      end

      private def system_mode_changed(value : SystemMode) : Nil
        emit_system_mode_change(SystemModeChangeEvent.new(value)) if @feature_map.events?
        update_running_mode
      end

      private def running_mode_changed(value : ThermostatRunningMode) : Nil
        return unless @feature_map.events?

        state = thermostat_running_state
        if state != @last_running_state
          emit_running_state_change(RunningStateChangeEvent.new(state))
          @last_running_state = state
        end
        emit_running_mode_change(RunningModeChangeEvent.new(value)) if @feature_map.automode?
      end
    end
  end
end
