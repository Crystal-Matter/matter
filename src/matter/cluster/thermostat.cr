require "./cluster"

module Matter
  module Cluster
    # Thermostat Cluster (0x0201)
    #
    # Provides an interface to thermostat functionality, including configuration
    # of setpoints, scheduling, and mode control.
    #
    # Specification: Matter 1.6 § 4.3 (revision 11 base wire surface)
    class Thermostat < Base
      cluster 0x0201, revision: 11

      @last_running_state : RelayState

      feature :heating, bit: 0                       # HEAT - Heating capability
      feature :cooling, bit: 1                       # COOL - Cooling capability
      feature :occupancy, bit: 2                     # OCC - Occupied and Unoccupied setpoints
      feature :automode, bit: 5                      # AUTO - Automatic setpoint management
      feature :local_temperature_not_exposed, bit: 6 # LTNE - Measured temperature is private
      feature :matter_schedules, bit: 7              # MSCH - gated until timed schedule activation is complete
      feature :presets, bit: 8                       # PRES - gated until wire conformance is complete
      feature :events, bit: 9                        # TEVT - Thermostat change events
      feature :thermostat_suggestions, bit: 10       # TSUGGEST - provisional, gated until behavior is complete

      TEMPERATURE_EVENT_INTERVAL     = 60.seconds
      SIGNIFICANT_TEMPERATURE_CHANGE = 50_i16 # 0.5°C
      MAX_PRESET_TYPES               =      7
      MAX_PRESET_HANDLE_LENGTH       =     16
      MAX_PRESET_NAME_LENGTH         =     64
      PRESET_STATE_KEY               = "preset_state"
      SUGGESTION_STATE_KEY           = "suggestion_state"
      MIN_SUGGESTION_CAPACITY        =            5_u8
      MAX_SUGGESTION_AHEAD_SECONDS   =      86_400_u64
      MATTER_EPOCH_UNIX_SECONDS      = 946_684_800_i64
      SCHEDULE_STATE_KEY             = "schedule_state"
      MAX_SCHEDULE_TYPES             =          3
      MAX_SCHEDULE_HANDLE_LENGTH     =         16
      MAX_SCHEDULE_NAME_LENGTH       =         64
      MINUTES_PER_HOUR               =         60
      MAX_WEEKLY_LOOKBACK_DAYS       =          7
      CMD_ATOMIC_RESPONSE            = 0x00FD_u32
      # Delegate maximum for a Presets atomic write. The wire field is uint16
      # milliseconds and Matter leaves the server maximum implementation-defined.
      # Separate controller commands can take several seconds; a lost writer
      # blocks another writer for no more than one minute.
      MAX_PRESET_ATOMIC_TIMEOUT = 60_000_u16

      # PRES is declared for conformance tests, but production instances refuse
      # the feature until the remaining atomic-write wire checks are complete.
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
      enum PresetTypeFeatures : UInt16
        Automatic     = 1
        SupportsNames = 2
      end

      struct PresetType
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter preset_scenario : PresetScenario
        @[TLV::Field(tag: 1)]
        getter number_of_presets : UInt8
        @[TLV::Field(tag: 2, fixed_size: true)]
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

      @[Flags]
      enum ScheduleTypeFeatures : UInt16
        SupportsPresets   = 1
        SupportsSetpoints = 2
        SupportsNames     = 4
        SupportsOff       = 8
      end

      struct ScheduleType
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter system_mode : SystemMode
        @[TLV::Field(tag: 1)]
        getter number_of_schedules : UInt8
        @[TLV::Field(tag: 2)]
        getter schedule_type_features : ScheduleTypeFeatures

        def initialize(@system_mode : SystemMode, @number_of_schedules : UInt8,
                       @schedule_type_features : ScheduleTypeFeatures)
        end
      end

      struct ScheduleTransition
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        getter day_of_week : UInt8
        @[TLV::Field(tag: 1)]
        getter transition_time : UInt16
        @[TLV::Field(tag: 2)]
        getter preset_handle : Bytes?
        @[TLV::Field(tag: 3)]
        getter system_mode : SystemMode?
        @[TLV::Field(tag: 4)]
        getter cooling_setpoint : Int16?
        @[TLV::Field(tag: 5)]
        getter heating_setpoint : Int16?

        def initialize(@day_of_week : UInt8, @transition_time : UInt16,
                       @preset_handle : Bytes?, @system_mode : SystemMode?,
                       @cooling_setpoint : Int16?, @heating_setpoint : Int16?)
        end
      end

      struct Schedule
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0, optional: false)]
        getter schedule_handle : Bytes?
        @[TLV::Field(tag: 1)]
        getter system_mode : SystemMode
        @[TLV::Field(tag: 2)]
        getter name : String?
        @[TLV::Field(tag: 3)]
        getter preset_handle : Bytes?
        @[TLV::Field(tag: 4)]
        getter transitions : Array(ScheduleTransition)
        @[TLV::Field(tag: 5, optional: false)]
        getter built_in : Bool?

        def initialize(@schedule_handle : Bytes?, @system_mode : SystemMode,
                       @name : String?, @preset_handle : Bytes?,
                       @transitions : Array(ScheduleTransition), @built_in : Bool?)
        end
      end

      struct SetActivePresetRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0, optional: false)]
        getter preset_handle : Bytes?

        def initialize(@preset_handle : Bytes?)
        end
      end

      # Matter 1.6 TSUGGEST wire types. The feature remains disabled in
      # production until its UTC, preset, and timer behavior is implemented.
      @[Flags]
      enum ThermostatSuggestionNotFollowingReason : UInt16
        DemandResponseEvent    = 0x0001
        OngoingHold            = 0x0002
        Schedule               = 0x0004
        Occupancy              = 0x0008
        VacationMode           = 0x0010
        TimeOfUseCostSavings   = 0x0020
        PreCoolingOrPreHeating = 0x0040
        ConflictingSuggestions = 0x0080
      end

      struct ThermostatSuggestion
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        getter unique_id : UInt8
        @[TLV::Field(tag: 1)]
        getter preset_handle : Bytes
        @[TLV::Field(tag: 2)]
        getter effective_time : UInt32
        @[TLV::Field(tag: 3)]
        getter expiration_time : UInt32

        def initialize(@unique_id : UInt8, @preset_handle : Bytes,
                       @effective_time : UInt32, @expiration_time : UInt32)
          raise ArgumentError.new("preset_handle exceeds 16 bytes") if @preset_handle.size > MAX_PRESET_HANDLE_LENGTH
        end
      end

      struct AddThermostatSuggestionRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter preset_handle : Bytes
        @[TLV::Field(tag: 1, optional: false)]
        getter effective_time : UInt32?
        @[TLV::Field(tag: 2)]
        getter expiration_in_minutes : UInt16

        def initialize(@preset_handle : Bytes, @effective_time : UInt32?, @expiration_in_minutes : UInt16)
          raise ArgumentError.new("preset_handle exceeds 16 bytes") if @preset_handle.size > MAX_PRESET_HANDLE_LENGTH
          raise ArgumentError.new("expiration_in_minutes must be 30..1440") unless (30_u16..1440_u16).includes?(@expiration_in_minutes)
        end
      end

      struct AddThermostatSuggestionResponse
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter unique_id : UInt8

        def initialize(@unique_id : UInt8)
        end
      end

      struct RemoveThermostatSuggestionRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter unique_id : UInt8

        def initialize(@unique_id : UInt8)
        end
      end

      struct SetActiveScheduleRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter schedule_handle : Bytes

        def initialize(@schedule_handle : Bytes)
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
        getter write_data_versions = [] of UInt32

        def initialize(@fabric : UInt8, @subject : UInt64, @expires_at : Time::Instant)
        end
      end

      private class PendingScheduleWrite
        getter fabric : UInt8
        getter subject : UInt64
        getter expires_at : Time::Instant
        property schedules : Array(Schedule)?
        getter write_data_versions = [] of UInt32

        def initialize(@fabric : UInt8, @subject : UInt64, @expires_at : Time::Instant)
        end
      end

      private struct PresetState
        include Storage::Record

        getter presets : Array(Preset)
        getter active_preset_handle : Bytes?
        getter used_preset_handles : Array(Bytes) = [] of Bytes

        def initialize(@presets : Array(Preset), @active_preset_handle : Bytes?,
                       @used_preset_handles : Array(Bytes) = [] of Bytes)
        end
      end

      private struct SuggestionState
        include Storage::Record

        getter suggestions : Array(ThermostatSuggestion)
        getter next_id : UInt8
        getter capacity : UInt8 = MIN_SUGGESTION_CAPACITY

        def initialize(@suggestions : Array(ThermostatSuggestion), @next_id : UInt8,
                       @capacity : UInt8 = MIN_SUGGESTION_CAPACITY)
        end
      end

      private struct ScheduleState
        include Storage::Record

        getter schedules : Array(Schedule)
        getter used_schedule_handles : Array(Bytes)
        getter active_schedule_handle : Bytes? = nil

        def initialize(@schedules : Array(Schedule), @used_schedule_handles : Array(Bytes),
                       @active_schedule_handle : Bytes? = nil)
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

        @[TLV::Field(tag: 1, optional: true)]
        getter occupancy : UInt8?

        @[TLV::Field(tag: 3)]
        getter current_setpoint : Int16

        def initialize(@system_mode : SystemMode, @current_setpoint : Int16, @occupancy : UInt8? = nil)
        end
      end

      struct OccupancyChangeEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0, optional: true)]
        getter previous_occupancy : UInt8?

        @[TLV::Field(tag: 1)]
        getter current_occupancy : UInt8

        def initialize(@previous_occupancy : UInt8?, @current_occupancy : UInt8)
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

      struct ActivePresetChangeEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0, optional: true)]
        getter previous_preset_handle : Bytes?

        @[TLV::Field(tag: 1, optional: false)]
        getter current_preset_handle : Bytes?

        def initialize(@previous_preset_handle : Bytes?, @current_preset_handle : Bytes?)
        end
      end

      struct ActiveScheduleChangeEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0, optional: true)]
        getter previous_schedule_handle : Bytes?

        @[TLV::Field(tag: 1, optional: false)]
        getter current_schedule_handle : Bytes?

        def initialize(@previous_schedule_handle : Bytes?, @current_schedule_handle : Bytes?)
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
      attribute 0x0002, :occupancy, UInt8, default: 1_u8, max: 1_u8, persist: true,
        requires: :occupancy, validate: :validate_occupancy, on_change: :occupancy_changed
      attribute 0x0003, :abs_min_heat_setpoint_limit, Int16, default: DEFAULT_ABS_MIN_HEAT, fixed: true, optional: true, requires: :heating
      attribute 0x0004, :abs_max_heat_setpoint_limit, Int16, default: DEFAULT_ABS_MAX_HEAT, fixed: true, optional: true, requires: :heating
      attribute 0x0005, :abs_min_cool_setpoint_limit, Int16, default: DEFAULT_ABS_MIN_COOL, fixed: true, optional: true, requires: :cooling
      attribute 0x0006, :abs_max_cool_setpoint_limit, Int16, default: DEFAULT_ABS_MAX_COOL, fixed: true, optional: true, requires: :cooling
      attribute 0x0011, :occupied_cooling_setpoint, Int16, default: DEFAULT_COOLING_SETPOINT, writable: true, write_access: :operate, requires: :cooling, on_change: :cooling_setpoint_changed
      attribute 0x0012, :occupied_heating_setpoint, Int16, default: DEFAULT_HEATING_SETPOINT, writable: true, write_access: :operate, requires: :heating, on_change: :heating_setpoint_changed
      attribute 0x0013, :unoccupied_cooling_setpoint, Int16, default: DEFAULT_COOLING_SETPOINT, writable: true, write_access: :operate,
        requires: {cooling: true, occupancy: true}, on_change: :unoccupied_cooling_setpoint_changed
      attribute 0x0014, :unoccupied_heating_setpoint, Int16, default: DEFAULT_HEATING_SETPOINT, writable: true, write_access: :operate,
        requires: {heating: true, occupancy: true}, on_change: :unoccupied_heating_setpoint_changed
      attribute 0x0015, :min_heat_setpoint_limit, Int16, default: DEFAULT_ABS_MIN_HEAT, writable: true, write_access: :manage,
        optional: true, requires: :heating, validate: :validate_min_heat_limit, on_change: :min_heat_limit_changed
      attribute 0x0016, :max_heat_setpoint_limit, Int16, default: DEFAULT_ABS_MAX_HEAT, writable: true, write_access: :manage,
        optional: true, requires: :heating, validate: :validate_max_heat_limit, on_change: :max_heat_limit_changed
      attribute 0x0017, :min_cool_setpoint_limit, Int16, default: DEFAULT_ABS_MIN_COOL, writable: true, write_access: :manage,
        optional: true, requires: :cooling, validate: :validate_min_cool_limit, on_change: :min_cool_limit_changed
      attribute 0x0018, :max_cool_setpoint_limit, Int16, default: DEFAULT_ABS_MAX_COOL, writable: true, write_access: :manage,
        optional: true, requires: :cooling, validate: :validate_max_cool_limit, on_change: :max_cool_limit_changed
      attribute 0x0019, :min_setpoint_dead_band, Int8, default: DEFAULT_DEAD_BAND, writable: true, write_access: :manage, min: MIN_DEAD_BAND, max: MAX_DEAD_BAND, requires: :automode
      attribute 0x001B, :control_sequence_of_operation, ControlSequenceOfOperation, default: ControlSequenceOfOperation::CoolingAndHeating, writable: true, write_access: :manage
      attribute 0x001C, :system_mode, SystemMode, default: SystemMode::Off, writable: true, write_access: :manage, on_change: :system_mode_changed
      attribute 0x001E, :thermostat_running_mode, ThermostatRunningMode, default: ThermostatRunningMode::Off, optional: true, requires: :automode, on_change: :running_mode_changed
      attribute 0x0029, :thermostat_running_state, RelayState, computed: true, optional: true, requires: :events
      attribute 0x0048, :preset_types, Array(PresetType), computed: true, optional: true,
        requires: :presets, present_if: :preset_wire_ready?
      attribute 0x0049, :schedule_types, Array(ScheduleType), computed: true, optional: true,
        requires: :matter_schedules, present_if: :schedule_wire_ready?
      attribute 0x004A, :number_of_presets, UInt8, computed: true, optional: true,
        requires: :presets, present_if: :preset_wire_ready?
      attribute 0x004B, :number_of_schedules, UInt8, computed: true, optional: true,
        requires: :matter_schedules, present_if: :schedule_wire_ready?
      attribute 0x004C, :number_of_schedule_transitions, UInt8, computed: true, optional: true,
        requires: :matter_schedules, present_if: :schedule_wire_ready?
      attribute 0x004D, :number_of_schedule_transition_per_day, UInt8, computed: true,
        nullable: true, optional: true, requires: :matter_schedules, present_if: :schedule_wire_ready?
      attribute 0x004E, :active_preset_handle, Bytes, computed: true, nullable: true, optional: true,
        requires: :presets, present_if: :preset_wire_ready?
      attribute 0x004F, :active_schedule_handle, Bytes, computed: true, nullable: true, optional: true,
        requires: :matter_schedules, present_if: :schedule_wire_ready?
      attribute 0x0050, :presets, Array(Preset), computed: true, writable: true, write_access: :manage,
        optional: true, requires: :presets, present_if: :preset_wire_ready?
      attribute 0x0051, :schedules, Array(Schedule), computed: true, writable: true, write_access: :manage,
        optional: true, requires: :matter_schedules, present_if: :schedule_wire_ready?
      attribute 0x0053, :max_thermostat_suggestions, UInt8, computed: true,
        optional: true, min: MIN_SUGGESTION_CAPACITY,
        requires: :thermostat_suggestions, present_if: :suggestion_wire_ready?
      attribute 0x0054, :thermostat_suggestions, Array(ThermostatSuggestion), computed: true,
        optional: true, requires: :thermostat_suggestions, present_if: :suggestion_wire_ready?
      attribute 0x0055, :current_thermostat_suggestion, ThermostatSuggestion, computed: true,
        nullable: true, optional: true, requires: :thermostat_suggestions, present_if: :suggestion_wire_ready?
      attribute 0x0056, :thermostat_suggestion_not_following_reason, ThermostatSuggestionNotFollowingReason,
        computed: true, nullable: true, optional: true,
        requires: :thermostat_suggestions, present_if: :suggestion_wire_ready?

      event 0x00, :system_mode_change, priority: :info, requires: :events, payload: SystemModeChangeEvent
      event 0x01, :local_temperature_change, priority: :info,
        requires: {events: true, local_temperature_not_exposed: false}, payload: LocalTemperatureChangeEvent
      event 0x02, :occupancy_change, priority: :info,
        requires: {events: true, occupancy: true}, payload: OccupancyChangeEvent
      event 0x03, :setpoint_change, priority: :info, requires: :events, payload: SetpointChangeEvent
      event 0x04, :running_state_change, priority: :info, requires: :events, payload: RunningStateChangeEvent
      event 0x05, :running_mode_change, priority: :info,
        requires: {events: true, automode: true}, payload: RunningModeChangeEvent
      event 0x06, :active_schedule_change, priority: :info,
        requires: {events: true, matter_schedules: true}, payload: ActiveScheduleChangeEvent
      event 0x07, :active_preset_change, priority: :info,
        requires: {events: true, presets: true}, payload: ActivePresetChangeEvent

      command 0x00, :setpoint_raise_lower, request: SetpointRaiseLowerRequest
      command 0x05, :set_active_schedule, request: SetActiveScheduleRequest, handler: :activate_schedule,
        requires: :matter_schedules, present_if: :schedule_wire_ready?
      command 0x06, :set_active_preset, request: SetActivePresetRequest, handler: :activate_preset,
        requires: :presets, present_if: :preset_wire_ready?
      command 0x07, :add_thermostat_suggestion, request: AddThermostatSuggestionRequest,
        handler: :add_thermostat_suggestion_wire, response: AddThermostatSuggestionResponse,
        response_id: 0x02, access: :manage,
        requires: :thermostat_suggestions, present_if: :suggestion_wire_ready?
      command 0x08, :remove_thermostat_suggestion, request: RemoveThermostatSuggestionRequest,
        access: :manage, requires: :thermostat_suggestions, present_if: :suggestion_wire_ready?
      command 0xFE, :atomic_request, request: AtomicRequest, response: AtomicResponse,
        response_id: 0xFD, access: :manage, present_if: :atomic_wire_ready?

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @feature_map : Feature = Feature::Cooling | Feature::Heating,
                     @local_temperature : Int16? = nil,
                     @occupied_cooling_setpoint : Int16 = DEFAULT_COOLING_SETPOINT,
                     @occupied_heating_setpoint : Int16 = DEFAULT_HEATING_SETPOINT,
                     @occupancy : UInt8 = 1_u8,
                     @unoccupied_cooling_setpoint : Int16 = DEFAULT_COOLING_SETPOINT,
                     @unoccupied_heating_setpoint : Int16 = DEFAULT_HEATING_SETPOINT,
                     @abs_min_heat_setpoint_limit : Int16 = DEFAULT_ABS_MIN_HEAT,
                     @abs_max_heat_setpoint_limit : Int16 = DEFAULT_ABS_MAX_HEAT,
                     @abs_min_cool_setpoint_limit : Int16 = DEFAULT_ABS_MIN_COOL,
                     @abs_max_cool_setpoint_limit : Int16 = DEFAULT_ABS_MAX_COOL,
                     @min_heat_setpoint_limit : Int16 = DEFAULT_ABS_MIN_HEAT,
                     @max_heat_setpoint_limit : Int16 = DEFAULT_ABS_MAX_HEAT,
                     @min_cool_setpoint_limit : Int16 = DEFAULT_ABS_MIN_COOL,
                     @max_cool_setpoint_limit : Int16 = DEFAULT_ABS_MAX_COOL,
                     @min_setpoint_dead_band : Int8 = DEFAULT_DEAD_BAND,
                     control_sequence_of_operation : ControlSequenceOfOperation? = nil,
                     @system_mode : SystemMode = SystemMode::Off,
                     @thermostat_running_mode : ThermostatRunningMode = ThermostatRunningMode::Off,
                     preset_types : Array(PresetType)? = nil,
                     presets : Array(Preset) = [] of Preset,
                     local_time_provider : Proc(Time?)? = nil,
                     utc_time_provider : Proc(UInt32?)? = nil,
                     @suggestion_timer_scheduler : Proc(Time::Span, Proc(Nil), Nil) = ->(delay : Time::Span, action : Proc(Nil)) : Nil {
                       spawn { sleep delay; action.call }
                       nil
                     })
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))

        @schedule_clock_configured = !local_time_provider.nil?
        @local_time_provider = local_time_provider || -> : Time? { nil }
        @suggestion_clock_configured = !utc_time_provider.nil?
        @utc_time_provider = utc_time_provider || -> : UInt32? { nil }
        if @feature_map.automode? && !(@feature_map.heating? && @feature_map.cooling?)
          raise ArgumentError.new("AUTO requires HEAT and COOL")
        end
        raise ArgumentError.new("Thermostat requires HEAT or COOL") unless @feature_map.heating? || @feature_map.cooling?

        @control_sequence_of_operation = control_sequence_of_operation || default_control_sequence
        validate_control_sequence!

        @measured_temperature = @local_temperature
        @local_temperature = nil if @feature_map.local_temperature_not_exposed?
        @last_reported_temperature = @local_temperature
        @last_occupancy = @occupancy
        @last_temperature_event_at = nil.as(Time::Instant?)
        @last_running_state = thermostat_running_state
        @preset_types = [] of PresetType
        @presets = [] of Preset
        @used_preset_handles = [] of Bytes
        @active_preset_handle = nil.as(Bytes?)
        @max_thermostat_suggestions = MIN_SUGGESTION_CAPACITY
        @thermostat_suggestions = [] of ThermostatSuggestion
        @next_suggestion_id = 0_u8
        @current_thermostat_suggestion = nil.as(ThermostatSuggestion?)
        @last_suggestion_now = nil.as(UInt32?)
        @suggestion_timer_boundary = nil.as(UInt32?)
        @suggestion_timer_generation = 0_u64
        @applying_preset = false
        @pending_preset_write = nil.as(PendingPresetWrite?)
        @pending_schedule_write = nil.as(PendingScheduleWrite?)
        @combined_atomic_write = false
        @schedule_types = [] of ScheduleType
        @schedules = [] of Schedule
        @used_schedule_handles = [] of Bytes
        @active_schedule_handle = nil.as(Bytes?)
        @last_schedule_occurrence = nil.as(Tuple(Int64, UInt16)?)
        @number_of_schedule_transitions = 0_u8
        @number_of_schedule_transition_per_day = nil.as(UInt8?)

        raise ArgumentError.new("PRES wire conformance is not yet enabled") if @feature_map.presets? && !preset_wire_ready?
        raise ArgumentError.new("MSCH wire conformance is not yet enabled") if @feature_map.matter_schedules? && !schedule_wire_ready?
        raise ArgumentError.new("TSUGGEST requires PRES") if @feature_map.thermostat_suggestions? && !@feature_map.presets?
        raise ArgumentError.new("TSUGGEST wire conformance is not yet enabled") if @feature_map.thermostat_suggestions? && !suggestion_wire_ready?
        validate_occupancy(@occupancy)

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

        if types = preset_types
          configure_presets(types, presets)
        elsif !presets.empty?
          raise ArgumentError.new("preset_types are required when presets are configured")
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

      before_write :presets do |values|
        stage_presets(values)
      end

      before_write :schedules do |values|
        stage_schedules(values)
      end

      before_write :occupied_heating_setpoint do |setpoint|
        return InteractionModel::Status.constraint_error unless setpoint.in?(@min_heat_setpoint_limit..@max_heat_setpoint_limit)
        keep_cooling_above(setpoint)
      end

      before_write :unoccupied_cooling_setpoint do |setpoint|
        return InteractionModel::Status.constraint_error unless setpoint.in?(@min_cool_setpoint_limit..@max_cool_setpoint_limit)
        keep_unoccupied_heating_below(setpoint)
      end

      before_write :unoccupied_heating_setpoint do |setpoint|
        return InteractionModel::Status.constraint_error unless setpoint.in?(@min_heat_setpoint_limit..@max_heat_setpoint_limit)
        keep_unoccupied_cooling_above(setpoint)
      end

      before_write :min_heat_setpoint_limit do |limit|
        return InteractionModel::Status.constraint_error unless valid_min_heat_limit?(limit)
      end

      before_write :max_heat_setpoint_limit do |limit|
        return InteractionModel::Status.constraint_error unless valid_max_heat_limit?(limit)
      end

      before_write :min_cool_setpoint_limit do |limit|
        return InteractionModel::Status.constraint_error unless valid_min_cool_limit?(limit)
      end

      before_write :max_cool_setpoint_limit do |limit|
        return InteractionModel::Status.constraint_error unless valid_max_cool_limit?(limit)
      end

      before_write :system_mode do |mode|
        InteractionModel::Status.constraint_error unless mode_allowed?(mode)
      end

      # Matter 1.6 §4.3.11.19 accepts legacy writes but leaves the host's
      # minimum deadband unchanged. The DSL validates the 0..127 range first.
      before_write :min_setpoint_dead_band do |_requested|
        @min_setpoint_dead_band
      end

      # Matter 1.6 §4.3.11.21 keeps this write accepted for legacy clients,
      # while the thermostat's physical control sequence remains fixed.
      before_write :control_sequence_of_operation do |_requested|
        @control_sequence_of_operation
      end

      # ------------------------------------------------------------------------
      # Commands
      # ------------------------------------------------------------------------

      def setpoint_raise_lower(request : SetpointRaiseLowerRequest) : InteractionModel::Status
        delta = request.amount.to_i32 * DECI_TO_CENTI_DEGREES

        if @feature_map.occupancy? && @occupancy == 0_u8
          return raise_lower_unoccupied(request.mode, delta)
        end

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

      # Configure a host-owned preset list. Production instances still reject
      # PRES; controller writes to Presets require an atomic transaction.
      def configure_presets(types : Array(PresetType), presets : Array(Preset)) : Nil
        validate_presets!(types, presets)
        unless @schedules.empty?
          validate_schedules!(@schedule_types, @schedules, @number_of_schedule_transitions,
            @number_of_schedule_transition_per_day, presets)
        end
        @pending_preset_write = nil
        if @combined_atomic_write
          @pending_schedule_write = nil
          @combined_atomic_write = false
        end
        types_changed = @preset_types != types
        capacity_changed = @preset_types.sum(&.number_of_presets.to_i) != types.sum(&.number_of_presets.to_i)
        presets_changed = @presets != presets
        remember_preset_handles(presets)
        @preset_types = types.dup
        @presets = copy_presets(presets)
        remove_orphan_suggestions
        @last_schedule_occurrence = nil if presets_changed
        update_active_preset_handle(nil)
        tick_suggestions(@last_suggestion_now)
        if @feature_map.presets? && preset_wire_ready?
          increment_version_and_notify(ATTR_PRESET_TYPES) if types_changed
          increment_version_and_notify(ATTR_NUMBER_OF_PRESETS) if capacity_changed
          increment_version_and_notify(ATTR_PRESETS) if presets_changed
        end
      end

      def preset_types : Array(PresetType)
        @preset_types.dup
      end

      def number_of_presets : UInt8
        @preset_types.sum(&.number_of_presets.to_i).to_u8
      end

      def presets : Array(Preset)
        copy_presets(@presets)
      end

      # Host state only. The TSUGGEST feature and command/attribute wire surface
      # remain gated until the pinned conformance cases have been exercised.
      def configure_suggestion_capacity(capacity : UInt8) : Nil
        raise ArgumentError.new("suggestion capacity must be at least five") if capacity < MIN_SUGGESTION_CAPACITY
        raise ArgumentError.new("suggestion capacity below live suggestion count") if capacity < @thermostat_suggestions.size
        @max_thermostat_suggestions = capacity
        suggestion_attribute_changed(ATTR_MAX_THERMOSTAT_SUGGESTIONS)
      end

      def max_thermostat_suggestions : UInt8
        @max_thermostat_suggestions
      end

      # The device runtime supplies the root Time Synchronization clock when
      # the host did not explicitly provide a synchronized UTC source.
      def bind_suggestion_utc_provider(provider : Proc(UInt32?)) : Nil
        return if @suggestion_clock_configured
        @utc_time_provider = provider
        @suggestion_clock_configured = true
      end

      def suggestion_polling_enabled? : Bool
        @feature_map.thermostat_suggestions? && suggestion_wire_ready? && @suggestion_clock_configured
      end

      def poll_suggestions : Int32
        tick_suggestions(@utc_time_provider.call)
      end

      def thermostat_suggestions : Array(ThermostatSuggestion)
        tick_suggestions(@utc_time_provider.call) if @feature_map.thermostat_suggestions? && suggestion_wire_ready?
        copy_suggestions(@thermostat_suggestions)
      end

      def current_thermostat_suggestion : ThermostatSuggestion?
        tick_suggestions(@utc_time_provider.call) if @feature_map.thermostat_suggestions? && suggestion_wire_ready?
        @current_thermostat_suggestion.try { |entry| copy_suggestion(entry) }
      end

      def thermostat_suggestion_not_following_reason : ThermostatSuggestionNotFollowingReason?
        nil
      end

      protected def suggestion_wire_ready? : Bool
        false
      end

      protected def suggestion_wire_ready?(command_id : UInt32) : Bool
        suggestion_wire_ready?
      end

      private def add_thermostat_suggestion_wire(request : AddThermostatSuggestionRequest) : AddThermostatSuggestionResponse | InteractionModel::Status
        add_thermostat_suggestion(request, @utc_time_provider.call)
      end

      private def suggestion_attribute_changed(attribute_id : UInt32) : Nil
        if @feature_map.thermostat_suggestions? && suggestion_wire_ready?
          increment_version_and_notify(attribute_id)
        else
          increment_version
        end
      end

      def add_thermostat_suggestion(request : AddThermostatSuggestionRequest,
                                    now_epoch : UInt32?) : AddThermostatSuggestionResponse | InteractionModel::Status
        now = now_epoch || return InteractionModel::Status.invalid_in_state
        return InteractionModel::Status.not_found unless @presets.any? { |preset| preset.preset_handle == request.preset_handle }
        effective = request.effective_time || now
        return InteractionModel::Status.invalid_command if effective.to_u64 > now.to_u64 + MAX_SUGGESTION_AHEAD_SECONDS
        expiration = effective.to_u64 + request.expiration_in_minutes.to_u64 * 60_u64
        return InteractionModel::Status.invalid_command if expiration > UInt32::MAX
        tick_suggestions(now)
        return InteractionModel::Status.resource_exhausted if @thermostat_suggestions.size >= @max_thermostat_suggestions

        id = @next_suggestion_id
        256.times do
          break unless @thermostat_suggestions.any? { |entry| entry.unique_id == id }
          id = id &+ 1_u8
        end
        return InteractionModel::Status.resource_exhausted if @thermostat_suggestions.any? { |entry| entry.unique_id == id }
        @next_suggestion_id = id &+ 1_u8
        @thermostat_suggestions << ThermostatSuggestion.new(id, request.preset_handle.dup, effective, expiration.to_u32)
        suggestion_attribute_changed(ATTR_THERMOSTAT_SUGGESTIONS)
        tick_suggestions(now)
        AddThermostatSuggestionResponse.new(id)
      end

      def remove_thermostat_suggestion(request : RemoveThermostatSuggestionRequest) : InteractionModel::Status
        index = @thermostat_suggestions.index { |entry| entry.unique_id == request.unique_id }
        return InteractionModel::Status.not_found unless index
        @thermostat_suggestions.delete_at(index)
        suggestion_attribute_changed(ATTR_THERMOSTAT_SUGGESTIONS)
        if now = @last_suggestion_now
          tick_suggestions(now)
        elsif @current_thermostat_suggestion.try(&.unique_id) == request.unique_id
          @current_thermostat_suggestion = nil
        end
        InteractionModel::Status.success
      end

      # Called by a host time service. UTC is deliberately explicit; the wire
      # feature cannot rely on an unverified local wall clock.
      def tick_suggestions(now_epoch : UInt32?) : Int32
        now = now_epoch || return 0
        @last_suggestion_now = now
        removed = @thermostat_suggestions.count { |entry| entry.expiration_time <= now }
        if removed > 0
          @thermostat_suggestions.reject! { |entry| entry.expiration_time <= now }
          suggestion_attribute_changed(ATTR_THERMOSTAT_SUGGESTIONS)
        end
        selected = @thermostat_suggestions
          .select do |entry|
            entry.effective_time <= now && entry.expiration_time > now &&
              @presets.any? { |preset| preset.preset_handle == entry.preset_handle && valid_preset_setpoints?(preset) }
          end
          .min_by? { |entry| {entry.effective_time, entry.unique_id} }
        if @current_thermostat_suggestion.try(&.unique_id) != selected.try(&.unique_id)
          @current_thermostat_suggestion = selected.try { |entry| copy_suggestion(entry) }
          suggestion_attribute_changed(ATTR_CURRENT_THERMOSTAT_SUGGESTION)
        end
        if selected && @active_preset_handle != selected.preset_handle
          activate_preset(SetActivePresetRequest.new(selected.preset_handle))
        end
        schedule_suggestion_boundary(now)
        removed
      end

      private def schedule_suggestion_boundary(now : UInt32) : Nil
        return unless @feature_map.thermostat_suggestions? && suggestion_wire_ready?
        next_boundary = nil.as(UInt32?)
        @thermostat_suggestions.each do |entry|
          if entry.effective_time > now
            next_boundary = {next_boundary || UInt32::MAX, entry.effective_time}.min
          end
          if entry.expiration_time > now
            next_boundary = {next_boundary || UInt32::MAX, entry.expiration_time}.min
          end
        end
        return if @suggestion_timer_boundary == next_boundary
        @suggestion_timer_boundary = next_boundary
        @suggestion_timer_generation &+= 1_u64
        return unless boundary = next_boundary
        generation = @suggestion_timer_generation
        delay = (boundary.to_i64 - now.to_i64).seconds
        @suggestion_timer_scheduler.call(delay, -> : Nil {
          if @suggestion_timer_generation == generation
            @suggestion_timer_boundary = nil
            tick_suggestions(@utc_time_provider.call)
          end
        })
      end

      # Host-owned schedule configuration. The MSCH wire feature remains gated
      # while its remaining conformance checks are completed.
      def configure_schedules(types : Array(ScheduleType), schedules : Array(Schedule),
                              max_transitions : UInt8, max_per_day : UInt8?) : Nil
        validate_schedules!(types, schedules, max_transitions, max_per_day)
        types_changed = @schedule_types != types
        capacity_changed = number_of_schedules != types.sum(&.number_of_schedules.to_i)
        transitions_changed = @number_of_schedule_transitions != max_transitions
        per_day_changed = @number_of_schedule_transition_per_day != max_per_day
        schedules_changed = @schedules != schedules
        schedules.each do |entry|
          handle = entry.schedule_handle || raise ArgumentError.new("configured schedule needs a handle")
          if @used_schedule_handles.any? { |used| used == handle } &&
             @schedules.none? { |old| old.schedule_handle == handle }
            raise ArgumentError.new("schedule handle was previously deleted")
          end
        end
        @schedules.each do |old|
          if old.built_in && schedules.none? { |entry| entry.schedule_handle == old.schedule_handle }
            raise ArgumentError.new("built-in schedule cannot be deleted")
          end
          if replacement = schedules.find { |entry| entry.schedule_handle == old.schedule_handle }
            raise ArgumentError.new("built-in schedule cannot be changed") if replacement.built_in != old.built_in
          end
        end
        if @active_schedule_handle && schedules.none? { |entry| entry.schedule_handle == @active_schedule_handle }
          raise ArgumentError.new("active schedule cannot be deleted")
        end
        @schedule_types = types.dup
        @pending_schedule_write = nil
        if @combined_atomic_write
          @pending_preset_write = nil
          @combined_atomic_write = false
        end
        @schedules = copy_schedules(schedules)
        @last_schedule_occurrence = nil
        @number_of_schedule_transitions = max_transitions
        @number_of_schedule_transition_per_day = max_per_day
        remember_schedule_handles(@schedules)
        if @feature_map.matter_schedules? && schedule_wire_ready?
          increment_version_and_notify(ATTR_SCHEDULE_TYPES) if types_changed
          increment_version_and_notify(ATTR_NUMBER_OF_SCHEDULES) if capacity_changed
          increment_version_and_notify(ATTR_NUMBER_OF_SCHEDULE_TRANSITIONS) if transitions_changed
          increment_version_and_notify(ATTR_NUMBER_OF_SCHEDULE_TRANSITION_PER_DAY) if per_day_changed
          increment_version_and_notify(ATTR_SCHEDULES) if schedules_changed
        end
      end

      def schedule_types : Array(ScheduleType)
        @schedule_types.dup
      end

      def schedules : Array(Schedule)
        copy_schedules(@schedules)
      end

      def number_of_schedules : UInt8
        @schedule_types.sum(&.number_of_schedules.to_i).to_u8
      end

      def number_of_schedule_transitions : UInt8
        @number_of_schedule_transitions
      end

      def number_of_schedule_transition_per_day : UInt8?
        @number_of_schedule_transition_per_day
      end

      def active_schedule_handle : Bytes?
        @active_schedule_handle.try(&.dup)
      end

      # Selects a committed schedule. Production MSCH wire exposure remains
      # gated while its remaining conformance checks are completed.
      def activate_schedule(request : SetActiveScheduleRequest) : InteractionModel::Status
        handle = request.schedule_handle
        return InteractionModel::Status.constraint_error if handle.size > MAX_SCHEDULE_HANDLE_LENGTH
        return InteractionModel::Status.invalid_command unless @schedules.any? { |entry| entry.schedule_handle == handle }

        update_active_schedule_handle(handle)
        tick_schedule
        InteractionModel::Status.success
      end

      # Hosts call this when local civil time becomes available or advances.
      # The clock must already include the intended timezone and DST offset.
      # It returns true when a new weekly transition occurrence was evaluated.
      def tick_schedule(local_time : Time? = @local_time_provider.call) : Bool
        unless local_time
          @last_schedule_occurrence = nil
          return false
        end
        handle = @active_schedule_handle || return false
        schedule = @schedules.find { |entry| entry.schedule_handle == handle } || return false
        occurrence = schedule_transition_at(schedule, local_time) || return false
        date, transition = occurrence
        key = {date, transition.transition_time}
        if previous = @last_schedule_occurrence
          # During a repeated DST hour, an earlier wall-clock transition must
          # not undo a later transition already applied on the same date.
          return false if date == previous[0] && transition.transition_time <= previous[1]
          return false if key == previous
        end

        return false unless apply_schedule_transition(schedule, transition)
        @last_schedule_occurrence = key
        true
      end

      # Runtime polling is only useful when the host explicitly supplies local
      # civil time and the guarded MSCH implementation is enabled.
      def schedule_polling_enabled? : Bool
        @feature_map.matter_schedules? && @schedule_clock_configured && schedule_wire_ready?
      end

      protected def schedules=(values : Array(Schedule)) : Nil
        raise ArgumentError.new("Schedules require an atomic transaction")
      end

      protected def schedule_wire_ready? : Bool
        false
      end

      protected def schedule_wire_ready?(command_id : UInt32) : Bool
        schedule_wire_ready?
      end

      protected def atomic_wire_ready? : Bool
        (@feature_map.presets? && preset_wire_ready?) ||
          (@feature_map.matter_schedules? && schedule_wire_ready?)
      end

      protected def atomic_wire_ready?(command_id : UInt32) : Bool
        atomic_wire_ready?
      end

      # IM writes are handled by the pending atomic transaction. This setter
      # exists for the computed writable attribute's DSL contract only.
      protected def presets=(values : Array(Preset)) : Nil
        raise ArgumentError.new("Presets require an atomic transaction")
      end

      protected def preset_wire_ready? : Bool
        false
      end

      protected def preset_wire_ready?(command_id : UInt32) : Bool
        preset_wire_ready?
      end

      def active_preset_handle : Bytes?
        @active_preset_handle.try(&.dup)
      end

      # Command 0x06 is declared behind the production PRES gate.
      def activate_preset(request : SetActivePresetRequest) : InteractionModel::Status
        handle = request.preset_handle
        if handle.nil?
          update_active_preset_handle(nil)
          return InteractionModel::Status.success
        end
        return InteractionModel::Status.constraint_error if handle.size > MAX_PRESET_HANDLE_LENGTH
        preset = @presets.find { |entry| entry.preset_handle == handle }
        return InteractionModel::Status.invalid_command unless preset
        return InteractionModel::Status.constraint_error unless valid_preset_setpoints?(preset)

        @applying_preset = true
        begin
          if @feature_map.cooling? && (cooling = preset.cooling_setpoint)
            if @feature_map.occupancy? && @occupancy == 0_u8
              self.unoccupied_cooling_setpoint = cooling
            else
              self.occupied_cooling_setpoint = cooling
            end
          end
          if @feature_map.heating? && (heating = preset.heating_setpoint)
            if @feature_map.occupancy? && @occupancy == 0_u8
              self.unoccupied_heating_setpoint = heating
            else
              self.occupied_heating_setpoint = heating
            end
          end
          update_active_preset_handle(handle)
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
        combined = ids.size == 2 && ids.includes?(ATTR_PRESETS) && ids.includes?(ATTR_SCHEDULES)
        return InteractionModel::Status.invalid_command unless ids == [ATTR_PRESETS] || ids == [ATTR_SCHEDULES] || combined
        return InteractionModel::Status.invalid_command if !request.request_type.begin_write? && request.timeout
        expire_preset_write
        expire_schedule_write

        if combined
          return InteractionModel::Status.invalid_command unless @feature_map.presets? && @feature_map.matter_schedules?
          return atomic_combined_request(request)
        end
        if ids == [ATTR_SCHEDULES]
          return InteractionModel::Status.invalid_command unless @feature_map.matter_schedules?
          return atomic_schedule_request(request)
        end

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
      # owns the matching atomic transaction.
      def read_attribute(attribute_id : UInt32, fabric_index : UInt8? = nil) : InteractionModel::Status | TLV::Any
        if attribute_id == ATTR_PRESETS && dsl_attribute_presets_supported?
          expire_preset_write
          if (pending = @pending_preset_write) && atomic_owner?(pending)
            return tlv(copy_presets(pending.presets || @presets))
          end
        end
        if attribute_id == ATTR_SCHEDULES && dsl_attribute_schedules_supported?
          expire_schedule_write
          if (pending = @pending_schedule_write) && schedule_atomic_owner?(pending)
            return tlv(copy_schedules(pending.schedules || @schedules))
          end
        end
        super
      end

      protected def handle_write_attribute(attribute_id : UInt32, value : TLV::Any) : InteractionModel::Status
        if attribute_id == ATTR_SCHEDULES && @pending_schedule_write
          return stage_schedules(decode(value, Array(Schedule)))
        end
        return super unless attribute_id == ATTR_PRESETS && @pending_preset_write

        stage_presets(decode(value, Array(Preset)))
      end

      # List append and whole-list replacement both generate handles for new
      # presets. IMHandler calls this after validating the append sequence and
      # Manage access.
      def append_preset(value : TLV::Any) : InteractionModel::Status
        entry = decode?(value, Preset) || return InteractionModel::Status.invalid_data_type
        expire_preset_write
        pending = @pending_preset_write || return InteractionModel::Status.invalid_in_state
        return InteractionModel::Status.busy unless atomic_owner?(pending)

        stage_presets((pending.presets || @presets) + [entry])
      end

      def append_schedule(value : TLV::Any) : InteractionModel::Status
        entry = decode?(value, Schedule) || return InteractionModel::Status.invalid_data_type
        expire_schedule_write
        pending = @pending_schedule_write || return InteractionModel::Status.invalid_in_state
        return InteractionModel::Status.invalid_in_state unless schedule_atomic_owner?(pending)

        stage_schedules((pending.schedules || @schedules) + [entry], allow_new: true)
      end

      # IM records each successful conditional list write. The version must
      # still match when the pending list is published at commit.
      def record_preset_write_data_version(version : UInt32?) : Nil
        return unless version
        pending = @pending_preset_write || return
        return unless atomic_owner?(pending)
        pending.write_data_versions << version unless pending.write_data_versions.includes?(version)
      end

      def record_schedule_write_data_version(version : UInt32?) : Nil
        return unless version
        pending = @pending_schedule_write || return
        return unless schedule_atomic_owner?(pending)
        pending.write_data_versions << version unless pending.write_data_versions.includes?(version)
      end

      # A removed fabric no longer owns an Atomic Write State, even if its
      # index is later assigned to another fabric before the timeout expires.
      def remove_fabric(fabric_index : UInt8) : Nil
        if @combined_atomic_write &&
           (@pending_preset_write.try(&.fabric) == fabric_index ||
           @pending_schedule_write.try(&.fabric) == fabric_index)
          @pending_preset_write = nil
          @pending_schedule_write = nil
          @combined_atomic_write = false
          return
        end
        if (pending = @pending_preset_write) && pending.fabric == fabric_index
          @pending_preset_write = nil
        end
        if (pending = @pending_schedule_write) && pending.fabric == fabric_index
          @pending_schedule_write = nil
        end
      end

      private def atomic_begin(request : AtomicRequest) : AtomicResponse | InteractionModel::Status
        timeout = request.timeout || return InteractionModel::Status.invalid_command
        return InteractionModel::Status.invalid_command if timeout == 0_u16
        actual_timeout = {timeout, MAX_PRESET_ATOMIC_TIMEOUT}.min
        if current = @pending_preset_write
          return InteractionModel::Status.invalid_in_state if atomic_owner?(current)
        end

        ids = request.attribute_requests
        if @preset_types.empty?
          return atomic_response(InteractionModel::StatusCode::Failure,
            ids.map { |id| AtomicAttributeStatus.new(id, InteractionModel::StatusCode::InvalidCommand) }, actual_timeout)
        end
        if @pending_preset_write || @pending_schedule_write
          return atomic_response(InteractionModel::StatusCode::Failure,
            [AtomicAttributeStatus.new(ATTR_PRESETS, InteractionModel::StatusCode::Busy)], actual_timeout)
        end

        fabric = request_fabric_index || return InteractionModel::Status.invalid_command
        subject = request_peer_node_id || return InteractionModel::Status.invalid_command
        @pending_preset_write = PendingPresetWrite.new(
          fabric, subject, Time.instant + actual_timeout.milliseconds)
        atomic_response(InteractionModel::StatusCode::Success,
          [AtomicAttributeStatus.new(ATTR_PRESETS, InteractionModel::StatusCode::Success)], actual_timeout)
      end

      private def atomic_finish(ids : Array(UInt32), *, commit : Bool) : AtomicResponse | InteractionModel::Status
        return InteractionModel::Status.invalid_in_state if @combined_atomic_write
        pending = @pending_preset_write || return InteractionModel::Status.invalid_in_state
        return InteractionModel::Status.invalid_in_state unless atomic_owner?(pending) && ids == [ATTR_PRESETS]
        @pending_preset_write = nil
        if commit && (values = pending.presets)
          if pending.write_data_versions.any? { |version| version != data_version }
            return atomic_response(InteractionModel::StatusCode::Failure,
              [AtomicAttributeStatus.new(ATTR_PRESETS, InteractionModel::StatusCode::DataVersionMismatch)])
          end
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
          if !@schedules.empty?
            begin
              validate_schedules!(@schedule_types, @schedules, @number_of_schedule_transitions,
                @number_of_schedule_transition_per_day, values)
            rescue ArgumentError
              return atomic_response(InteractionModel::StatusCode::Failure,
                [AtomicAttributeStatus.new(ATTR_PRESETS, InteractionModel::StatusCode::ConstraintError)])
            end
          end
          unless @presets == values
            remember_preset_handles(values)
            @presets = copy_presets(values)
            remove_orphan_suggestions
            @last_schedule_occurrence = nil
            increment_version_and_notify(ATTR_PRESETS)
          end
        end
        atomic_response(InteractionModel::StatusCode::Success,
          commit ? [] of AtomicAttributeStatus : [AtomicAttributeStatus.new(ATTR_PRESETS, InteractionModel::StatusCode::Success)])
      end

      private def atomic_schedule_request(request : AtomicRequest) : AtomicResponse | InteractionModel::Status
        ids = request.attribute_requests
        case request.request_type
        when .begin_write?
          timeout = request.timeout || return InteractionModel::Status.invalid_command
          return InteractionModel::Status.invalid_command if timeout == 0_u16
          actual_timeout = {timeout, MAX_PRESET_ATOMIC_TIMEOUT}.min
          if current = @pending_schedule_write
            return InteractionModel::Status.invalid_in_state if schedule_atomic_owner?(current)
          end
          if @schedule_types.empty?
            return atomic_response(InteractionModel::StatusCode::Failure,
              [AtomicAttributeStatus.new(ATTR_SCHEDULES, InteractionModel::StatusCode::InvalidCommand)], actual_timeout)
          end
          if @pending_schedule_write || @pending_preset_write
            return atomic_response(InteractionModel::StatusCode::Failure,
              [AtomicAttributeStatus.new(ATTR_SCHEDULES, InteractionModel::StatusCode::Busy)], actual_timeout)
          end
          fabric = request_fabric_index || return InteractionModel::Status.invalid_command
          subject = request_peer_node_id || return InteractionModel::Status.invalid_command
          @pending_schedule_write = PendingScheduleWrite.new(fabric, subject,
            Time.instant + actual_timeout.milliseconds)
          atomic_response(InteractionModel::StatusCode::Success,
            [AtomicAttributeStatus.new(ATTR_SCHEDULES, InteractionModel::StatusCode::Success)], actual_timeout)
        when .commit_write?, .rollback_write?
          atomic_schedule_finish(ids, commit: request.request_type.commit_write?)
        else
          InteractionModel::Status.invalid_command
        end
      end

      private def atomic_schedule_finish(ids : Array(UInt32), *, commit : Bool) : AtomicResponse | InteractionModel::Status
        return InteractionModel::Status.invalid_in_state if @combined_atomic_write
        pending = @pending_schedule_write || return InteractionModel::Status.invalid_in_state
        return InteractionModel::Status.invalid_in_state unless schedule_atomic_owner?(pending) && ids == [ATTR_SCHEDULES]
        @pending_schedule_write = nil
        if commit && (values = pending.schedules)
          if pending.write_data_versions.any? { |version| version != data_version }
            return atomic_response(InteractionModel::StatusCode::Failure,
              [AtomicAttributeStatus.new(ATTR_SCHEDULES, InteractionModel::StatusCode::DataVersionMismatch)])
          end
          if @schedules.any? { |entry| entry.built_in && !values.any? { |candidate| candidate.schedule_handle == entry.schedule_handle } }
            return atomic_response(InteractionModel::StatusCode::Failure,
              [AtomicAttributeStatus.new(ATTR_SCHEDULES, InteractionModel::StatusCode::ConstraintError)])
          end
          if @active_schedule_handle && !values.any? { |entry| entry.schedule_handle == @active_schedule_handle }
            return atomic_response(InteractionModel::StatusCode::Failure,
              [AtomicAttributeStatus.new(ATTR_SCHEDULES, InteractionModel::StatusCode::InvalidInState)])
          end
          begin
            validate_schedules!(@schedule_types, values, @number_of_schedule_transitions,
              @number_of_schedule_transition_per_day)
          rescue ArgumentError
            return atomic_response(InteractionModel::StatusCode::Failure,
              [AtomicAttributeStatus.new(ATTR_SCHEDULES, InteractionModel::StatusCode::ConstraintError)])
          end
          unless @schedules == values
            remember_schedule_handles(values)
            @schedules = copy_schedules(values)
            @last_schedule_occurrence = nil
            increment_version_and_notify(ATTR_SCHEDULES)
          end
        end
        atomic_response(InteractionModel::StatusCode::Success,
          commit ? [] of AtomicAttributeStatus : [AtomicAttributeStatus.new(ATTR_SCHEDULES, InteractionModel::StatusCode::Success)])
      end

      private def atomic_combined_request(request : AtomicRequest) : AtomicResponse | InteractionModel::Status
        ids = request.attribute_requests
        case request.request_type
        when .begin_write?
          timeout = request.timeout || return InteractionModel::Status.invalid_command
          return InteractionModel::Status.invalid_command if timeout == 0_u16
          actual_timeout = {timeout, MAX_PRESET_ATOMIC_TIMEOUT}.min
          preset_owner = @pending_preset_write.try { |pending| atomic_owner?(pending) } || false
          schedule_owner = @pending_schedule_write.try { |pending| schedule_atomic_owner?(pending) } || false
          if preset_owner || schedule_owner
            return InteractionModel::Status.invalid_in_state
          end
          if @preset_types.empty? || @schedule_types.empty?
            return atomic_response(InteractionModel::StatusCode::Failure,
              ids.map { |id| AtomicAttributeStatus.new(id, InteractionModel::StatusCode::InvalidCommand) }, actual_timeout)
          end
          if @pending_preset_write || @pending_schedule_write
            return atomic_response(InteractionModel::StatusCode::Failure,
              ids.map { |id| AtomicAttributeStatus.new(id, InteractionModel::StatusCode::Busy) }, actual_timeout)
          end
          fabric = request_fabric_index || return InteractionModel::Status.invalid_command
          subject = request_peer_node_id || return InteractionModel::Status.invalid_command
          expires_at = Time.instant + actual_timeout.milliseconds
          @pending_preset_write = PendingPresetWrite.new(fabric, subject, expires_at)
          @pending_schedule_write = PendingScheduleWrite.new(fabric, subject, expires_at)
          @combined_atomic_write = true
          atomic_response(InteractionModel::StatusCode::Success,
            ids.map { |id| AtomicAttributeStatus.new(id, InteractionModel::StatusCode::Success) }, actual_timeout)
        when .commit_write?, .rollback_write?
          atomic_combined_finish(ids, commit: request.request_type.commit_write?)
        else
          InteractionModel::Status.invalid_command
        end
      end

      private def atomic_combined_finish(ids : Array(UInt32), *, commit : Bool) : AtomicResponse | InteractionModel::Status
        presets_write = @pending_preset_write || return InteractionModel::Status.invalid_in_state
        schedules_write = @pending_schedule_write || return InteractionModel::Status.invalid_in_state
        return InteractionModel::Status.invalid_in_state unless @combined_atomic_write &&
                                                                atomic_owner?(presets_write) && schedule_atomic_owner?(schedules_write)
        @pending_preset_write = nil
        @pending_schedule_write = nil
        @combined_atomic_write = false
        unless commit
          return atomic_response(InteractionModel::StatusCode::Success,
            ids.map { |id| AtomicAttributeStatus.new(id, InteractionModel::StatusCode::Success) })
        end

        presets = presets_write.presets || @presets
        schedules = schedules_write.schedules || @schedules
        if presets_write.write_data_versions.any? { |version| version != data_version }
          return atomic_response(InteractionModel::StatusCode::Failure,
            [AtomicAttributeStatus.new(ATTR_PRESETS, InteractionModel::StatusCode::DataVersionMismatch)])
        end
        if schedules_write.write_data_versions.any? { |version| version != data_version }
          return atomic_response(InteractionModel::StatusCode::Failure,
            [AtomicAttributeStatus.new(ATTR_SCHEDULES, InteractionModel::StatusCode::DataVersionMismatch)])
        end
        if @presets.any? { |entry| entry.built_in && !presets.any? { |candidate| candidate.preset_handle == entry.preset_handle } }
          return atomic_response(InteractionModel::StatusCode::Failure,
            [AtomicAttributeStatus.new(ATTR_PRESETS, InteractionModel::StatusCode::ConstraintError)])
        end
        if @active_preset_handle && !presets.any? { |entry| entry.preset_handle == @active_preset_handle }
          return atomic_response(InteractionModel::StatusCode::Failure,
            [AtomicAttributeStatus.new(ATTR_PRESETS, InteractionModel::StatusCode::InvalidInState)])
        end
        if @schedules.any? { |entry| entry.built_in && !schedules.any? { |candidate| candidate.schedule_handle == entry.schedule_handle } }
          return atomic_response(InteractionModel::StatusCode::Failure,
            [AtomicAttributeStatus.new(ATTR_SCHEDULES, InteractionModel::StatusCode::ConstraintError)])
        end
        if @active_schedule_handle && !schedules.any? { |entry| entry.schedule_handle == @active_schedule_handle }
          return atomic_response(InteractionModel::StatusCode::Failure,
            [AtomicAttributeStatus.new(ATTR_SCHEDULES, InteractionModel::StatusCode::InvalidInState)])
        end
        begin
          validate_presets!(@preset_types, presets)
        rescue ArgumentError
          return atomic_response(InteractionModel::StatusCode::Failure,
            [AtomicAttributeStatus.new(ATTR_PRESETS, InteractionModel::StatusCode::ConstraintError)])
        end
        begin
          validate_schedules!(@schedule_types, schedules, @number_of_schedule_transitions,
            @number_of_schedule_transition_per_day, presets)
        rescue ArgumentError
          return atomic_response(InteractionModel::StatusCode::Failure,
            [AtomicAttributeStatus.new(ATTR_SCHEDULES, InteractionModel::StatusCode::ConstraintError)])
        end

        unless @presets == presets
          remember_preset_handles(presets)
          @presets = copy_presets(presets)
          remove_orphan_suggestions
          @last_schedule_occurrence = nil
          increment_version_and_notify(ATTR_PRESETS)
        end
        unless @schedules == schedules
          remember_schedule_handles(schedules)
          @schedules = copy_schedules(schedules)
          @last_schedule_occurrence = nil
          increment_version_and_notify(ATTR_SCHEDULES)
        end
        atomic_response(InteractionModel::StatusCode::Success, [] of AtomicAttributeStatus)
      end

      private def stage_schedules(values : Array(Schedule), *, allow_new : Bool = false) : InteractionModel::Status
        expire_schedule_write
        pending = @pending_schedule_write || return InteractionModel::Status.invalid_in_state
        return InteractionModel::Status.invalid_in_state unless schedule_atomic_owner?(pending)

        capacity = @schedule_types.sum(&.number_of_schedules.to_i)
        return InteractionModel::Status.resource_exhausted if values.size > capacity
        normalized = [] of Schedule
        values.each do |entry|
          handle = entry.schedule_handle
          return InteractionModel::Status.constraint_error if handle && handle.size > MAX_SCHEDULE_HANDLE_LENGTH
          existing = if handle
                       pending.schedules.try(&.find { |current| current.schedule_handle == handle }) ||
                         @schedules.find { |current| current.schedule_handle == handle }
                     end
          return InteractionModel::Status.not_found if handle && !existing
          return InteractionModel::Status.constraint_error if handle.nil? && !allow_new
          return InteractionModel::Status.constraint_error if handle.nil? && entry.built_in == true
          return InteractionModel::Status.constraint_error if existing && !entry.built_in.nil? && entry.built_in != existing.built_in
          handle ||= new_schedule_handle(normalized)
          return InteractionModel::Status.constraint_error if normalized.any? { |current| current.schedule_handle == handle }
          normalized << Schedule.new(handle, entry.system_mode, entry.name, entry.preset_handle,
            entry.transitions, existing.try(&.built_in) || false)
        end
        if @schedule_types.any? { |type| normalized.count { |entry| entry.system_mode == type.system_mode } > type.number_of_schedules }
          return InteractionModel::Status.resource_exhausted
        end
        if normalized.any? { |entry| entry.transitions.size > @number_of_schedule_transitions }
          return InteractionModel::Status.resource_exhausted
        end
        if limit = @number_of_schedule_transition_per_day
          normalized.each do |entry|
            7.times do |bit|
              if entry.transitions.count { |transition| (transition.day_of_week & (1_u8 << bit)) != 0_u8 } > limit
                return InteractionModel::Status.resource_exhausted
              end
            end
          end
        end
        begin
          candidate_presets = @combined_atomic_write ? (@pending_preset_write.try(&.presets) || @presets) : @presets
          validate_schedules!(@schedule_types, normalized, @number_of_schedule_transitions,
            @number_of_schedule_transition_per_day, candidate_presets)
        rescue ArgumentError
          return InteractionModel::Status.constraint_error
        end
        pending.schedules = copy_schedules(normalized)
        InteractionModel::Status.success
      end

      private def new_schedule_handle(staged : Array(Schedule)) : Bytes
        loop do
          handle = candidate_schedule_handle
          return handle unless @used_schedule_handles.any? { |used| used == handle } ||
                               staged.any? { |entry| entry.schedule_handle == handle }
        end
      end

      protected def candidate_schedule_handle : Bytes
        Random::Secure.random_bytes(MAX_SCHEDULE_HANDLE_LENGTH)
      end

      private def stage_presets(values : Array(Preset)) : InteractionModel::Status
        expire_preset_write
        pending = @pending_preset_write || return InteractionModel::Status.invalid_in_state
        return InteractionModel::Status.busy unless atomic_owner?(pending)

        capacity = @preset_types.sum(&.number_of_presets.to_i)
        return InteractionModel::Status.resource_exhausted if values.size > capacity
        normalized = [] of Preset
        values.each do |entry|
          handle = entry.preset_handle
          return InteractionModel::Status.constraint_error if handle && handle.size > MAX_PRESET_HANDLE_LENGTH
          existing = if handle
                       pending.presets.try(&.find { |current| current.preset_handle == handle }) ||
                         @presets.find { |current| current.preset_handle == handle }
                     end
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
          handle = candidate_preset_handle
          return handle unless @used_preset_handles.any? { |used| used == handle } ||
                               staged.any? { |entry| entry.preset_handle == handle }
        end
      end

      protected def candidate_preset_handle : Bytes
        Random::Secure.random_bytes(MAX_PRESET_HANDLE_LENGTH)
      end

      private def remember_preset_handles(values : Array(Preset)) : Nil
        values.each do |entry|
          handle = entry.preset_handle || next
          @used_preset_handles << handle.dup unless @used_preset_handles.any? { |used| used == handle }
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

      private def schedule_atomic_owner?(pending : PendingScheduleWrite) : Bool
        atomic_peer? && pending.fabric == request_fabric_index && pending.subject == request_peer_node_id
      end

      private def expire_preset_write : Nil
        if (pending = @pending_preset_write) && Time.instant >= pending.expires_at
          @pending_preset_write = nil
          if @combined_atomic_write
            @pending_schedule_write = nil
            @combined_atomic_write = false
          end
        end
      end

      private def expire_schedule_write : Nil
        if (pending = @pending_schedule_write) && Time.instant >= pending.expires_at
          @pending_schedule_write = nil
          if @combined_atomic_write
            @pending_preset_write = nil
            @combined_atomic_write = false
          end
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

      private def raise_lower_unoccupied(mode : SetpointAdjustMode, delta : Int32) : InteractionModel::Status
        case mode
        when SetpointAdjustMode::Heat
          return InteractionModel::Status.invalid_command unless @feature_map.heating?
          heating = (@unoccupied_heating_setpoint.to_i32 + delta).clamp(@min_heat_setpoint_limit.to_i32, @max_heat_setpoint_limit.to_i32)
          if @feature_map.automode? && @feature_map.cooling?
            cooling = heating + deadband
            return InteractionModel::Status.invalid_command if cooling > @max_cool_setpoint_limit
            self.unoccupied_cooling_setpoint = cooling.to_i16 if @unoccupied_cooling_setpoint < cooling
          end
          self.unoccupied_heating_setpoint = heating.to_i16
        when SetpointAdjustMode::Cool
          return InteractionModel::Status.invalid_command unless @feature_map.cooling?
          cooling = (@unoccupied_cooling_setpoint.to_i32 + delta).clamp(@min_cool_setpoint_limit.to_i32, @max_cool_setpoint_limit.to_i32)
          if @feature_map.automode? && @feature_map.heating?
            heating = cooling - deadband
            return InteractionModel::Status.invalid_command if heating < @min_heat_setpoint_limit
            self.unoccupied_heating_setpoint = heating.to_i16 if @unoccupied_heating_setpoint > heating
          end
          self.unoccupied_cooling_setpoint = cooling.to_i16
        when SetpointAdjustMode::Both
          return raise_lower_unoccupied_both(delta) if @feature_map.heating? && @feature_map.cooling?
          return raise_lower_unoccupied(SetpointAdjustMode::Heat, delta) if @feature_map.heating?
          return raise_lower_unoccupied(SetpointAdjustMode::Cool, delta) if @feature_map.cooling?
          return InteractionModel::Status.invalid_command
        else
          return InteractionModel::Status.invalid_command
        end
        update_running_mode
        InteractionModel::Status.success
      end

      private def raise_lower_unoccupied_both(delta : Int32) : InteractionModel::Status
        minimum_shift = {@min_heat_setpoint_limit.to_i32 - @unoccupied_heating_setpoint,
                         @min_cool_setpoint_limit.to_i32 - @unoccupied_cooling_setpoint}.max
        maximum_shift = {@max_heat_setpoint_limit.to_i32 - @unoccupied_heating_setpoint,
                         @max_cool_setpoint_limit.to_i32 - @unoccupied_cooling_setpoint}.min
        return InteractionModel::Status.invalid_command if minimum_shift > maximum_shift
        return InteractionModel::Status.invalid_command if @feature_map.automode? &&
                                                           @unoccupied_cooling_setpoint - @unoccupied_heating_setpoint < deadband

        shift = delta.clamp(minimum_shift, maximum_shift)
        self.unoccupied_heating_setpoint = (@unoccupied_heating_setpoint + shift).to_i16
        self.unoccupied_cooling_setpoint = (@unoccupied_cooling_setpoint + shift).to_i16
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

      private def keep_unoccupied_cooling_above(heating : Int16) : InteractionModel::Status?
        return unless @feature_map.automode? && @feature_map.cooling?
        lowest_cooling = heating + deadband
        return if @unoccupied_cooling_setpoint >= lowest_cooling
        return InteractionModel::Status.constraint_error if lowest_cooling > @max_cool_setpoint_limit

        self.unoccupied_cooling_setpoint = lowest_cooling
        nil
      end

      private def keep_unoccupied_heating_below(cooling : Int16) : InteractionModel::Status?
        return unless @feature_map.automode? && @feature_map.heating?
        highest_heating = cooling - deadband
        return if @unoccupied_heating_setpoint <= highest_heating
        return InteractionModel::Status.constraint_error if highest_heating < @min_heat_setpoint_limit

        self.unoccupied_heating_setpoint = highest_heating
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

        cooling = @feature_map.occupancy? && @occupancy == 0_u8 ? @unoccupied_cooling_setpoint : @occupied_cooling_setpoint
        heating = @feature_map.occupancy? && @occupancy == 0_u8 ? @unoccupied_heating_setpoint : @occupied_heating_setpoint
        if temperature > cooling
          ThermostatRunningMode::Cool
        elsif temperature < heating
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
          @feature_map.cooling? && !@control_sequence_of_operation.in?({ControlSequenceOfOperation::HeatingOnly,
                                                                        ControlSequenceOfOperation::HeatingWithReheat})
        in .heat?, .emergency_heat?
          @feature_map.heating? && !@control_sequence_of_operation.in?({ControlSequenceOfOperation::CoolingOnly,
                                                                        ControlSequenceOfOperation::CoolingWithReheat})
        in .auto?
          @feature_map.automode?
        end
      end

      private def default_control_sequence : ControlSequenceOfOperation
        if @feature_map.heating? && @feature_map.cooling?
          ControlSequenceOfOperation::CoolingAndHeating
        elsif @feature_map.heating?
          ControlSequenceOfOperation::HeatingOnly
        else
          ControlSequenceOfOperation::CoolingOnly
        end
      end

      private def validate_control_sequence! : Nil
        if error = control_sequence_error
          raise ArgumentError.new(error)
        end
      end

      private def control_sequence_error : String?
        case @control_sequence_of_operation
        when .cooling_only?, .cooling_with_reheat?
          return "AUTO requires a combined control sequence" if @feature_map.automode?
          return "ControlSequenceOfOperation requires COOL" unless @feature_map.cooling?
        when .heating_only?, .heating_with_reheat?
          return "AUTO requires a combined control sequence" if @feature_map.automode?
          return "ControlSequenceOfOperation requires HEAT" unless @feature_map.heating?
        when .cooling_and_heating?, .cooling_and_heating_with_reheat?
          unless @feature_map.heating? && @feature_map.cooling?
            return "ControlSequenceOfOperation requires HEAT and COOL"
          end
        else
          return "Unsupported ControlSequenceOfOperation"
        end
        nil
      end

      private def validate_local_temperature(value : Int16?) : Nil
        if @feature_map.local_temperature_not_exposed? && !value.nil?
          raise ArgumentError.new("LocalTemperature must remain null when LTNE is enabled")
        end
      end

      private def validate_occupancy(value : UInt8) : Nil
        raise ArgumentError.new("Occupancy must be 0 or 1") unless value <= 1_u8
      end

      private def valid_min_heat_limit?(limit : Int16) : Bool
        limit >= @abs_min_heat_setpoint_limit && limit <= @max_heat_setpoint_limit &&
          limit <= @abs_max_heat_setpoint_limit &&
          (!@feature_map.automode? || limit <= @min_cool_setpoint_limit - deadband)
      end

      private def valid_max_heat_limit?(limit : Int16) : Bool
        limit >= @min_heat_setpoint_limit && limit >= @abs_min_heat_setpoint_limit &&
          limit <= @abs_max_heat_setpoint_limit &&
          (!@feature_map.automode? || limit <= @max_cool_setpoint_limit - deadband)
      end

      private def valid_min_cool_limit?(limit : Int16) : Bool
        limit >= @abs_min_cool_setpoint_limit && limit <= @max_cool_setpoint_limit &&
          limit <= @abs_max_cool_setpoint_limit &&
          (!@feature_map.automode? || limit >= @min_heat_setpoint_limit + deadband)
      end

      private def valid_max_cool_limit?(limit : Int16) : Bool
        limit >= @min_cool_setpoint_limit && limit >= @abs_min_cool_setpoint_limit &&
          limit <= @abs_max_cool_setpoint_limit &&
          (!@feature_map.automode? || limit >= @max_heat_setpoint_limit + deadband)
      end

      private def validate_min_heat_limit(limit : Int16) : Nil
        raise ArgumentError.new("MinHeatSetpointLimit violates the setpoint limits") unless valid_min_heat_limit?(limit)
      end

      private def validate_max_heat_limit(limit : Int16) : Nil
        raise ArgumentError.new("MaxHeatSetpointLimit violates the setpoint limits") unless valid_max_heat_limit?(limit)
      end

      private def validate_min_cool_limit(limit : Int16) : Nil
        raise ArgumentError.new("MinCoolSetpointLimit violates the setpoint limits") unless valid_min_cool_limit?(limit)
      end

      private def validate_max_cool_limit(limit : Int16) : Nil
        raise ArgumentError.new("MaxCoolSetpointLimit violates the setpoint limits") unless valid_max_cool_limit?(limit)
      end

      private def after_restore_state : Nil
        @control_sequence_of_operation = default_control_sequence if control_sequence_error
        @system_mode = SystemMode::Off unless mode_allowed?(@system_mode)
        @last_occupancy = @occupancy
        update_running_mode
        tick_suggestions(@utc_time_provider.call)
      end

      private def copy_presets(values : Array(Preset)) : Array(Preset)
        values.map do |entry|
          Preset.new(entry.preset_handle.try(&.dup), entry.preset_scenario, entry.name,
            entry.cooling_setpoint, entry.heating_setpoint, entry.built_in)
        end
      end

      private def copy_suggestion(entry : ThermostatSuggestion) : ThermostatSuggestion
        ThermostatSuggestion.new(entry.unique_id, entry.preset_handle.dup,
          entry.effective_time, entry.expiration_time)
      end

      private def copy_suggestions(values : Array(ThermostatSuggestion)) : Array(ThermostatSuggestion)
        values.map { |entry| copy_suggestion(entry) }
      end

      private def remove_orphan_suggestions : Nil
        original_size = @thermostat_suggestions.size
        @thermostat_suggestions.reject! do |entry|
          @presets.none? { |preset| preset.preset_handle == entry.preset_handle }
        end
        if @thermostat_suggestions.size != original_size
          suggestion_attribute_changed(ATTR_THERMOSTAT_SUGGESTIONS)
          if now = @last_suggestion_now
            tick_suggestions(now)
          elsif current = @current_thermostat_suggestion
            @current_thermostat_suggestion = nil unless @thermostat_suggestions.any? { |entry| entry.unique_id == current.unique_id }
          end
        end
      end

      private def copy_schedules(values : Array(Schedule)) : Array(Schedule)
        values.map do |entry|
          transitions = entry.transitions.map do |transition|
            ScheduleTransition.new(transition.day_of_week, transition.transition_time,
              transition.preset_handle.try(&.dup), transition.system_mode,
              transition.cooling_setpoint, transition.heating_setpoint)
          end
          Schedule.new(entry.schedule_handle.try(&.dup), entry.system_mode,
            entry.name, entry.preset_handle.try(&.dup), transitions, entry.built_in)
        end
      end

      private def remember_schedule_handles(values : Array(Schedule)) : Nil
        values.each do |entry|
          handle = entry.schedule_handle || next
          @used_schedule_handles << handle.dup unless @used_schedule_handles.any? { |used| used == handle }
        end
      end

      private def validate_schedules!(types : Array(ScheduleType), values : Array(Schedule),
                                      max_transitions : UInt8, max_per_day : UInt8?,
                                      presets : Array(Preset) = @presets) : Nil
        raise ArgumentError.new("schedule types must contain 1 to 3 modes") unless (1..MAX_SCHEDULE_TYPES).includes?(types.size)
        raise ArgumentError.new("duplicate schedule mode") unless types.map(&.system_mode).uniq!.size == types.size
        raise ArgumentError.new("schedule transition capacity must be positive") if max_transitions == 0_u8
        if max_per_day && !(1_u8..254_u8).includes?(max_per_day)
          raise ArgumentError.new("per-day transition capacity must be within 1..254")
        end
        types.each do |type|
          raise ArgumentError.new("unsupported schedule mode") unless schedule_mode_allowed?(type.system_mode)
          features = type.schedule_type_features
          unless features.supports_presets? || features.supports_setpoints?
            raise ArgumentError.new("schedule type needs presets or setpoints")
          end
          if features.supports_presets? && !@feature_map.presets?
            raise ArgumentError.new("schedule presets require PRES")
          end
        end
        capacity = types.sum(&.number_of_schedules.to_i)
        raise ArgumentError.new("schedule capacity must be within 1..255") unless (1..255).includes?(capacity)
        raise ArgumentError.new("too many schedules") if values.size > capacity

        handles = [] of Bytes
        values.each do |entry|
          handle = entry.schedule_handle || raise ArgumentError.new("configured schedule needs a handle")
          raise ArgumentError.new("schedule handle length is invalid") unless (0..MAX_SCHEDULE_HANDLE_LENGTH).includes?(handle.size)
          raise ArgumentError.new("duplicate schedule handle") if handles.any? { |used| used == handle }
          handles << handle
          type = types.find { |candidate| candidate.system_mode == entry.system_mode } ||
                 raise ArgumentError.new("unsupported schedule mode")
          if values.count { |candidate| candidate.system_mode == entry.system_mode } > type.number_of_schedules
            raise ArgumentError.new("schedule mode capacity exceeded")
          end
          raise ArgumentError.new("configured schedule needs BuiltIn") if entry.built_in.nil?
          if name = entry.name
            raise ArgumentError.new("schedule name too long") if name.bytesize > MAX_SCHEDULE_NAME_LENGTH
            raise ArgumentError.new("schedule mode does not support names") unless type.schedule_type_features.supports_names?
          end
          validate_schedule_preset!(entry.preset_handle, type, presets)
          raise ArgumentError.new("schedule needs transitions") if entry.transitions.empty?
          raise ArgumentError.new("schedule transition capacity exceeded") if entry.transitions.size > max_transitions

          day_counts = Array(Int32).new(7, 0)
          transitions = entry.transitions
          transitions.each_with_index do |transition, index|
            day = transition.day_of_week
            raise ArgumentError.new("invalid schedule day bitmap") if day == 0_u8 || day.bit(7) == 1
            raise ArgumentError.new("invalid transition time") if transition.transition_time > 1439_u16
            if transitions[0...index].any? do |prior|
                 prior.transition_time == transition.transition_time && (prior.day_of_week & day) != 0_u8
               end
              raise ArgumentError.new("overlapping schedule transitions")
            end
            7.times do |bit|
              next if (day & (1_u8 << bit)) == 0_u8
              day_counts[bit] += 1
              if limit = max_per_day
                raise ArgumentError.new("per-day transition capacity exceeded") if day_counts[bit] > limit
              end
            end
            validate_schedule_transition!(transition, entry, type, presets)
          end
        end
      end

      private def schedule_mode_allowed?(mode : SystemMode) : Bool
        case mode
        when SystemMode::Heat then @feature_map.heating?
        when SystemMode::Cool then @feature_map.cooling?
        when SystemMode::Auto then @feature_map.automode? && @feature_map.heating? && @feature_map.cooling?
        else                       false
        end
      end

      private def validate_schedule_preset!(handle : Bytes?, type : ScheduleType,
                                            presets : Array(Preset)) : Nil
        return unless handle
        raise ArgumentError.new("schedule mode does not support presets") unless type.schedule_type_features.supports_presets?
        raise ArgumentError.new("schedule preset handle length is invalid") if handle.size > MAX_PRESET_HANDLE_LENGTH
        raise ArgumentError.new("unknown schedule preset") unless presets.any? { |preset| preset.preset_handle == handle }
      end

      private def validate_schedule_transition!(transition : ScheduleTransition, schedule : Schedule,
                                                type : ScheduleType, presets : Array(Preset)) : Nil
        features = type.schedule_type_features
        validate_schedule_preset!(transition.preset_handle, type, presets)
        if transition.preset_handle
          if transition.system_mode || transition.cooling_setpoint || transition.heating_setpoint
            raise ArgumentError.new("preset transition cannot override mode or setpoints")
          end
          return
        end
        if mode = transition.system_mode
          raise ArgumentError.new("schedule transition mode must differ") if mode == schedule.system_mode
          unless mode.off? || schedule_mode_allowed?(mode)
            raise ArgumentError.new("unsupported transition mode")
          end
          raise ArgumentError.new("schedule mode does not support setpoint transitions") unless features.supports_setpoints?
          raise ArgumentError.new("schedule mode does not support Off") if mode.off? && !features.supports_off?
        end
        if (transition.cooling_setpoint || transition.heating_setpoint) && !features.supports_setpoints?
          raise ArgumentError.new("schedule mode does not support setpoints")
        end
        if cooling = transition.cooling_setpoint
          unless @feature_map.cooling? && cooling.in?(@min_cool_setpoint_limit..@max_cool_setpoint_limit)
            raise ArgumentError.new("invalid schedule cooling setpoint")
          end
        end
        if heating = transition.heating_setpoint
          unless @feature_map.heating? && heating.in?(@min_heat_setpoint_limit..@max_heat_setpoint_limit)
            raise ArgumentError.new("invalid schedule heating setpoint")
          end
        end
        if cooling = transition.cooling_setpoint
          if heating = transition.heating_setpoint
            raise ArgumentError.new("schedule deadband violated") if cooling - heating < deadband
          end
        end
        return if schedule.preset_handle
        if (schedule.system_mode.in?({SystemMode::Heat, SystemMode::Auto}) ||
           transition.system_mode.try(&.in?({SystemMode::Heat, SystemMode::Auto}))) && !transition.heating_setpoint
          raise ArgumentError.new("schedule transition needs heating setpoint")
        end
        if (schedule.system_mode.in?({SystemMode::Cool, SystemMode::Auto}) ||
           transition.system_mode.try(&.in?({SystemMode::Cool, SystemMode::Auto}))) && !transition.cooling_setpoint
          raise ArgumentError.new("schedule transition needs cooling setpoint")
        end
      end

      private def update_active_preset_handle(handle : Bytes?) : Nil
        return if @active_preset_handle == handle

        previous = @active_preset_handle.try(&.dup)
        @active_preset_handle = handle.try(&.dup)
        if @feature_map.presets? && preset_wire_ready?
          increment_version_and_notify(ATTR_ACTIVE_PRESET_HANDLE)
          if @feature_map.events?
            emit_active_preset_change(ActivePresetChangeEvent.new(previous, @active_preset_handle.try(&.dup)))
          end
        end
      end

      private def update_active_schedule_handle(handle : Bytes?) : Nil
        return if @active_schedule_handle == handle

        previous = @active_schedule_handle.try(&.dup)
        @active_schedule_handle = handle.try(&.dup)
        @last_schedule_occurrence = nil
        if @feature_map.matter_schedules? && schedule_wire_ready?
          increment_version_and_notify(ATTR_ACTIVE_SCHEDULE_HANDLE)
          if @feature_map.events?
            emit_active_schedule_change(ActiveScheduleChangeEvent.new(previous, @active_schedule_handle.try(&.dup)))
          end
        end
      end

      # Compare civil dates rather than elapsed UTC seconds. That keeps the
      # weekly bitmap stable across timezone offsets and DST changes.
      private def schedule_transition_at(schedule : Schedule, local_time : Time) : Tuple(Int64, ScheduleTransition)?
        midnight = Time.utc(local_time.year, local_time.month, local_time.day)
        minute = local_time.hour * MINUTES_PER_HOUR + local_time.minute
        (0..MAX_WEEKLY_LOOKBACK_DAYS).each do |age|
          date = midnight - age.days
          day_bit = (1_u8 << (date.day_of_week.value % 7)).to_u8
          latest = nil.as(ScheduleTransition?)
          schedule.transitions.each do |transition|
            next if (transition.day_of_week & day_bit) == 0_u8
            next if age == 0 && transition.transition_time > minute
            latest = transition if latest.nil? || transition.transition_time > latest.transition_time
          end
          return {date.to_unix, latest} if latest
        end
        nil
      end

      private def apply_schedule_transition(schedule : Schedule, transition : ScheduleTransition) : Bool
        mode = transition.system_mode || schedule.system_mode
        preset_handle = if handle = transition.preset_handle
                          handle
                        elsif transition.cooling_setpoint || transition.heating_setpoint
                          nil
                        else
                          schedule.preset_handle
                        end
        preset = @presets.find { |entry| entry.preset_handle == preset_handle } if preset_handle
        return false if preset_handle && !preset
        cooling = transition.cooling_setpoint || preset.try(&.cooling_setpoint)
        heating = transition.heating_setpoint || preset.try(&.heating_setpoint)
        occupied = !@feature_map.occupancy? || @occupancy == 1_u8
        targets = planned_scheduled_setpoints(cooling, heating, occupied) || return false
        target_cooling, target_heating, corrected = targets
        active_preset = corrected ? nil : preset_handle

        @applying_preset = true
        begin
          apply_scheduled_setpoints(target_cooling, target_heating, occupied: occupied)
          self.system_mode = mode
          update_active_preset_handle(active_preset)
        ensure
          @applying_preset = false
        end
        true
      end

      private def planned_scheduled_setpoints(cooling : Int16?, heating : Int16?, occupied : Bool) : Tuple(Int16, Int16, Bool)?
        current_cooling = occupied ? @occupied_cooling_setpoint : @unoccupied_cooling_setpoint
        current_heating = occupied ? @occupied_heating_setpoint : @unoccupied_heating_setpoint
        target_cooling = cooling || current_cooling
        target_heating = heating || current_heating
        corrected = false
        if @feature_map.automode? && @feature_map.heating? && @feature_map.cooling? &&
           target_cooling.to_i32 - target_heating.to_i32 < deadband
          if heating && !cooling
            value = target_heating.to_i32 + deadband
            return unless value.in?(@min_cool_setpoint_limit..@max_cool_setpoint_limit)
            target_cooling = value.to_i16
          elsif cooling && !heating
            value = target_cooling.to_i32 - deadband
            return unless value.in?(@min_heat_setpoint_limit..@max_heat_setpoint_limit)
            target_heating = value.to_i16
          else
            return
          end
          corrected = true
        end
        {target_cooling, target_heating, corrected}
      end

      private def apply_scheduled_setpoints(cooling : Int16?, heating : Int16?, *, occupied : Bool) : Nil
        current_cooling = occupied ? @occupied_cooling_setpoint : @unoccupied_cooling_setpoint
        # Lower the heat target first when cooling falls; otherwise raise the
        # cool target first. Either order preserves the Auto deadband.
        if cooling && heating && cooling < current_cooling
          apply_scheduled_heating(heating, occupied)
          apply_scheduled_cooling(cooling, occupied)
        else
          apply_scheduled_cooling(cooling, occupied) if cooling
          apply_scheduled_heating(heating, occupied) if heating
        end
      end

      private def apply_scheduled_cooling(value : Int16, occupied : Bool) : Nil
        occupied ? self.occupied_cooling_setpoint = value : self.unoccupied_cooling_setpoint = value
      end

      private def apply_scheduled_heating(value : Int16, occupied : Bool) : Nil
        occupied ? self.occupied_heating_setpoint = value : self.unoccupied_heating_setpoint = value
      end

      private def validate_presets!(types : Array(PresetType), values : Array(Preset)) : Nil
        raise ArgumentError.new("preset types must contain 1 to 7 scenarios") unless (1..MAX_PRESET_TYPES).includes?(types.size)
        raise ArgumentError.new("duplicate preset scenario") unless types.map(&.preset_scenario).uniq!.size == types.size
        raise ArgumentError.new("automatic preset transitions are not supported") if types.any?(&.preset_type_features.automatic?)
        capacity = types.sum(&.number_of_presets.to_i)
        raise ArgumentError.new("preset capacity must be within 1..255") unless (1..255).includes?(capacity)
        raise ArgumentError.new("too many presets") if values.size > capacity

        handles = [] of Bytes
        names = Set(Tuple(PresetScenario, String)).new
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
            raise ArgumentError.new("duplicate preset name") unless names.add?({entry.preset_scenario, name})
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
        unless @preset_types.empty?
          document[PRESET_STATE_KEY] = PresetState.new(copy_presets(@presets),
            @active_preset_handle.try(&.dup), @used_preset_handles.map(&.dup)).to_document
        end
        unless @schedule_types.empty?
          document[SCHEDULE_STATE_KEY] = ScheduleState.new(copy_schedules(@schedules),
            @used_schedule_handles.map(&.dup), @active_schedule_handle.try(&.dup)).to_document
        end
        if !@thermostat_suggestions.empty? || @next_suggestion_id != 0_u8 ||
           @max_thermostat_suggestions != MIN_SUGGESTION_CAPACITY
          document[SUGGESTION_STATE_KEY] = SuggestionState.new(copy_suggestions(@thermostat_suggestions),
            @next_suggestion_id, @max_thermostat_suggestions).to_document
        end
      end

      private def restore_persisted_extension(document : Storage::Document) : Nil
        @pending_preset_write = nil
        @pending_schedule_write = nil
        @combined_atomic_write = false
        @suggestion_timer_generation &+= 1_u64
        @suggestion_timer_boundary = nil
        raw = document[PRESET_STATE_KEY]?
        if raw
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
          state.used_preset_handles.each do |used_handle|
            raise StorageError.new("invalid used preset handle") unless (0..MAX_PRESET_HANDLE_LENGTH).includes?(used_handle.size)
            @used_preset_handles << used_handle.dup unless @used_preset_handles.any? { |used| used == used_handle }
          end
          remember_preset_handles(state.presets)
          @presets = copy_presets(state.presets)
          @last_schedule_occurrence = nil
          @active_preset_handle = state.active_preset_handle.try(&.dup)
          @pending_preset_write = nil
        end
        if schedule_raw = document[SCHEDULE_STATE_KEY]?
          state = ScheduleState.from_document(schedule_raw.as?(Storage::Document) ||
                                              raise StorageError.new("invalid thermostat schedule state"))
          begin
            validate_schedules!(@schedule_types, state.schedules,
              @number_of_schedule_transitions, @number_of_schedule_transition_per_day)
          rescue ex : ArgumentError
            raise StorageError.new("invalid thermostat schedule state: #{ex.message}")
          end
          if handle = state.active_schedule_handle
            raise StorageError.new("unknown active schedule handle") unless state.schedules.any? { |entry| entry.schedule_handle == handle }
          end
          state.used_schedule_handles.each do |used_handle|
            raise StorageError.new("invalid used schedule handle") unless (0..MAX_SCHEDULE_HANDLE_LENGTH).includes?(used_handle.size)
            @used_schedule_handles << used_handle.dup unless @used_schedule_handles.any? { |used| used == used_handle }
          end
          remember_schedule_handles(state.schedules)
          @schedules = copy_schedules(state.schedules)
          @last_schedule_occurrence = nil
          @active_schedule_handle = state.active_schedule_handle.try(&.dup)
          @pending_schedule_write = nil
        end
        if suggestion_raw = document[SUGGESTION_STATE_KEY]?
          state = SuggestionState.from_document(suggestion_raw.as?(Storage::Document) ||
                                                raise StorageError.new("invalid thermostat suggestion state"))
          raise StorageError.new("invalid thermostat suggestion capacity") if state.capacity < MIN_SUGGESTION_CAPACITY
          raise StorageError.new("too many thermostat suggestions") if state.suggestions.size > state.capacity
          ids = state.suggestions.map(&.unique_id)
          raise StorageError.new("duplicate thermostat suggestion ID") if ids.uniq.size != ids.size
          state.suggestions.each do |entry|
            unless entry.preset_handle.size <= MAX_PRESET_HANDLE_LENGTH && entry.expiration_time > entry.effective_time
              raise StorageError.new("invalid thermostat suggestion")
            end
          end
          @thermostat_suggestions = copy_suggestions(state.suggestions)
          @max_thermostat_suggestions = state.capacity
          @next_suggestion_id = state.next_id
          @current_thermostat_suggestion = nil
          @last_suggestion_now = nil
          remove_orphan_suggestions
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

      # A limit write first validates the prospective limit relationship. Once
      # accepted, clamp only the setpoints that now fall outside that limit;
      # this is the minimum adjustment required by Thermostat §4.3.11.15–18.
      private def min_heat_limit_changed(limit : Int16) : Nil
        self.occupied_heating_setpoint = limit if @occupied_heating_setpoint < limit
        if @feature_map.occupancy? && @unoccupied_heating_setpoint < limit
          self.unoccupied_heating_setpoint = limit
        end
      end

      private def max_heat_limit_changed(limit : Int16) : Nil
        self.occupied_heating_setpoint = limit if @occupied_heating_setpoint > limit
        if @feature_map.occupancy? && @unoccupied_heating_setpoint > limit
          self.unoccupied_heating_setpoint = limit
        end
      end

      private def min_cool_limit_changed(limit : Int16) : Nil
        self.occupied_cooling_setpoint = limit if @occupied_cooling_setpoint < limit
        if @feature_map.occupancy? && @unoccupied_cooling_setpoint < limit
          self.unoccupied_cooling_setpoint = limit
        end
      end

      private def max_cool_limit_changed(limit : Int16) : Nil
        self.occupied_cooling_setpoint = limit if @occupied_cooling_setpoint > limit
        if @feature_map.occupancy? && @unoccupied_cooling_setpoint > limit
          self.unoccupied_cooling_setpoint = limit
        end
      end

      private def cooling_setpoint_changed(value : Int16) : Nil
        update_active_preset_handle(nil) unless @applying_preset || (@feature_map.occupancy? && @occupancy == 0_u8)
        emit_setpoint_change(SetpointChangeEvent.new(SystemMode::Cool, value,
          @feature_map.occupancy? ? 1_u8 : nil)) if @feature_map.events?
        update_running_mode
      end

      private def heating_setpoint_changed(value : Int16) : Nil
        update_active_preset_handle(nil) unless @applying_preset || (@feature_map.occupancy? && @occupancy == 0_u8)
        emit_setpoint_change(SetpointChangeEvent.new(SystemMode::Heat, value,
          @feature_map.occupancy? ? 1_u8 : nil)) if @feature_map.events?
        update_running_mode
      end

      private def unoccupied_cooling_setpoint_changed(value : Int16) : Nil
        update_active_preset_handle(nil) unless @applying_preset || @occupancy == 1_u8
        emit_setpoint_change(SetpointChangeEvent.new(SystemMode::Cool, value, 0_u8)) if @feature_map.events? && @feature_map.occupancy?
        update_running_mode if @occupancy == 0_u8
      end

      private def unoccupied_heating_setpoint_changed(value : Int16) : Nil
        update_active_preset_handle(nil) unless @applying_preset || @occupancy == 1_u8
        emit_setpoint_change(SetpointChangeEvent.new(SystemMode::Heat, value, 0_u8)) if @feature_map.events? && @feature_map.occupancy?
        update_running_mode if @occupancy == 0_u8
      end

      private def occupancy_changed(value : UInt8) : Nil
        previous = @last_occupancy
        @last_occupancy = value
        emit_occupancy_change(OccupancyChangeEvent.new(previous, value)) if @feature_map.events? && @feature_map.occupancy?
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
