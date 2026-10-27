require "./cluster"
require "../storage/record"

module Matter
  module Cluster
    # Matter 1.6 ICD Management (0x0046). Only explicitly configured ICDs
    # instantiate this cluster; always-on devices do not advertise it.
    class IcdManagement < Base
      cluster 0x0046, revision: 3, persist_state: false

      # These trigger hints require a non-empty instruction telling a user
      # how to activate the ICD (Matter 1.6 ICD Management §9.16.6.7).
      INSTRUCTION_REQUIRED_TRIGGER_HINTS  = 0x0001_AC64_u32
      MRP_BASE_IDLE_INTERVAL_MS           =         500_u32
      MRP_BASE_ACTIVE_INTERVAL_MS         =         300_u32
      MRP_MAX_INTERVAL_MS                 =   3_600_000_u32
      DEFAULT_MAX_STAY_ACTIVE_DURATION_MS =      30_000_u32

      feature :check_in_protocol_support, bit: 0
      feature :user_active_mode_trigger, bit: 1
      feature :long_idle_time_support, bit: 2
      feature :dynamic_sit_lit_support, bit: 3

      enum ClientType : UInt8
        Permanent = 0
        Ephemeral = 1
      end

      enum OperatingMode : UInt8
        Sit = 0
        Lit = 1
      end

      struct MonitoringRegistration
        include TLV::Serializable

        @[TLV::Field(tag: 1)]
        property check_in_node_id : UInt64
        @[TLV::Field(tag: 2)]
        property monitored_subject : UInt64
        @[TLV::Field(tag: 4)]
        property client_type : ClientType
        @[TLV::Field(tag: 254)]
        property fabric_index : UInt8

        def initialize(@check_in_node_id, @monitored_subject, @client_type, @fabric_index)
        end
      end

      struct RegisterClientRequest
        include TLV::Serializable
        @[TLV::Field(tag: 0)]
        property check_in_node_id : UInt64
        @[TLV::Field(tag: 1)]
        property monitored_subject : UInt64
        @[TLV::Field(tag: 2)]
        property key : Bytes
        @[TLV::Field(tag: 3, optional: true)]
        property verification_key : Bytes?
        @[TLV::Field(tag: 4)]
        property client_type : ClientType

        def initialize(@check_in_node_id, @monitored_subject, @key, @verification_key, @client_type)
        end
      end

      struct RegisterClientResponse
        include TLV::Serializable
        @[TLV::Field(tag: 0)]
        property icd_counter : UInt32

        def initialize(@icd_counter)
        end
      end

      struct UnregisterClientRequest
        include TLV::Serializable
        @[TLV::Field(tag: 0)]
        property check_in_node_id : UInt64
        @[TLV::Field(tag: 1, optional: true)]
        property verification_key : Bytes?

        def initialize(@check_in_node_id, @verification_key)
        end
      end

      struct StayActiveRequest
        include TLV::Serializable
        @[TLV::Field(tag: 0)]
        property stay_active_duration : UInt32

        def initialize(@stay_active_duration)
        end
      end

      struct StayActiveResponse
        include TLV::Serializable
        @[TLV::Field(tag: 0)]
        property promised_active_duration : UInt32

        def initialize(@promised_active_duration)
        end
      end

      struct Registration
        include Storage::Record
        getter fabric_index : UInt8
        getter check_in_node_id : UInt64
        getter monitored_subject : UInt64
        getter key : Bytes
        getter client_type : ClientType

        def initialize(@fabric_index, @check_in_node_id, @monitored_subject, @key, @client_type)
        end
      end

      struct PersistedState
        include Storage::Record
        getter data_version : UInt32
        getter counter : UInt32
        getter registrations : Array(Registration)

        def initialize(@data_version, @counter, @registrations)
        end
      end

      struct Configuration
        getter feature_map : Feature
        getter idle_mode_duration : UInt32
        getter active_mode_duration : UInt32
        getter active_mode_threshold : UInt16
        # Polling cadence is separate from the duration the ICD stays awake.
        getter slow_polling_interval_ms : UInt32
        getter fast_polling_interval_ms : UInt32
        getter clients_supported_per_fabric : UInt16
        getter maximum_check_in_backoff : UInt32
        getter user_active_mode_trigger_hint : UInt32
        getter user_active_mode_trigger_instruction : String
        getter max_stay_active_duration_ms : UInt32

        def initialize(@feature_map : Feature = Feature::None,
                       @idle_mode_duration : UInt32 = 1_u32,
                       @active_mode_duration : UInt32 = 300_u32,
                       @active_mode_threshold : UInt16 = 300_u16,
                       @slow_polling_interval_ms : UInt32 = 0_u32,
                       @fast_polling_interval_ms : UInt32 = 0_u32,
                       @clients_supported_per_fabric : UInt16 = 1_u16,
                       maximum_check_in_backoff : UInt32? = nil,
                       @user_active_mode_trigger_hint : UInt32 = 0_u32,
                       @user_active_mode_trigger_instruction : String = "",
                       @max_stay_active_duration_ms : UInt32 = DEFAULT_MAX_STAY_ACTIVE_DURATION_MS)
          @maximum_check_in_backoff = maximum_check_in_backoff || @idle_mode_duration
        end
      end

      attribute 0x0000, :idle_mode_duration, UInt32, default: 1_u32, fixed: true
      attribute 0x0001, :active_mode_duration, UInt32, default: 300_u32, fixed: true
      attribute 0x0002, :active_mode_threshold, UInt16, default: 300_u16, fixed: true
      attribute 0x0003, :registered_clients, Array(MonitoringRegistration), computed: true, read_access: :administer, fabric_scoped: true, requires: :check_in_protocol_support
      attribute 0x0004, :icd_counter, UInt32, computed: true, read_access: :administer, omit_changes: true, requires: :check_in_protocol_support
      attribute 0x0005, :clients_supported_per_fabric, UInt16, default: 1_u16, fixed: true, requires: :check_in_protocol_support
      attribute 0x0006, :user_active_mode_trigger_hint, UInt32, default: 0_u32, fixed: true, requires: :user_active_mode_trigger
      attribute 0x0007, :user_active_mode_trigger_instruction, String, default: "", fixed: true, requires: :user_active_mode_trigger, optional: true
      attribute 0x0008, :operating_mode, OperatingMode, computed: true, requires: :long_idle_time_support
      attribute 0x0009, :maximum_check_in_backoff, UInt32, default: 1_u32, fixed: true, requires: :check_in_protocol_support

      command 0x00, :register_client, request: RegisterClientRequest, response: RegisterClientResponse, response_id: 0x01, access: :manage, requires: :check_in_protocol_support
      command 0x02, :unregister_client, request: UnregisterClientRequest, access: :manage, requires: :check_in_protocol_support
      command 0x03, :stay_active_request, request: StayActiveRequest, response: StayActiveResponse, response_id: 0x04, access: :operate

      CMD_STAY_ACTIVE_RESPONSE = 0x04_u32

      property? request_administer_privilege : Bool = false
      property on_check_in : Proc(UInt8, UInt64, Bytes, UInt32, UInt16, Nil)?
      property on_monitored_subject_covered : Proc(UInt8, UInt64, Bool)?
      property on_persist_counter : Proc(Bool)?
      property on_persist_registration : Proc(Bool)?
      property on_operating_mode_changed : Proc(Nil)?
      getter idle_mode_duration : UInt32
      getter active_mode_duration : UInt32
      getter active_mode_threshold : UInt16
      getter slow_polling_interval_ms : UInt32
      getter fast_polling_interval_ms : UInt32
      getter clients_supported_per_fabric : UInt16
      getter maximum_check_in_backoff : UInt32
      getter user_active_mode_trigger_hint : UInt32
      getter user_active_mode_trigger_instruction : String
      getter max_stay_active_duration_ms : UInt32
      getter icd_counter : UInt32

      @registrations = [] of Registration
      @check_in_send_count = {} of Tuple(UInt8, UInt64) => UInt8
      @check_in_skip_cycles = {} of Tuple(UInt8, UInt64) => UInt32
      @idle = false
      @active_until : Time::Instant? = nil
      @forced_operating_mode : OperatingMode? = nil

      def initialize(endpoint_id : DataType::EndpointNumber = DataType::EndpointNumber::ROOT,
                     @feature_map : Feature = Feature::None,
                     @idle_mode_duration : UInt32 = 1_u32,
                     @active_mode_duration : UInt32 = 300_u32,
                     @active_mode_threshold : UInt16 = 300_u16,
                     @slow_polling_interval_ms : UInt32 = 0_u32,
                     @fast_polling_interval_ms : UInt32 = 0_u32,
                     @clients_supported_per_fabric : UInt16 = 1_u16,
                     maximum_check_in_backoff : UInt32? = nil,
                     @user_active_mode_trigger_hint : UInt32 = 0_u32,
                     @user_active_mode_trigger_instruction : String = "",
                     @max_stay_active_duration_ms : UInt32 = DEFAULT_MAX_STAY_ACTIVE_DURATION_MS,
                     counter_seed : UInt32? = nil,
                     configuration : Configuration? = nil)
        @maximum_check_in_backoff = maximum_check_in_backoff || @idle_mode_duration
        if configuration
          @feature_map = configuration.feature_map
          @idle_mode_duration = configuration.idle_mode_duration
          @active_mode_duration = configuration.active_mode_duration
          @active_mode_threshold = configuration.active_mode_threshold
          @slow_polling_interval_ms = configuration.slow_polling_interval_ms
          @fast_polling_interval_ms = configuration.fast_polling_interval_ms
          @clients_supported_per_fabric = configuration.clients_supported_per_fabric
          @maximum_check_in_backoff = configuration.maximum_check_in_backoff
          @user_active_mode_trigger_hint = configuration.user_active_mode_trigger_hint
          @user_active_mode_trigger_instruction = configuration.user_active_mode_trigger_instruction
          @max_stay_active_duration_ms = configuration.max_stay_active_duration_ms
        end
        validate_configuration
        @icd_counter = counter_seed || ((Random::Secure.rand(UInt32) >> 4) + 1_u32)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
      end

      # Core MRP base intervals plus the time spent waiting for the radio's
      # next poll. ActiveModeDuration controls wake time and does not affect MRP.
      def mrp_idle_interval_ms : UInt32
        MRP_BASE_IDLE_INTERVAL_MS + @slow_polling_interval_ms
      end

      def mrp_active_interval_ms : UInt32
        MRP_BASE_ACTIVE_INTERVAL_MS + @fast_polling_interval_ms
      end

      def registered_clients(fabric_index : UInt8? = request_fabric_index) : Array(MonitoringRegistration)
        return [] of MonitoringRegistration unless fabric_index
        @registrations.compact_map do |entry|
          next if request_fabric_filtered? && entry.fabric_index != fabric_index
          MonitoringRegistration.new(entry.check_in_node_id, entry.monitored_subject,
            entry.client_type, entry.fabric_index)
        end
      end

      def check_in_key(fabric_index : UInt8, node_id : UInt64) : Bytes?
        @registrations.find { |entry| entry.fabric_index == fabric_index && entry.check_in_node_id == node_id }.try(&.key.dup)
      end

      def operating_mode : OperatingMode
        if forced = @forced_operating_mode
          return forced
        end
        if @feature_map.includes?(Feature::LongIdleTimeSupport) && !@registrations.empty?
          OperatingMode::Lit
        else
          OperatingMode::Sit
        end
      end

      def force_operating_mode(mode : OperatingMode) : Nil
        raise ArgumentError.new("DSLS is not enabled") unless @feature_map.includes?(Feature::DynamicSitLitSupport)
        @forced_operating_mode = mode
        increment_version_and_notify(ATTR_OPERATING_MODE)
        @on_operating_mode_changed.try(&.call)
      end

      def withdraw_forced_operating_mode : Nil
        raise ArgumentError.new("DSLS is not enabled") unless @feature_map.includes?(Feature::DynamicSitLitSupport)
        @forced_operating_mode = nil
        increment_version_and_notify(ATTR_OPERATING_MODE)
        @on_operating_mode_changed.try(&.call)
      end

      def register_client(request : RegisterClientRequest) : RegisterClientResponse | InteractionModel::Status
        fabric = request_fabric_index
        return InteractionModel::Status.unsupported_access unless request_is_case_session? && fabric
        return InteractionModel::Status.constraint_error unless request.key.size == 16 &&
                                                                (request.verification_key.nil? || request.verification_key.try(&.size) == 16)
        index = @registrations.index { |entry| entry.fabric_index == fabric && entry.check_in_node_id == request.check_in_node_id }
        previous = @registrations.dup
        if index
          old = @registrations[index]
          return InteractionModel::Status.failure unless request_administer_privilege? || equivalent_key?(old.key, request.verification_key)
          @registrations[index] = Registration.new(fabric, request.check_in_node_id,
            request.monitored_subject, request.key.dup, request.client_type)
        else
          return InteractionModel::Status.resource_exhausted if @registrations.count(&.fabric_index.==(fabric)) >= @clients_supported_per_fabric
          @registrations << Registration.new(fabric, request.check_in_node_id,
            request.monitored_subject, request.key.dup, request.client_type)
        end
        increment_version_and_notify(ATTR_REGISTERED_CLIENTS)
        check_in_identity = {fabric, request.check_in_node_id}
        @check_in_send_count.delete(check_in_identity)
        @check_in_skip_cycles.delete(check_in_identity)
        if (persist = @on_persist_registration) && !persist.call
          @registrations = previous
          return InteractionModel::Status.failure
        end
        @on_operating_mode_changed.try(&.call)
        RegisterClientResponse.new(@icd_counter)
      end

      def unregister_client(request : UnregisterClientRequest) : InteractionModel::Status
        fabric = request_fabric_index
        return InteractionModel::Status.unsupported_access unless request_is_case_session? && fabric
        index = @registrations.index { |entry| entry.fabric_index == fabric && entry.check_in_node_id == request.check_in_node_id }
        return InteractionModel::Status.not_found unless index
        return InteractionModel::Status.failure unless request_administer_privilege? || equivalent_key?(@registrations[index].key, request.verification_key)
        previous = @registrations.dup
        @registrations.delete_at(index)
        check_in_identity = {fabric, request.check_in_node_id}
        @check_in_send_count.delete(check_in_identity)
        @check_in_skip_cycles.delete(check_in_identity)
        increment_version_and_notify(ATTR_REGISTERED_CLIENTS)
        if (persist = @on_persist_registration) && !persist.call
          @registrations = previous
          return InteractionModel::Status.failure
        end
        @on_operating_mode_changed.try(&.call)
        InteractionModel::Status.success
      end

      def stay_active_request(request : StayActiveRequest) : StayActiveResponse
        now = Time.instant
        @active_until = now + baseline_active_duration_ms.milliseconds if @idle || @active_until.nil?
        @idle = false
        requested = {request.stay_active_duration, @max_stay_active_duration_ms}.min
        deadline = now + requested.milliseconds
        active_until = {deadline, @active_until || deadline}.max
        @active_until = active_until
        remaining_ms = (active_until - Time.instant).total_milliseconds.ceil.to_i64
        StayActiveResponse.new(remaining_ms.clamp(0_i64, UInt32::MAX.to_i64).to_u32)
      end

      # Platform power managers call this when the ICD actually enters idle mode.
      def enter_idle_mode : Nil
        return if (deadline = @active_until) && Time.instant < deadline
        @active_until = nil
        @idle = true
      end

      # Platform power managers call this on wake. Counter state is persisted
      # before any Check-In callback to prevent AES-CCM nonce reuse after crash.
      def request_active_mode : Nil
        return unless @idle
        @idle = false
        @active_until = Time.instant + baseline_active_duration_ms.milliseconds
        callback = @on_check_in
        return unless callback && @feature_map.includes?(Feature::CheckInProtocolSupport)
        @registrations.each do |entry|
          next unless entry.client_type.permanent?
          identity = {entry.fabric_index, entry.check_in_node_id}
          if @on_monitored_subject_covered.try(&.call(entry.fabric_index, entry.monitored_subject))
            @check_in_send_count.delete(identity)
            @check_in_skip_cycles.delete(identity)
            next
          end
          if (remaining = @check_in_skip_cycles[identity]?) && remaining > 0
            @check_in_skip_cycles[identity] = remaining - 1_u32
            next
          end
          # Reusing an AES-CCM nonce with the same registration key is unsafe.
          next if @icd_counter == UInt32::MAX
          counter = @icd_counter + 1_u32
          @icd_counter = counter
          next if (persist = @on_persist_counter) && !persist.call
          callback.call(entry.fabric_index, entry.check_in_node_id, entry.key.dup, counter, @active_mode_threshold)
          sends = {@check_in_send_count.fetch(identity, 0_u8).to_i + 1, 31}.min.to_u8
          @check_in_send_count[identity] = sends
          max_cycles = {@maximum_check_in_backoff // @idle_mode_duration, 1_u32}.max
          @check_in_skip_cycles[identity] = {(1_u32 << (sends - 1)), max_cycles}.min - 1_u32
        end
      end

      # A physical user trigger resets the Check-In backoff schedule.
      def trigger_user_active_mode : Nil
        @check_in_send_count.clear
        @check_in_skip_cycles.clear
        request_active_mode
      end

      def remove_fabric(fabric_index : UInt8) : Nil
        before = @registrations.size
        @registrations.reject! { |entry| entry.fabric_index == fabric_index }
        @check_in_send_count.reject! { |identity, _| identity[0] == fabric_index }
        @check_in_skip_cycles.reject! { |identity, _| identity[0] == fabric_index }
        increment_version_and_notify(ATTR_REGISTERED_CLIENTS) if before != @registrations.size
      end

      def retain_fabrics(fabric_indices : Array(UInt8)) : Nil
        @registrations.reject! { |entry| !fabric_indices.includes?(entry.fabric_index) }
      end

      def save_state : Storage::Document?
        PersistedState.new(@data_version, @icd_counter, @registrations).to_document
      end

      def restore_state(document : Storage::Document) : Nil
        state = PersistedState.from_document(document)
        raise Matter::SessionError.new("ICD Check-In counter exhausted") if state.counter > UInt32::MAX - 1000_u32
        @data_version = state.data_version
        @registrations = state.registrations
        @icd_counter = state.counter + 1000_u32
      end

      private def equivalent_key?(expected : Bytes, provided : Bytes?) : Bool
        return false unless provided && provided.size == expected.size
        difference = 0_u8
        expected.each_with_index { |byte, index| difference |= byte ^ provided[index] }
        difference == 0_u8
      end

      private def baseline_active_duration_ms : UInt32
        @active_mode_duration == 0_u32 ? @active_mode_threshold.to_u32 : @active_mode_duration
      end

      private def validate_configuration : Nil
        raise ArgumentError.new("ICD MRP idle interval exceeds one hour") if @slow_polling_interval_ms > MRP_MAX_INTERVAL_MS - MRP_BASE_IDLE_INTERVAL_MS
        raise ArgumentError.new("ICD MRP active interval exceeds one hour") if @fast_polling_interval_ms > MRP_MAX_INTERVAL_MS - MRP_BASE_ACTIVE_INTERVAL_MS
        raise ArgumentError.new("ICD idle duration out of range") unless (1_u32..64_800_u32).includes?(@idle_mode_duration)
        raise ArgumentError.new("ICD active duration exceeds idle duration") if @active_mode_duration > @idle_mode_duration * 1000_u32
        raise ArgumentError.new("ICD StayActive maximum must be positive") if @max_stay_active_duration_ms == 0
        raise ArgumentError.new("ICD registration capacity must be positive") if @clients_supported_per_fabric == 0
        raise ArgumentError.new("ICD Check-In backoff out of range") unless (@idle_mode_duration..64_800_u32).includes?(@maximum_check_in_backoff)
        lits = @feature_map.includes?(Feature::LongIdleTimeSupport)
        raise ArgumentError.new("LITS requires CIP and UAT") if lits && (!@feature_map.includes?(Feature::CheckInProtocolSupport) || !@feature_map.includes?(Feature::UserActiveModeTrigger))
        raise ArgumentError.new("DSLS requires LITS") if @feature_map.includes?(Feature::DynamicSitLitSupport) && !lits
        raise ArgumentError.new("LITS threshold must be at least five seconds") if lits && @active_mode_threshold < 5_000
        raise ArgumentError.new("ICD trigger instruction exceeds 128 characters") if @user_active_mode_trigger_instruction.size > 128
        if @feature_map.includes?(Feature::UserActiveModeTrigger) &&
           (@user_active_mode_trigger_hint & INSTRUCTION_REQUIRED_TRIGGER_HINTS) != 0 &&
           @user_active_mode_trigger_instruction.empty?
          raise ArgumentError.new("ICD trigger hint requires a non-empty instruction")
        end
      end
    end
  end
end
