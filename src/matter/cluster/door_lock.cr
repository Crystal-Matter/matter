require "time"
require "../crypto/key"
require "./cluster"
require "./door_lock/types"

module Matter
  module Cluster
    # Door Lock Cluster (0x0101)
    #
    # Provides remote lock/unlock control plus user/credential management for a lock.
    # This implementation focuses on robust server-side behavior for the most commonly
    # used Door Lock attributes and commands, including feature-gated command support.
    class DoorLock < Base
      Log = ::Log.for("matter.cluster.door_lock")

      cluster 0x0101, revision: 9

      feature :pin_credential, bit: 0
      feature :rfid_credential, bit: 1
      feature :finger_credentials, bit: 2
      feature :week_day_access_schedules, bit: 4
      feature :door_position_sensor, bit: 5
      feature :face_credentials, bit: 6
      feature :credential_over_the_air_access, bit: 7
      feature :user, bit: 8
      feature :year_day_access_schedules, bit: 10
      feature :holiday_schedules, bit: 11
      feature :unbolting, bit: 12
      feature :aliro_provisioning, bit: 13
      feature :aliro_bleuwb, bit: 14

      enum LedSettings : UInt8
        NoLedSignal = 0
        LedSignal1  = 1
        LedSignal2  = 2
      end

      enum SoundVolume : UInt8
        Silent = 0
        Low    = 1
        High   = 2
        Medium = 3
      end

      # OperatingModesBitmap uses set bits for unsupported modes; bits 5–15
      # are reserved and must remain set.
      SUPPORTED_OPERATING_MODES_RESERVED   = 0xFFE0_u16
      UNSUPPORTED_OPTIONAL_OPERATING_MODES = (1_u16 << OperatingMode::Vacation.value) |
                                             (1_u16 << OperatingMode::Privacy.value) |
                                             (1_u16 << OperatingMode::Passage.value)
      DEFAULT_SUPPORTED_OPERATING_MODES = SUPPORTED_OPERATING_MODES_RESERVED | UNSUPPORTED_OPTIONAL_OPERATING_MODES
      NORMAL_OPERATING_MODE_BIT         = 1_u16 << OperatingMode::Normal.value
      NO_REMOTE_OPERATING_MODE_BIT      = 1_u16 << OperatingMode::NoRemoteLockUnlock.value

      # Wildcard indexes clearing every user / schedule / credential
      ALL_USERS     = 0xFFFE_u16
      ALL_SCHEDULES =    0xFE_u8

      # The programming PIN occupies credential index zero
      PROGRAMMING_PIN_INDEX = 0_u16

      # Lowest accepted values of the credential policy attributes
      MIN_WRONG_CODE_ENTRY_LIMIT =     1_u8
      MIN_TEMPORARY_DISABLE_TIME =     1_u8
      MIN_EXPIRING_USER_TIMEOUT  =    1_u16
      MAX_EXPIRING_USER_TIMEOUT  = 2880_u16

      # Every bit of LocalProgrammingFeatures set
      ALL_LOCAL_PROGRAMMING_FEATURES = 0x0F_u8

      # CredentialRulesSupport with the Single rule
      CREDENTIAL_RULE_SINGLE = 0x01_u8

      # Capacity defaults
      DEFAULT_USERS_SUPPORTED           = 50_u16
      DEFAULT_SCHEDULES_SUPPORTED       =   5_u8
      DEFAULT_CREDENTIALS_PER_USER      =   5_u8
      DEFAULT_MAX_PIN_CODE_LENGTH       =   8_u8
      DEFAULT_MIN_PIN_CODE_LENGTH       =   4_u8
      DEFAULT_MAX_RFID_CODE_LENGTH      =  20_u8
      DEFAULT_MIN_RFID_CODE_LENGTH      =   4_u8
      DEFAULT_WRONG_CODE_ENTRY_LIMIT    =   3_u8
      DEFAULT_TEMPORARY_DISABLE_SECONDS =  30_u8
      DEFAULT_EXPIRING_USER_TIMEOUT     = 10_u16
      DEFAULT_LANGUAGE                  = "en"
      DEFAULT_PIN_CODE                  = "1234"
      LAST_HOUR_OF_DAY                  = 23_u8
      LAST_MINUTE_OF_HOUR               = 59_u8
      MINUTES_PER_HOUR                  =    60
      LAST_MINUTE_OF_DAY                = LAST_HOUR_OF_DAY.to_i32 * MINUTES_PER_HOUR + LAST_MINUTE_OF_HOUR.to_i32
      WEEK_DAY_MASK                     = 0x7F_u8
      ALIRO_SIGNING_KEY_LENGTH          =      32
      ALIRO_PUBLIC_KEY_LENGTH           =      65
      ALIRO_GROUP_IDENTIFIER_LENGTH     =      16
      ALIRO_UNCOMPRESSED_POINT_PREFIX   = 0x04_u8

      private enum PinAuthorization
        Allowed
        Invalid
        Restricted
      end

      private record PinMatch, result : PinAuthorization, user_index : UInt16? = nil,
        credential : Credential? = nil, error : OperationError? = nil

      private record Authorization, status : InteractionModel::Status? = nil,
        user_index : UInt16? = nil, credential : Credential? = nil

      private record LocalScheduleTime, epoch_seconds : Int64, day_mask : UInt8, minute_of_day : Int32

      attribute 0x0000, :lock_state, LockState, nullable: true, default: LockState::Locked
      attribute 0x0001, :lock_type, LockType, default: LockType::Deadbolt
      attribute 0x0002, :actuator_enabled, Bool, default: true
      attribute 0x0003, :door_state, DoorState, nullable: true, default: DoorState::DoorClosed, optional: true, requires: :door_position_sensor
      attribute 0x0004, :door_open_events, UInt32, default: 0_u32, writable: true, write_access: :manage, optional: true, requires: :door_position_sensor
      attribute 0x0005, :door_closed_events, UInt32, default: 0_u32, writable: true, write_access: :manage, optional: true, requires: :door_position_sensor
      attribute 0x0006, :open_period, UInt16, default: 0_u16, writable: true, write_access: :manage, optional: true, requires: :door_position_sensor
      attribute 0x0011, :number_of_total_users_supported, UInt16, default: DEFAULT_USERS_SUPPORTED, fixed: true, requires: :user
      attribute 0x0012, :number_of_pin_users_supported, UInt16, default: DEFAULT_USERS_SUPPORTED, fixed: true, requires: :pin_credential
      attribute 0x0013, :number_of_rfid_users_supported, UInt16, default: DEFAULT_USERS_SUPPORTED, fixed: true, requires: :rfid_credential
      attribute 0x0014, :number_of_week_day_schedules_supported_per_user, UInt8, default: DEFAULT_SCHEDULES_SUPPORTED, fixed: true, requires: :week_day_access_schedules
      attribute 0x0015, :number_of_year_day_schedules_supported_per_user, UInt8, default: DEFAULT_SCHEDULES_SUPPORTED, fixed: true, requires: :year_day_access_schedules
      attribute 0x0016, :number_of_holiday_schedules_supported, UInt8, default: DEFAULT_SCHEDULES_SUPPORTED, fixed: true, requires: :holiday_schedules
      attribute 0x0017, :max_pin_code_length, UInt8, default: DEFAULT_MAX_PIN_CODE_LENGTH, fixed: true, requires: :pin_credential
      attribute 0x0018, :min_pin_code_length, UInt8, default: DEFAULT_MIN_PIN_CODE_LENGTH, fixed: true, requires: :pin_credential
      attribute 0x0019, :max_rfid_code_length, UInt8, default: DEFAULT_MAX_RFID_CODE_LENGTH, fixed: true, requires: :rfid_credential
      attribute 0x001A, :min_rfid_code_length, UInt8, default: DEFAULT_MIN_RFID_CODE_LENGTH, fixed: true, requires: :rfid_credential
      attribute 0x001B, :credential_rules_support, UInt8, default: CREDENTIAL_RULE_SINGLE, fixed: true, requires: :user
      attribute 0x001C, :number_of_credentials_supported_per_user, UInt8, default: DEFAULT_CREDENTIALS_PER_USER, fixed: true, requires: :user
      attribute 0x0021, :language, String, default: DEFAULT_LANGUAGE, writable: true, write_access: :manage, optional: true
      attribute 0x0022, :led_settings, LedSettings, default: LedSettings::NoLedSignal, writable: true, write_access: :manage, optional: true
      attribute 0x0023, :auto_relock_time, UInt32, default: 0_u32, writable: true, write_access: :manage, optional: true
      attribute 0x0024, :sound_volume, SoundVolume, default: SoundVolume::Medium, writable: true, write_access: :manage, optional: true
      attribute 0x0025, :operating_mode, OperatingMode, default: OperatingMode::Normal, writable: true, write_access: :manage
      before_write :operating_mode do |mode|
        InteractionModel::Status.constraint_error unless operating_mode_supported?(mode)
      end
      attribute 0x0026, :supported_operating_modes, UInt16, default: DEFAULT_SUPPORTED_OPERATING_MODES, fixed: true
      attribute 0x0027, :default_configuration_register, UInt16, default: 0_u16, optional: true
      attribute 0x0028, :enable_local_programming, Bool, default: true, writable: true, write_access: :administer, optional: true
      attribute 0x0029, :enable_one_touch_locking, Bool, default: false, writable: true, write_access: :manage, optional: true
      attribute 0x002A, :enable_inside_status_led, Bool, default: false, writable: true, write_access: :manage, optional: true
      attribute 0x002B, :enable_privacy_mode_button, Bool, default: false, writable: true, write_access: :manage, optional: true
      attribute 0x002C, :local_programming_features, UInt8, default: 0_u8, writable: true, write_access: :administer, max: ALL_LOCAL_PROGRAMMING_FEATURES, optional: true
      attribute 0x0030, :wrong_code_entry_limit, UInt8, default: DEFAULT_WRONG_CODE_ENTRY_LIMIT, writable: true, write_access: :administer, min: MIN_WRONG_CODE_ENTRY_LIMIT, requires: [:pin_credential, :rfid_credential]
      attribute 0x0031, :user_code_temporary_disable_time, UInt8, default: DEFAULT_TEMPORARY_DISABLE_SECONDS, writable: true, write_access: :administer, min: MIN_TEMPORARY_DISABLE_TIME, requires: [:pin_credential, :rfid_credential]
      attribute 0x0032, :send_pin_over_the_air, Bool, default: false, writable: true, write_access: :administer, optional: true, requires: {pin_credential: true, user: false}
      attribute 0x0033, :require_pin_for_remote_operation, Bool, default: false, writable: true, write_access: :administer, requires: {pin_credential: true, credential_over_the_air_access: true}
      attribute 0x0035, :expiring_user_timeout, UInt16, default: DEFAULT_EXPIRING_USER_TIMEOUT, writable: true, write_access: :administer, min: MIN_EXPIRING_USER_TIMEOUT, max: MAX_EXPIRING_USER_TIMEOUT, optional: true, requires: :user
      attribute 0x0080, :aliro_reader_verification_key, Bytes, nullable: true, computed: true, read_access: :administer, requires: :aliro_provisioning
      attribute 0x0081, :aliro_reader_group_identifier, Bytes, nullable: true, computed: true, read_access: :administer, requires: :aliro_provisioning
      attribute 0x0082, :aliro_reader_group_sub_identifier, Bytes, computed: true, fixed: true, read_access: :administer, requires: :aliro_provisioning
      attribute 0x0083, :aliro_expedited_transaction_supported_protocol_versions, Array(Bytes), computed: true, fixed: true, read_access: :administer, requires: :aliro_provisioning
      attribute 0x0087, :number_of_aliro_credential_issuer_keys_supported, UInt16, default: 0_u16, fixed: true, requires: :aliro_provisioning
      attribute 0x0088, :number_of_aliro_endpoint_keys_supported, UInt16, default: 0_u16, fixed: true, requires: :aliro_provisioning

      command 0x00, :lock_door, request: LockDoorRequest, timed: true
      command 0x01, :unlock_door, request: UnlockDoorRequest, timed: true
      command 0x03, :unlock_with_timeout, request: UnlockWithTimeoutRequest, timed: true, optional: true
      command 0x0B, :set_week_day_schedule, request: SetWeekDayScheduleRequest, access: :administer, requires: :week_day_access_schedules, handler: :handle_set_week_day_schedule
      command 0x0C, :get_week_day_schedule, request: GetWeekDayScheduleRequest, response: GetWeekDayScheduleResponse, access: :administer, requires: :week_day_access_schedules
      command 0x0D, :clear_week_day_schedule, request: ClearWeekDayScheduleRequest, access: :administer, requires: :week_day_access_schedules
      command 0x0E, :set_year_day_schedule, request: SetYearDayScheduleRequest, access: :administer, requires: :year_day_access_schedules, handler: :handle_set_year_day_schedule
      command 0x0F, :get_year_day_schedule, request: GetYearDayScheduleRequest, response: GetYearDayScheduleResponse, access: :administer, requires: :year_day_access_schedules
      command 0x10, :clear_year_day_schedule, request: ClearYearDayScheduleRequest, access: :administer, requires: :year_day_access_schedules
      command 0x11, :set_holiday_schedule, request: SetHolidayScheduleRequest, access: :administer, requires: :holiday_schedules, handler: :handle_set_holiday_schedule
      command 0x12, :get_holiday_schedule, request: GetHolidayScheduleRequest, response: GetHolidayScheduleResponse, access: :administer, requires: :holiday_schedules
      command 0x13, :clear_holiday_schedule, request: ClearHolidayScheduleRequest, access: :administer, requires: :holiday_schedules
      command 0x1A, :set_user, request: SetUserRequest, access: :administer, timed: true, requires: :user, handler: :handle_set_user
      command 0x1B, :get_user, request: GetUserRequest, response: GetUserResponse, response_id: 0x1C, access: :administer, requires: :user
      command 0x1D, :clear_user, request: ClearUserRequest, access: :administer, timed: true, requires: :user
      command 0x22, :set_credential, request: SetCredentialRequest, response: SetCredentialResponse, response_id: 0x23, access: :administer, timed: true, requires: :user, handler: :handle_set_credential
      command 0x24, :get_credential_status, request: GetCredentialStatusRequest, response: GetCredentialStatusResponse, response_id: 0x25, access: :administer, requires: :user, handler: :handle_get_credential_status
      command 0x26, :clear_credential, request: ClearCredentialRequest, access: :administer, timed: true, requires: :user
      command 0x27, :unbolt_door, request: UnboltDoorRequest, timed: true, requires: :unbolting
      command 0x28, :set_aliro_reader_config, request: SetAliroReaderConfigRequest, access: :administer, timed: true, requires: :aliro_provisioning, handler: :handle_set_aliro_reader_config
      command 0x29, :clear_aliro_reader_config, access: :administer, timed: true, requires: :aliro_provisioning, handler: :handle_clear_aliro_reader_config

      event 0x00, :door_lock_alarm, priority: :critical, payload: Events::DoorLockAlarm
      event 0x01, :door_state_change, priority: :critical, requires: :door_position_sensor, payload: Events::DoorStateChange
      event 0x02, :lock_operation, priority: :critical, payload: Events::LockOperation
      event 0x03, :lock_operation_error, priority: :critical, payload: Events::LockOperationError
      event 0x04, :lock_user_change, priority: :info, requires: :user, payload: Events::LockUserChange

      struct UserRecord
        include Storage::Record

        property user_index : UInt16
        property user_name : String
        property user_unique_id : UInt32
        property user_status : UserStatus
        property user_type : UserType
        property credential_rule : CredentialRule
        property credentials : Array(Credential)
        property creator_fabric_index : UInt8?
        property last_modified_fabric_index : UInt8?
        property expiring_user_expires_at : Time?

        def initialize(
          @user_index : UInt16,
          @user_name : String,
          @user_unique_id : UInt32,
          @user_status : UserStatus,
          @user_type : UserType,
          @credential_rule : CredentialRule,
          @credentials : Array(Credential) = [] of Credential,
          @creator_fabric_index : UInt8? = nil,
          @last_modified_fabric_index : UInt8? = nil,
          @expiring_user_expires_at : Time? = nil,
        )
        end
      end

      struct CredentialRecord
        include Storage::Record

        property credential : Credential
        property credential_data : Bytes
        property user_index : UInt16?
        property creator_fabric_index : UInt8?
        property last_modified_fabric_index : UInt8?

        def initialize(
          @credential : Credential,
          @credential_data : Bytes,
          @user_index : UInt16? = nil,
          @creator_fabric_index : UInt8? = nil,
          @last_modified_fabric_index : UInt8? = nil,
        )
        end
      end

      # Internal reader material. The signing key is secret and is never
      # exposed as a Matter attribute until the Aliro feature is implemented.
      struct AliroReaderConfig
        include Storage::Record

        getter signing_key : Bytes
        getter verification_key : Bytes
        getter group_identifier : Bytes
        getter group_resolving_key : Bytes?

        def initialize(signing_key : Bytes, verification_key : Bytes, group_identifier : Bytes, group_resolving_key : Bytes? = nil)
          @signing_key = signing_key.dup
          @verification_key = verification_key.dup
          @group_identifier = group_identifier.dup
          @group_resolving_key = group_resolving_key.try(&.dup)
        end
      end

      # Returned only by a trusted reader after it has validated the Aliro
      # transcript, freshness, Access Credential and requested `matter1` data.
      # An issuer identity may result in a new evictable endpoint credential.
      struct AliroAuthenticatedAccess
        getter credential_public_key : Bytes
        getter issuer_public_key : Bytes?
        getter new_endpoint_public_key : Bytes?

        def initialize(credential_public_key : Bytes, issuer_public_key : Bytes? = nil, new_endpoint_public_key : Bytes? = nil)
          @credential_public_key = credential_public_key.dup
          @issuer_public_key = issuer_public_key.try(&.dup)
          @new_endpoint_public_key = new_endpoint_public_key.try(&.dup)
        end
      end

      # The application supplies an Aliro transport and cryptographic verifier.
      # `authenticate` MUST verify the complete reader transaction, its freshness,
      # key possession, and any step-up Access Credential before returning an
      # identity. The Door Lock never accepts a caller-supplied public key as
      # authentication by itself. This interface does not provide BLE/UWB.
      abstract class AliroReaderDelegate
        # True only when a real reader transport and verifier are available.
        abstract def ready? : Bool
        abstract def supported_protocol_versions : Array(Bytes)
        abstract def group_sub_identifier : Bytes
        abstract def configure(config : AliroReaderConfig) : Bool
        # Must obtain explicit local user permission before removing the reader
        # configuration. This callback must either complete the clear and
        # return true, or preserve reader state and return false/raise. A failed
        # call leaves Matter's stored configuration intact.
        abstract def clear_with_user_permission : Bool
        abstract def authenticate(transaction : Bytes, required_step_up_data_element : String) : AliroAuthenticatedAccess?
      end

      record WeekDaySchedule, week_day : UInt8, start_hour : UInt8, start_minute : UInt8, end_hour : UInt8, end_minute : UInt8 do
        include Storage::Record
      end

      record YearDaySchedule, local_start_time : UInt32, local_end_time : UInt32 do
        include Storage::Record
      end

      record HolidaySchedule, local_start_time : UInt32, local_end_time : UInt32, operating_mode : OperatingMode do
        include Storage::Record
      end

      record PersistedWeekDaySchedule, user_index : UInt16, week_day_index : UInt8, schedule : WeekDaySchedule do
        include Storage::Record
      end

      record PersistedYearDaySchedule, user_index : UInt16, year_day_index : UInt8, schedule : YearDaySchedule do
        include Storage::Record
      end

      record PersistedHolidaySchedule, holiday_index : UInt8, schedule : HolidaySchedule do
        include Storage::Record
      end

      struct PersistedDatabase
        include Storage::Record

        getter users : Array(UserRecord)
        getter credentials : Array(CredentialRecord)
        getter week_day_schedules : Array(PersistedWeekDaySchedule)
        getter year_day_schedules : Array(PersistedYearDaySchedule)
        getter holiday_schedules : Array(PersistedHolidaySchedule)
        getter aliro_reader_config : AliroReaderConfig?

        def initialize(
          @users : Array(UserRecord),
          @credentials : Array(CredentialRecord),
          @week_day_schedules : Array(PersistedWeekDaySchedule),
          @year_day_schedules : Array(PersistedYearDaySchedule),
          @holiday_schedules : Array(PersistedHolidaySchedule),
          @aliro_reader_config : AliroReaderConfig? = nil,
        )
        end
      end

      PERSISTED_DATABASE_KEY = "door_lock_database"

      @users = {} of UInt16 => UserRecord
      @credentials = {} of Tuple(UInt8, UInt16) => CredentialRecord
      @week_day_schedules = {} of Tuple(UInt16, UInt8) => WeekDaySchedule
      @year_day_schedules = {} of Tuple(UInt16, UInt8) => YearDaySchedule
      @holiday_schedules = {} of UInt8 => HolidaySchedule
      @aliro_reader_config : AliroReaderConfig? = nil
      @aliro_reader_delegate : AliroReaderDelegate? = nil
      @aliro_config_generation : UInt64 = 0_u64
      @aliro_group_sub_identifier : Bytes = Bytes.new(0)
      @aliro_protocol_versions : Array(Bytes) = [] of Bytes

      @failed_remote_pin_attempts : UInt8 = 0_u8
      @lockout_until : Time? = nil
      @relock_generation : UInt64 = 0_u64
      @user_expiry_generations = {} of UInt16 => UInt64

      getter default_pin_code : String

      def initialize(
        endpoint_id : DataType::EndpointNumber,
        @feature_map : Feature = Feature::DoorPositionSensor | Feature::PinCredential | Feature::CredentialOverTheAirAccess | Feature::User | Feature::Unbolting,
        @lock_state : LockState? = LockState::Locked,
        @lock_type : LockType = LockType::Deadbolt,
        @actuator_enabled : Bool = true,
        @door_state : DoorState? = DoorState::DoorClosed,
        @language : String = DEFAULT_LANGUAGE,
        @led_settings : LedSettings = LedSettings::NoLedSignal,
        @auto_relock_time : UInt32 = 0_u32,
        @sound_volume : SoundVolume = SoundVolume::Medium,
        @operating_mode : OperatingMode = OperatingMode::Normal,
        @supported_operating_modes : UInt16 = DEFAULT_SUPPORTED_OPERATING_MODES,
        @default_configuration_register : UInt16 = 0_u16,
        @enable_local_programming : Bool = true,
        @enable_one_touch_locking : Bool = false,
        @enable_inside_status_led : Bool = false,
        @enable_privacy_mode_button : Bool = false,
        @local_programming_features : UInt8 = 0_u8,
        @number_of_total_users_supported : UInt16 = DEFAULT_USERS_SUPPORTED,
        @number_of_pin_users_supported : UInt16 = DEFAULT_USERS_SUPPORTED,
        @number_of_rfid_users_supported : UInt16 = DEFAULT_USERS_SUPPORTED,
        @number_of_week_day_schedules_supported_per_user : UInt8 = DEFAULT_SCHEDULES_SUPPORTED,
        @number_of_year_day_schedules_supported_per_user : UInt8 = DEFAULT_SCHEDULES_SUPPORTED,
        @number_of_holiday_schedules_supported : UInt8 = DEFAULT_SCHEDULES_SUPPORTED,
        @max_pin_code_length : UInt8 = DEFAULT_MAX_PIN_CODE_LENGTH,
        @min_pin_code_length : UInt8 = DEFAULT_MIN_PIN_CODE_LENGTH,
        @max_rfid_code_length : UInt8 = DEFAULT_MAX_RFID_CODE_LENGTH,
        @min_rfid_code_length : UInt8 = DEFAULT_MIN_RFID_CODE_LENGTH,
        @credential_rules_support : UInt8 = CREDENTIAL_RULE_SINGLE,
        @number_of_credentials_supported_per_user : UInt8 = DEFAULT_CREDENTIALS_PER_USER,
        @number_of_aliro_credential_issuer_keys_supported : UInt16 = 0_u16,
        @number_of_aliro_endpoint_keys_supported : UInt16 = 0_u16,
        @aliro_reader_delegate : AliroReaderDelegate? = nil,
        @wrong_code_entry_limit : UInt8 = DEFAULT_WRONG_CODE_ENTRY_LIMIT,
        @user_code_temporary_disable_time : UInt8 = DEFAULT_TEMPORARY_DISABLE_SECONDS,
        @send_pin_over_the_air : Bool = false,
        @require_pin_for_remote_operation : Bool = false,
        @expiring_user_timeout : UInt16 = DEFAULT_EXPIRING_USER_TIMEOUT,
        @default_pin_code : String = DEFAULT_PIN_CODE,
        @local_time_provider : Proc(Time?) = -> : Time? { Time.local },
      )
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))

        raise ArgumentError.new("Aliro BLE/UWB requires a radio adapter") if @feature_map.aliro_bleuwb?
        if @feature_map.aliro_provisioning?
          reader = @aliro_reader_delegate || raise ArgumentError.new("Aliro provisioning requires a trusted reader delegate")
          raise ArgumentError.new("Aliro reader delegate is not ready") unless reader.ready?
          versions = reader.supported_protocol_versions
          raise ArgumentError.new("Aliro protocol versions must contain 1 to 16 two-byte entries") unless versions.size.in?(1..16) && versions.all? { |entry| entry.size == 2 }
          group_sub_identifier = reader.group_sub_identifier
          raise ArgumentError.new("Aliro group subidentifier must be 16 bytes") unless group_sub_identifier.size == ALIRO_GROUP_IDENTIFIER_LENGTH
          raise ArgumentError.new("Aliro issuer and endpoint capacities must be nonzero") if @number_of_aliro_credential_issuer_keys_supported.zero? || @number_of_aliro_endpoint_keys_supported.zero?
          @aliro_protocol_versions = versions.map(&.dup)
          @aliro_group_sub_identifier = group_sub_identifier.dup
        end
        raise ArgumentError.new("credentialOverTheAirAccess requires pinCredential") if @feature_map.credential_over_the_air_access? && !@feature_map.pin_credential?
        credential_feature = @feature_map.pin_credential? || @feature_map.rfid_credential? || @feature_map.finger_credentials? || @feature_map.face_credentials? || @feature_map.aliro_provisioning?
        raise ArgumentError.new("credential features require user") if credential_feature && !@feature_map.user?
        raise ArgumentError.new("aliroBLEUWB requires aliroProvisioning") if @feature_map.aliro_bleuwb? && !@feature_map.aliro_provisioning?
        raise ArgumentError.new("user schedules require user feature") if (@feature_map.week_day_access_schedules? || @feature_map.year_day_access_schedules? || @feature_map.holiday_schedules?) && !@feature_map.user?
        raise ArgumentError.new("supportedOperatingModes reserved bits must be set") if (@supported_operating_modes & SUPPORTED_OPERATING_MODES_RESERVED) != SUPPORTED_OPERATING_MODES_RESERVED
        raise ArgumentError.new("Normal operating mode is mandatory") unless (@supported_operating_modes & NORMAL_OPERATING_MODE_BIT).zero?
        raise ArgumentError.new("NoRemoteLockUnlock operating mode is mandatory") unless (@supported_operating_modes & NO_REMOTE_OPERATING_MODE_BIT).zero?
        raise ArgumentError.new("operatingMode is not supported") unless operating_mode_supported?(@operating_mode)
        raise ArgumentError.new("min_pin_code_length must be <= max_pin_code_length") if @min_pin_code_length > @max_pin_code_length
        raise ArgumentError.new("min_rfid_code_length must be <= max_rfid_code_length") if @min_rfid_code_length > @max_rfid_code_length
        raise ArgumentError.new("wrong_code_entry_limit must be >= 1") if @wrong_code_entry_limit < MIN_WRONG_CODE_ENTRY_LIMIT
        raise ArgumentError.new("user_code_temporary_disable_time must be >= 1") if @user_code_temporary_disable_time < MIN_TEMPORARY_DISABLE_TIME
        raise ArgumentError.new("expiring_user_timeout must be 1..2880 minutes") unless @expiring_user_timeout.in?(MIN_EXPIRING_USER_TIMEOUT..MAX_EXPIRING_USER_TIMEOUT)
        raise ArgumentError.new("only the Single credential rule is supported") unless @credential_rules_support == CREDENTIAL_RULE_SINGLE
        raise ArgumentError.new("local programming features contain reserved bits") unless (@local_programming_features & ~ALL_LOCAL_PROGRAMMING_FEATURES).zero?

        if @feature_map.user?
          # Keep a default programming user slot for easier integration testing.
          @users[1_u16] = UserRecord.new(
            user_index: 1_u16,
            user_name: "Admin",
            user_unique_id: 1_u32,
            user_status: UserStatus::OccupiedEnabled,
            user_type: UserType::ProgrammingUser,
            credential_rule: CredentialRule::Single,
            credentials: [] of Credential,
            creator_fabric_index: @request_fabric_index,
            last_modified_fabric_index: @request_fabric_index
          )
        end
      end

      # The DSL persists writable attributes. Keep the user database in the
      # same cluster document so a device flush commits the complete lock state.
      private def extend_persisted_state(document : Storage::Document) : Nil
        week_days = @week_day_schedules.map do |(user_index, index), schedule|
          PersistedWeekDaySchedule.new(user_index, index, schedule)
        end
        year_days = @year_day_schedules.map do |(user_index, index), schedule|
          PersistedYearDaySchedule.new(user_index, index, schedule)
        end
        holidays = @holiday_schedules.map do |index, schedule|
          PersistedHolidaySchedule.new(index, schedule)
        end

        document[PERSISTED_DATABASE_KEY] = PersistedDatabase.new(
          users: @users.values,
          credentials: @credentials.values,
          week_day_schedules: week_days,
          year_day_schedules: year_days,
          holiday_schedules: holidays,
          aliro_reader_config: @aliro_reader_config
        ).to_document
      end

      # Decode and validate into temporary tables before changing live state.
      # A document saved by an older version has no database and retains the
      # constructor's default programming user.
      private def restore_persisted_extension(document : Storage::Document) : Nil
        if raw_mask = document["local_programming_features"]?
          invalid = case raw_mask
                    when Int64
                      raw_mask < 0 || (raw_mask > ALL_LOCAL_PROGRAMMING_FEATURES && raw_mask != 0xFF_i64)
                    when UInt64
                      raw_mask > ALL_LOCAL_PROGRAMMING_FEATURES && raw_mask != 0xFF_u64
                    else
                      false # PersistedState has already validated the field type.
                    end
          raise StorageError.new("Invalid persisted Door Lock local programming features") if invalid
        end

        value = document[PERSISTED_DATABASE_KEY]?
        return unless value
        database = PersistedDatabase.from_document(value.as?(Storage::Document) ||
                                                   raise StorageError.new("Invalid persisted Door Lock database"))
        if (aliro_reader = database.aliro_reader_config) && !valid_aliro_reader_config?(aliro_reader)
          raise StorageError.new("Invalid persisted Door Lock Aliro reader configuration")
        end

        users = {} of UInt16 => UserRecord
        database.users.each do |user|
          if !valid_user_index?(user.user_index) || users.has_key?(user.user_index)
            raise StorageError.new("Invalid or duplicate persisted Door Lock user")
          end
          unless user.credential_rule.single?
            raise StorageError.new("Unsupported persisted Door Lock credential rule")
          end
          user.credentials = [] of Credential
          users[user.user_index] = user
        end
        raise StorageError.new("Too many persisted Door Lock users") if users.size > @number_of_total_users_supported

        credentials = {} of Tuple(UInt8, UInt16) => CredentialRecord
        aliro_public_keys = Set(String).new
        issuer_count = 0
        endpoint_count = 0
        database.credentials.each do |record|
          key = credential_key(record.credential)
          aliro = aliro_credential_type?(record.credential.credential_type)
          if credentials.has_key?(key) || validate_credential_input(record.credential, record.credential_data, allow_aliro: aliro)
            raise StorageError.new("Invalid or duplicate persisted Door Lock credential")
          end
          if aliro
            public_key = record.credential_data.hexstring
            if aliro_public_keys.includes?(public_key)
              raise StorageError.new("Duplicate persisted Door Lock Aliro public key")
            end
            aliro_public_keys << public_key
            if record.credential.credential_type.aliro_credential_issuer_key?
              issuer_count += 1
              raise StorageError.new("Too many persisted Door Lock Aliro issuer keys") if issuer_count > @number_of_aliro_credential_issuer_keys_supported
            else
              endpoint_count += 1
              raise StorageError.new("Too many persisted Door Lock Aliro endpoint keys") if endpoint_count > @number_of_aliro_endpoint_keys_supported
            end
          end
          if user_index = record.user_index
            user = users[user_index]? || raise StorageError.new("Persisted Door Lock credential has no user")
            if user.credentials.size >= @number_of_credentials_supported_per_user
              raise StorageError.new("Too many persisted Door Lock credentials for user")
            end
            user.credentials << record.credential
            users[user_index] = user
          end
          credentials[key] = record
        end

        week_days = {} of Tuple(UInt16, UInt8) => WeekDaySchedule
        database.week_day_schedules.each do |entry|
          key = {entry.user_index, entry.week_day_index}
          if !users.has_key?(entry.user_index) || !valid_week_day_schedule_index?(entry.week_day_index) || week_days.has_key?(key) ||
             !valid_week_day_schedule?(entry.schedule)
            raise StorageError.new("Invalid persisted Door Lock week day schedule")
          end
          week_days[key] = entry.schedule
        end

        year_days = {} of Tuple(UInt16, UInt8) => YearDaySchedule
        database.year_day_schedules.each do |entry|
          key = {entry.user_index, entry.year_day_index}
          if !users.has_key?(entry.user_index) || !valid_year_day_schedule_index?(entry.year_day_index) || year_days.has_key?(key) ||
             entry.schedule.local_start_time >= entry.schedule.local_end_time
            raise StorageError.new("Invalid persisted Door Lock year day schedule")
          end
          year_days[key] = entry.schedule
        end

        holidays = {} of UInt8 => HolidaySchedule
        database.holiday_schedules.each do |entry|
          if !valid_holiday_schedule_index?(entry.holiday_index) || holidays.has_key?(entry.holiday_index) ||
             entry.schedule.local_start_time >= entry.schedule.local_end_time || !operating_mode_supported?(entry.schedule.operating_mode)
            raise StorageError.new("Invalid persisted Door Lock holiday schedule")
          end
          holidays[entry.holiday_index] = entry.schedule
        end

        if @feature_map.aliro_provisioning? && (config = aliro_reader)
          reader = @aliro_reader_delegate || raise StorageError.new("Aliro reader delegate unavailable")
          applied = begin
            reader.configure(config)
          rescue ex
            Log.error(exception: ex) { "Aliro reader rejected restored configuration" }
            false
          end
          unless applied
            @feature_map = @feature_map & ~Feature::AliroProvisioning
            raise StorageError.new("Door Lock Aliro reader rejected restored configuration")
          end
        end
        @users = users
        @credentials = credentials
        @week_day_schedules = week_days
        @year_day_schedules = year_days
        @holiday_schedules = holidays
        @aliro_reader_config = aliro_reader.try do |restored_config|
          AliroReaderConfig.new(restored_config.signing_key, restored_config.verification_key,
            restored_config.group_identifier, restored_config.group_resolving_key)
        end
      end

      private def after_restore_state : Nil
        if @local_programming_features == 0xFF_u8
          @local_programming_features = ALL_LOCAL_PROGRAMMING_FEATURES
          increment_version_and_notify(ATTR_LOCAL_PROGRAMMING_FEATURES)
        end
        @user_expiry_generations.keys.each { |user_index| cancel_user_expiry(user_index) }
        @users.keys.each do |user_index|
          expire_user_if_due(user_index)
          if user = @users[user_index]?
            if user.user_type.expiring_user? && user.user_status.occupied_enabled? && (deadline = user.expiring_user_expires_at)
              arm_user_expiry(user_index, deadline)
            end
          end
        end
      end

      # These local APIs stage Aliro material for a future reader delegate.
      # They do not enable the Aliro Matter feature bits or wire commands.
      def aliro_reader_config : AliroReaderConfig?
        @aliro_reader_config.try do |config|
          AliroReaderConfig.new(config.signing_key, config.verification_key,
            config.group_identifier, config.group_resolving_key)
        end
      end

      def configure_aliro_reader(config : AliroReaderConfig) : InteractionModel::Status
        return InteractionModel::Status.invalid_in_state if @aliro_reader_config
        return InteractionModel::Status.constraint_error unless valid_aliro_reader_config?(config)
        if @feature_map.aliro_provisioning?
          reader = @aliro_reader_delegate || return InteractionModel::Status.failure
          applied = begin
            reader.configure(config)
          rescue ex
            Log.error(exception: ex) { "Aliro reader configuration failed" }
            false
          end
          return InteractionModel::Status.failure unless applied
        end

        @aliro_reader_config = AliroReaderConfig.new(config.signing_key, config.verification_key,
          config.group_identifier, config.group_resolving_key)
        @aliro_config_generation = @aliro_config_generation &+ 1_u64
        increment_version
        notify_changed(0x0080_u32)
        notify_changed(0x0081_u32)
        InteractionModel::Status.success
      end

      def clear_aliro_reader_config : InteractionModel::Status
        if @feature_map.aliro_provisioning?
          reader = @aliro_reader_delegate || return InteractionModel::Status.failure
          permitted = begin
            reader.clear_with_user_permission
          rescue ex
            Log.error(exception: ex) { "Aliro reader clear failed" }
            false
          end
          return InteractionModel::Status.failure unless permitted
        end
        @aliro_reader_config = nil
        @aliro_config_generation = @aliro_config_generation &+ 1_u64
        increment_version
        notify_changed(0x0080_u32)
        notify_changed(0x0081_u32)
        InteractionModel::Status.success
      end

      def aliro_reader_verification_key : Bytes?
        @aliro_reader_config.try(&.verification_key.dup)
      end

      def aliro_reader_group_identifier : Bytes?
        @aliro_reader_config.try(&.group_identifier.dup)
      end

      def aliro_reader_group_sub_identifier : Bytes
        @aliro_group_sub_identifier.dup
      end

      def aliro_expedited_transaction_supported_protocol_versions : Array(Bytes)
        @aliro_protocol_versions.map(&.dup)
      end

      # Called by the host transport with an opaque Aliro transaction. Only the
      # trusted delegate may turn it into an authenticated key identity. The
      # delegate is responsible for the Aliro cryptography and replay checks.
      def perform_aliro_transaction(transaction : Bytes) : InteractionModel::Status
        return InteractionModel::Status.unsupported_command unless @feature_map.aliro_provisioning?
        return InteractionModel::Status.cluster_failure(StatusCode::Failure) unless @aliro_reader_config
        return InteractionModel::Status.cluster_failure(StatusCode::Failure) unless remote_control_allowed?

        generation = @aliro_config_generation
        reader = @aliro_reader_delegate || return InteractionModel::Status.cluster_failure(StatusCode::Failure)
        access = begin
          reader.authenticate(transaction, "matter1")
        rescue ex
          Log.error(exception: ex) { "Aliro reader authentication failed" }
          nil
        end
        return InteractionModel::Status.cluster_failure(StatusCode::Failure) unless generation == @aliro_config_generation && @aliro_reader_config
        return InteractionModel::Status.cluster_failure(StatusCode::Failure) unless access
        return InteractionModel::Status.cluster_failure(StatusCode::Failure) unless valid_aliro_public_key?(access.credential_public_key)

        issuer = access.issuer_public_key
        if issuer
          return InteractionModel::Status.cluster_failure(StatusCode::Failure) unless issuer == access.credential_public_key
          # An issuer key is only usable after the delegate verifies a step-up
          # request. A bare issuer identity may never operate the lock.
          proposed_key = access.new_endpoint_public_key
          return InteractionModel::Status.cluster_failure(StatusCode::Failure) unless proposed_key && valid_aliro_public_key?(proposed_key)
        elsif access.new_endpoint_public_key
          return InteractionModel::Status.cluster_failure(StatusCode::Failure)
        end

        record = @credentials.values.find do |candidate|
          next false unless candidate.credential_data == access.credential_public_key
          issuer ? candidate.credential.credential_type.aliro_credential_issuer_key? : aliro_endpoint_key_type?(candidate.credential.credential_type)
        end
        return InteractionModel::Status.cluster_failure(StatusCode::Failure) unless record
        user_index = record.user_index
        return InteractionModel::Status.cluster_failure(StatusCode::Failure) unless user_index
        expire_user_if_due(user_index)
        user = @users[user_index]?
        return InteractionModel::Status.cluster_failure(StatusCode::Failure) unless user
        if user.user_status != UserStatus::OccupiedEnabled
          report_lock_operation_error(LockOperationType::Unlock, OperationSource::Aliro, OperationError::DisabledUserDenied,
            Authorization.new(nil, user_index, record.credential))
          return InteractionModel::Status.cluster_failure(StatusCode::Failure)
        end
        unless schedule_allows_user?(user)
          report_lock_operation_error(LockOperationType::Unlock, OperationSource::Aliro, OperationError::Restricted,
            Authorization.new(nil, user_index, record.credential))
          return InteractionModel::Status.cluster_failure(StatusCode::Failure)
        end
        if user.user_type.expiring_user? && @local_time_provider.call.nil?
          report_lock_operation_error(LockOperationType::Unlock, OperationSource::Aliro, OperationError::Restricted,
            Authorization.new(nil, user_index, record.credential))
          return InteractionModel::Status.cluster_failure(StatusCode::Failure)
        end

        if user.user_type.non_access_user?
          emit_aliro_lock_operation(LockOperationType::NonAccessUserEvent, user_index, record.credential)
          return InteractionModel::Status.success
        end

        used_credential = record.credential
        if issuer && (new_key = access.new_endpoint_public_key)
          if installed = install_aliro_step_up_key(user_index, new_key)
            used_credential = installed
          end
        end

        self.lock_state = LockState::Unlocked
        schedule_relock(@auto_relock_time)
        operation = user.user_type.forced_user? ? LockOperationType::ForcedUserEvent : LockOperationType::Unlock
        emit_aliro_lock_operation(operation, user_index, used_credential)
        emit_door_lock_alarm(Events::DoorLockAlarm.new(AlarmCode::ForcedUser)) if user.user_type.forced_user?
        if user.user_type.disposable_user?
          disable_user(user_index)
        elsif user.user_type.expiring_user? && !user.expiring_user_expires_at
          start_user_expiry(user_index)
        end
        InteractionModel::Status.success
      end

      private def emit_aliro_lock_operation(operation : LockOperationType, user_index : UInt16, credential : Credential) : Nil
        emit_lock_operation(Events::LockOperation.new(
          lock_operation_type: operation,
          operation_source: OperationSource::Aliro,
          user_index: user_index,
          credentials: [credential]
        ))
      end

      private def install_aliro_step_up_key(user_index : UInt16, public_key : Bytes) : Credential?
        return unless valid_aliro_public_key?(public_key)
        return if @credentials.values.any? { |record| aliro_credential_type?(record.credential.credential_type) && record.credential_data == public_key }

        type = CredentialType::AliroEvictableEndpointKey
        index = next_available_credential_index(type, 0_u16)
        user = @users[user_index]
        endpoint_count = @credentials.values.count { |record| aliro_endpoint_key_type?(record.credential.credential_type) }
        if !index || endpoint_count >= @number_of_aliro_endpoint_keys_supported || user.credentials.size >= @number_of_credentials_supported_per_user
          evictable = @credentials.values
            .select { |record| record.user_index == user_index && record.credential.credential_type.aliro_evictable_endpoint_key? }
            .min_by?(&.credential.credential_index)
          return unless evictable
          index = evictable.credential.credential_index
          @credentials.delete(credential_key(evictable.credential))
          remove_credential_from_user(evictable, nil)
          emit_aliro_user_change(evictable.credential, user_index, DataOperationType::Clear)
        end

        credential_index = index || return
        credential = Credential.new(type, credential_index)
        record = CredentialRecord.new(credential, public_key.dup, user_index)
        @credentials[credential_key(credential)] = record
        add_credential_to_user(record, nil)
        emit_aliro_user_change(credential, user_index, DataOperationType::Add)
        increment_version
        credential
      end

      private def emit_aliro_user_change(credential : Credential, user_index : UInt16, operation : DataOperationType) : Nil
        emit_lock_user_change(Events::LockUserChange.new(
          lock_data_type: LockDataType::AliroEvictableEndpointKey,
          data_operation_type: operation,
          operation_source: OperationSource::Aliro,
          user_index: user_index,
          data_index: credential.credential_index
        ))
      end

      private def emit_aliro_wire_user_change(credential : Credential, operation : DataOperationType, user_index : UInt16?) : Nil
        data_type = case credential.credential_type
                    when CredentialType::AliroCredentialIssuerKey     then LockDataType::AliroCredentialIssuerKey
                    when CredentialType::AliroEvictableEndpointKey    then LockDataType::AliroEvictableEndpointKey
                    when CredentialType::AliroNonEvictableEndpointKey then LockDataType::AliroNonEvictableEndpointKey
                    else                                                   return
                    end
        emit_lock_user_change(Events::LockUserChange.new(
          lock_data_type: data_type,
          data_operation_type: operation,
          operation_source: OperationSource::Remote,
          user_index: user_index,
          fabric_index: @request_fabric_index,
          source_node: @request_peer_node_id,
          data_index: credential.credential_index
        ), @request_fabric_index)
      end

      def handle_set_aliro_reader_config(request : SetAliroReaderConfigRequest) : InteractionModel::Status
        return InteractionModel::Status.unsupported_command unless @feature_map.aliro_provisioning?
        return InteractionModel::Status.constraint_error if request.group_resolving_key
        configure_aliro_reader(AliroReaderConfig.new(request.signing_key, request.verification_key, request.group_identifier))
      end

      def handle_clear_aliro_reader_config : InteractionModel::Status
        return InteractionModel::Status.unsupported_command unless @feature_map.aliro_provisioning?
        clear_aliro_reader_config
      end

      def provision_aliro_key(type : CredentialType, index : UInt16, user_index : UInt16, public_key : Bytes, *, fabric_index : UInt8? = nil) : StatusCode
        return StatusCode::InvalidField unless aliro_credential_type?(type)
        credential = Credential.new(type, index)
        return StatusCode::InvalidField if validate_credential_input(credential, public_key, allow_aliro: true)
        return StatusCode::InvalidField unless @users.has_key?(user_index)

        key = credential_key(credential)
        return StatusCode::Occupied if @credentials.has_key?(key)
        return StatusCode::Duplicate if @credentials.values.any? { |record| aliro_credential_type?(record.credential.credential_type) && record.credential_data == public_key }

        user = @users[user_index]
        return StatusCode::ResourceExhausted if user.credentials.size >= @number_of_credentials_supported_per_user
        if type.aliro_credential_issuer_key?
          count = @credentials.values.count { |record| record.credential.credential_type.aliro_credential_issuer_key? }
          return StatusCode::ResourceExhausted if count >= @number_of_aliro_credential_issuer_keys_supported
        else
          count = @credentials.values.count { |record| aliro_endpoint_key_type?(record.credential.credential_type) }
          return StatusCode::ResourceExhausted if count >= @number_of_aliro_endpoint_keys_supported
        end

        record = CredentialRecord.new(credential, public_key.dup, user_index, fabric_index, fabric_index)
        @credentials[key] = record
        add_credential_to_user(record, fabric_index)
        increment_version
        StatusCode::Success
      end

      def aliro_key_data(type : CredentialType, index : UInt16) : Bytes?
        return unless aliro_credential_type?(type)
        @credentials[{type.value.to_u8, index}]?.try(&.credential_data.dup)
      end

      def clear_aliro_key(type : CredentialType, index : UInt16, *, fabric_index : UInt8? = nil) : StatusCode
        return StatusCode::InvalidField unless aliro_credential_type?(type) && credential_index_supported?(Credential.new(type, index), allow_aliro: true)
        return StatusCode::NotFound unless record = @credentials.delete({type.value.to_u8, index})

        remove_credential_from_user(record, fabric_index || record.last_modified_fabric_index)
        increment_version
        StatusCode::Success
      end

      private def valid_aliro_reader_config?(config : AliroReaderConfig) : Bool
        return false unless config.signing_key.size == ALIRO_SIGNING_KEY_LENGTH
        return false unless valid_aliro_public_key?(config.verification_key)
        return false unless config.group_identifier.size == ALIRO_GROUP_IDENTIFIER_LENGTH
        if resolving_key = config.group_resolving_key
          return false unless resolving_key.size == ALIRO_GROUP_IDENTIFIER_LENGTH
        end

        derived = OpenSSL::PKey::EC.from_private_bytes(config.signing_key, Crypto::CRYPTO_EC_CURVE_NIST)
        derived.public_key_bytes == config.verification_key
      rescue OpenSSL::PKey::EcError
        false
      end

      private def valid_aliro_public_key?(public_key : Bytes) : Bool
        return false unless public_key.size == ALIRO_PUBLIC_KEY_LENGTH && public_key[0] == ALIRO_UNCOMPRESSED_POINT_PREFIX
        OpenSSL::PKey::EC.from_public_bytes(public_key, Crypto::CRYPTO_EC_CURVE_NIST)
        true
      rescue OpenSSL::PKey::EcError
        false
      end

      private def aliro_credential_type?(type : CredentialType) : Bool
        type.aliro_credential_issuer_key? || aliro_endpoint_key_type?(type)
      end

      private def aliro_endpoint_key_type?(type : CredentialType) : Bool
        type.aliro_evictable_endpoint_key? || type.aliro_non_evictable_endpoint_key?
      end

      # ------------------------------------------------------------------------
      # Lock commands
      # ------------------------------------------------------------------------

      def lock_door(request : LockDoorRequest) : InteractionModel::Status
        lock(pin: pin_from_slice(request.pin_code))
      end

      def unlock_door(request : UnlockDoorRequest) : InteractionModel::Status
        unlock(pin: pin_from_slice(request.pin_code))
      end

      def unlock_with_timeout(request : UnlockWithTimeoutRequest) : InteractionModel::Status
        unlock_with_timeout(request.timeout, pin: pin_from_slice(request.pin_code))
      end

      def unbolt_door(request : UnboltDoorRequest) : InteractionModel::Status
        unbolt(pin: pin_from_slice(request.pin_code))
      end

      # ------------------------------------------------------------------------
      # Public API for local application logic
      # ------------------------------------------------------------------------

      def lock(pin : String? = nil, source : OperationSource = OperationSource::Remote) : InteractionModel::Status
        return InteractionModel::Status.cluster_failure(StatusCode::Failure) unless remote_control_allowed?
        authorization = authorize_remote_operation(pin, LockOperationType::Lock, source)
        if status = authorization.status
          return status
        end

        cancel_pending_relock
        self.lock_state = LockState::Locked
        complete_lock_operation(LockOperationType::Lock, source, authorization)
        InteractionModel::Status.success
      end

      def unlock(pin : String? = nil, source : OperationSource = OperationSource::Remote) : InteractionModel::Status
        return InteractionModel::Status.cluster_failure(StatusCode::Failure) unless remote_control_allowed?
        authorization = authorize_remote_operation(pin, LockOperationType::Unlock, source)
        if status = authorization.status
          return status
        end

        self.lock_state = LockState::Unlocked
        schedule_relock(@auto_relock_time)
        complete_lock_operation(LockOperationType::Unlock, source, authorization)
        InteractionModel::Status.success
      end

      def unlock_with_timeout(timeout_seconds : UInt16, pin : String? = nil, source : OperationSource = OperationSource::Remote) : InteractionModel::Status
        return InteractionModel::Status.cluster_failure(StatusCode::Failure) unless remote_control_allowed?
        authorization = authorize_remote_operation(pin, LockOperationType::Unlock, source)
        if status = authorization.status
          return status
        end

        self.lock_state = LockState::Unlocked
        schedule_relock(timeout_seconds.to_u32)
        complete_lock_operation(LockOperationType::Unlock, source, authorization)
        InteractionModel::Status.success
      end

      def unbolt(pin : String? = nil, source : OperationSource = OperationSource::Remote) : InteractionModel::Status
        return InteractionModel::Status.unsupported_command unless @feature_map.unbolting?
        return InteractionModel::Status.cluster_failure(StatusCode::Failure) unless remote_control_allowed?
        authorization = authorize_remote_operation(pin, LockOperationType::Unlatch, source)
        if status = authorization.status
          return status
        end

        self.lock_state = LockState::Unlatched
        schedule_relock(@auto_relock_time)
        complete_lock_operation(LockOperationType::Unlatch, source, authorization)
        InteractionModel::Status.success
      end

      def locked? : Bool
        @lock_state == LockState::Locked
      end

      def unlocked? : Bool
        @lock_state == LockState::Unlocked
      end

      def unlatched? : Bool
        @lock_state == LockState::Unlatched
      end

      private def operating_mode_supported?(mode : OperatingMode) : Bool
        (@supported_operating_modes & (1_u16 << mode.value)).zero?
      end

      # Records a door position change and counts the open / close events; the
      # counters move before DoorState so its callback sees them updated.
      def update_door_state(new_state : DoorState?) : Nil
        return unless @feature_map.door_position_sensor?
        return if @door_state == new_state

        case new_state
        when DoorState::DoorOpen
          self.door_open_events = @door_open_events + 1_u32
        when DoorState::DoorClosed
          self.door_closed_events = @door_closed_events + 1_u32
        end

        self.door_state = new_state
        emit_door_state_change(Events::DoorStateChange.new(new_state)) if new_state
      end

      # Journals the LockOperation event for a completed operation. Remote
      # operations carry the fabric and node that asked for them; a local one
      # carries neither.
      private def report_lock_operation(operation : LockOperationType, source : OperationSource, authorization : Authorization) : Nil
        fabric_index = @request_fabric_index
        emit_lock_operation(
          Events::LockOperation.new(
            lock_operation_type: operation,
            operation_source: source,
            user_index: authorization.user_index,
            fabric_index: fabric_index,
            source_node: @request_peer_node_id,
            credentials: authorization.credential.try { |credential| [credential] }
          ),
          fabric_index
        )
      end

      private def report_lock_operation_error(operation : LockOperationType, source : OperationSource,
                                              error : OperationError, authorization : Authorization = Authorization.new) : Nil
        emit_lock_operation_error(Events::LockOperationError.new(
          lock_operation_type: operation,
          operation_source: source,
          operation_error: error,
          user_index: authorization.user_index,
          fabric_index: @request_fabric_index,
          source_node: @request_peer_node_id,
          credentials: authorization.credential.try { |credential| [credential] }
        ), @request_fabric_index)
      end

      private def complete_lock_operation(operation : LockOperationType, source : OperationSource, authorization : Authorization) : Nil
        user = authorization.user_index.try { |index| @users[index]? }
        forced = user && user.user_type.forced_user?
        report_lock_operation(forced ? LockOperationType::ForcedUserEvent : operation, source, authorization)
        emit_door_lock_alarm(Events::DoorLockAlarm.new(AlarmCode::ForcedUser)) if forced

        if user
          if user.user_type.disposable_user? && (operation.unlock? || operation.unlatch?)
            disable_user(user.user_index)
          elsif user.user_type.expiring_user? && !user.expiring_user_expires_at
            start_user_expiry(user.user_index)
          end
        end
      end

      # ------------------------------------------------------------------------
      # Schedule commands
      # ------------------------------------------------------------------------

      def handle_set_week_day_schedule(request : SetWeekDayScheduleRequest) : InteractionModel::Status
        return InteractionModel::Status.cluster_failure(StatusCode::InvalidField) unless valid_user_index?(request.user_index)
        return InteractionModel::Status.cluster_failure(StatusCode::InvalidField) unless valid_week_day_schedule_index?(request.week_day_index)
        return InteractionModel::Status.cluster_failure(StatusCode::NotFound) unless @users.has_key?(request.user_index)

        schedule = WeekDaySchedule.new(request.week_day, request.start_hour, request.start_minute, request.end_hour, request.end_minute)
        return InteractionModel::Status.cluster_failure(StatusCode::InvalidField) unless valid_week_day_schedule?(schedule)

        @week_day_schedules[{request.user_index, request.week_day_index}] = schedule
        increment_version
        InteractionModel::Status.success
      end

      def get_week_day_schedule(request : GetWeekDayScheduleRequest) : GetWeekDayScheduleResponse
        if !valid_user_index?(request.user_index) || !valid_week_day_schedule_index?(request.week_day_index)
          return week_day_schedule_response(request, StatusCode::InvalidField)
        end

        if schedule = @week_day_schedules[{request.user_index, request.week_day_index}]?
          week_day_schedule_response(request, StatusCode::Success, schedule)
        else
          week_day_schedule_response(request, StatusCode::NotFound)
        end
      end

      def clear_week_day_schedule(request : ClearWeekDayScheduleRequest) : InteractionModel::Status
        return InteractionModel::Status.cluster_failure(StatusCode::InvalidField) unless valid_user_index?(request.user_index)
        unless request.week_day_index == ALL_SCHEDULES || valid_week_day_schedule_index?(request.week_day_index)
          return InteractionModel::Status.cluster_failure(StatusCode::InvalidField)
        end

        if request.week_day_index == ALL_SCHEDULES
          @week_day_schedules.keys.select { |(user_index, _)| user_index == request.user_index }.each do |key|
            @week_day_schedules.delete(key)
          end
        else
          @week_day_schedules.delete({request.user_index, request.week_day_index})
        end

        increment_version
        InteractionModel::Status.success
      end

      def handle_set_year_day_schedule(request : SetYearDayScheduleRequest) : InteractionModel::Status
        return InteractionModel::Status.cluster_failure(StatusCode::InvalidField) unless valid_user_index?(request.user_index)
        return InteractionModel::Status.cluster_failure(StatusCode::InvalidField) unless valid_year_day_schedule_index?(request.year_day_index)
        return InteractionModel::Status.cluster_failure(StatusCode::NotFound) unless @users.has_key?(request.user_index)
        return InteractionModel::Status.cluster_failure(StatusCode::InvalidField) if request.local_start_time >= request.local_end_time

        @year_day_schedules[{request.user_index, request.year_day_index}] = YearDaySchedule.new(
          request.local_start_time,
          request.local_end_time
        )
        increment_version
        InteractionModel::Status.success
      end

      def get_year_day_schedule(request : GetYearDayScheduleRequest) : GetYearDayScheduleResponse
        if !valid_user_index?(request.user_index) || !valid_year_day_schedule_index?(request.year_day_index)
          return year_day_schedule_response(request, StatusCode::InvalidField)
        end

        if schedule = @year_day_schedules[{request.user_index, request.year_day_index}]?
          year_day_schedule_response(request, StatusCode::Success, schedule)
        else
          year_day_schedule_response(request, StatusCode::NotFound)
        end
      end

      def clear_year_day_schedule(request : ClearYearDayScheduleRequest) : InteractionModel::Status
        return InteractionModel::Status.cluster_failure(StatusCode::InvalidField) unless valid_user_index?(request.user_index)
        unless request.year_day_index == ALL_SCHEDULES || valid_year_day_schedule_index?(request.year_day_index)
          return InteractionModel::Status.cluster_failure(StatusCode::InvalidField)
        end

        if request.year_day_index == ALL_SCHEDULES
          @year_day_schedules.keys.select { |(user_index, _)| user_index == request.user_index }.each do |key|
            @year_day_schedules.delete(key)
          end
        else
          @year_day_schedules.delete({request.user_index, request.year_day_index})
        end

        increment_version
        InteractionModel::Status.success
      end

      def handle_set_holiday_schedule(request : SetHolidayScheduleRequest) : InteractionModel::Status
        return InteractionModel::Status.cluster_failure(StatusCode::InvalidField) unless valid_holiday_schedule_index?(request.holiday_index)
        return InteractionModel::Status.cluster_failure(StatusCode::InvalidField) if request.local_start_time >= request.local_end_time
        return InteractionModel::Status.cluster_failure(StatusCode::InvalidField) unless operating_mode_supported?(request.operating_mode)

        @holiday_schedules[request.holiday_index] = HolidaySchedule.new(
          request.local_start_time,
          request.local_end_time,
          request.operating_mode
        )
        increment_version
        InteractionModel::Status.success
      end

      def get_holiday_schedule(request : GetHolidayScheduleRequest) : GetHolidayScheduleResponse
        return holiday_schedule_response(request, StatusCode::InvalidField) unless valid_holiday_schedule_index?(request.holiday_index)

        if schedule = @holiday_schedules[request.holiday_index]?
          holiday_schedule_response(request, StatusCode::Success, schedule)
        else
          holiday_schedule_response(request, StatusCode::NotFound)
        end
      end

      def clear_holiday_schedule(request : ClearHolidayScheduleRequest) : InteractionModel::Status
        unless request.holiday_index == ALL_SCHEDULES || valid_holiday_schedule_index?(request.holiday_index)
          return InteractionModel::Status.cluster_failure(StatusCode::InvalidField)
        end

        if request.holiday_index == ALL_SCHEDULES
          @holiday_schedules.clear
        else
          @holiday_schedules.delete(request.holiday_index)
        end

        increment_version
        InteractionModel::Status.success
      end

      # ------------------------------------------------------------------------
      # User commands
      # ------------------------------------------------------------------------

      def handle_set_user(request : SetUserRequest) : InteractionModel::Status
        return InteractionModel::Status.cluster_failure(StatusCode::InvalidField) unless valid_user_index?(request.user_index)
        if (rule = request.credential_rule) && !rule.single?
          return InteractionModel::Status.cluster_failure(StatusCode::InvalidField)
        end

        case request.operation_type
        when DataOperationType::Add
          return InteractionModel::Status.cluster_failure(StatusCode::Occupied) if @users.has_key?(request.user_index)
          if @users.size >= @number_of_total_users_supported
            return InteractionModel::Status.cluster_failure(StatusCode::ResourceExhausted)
          end

          @users[request.user_index] = UserRecord.new(
            user_index: request.user_index,
            user_name: request.user_name || "",
            user_unique_id: request.user_unique_id || request.user_index.to_u32,
            user_status: request.user_status || UserStatus::OccupiedEnabled,
            user_type: request.user_type || UserType::UnrestrictedUser,
            credential_rule: request.credential_rule || CredentialRule::Single,
            credentials: [] of Credential,
            creator_fabric_index: @request_fabric_index,
            last_modified_fabric_index: @request_fabric_index
          )
        when DataOperationType::Modify
          unless user = @users[request.user_index]?
            return InteractionModel::Status.cluster_failure(StatusCode::NotFound)
          end

          restarts_expiry = request.user_status.try { |status| status != user.user_status } || false
          restarts_expiry ||= request.user_type.try { |type| type != user.user_type } || false
          if restarts_expiry
            user.expiring_user_expires_at = nil
            cancel_user_expiry(request.user_index)
          end

          if user_name = request.user_name
            user.user_name = user_name
          end

          if user_unique_id = request.user_unique_id
            user.user_unique_id = user_unique_id
          end

          if user_status = request.user_status
            user.user_status = user_status
          end

          if user_type = request.user_type
            user.user_type = user_type
          end

          if credential_rule = request.credential_rule
            user.credential_rule = credential_rule
          end

          user.last_modified_fabric_index = @request_fabric_index
          @users[request.user_index] = user
        when DataOperationType::Clear
          clear_user_record(request.user_index)
        else
          return InteractionModel::Status.cluster_failure(StatusCode::InvalidField)
        end

        increment_version
        InteractionModel::Status.success
      end

      def get_user(request : GetUserRequest) : GetUserResponse
        return vacant_user_response(request.user_index, nil) unless valid_user_index?(request.user_index)

        expire_user_if_due(request.user_index)

        next_user = @users.keys.select { |index| index > request.user_index }.sort!.first?

        if user = @users[request.user_index]?
          visible_credentials = user.credentials.select { |credential| credential_type_supported?(credential.credential_type) }
          GetUserResponse.new(
            user_index: user.user_index,
            user_name: user.user_name,
            user_unique_id: user.user_unique_id,
            user_status: user.user_status,
            user_type: user.user_type,
            credential_rule: user.credential_rule,
            credentials: visible_credentials.empty? ? nil : visible_credentials,
            creator_fabric_index: user.creator_fabric_index,
            last_modified_fabric_index: user.last_modified_fabric_index,
            next_user_index: next_user
          )
        else
          vacant_user_response(request.user_index, next_user)
        end
      end

      def clear_user(request : ClearUserRequest) : InteractionModel::Status
        if request.user_index == ALL_USERS
          @users.keys.each { |user_index| clear_user_record(user_index) }
        else
          return InteractionModel::Status.cluster_failure(StatusCode::InvalidField) unless valid_user_index?(request.user_index)
          clear_user_record(request.user_index)
        end

        increment_version
        InteractionModel::Status.success
      end

      # ------------------------------------------------------------------------
      # Credential commands
      # ------------------------------------------------------------------------

      def handle_set_credential(request : SetCredentialRequest) : SetCredentialResponse
        if (user_index = request.user_index) && !valid_user_index?(user_index)
          return set_credential_response(request, StatusCode::InvalidField)
        end

        credential_key = credential_key(request.credential)

        if error = validate_credential_input(request.credential, request.credential_data)
          return set_credential_response(request, error)
        end

        created_user_index : UInt16? = nil
        affected_user_index : UInt16? = request.user_index

        case request.operation_type
        when DataOperationType::Add
          if @credentials.has_key?(credential_key)
            status = StatusCode::Occupied
          else
            if aliro_credential_type?(request.credential.credential_type)
              if @credentials.values.any? { |record| aliro_credential_type?(record.credential.credential_type) && record.credential_data == request.credential_data }
                return set_credential_response(request, StatusCode::Duplicate)
              end
              type = request.credential.credential_type
              count = @credentials.values.count do |record|
                type.aliro_credential_issuer_key? ? record.credential.credential_type.aliro_credential_issuer_key? : aliro_endpoint_key_type?(record.credential.credential_type)
              end
              limit = type.aliro_credential_issuer_key? ? @number_of_aliro_credential_issuer_keys_supported : @number_of_aliro_endpoint_keys_supported
              return set_credential_response(request, StatusCode::ResourceExhausted) if count >= limit
            end

            target_user_index = request.user_index
            if target_user_index.nil? && !request.credential.credential_type.programming_pin?
              target_user_index = (1_u16..@number_of_total_users_supported).find { |index| !@users.has_key?(index) }
              return set_credential_response(request, StatusCode::ResourceExhausted) unless target_user_index
            end
            if user_index = target_user_index
              if @users.size >= @number_of_total_users_supported && !@users.has_key?(user_index)
                return set_credential_response(request, StatusCode::ResourceExhausted)
              end

              user_existed = @users.has_key?(user_index)
              ensure_user_exists(user_index, request.user_status, request.user_type)
              unless @users.has_key?(user_index)
                return set_credential_response(request, StatusCode::ResourceExhausted)
              end
              created_user_index = user_index unless user_existed

              if user = @users[user_index]?
                if !credential_belongs_to_user?(user, request.credential) && user.credentials.size >= @number_of_credentials_supported_per_user
                  return set_credential_response(request, StatusCode::ResourceExhausted)
                end
              end
            end

            record = CredentialRecord.new(
              credential: request.credential,
              credential_data: request.credential_data.dup,
              user_index: target_user_index,
              creator_fabric_index: @request_fabric_index,
              last_modified_fabric_index: @request_fabric_index
            )
            @credentials[credential_key] = record
            add_credential_to_user(record)
            affected_user_index = target_user_index
            status = StatusCode::Success
          end
        when DataOperationType::Modify
          if existing = @credentials[credential_key]?
            affected_user_index = existing.user_index
            if aliro_credential_type?(request.credential.credential_type) &&
               @credentials.any? { |key, record| key != credential_key && aliro_credential_type?(record.credential.credential_type) && record.credential_data == request.credential_data }
              return set_credential_response(request, StatusCode::Duplicate)
            end
            remove_credential_from_user(existing)

            existing.credential_data = request.credential_data.dup
            if new_user_index = request.user_index
              ensure_user_exists(new_user_index, request.user_status, request.user_type)
              unless @users.has_key?(new_user_index)
                add_credential_to_user(existing)
                return set_credential_response(request, StatusCode::ResourceExhausted)
              end

              if user = @users[new_user_index]?
                if !credential_belongs_to_user?(user, request.credential) && user.credentials.size >= @number_of_credentials_supported_per_user
                  add_credential_to_user(existing)
                  return set_credential_response(request, StatusCode::ResourceExhausted)
                end
              end
              existing.user_index = new_user_index
              affected_user_index = new_user_index
            end
            existing.last_modified_fabric_index = @request_fabric_index
            @credentials[credential_key] = existing
            add_credential_to_user(existing)
            status = StatusCode::Success
          else
            status = StatusCode::NotFound
          end
        when DataOperationType::Clear
          if existing = @credentials.delete(credential_key)
            affected_user_index = existing.user_index
            remove_credential_from_user(existing)
            status = StatusCode::Success
          else
            status = StatusCode::NotFound
          end
        else
          status = StatusCode::InvalidField
        end

        if status == StatusCode::Success
          increment_version
          if aliro_credential_type?(request.credential.credential_type)
            emit_aliro_wire_user_change(request.credential, request.operation_type, affected_user_index)
          end
        end

        set_credential_response(request, status, created_user_index)
      end

      def get_credential_status(request : GetCredentialStatusRequest) : GetCredentialStatusResponse
        unless credential_index_supported?(request.credential)
          return GetCredentialStatusResponse.new(
            credential_exists: false,
            user_index: nil,
            creator_fabric_index: nil,
            last_modified_fabric_index: nil,
            next_credential_index: nil
          )
        end

        next_index = next_occupied_credential_index(request.credential.credential_type, request.credential.credential_index)

        if credential = @credentials[credential_key(request.credential)]?
          GetCredentialStatusResponse.new(
            credential_exists: true,
            user_index: credential.user_index,
            creator_fabric_index: credential.creator_fabric_index,
            last_modified_fabric_index: credential.last_modified_fabric_index,
            next_credential_index: next_index,
            credential_data: aliro_credential_type?(credential.credential.credential_type) ? credential.credential_data.dup : nil
          )
        else
          GetCredentialStatusResponse.new(
            credential_exists: false,
            user_index: nil,
            creator_fabric_index: nil,
            last_modified_fabric_index: nil,
            next_credential_index: next_index
          )
        end
      end

      def handle_get_credential_status(request : GetCredentialStatusRequest) : TLV::Serializable
        response = get_credential_status(request)
        if @feature_map.aliro_provisioning? && aliro_credential_type?(request.credential.credential_type)
          AliroGetCredentialStatusResponse.new(response)
        else
          response
        end
      end

      def clear_credential(request : ClearCredentialRequest) : InteractionModel::Status
        if credential = request.credential
          unless credential_type_supported?(credential.credential_type) &&
                 (credential.credential_index == ALL_USERS || credential_index_supported?(credential))
            return InteractionModel::Status.cluster_failure(StatusCode::InvalidField)
          end

          if credential.credential_index == ALL_USERS
            keys_to_clear = @credentials.keys.select { |(type, _)| type == credential.credential_type.value.to_u8 }
            keys_to_clear.each do |key|
              if existing = @credentials.delete(key)
                remove_credential_from_user(existing)
                emit_aliro_wire_user_change(existing.credential, DataOperationType::Clear, existing.user_index)
              end
            end
          else
            key = credential_key(credential)
            if existing = @credentials.delete(key)
              remove_credential_from_user(existing)
              emit_aliro_wire_user_change(existing.credential, DataOperationType::Clear, existing.user_index)
            end
          end
        else
          @credentials.keys.each do |key|
            if record = @credentials[key]?
              next unless credential_type_supported?(record.credential.credential_type)
              @credentials.delete(key)
              remove_credential_from_user(record)
              emit_aliro_wire_user_change(record.credential, DataOperationType::Clear, record.user_index)
            end
          end
        end

        increment_version
        InteractionModel::Status.success
      end

      # ------------------------------------------------------------------------
      # Response builders
      # ------------------------------------------------------------------------

      private def week_day_schedule_response(request : GetWeekDayScheduleRequest, status : StatusCode, schedule : WeekDaySchedule? = nil) : GetWeekDayScheduleResponse
        GetWeekDayScheduleResponse.new(
          week_day_index: request.week_day_index,
          user_index: request.user_index,
          status_code: status,
          week_day: schedule.try(&.week_day) || 0_u8,
          start_hour: schedule.try(&.start_hour) || 0_u8,
          start_minute: schedule.try(&.start_minute) || 0_u8,
          end_hour: schedule.try(&.end_hour) || 0_u8,
          end_minute: schedule.try(&.end_minute) || 0_u8
        )
      end

      private def year_day_schedule_response(request : GetYearDayScheduleRequest, status : StatusCode, schedule : YearDaySchedule? = nil) : GetYearDayScheduleResponse
        GetYearDayScheduleResponse.new(
          year_day_index: request.year_day_index,
          user_index: request.user_index,
          status_code: status,
          local_start_time: schedule.try(&.local_start_time) || 0_u32,
          local_end_time: schedule.try(&.local_end_time) || 0_u32
        )
      end

      private def holiday_schedule_response(request : GetHolidayScheduleRequest, status : StatusCode, schedule : HolidaySchedule? = nil) : GetHolidayScheduleResponse
        GetHolidayScheduleResponse.new(
          holiday_index: request.holiday_index,
          status_code: status,
          local_start_time: schedule.try(&.local_start_time) || 0_u32,
          local_end_time: schedule.try(&.local_end_time) || 0_u32,
          operating_mode: schedule.try(&.operating_mode) || OperatingMode::Normal
        )
      end

      private def vacant_user_response(user_index : UInt16, next_user_index : UInt16?) : GetUserResponse
        GetUserResponse.new(
          user_index: user_index,
          user_name: nil,
          user_unique_id: nil,
          user_status: UserStatus::Available,
          user_type: nil,
          credential_rule: nil,
          credentials: nil,
          creator_fabric_index: nil,
          last_modified_fabric_index: nil,
          next_user_index: next_user_index
        )
      end

      private def set_credential_response(request : SetCredentialRequest, status : StatusCode, user_index : UInt16? = nil) : SetCredentialResponse
        SetCredentialResponse.new(
          status_code: status,
          user_index: user_index,
          next_credential_index: next_available_credential_index(request.credential.credential_type, request.credential.credential_index)
        )
      end

      # ------------------------------------------------------------------------
      # Remote operation policy
      # ------------------------------------------------------------------------

      private def remote_control_allowed? : Bool
        return false unless @actuator_enabled
        mode = effective_operating_mode
        return false if mode.no_remote_lock_unlock? || mode.privacy?
        return false if lockout_active

        true
      end

      private def effective_operating_mode : OperatingMode
        return @operating_mode unless now = local_schedule_time

        # Holiday schedules are lock-wide. A lower index wins if intervals overlap.
        @holiday_schedules.keys.sort!.each do |index|
          schedule = @holiday_schedules[index]
          if now.epoch_seconds >= schedule.local_start_time && now.epoch_seconds <= schedule.local_end_time
            return schedule.operating_mode
          end
        end
        @operating_mode
      end

      def read_attribute(attribute_id : UInt32, fabric_index : UInt8? = nil) : InteractionModel::Status | TLV::Any
        return tlv(effective_operating_mode.value) if attribute_id == ATTR_OPERATING_MODE
        super
      end

      private def local_schedule_time : LocalScheduleTime?
        time = @local_time_provider.call
        return unless time

        # Matter's local schedule timestamps encode wall-clock fields as Unix
        # seconds after applying the local timezone and DST offset.
        epoch = Time.utc(time.year, time.month, time.day, time.hour, time.minute, time.second).to_unix
        LocalScheduleTime.new(epoch, (1_u8 << time.day_of_week.value).to_u8, time.hour * MINUTES_PER_HOUR + time.minute)
      end

      private def valid_week_day_schedule?(schedule : WeekDaySchedule) : Bool
        return false unless (schedule.week_day & ~WEEK_DAY_MASK).zero?
        return false if schedule.start_hour > LAST_HOUR_OF_DAY || schedule.end_hour > LAST_HOUR_OF_DAY
        return false if schedule.start_minute > LAST_MINUTE_OF_HOUR || schedule.end_minute > LAST_MINUTE_OF_HOUR
        return false if schedule.end_hour < schedule.start_hour
        return false if schedule.end_hour == schedule.start_hour && schedule.end_minute <= schedule.start_minute

        true
      end

      private def week_day_schedule_matches?(schedule : WeekDaySchedule, now : LocalScheduleTime) : Bool
        return false if (schedule.week_day & now.day_mask).zero?

        start_minute = schedule.start_hour.to_i32 * MINUTES_PER_HOUR + schedule.start_minute
        end_minute = schedule.end_hour.to_i32 * MINUTES_PER_HOUR + schedule.end_minute
        now.minute_of_day >= start_minute && (now.minute_of_day < end_minute || end_minute == LAST_MINUTE_OF_DAY)
      end

      private def year_day_schedule_matches?(schedule : YearDaySchedule, now : LocalScheduleTime) : Bool
        now.epoch_seconds >= schedule.local_start_time && now.epoch_seconds <= schedule.local_end_time
      end

      private def schedule_allows_user?(user : UserRecord) : Bool
        case user.user_type
        when UserType::WeekDayScheduleUser, UserType::YearDayScheduleUser, UserType::ScheduleRestrictedUser
          now = local_schedule_time
          return false unless now

          week_days = @week_day_schedules.select { |(user_index, _), _| user_index == user.user_index }.values
          year_days = @year_day_schedules.select { |(user_index, _), _| user_index == user.user_index }.values
          week_day_match = week_days.any? { |schedule| week_day_schedule_matches?(schedule, now) }
          year_day_match = year_days.any? { |schedule| year_day_schedule_matches?(schedule, now) }

          case user.user_type
          when UserType::WeekDayScheduleUser
            week_day_match
          when UserType::YearDayScheduleUser
            year_day_match
          else
            return false if week_days.empty? && year_days.empty?
            return week_day_match if year_days.empty?
            return year_day_match if week_days.empty?
            week_day_match && year_day_match
          end
        else
          true
        end
      end

      private def lockout_active : Bool
        if until_time = @lockout_until
          return Time.utc < until_time
        end

        false
      end

      private def authorize_remote_operation(pin : String?, operation : LockOperationType, source : OperationSource) : Authorization
        requires_pin = @feature_map.pin_credential? && @feature_map.credential_over_the_air_access? && @require_pin_for_remote_operation

        if requires_pin
          pin_value = pin
          if pin_value.nil? || pin_value.empty?
            report_lock_operation_error(operation, source, OperationError::InvalidCredential)
            return Authorization.new(InteractionModel::Status.cluster_failure(StatusCode::InvalidField))
          end
          return authorize_pin(pin_value, operation, source)
        end

        if pin && !pin.empty? && @feature_map.pin_credential?
          return authorize_pin(pin, operation, source)
        end

        Authorization.new
      end

      private def authorize_pin(pin : String, operation : LockOperationType, source : OperationSource) : Authorization
        match = pin_authorization(pin)
        authorization = Authorization.new(nil, match.user_index, match.credential)
        case match.result
        when PinAuthorization::Allowed
          clear_failed_pin_state
          authorization
        when PinAuthorization::Invalid
          record_failed_pin_attempt
          report_lock_operation_error(operation, source, OperationError::InvalidCredential)
          Authorization.new(InteractionModel::Status.cluster_failure(StatusCode::InvalidField))
        when PinAuthorization::Restricted
          report_lock_operation_error(operation, source, match.error || OperationError::Restricted, authorization)
          Authorization.new(InteractionModel::Status.cluster_failure(StatusCode::Failure), match.user_index, match.credential)
        else
          Authorization.new(InteractionModel::Status.cluster_failure(StatusCode::Failure))
        end
      end

      private def pin_authorization(pin : String) : PinMatch
        return PinMatch.new(PinAuthorization::Allowed) if pin == @default_pin_code

        recognized = false
        restricted : PinMatch? = nil
        @credentials.values.each do |credential|
          next unless credential.credential.credential_type.pin? && String.new(credential.credential_data) == pin
          recognized = true
          user_index = credential.user_index
          next unless user_index
          user = @users[user_index]?
          next unless user
          context = PinMatch.new(PinAuthorization::Restricted, user_index, credential.credential)
          if user.user_status != UserStatus::OccupiedEnabled || expire_user_if_due(user_index)
            restricted ||= PinMatch.new(PinAuthorization::Restricted, user_index, credential.credential, OperationError::DisabledUserDenied)
            next
          end
          if user.user_type.non_access_user? || !schedule_allows_user?(user) || (user.user_type.expiring_user? && !@local_time_provider.call)
            restricted ||= context
            next
          end
          return PinMatch.new(PinAuthorization::Allowed, user_index, credential.credential)
        end
        restricted || PinMatch.new(recognized ? PinAuthorization::Restricted : PinAuthorization::Invalid)
      end

      private def start_user_expiry(user_index : UInt16) : Nil
        now = @local_time_provider.call
        return unless now
        user = @users[user_index]?
        return unless user && user.user_type.expiring_user? && user.user_status.occupied_enabled?
        return if user.expiring_user_expires_at

        deadline = now + @expiring_user_timeout.minutes
        user.expiring_user_expires_at = deadline
        @users[user_index] = user
        increment_version
        arm_user_expiry(user_index, deadline)
      end

      private def arm_user_expiry(user_index : UInt16, deadline : Time) : Nil
        now = @local_time_provider.call
        return unless now
        remaining = deadline - now
        return if remaining <= 0.seconds

        generation = (@user_expiry_generations[user_index]? || 0_u64) &+ 1_u64
        @user_expiry_generations[user_index] = generation
        spawn do
          sleep remaining
          expire_user_if_due(user_index) if @user_expiry_generations[user_index]? == generation
        end
      end

      private def cancel_user_expiry(user_index : UInt16) : Nil
        @user_expiry_generations[user_index] = (@user_expiry_generations[user_index]? || 0_u64) &+ 1_u64
      end

      private def expire_user_if_due(user_index : UInt16) : Bool
        user = @users[user_index]?
        return false unless user && user.user_type.expiring_user? && user.user_status.occupied_enabled?
        deadline = user.expiring_user_expires_at
        return false unless deadline
        now = @local_time_provider.call
        return false unless now && now >= deadline

        disable_user(user_index)
        true
      end

      private def disable_user(user_index : UInt16) : Nil
        user = @users[user_index]?
        return unless user && user.user_status.occupied_enabled?
        user.user_status = UserStatus::OccupiedDisabled
        @users[user_index] = user
        cancel_user_expiry(user_index)
        increment_version
        emit_lock_user_change(Events::LockUserChange.new(
          lock_data_type: LockDataType::UserIndex,
          data_operation_type: DataOperationType::Modify,
          operation_source: OperationSource::Unspecified,
          user_index: user_index,
          data_index: user_index
        ))
      end

      private def record_failed_pin_attempt : Nil
        if @failed_remote_pin_attempts < UInt8::MAX
          @failed_remote_pin_attempts = @failed_remote_pin_attempts &+ 1_u8
        end

        if @failed_remote_pin_attempts >= @wrong_code_entry_limit
          @failed_remote_pin_attempts = 0_u8
          @lockout_until = Time.utc + @user_code_temporary_disable_time.seconds
        end
      end

      private def clear_failed_pin_state : Nil
        @failed_remote_pin_attempts = 0_u8
        @lockout_until = nil
      end

      # Relocks after *after_seconds* unless a later lock operation superseded it
      private def schedule_relock(after_seconds : UInt32) : Nil
        return if after_seconds == 0_u32

        @relock_generation = @relock_generation &+ 1_u64
        generation = @relock_generation

        spawn do
          sleep after_seconds.seconds
          next unless generation == @relock_generation

          self.lock_state = LockState::Locked
        end
      end

      private def cancel_pending_relock : Nil
        @relock_generation = @relock_generation &+ 1_u64
      end

      # ------------------------------------------------------------------------
      # User / credential tables
      # ------------------------------------------------------------------------

      private def ensure_user_exists(user_index : UInt16, status : UserStatus?, user_type : UserType?) : Nil
        return if @users.has_key?(user_index)
        return unless valid_user_index?(user_index)
        return if @users.size >= @number_of_total_users_supported

        @users[user_index] = UserRecord.new(
          user_index: user_index,
          user_name: "",
          user_unique_id: user_index.to_u32,
          user_status: status || UserStatus::OccupiedEnabled,
          user_type: user_type || UserType::UnrestrictedUser,
          credential_rule: CredentialRule::Single,
          credentials: [] of Credential,
          creator_fabric_index: @request_fabric_index,
          last_modified_fabric_index: @request_fabric_index
        )
      end

      private def clear_user_record(user_index : UInt16) : Nil
        cancel_user_expiry(user_index)
        @users.delete(user_index)

        @credentials.keys.select { |key| @credentials[key]?.try(&.user_index) == user_index }.each do |key|
          @credentials.delete(key)
        end

        @week_day_schedules.keys.select { |(target_user, _)| target_user == user_index }.each { |key| @week_day_schedules.delete(key) }
        @year_day_schedules.keys.select { |(target_user, _)| target_user == user_index }.each { |key| @year_day_schedules.delete(key) }
      end

      private def credential_belongs_to_user?(user : UserRecord, credential : Credential) : Bool
        user.credentials.any? do |existing|
          existing.credential_type == credential.credential_type && existing.credential_index == credential.credential_index
        end
      end

      private def add_credential_to_user(record : CredentialRecord, fabric_index : UInt8? = @request_fabric_index) : Nil
        return unless user_index = record.user_index
        return unless user = @users[user_index]?

        unless credential_belongs_to_user?(user, record.credential)
          user.credentials << record.credential
          user.last_modified_fabric_index = fabric_index
          @users[user_index] = user
        end
      end

      private def remove_credential_from_user(record : CredentialRecord, fabric_index : UInt8? = @request_fabric_index) : Nil
        return unless user_index = record.user_index
        return unless user = @users[user_index]?

        user.credentials = user.credentials.reject do |credential|
          credential.credential_type == record.credential.credential_type && credential.credential_index == record.credential.credential_index
        end
        user.last_modified_fabric_index = fabric_index

        @users[user_index] = user
      end

      private def validate_credential_input(credential : Credential, credential_data : Bytes, *, allow_aliro : Bool = false) : StatusCode?
        return StatusCode::InvalidField unless credential_index_supported?(credential, allow_aliro: allow_aliro)

        case credential.credential_type
        when CredentialType::ProgrammingPin
          return StatusCode::InvalidField unless @feature_map.pin_credential?
          return StatusCode::InvalidField unless credential.credential_index == PROGRAMMING_PIN_INDEX
          return StatusCode::InvalidField if credential_data.empty?
        when CredentialType::Pin
          return StatusCode::InvalidField unless @feature_map.pin_credential?
          return StatusCode::InvalidField unless credential_data.size.in?(@min_pin_code_length..@max_pin_code_length)
        when CredentialType::Rfid
          return StatusCode::InvalidField unless @feature_map.rfid_credential?
          return StatusCode::InvalidField unless credential_data.size.in?(@min_rfid_code_length..@max_rfid_code_length)
        when CredentialType::Fingerprint, CredentialType::FingerVein
          return StatusCode::InvalidField unless @feature_map.finger_credentials?
        when CredentialType::Face
          return StatusCode::InvalidField unless @feature_map.face_credentials?
        when CredentialType::AliroCredentialIssuerKey,
             CredentialType::AliroEvictableEndpointKey,
             CredentialType::AliroNonEvictableEndpointKey
          return StatusCode::InvalidField unless (allow_aliro || @feature_map.aliro_provisioning?) && valid_aliro_public_key?(credential_data)
        else
          return StatusCode::InvalidField
        end

        nil
      end

      private def credential_key(credential : Credential) : Tuple(UInt8, UInt16)
        {credential.credential_type.value.to_u8, credential.credential_index}
      end

      private def next_available_credential_index(type : CredentialType, current_index : UInt16) : UInt16?
        max_index = max_credential_index(type)
        index = current_index + 1

        while index <= max_index
          return index unless @credentials.has_key?({type.value.to_u8, index})
          index += 1
        end

        nil
      end

      private def next_occupied_credential_index(type : CredentialType, current_index : UInt16) : UInt16?
        @credentials.keys
          .select { |(credential_type, credential_index)| credential_type == type.value.to_u8 && credential_index > current_index }
          .min_of?(&.[1])
      end

      private def max_credential_index(type : CredentialType) : UInt16
        case type
        when CredentialType::Pin
          @number_of_pin_users_supported
        when CredentialType::Rfid
          @number_of_rfid_users_supported
        when CredentialType::AliroCredentialIssuerKey
          @number_of_aliro_credential_issuer_keys_supported
        when CredentialType::AliroEvictableEndpointKey, CredentialType::AliroNonEvictableEndpointKey
          @number_of_aliro_endpoint_keys_supported
        else
          @number_of_total_users_supported
        end
      end

      private def valid_user_index?(user_index : UInt16) : Bool
        user_index >= 1_u16 && user_index <= @number_of_total_users_supported
      end

      private def valid_week_day_schedule_index?(schedule_index : UInt8) : Bool
        schedule_index >= 1_u8 && schedule_index <= @number_of_week_day_schedules_supported_per_user
      end

      private def valid_year_day_schedule_index?(schedule_index : UInt8) : Bool
        schedule_index >= 1_u8 && schedule_index <= @number_of_year_day_schedules_supported_per_user
      end

      private def valid_holiday_schedule_index?(schedule_index : UInt8) : Bool
        schedule_index >= 1_u8 && schedule_index <= @number_of_holiday_schedules_supported
      end

      private def credential_index_supported?(credential : Credential, *, allow_aliro : Bool = false) : Bool
        return false unless credential_type_supported?(credential.credential_type, allow_aliro: allow_aliro)
        return credential.credential_index == PROGRAMMING_PIN_INDEX if credential.credential_type.programming_pin?

        max = max_credential_index(credential.credential_type)
        credential.credential_index >= 1_u16 && credential.credential_index <= max
      end

      private def credential_type_supported?(credential_type : CredentialType, *, allow_aliro : Bool = false) : Bool
        case credential_type
        when CredentialType::ProgrammingPin, CredentialType::Pin
          @feature_map.pin_credential?
        when CredentialType::Rfid
          @feature_map.rfid_credential?
        when CredentialType::Fingerprint, CredentialType::FingerVein
          @feature_map.finger_credentials?
        when CredentialType::Face
          @feature_map.face_credentials?
        when CredentialType::AliroCredentialIssuerKey,
             CredentialType::AliroEvictableEndpointKey,
             CredentialType::AliroNonEvictableEndpointKey
          (allow_aliro || @feature_map.aliro_provisioning?) && @feature_map.user?
        else
          false
        end
      end

      private def pin_from_slice(pin_slice : Slice(UInt8)?) : String?
        return unless pin_slice
        String.new(pin_slice)
      end
    end
  end
end
