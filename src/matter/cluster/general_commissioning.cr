require "./cluster"
require "../commissioning"
require "log"

module Matter
  module Cluster
    # General Commissioning Cluster (0x0030)
    #
    # Provides commands and attributes to support the device commissioning process.
    # This includes commissioning window management, failsafe timer management,
    # regulatory configuration, and commissioning completion.
    #
    # The failsafe state machine itself lives in `Commissioning::FailsafeService`;
    # this cluster is its wire front and owns the attributes a commissioner reads
    # the result back from.
    #
    # Matter Core Spec §11.9 - General Commissioning Cluster
    class GeneralCommissioning < Base
      include Commissioning::RollbackTargets

      Log = ::Log.for("matter.cluster.general_commissioning")

      cluster 0x0030, revision: 2

      feature :terms_and_conditions, bit: 0

      # ========================================================================
      # Enumerations
      # ========================================================================

      # Regulatory Location Type
      enum RegulatoryLocationType : UInt8
        Indoor        = 0 # Indoor use only
        Outdoor       = 1 # Outdoor use only
        IndoorOutdoor = 2 # Indoor and outdoor use
      end

      # Commissioning Error Codes, shared with the service behind this facade
      alias CommissioningError = Commissioning::ErrorCode

      # ========================================================================
      # Command Structures
      # ========================================================================

      # ArmFailSafe command request
      struct ArmFailSafeRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property expiry_length_seconds : UInt16

        @[TLV::Field(tag: 1)]
        property breadcrumb : UInt64

        @[TLV::Field(tag: 2)]
        property timeout_ms : UInt32 = 0_u32 # Deprecated, kept for compatibility

        def initialize(@expiry_length_seconds, @breadcrumb, @timeout_ms = 0_u32)
        end
      end

      # ArmFailSafe command response
      struct ArmFailSafeResponse
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property error_code : CommissioningError

        @[TLV::Field(tag: 1)]
        property debug_text : String = ""

        def initialize(@error_code : CommissioningError, @debug_text = "")
        end
      end

      # SetRegulatoryConfig command request
      struct SetRegulatoryConfigRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property new_regulatory_config : RegulatoryLocationType

        @[TLV::Field(tag: 1)]
        property country_code : String

        @[TLV::Field(tag: 2)]
        property breadcrumb : UInt64

        def initialize(@new_regulatory_config : RegulatoryLocationType, @country_code : String, @breadcrumb : UInt64)
        end
      end

      # SetRegulatoryConfig command response
      struct SetRegulatoryConfigResponse
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property error_code : CommissioningError

        @[TLV::Field(tag: 1)]
        property debug_text : String = ""

        def initialize(@error_code : CommissioningError, @debug_text = "")
        end
      end

      # CommissioningComplete command response
      struct CommissioningCompleteResponse
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property error_code : CommissioningError

        @[TLV::Field(tag: 1)]
        property debug_text : String = ""

        def initialize(@error_code : CommissioningError, @debug_text = "")
        end
      end

      struct SetTCAcknowledgementsRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter tc_version : UInt16

        @[TLV::Field(tag: 1)]
        getter tc_user_response : UInt16

        def initialize(@tc_version, @tc_user_response)
        end
      end

      struct SetTCAcknowledgementsResponse
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter error_code : CommissioningError

        def initialize(@error_code)
        end
      end

      # BasicCommissioningInfo - returned by BasicCommissioningInfo attribute
      struct BasicCommissioningInfo
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property fail_safe_expiry_length : UInt16

        @[TLV::Field(tag: 1)]
        property max_cumulative_failsafe_seconds : UInt16

        def initialize(@fail_safe_expiry_length, @max_cumulative_failsafe_seconds)
        end
      end

      # ========================================================================
      # Attributes
      # ========================================================================

      # Failsafe and network commissioning windows default to 15 minutes
      DEFAULT_COMMISSIONING_SECONDS = Commissioning::FailsafeService::DEFAULT_MAX_CUMULATIVE_SECONDS

      # Recommended ArmFailSafe expiry reported in BasicCommissioningInfo
      FAIL_SAFE_EXPIRY_LENGTH_SECONDS = 60_u16

      # Progress tracking during commissioning; not persisted (Matter Core §11.10.6.1)
      attribute 0x0000, :breadcrumb, UInt64, default: 0_u64, writable: true, persist: false, write_access: :administer
      # Built from `FAIL_SAFE_EXPIRY_LENGTH_SECONDS` and `max_cumulative_failsafe_seconds`
      attribute 0x0001, :basic_commissioning_info, BasicCommissioningInfo, computed: true, fixed: true
      attribute 0x0002, :regulatory_config, RegulatoryLocationType, default: RegulatoryLocationType::IndoorOutdoor
      attribute 0x0003, :location_capability, RegulatoryLocationType, default: RegulatoryLocationType::IndoorOutdoor, fixed: true
      attribute 0x0004, :supports_concurrent_connection, Bool, default: true, fixed: true
      attribute 0x0005, :tc_accepted_version, UInt16, computed: true, read_access: :administer, requires: :terms_and_conditions
      attribute 0x0006, :tc_min_required_version, UInt16, computed: true, read_access: :administer, requires: :terms_and_conditions
      attribute 0x0007, :tc_acknowledgements, UInt16, computed: true, read_access: :administer, requires: :terms_and_conditions
      attribute 0x0008, :tc_acknowledgements_required, Bool, computed: true, read_access: :administer, requires: :terms_and_conditions
      attribute 0x0009, :tc_update_deadline, UInt32, computed: true, nullable: true, read_access: :administer, requires: :terms_and_conditions
      # Commissioning on backup power is not supported
      attribute 0x000C, :is_commissioning_without_power, Bool, default: false

      # Longest network commissioning step a commissioner should allow for
      property max_network_commissioning_seconds : UInt16 = DEFAULT_COMMISSIONING_SECONDS

      # The device runtime closes the AdministratorCommissioning window after
      # both successful CommissioningComplete and fail-safe rollback.
      property on_close_commissioning_window : Proc(Nil)?

      # Country code (stored for rollback purposes)
      property country_code : String = "XX" # Default: unknown/unspecified

      # Country code whitelist (nil = all countries allowed)
      property country_code_whitelist : Array(String)? = nil

      # ========================================================================
      # Commands
      # ========================================================================

      # Wire-format (TLV) request structs of the commands; the handlers convert
      # them to the hand-written request types above.
      module Tlv
        # Input to the GeneralCommissioning armFailSafe command
        struct ArmFailSafeRequest
          include TLV::Serializable

          @[TLV::Field(tag: 0)]
          property expiry_length_seconds : UInt16

          @[TLV::Field(tag: 1)]
          property breadcrumb : UInt64
        end

        # Input to the GeneralCommissioning setRegulatoryConfig command
        struct SetRegularConfigurationRequest
          include TLV::Serializable

          @[TLV::Field(tag: 0)]
          property new_regulatory_configuration : RegulatoryLocationType

          @[TLV::Field(tag: 1)]
          property country_code : String

          @[TLV::Field(tag: 2)]
          property breadcrumb : UInt64
        end
      end

      command 0x00, :arm_fail_safe, request: Tlv::ArmFailSafeRequest, response: ArmFailSafeResponse, response_id: 0x01, access: :administer
      command 0x02, :set_regulatory_config, request: Tlv::SetRegularConfigurationRequest, response: SetRegulatoryConfigResponse, response_id: 0x03, access: :administer, handler: :handle_set_regulatory_config
      command 0x04, :commissioning_complete, response: CommissioningCompleteResponse, response_id: 0x05, access: :administer
      command 0x06, :set_tc_acknowledgements, request: SetTCAcknowledgementsRequest, response: SetTCAcknowledgementsResponse, response_id: 0x07, access: :administer, requires: :terms_and_conditions

      # ========================================================================
      # State Management
      # ========================================================================

      # The failsafe state machine behind ArmFailSafe / CommissioningComplete.
      # Built on first use: the service takes this cluster as its rollback
      # target, and an object cannot hand itself out of its own constructor.
      @failsafe : Commissioning::FailsafeService? = nil

      # Only committed acceptance is serialized; acceptance under an armed
      # fail-safe is intentionally lost on restart or rollback.
      private struct PersistedTCState
        include Storage::Record

        getter accepted_version : UInt16?
        getter acknowledgements : UInt16?

        def initialize(@accepted_version, @acknowledgements)
        end
      end

      @tc_committed_version : UInt16? = nil
      @tc_committed_acknowledgements : UInt16? = nil
      @tc_temporal_version : UInt16? = nil
      @tc_temporal_acknowledgements : UInt16? = nil
      @tc_commit_pending : Bool = false

      # Device persistence writes direct (non-fail-safe) acceptance before
      # SetTCAcknowledgements can report success.
      property on_tc_acceptance_write : Proc(Storage::Document, Nil)?

      def failsafe : Commissioning::FailsafeService
        @failsafe ||= begin
          service = Commissioning::FailsafeService.new(self)
          # The breadcrumb tracks commissioner progress and is polled, never
          # subscribed to, so it is written without bumping the data version.
          service.on_breadcrumb_changed = ->(value : UInt64) { @breadcrumb = value }
          service.on_terms_conditions_validate = -> { validate_tc_acceptance }
          service.on_terms_conditions_commit = -> { commit_tc_acceptance }
          service.on_terms_conditions_revert = -> { revert_tc_acceptance }
          service
        end
      end

      # Terms & Conditions state, the per-failsafe reset hook the
      # OperationalCredentials cluster installs and the armed state all belong
      # to the service.
      delegate terms_conditions_required?, :terms_conditions_required=,
        terms_conditions_accepted?, on_failsafe_armed, :on_failsafe_armed=,
        on_failsafe_expired, :on_failsafe_expired=,
        on_failsafe_success, :on_failsafe_success=,
        record_added_fabric,
        to: failsafe

      # Whether a failsafe is currently armed
      def failsafe_armed? : Bool
        failsafe.armed?
      end

      # ========================================================================
      # Initialization
      # ========================================================================

      def initialize(
        endpoint_id : DataType::EndpointNumber = DataType::EndpointNumber.new(0_u16),
        @feature_map : Feature = Feature::None,
        @tc_min_required_version : UInt16? = nil,
        @tc_required_acknowledgements : UInt16 = 0_u16,
        location_capability : RegulatoryLocationType = RegulatoryLocationType::IndoorOutdoor,
      )
        @location_capability = location_capability
        @regulatory_config = location_capability
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
      end

      # LocationCapability is a fixed manufacturer capability. The DSL's
      # generated local setter would otherwise let application code change it
      # after RegulatoryConfig has been initialized from the original value.
      def location_capability=(_value : RegulatoryLocationType) : Nil
        raise ConfigurationError.new("LocationCapability is fixed at construction")
      end

      # ========================================================================
      # Command entry points (DSL dispatch)
      # ========================================================================

      def arm_fail_safe(request_def : Tlv::ArmFailSafeRequest) : ArmFailSafeResponse
        request = ArmFailSafeRequest.new(
          expiry_length_seconds: request_def.expiry_length_seconds,
          breadcrumb: request_def.breadcrumb
        )

        # Session context comes from `Base#invoke_command`
        arm_failsafe(
          request: request,
          session_fabric_index: request_fabric_index,
          is_pase_session: !request_is_case_session?
        )
      end

      def handle_set_regulatory_config(request_def : Tlv::SetRegularConfigurationRequest) : SetRegulatoryConfigResponse
        request = SetRegulatoryConfigRequest.new(
          new_regulatory_config: RegulatoryLocationType.from_value(request_def.new_regulatory_configuration.value),
          country_code: request_def.country_code,
          breadcrumb: request_def.breadcrumb
        )

        self.regulatory_config = request
      end

      def commissioning_complete : CommissioningCompleteResponse
        # Session context comes from `Base#invoke_command`
        commissioning_complete(
          session_fabric_index: request_fabric_index,
          is_case_session: request_is_case_session?
        )
      end

      # Matter command name, rather than a Crystal property setter.
      # ameba:disable Naming/AccessorMethodName
      def set_tc_acknowledgements(request : SetTCAcknowledgementsRequest) : SetTCAcknowledgementsResponse
        if error = validate_tc_values(request.tc_version, request.tc_user_response)
          return SetTCAcknowledgementsResponse.new(error)
        end

        if failsafe.armed?
          @tc_temporal_version = request.tc_version
          @tc_temporal_acknowledgements = request.tc_user_response
        else
          @on_tc_acceptance_write.try(&.call(
            PersistedTCState.new(request.tc_version, request.tc_user_response).to_document))
          @tc_committed_version = request.tc_version
          @tc_committed_acknowledgements = request.tc_user_response
        end
        notify_tc_acceptance_changed
        SetTCAcknowledgementsResponse.new(CommissioningError::OK)
      end

      # ========================================================================
      # Command handlers
      # ========================================================================

      # Handle ArmFailSafe command (0x00)
      #
      # @param request ArmFailSafe request with expiry length and breadcrumb
      # @param session_fabric_index Fabric index of requesting session (nil for PASE)
      # @param is_pase_session Whether this is a PASE session
      def arm_failsafe(
        request : ArmFailSafeRequest,
        session_fabric_index : UInt8?,
        is_pase_session : Bool,
      ) : ArmFailSafeResponse
        outcome = failsafe.arm(
          expiry_length_seconds: request.expiry_length_seconds,
          breadcrumb: request.breadcrumb,
          session_fabric_index: session_fabric_index,
          pase_session: is_pase_session
        )

        ArmFailSafeResponse.new(outcome.error, outcome.debug_text)
      end

      # Handle CommissioningComplete command (0x04)
      #
      # @param session_fabric_index Fabric index of requesting session
      # @param is_case_session Whether this is a CASE session (required)
      def commissioning_complete(
        session_fabric_index : UInt8?,
        is_case_session : Bool,
      ) : CommissioningCompleteResponse
        outcome = failsafe.complete(session_fabric_index, is_case_session)

        CommissioningCompleteResponse.new(outcome.error, outcome.debug_text)
      end

      # Handle SetRegulatoryConfig command (0x02)
      #
      # Sets the regulatory configuration (indoor/outdoor) and country code,
      # snapshotting the previous values so an expiring failsafe restores them.
      def regulatory_config=(
        request : SetRegulatoryConfigRequest,
      ) : SetRegulatoryConfigResponse
        Log.info { "SetRegulatoryConfig: location=#{request.new_regulatory_config}, country=#{request.country_code}" }

        # Validate regulatory location against capability
        unless validate_regulatory_location(request.new_regulatory_config)
          return SetRegulatoryConfigResponse.new(
            CommissioningError::ValueOutsideRange,
            "Requested location #{request.new_regulatory_config} not supported (capability: #{@location_capability})"
          )
        end

        # Validate country code format (2-character ISO 3166-1 alpha-2)
        unless request.country_code.size == 2 && request.country_code.chars.all?(&.ascii_uppercase?)
          return SetRegulatoryConfigResponse.new(
            CommissioningError::ValueOutsideRange,
            "Invalid country code format (expected 2 uppercase letters)"
          )
        end

        # Validate country code against whitelist if configured
        if whitelist = @country_code_whitelist
          unless whitelist.includes?(request.country_code)
            return SetRegulatoryConfigResponse.new(
              CommissioningError::ValueOutsideRange,
              "Country code #{request.country_code} not in whitelist"
            )
          end
        end

        # Record current state for rollback if the failsafe is armed
        failsafe.record_regulatory_config(@regulatory_config.value, @country_code)

        # Apply configuration atomically (only update breadcrumb on success)
        @regulatory_config = request.new_regulatory_config
        @country_code = request.country_code
        @breadcrumb = request.breadcrumb

        Log.info { "Regulatory config updated" }
        SetRegulatoryConfigResponse.new(CommissioningError::OK)
      end

      # BasicCommissioningInfo attribute (0x01)
      def basic_commissioning_info : BasicCommissioningInfo
        BasicCommissioningInfo.new(
          fail_safe_expiry_length: FAIL_SAFE_EXPIRY_LENGTH_SECONDS,
          max_cumulative_failsafe_seconds: max_cumulative_failsafe_seconds
        )
      end

      # ========================================================================
      # Failsafe accessors
      # ========================================================================

      # Hard limit on ArmFailSafe durations, reported in BasicCommissioningInfo
      def max_cumulative_failsafe_seconds : UInt16
        failsafe.max_cumulative_seconds
      end

      def max_cumulative_failsafe_seconds=(seconds : UInt16) : UInt16
        failsafe.max_cumulative_seconds = seconds
      end

      # Get failsafe expiry time (when it will expire)
      def fail_safe_expiry_time : Time?
        failsafe.expiry_time
      end

      # Arm the failsafe outside of an ArmFailSafe request
      def arm_fail_safe(expiry_seconds : UInt16) : Nil
        failsafe.arm_timer(expiry_seconds)
      end

      # Disarm the failsafe
      def disarm_fail_safe : Nil
        failsafe.disarm
      end

      # Check whether a failsafe that was armed has since expired
      def fail_safe_expired? : Bool
        return false unless failsafe.context
        !failsafe.armed?
      end

      # Get current failsafe context (for testing/inspection)
      def failsafe_context : Commissioning::FailsafeContext?
        failsafe.context
      end

      # ========================================================================
      # Rollback targets (`Commissioning::RollbackTargets`)
      # ========================================================================

      # Network configuration this cluster hands a rollback, when one is attached.
      # `Cluster::NetworkCommissioning` includes `Commissioning::NetworkStateStore`.
      property network_state_store : Commissioning::NetworkStateStore?

      # Restore the network configuration captured in `snapshot`. A device with
      # no network store attached has nothing to restore.
      def restore_network_state(snapshot : Storage::Document) : Nil
        @network_state_store.try(&.restore_network_state(snapshot))
      end

      def commit_network_state : Nil
        @network_state_store.try(&.commit_network_state)
      end

      # Restore regulatory config from the snapshot taken before SetRegulatoryConfig
      def restore_regulatory_config(location_type : UInt8, country_code : String) : Nil
        @regulatory_config = RegulatoryLocationType.from_value(location_type)
        @country_code = country_code
        Log.info { "Restored regulatory config: location=#{@regulatory_config}, country=#{country_code}" }
      end

      # Open commissioning window (allows PASE sessions)
      def open_commissioning_window : Nil
        failsafe.commissioning_window_open = true
        Log.info { "Commissioning window opened" }
      end

      # Close commissioning window
      def close_commissioning_window : Nil
        failsafe.commissioning_window_open = false
        @on_close_commissioning_window.try(&.call)
        Log.info { "Commissioning window closed" }
      end

      # ========================================================================
      # Terms & Conditions
      # ========================================================================

      # Accept Terms & Conditions (for TC feature)
      #
      # This method is used when the Terms & Conditions feature is enabled
      # to mark that the user has accepted the terms.
      def accept_terms_conditions : Nil
        failsafe.terms_conditions_accepted = true
        Log.info { "Terms & Conditions accepted" }
      end

      # TC feature attributes expose the temporal acceptance while a fail-safe
      # is armed. With no acceptance, the wire values are zero, as in the SDK.
      def tc_accepted_version : UInt16
        @tc_temporal_version || @tc_committed_version || 0_u16
      end

      def tc_min_required_version : UInt16
        @tc_min_required_version || 0_u16
      end

      def tc_acknowledgements : UInt16
        @tc_temporal_acknowledgements || @tc_committed_acknowledgements || 0_u16
      end

      def tc_acknowledgements_required? : Bool
        !validate_tc_acceptance.nil?
      end

      def tc_acknowledgements_required : Bool
        tc_acknowledgements_required?
      end

      def tc_update_deadline : UInt32?
        nil
      end

      def save_state : Storage::Document?
        return unless @feature_map.terms_and_conditions?
        version = @tc_commit_pending ? (@tc_temporal_version || @tc_committed_version) : @tc_committed_version
        acknowledgements = @tc_commit_pending ? (@tc_temporal_acknowledgements || @tc_committed_acknowledgements) : @tc_committed_acknowledgements
        PersistedTCState.new(version, acknowledgements).to_document
      end

      # The state that CommissioningComplete will commit. The device writes
      # this with the credential-journal deletion in one backend transaction,
      # before either change can be acknowledged to the commissioner.
      def pending_tc_commit_state : Storage::Document?
        return unless version = @tc_temporal_version
        PersistedTCState.new(version, @tc_temporal_acknowledgements).to_document
      end

      # During the file flush, a previously armed debouncer may try to save
      # this cluster. Make it see the same pending acceptance as the commit
      # transaction without changing the in-memory committed state until the
      # transaction has actually reached disk.
      def with_pending_tc_commit(& : -> Nil) : Nil
        @tc_commit_pending = true
        yield
      ensure
        @tc_commit_pending = false
      end

      def restore_state(document : Storage::Document) : Nil
        state = PersistedTCState.from_document(document)
        @tc_committed_version = state.accepted_version
        @tc_committed_acknowledgements = state.acknowledgements
        @tc_temporal_version = nil
        @tc_temporal_acknowledgements = nil
      rescue ex
        Log.warn(exception: ex) { "Failed to restore Terms and Conditions acceptance" }
      end

      private def validate_tc_values(version : UInt16, acknowledgements : UInt16) : CommissioningError?
        required_version = @tc_min_required_version
        return unless required_version
        return CommissioningError::TCMinVersionNotMet if version < required_version
        return CommissioningError::RequiredTCNotAccepted if (acknowledgements & @tc_required_acknowledgements) != @tc_required_acknowledgements
        nil
      end

      private def validate_tc_acceptance : CommissioningError?
        return unless @feature_map.terms_and_conditions?
        return unless @tc_min_required_version

        version = @tc_temporal_version || @tc_committed_version
        acknowledgements = @tc_temporal_acknowledgements || @tc_committed_acknowledgements
        return CommissioningError::TCAcknowledgementsNotReceived unless version && acknowledgements

        validate_tc_values(version, acknowledgements)
      end

      # Also invoked inside the device's credential commit transaction. The
      # device publishes the data-version change only after the file flush;
      # its fail-safe callback then invokes this again as a no-op.
      def commit_tc_acceptance(publish : Bool = true) : Nil
        return unless version = @tc_temporal_version
        @tc_committed_version = version
        @tc_committed_acknowledgements = @tc_temporal_acknowledgements
        @tc_temporal_version = nil
        @tc_temporal_acknowledgements = nil
        increment_version if publish # Wire values were already reported by SetTCAcknowledgements.
      end

      def publish_tc_commit : Nil
        increment_version
      end

      private def revert_tc_acceptance : Nil
        return unless @tc_temporal_version
        @tc_temporal_version = nil
        @tc_temporal_acknowledgements = nil
        notify_tc_acceptance_changed
      end

      private def notify_tc_acceptance_changed : Nil
        increment_version
        notify_changed(ATTR_TC_ACCEPTED_VERSION)
        notify_changed(ATTR_TC_ACKNOWLEDGEMENTS)
        notify_changed(ATTR_TC_ACKNOWLEDGEMENTS_REQUIRED)
      end

      # ========================================================================
      # Helper Methods
      # ========================================================================

      # Validate that requested regulatory location is within capability
      private def validate_regulatory_location(requested : RegulatoryLocationType) : Bool
        case @location_capability
        when RegulatoryLocationType::Indoor
          requested == RegulatoryLocationType::Indoor
        when RegulatoryLocationType::Outdoor
          requested == RegulatoryLocationType::Outdoor
        when RegulatoryLocationType::IndoorOutdoor
          true # All locations supported
        else
          false
        end
      end
    end
  end
end
