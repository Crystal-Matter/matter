require "log"
require "./cluster"
require "../commissioning"

module Matter
  module Cluster
    # Administrator Commissioning Cluster (0x003C)
    #
    # Provides commands to open and close commissioning windows for device onboarding.
    # Administrators can open enhanced windows (with custom PAKE verifier) or basic
    # windows (with default passcode) to allow new commissioners to join the fabric.
    #
    # The window itself - its state, its timeout and the PASE and mDNS side
    # effects of opening and closing it - is `Commissioning::WindowService`;
    # this cluster is its wire front.
    #
    # Matter Core Spec §11.19 - Administrator Commissioning Cluster
    class AdministratorCommissioning < Base
      include Commissioning::WindowTarget

      Log = ::Log.for("matter.cluster.administrator_commissioning")

      cluster 0x003C, revision: 1

      feature :basic, bit: 0 # BC - OpenBasicCommissioningWindow

      # ========================================================================
      # Enums, errors and constants (owned by the service)
      # ========================================================================

      alias CommissioningWindowStatus = Commissioning::WindowStatus
      alias StatusCode = Commissioning::WindowStatusCode

      alias BusyError = Commissioning::BusyError
      alias PAKEParameterError = Commissioning::PAKEParameterError
      alias WindowNotOpenError = Commissioning::WindowNotOpenError

      CRYPTO_GROUP_SIZE_BYTES       = Commissioning::WindowService::CRYPTO_GROUP_SIZE_BYTES
      CRYPTO_PUBLIC_KEY_SIZE_BYTES  = Commissioning::WindowService::CRYPTO_PUBLIC_KEY_SIZE_BYTES
      PAKE_PASSCODE_VERIFIER_LENGTH = Commissioning::WindowService::PAKE_PASSCODE_VERIFIER_LENGTH
      PBKDF2_MIN_ITERATIONS         = Commissioning::WindowService::PBKDF2_MIN_ITERATIONS
      PBKDF2_MAX_ITERATIONS         = Commissioning::WindowService::PBKDF2_MAX_ITERATIONS
      PAKE_SALT_MIN_LENGTH          = Commissioning::WindowService::PAKE_SALT_MIN_LENGTH
      PAKE_SALT_MAX_LENGTH          = Commissioning::WindowService::PAKE_SALT_MAX_LENGTH

      MINIMUM_COMMISSIONING_TIMEOUT  = Commissioning::WindowService::MINIMUM_COMMISSIONING_TIMEOUT
      STANDARD_COMMISSIONING_TIMEOUT = Commissioning::WindowService::STANDARD_COMMISSIONING_TIMEOUT
      MAXIMUM_COMMISSIONING_TIMEOUT  = Commissioning::WindowService::MAXIMUM_COMMISSIONING_TIMEOUT

      # ========================================================================
      # Attributes
      # ========================================================================

      # Current commissioning window state, the fabric that opened it and
      # the vendor id of the opening administrator
      attribute 0x0000, :window_status, CommissioningWindowStatus, default: CommissioningWindowStatus::WindowNotOpen
      attribute 0x0001, :admin_fabric_index, UInt8, nullable: true
      attribute 0x0002, :admin_vendor_id, UInt16, nullable: true

      # ========================================================================
      # Commands
      # ========================================================================

      # Input to the AdministratorCommissioning openCommissioningWindow command
      struct OpenCommissioningWindowRequest
        include TLV::Serializable

        # This field shall specify the time in seconds during which commissioning session establishment is allowed by
        # the Node. This is known as Open Commissioning Window (OCW). This timeout value shall follow guidance as
        # specified in Announcement Duration. The CommissioningTimeout applies only to cessation of any announcements
        # and to accepting of new commissioning sessions; it does not apply to abortion of connections, i.e., a
        # commissioning session SHOULD NOT abort prematurely upon expiration of this timeout.
        @[TLV::Field(tag: 0)]
        property commissioning_timeout : UInt16

        # This field shall specify an ephemeral PAKE passcode verifier (see Section 3.10, “Password-Authenticated Key
        # Exchange (PAKE)”) computed by the existing Administrator to be used for this commissioning. The field is
        # concatenation of two values (w0 || L) shall be (CRYPTO_GROUP_SIZE_BYTES +
        # CRYPTO_PUBLIC_KEY_SIZE_BYTES)-octets long as detailed in Crypto_PAKEValues_Responder. It shall be derived
        # from an ephemeral passcode (See PAKE). It shall be deleted by the Node at the end of commissioning or
        # expiration of OCW, and shall be deleted by the existing Administrator after sending it to the Node(s).
        @[TLV::Field(tag: 1)]
        property pake_passcode_verifier : Slice(UInt8)

        # This field shall be used by the Node as the long discriminator for DNS-SD advertisement (see Commissioning
        # Discriminator) for discovery by the new Administrator. The new Administrator can find and filter DNS-SD
        # records by long discriminator to locate and initiate commissioning with the appropriate Node.
        @[TLV::Field(tag: 2)]
        property discriminator : UInt16

        # This field shall be used by the Node as the PAKE iteration count associated with the ephemeral PAKE passcode
        # verifier to be used for this commissioning, which shall be sent by the Node to the new Administrator’s
        # software as response to the PBKDFParamRequest during PASE negotiation. The permitted range of values shall
        # match the range specified in Section 3.9, “Password-Based Key Derivation Function (PBKDF)”, within the
        # definition of the Crypto_PBKDFParameterSet.
        @[TLV::Field(tag: 3)]
        property iterations : UInt32

        # This field shall be used by the Node as the PAKE Salt associated with the ephemeral PAKE passcode verifier
        # to be used for this commissioning, which shall be sent by the Node to the new
        #
        # Administrator’s software as response to the PBKDFParamRequest during PASE negotiation. The constraints on
        # the value shall match those specified in Section 3.9, “Password-Based Key Derivation Function (PBKDF)”,
        # within the definition of the Crypto_PBKDFParameterSet.
        #
        # When a Node receives the Open Commissioning Window command, it shall begin advertising on DNS-SD as
        # described in Section 4.3.1, "Commissionable Node Discovery" and for a time period as described in Section
        # 11.18.8.1.1, "CommissioningTimeout Field". When the command is received by a SED, it shall enter into active
        # mode and set its fast-polling interval to SLEEPY_ACTIVE_INTERVAL for at least the entire duration of the
        # CommissioningTimeout.
        @[TLV::Field(tag: 4)]
        property salt : Slice(UInt8)

        def initialize(@commissioning_timeout : UInt16, @pake_passcode_verifier : Slice(UInt8), @discriminator : UInt16, @iterations : UInt32, @salt : Slice(UInt8))
        end
      end

      # Input to the AdministratorCommissioning openBasicCommissioningWindow command
      struct OpenBasicCommissioningWindowRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property commissioning_timeout : UInt16

        def initialize(@commissioning_timeout : UInt16)
        end
      end

      command 0x00, :open_commissioning_window, request: OpenCommissioningWindowRequest, access: :administer, timed: true
      command 0x01, :open_basic_commissioning_window, request: OpenBasicCommissioningWindowRequest, access: :administer, timed: true, requires: :basic
      command 0x02, :revoke_commissioning, access: :administer, timed: true

      # ========================================================================
      # State
      # ========================================================================

      # Session context (set by the session before invoking commands)
      property session_fabric_index : UInt8?
      property session_vendor_id : UInt16?

      # The commissioning window behind the three commands. Built on first use:
      # the service publishes state back onto this cluster's attributes, and an
      # object cannot hand itself out of its own constructor.
      @window : Commissioning::WindowService? = nil

      def window : Commissioning::WindowService
        @window ||= Commissioning::WindowService.new(self, @minimum_commissioning_timeout, @maximum_commissioning_timeout)
      end

      # PAKE parameters of an open enhanced window, and the window's timing
      delegate pake_verifier, discriminator, iterations, salt, time_remaining,
        on_configure_pase_server, :on_configure_pase_server=,
        on_configure_pase_pin, :on_configure_pase_pin=,
        on_stop_pase_server, :on_stop_pase_server=,
        on_start_commissioning_advertising, :on_start_commissioning_advertising=,
        on_stop_commissioning_advertising, :on_stop_commissioning_advertising=,
        to: window

      @minimum_commissioning_timeout : UInt16
      @maximum_commissioning_timeout : UInt16

      # ========================================================================
      # Initialization
      # ========================================================================

      def initialize(
        endpoint_id : DataType::EndpointNumber = DataType::EndpointNumber.new(0_u16),
        minimum_timeout : UInt16 = Commissioning::WindowService::MINIMUM_COMMISSIONING_TIMEOUT,
        maximum_timeout : UInt16 = Commissioning::WindowService::STANDARD_COMMISSIONING_TIMEOUT,
        @feature_map : Feature = Feature::Basic,
      )
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))

        @minimum_commissioning_timeout = minimum_timeout
        @maximum_commissioning_timeout = maximum_timeout

        @session_fabric_index = nil
        @session_vendor_id = nil
      end

      # Configure timeout bounds (for testing)
      def configure_timeout_bounds(minimum : UInt16, maximum : UInt16) : Nil
        @minimum_commissioning_timeout = minimum
        @maximum_commissioning_timeout = maximum
        window.minimum_timeout = minimum
        window.maximum_timeout = maximum
      end

      # ========================================================================
      # Command entry points (DSL dispatch)
      # ========================================================================

      def open_commissioning_window(request : OpenCommissioningWindowRequest) : InteractionModel::Status
        open_commissioning_window(request, @session_fabric_index, @session_vendor_id)
        InteractionModel::Status.success
      rescue ex : Matter::ClusterError
        Log.warn(exception: ex) { "OpenCommissioningWindow rejected" }
        ex.to_status
      rescue ex : ArgumentError
        Log.warn(exception: ex) { "OpenCommissioningWindow rejected" }
        InteractionModel::Status.constraint_error
      end

      def open_basic_commissioning_window(request : OpenBasicCommissioningWindowRequest) : InteractionModel::Status
        open_basic_commissioning_window(request, @session_fabric_index, @session_vendor_id)
        InteractionModel::Status.success
      rescue ex : Matter::ClusterError
        Log.warn(exception: ex) { "OpenBasicCommissioningWindow rejected" }
        ex.to_status
      rescue ex : ArgumentError
        Log.warn(exception: ex) { "OpenBasicCommissioningWindow rejected" }
        InteractionModel::Status.constraint_error
      end

      def revoke_commissioning : InteractionModel::Status
        revoke_commissioning!
        InteractionModel::Status.success
      rescue ex : Matter::ClusterError
        Log.warn(exception: ex) { "RevokeCommissioning rejected" }
        ex.to_status
      end

      # ========================================================================
      # Command handlers
      # ========================================================================

      # Handle OpenCommissioningWindow command (0x00)
      #
      # Opens an enhanced commissioning window with a custom PAKE verifier,
      # pre-computed by the administrator from an ephemeral passcode.
      #
      # Raises `PAKEParameterError`, `BusyError` or `ArgumentError` on a request
      # the device cannot honour.
      def open_commissioning_window(
        request : OpenCommissioningWindowRequest,
        session_fabric_index : UInt8?,
        session_vendor_id : UInt16?,
        joint : Bool = false,
      ) : Nil
        window.open_enhanced(
          timeout_seconds: request.commissioning_timeout,
          verifier: request.pake_passcode_verifier,
          discriminator: request.discriminator,
          iterations: request.iterations,
          salt: request.salt,
          admin_fabric_index: session_fabric_index,
          admin_vendor_id: session_vendor_id,
          joint: joint
        )
      end

      # Handle OpenBasicCommissioningWindow command (0x01)
      #
      # Opens a basic commissioning window onto the device's own passcode.
      def open_basic_commissioning_window(
        request : OpenBasicCommissioningWindowRequest,
        session_fabric_index : UInt8?,
        session_vendor_id : UInt16?,
      ) : Nil
        window.open_basic(
          timeout_seconds: request.commissioning_timeout,
          admin_fabric_index: session_fabric_index,
          admin_vendor_id: session_vendor_id
        )
      end

      # Handle RevokeCommissioning command (0x02)
      #
      # Raises `WindowNotOpenError` when no window is open.
      def revoke_commissioning! : Nil
        window.revoke
      end

      # ========================================================================
      # Window state
      # ========================================================================

      # Publish the window state onto the attributes (`Commissioning::WindowTarget`)
      def publish_window_state(
        status : Commissioning::WindowStatus,
        admin_fabric_index : UInt8?,
        admin_vendor_id : UInt16?,
        notify : Bool,
      ) : Nil
        @window_status = status
        @admin_fabric_index = admin_fabric_index
        @admin_vendor_id = admin_vendor_id
        increment_version if notify
      end

      # Record an enhanced window without the PASE and mDNS side effects
      def open_enhanced_window(timeout_seconds : UInt16, fabric_index : UInt8, vendor_id : UInt16) : Nil
        window.mark_open(CommissioningWindowStatus::EnhancedWindowOpen, timeout_seconds, fabric_index, vendor_id)
      end

      # Record a basic window without the PASE and mDNS side effects
      def open_basic_window(timeout_seconds : UInt16, fabric_index : UInt8, vendor_id : UInt16) : Nil
        window.mark_open(CommissioningWindowStatus::BasicWindowOpen, timeout_seconds, fabric_index, vendor_id)
      end

      # When the open window expires
      def window_timeout : Time?
        window.expires_at
      end

      # Whether the window's timeout has passed
      def window_expired? : Bool
        window.expired?
      end

      # Check if commissioning window is open
      def window_open? : Bool
        window.open?
      end

      # Check if enhanced window is open
      def enhanced_window_open? : Bool
        window.enhanced_open?
      end

      # Check if basic window is open
      def basic_window_open? : Bool
        window.basic_open?
      end

      # Close the window (backward compatibility)
      def close_window : Nil
        window.close
      end

      # Close and cleanup (for testing/shutdown)
      def close : Nil
        window.close if window_open?
      end
    end
  end
end
