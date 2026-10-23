require "../cluster"

module Matter
  module Cluster
    class DoorLock < Base
      # The value of the DoorLock lockState attribute
      enum LockState : UInt8
        # Lock state is not fully locked
        NotFullyLocked = 0

        # Lock state is fully locked
        Locked = 1

        # Lock state is fully unlocked
        Unlocked = 2

        # Lock state is unlatched
        Unlatched = 3
      end

      # The value of the DoorLock lockType attribute
      enum LockType : UInt8
        # Physical lock type is dead bolt
        Deadbolt = 0

        # Physical lock type is magnetic
        Magnetic = 1

        # Physical lock type is other
        Other = 2

        # Physical lock type is mortise
        Mortise = 3

        # Physical lock type is rim
        Rim = 4

        # Physical lock type is latch bolt
        LatchBolt = 5

        # Physical lock type is cylindrical lock
        CylindricalLock = 6

        # Physical lock type is tubular lock
        TubularLock = 7

        # Physical lock type is interconnected lock
        InterconnectedLock = 8

        # Physical lock type is dead latch
        DeadLatch = 9

        # Physical lock type is door furniture
        DoorFurniture = 10
      end

      # The OperatingMode enumeration shall indicate the lock operating mode.
      #
      # The table below shows the operating mode and which interfaces are enabled, if supported, for each mode.
      #
      # Note: For modes that disable the remote interface, the door lock shall respond to Lock, Unlock, Toggle, and
      # Unlock with Timeout commands with a response status Failure and not take the action requested by those commands.
      # The door lock shall NOT disable the radio or otherwise unbind or leave the network. It shall still respond to
      # all other commands and requests.
      enum OperatingMode : UInt8
        # The lock operates normally. All interfaces are enabled.
        Normal = 0

        # Only remote interaction is enabled. The keypad shall only be operable by the master user.
        Vacation = 1

        # This mode is only possible if the door is locked. Manual unlocking changes the mode to Normal operating
        # mode. All external interaction with the door lock is disabled. This mode is intended to be used so that
        # users, presumably inside the property, will have control over the entrance.
        Privacy = 2

        # This mode only disables remote interaction with the lock. This does not apply to any remote proprietary
        # means of communication. It specifically applies to the Lock, Unlock, Toggle, and Unlock with Timeout
        # Commands.
        NoRemoteLockUnlock = 3

        # The lock is open or can be opened or closed at will without the use of a Keypad or other means of user
        # validation (e.g. a lock for a business during work hours).
        Passage = 4
      end

      # The Alarm Code enum shall indicate the alarm type.
      enum AlarmCode : UInt8
        # Locking Mechanism Jammed
        LockJammed = 0

        # Lock Reset to Factory Defaults
        LockFactoryReset = 1

        # Lock Radio Power Cycled
        LockRadioPowerCycled = 3

        # Tamper Alarm - wrong code entry limit
        WrongCodeEntryLimit = 4

        # Tamper Alarm - front escutcheon removed from main
        FrontEsceutcheonRemoved = 5

        # Forced Door Open under Door Locked Condition
        DoorForcedOpen = 6

        # Door ajar
        DoorAjar = 7

        # Force User SOS alarm
        ForcedUser = 8
      end

      # The LockOperationType enumeration shall indicate the type of Lock operation performed.
      enum LockOperationType : UInt8
        Lock               = 0
        Unlock             = 1
        NonAccessUserEvent = 2
        ForcedUserEvent    = 3
        Unlatch            = 4
      end

      # The OperationSource enumeration shall indicate the source of the Lock/Unlock operation performed.
      #
      # 5.2.6.14. PIN/RFID Code Format
      #
      # The PIN/RFID codes defined in this specification are all octet strings.
      #
      # All value in the PIN/RFID code shall be ASCII encoded regardless if the PIN/RFID codes are number or characters.
      # For example, code of “1, 2, 3, 4” shall be represented as 0x31, 0x32, 0x33, 0x34.
      enum OperationSource : UInt8
        Unspecified       =  0
        Manual            =  1
        ProprietaryRemote =  2
        Keypad            =  3
        Auto              =  4
        Button            =  5
        Schedule          =  6
        Remote            =  7
        Rfid              =  8
        Biometric         =  9
        Aliro             = 10
      end

      # The Credential Type enum shall indicate the credential type.
      enum CredentialType : UInt8
        ProgrammingPin               = 0
        Pin                          = 1
        Rfid                         = 2
        Fingerprint                  = 3
        FingerVein                   = 4
        Face                         = 5
        AliroCredentialIssuerKey     = 6
        AliroEvictableEndpointKey    = 7
        AliroNonEvictableEndpointKey = 8
      end

      # The OperationError enumeration shall indicate the error cause of the Lock/Unlock operation performed.
      enum OperationError : UInt8
        Unspecified         = 0
        InvalidCredential   = 1
        DisabledUserDenied  = 2
        Restricted          = 3
        InsufficientBattery = 4
      end

      # The DoorState enumeration shall indicate the current door state. The data type of the DoorState
      #
      # enum field is derived from enum8.
      enum DoorState : UInt8
        # Door state is open
        DoorOpen = 0

        # Door state is closed
        DoorClosed = 1

        # Door state is jammed
        DoorJammed = 2

        # Door state is currently forced open
        DoorForcedOpen = 3

        # Door state is invalid for unspecified reason
        DoorUnspecifiedError = 4

        # Door state is ajar
        DoorAjar = 5
      end

      # The DataOperationType enum shall indicate the data operation performed.
      enum DataOperationType : UInt8
        # Data is being added or was added
        Add = 0

        # Data is being cleared or was cleared
        Clear = 1

        # Data is being modified or was modified
        Modify = 2
      end

      # The UserStatus enum used in various commands shall indicate what the status is for a specific user ID.
      enum UserStatus : UInt8
        Available        = 0
        OccupiedEnabled  = 1
        OccupiedDisabled = 3
      end

      # The UserType enum used in various commands shall indicate what the type is for a specific user ID.
      enum UserType : UInt8
        # User has access 24/7 provided proper PIN or RFID is supplied (e.g., owner).
        UnrestrictedUser = 0

        # User has ability to open lock within a specific time period (e.g., guest).
        YearDayScheduleUser = 1

        # User has ability to open lock based on specific time period within a reoccurring weekly schedule (e.g.,
        # cleaning worker).
        WeekDayScheduleUser = 2

        # User has ability to both program and operate the door lock. This user can manage the users and user
        # schedules. In all other respects this user matches the unrestricted (default) user. ProgrammingUser is the
        # only user that can disable the user interface (keypad, remote, etc…).
        ProgrammingUser = 3

        # User is recognized by the lock but does not have the ability to open the lock. This user will only cause the
        # lock to generate the appropriate event notification to any bound devices.
        NonAccessUser = 4

        # User has ability to open lock but a ForcedUser LockOperationType and ForcedUser silent alarm will be emitted
        # to allow a notified Node to alert emergency services or contacts on the user account when used.
        ForcedUser = 5

        # User has ability to open lock once after which the lock shall change the corresponding user record
        # UserStatus value to OccupiedDisabled automatically.
        DisposableUser = 6

        # User has ability to open lock for ExpiringUserTimeout attribute minutes after the first use of the PIN code,
        # RFID code, Fingerprint, or other credential. After ExpiringUserTimeout minutes the corresponding user record
        # UserStatus value shall be set to OccupiedDisabled automatically by the lock. The lock shall persist the
        # timeout across reboots such that the ExpiringUserTimeout is honored.
        ExpiringUser = 7

        # User access is restricted by Week Day and/or Year Day schedule.
        ScheduleRestrictedUser = 8

        # User access and PIN code is restricted to remote lock/unlock commands only. This type of user might be
        # useful for regular delivery services or voice assistant unlocking operations to prevent a PIN code
        # credential created for them from being used at the keypad. The PIN code credential would only be provided
        # over-the-air for the lock/unlock commands.
        RemoteOnlyUser = 9
      end

      # The CredentialRule enum used in various commands shall indicate the credential rule that can be applied to a
      # particular user.
      enum CredentialRule : UInt8
        Single = 0
        Dual   = 1
        Tri    = 2
      end

      enum StatusCode : UInt8
        Success           =   0
        Failure           =   1
        Duplicate         =   2
        Occupied          =   3
        InvalidField      = 133
        ResourceExhausted = 137
        NotFound          = 139
      end

      # The LockDataType enum shall indicate the data type that is being or has changed.
      enum LockDataType : UInt8
        # Unspecified or manufacturer specific lock user data added, cleared, or modified.
        Unspecified = 0

        # Lock programming PIN code was added, cleared, or modified.
        ProgrammingCode = 1

        # Lock user index was added, cleared, or modified.
        UserIndex = 2

        # Lock user week day schedule was added, cleared, or modified.
        WeekDaySchedule = 3

        # Lock user year day schedule was added, cleared, or modified.
        YearDaySchedule = 4

        # Lock holiday schedule was added, cleared, or modified.
        HolidaySchedule = 5

        # Lock user PIN code was added, cleared, or modified.
        Pin = 6

        # Lock user RFID code was added, cleared, or modified.
        Rfid = 7

        # Lock user fingerprint was added, cleared, or modified.
        Fingerprint = 8

        # Lock user finger-vein information was added, cleared, or modified.
        FingerVein = 9

        # Lock user face information was added, cleared, or modified.
        Face = 10

        # Lock Aliro Credential Issuer key was added, cleared, or modified.
        AliroCredentialIssuerKey = 11

        # Lock Aliro evictable endpoint key was added, cleared, or modified.
        AliroEvictableEndpointKey = 12

        # Lock Aliro non-evictable endpoint key was added, cleared, or modified.
        AliroNonEvictableEndpointKey = 13
      end

      # Input to the DoorLock lockDoor command
      struct LockDoorRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property pin_code : Slice(UInt8)?

        def initialize(@pin_code : Slice(UInt8)? = nil)
        end
      end

      # Input to the DoorLock unlockDoor command
      struct UnlockDoorRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property pin_code : Slice(UInt8)?

        def initialize(@pin_code : Slice(UInt8)? = nil)
        end
      end

      # Input to the DoorLock unlockWithTimeout command
      struct UnlockWithTimeoutRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property timeout : UInt16

        @[TLV::Field(tag: 1)]
        property pin_code : Slice(UInt8)?

        def initialize(@timeout : UInt16, @pin_code : Slice(UInt8)? = nil)
        end
      end

      # Input to the DoorLock unboltDoor command
      struct UnboltDoorRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property pin_code : Slice(UInt8)?

        def initialize(@pin_code : Slice(UInt8)? = nil)
        end
      end

      struct Credential
        include TLV::Serializable
        include Storage::Record

        # The credential type used to authorize the lock operation.
        @[TLV::Field(tag: 0)]
        property credential_type : CredentialType

        # This is the index of the specific credential used to authorize the lock operation in the list of credentials
        # identified by CredentialType (e.g. schedule, PIN, RFID, etc.). This shall be set to 0 if CredentialType is
        # ProgrammingPIN or does not correspond to a list that can be indexed into.
        @[TLV::Field(tag: 1)]
        property credential_index : UInt16

        def initialize(@credential_type : CredentialType, @credential_index : UInt16)
        end
      end

      # Input to the DoorLock setUser command
      struct SetUserRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property operation_type : DataOperationType

        @[TLV::Field(tag: 1)]
        property user_index : UInt16

        @[TLV::Field(tag: 2)]
        property user_name : String?

        @[TLV::Field(tag: 3)]
        property user_unique_id : UInt32?

        @[TLV::Field(tag: 4)]
        property user_status : UserStatus?

        @[TLV::Field(tag: 5)]
        property user_type : UserType?

        @[TLV::Field(tag: 6)]
        property credential_rule : CredentialRule?

        def initialize(
          @operation_type : DataOperationType,
          @user_index : UInt16,
          @user_name : String? = nil,
          @user_unique_id : UInt32? = nil,
          @user_status : UserStatus? = nil,
          @user_type : UserType? = nil,
          @credential_rule : CredentialRule? = nil,
        )
        end
      end

      # Input to the DoorLock getUser command
      struct GetUserRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property user_index : UInt16

        def initialize(@user_index : UInt16)
        end
      end

      struct GetUserResponse
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property user_index : UInt16

        @[TLV::Field(tag: 1)]
        property user_name : String?

        @[TLV::Field(tag: 2)]
        property user_unique_id : UInt32?

        @[TLV::Field(tag: 3)]
        property user_status : UserStatus?

        @[TLV::Field(tag: 4)]
        property user_type : UserType?

        @[TLV::Field(tag: 5)]
        property credential_rule : CredentialRule?

        @[TLV::Field(tag: 6)]
        property credentials : Array(Credential)?

        @[TLV::Field(tag: 7)]
        property creator_fabric_index : UInt8?

        @[TLV::Field(tag: 8)]
        property last_modified_fabric_index : UInt8?

        @[TLV::Field(tag: 9)]
        property next_user_index : UInt16?

        def initialize(
          @user_index : UInt16,
          @user_name : String? = nil,
          @user_unique_id : UInt32? = nil,
          @user_status : UserStatus? = nil,
          @user_type : UserType? = nil,
          @credential_rule : CredentialRule? = nil,
          @credentials : Array(Credential)? = nil,
          @creator_fabric_index : UInt8? = nil,
          @last_modified_fabric_index : UInt8? = nil,
          @next_user_index : UInt16? = nil,
        )
        end
      end

      # Input to the DoorLock clearUser command
      struct ClearUserRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property user_index : UInt16

        def initialize(@user_index : UInt16)
        end
      end

      # Input to the DoorLock setCredential command
      struct SetCredentialRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property operation_type : DataOperationType

        @[TLV::Field(tag: 1)]
        property credential : Credential

        @[TLV::Field(tag: 2)]
        property credential_data : Slice(UInt8)

        @[TLV::Field(tag: 3)]
        property user_index : UInt16?

        @[TLV::Field(tag: 4)]
        property user_status : UserStatus?

        @[TLV::Field(tag: 5)]
        property user_type : UserType

        def initialize(
          @operation_type : DataOperationType,
          @credential : Credential,
          @credential_data : Slice(UInt8),
          @user_index : UInt16? = nil,
          @user_status : UserStatus? = nil,
          @user_type : UserType = UserType::UnrestrictedUser,
        )
        end
      end

      struct SetCredentialResponse
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property status_code : StatusCode

        @[TLV::Field(tag: 1)]
        property user_index : UInt16?

        @[TLV::Field(tag: 2)]
        property next_credential_index : UInt16?

        def initialize(
          @status_code : StatusCode,
          @user_index : UInt16? = nil,
          @next_credential_index : UInt16? = nil,
        )
        end
      end

      # Input to the DoorLock getCredentialStatus command
      struct GetCredentialStatusRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property credential : Credential

        def initialize(@credential : Credential)
        end
      end

      struct GetCredentialStatusResponse
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property? credential_exists : Bool

        @[TLV::Field(tag: 1)]
        property user_index : UInt16?

        @[TLV::Field(tag: 2)]
        property creator_fabric_index : UInt8?

        @[TLV::Field(tag: 3)]
        property last_modified_fabric_index : UInt8?

        @[TLV::Field(tag: 4)]
        property next_credential_index : UInt16?

        def initialize(
          @credential_exists : Bool,
          @user_index : UInt16? = nil,
          @creator_fabric_index : UInt8? = nil,
          @last_modified_fabric_index : UInt8? = nil,
          @next_credential_index : UInt16? = nil,
        )
        end
      end

      # Input to the DoorLock clearCredential command
      struct ClearCredentialRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property credential : Credential?

        def initialize(@credential : Credential? = nil)
        end
      end

      # Input to the DoorLock setWeekDaySchedule command
      struct SetWeekDayScheduleRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property week_day_index : UInt8

        @[TLV::Field(tag: 1)]
        property user_index : UInt16

        @[TLV::Field(tag: 2)]
        property week_day : UInt8

        @[TLV::Field(tag: 3)]
        property start_hour : UInt8

        @[TLV::Field(tag: 4)]
        property start_minute : UInt8

        @[TLV::Field(tag: 5)]
        property end_hour : UInt8

        @[TLV::Field(tag: 6)]
        property end_minute : UInt8

        def initialize(
          @week_day_index : UInt8,
          @user_index : UInt16,
          @week_day : UInt8,
          @start_hour : UInt8,
          @start_minute : UInt8,
          @end_hour : UInt8,
          @end_minute : UInt8,
        )
        end
      end

      # Input to the DoorLock getWeekDaySchedule command
      struct GetWeekDayScheduleRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property week_day_index : UInt8

        @[TLV::Field(tag: 1)]
        property user_index : UInt16

        def initialize(@week_day_index : UInt8, @user_index : UInt16)
        end
      end

      struct GetWeekDayScheduleResponse
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property week_day_index : UInt8

        @[TLV::Field(tag: 1)]
        property user_index : UInt16

        @[TLV::Field(tag: 2)]
        property status_code : StatusCode

        @[TLV::Field(tag: 3)]
        property week_day : UInt8

        @[TLV::Field(tag: 4)]
        property start_hour : UInt8

        @[TLV::Field(tag: 5)]
        property start_minute : UInt8

        @[TLV::Field(tag: 6)]
        property end_hour : UInt8

        @[TLV::Field(tag: 7)]
        property end_minute : UInt8

        def initialize(
          @week_day_index : UInt8,
          @user_index : UInt16,
          @status_code : StatusCode,
          @week_day : UInt8,
          @start_hour : UInt8,
          @start_minute : UInt8,
          @end_hour : UInt8,
          @end_minute : UInt8,
        )
        end
      end

      # Input to the DoorLock clearWeekDaySchedule command
      struct ClearWeekDayScheduleRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property week_day_index : UInt8

        @[TLV::Field(tag: 1)]
        property user_index : UInt16

        def initialize(@week_day_index : UInt8, @user_index : UInt16)
        end
      end

      # Input to the DoorLock setYearDaySchedule command
      struct SetYearDayScheduleRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property year_day_index : UInt8

        @[TLV::Field(tag: 1)]
        property user_index : UInt16

        @[TLV::Field(tag: 2)]
        property local_start_time : UInt32

        @[TLV::Field(tag: 3)]
        property local_end_time : UInt32

        def initialize(
          @year_day_index : UInt8,
          @user_index : UInt16,
          @local_start_time : UInt32,
          @local_end_time : UInt32,
        )
        end
      end

      # Input to the DoorLock getYearDaySchedule command
      struct GetYearDayScheduleRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property year_day_index : UInt8

        @[TLV::Field(tag: 1)]
        property user_index : UInt16

        def initialize(@year_day_index : UInt8, @user_index : UInt16)
        end
      end

      struct GetYearDayScheduleResponse
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property year_day_index : UInt8

        @[TLV::Field(tag: 1)]
        property user_index : UInt16

        @[TLV::Field(tag: 2)]
        property status_code : StatusCode

        @[TLV::Field(tag: 3)]
        property local_start_time : UInt32

        @[TLV::Field(tag: 4)]
        property local_end_time : UInt32

        def initialize(
          @year_day_index : UInt8,
          @user_index : UInt16,
          @status_code : StatusCode,
          @local_start_time : UInt32,
          @local_end_time : UInt32,
        )
        end
      end

      # Input to the DoorLock clearYearDaySchedule command
      struct ClearYearDayScheduleRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property year_day_index : UInt8

        @[TLV::Field(tag: 1)]
        property user_index : UInt16

        def initialize(@year_day_index : UInt8, @user_index : UInt16)
        end
      end

      # Input to the DoorLock setHolidaySchedule command
      struct SetHolidayScheduleRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property holiday_index : UInt8

        @[TLV::Field(tag: 1)]
        property local_start_time : UInt32

        @[TLV::Field(tag: 2)]
        property local_end_time : UInt32

        @[TLV::Field(tag: 3)]
        property operating_mode : OperatingMode

        def initialize(
          @holiday_index : UInt8,
          @local_start_time : UInt32,
          @local_end_time : UInt32,
          @operating_mode : OperatingMode,
        )
        end
      end

      struct GetHolidayScheduleRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property holiday_index : UInt8

        def initialize(@holiday_index : UInt8)
        end
      end

      struct GetHolidayScheduleResponse
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property holiday_index : UInt8

        @[TLV::Field(tag: 1)]
        property status_code : StatusCode

        @[TLV::Field(tag: 2)]
        property local_start_time : UInt32

        @[TLV::Field(tag: 3)]
        property local_end_time : UInt32

        @[TLV::Field(tag: 4)]
        property operating_mode : OperatingMode

        def initialize(
          @holiday_index : UInt8,
          @status_code : StatusCode,
          @local_start_time : UInt32,
          @local_end_time : UInt32,
          @operating_mode : OperatingMode,
        )
        end
      end

      # Input to the DoorLock clearHolidaySchedule command
      struct ClearHolidayScheduleRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property holiday_index : UInt8

        def initialize(@holiday_index : UInt8)
        end
      end

      module Events
        # Body of the DoorLock doorLockAlarm event
        struct DoorLockAlarm
          include TLV::Serializable

          @[TLV::Field(tag: 0)]
          property alarm_code : AlarmCode
        end

        # Body of the DoorLock lockOperation event
        struct LockOperation
          include TLV::Serializable

          # The type of the lock operation that was performed.
          @[TLV::Field(tag: 0)]
          property lock_operation_type : LockOperationType

          # The source of the lock operation that was performed.
          @[TLV::Field(tag: 1)]
          property operation_source : OperationSource

          # The lock UserIndex who performed the lock operation. This shall be null if there is no user index that can
          # be determined for the given operation source. This shall NOT be null if a user index can be determined. In
          # particular, this shall NOT be null if the operation was associated with a valid credential.
          @[TLV::Field(tag: 2)]
          property user_index : UInt16?

          # The fabric index of the fabric that performed the lock operation. This shall be null if there is no fabric
          # that can be determined for the given operation source. This shall NOT be null if the operation source is
          # "Remote".
          @[TLV::Field(tag: 3)]
          property fabric_index : UInt8?

          # The Node ID of the node that performed the lock operation. This shall be null if there is no Node associated
          # with the given operation source. This shall NOT be null if the operation source is "Remote".
          @[TLV::Field(tag: 4)]
          property source_node : UInt64?

          # The list of credentials used in performing the lock operation. This shall be null if no credentials were
          # involved.
          @[TLV::Field(tag: 5)]
          property credentials : Array(Credential)?

          def initialize(
            @lock_operation_type : LockOperationType,
            @operation_source : OperationSource,
            @user_index : UInt16? = nil,
            @fabric_index : UInt8? = nil,
            @source_node : UInt64? = nil,
            @credentials : Array(Credential)? = nil,
          )
          end
        end

        # Body of the DoorLock lockOperationError event
        struct LockOperationError
          include TLV::Serializable

          # The type of the lock operation that was performed.
          @[TLV::Field(tag: 0)]
          property lock_operation_type : LockOperationType

          # The source of the lock operation that was performed.
          @[TLV::Field(tag: 1)]
          property operation_source : OperationSource

          @[TLV::Field(tag: 2)]
          property operation_error : OperationError

          # The lock UserIndex who performed the lock operation. This shall be null if there is no user index that can
          # be determined for the given operation source. This shall NOT be null if a user index can be determined. In
          # particular, this shall NOT be null if the operation was associated with a valid credential.
          @[TLV::Field(tag: 3)]
          property user_index : UInt16?

          # The fabric index of the fabric that performed the lock operation. This shall be null if there is no fabric
          # that can be determined for the given operation source. This shall NOT be null if the operation source is
          # "Remote".
          @[TLV::Field(tag: 4)]
          property fabric_index : UInt8?

          # The Node ID of the node that performed the lock operation. This shall be null if there is no Node associated
          # with the given operation source. This shall NOT be null if the operation source is "Remote".
          @[TLV::Field(tag: 5)]
          property source_node : UInt64?

          # The list of credentials used in performing the lock operation. This shall be null if no credentials were
          # involved.
          @[TLV::Field(tag: 6)]
          property credentials : Array(Credential)?
        end

        # Body of the DoorLock doorStateChange event
        struct DoorStateChange
          include TLV::Serializable

          # The new door state for this door event.
          @[TLV::Field(tag: 0)]
          property door_state : DoorState

          def initialize(@door_state : DoorState)
          end
        end

        # Body of the DoorLock lockUserChange event
        struct LockUserChange
          include TLV::Serializable

          # The lock data type that was changed.
          @[TLV::Field(tag: 0)]
          property lock_data_type : LockDataType

          # The data operation performed on the lock data type changed.
          @[TLV::Field(tag: 1)]
          property data_operation_type : DataOperationType

          # The source of the user data change.
          @[TLV::Field(tag: 2)]
          property operation_source : OperationSource

          # The lock UserIndex associated with the change (if any). This shall be null if there is no specific user
          # associated with the data operation. This shall be 0xFFFE if all users are affected (e.g. Clear Users).
          @[TLV::Field(tag: 3)]
          property user_index : UInt16?

          # The fabric index of the fabric that performed the change (if any). This shall be null if there is no fabric
          # that can be determined to have caused the change. This shall NOT be null if the operation source is "Remote".
          @[TLV::Field(tag: 4)]
          property fabric_index : UInt8?

          # The Node ID that that performed the change (if any). The Node ID of the node that performed the change. This
          # shall be null if there was no Node involved in the change. This shall NOT be null if the operation source is
          # "Remote".
          @[TLV::Field(tag: 5)]
          property source_node : UInt64?

          # This is the index of the specific item that was changed (e.g. schedule, PIN, RFID, etc.) in the list of
          # items identified by LockDataType. This shall be null if the LockDataType does not correspond to a list that
          # can be indexed into (e.g. ProgrammingUser). This shall be 0xFFFE if all indices are affected (e.g. Clear PIN
          # Code, Clear RFID Code, Clear Week Day Schedule, Clear Year Day Schedule, etc.).
          @[TLV::Field(tag: 6)]
          property data_index : UInt16?
        end
      end
    end
  end
end
