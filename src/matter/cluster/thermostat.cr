require "./cluster"

module Matter
  module Cluster
    # Thermostat Cluster (0x0201)
    #
    # Provides an interface to thermostat functionality, including configuration
    # of setpoints, scheduling, and mode control.
    #
    # Specification: Matter 1.6 § 4.3 (revision 9 wire surface)
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
      MAX_PRESET_TYPES               =      7
      MAX_PRESET_HANDLE_LENGTH       =     16
      MAX_PRESET_NAME_LENGTH         =     64
      PRESET_STATE_KEY               = "preset_state"
      ATTR_PRESETS                   = 0x0050_u32
      CMD_ATOMIC_REQUEST             = 0x00FE_u32
      CMD_ATOMIC_RESPONSE            = 0x00FD_u32
      MAX_PRESET_ATOMIC_TIMEOUT      =  3_000_u16 # milliseconds

      # The PRES wire feature is deliberately withheld until atomic list writes
      # are implemented. These types and the host API provide its state model.
      enum PresetScenario : UInt8
        Occupied     =   1
        Unoccupied   =   2
        Sleep        =   3
        Wake         =   4
        Vacation     =   5
        GoingToSleep =   6
        UserDefined  = 254
      end

      @[Flags]
      enum PresetTypeFeatures : UInt8
        Automatic     = 1
        SupportsNames = 2
      end

      struct PresetType
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter preset_scenario : PresetScenario
        @[TLV::Field(tag: 1)]
        getter number_of_presets : UInt8
        @[TLV::Field(tag: 2)]
        getter preset_type_features : PresetTypeFeatures

        def initialize(@preset_scenario : PresetScenario, @number_of_presets : UInt8,
                       @preset_type_features : PresetTypeFeatures = PresetTypeFeatures::None)
        end
      end

      struct Preset
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0, optional: false)]
        getter preset_handle : Bytes?
        @[TLV::Field(tag: 1)]
        getter preset_scenario : PresetScenario
        @[TLV::Field(tag: 2)]
        getter name : String?
        @[TLV::Field(tag: 3)]
        getter cooling_setpoint : Int16?
        @[TLV::Field(tag: 4)]
        getter heating_setpoint : Int16?
        @[TLV::Field(tag: 5, optional: false)]
        getter built_in : Bool?

        def initialize(@preset_handle : Bytes?, @preset_scenario : PresetScenario,
                       @name : String?, @cooling_setpoint : Int16?, @heating_setpoint : Int16?,
                       @built_in : Bool?)
        end
      end

      struct SetActivePresetRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0, optional: false)]
        getter preset_handle : Bytes?

        def initialize(@preset_handle : Bytes?)
        end
      end

      enum AtomicRequestType : UInt8
        BeginWrite    = 0
        CommitWrite   = 1
        RollbackWrite = 2
      end

      struct AtomicRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter request_type : AtomicRequestType
        @[TLV::Field(tag: 1)]
        getter attribute_requests : Array(UInt32)
        @[TLV::Field(tag: 2)]
        getter timeout : UInt16?

        def initialize(@request_type : AtomicRequestType, @attribute_requests : Array(UInt32),
                       @timeout : UInt16? = nil)
        end
      end

      struct AtomicAttributeStatus
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter attribute_id : UInt32
        @[TLV::Field(tag: 1)]
        getter status_code : InteractionModel::StatusCode

        def initialize(@attribute_id : UInt32, @status_code : InteractionModel::StatusCode)
        end
      end

      struct AtomicResponse
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter status_code : InteractionModel::StatusCode
        @[TLV::Field(tag: 1)]
        getter attribute_status : Array(AtomicAttributeStatus)
        @[TLV::Field(tag: 2)]
        getter timeout : UInt16?

        def initialize(@status_code : InteractionModel::StatusCode,
                       @attribute_status : Array(AtomicAttributeStatus), @timeout : UInt16? = nil)
        end
      end

      private class PendingPresetWrite
        getter fabric : UInt8
        getter subject : UInt64
        getter expires_at : Time::Instant
        property presets : Array(Preset)?

        def initialize(@fabric : UInt8, @subject : UInt64, @expires_at : Time::Instant)
        end
      end

      private struct PresetState
        include Storage::Record

        getter presets : Array(Preset)
        getter active_preset_handle : Bytes?

        def initialize(@presets : Array(Preset), @active_preset_handle : Bytes?)
        end
      end

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
        @preset_types = [] of PresetType
        @presets = [] of Preset
        @active_preset_handle = nil.as(Bytes?)
        @applying_preset = false
        @pending_preset_write = nil.as(PendingPresetWrite?)

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

      # Configure a host-owned preset list. PRES remains absent from FeatureMap:
      # controller writes to Presets require Interaction Model atomic writes.
      def configure_presets(types : Array(PresetType), presets : Array(Preset)) : Nil
        validate_presets!(types, presets)
        @pending_preset_write = nil
        @preset_types = types.dup
        @presets = copy_presets(presets)
        @active_preset_handle = nil
      end

      def preset_types : Array(PresetType)
        @preset_types.dup
      end

      def presets : Array(Preset)
        copy_presets(@presets)
      end

      def active_preset_handle : Bytes?
        @active_preset_handle.try(&.dup)
      end

      # Command payload and behavior are ready for command 0x06, but dispatch
      # stays unavailable until the whole PRES feature can be advertised.
      def activate_preset(request : SetActivePresetRequest) : InteractionModel::Status
        handle = request.preset_handle
        if handle.nil?
          @active_preset_handle = nil
          return InteractionModel::Status.success
        end
        return InteractionModel::Status.constraint_error if handle.size > MAX_PRESET_HANDLE_LENGTH
        preset = @presets.find { |entry| entry.preset_handle == handle }
        return InteractionModel::Status.invalid_command unless preset
        return InteractionModel::Status.constraint_error unless valid_preset_setpoints?(preset)

        @applying_preset = true
        begin
          if @feature_map.cooling? && (cooling = preset.cooling_setpoint)
            self.occupied_cooling_setpoint = cooling
          end
          if @feature_map.heating? && (heating = preset.heating_setpoint)
            self.occupied_heating_setpoint = heating
          end
          @active_preset_handle = handle.dup
        ensure
          @applying_preset = false
        end
        InteractionModel::Status.success
      end

      # The typed handler is retained behind the PRES advertisement gate. A
      # BeginWrite reserves the Presets list for one operational peer; writes
      # stay private until CommitWrite and are discarded by RollbackWrite.
      def atomic_request(request : AtomicRequest) : AtomicResponse | InteractionModel::Status
        return InteractionModel::Status.invalid_command unless atomic_peer?
        ids = request.attribute_requests
        return InteractionModel::Status.invalid_command if ids.empty? || ids.uniq.size != ids.size
        return InteractionModel::Status.invalid_command unless ids == [ATTR_PRESETS]
        return InteractionModel::Status.invalid_command if !request.request_type.begin_write? && request.timeout
        expire_preset_write

        case request.request_type
        when .begin_write?
          atomic_begin(request)
        when .commit_write?
          atomic_finish(ids, commit: true)
        when .rollback_write?
          atomic_finish(ids, commit: false)
        else
          InteractionModel::Status.invalid_command
        end
      end

      # A whole-list replacement is staged only while its authenticated peer
      # owns the matching atomic transaction. The wire attribute remains hidden.
      protected def handle_write_attribute(attribute_id : UInt32, value : TLV::Any) : InteractionModel::Status
        return super unless attribute_id == ATTR_PRESETS && @pending_preset_write

        stage_presets(decode(value, Array(Preset)))
      end

      private def atomic_begin(request : AtomicRequest) : AtomicResponse | InteractionModel::Status
        timeout = request.timeout || return InteractionModel::Status.invalid_command
        return InteractionModel::Status.invalid_command if timeout == 0_u16
        if current = @pending_preset_write
          return InteractionModel::Status.invalid_in_state if atomic_owner?(current)
        end

        ids = request.attribute_requests
        if @preset_types.empty?
          return atomic_response(InteractionModel::StatusCode::Failure,
            ids.map { |id| AtomicAttributeStatus.new(id, InteractionModel::StatusCode::InvalidCommand) })
        end
        if @pending_preset_write
          return atomic_response(InteractionModel::StatusCode::Failure,
            [AtomicAttributeStatus.new(ATTR_PRESETS, InteractionModel::StatusCode::Busy)])
        end

        actual_timeout = {timeout, MAX_PRESET_ATOMIC_TIMEOUT}.min
        fabric = request_fabric_index || return InteractionModel::Status.invalid_command
        subject = request_peer_node_id || return InteractionModel::Status.invalid_command
        @pending_preset_write = PendingPresetWrite.new(
          fabric, subject, Time.instant + actual_timeout.milliseconds)
        atomic_response(InteractionModel::StatusCode::Success,
          [AtomicAttributeStatus.new(ATTR_PRESETS, InteractionModel::StatusCode::Success)], actual_timeout)
      end

      private def atomic_finish(ids : Array(UInt32), *, commit : Bool) : AtomicResponse | InteractionModel::Status
        pending = @pending_preset_write || return InteractionModel::Status.invalid_in_state
        return InteractionModel::Status.invalid_in_state unless atomic_owner?(pending) && ids == [ATTR_PRESETS]
        @pending_preset_write = nil
        if commit && (values = pending.presets)
          if @presets.any? { |entry| entry.built_in && !values.any? { |candidate| candidate.preset_handle == entry.preset_handle } }
            return atomic_response(InteractionModel::StatusCode::Failure,
              [AtomicAttributeStatus.new(ATTR_PRESETS, InteractionModel::StatusCode::ConstraintError)])
          end
          if @active_preset_handle && !values.any? { |entry| entry.preset_handle == @active_preset_handle }
            return atomic_response(InteractionModel::StatusCode::Failure,
              [AtomicAttributeStatus.new(ATTR_PRESETS, InteractionModel::StatusCode::InvalidInState)])
          end
          begin
            validate_presets!(@preset_types, values)
          rescue ArgumentError
            return atomic_response(InteractionModel::StatusCode::Failure,
              [AtomicAttributeStatus.new(ATTR_PRESETS, InteractionModel::StatusCode::ConstraintError)])
          end
          unless @presets == values
            @presets = copy_presets(values)
            increment_version_and_notify(ATTR_PRESETS)
          end
        end
        atomic_response(InteractionModel::StatusCode::Success,
          commit ? [] of AtomicAttributeStatus : [AtomicAttributeStatus.new(ATTR_PRESETS, InteractionModel::StatusCode::Success)])
      end

      private def stage_presets(values : Array(Preset)) : InteractionModel::Status
        expire_preset_write
        pending = @pending_preset_write || return InteractionModel::Status.invalid_in_state
        return InteractionModel::Status.invalid_in_state unless atomic_owner?(pending)

        capacity = @preset_types.sum(&.number_of_presets.to_i)
        return InteractionModel::Status.resource_exhausted if values.size > capacity
        normalized = [] of Preset
        values.each do |entry|
          handle = entry.preset_handle
          return InteractionModel::Status.constraint_error if handle && handle.size > MAX_PRESET_HANDLE_LENGTH
          existing = handle ? @presets.find { |current| current.preset_handle == handle } : nil
          return InteractionModel::Status.not_found if handle && !existing
          return InteractionModel::Status.constraint_error if handle.nil? && entry.built_in == true
          return InteractionModel::Status.constraint_error if existing && !entry.built_in.nil? && entry.built_in != existing.built_in
          handle ||= new_preset_handle(normalized)
          return InteractionModel::Status.constraint_error if normalized.any? { |current| current.preset_handle == handle }
          normalized << Preset.new(handle, entry.preset_scenario, entry.name,
            entry.cooling_setpoint, entry.heating_setpoint, existing.try(&.built_in) || false)
        end
        if @preset_types.any? { |type| normalized.count { |entry| entry.preset_scenario == type.preset_scenario } > type.number_of_presets }
          return InteractionModel::Status.resource_exhausted
        end
        begin
          validate_presets!(@preset_types, normalized)
        rescue ArgumentError
          return InteractionModel::Status.constraint_error
        end
        pending.presets = copy_presets(normalized)
        InteractionModel::Status.success
      end

      private def new_preset_handle(staged : Array(Preset)) : Bytes
        loop do
          handle = Random::Secure.random_bytes(MAX_PRESET_HANDLE_LENGTH)
          return handle unless @presets.any? { |entry| entry.preset_handle == handle } ||
                               staged.any? { |entry| entry.preset_handle == handle }
        end
      end

      private def atomic_peer? : Bool
        subject = request_peer_node_id
        fabric = request_fabric_index
        request_is_case_session? && !fabric.nil? && fabric > 0 && !subject.nil? &&
          subject >= DataType::NodeId::OPERATIONAL_MINIMUM && subject <= DataType::NodeId::OPERATIONAL_MAXIMUM
      end

      private def atomic_owner?(pending : PendingPresetWrite) : Bool
        atomic_peer? && pending.fabric == request_fabric_index && pending.subject == request_peer_node_id
      end

      private def expire_preset_write : Nil
        if (pending = @pending_preset_write) && Time.instant >= pending.expires_at
          @pending_preset_write = nil
        end
      end

      private def atomic_response(code : InteractionModel::StatusCode, statuses : Array(AtomicAttributeStatus),
                                  timeout : UInt16? = nil) : AtomicResponse
        AtomicResponse.new(code, statuses, timeout)
      end

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

      private def copy_presets(values : Array(Preset)) : Array(Preset)
        values.map do |entry|
          Preset.new(entry.preset_handle.try(&.dup), entry.preset_scenario, entry.name,
            entry.cooling_setpoint, entry.heating_setpoint, entry.built_in)
        end
      end

      private def validate_presets!(types : Array(PresetType), values : Array(Preset)) : Nil
        raise ArgumentError.new("preset types must contain 1 to 7 scenarios") unless (1..MAX_PRESET_TYPES).includes?(types.size)
        raise ArgumentError.new("duplicate preset scenario") unless types.map(&.preset_scenario).uniq!.size == types.size
        capacity = types.sum(&.number_of_presets.to_i)
        raise ArgumentError.new("preset capacity must be positive") if capacity == 0
        raise ArgumentError.new("too many presets") if values.size > capacity

        handles = [] of Bytes
        values.each do |entry|
          handle = entry.preset_handle || raise ArgumentError.new("configured preset needs a handle")
          unless (0..MAX_PRESET_HANDLE_LENGTH).includes?(handle.size)
            raise ArgumentError.new("preset handle length is invalid")
          end
          raise ArgumentError.new("duplicate preset handle") if handles.any? { |used| used == handle }
          handles << handle

          type = types.find { |candidate| candidate.preset_scenario == entry.preset_scenario } ||
                 raise ArgumentError.new("unsupported preset scenario")
          if values.count { |candidate| candidate.preset_scenario == entry.preset_scenario } > type.number_of_presets
            raise ArgumentError.new("preset scenario capacity exceeded")
          end
          if name = entry.name
            raise ArgumentError.new("preset name too long") if name.bytesize > MAX_PRESET_NAME_LENGTH
            raise ArgumentError.new("preset scenario does not support names") unless type.preset_type_features.supports_names?
          elsif entry.preset_scenario.user_defined?
            raise ArgumentError.new("user-defined preset requires a name")
          end
          raise ArgumentError.new("configured preset needs BuiltIn") if entry.built_in.nil?
          raise ArgumentError.new("preset setpoints are invalid") unless valid_preset_setpoints?(entry)
        end
      end

      private def valid_preset_setpoints?(preset : Preset) : Bool
        if @feature_map.cooling?
          cooling = preset.cooling_setpoint
          return false unless cooling && cooling.in?(@min_cool_setpoint_limit..@max_cool_setpoint_limit)
        elsif preset.cooling_setpoint
          return false
        end
        if @feature_map.heating?
          heating = preset.heating_setpoint
          return false unless heating && heating.in?(@min_heat_setpoint_limit..@max_heat_setpoint_limit)
        elsif preset.heating_setpoint
          return false
        end
        if @feature_map.automode? && @feature_map.cooling? && @feature_map.heating?
          cooling = preset.cooling_setpoint
          heating = preset.heating_setpoint
          return false unless cooling && heating
          return false if cooling - heating < deadband
        end
        true
      end

      private def extend_persisted_state(document : Storage::Document) : Nil
        return if @preset_types.empty?

        document[PRESET_STATE_KEY] = PresetState.new(copy_presets(@presets), @active_preset_handle.try(&.dup)).to_document
      end

      private def restore_persisted_extension(document : Storage::Document) : Nil
        raw = document[PRESET_STATE_KEY]?
        return unless raw

        state = PresetState.from_document(raw.as?(Storage::Document) ||
                                          raise StorageError.new("invalid thermostat preset state"))
        begin
          validate_presets!(@preset_types, state.presets)
        rescue ex : ArgumentError
          raise StorageError.new("invalid thermostat preset state: #{ex.message}")
        end
        if handle = state.active_preset_handle
          raise StorageError.new("unknown active preset handle") unless state.presets.any? { |preset| preset.preset_handle == handle }
        end
        @presets = copy_presets(state.presets)
        @active_preset_handle = state.active_preset_handle.try(&.dup)
        @pending_preset_write = nil
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
        @active_preset_handle = nil unless @applying_preset
        emit_setpoint_change(SetpointChangeEvent.new(SystemMode::Cool, value)) if @feature_map.events?
        update_running_mode
      end

      private def heating_setpoint_changed(value : Int16) : Nil
        @active_preset_handle = nil unless @applying_preset
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
