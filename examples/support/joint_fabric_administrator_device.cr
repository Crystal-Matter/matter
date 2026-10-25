require "./console"
require "../../src/matter/commissioning/joint_fabric_administrator_service"
require "../../src/matter/controller/datastore_propagator"
require "../../src/matter/controller/anchor_datastore_subscription"
require "../../src/matter/controller/joint_commissioning"
require "../../src/matter/controller/anchor_transfer"
require "../../src/matter/controller/administrator_removal"
require "../../src/matter/controller/joint_fabric_device_migration"
require "../../src/matter/controller/vid_verification_dcl"

# Joint Fabric Administrator endpoint for interoperability work. Commission
# this device onto an Anchor fabric first; its JF service binds to that fabric
# as soon as the RCAC and operational credentials are installed.
module MatterJointFabricAdministrator
  class Device < Matter::Device
    include Examples::Console

    alias Admin = Matter::Cluster::JointFabricAdministrator
    alias Datastore = Matter::Cluster::JointFabricDatastore

    APP_KEY_DOCUMENT                      = "joint-fabric-admin-key"
    APP_ICAC_DOCUMENT                     = "joint-fabric-admin-icac"
    APP_ROLE_DOCUMENT                     = "joint-fabric-admin-role"
    APP_BOOTSTRAP_ROLE_DOCUMENT           = "joint-fabric-bootstrap-role"
    APP_BOOTSTRAP_ICAC_DOCUMENT           = "joint-fabric-bootstrap-icac"
    APP_BOOTSTRAP_TRANSFER_WATCH_DOCUMENT = "joint-fabric-bootstrap-transfer-watch"
    APP_TRANSFER_DOCUMENT                 = "joint-fabric-anchor-transfer"
    APP_TRANSFER_WATCH_DOCUMENT           = "joint-fabric-transfer-watch"
    APP_FOLLOW_UP_PREFIX                  = "joint-fabric-anchor-follow-up-"
    APP_REMOVAL_PREFIX                    = "joint-fabric-administrator-removal-"
    JCM_RPC_COLLECTION                    = "jcm_anchor_exchange"
    JCM_RPC_REQUEST                       = "request"
    JCM_RPC_RESULT                        = "result"
    COMMAND_RPC_COLLECTION                = "jfa_command"
    ANCHOR_CAT_ID                         = 0xFFFE_u16
    DEFAULT_OPERATIONAL_PORT              =       5540
    ADMIN_GROUP_ID                        =      1_u16
    ANCHOR_GROUP_ID                       =      2_u16
    ANCHOR_IPK_KEY_SET_ID                 =      0_u16

    struct IcacKeyState
      include Matter::Storage::Record

      getter private_key : Bytes
      getter public_key : Bytes

      def initialize(@private_key : Bytes, @public_key : Bytes)
      end
    end

    struct IcacCertificateState
      include Matter::Storage::Record

      getter certificate : Bytes

      def initialize(@certificate : Bytes)
      end
    end

    struct JointFabricRoleState
      include Matter::Storage::Record

      getter? anchor : Bool
      # A pre-upgrade role record without this field must fail closed rather
      # than re-expose a former Anchor's frozen Datastore after restart.
      getter? transfer_complete : Bool = true

      def initialize(@anchor : Bool, @transfer_complete : Bool = false)
      end
    end

    struct TransferWatchState
      include Matter::Storage::Record

      getter requester_node_id : UInt64
      getter old_fabric_id : UInt64
      getter old_root_public_key : Bytes
      getter new_anchor_node_id : UInt64?

      def initialize(@requester_node_id : UInt64, @old_fabric_id : UInt64,
                     @old_root_public_key : Bytes, @new_anchor_node_id : UInt64?)
      end
    end

    # Local controller-to-JFA handoff used by the e2e example. The controller
    # has already verified the joining ICAC public key before writing this.
    struct AnchorExchangeRequest
      include Matter::Storage::Record

      getter joining_node_id : UInt64
      getter fabric_id : UInt64
      getter root_public_key : Bytes
      getter peer_address : String
      getter peer_port : Int32
      getter administrator_endpoint : UInt16
      getter icac_public_key : Bytes
      getter icac_id : UInt64

      def initialize(@fabric_id : UInt64, @root_public_key : Bytes,
                     @joining_node_id : UInt64, @peer_address : String,
                     @peer_port : Int32, @administrator_endpoint : UInt16,
                     @icac_public_key : Bytes, @icac_id : UInt64)
      end

      def initialize(fabric_id : UInt64, root_public_key : Bytes,
                     joining_node_id : UInt64, peer : Socket::IPAddress,
                     administrator_endpoint : UInt16, icac_public_key : Bytes,
                     icac_id : UInt64)
        initialize(fabric_id, root_public_key, joining_node_id,
          Matter::Controller::OperationalPeerResolver.address_hint(peer), peer.port,
          administrator_endpoint, icac_public_key, icac_id)
      end
    end

    struct AnchorExchangeResult
      include Matter::Storage::Record

      getter status : String
      getter certificate : Bytes?
      getter error : String?

      def initialize(@status : String, @certificate : Bytes? = nil, @error : String? = nil)
      end
    end

    # File-backed local command channel for headless interoperability runs.
    # The application must explicitly set MATTER_JFA_COMMAND_PATH to enable it.
    struct CommandRequest
      include Matter::Storage::Record

      getter operation : String
      getter node_id : UInt64
      getter fabric_id : UInt64?
      getter root_public_key : Bytes?
      getter nonce : String?
      getter? interrupt_after_remove_fabric : Bool
      # Older command-channel YAML files predate these test-only fault hooks.
      getter? interrupt_after_remove_admin : Bool = false
      getter? interrupt_before_transfer_follow_up : Bool = false
      getter? interrupt_after_transfer_request : Bool = false
      getter? interrupt_after_anchor_rotation : Bool = false
      getter? interrupt_after_participant_rotation : Bool = false
      getter fail_safe_max_seconds : UInt16? = nil
      getter? jcm : Bool
      getter trusted_icac_public_key_b : Bytes?
      getter peer_admin_jfa_endpoint_id : UInt16?
      getter anchor_node_id : UInt64?
      getter peer_address : String?
      getter peer_port : Int32?

      def initialize(@operation : String, @node_id : UInt64,
                     @fabric_id : UInt64? = nil, @root_public_key : Bytes? = nil,
                     @nonce : String? = nil, @interrupt_after_remove_fabric : Bool = false,
                     @jcm : Bool = false, @trusted_icac_public_key_b : Bytes? = nil,
                     @peer_admin_jfa_endpoint_id : UInt16? = nil,
                     @anchor_node_id : UInt64? = nil, @peer_address : String? = nil,
                     @peer_port : Int32? = nil,
                     @interrupt_after_remove_admin : Bool = false,
                     @interrupt_before_transfer_follow_up : Bool = false,
                     @interrupt_after_transfer_request : Bool = false,
                     @interrupt_after_anchor_rotation : Bool = false,
                     @interrupt_after_participant_rotation : Bool = false,
                     @fail_safe_max_seconds : UInt16? = nil)
      end
    end

    struct CommandResult
      include Matter::Storage::Record

      getter status : String
      getter error : String?
      getter fabric_present : Bool?
      getter inspected_fabric_id : UInt64?
      getter inspected_root_public_key : Bytes?
      getter inspected_root_certificate : Bytes?
      getter inspected_icac_certificate : Bytes?
      getter inspected_node_id : UInt64?
      getter inspected_cross_signed_icac : Bytes?
      getter inspected_administrator_fabric_index : UInt8?
      getter inspected_fabric_count : Int32?
      getter inspected_datastore_admin_entries : Array(Bytes)?
      getter inspected_transfer_requester_node_id : UInt64?
      getter inspected_transfer_frozen : Bool?
      getter nonce : String?
      getter certificate : Bytes?
      getter subscription_committed : Bool?

      def initialize(@status : String, @error : String? = nil, @fabric_present : Bool? = nil,
                     @inspected_fabric_id : UInt64? = nil,
                     @inspected_root_public_key : Bytes? = nil, @nonce : String? = nil,
                     @certificate : Bytes? = nil, @subscription_committed : Bool? = nil,
                     @inspected_root_certificate : Bytes? = nil,
                     @inspected_icac_certificate : Bytes? = nil,
                     @inspected_node_id : UInt64? = nil,
                     @inspected_cross_signed_icac : Bytes? = nil,
                     @inspected_administrator_fabric_index : UInt8? = nil,
                     @inspected_fabric_count : Int32? = nil,
                     @inspected_datastore_admin_entries : Array(Bytes)? = nil,
                     @inspected_transfer_requester_node_id : UInt64? = nil,
                     @inspected_transfer_frozen : Bool? = nil)
      end
    end

    # Exercises the journal boundary where the remote RemoveFabric completed
    # but its acknowledgement was lost before the local stage could advance.
    class InterruptedRemovalPort < Matter::Controller::AdministratorRemoval::Port
      def initialize(@delegate : Matter::Controller::AdministratorRemoval::Port,
                     @interrupt_after_remove_fabric : Bool = false,
                     @interrupt_after_remove_admin : Bool = false,
                     @interrupt_after_anchor_rotation : Bool = false,
                     @interrupt_after_participant_rotation : Bool = false)
      end

      def remove_outgoing_fabric! : Nil
        @delegate.remove_outgoing_fabric!
        if @interrupt_after_remove_fabric
          raise Matter::TransportError.new("Injected lost RemoveFabric acknowledgement")
        end
      end

      def remove_datastore_admin! : Nil
        @delegate.remove_datastore_admin!
        if @interrupt_after_remove_admin
          raise Matter::TransportError.new("Injected lost RemoveAdmin acknowledgement")
        end
      end

      def rotate_anchor! : Nil
        @delegate.rotate_anchor!
        if @interrupt_after_anchor_rotation
          raise Matter::TransportError.new("Injected lost Anchor rotation acknowledgement")
        end
      end

      def rotate_participant!(node_id : UInt64) : Nil
        @delegate.rotate_participant!(node_id)
        if @interrupt_after_participant_rotation
          raise Matter::TransportError.new("Injected lost participant rotation acknowledgement")
        end
      end
    end

    # Test-only loss of the TransferAnchorRequest acknowledgement. The old
    # Anchor is already frozen when the local journal remains Requesting.
    class InterruptedTransferPort < Matter::Controller::AnchorTransfer::Port
      def initialize(@delegate : Matter::Controller::AnchorTransfer::Port)
      end

      def request : Admin::TransferAnchorResponseStatusEnum
        result = @delegate.request
        raise Matter::TransportError.new("Injected lost TransferAnchorRequest acknowledgement") if result.ok?
        result
      end

      def complete : Nil
        @delegate.complete
      end
    end

    identity vendor: "Crystal Matter", product: "Crystal Joint Fabric Administrator",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: 0x0130_u16,
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::JOINT_FABRIC_ADMINISTRATOR

    storage yaml: "matter_joint_fabric_administrator_storage.yml"
    network :ethernet

    endpoint 1, device_type: Matter::DeviceType::JOINT_FABRIC_ADMINISTRATOR do
      cluster Admin, as: :joint_fabric_administrator
      cluster Datastore, as: :joint_fabric_datastore
    end

    # A joining Administrator retains its bootstrap fabric's Datastore while
    # endpoint 1 is rebound to the joined Anchor fabric. The two instances
    # enforce their own CASE fabric indices.
    endpoint 2, device_type: Matter::DeviceType::JOINT_FABRIC_ADMINISTRATOR do
      cluster Admin, as: :bootstrap_joint_fabric_administrator
      cluster Datastore, as: :bootstrap_joint_fabric_datastore
    end

    @anchor_role : Bool = false
    @joint_fabric_provisioned : Bool = false
    @datastore_propagator : Matter::Controller::DatastorePropagator?
    @bootstrap_datastore_propagator : Matter::Controller::DatastorePropagator?
    @migration_attestation_trust : Matter::Controller::AttestationTrustStore?
    @controller_store : Matter::Controller::StateStore?
    @propagation_fabric : Matter::Fabric?
    @propagation_started : Bool = false
    @transfer_in_progress : Bool = false
    @removal_in_progress : Bool = false
    @jcm_failsafe_session_id : UInt64?
    @new_anchor_subscription : Matter::Controller::AnchorDatastoreSubscription?
    @new_anchor_scanner : Matter::Controller::Scanner?
    @subscribed_fabric_id : UInt64?
    @subscribed_root_public_key : Bytes?
    @participant_view_current : Bool = false
    @watch_polling : Bool = false
    @watch_stopped : Bool = false
    @unprovisioned_service_fabric_index : UInt8?

    def console_notes : Array(String)
      ["Endpoint 1: Joint Fabric Administrator and Joint Fabric Datastore"]
    end

    # Applications can supply their own PAA and CD signer trust, together with
    # a revocation decision source. No test trust is installed by default.
    def migration_attestation_trust=(trust : Matter::Controller::AttestationTrustStore) : Nil
      if trust.paa_certificates.empty? || trust.cd_signers.empty? || !trust.revocation_check
        raise Matter::ConfigurationError.new("Migration trust requires PAA, CD signer, and revocation source")
      end
      @migration_attestation_trust = trust
    end

    private def migration_attestation_verifier : Matter::Controller::DeviceAttestationVerifier
      trust = @migration_attestation_trust ||
              (ENV["MATTER_JFA_MIGRATION_TEST_TRUST"]? == "1" ? Matter::Controller::AttestationTrustStore.matter_test_fixture : nil)
      raise Matter::ConfigurationError.new("Migration attestation trust is not configured") unless trust
      Matter::Controller::DeviceAttestationVerifier.new(trust)
    end

    def commands : Array(Tuple(String, String))
      [{"transfer-anchor", "Transfer Anchor role from a joined fabric: transfer-anchor <old-anchor-node-id-hex>"},
       {"transfer-status", "Show the persisted Anchor transfer stage"},
       {"remove-administrator", "Remove a consented JFA: remove-administrator <node-id-hex>"}]
    end

    def handle_command(name : String, argument : String?) : Bool
      case name
      when "transfer-status"
        document = persistence.app_document(APP_TRANSFER_DOCUMENT)
        journal = document ? Matter::Controller::AnchorTransfer::Journal.from_document(document) : nil
        puts(journal ? "Anchor transfer: #{journal.stage} for node 0x#{journal.candidate_node_id.to_s(16)}" : "No Anchor transfer journal")
      when "transfer-anchor"
        unless argument && (old_node_id = argument.to_u64?(16))
          puts "Usage: transfer-anchor <old-anchor-node-id-hex>"
          return true
        end
        begin
          transfer_anchor_from(old_node_id)
          puts "Anchor transfer completed"
        rescue ex : Matter::Error | IO::Error | ArgumentError
          ::Log.for("matter.example.joint_fabric_administrator").error(exception: ex) { "Anchor transfer stopped" }
          puts "Anchor transfer stopped: #{ex.message}"
        end
      when "remove-administrator"
        unless argument && (outgoing_node_id = argument.to_u64?(16))
          puts "Usage: remove-administrator <node-id-hex>"
          return true
        end
        begin
          remove_administrator(outgoing_node_id)
          puts "Administrator removal completed"
        rescue ex : Matter::Error | IO::Error | ArgumentError
          ::Log.for("matter.example.joint_fabric_administrator").error(exception: ex) { "Administrator removal stopped" }
          puts "Administrator removal stopped: #{ex.message}"
        end
      else
        return false
      end
      true
    end

    protected def before_start : Nil
      super
      # The second endpoint is a retained bootstrap JFA only when explicitly
      # provisioned. A wildcard JCM read must not discover a second JFA with
      # a null AdministratorFabricIndex, which the SDK correctly rejects.
      remove_endpoint(2_u16, notify_subscribers: false) unless ENV["MATTER_JFA_KEEP_BOOTSTRAP_DATASTORE"]? == "1"
      connect_failsafe_lifecycle
      fabrics = fabric_table.all_fabrics
      fabrics.select { |fabric| compliant_anchor_fabric?(fabric) }.each { |fabric| attach_joint_fabric(fabric) }
      fabrics.reject { |fabric| compliant_anchor_fabric?(fabric) }.each { |fabric| attach_joined_fabric(fabric) }
      fabrics.each { |fabric| attach_unprovisioned_administrator(fabric) }
    end

    protected def fabric_added(fabric : Matter::Fabric) : Nil
      attach_joint_fabric(fabric)
      attach_joined_fabric(fabric)
      attach_unprovisioned_administrator(fabric)
    end

    protected def started_commissioning_mode : Nil
      super
      # The official multi-ecosystem fixture starts this external DUT before
      # its first SDK test device. Keep it out of SDK on-network discovery
      # until that device has completed commissioning.
      @responder.stop_commissioning if ENV["MATTER_JFA_DISCOVERY_GATE_PATH"]?
    end

    protected def on_started : Nil
      super
      if gate = ENV["MATTER_JFA_DISCOVERY_GATE_PATH"]?
        discovery_enabled = false
        every(1.second) do
          if !discovery_enabled && File.exists?(gate) && @fabric_table.empty?
            discovery_enabled = true
            @lifecycle.sync_advertisements
          end
        end
      end
      @propagation_started = true
      @datastore_propagator.try(&.start) if joint_fabric_datastore.access_mode.active?
      @bootstrap_datastore_propagator.try(&.start) if bootstrap_joint_fabric_datastore.access_mode.active?
      if ENV["MATTER_JFA_JCM_REQUEST_PATH"]?
        every(1.second) { process_anchor_exchange_request }
      end
      if ENV["MATTER_JFA_COMMAND_PATH"]?
        every(1.second) { process_command_request }
      end
      every(5.seconds) { poll_new_anchor_subscription }
    end

    def shutdown! : Nil
      @watch_stopped = true
      close_new_anchor_subscription
      @datastore_propagator.try(&.stop!)
      @bootstrap_datastore_propagator.try(&.stop!)
      super
    end

    protected def fabric_removed(fabric_index : UInt8) : Nil
      if @unprovisioned_service_fabric_index == fabric_index
        joint_fabric_administrator.service = nil
        @unprovisioned_service_fabric_index = nil
      end
      if bootstrap_joint_fabric_datastore.joint_fabric_index == fabric_index
        @bootstrap_datastore_propagator.try(&.stop!)
        @bootstrap_datastore_propagator = nil
        bootstrap_joint_fabric_datastore.clear_fabric_state
        bootstrap_joint_fabric_administrator.administrator_fabric_index = nil
        bootstrap_joint_fabric_administrator.service = nil
        persistence.forget_cluster(2_u16, Datastore::CLUSTER_ID)
        persistence.delete_app_document(APP_BOOTSTRAP_ROLE_DOCUMENT)
        persistence.delete_app_document(APP_BOOTSTRAP_ICAC_DOCUMENT)
        persistence.delete_app_document(APP_BOOTSTRAP_TRANSFER_WATCH_DOCUMENT)
        persistence.delete_app_document(APP_KEY_DOCUMENT) unless joint_fabric_datastore.joint_fabric_index
        if propagation = @propagation_fabric
          if propagation.fabric_index == fabric_index && joint_fabric_datastore.joint_fabric_index != fabric_index
            if store = @controller_store
              state = store.load
              state.remove_fabric(propagation.fabric_id, propagation.root_public_key, propagation.node_id)
              store.save(state)
            end
            @propagation_fabric = nil
            @controller_store = nil
          end
        end
      end
      @participant_view_current = false
      close_new_anchor_subscription
      if joint_fabric_datastore.joint_fabric_index == fabric_index
        @datastore_propagator.try(&.stop!)
        @datastore_propagator = nil
        if fabric = @propagation_fabric
          if fabric.fabric_index == fabric_index
            if store = @controller_store
              state = store.load
              state.remove_fabric(fabric.fabric_id, fabric.root_public_key, fabric.node_id)
              store.save(state)
            end
          end
        end
        if @propagation_fabric.try(&.fabric_index) == fabric_index
          @propagation_fabric = nil
          @controller_store = nil
        end
        joint_fabric_datastore.clear_fabric_state
        joint_fabric_datastore.allow_jcm_pase_group_list = nil
        @jcm_failsafe_session_id = nil
        persistence.forget_cluster(1_u16, Datastore::CLUSTER_ID)
        joint_fabric_administrator.administrator_fabric_index = nil
        joint_fabric_administrator.service = nil
        @joint_fabric_provisioned = !bootstrap_joint_fabric_datastore.joint_fabric_index.nil?
        @anchor_role = false
        persistence.delete_app_document(APP_ROLE_DOCUMENT)
        persistence.delete_app_document(APP_ICAC_DOCUMENT)
        persistence.delete_app_document(APP_KEY_DOCUMENT) unless bootstrap_joint_fabric_datastore.joint_fabric_index
      end
    end

    protected def commissioning_info_for(mode : Matter::MDNS::CommissioningMode) : Matter::MDNS::CommissioningInfo
      info = super
      bootstrap_active = bootstrap_joint_fabric_datastore.access_mode.active? &&
                         (bootstrap_joint_fabric_datastore.joint_fabric_index != joint_fabric_datastore.joint_fabric_index ||
                          joint_fabric_datastore.status.state != Datastore::DatastoreStateEnum::DeletePending)
      info.joint_fabric_role = if joint_fabric_datastore.status.state == Datastore::DatastoreStateEnum::DeletePending &&
                                  !bootstrap_active
                                 nil
                               elsif !@joint_fabric_provisioned
                                 Matter::MDNS::JointFabricRole::Available
                               elsif @anchor_role || bootstrap_active
                                 Matter::MDNS::JointFabricRole::Administrator |
                                   Matter::MDNS::JointFabricRole::Anchor |
                                   Matter::MDNS::JointFabricRole::Datastore
                               else
                                 Matter::MDNS::JointFabricRole::Administrator
                               end
      info
    end

    # A freshly commissioned JFA has no Anchor role yet, but its JFA commands
    # still have defined fail-safe and validation results. Keep an isolated
    # service on that fabric until the device joins or provisions a Joint Fabric.
    private def attach_unprovisioned_administrator(fabric : Matter::Fabric) : Nil
      return if joint_fabric_administrator.service
      root = fabric.root_cert || return
      administrator = joint_fabric_administrator
      administrator.service = Matter::Commissioning::JointFabricAdministratorService.new(
        icac_private_key: Matter::Crypto::StandardCrypto.new.create_key_pair,
        root_certificate: root,
        fabric_id: fabric.fabric_id,
        failsafe_armed: -> { general_commissioning.failsafe_armed? },
        vendor_id_verified: ->(_index : UInt8) { false },
        open_window: ->(_request : Admin::OpenJointCommissioningWindowRequest) { Matter::InteractionModel::Status.invalid_command },
        transfer_authorized: ->(_node_id : UInt64) { false },
        datastore_busy: -> { false },
        begin_transfer: -> { nil },
        complete_transfer: -> { nil })
      @unprovisioned_service_fabric_index = fabric.fabric_index
    end

    private def attach_joint_fabric(fabric : Matter::Fabric) : Nil
      root = fabric.root_cert
      unless root
        ::Log.for("matter.example.joint_fabric_administrator").info { "JFA activation skipped: fabric has no root certificate" }
        return
      end
      unless compliant_anchor_fabric?(fabric)
        ::Log.for("matter.example.joint_fabric_administrator").info do
          "JFA activation skipped: Anchor CAT or ICAC validation failed (fabric_id=0x#{fabric.fabric_id.to_s(16)}, cats=#{fabric.cats.map(&.value).map(&.to_s(16))})"
        end
        return
      end
      icac = fabric.intermediate_cert
      unless icac
        ::Log.for("matter.example.joint_fabric_administrator").info { "JFA activation skipped: no Anchor ICAC" }
        return
      end
      remote_csr_path = ENV["MATTER_JFA_ICAC_CSR_MAILBOX_PATH"]?
      key = remote_csr_path ? nil : provisioned_icac_key(fabric, icac)
      unless key || remote_csr_path
        ::Log.for("matter.example.joint_fabric_administrator").warn do
          "JFA activation skipped: Anchor ICAC private key unavailable or mismatched (fabric_id=0x#{fabric.fabric_id.to_s(16)})"
        end
        return
      end

      ::Log.for("matter.example.joint_fabric_administrator").info do
        "JFA Anchor activated (fabric_id=0x#{fabric.fabric_id.to_s(16)}, index=#{fabric.fabric_index})"
      end

      grant_administrator_cat_access(fabric)
      @joint_fabric_provisioned = true
      @anchor_role = persisted_anchor_role

      datastore = joint_fabric_datastore
      datastore.joint_fabric_index = fabric.fabric_index
      datastore.access_mode = if @anchor_role
                                Datastore::AccessMode::Active
                              elsif datastore.status.state.delete_pending? && !persisted_transfer_complete?
                                Datastore::AccessMode::Frozen
                              else
                                Datastore::AccessMode::Inactive
                              end
      datastore.allow_jcm_pase_group_list = -> {
        owner = @jcm_failsafe_session_id
        !owner.nil? && owner == datastore.request_session_id &&
        general_commissioning.failsafe_armed? &&
        administrator_commissioning.window.joint_window? &&
        administrator_commissioning.window_open?
      }
      unless datastore.status.state == Datastore::DatastoreStateEnum::DeletePending
        # Older Anchor stores may contain a zero key set without its IPK.
        # Persist the repaired key before this JFA serves the Datastore: a
        # debounced write alone can be lost on a process crash.
        ipk_needs_repair = datastore.group_key_set_list.find do |entry|
          entry.group_key_set_id == ANCHOR_IPK_KEY_SET_ID
        end.try(&.epoch_key0) != fabric.ipk
        status = datastore.configure_anchor(root, fabric.node_id, fabric.vendor_id, "Crystal Anchor", fabric.ipk)
        if ipk_needs_repair
          raise Matter::StorageError.new("Could not repair Anchor Datastore IPK") unless status.success?
          unless persistence.save_cluster(datastore)
            raise Matter::StorageError.new("Could not persist repaired Anchor Datastore IPK")
          end
        end
        seed_joint_fabric_groups(datastore)
        seed_anchor_administrator(datastore, fabric, icac)
      end

      administrator = joint_fabric_administrator
      administrator.administrator_fabric_index = fabric.fabric_index
      remote_csr_provider = remote_csr_path.try do |path|
        Matter::Commissioning::RemoteIcacCsrProvider.new(path, fabric.fabric_id, fabric.root_public_key)
      end
      administrator.service = Matter::Commissioning::JointFabricAdministratorService.new(
        icac_private_key: key,
        root_certificate: root,
        fabric_id: fabric.fabric_id,
        failsafe_armed: -> { general_commissioning.failsafe_armed? },
        vendor_id_verified: ->(_index : UInt8) { true },
        open_window: ->(request : Admin::OpenJointCommissioningWindowRequest) { open_joint_window(request, fabric) },
        transfer_authorized: ->(_node_id : UInt64) { ENV["MATTER_JFA_ALLOW_TRANSFER"]? == "1" },
        datastore_busy: -> { joint_fabric_datastore.transfer_busy? },
        begin_transfer: -> { begin_anchor_transfer },
        complete_transfer: -> {
          persist_anchor_role(false, transfer_complete: true)
          if bootstrap_joint_fabric_datastore.joint_fabric_index == fabric.fabric_index
            persist_bootstrap_anchor_role(false, transfer_complete: true)
          end
          lifecycle.sync_advertisements
          nil
        },
        on_transfer_requested: ->(node_id : UInt64, index : UInt8) { record_transfer_candidate(node_id, index) },
        initial_transfer_requester: persisted_transfer_requester(fabric, datastore),
        initial_icac: persisted_icac,
        persist_icac: ->(certificate : Bytes?) { persist_icac(certificate, APP_ICAC_DOCUMENT, administrator) },
        verify_anchor_initiator: ->(node_id : UInt64, index : UInt8, source : Socket::IPAddress) {
          verify_anchor_initiator(node_id, index, source)
        },
        resolve_accessing_fabric: ->(index : UInt8) { accessing_fabric_identity(index) },
        existing_icac_certificate: icac,
        icac_csr_provider: remote_csr_provider,
        failsafe_fabric_matches: ->(index : UInt8?) {
          if context = general_commissioning.failsafe_context
            context.armed? && !index.nil? &&
            (context.associated_fabric_index == index ||
             (context.associated_fabric_index.nil? && context.added_fabric_index == index))
          else
            false
          end
        }
      )
      @unprovisioned_service_fabric_index = nil
      configure_propagator(fabric, root)
      configure_bootstrap_datastore(fabric, root, icac, key)
    end

    private def configure_bootstrap_datastore(fabric : Matter::Fabric, root : Bytes, icac : Bytes,
                                              key : Matter::Crypto::Key?) : Nil
      return unless ENV["MATTER_JFA_KEEP_BOOTSTRAP_DATASTORE"]? == "1"
      bootstrap = begin
        provisioned_anchor_bootstrap(fabric).fabric
      rescue Matter::ConfigurationError
        return
      end
      return unless bootstrap.fabric_id == fabric.fabric_id &&
                    bootstrap.root_public_key == fabric.root_public_key

      datastore = bootstrap_joint_fabric_datastore
      administrator = bootstrap_joint_fabric_administrator
      administrator.administrator_fabric_index = fabric.fabric_index
      remote_csr_provider = ENV["MATTER_JFA_ICAC_CSR_MAILBOX_PATH"]?.try do |path|
        Matter::Commissioning::RemoteIcacCsrProvider.new(path, fabric.fabric_id, fabric.root_public_key)
      end
      datastore.joint_fabric_index = fabric.fabric_index
      role = bootstrap_role_state
      datastore.access_mode = if role.anchor?
                                Datastore::AccessMode::Active
                              elsif role.transfer_complete?
                                Datastore::AccessMode::Inactive
                              else
                                Datastore::AccessMode::Frozen
                              end
      datastore.configure_anchor(root, fabric.node_id, fabric.vendor_id, "Bootstrap Anchor", fabric.ipk)
      seed_joint_fabric_groups(datastore)
      seed_anchor_administrator(datastore, fabric, icac)
      administrator.service = Matter::Commissioning::JointFabricAdministratorService.new(
        icac_private_key: key,
        root_certificate: root,
        fabric_id: fabric.fabric_id,
        failsafe_armed: -> { general_commissioning.failsafe_armed? },
        vendor_id_verified: ->(_index : UInt8) { true },
        open_window: ->(request : Admin::OpenJointCommissioningWindowRequest) {
          open_bootstrap_joint_window(request, fabric)
        },
        transfer_authorized: ->(_node_id : UInt64) { ENV["MATTER_JFA_ALLOW_TRANSFER"]? == "1" },
        datastore_busy: -> { datastore.transfer_busy? },
        begin_transfer: -> { begin_bootstrap_anchor_transfer },
        complete_transfer: -> {
          persist_bootstrap_anchor_role(false, transfer_complete: true)
          if joint_fabric_datastore.joint_fabric_index == fabric.fabric_index
            persist_anchor_role(false, transfer_complete: true)
          end
          lifecycle.sync_advertisements
          nil
        },
        on_transfer_requested: ->(node_id : UInt64, index : UInt8) {
          record_bootstrap_transfer_candidate(node_id, index)
        },
        initial_transfer_requester: persisted_transfer_requester(fabric, datastore,
          APP_BOOTSTRAP_TRANSFER_WATCH_DOCUMENT),
        initial_icac: persisted_icac(APP_BOOTSTRAP_ICAC_DOCUMENT),
        persist_icac: ->(certificate : Bytes?) { persist_icac(certificate, APP_BOOTSTRAP_ICAC_DOCUMENT, administrator) },
        verify_anchor_initiator: ->(node_id : UInt64, index : UInt8, source : Socket::IPAddress) {
          verify_anchor_initiator(node_id, index, source)
        },
        resolve_accessing_fabric: ->(index : UInt8) { accessing_fabric_identity(index) },
        existing_icac_certificate: icac,
        icac_csr_provider: remote_csr_provider,
        failsafe_fabric_matches: ->(index : UInt8?) {
          if context = general_commissioning.failsafe_context
            context.armed? && !index.nil? &&
            (context.associated_fabric_index == index ||
             (context.associated_fabric_index.nil? && context.added_fabric_index == index))
          else
            false
          end
        }
      )
      if role.transfer_complete?
        administrator.administrator_fabric_index = nil
        administrator.service = nil
      end
      unless persistence.save_cluster(datastore)
        raise Matter::StorageError.new("Could not persist bootstrap Joint Fabric Datastore")
      end
      @bootstrap_datastore_propagator.try(&.stop!)
      store = @controller_store || Matter::Controller::StateStore.new(persistence.backend)
      delivery = Matter::Controller::DatastorePropagator::NetworkDelivery.new(
        store,
        fabric_id: fabric.fabric_id,
        root_public_key: fabric.root_public_key,
        controller_node_id: fabric.node_id,
        peer_hints: configured_peer_hints
      )
      @bootstrap_datastore_propagator = Matter::Controller::DatastorePropagator.new(datastore, delivery)
      @bootstrap_datastore_propagator.try(&.start) if @propagation_started
    end

    # JCM leaves the bootstrap fabric in place. Its JFA stays on endpoint 2,
    # while endpoint 1 follows the committed cross-signed ICAC onto the joined
    # fabric. Match both fabric identity and certificate before rebinding.
    private def attach_joined_fabric(fabric : Matter::Fabric) : Nil
      # A promoted Anchor may still retain the former Anchor fabric for its
      # controller journal. Its persisted Anchor role owns endpoint 1 now;
      # loading that residual joined fabric must not replace the copied store.
      if document = persistence.app_document(APP_ROLE_DOCUMENT)
        if JointFabricRoleState.from_document(document).anchor? &&
           joint_fabric_datastore.joint_fabric_index != fabric.fabric_index
          return
        end
      end
      certificate = persisted_icac
      unless certificate && joined_icac_matches_fabric?(certificate, fabric)
        ::Log.for("matter.example.joint_fabric_administrator").info do
          "Joined JFA activation skipped: committed ICAC #{certificate ? "mismatches" : "absent for"} fabric 0x#{fabric.fabric_id.to_s(16)}"
        end
        return
      end
      return if compliant_anchor_fabric?(fabric)
      root = fabric.root_cert || raise Matter::ConfigurationError.new("Joined Joint Fabric root is unavailable")
      remote_csr_provider = ENV["MATTER_JFA_ICAC_CSR_MAILBOX_PATH"]?.try do |path|
        Matter::Commissioning::RemoteIcacCsrProvider.new(path, fabric.fabric_id, fabric.root_public_key)
      end
      key = remote_csr_provider ? nil : provisioned_icac_key(fabric, certificate)
      unless key || remote_csr_provider
        raise Matter::ConfigurationError.new("Joined JFA ICAC private key is unavailable")
      end
      return if joint_fabric_datastore.joint_fabric_index == fabric.fabric_index &&
                joint_fabric_administrator.administrator_fabric_index == fabric.fabric_index &&
                joint_fabric_service.try(&.cross_signed_icac) == certificate

      grant_administrator_cat_access(fabric)
      unless persistence.app_document(APP_ROLE_DOCUMENT)
        persistence.write_app_document(APP_ROLE_DOCUMENT, JointFabricRoleState.new(false).to_document)
      end
      @anchor_role = persisted_anchor_role
      @joint_fabric_provisioned = true
      datastore = joint_fabric_datastore
      @datastore_propagator.try(&.stop!)
      @datastore_propagator = nil
      datastore.clear_fabric_state if datastore.joint_fabric_index != fabric.fabric_index
      datastore.joint_fabric_index = fabric.fabric_index
      datastore.access_mode = @anchor_role ? Datastore::AccessMode::Active : Datastore::AccessMode::Inactive
      administrator = joint_fabric_administrator
      administrator.administrator_fabric_index = fabric.fabric_index
      administrator.service = Matter::Commissioning::JointFabricAdministratorService.new(
        icac_private_key: key,
        root_certificate: root,
        fabric_id: fabric.fabric_id,
        failsafe_armed: -> { general_commissioning.failsafe_armed? },
        vendor_id_verified: ->(_index : UInt8) { true },
        open_window: ->(request : Admin::OpenJointCommissioningWindowRequest) { open_joint_window(request, fabric) },
        transfer_authorized: ->(_node_id : UInt64) { ENV["MATTER_JFA_ALLOW_TRANSFER"]? == "1" },
        datastore_busy: -> { datastore.transfer_busy? },
        begin_transfer: -> { begin_anchor_transfer },
        complete_transfer: -> { persist_anchor_role(false, transfer_complete: true); lifecycle.sync_advertisements; nil },
        on_transfer_requested: ->(node_id : UInt64, index : UInt8) { record_transfer_candidate(node_id, index) },
        initial_transfer_requester: persisted_transfer_requester(fabric, datastore),
        initial_icac: certificate,
        persist_icac: ->(value : Bytes?) { persist_icac(value, APP_ICAC_DOCUMENT, administrator) },
        verify_anchor_initiator: ->(node_id : UInt64, index : UInt8, source : Socket::IPAddress) {
          verify_anchor_initiator(node_id, index, source)
        },
        resolve_accessing_fabric: ->(index : UInt8) { accessing_fabric_identity(index) },
        existing_icac_certificate: certificate,
        icac_csr_provider: remote_csr_provider,
        failsafe_fabric_matches: ->(index : UInt8?) {
          if context = general_commissioning.failsafe_context
            context.armed? && !index.nil? &&
            (context.associated_fabric_index == index ||
             (context.associated_fabric_index.nil? && context.added_fabric_index == index))
          else
            false
          end
        }
      )
      @unprovisioned_service_fabric_index = nil
      unless persistence.save_cluster(administrator) && persistence.save_cluster(datastore)
        raise Matter::StorageError.new("Could not persist joined Joint Fabric Administrator endpoints")
      end
      persistence.flush
    end

    # The operational NOC chains through the Anchor ICAC, while the JFA's
    # committed cross-signed ICAC certifies the JFA signing key. A local JFA
    # proves possession with its private key; an SDK-owned JFA delegates CSR
    # signing to its authenticated remote provider and retains the operational
    # ICAC public key while allowing the cross-signer a distinct ICAC ID.
    private def joined_icac_matches_fabric?(certificate : Bytes, fabric : Matter::Fabric) : Bool
      installed = fabric.intermediate_cert || return false
      root = fabric.root_cert || return false
      committed_icac = Matter::Crypto::MatterCertificate.from_slice(certificate)
      installed_icac = Matter::Crypto::MatterCertificate.from_slice(installed)
      remote_signer = !!ENV["MATTER_JFA_ICAC_CSR_MAILBOX_PATH"]?
      expected_identity = remote_signer ? committed_icac.ec_public_key == installed_icac.ec_public_key : committed_icac.subject.icac_id == installed_icac.subject.icac_id
      unless committed_icac.subject.fabric_id == fabric.fabric_id &&
             committed_icac.subject.icac_id && expected_identity
        ::Log.for("matter.example.joint_fabric_administrator").info { "Joined JFA committed and installed ICAC identities differ" }
        return false
      end
      Matter::Crypto::MatterCertificate::Validation.verify_intermediate_profile(certificate, fabric.fabric_id)
      Matter::Crypto::MatterCertificate::Validation.verify_issued_by(certificate, root)
      Matter::Crypto::MatterCertificate::Validation.verify_signature(certificate, fabric.root_public_key)
      true
    rescue error : Matter::Error
      ::Log.for("matter.example.joint_fabric_administrator").info(exception: error) { "Joined JFA committed ICAC validation failed" }
      false
    end

    private def grant_administrator_cat_access(fabric : Matter::Fabric) : Nil
      acl = access_control
      version = fabric.cats.find(&.identity_value.==(0xFFFF_u16)).try(&.version) || 1_u16
      subject = Matter::DataType::NodeId.from_case_authenticated_tag(
        Matter::DataType::CaseAuthenticatedTag.create(0xFFFF_u16, version)).id
      return if acl.get_acl_for_fabric(fabric.fabric_index).any? do |entry|
                  subjects = entry.subjects
                  subjects.nil? || subjects.empty? || subjects.includes?(subject)
                end

      entries = acl.acl.dup
      entries << Matter::Cluster::AccessControl::AccessControlEntry.new(
        Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer,
        Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
        [subject], nil, fabric.fabric_index)
      previous_context = acl.request_fabric_index
      begin
        acl.request_fabric_index = nil
        acl.acl = entries
      ensure
        acl.request_fabric_index = previous_context
      end
      unless persistence.save_cluster(acl)
        raise Matter::StorageError.new("Could not persist Joint Fabric Administrator CAT ACL")
      end
    end

    private def configure_propagator(fabric : Matter::Fabric, root : Bytes) : Nil
      @datastore_propagator.try(&.stop!)
      store = Matter::Controller::StateStore.new(persistence.backend)
      state = store.load
      existing = state.fabrics.find do |candidate|
        candidate.fabric_id == fabric.fabric_id &&
          candidate.root_public_key == fabric.root_public_key &&
          candidate.controller_node_id == fabric.node_id
      end
      bootstrap_info = if (path = ENV["MATTER_JFA_BOOTSTRAP_STATE_PATH"]?) && File.exists?(path)
                         begin
                           provisioned_anchor_bootstrap(fabric).fabric
                         rescue Matter::ConfigurationError
                           existing
                         end
                       else
                         existing
                       end
      if existing && (existing.controller_noc != fabric.operational_cert ||
         existing.controller_private_key != fabric.operational_private_key ||
         existing.ipk_value != fabric.ipk || existing.intermediate_cert != fabric.intermediate_cert ||
         existing.root_private_key != bootstrap_info.try(&.root_private_key) ||
         existing.intermediate_private_key != bootstrap_info.try(&.intermediate_private_key))
        state.remove_fabric(fabric.fabric_id, fabric.root_public_key, fabric.node_id)
        existing = nil
      end
      unless existing
        state.install_fabric(Matter::Controller::FabricInfo.new(
          fabric_id: fabric.fabric_id,
          controller_node_id: fabric.node_id,
          ipk_value: fabric.ipk,
          root_cert: root,
          root_public_key: fabric.root_public_key,
          controller_noc: fabric.operational_cert,
          controller_private_key: fabric.operational_private_key,
          root_private_key: bootstrap_info.try(&.root_private_key),
          admin_vendor_id: fabric.vendor_id,
          intermediate_cert: fabric.intermediate_cert,
          intermediate_private_key: bootstrap_info.try(&.intermediate_private_key)
        ))
        store.save(state)
      end
      delivery = Matter::Controller::DatastorePropagator::NetworkDelivery.new(
        store,
        fabric_id: fabric.fabric_id,
        root_public_key: fabric.root_public_key,
        controller_node_id: fabric.node_id,
        peer_hints: configured_peer_hints
      )
      @datastore_propagator = Matter::Controller::DatastorePropagator.new(joint_fabric_datastore, delivery)
      @controller_store = store
      @propagation_fabric = fabric
      @datastore_propagator.try(&.start) if @propagation_started && joint_fabric_datastore.access_mode.active?
    end

    private def seed_joint_fabric_groups(datastore : Datastore) : Nil
      unless datastore.group_list.any?(&.group_cat.==(0xFFFF_u16))
        datastore.seed_reserved_cat_group(ADMIN_GROUP_ID, "Administrators", 0xFFFF_u16, 1_u16)
      end
      unless datastore.group_list.any?(&.group_cat.==(0xFFFE_u16))
        datastore.seed_reserved_cat_group(ANCHOR_GROUP_ID, "Anchors", 0xFFFE_u16, 1_u16)
      end
    end

    private def seed_anchor_administrator(datastore : Datastore, fabric : Matter::Fabric, icac : Bytes) : Nil
      return if datastore.admin_list.any?(&.node_id.==(fabric.node_id))
      datastore.add_admin(Datastore::AddAdminRequest.new(
        fabric.node_id, "Crystal Anchor", fabric.vendor_id, icac))
    end

    private def connect_failsafe_lifecycle : Nil
      armed = general_commissioning.on_failsafe_armed
      expired = general_commissioning.on_failsafe_expired
      succeeded = general_commissioning.on_failsafe_success
      general_commissioning.on_failsafe_armed = -> do
        armed.try(&.call)
        if administrator_commissioning.window.joint_window? && !general_commissioning.request_is_case_session?
          @jcm_failsafe_session_id = general_commissioning.request_session_id
        end
        joint_fabric_service.try(&.reset_failsafe)
        bootstrap_joint_fabric_service.try(&.reset_failsafe)
      end
      general_commissioning.on_failsafe_expired = -> do
        expired.try(&.call)
        @jcm_failsafe_session_id = nil
        joint_fabric_service.try(&.on_failsafe_expired)
        bootstrap_joint_fabric_service.try(&.on_failsafe_expired)
      end
      general_commissioning.on_failsafe_success = -> do
        succeeded.try(&.call)
        @jcm_failsafe_session_id = nil
        joint_fabric_service.try(&.on_commissioning_complete)
        bootstrap_joint_fabric_service.try(&.on_commissioning_complete)
        fabric_table.all_fabrics.each { |fabric| attach_joined_fabric(fabric) }
      end
    end

    private def joint_fabric_service : Matter::Commissioning::JointFabricAdministratorService?
      joint_fabric_administrator.service.as?(Matter::Commissioning::JointFabricAdministratorService)
    end

    private def bootstrap_joint_fabric_service : Matter::Commissioning::JointFabricAdministratorService?
      bootstrap_joint_fabric_administrator.service.as?(Matter::Commissioning::JointFabricAdministratorService)
    end

    private def persisted_icac(document_name : String = APP_ICAC_DOCUMENT) : Bytes?
      document = persistence.app_document(document_name)
      document ? IcacCertificateState.from_document(document).certificate : nil
    end

    private def persist_icac(certificate : Bytes?, document_name : String,
                             administrator : Admin) : Nil
      # The service exposes the post-commit cluster document while this
      # callback runs. Both documents must reach the backend together: a
      # restart after this transaction must restore the committed index.
      cluster_document = administrator.save_state ||
                         raise Matter::StorageError.new("JFA cluster has no persistent state")
      backend = persistence.backend
      app_collection = Matter::Storage::Collections::APP
      cluster_collection = Matter::Storage::Collections::CLUSTERS
      cluster_key = administrator.persistence_key
      backend.transaction do
        if certificate
          backend.write(app_collection, document_name, IcacCertificateState.new(certificate).to_document)
        else
          backend.delete(app_collection, document_name)
        end
        backend.write(cluster_collection, cluster_key, cluster_document)
      end
    end

    private def bootstrap_anchor_role? : Bool
      bootstrap_role_state.anchor?
    end

    private def bootstrap_role_state : JointFabricRoleState
      document = persistence.app_document(APP_BOOTSTRAP_ROLE_DOCUMENT)
      document ? JointFabricRoleState.from_document(document) : JointFabricRoleState.new(true)
    end

    private def persist_bootstrap_anchor_role(anchor : Bool, transfer_complete : Bool = false) : Nil
      persistence.write_app_document(APP_BOOTSTRAP_ROLE_DOCUMENT,
        JointFabricRoleState.new(anchor, transfer_complete).to_document)
      bootstrap_joint_fabric_datastore.access_mode = if anchor
                                                       Datastore::AccessMode::Active
                                                     elsif transfer_complete
                                                       Datastore::AccessMode::Inactive
                                                     else
                                                       Datastore::AccessMode::Frozen
                                                     end
      @bootstrap_datastore_propagator.try(&.start) if anchor && @propagation_started
    end

    private def begin_bootstrap_anchor_transfer : Nil
      unless bootstrap_joint_fabric_datastore.begin_anchor_transfer
        raise Matter::ConfigurationError.new("Bootstrap Datastore changed while Anchor transfer was starting")
      end
      @bootstrap_datastore_propagator.try(&.stop!)
      if joint_fabric_datastore.joint_fabric_index == bootstrap_joint_fabric_datastore.joint_fabric_index
        unless joint_fabric_datastore.status.state.delete_pending? || joint_fabric_datastore.begin_anchor_transfer
          raise Matter::ConfigurationError.new("Joint Datastore changed while bootstrap Anchor transfer was starting")
        end
        @datastore_propagator.try(&.stop!)
        persist_anchor_role(false)
      end
      persist_bootstrap_anchor_role(false)
      lifecycle.sync_advertisements
    end

    private def record_bootstrap_transfer_candidate(node_id : UInt64, fabric_index : UInt8) : Nil
      fabric = fabric_table.get_fabric(fabric_index) ||
               raise Matter::AuthenticationError.new("Bootstrap transfer requester fabric is unavailable")
      unless bootstrap_joint_fabric_datastore.joint_fabric_index == fabric_index && node_id != 0_u64
        raise Matter::AuthenticationError.new("Transfer requester is not on the bootstrap fabric")
      end
      persistence.write_app_document(APP_BOOTSTRAP_TRANSFER_WATCH_DOCUMENT,
        TransferWatchState.new(node_id, fabric.fabric_id, fabric.root_public_key,
          configured_new_anchor_node_id(node_id)).to_document)
      persistence.flush
    end

    private def persisted_anchor_role : Bool
      document = persistence.app_document(APP_ROLE_DOCUMENT)
      document ? JointFabricRoleState.from_document(document).anchor? : true
    end

    private def persisted_transfer_complete? : Bool
      document = persistence.app_document(APP_ROLE_DOCUMENT)
      document ? JointFabricRoleState.from_document(document).transfer_complete? : false
    end

    private def persist_anchor_role(anchor : Bool, transfer_complete : Bool = false) : Nil
      persistence.write_app_document(APP_ROLE_DOCUMENT, JointFabricRoleState.new(anchor, transfer_complete).to_document)
      @anchor_role = anchor
      joint_fabric_datastore.access_mode = if anchor
                                             Datastore::AccessMode::Active
                                           elsif transfer_complete
                                             Datastore::AccessMode::Inactive
                                           else
                                             Datastore::AccessMode::Frozen
                                           end
      @datastore_propagator.try(&.start) if anchor && @propagation_started
    end

    private def begin_anchor_transfer : Nil
      unless joint_fabric_datastore.begin_anchor_transfer
        raise Matter::ConfigurationError.new("Datastore changed while Anchor transfer was starting")
      end
      @datastore_propagator.try(&.stop!)
      if bootstrap_joint_fabric_datastore.joint_fabric_index == joint_fabric_datastore.joint_fabric_index
        begin_bootstrap_anchor_transfer
      end
      persist_anchor_role(false)
      lifecycle.sync_advertisements
    end

    private def record_transfer_candidate(node_id : UInt64, fabric_index : UInt8) : Nil
      fabric = fabric_table.get_fabric(fabric_index) ||
               raise Matter::AuthenticationError.new("Transfer requester fabric is unavailable")
      unless joint_fabric_datastore.joint_fabric_index == fabric_index && node_id != 0_u64
        raise Matter::AuthenticationError.new("Transfer requester is not on the Anchor fabric")
      end
      new_anchor_node_id = configured_new_anchor_node_id(node_id)
      persistence.write_app_document(APP_TRANSFER_WATCH_DOCUMENT,
        TransferWatchState.new(node_id, fabric.fabric_id, fabric.root_public_key, new_anchor_node_id).to_document)
      persistence.flush
      @participant_view_current = false
      ::Log.for("matter.example.joint_fabric_administrator").info do
        "Recorded authenticated Anchor transfer requester 0x#{node_id.to_s(16)}"
      end
    end

    private def persisted_transfer_requester(fabric : Matter::Fabric,
                                             datastore : Datastore,
                                             document_name : String = APP_TRANSFER_WATCH_DOCUMENT) : Tuple(UInt64, UInt8)?
      return unless datastore.status.state.delete_pending?
      document = persistence.app_document(document_name)
      return unless document
      watch = TransferWatchState.from_document(document)
      return unless watch.old_fabric_id == fabric.fabric_id &&
                    watch.old_root_public_key == fabric.root_public_key &&
                    watch.requester_node_id != 0_u64
      {watch.requester_node_id, fabric.fabric_index}
    end

    # The wire request identifies B on the old fabric. A local, provisioned
    # mapping binds that authenticated identity to B's Node ID on its own fabric.
    # Without this binding the old Anchor remains fail closed after transfer.
    private def configured_new_anchor_node_id(requester_node_id : UInt64) : UInt64?
      entries = ENV["MATTER_JFA_TRANSFER_CANDIDATE_IDS"]?
      return unless entries
      matching = entries.split(',').select do |entry|
        entry.split('=', 2).first.to_u64?(16) == requester_node_id
      end
      raise Matter::ConfigurationError.new("Duplicate Anchor candidate mapping") if matching.size > 1
      return if matching.empty?
      value = matching.first.split('=', 2)[1]?.try(&.to_u64?(16))
      if value.nil? || value == 0_u64
        raise Matter::ConfigurationError.new("Invalid new Anchor Node ID mapping")
      end
      value
    end

    private def poll_new_anchor_subscription : Nil
      return if @watch_stopped || @watch_polling || general_commissioning.failsafe_armed?
      document = persistence.app_document(APP_TRANSFER_WATCH_DOCUMENT)
      return unless document
      watch = TransferWatchState.from_document(document)
      new_anchor_node_id = watch.new_anchor_node_id
      unless new_anchor_node_id
        @participant_view_current = false
        return
      end
      candidates = fabric_table.all_fabrics.select do |fabric|
        fabric.fabric_id != watch.old_fabric_id || fabric.root_public_key != watch.old_root_public_key
      end
      unless candidates.size == 1
        @participant_view_current = false
        close_new_anchor_subscription
        return
      end
      fabric = candidates.first
      invalidate_new_anchor_subscription_unless(fabric.fabric_id, fabric.root_public_key)
      @watch_polling = true
      begin
        subscription = @new_anchor_subscription
        if subscription
          status = subscription.poll_status(100.milliseconds) || subscription.last_status
        else
          root = fabric.root_cert || raise Matter::ConfigurationError.new("New Anchor fabric has no root certificate")
          identity = Matter::Controller::FabricInfo.new(
            fabric_id: fabric.fabric_id, controller_node_id: fabric.node_id,
            ipk_value: fabric.ipk, root_cert: root, root_public_key: fabric.root_public_key,
            controller_noc: fabric.operational_cert,
            controller_private_key: fabric.operational_private_key,
            admin_vendor_id: fabric.vendor_id,
            intermediate_cert: fabric.intermediate_cert)
          scanner = Matter::Controller::Scanner.new
          scanner.start
          @new_anchor_scanner = scanner
          subscription = Matter::Controller::AnchorDatastoreSubscription.new(
            scanner, identity, new_anchor_node_id, nil,
            ->(_im : Matter::Controller::ImClient, session : Matter::Session::SecureContext, _peer : Socket::IPAddress) { verify_new_anchor_session!(session) },
            address_hint: configured_transfer_peer(new_anchor_node_id))
          @new_anchor_subscription = subscription
          @subscribed_fabric_id = fabric.fabric_id
          @subscribed_root_public_key = fabric.root_public_key.dup
          status = subscription.initial_status
        end
        @participant_view_current = status.state == Datastore::DatastoreStateEnum::Committed
      rescue ex : Matter::Error | IO::Error | ArgumentError
        @participant_view_current = false
        close_new_anchor_subscription
        ::Log.for("matter.example.joint_fabric_administrator").warn(exception: ex) do
          "New Anchor Datastore subscription is unavailable; participant view is stale"
        end
      ensure
        @watch_polling = false
      end
    end

    private def verify_new_anchor_session!(session : Matter::Session::SecureContext) : Nil
      has_anchor_cat = session.peer_subject_ids.any? do |subject|
        node = Matter::DataType::NodeId.new(subject)
        if node.case_authenticated_tag?
          cat = node.extract_as_case_authenticated_tag
          cat.identity_value == 0xFFFE_u16 && cat.version > 0_u16
        else
          false
        end
      end
      raise Matter::AuthenticationError.new("New Anchor CASE peer lacks Anchor CAT") unless has_anchor_cat
      icac = session.peer_icac || raise Matter::AuthenticationError.new("New Anchor CASE peer lacks ICAC")
      subject = TLV::Any.from_slice(icac).as_structure[Matter::Crypto::MatterCertificate::Asn1::Field::Subject.value].as_list
      unless subject.any? do |entry|
               entry.header.ids == Matter::Crypto::MatterCertificate::Asn1::Dn::OrgUnitName.value &&
               entry.as_s? == Matter::Crypto::MatterCertificate::Builder::ANCHOR_ICAC_ORGANIZATIONAL_UNIT
             end
        raise Matter::AuthenticationError.new("New Anchor ICAC lacks jf-anchor-icac organization unit")
      end
    end

    private def close_new_anchor_subscription : Nil
      @new_anchor_subscription.try(&.close)
      @new_anchor_subscription = nil
      @new_anchor_scanner.try(&.close)
      @new_anchor_scanner = nil
      @subscribed_fabric_id = nil
      @subscribed_root_public_key = nil
    end

    private def invalidate_new_anchor_subscription_unless(fabric_id : UInt64, root_public_key : Bytes) : Nil
      return unless @subscribed_fabric_id
      return if @subscribed_fabric_id == fabric_id && @subscribed_root_public_key == root_public_key
      @participant_view_current = false
      close_new_anchor_subscription
    end

    # An explicit console command is the candidate's user consent. Resolve
    # all peers and obtain a consistent committed Datastore before asking the
    # old Anchor to freeze; network operations after that point are journaled.
    private def transfer_anchor_from(old_anchor_node_id : UInt64,
                                     interrupt_before_follow_up : Bool = false,
                                     interrupt_after_request : Bool = false) : Nil
      raise Matter::ConfigurationError.new("Anchor transfer already running") if @transfer_in_progress
      own_fabric = @propagation_fabric || raise Matter::ConfigurationError.new("Candidate Anchor fabric is not provisioned")
      old_fabrics = fabric_table.all_fabrics.select do |fabric|
        fabric.root_public_key != own_fabric.root_public_key &&
          fabric.cats.any?(&.identity_value.==(0xFFFF_u16))
      end
      unless old_fabrics.size == 1
        raise Matter::ConfigurationError.new("Candidate must have exactly one joined Joint Fabric with Administrator CAT")
      end
      old_fabric = old_fabrics.first
      bootstrap = provisioned_anchor_bootstrap(own_fabric)
      old_identity = Matter::Controller::FabricInfo.new(
        fabric_id: old_fabric.fabric_id, controller_node_id: old_fabric.node_id,
        ipk_value: old_fabric.ipk, root_cert: old_fabric.root_cert.as(Bytes),
        root_public_key: old_fabric.root_public_key,
        controller_noc: old_fabric.operational_cert,
        controller_private_key: old_fabric.operational_private_key,
        admin_vendor_id: old_fabric.vendor_id,
        intermediate_cert: old_fabric.intermediate_cert)
      scanner = Matter::Controller::Scanner.new
      old_client = Matter::Controller::Client.new(unsecured_source_node_id: old_fabric.node_id)
      own_client = Matter::Controller::Client.new(unsecured_source_node_id: bootstrap.fabric.controller_node_id)
      own_im = Matter::Controller::ImClient.new(own_client)
      journal = if document = persistence.app_document(APP_TRANSFER_DOCUMENT)
                  Matter::Controller::AnchorTransfer::Journal.from_document(document)
                else
                  Matter::Controller::AnchorTransfer::Journal.new(old_fabric.node_id)
                end
      unless journal.candidate_node_id == old_fabric.node_id
        raise Matter::ConfigurationError.new("Existing transfer journal belongs to another candidate")
      end
      @transfer_in_progress = true
      begin
        return if journal.stage.completed?
        scanner.start
        scanner.query_operational
        if journal.stage.transferred? || journal.stage.following_up?
          follow_up_administrators(joint_fabric_datastore, old_fabric, scanner, own_client, own_im)
          journal.stage = Matter::Controller::AnchorTransfer::Stage::Completed
          persistence.write_app_document(APP_TRANSFER_DOCUMENT, journal.to_document)
          persistence.flush
          return
        end
        old_peer = resolve_transfer_peer(scanner, old_identity.compressed_fabric_id, old_anchor_node_id)
        old_session = Matter::Controller::Pairing::CasePairing.new.pair(old_client, old_peer,
          old_identity, peer_node_id: old_anchor_node_id)
        old_im = Matter::Controller::ImClient.new(old_client)
        old_endpoint = Matter::Controller::JointCommissioning.discover_administrator_endpoint(
          old_im, old_session, old_peer)
        # Requesting may mean the old Anchor froze its Datastore before the
        # acknowledgement was lost. Read both valid states over CASE, then
        # resolve that uncertainty before the workflow can send a request.
        expected_frozen = if journal.stage.ready?
                            false
                          elsif journal.stage.requesting?
                            nil
                          else
                            true
                          end
        preflight = Matter::Controller::AnchorTransfer::Snapshot.read_remote(old_im, old_session, old_peer,
          old_endpoint, require_frozen: expected_frozen)
        if journal.stage.requesting? && preflight.status.state.delete_pending?
          raise Matter::CommissioningError.new("Frozen Anchor transfer needs authenticated requester reconciliation")
        end
        unless preflight.anchor_node_id == old_anchor_node_id
          raise Matter::AuthenticationError.new("Discovered node is not the Datastore Anchor")
        end
        # Verify that each participant supplied a usable ICAC before freezing A.
        preflight.admin_list.each do |admin|
          next if admin.node_id == old_fabric.node_id
          certificate = Matter::Crypto::MatterCertificate.from_slice(admin.icac)
          unless certificate.subject.icac_id
            raise Matter::ConfigurationError.new("Administrator 0x#{admin.node_id.to_s(16)} lacks an ICAC ID")
          end
          Matter::Crypto::MatterCertificate.public_key_from_tlv(admin.icac)
        end
        admin_version = next_transfer_cat_version(preflight, 0xFFFF_u16)
        anchor_version = next_transfer_cat_version(preflight, 0xFFFE_u16)

        rotations = [] of Matter::Controller::AnchorTransfer::CredentialTransition
        preflight.admin_list.each do |admin|
          node_id = admin.node_id
          next if node_id == old_fabric.node_id
          peer = node_id == old_anchor_node_id ? old_peer : resolve_transfer_peer(scanner, old_identity.compressed_fabric_id, node_id)
          session = node_id == old_anchor_node_id ? old_session : Matter::Controller::Pairing::CasePairing.new.pair(old_client, peer,
            old_identity, peer_node_id: node_id)
          rotations << Matter::Controller::AnchorTransfer::AdministratorRotation.new(old_client, old_im,
            session, peer, node_id, bootstrap, admin_version, anchor_version)
        end

        own_peer = Socket::IPAddress.new("127.0.0.1", port)
        own_session = Matter::Controller::Pairing::CasePairing.new.pair(own_client, own_peer,
          bootstrap.fabric, peer_node_id: own_fabric.node_id)
        own_rotation = Matter::Controller::AnchorTransfer::AdministratorRotation.new(own_client, own_im,
          own_session, own_peer, own_fabric.node_id, bootstrap,
          admin_version, anchor_version, anchor_target: true,
          existing_fabric: true, existing_fabric_index: own_fabric.fabric_index)
        own_icac = bootstrap.fabric.intermediate_cert ||
                   raise Matter::ConfigurationError.new("Candidate Anchor ICAC is unavailable")
        candidate_administrator = Datastore::DatastoreAdministratorInformationEntryStruct.new(
          own_fabric.node_id, "Crystal Anchor", own_fabric.vendor_id, own_icac)
        migration = Matter::Controller::AnchorTransfer::RotationMigration.new(old_im, old_session, old_peer,
          old_endpoint, joint_fabric_datastore, own_fabric.node_id, bootstrap,
          rotations, own_rotation,
          -> { persistence.save_cluster(joint_fabric_datastore); persistence.flush; nil },
          -> {
            select_anchor_administrator_fabric(own_fabric.fabric_index)
            configure_propagator(own_fabric, bootstrap.fabric.root_cert)
            persist_anchor_role(true)
            @transfer_in_progress = false
            lifecycle.sync_advertisements
            nil
          },
          administrator_cat_version: admin_version,
          anchor_cat_version: anchor_version,
          candidate_old_node_id: old_fabric.node_id,
          candidate_administrator: candidate_administrator,
          finalize_administrators: -> {
            if interrupt_before_follow_up
              raise Matter::TransportError.new("Injected interruption before Anchor transfer follow-up")
            end
            follow_up_administrators(preflight, old_fabric, scanner, own_client, own_im)
            nil
          })
        port = Matter::Controller::AnchorTransfer::ImPort.new(old_im, old_session, old_peer, old_endpoint)
        transfer_port = interrupt_after_request ? InterruptedTransferPort.new(port) : port
        workflow = Matter::Controller::AnchorTransfer::Workflow.new(preflight,
          transfer_port, migration,
          -> { true },
          ->(state : Matter::Controller::AnchorTransfer::Journal) {
            persistence.write_app_document(APP_TRANSFER_DOCUMENT, state.to_document)
            persistence.flush
            nil
          }, journal)
        workflow.reconcile_request!(preflight.status.state) if journal.stage.requesting?
        workflow.run
      ensure
        @transfer_in_progress = false
        old_client.close
        own_client.close
        scanner.close
      end
    end

    # After candidate promotion, VID verification must inspect this device's
    # new Anchor fabric. JCM may have pointed the attribute at the joined old
    # Anchor fabric, so persist the switch before participant follow-up.
    private def select_anchor_administrator_fabric(index : UInt8) : Nil
      cluster = joint_fabric_administrator
      cluster.administrator_fabric_index = index
      joint_fabric_datastore.joint_fabric_index = index
      @bootstrap_datastore_propagator.try(&.stop!)
      persist_bootstrap_anchor_role(false, transfer_complete: true)
      bootstrap_joint_fabric_administrator.administrator_fabric_index = nil
      bootstrap_joint_fabric_administrator.service = nil
      unless persistence.save_cluster(cluster) &&
             persistence.save_cluster(joint_fabric_datastore) &&
             persistence.save_cluster(bootstrap_joint_fabric_administrator) &&
             persistence.save_cluster(bootstrap_joint_fabric_datastore)
        raise Matter::StorageError.new("Could not persist promoted Anchor Datastore and Administrator endpoints")
      end
      persistence.flush
    end

    private def follow_up_administrators(source : Datastore, old_fabric : Matter::Fabric,
                                         scanner : Matter::Controller::Scanner,
                                         client : Matter::Controller::Client,
                                         im : Matter::Controller::ImClient) : Nil
      own_fabric = @propagation_fabric || raise Matter::ConfigurationError.new("Candidate Anchor fabric disappeared")
      controller_store = @controller_store || raise Matter::ConfigurationError.new("Candidate controller identity disappeared")
      identity = controller_store.load.fabric_for(own_fabric.fabric_id, own_fabric.root_public_key, own_fabric.node_id)
      scanner.query_operational
      source.admin_list.each do |admin|
        # The frozen source lists our old Joint Fabric Node ID; a restored
        # promoted Datastore instead lists our new Anchor Node ID.
        next if admin.node_id == old_fabric.node_id || admin.node_id == own_fabric.node_id
        document_name = "#{APP_FOLLOW_UP_PREFIX}#{admin.node_id.to_s(16)}"
        journal = if document = persistence.app_document(document_name)
                    Matter::Controller::AnchorTransfer::AdministratorFollowUp::Journal.from_document(document)
                  else
                    Matter::Controller::AnchorTransfer::AdministratorFollowUp::Journal.new(admin.node_id)
                  end
        next if journal.stage.completed?
        icac_id = Matter::Crypto::MatterCertificate.from_slice(admin.icac).subject.icac_id ||
                  raise Matter::ConfigurationError.new("Administrator ICAC ID missing")
        icac_public_key = Matter::Crypto::MatterCertificate.public_key_from_tlv(admin.icac)
        peer = resolve_transfer_peer(scanner, identity.compressed_fabric_id, admin.node_id)
        endpoint = Matter::Controller::JointCommissioning.discover_administrator_endpoint(
          im, Matter::Controller::Pairing::CasePairing.new.pair(client, peer, identity,
          peer_node_id: admin.node_id), peer)
        runner = Matter::Controller::AnchorTransfer::AdministratorFollowUp.new(
          client, im, peer, admin.node_id, identity, old_fabric.fabric_id,
          old_fabric.root_public_key, endpoint, icac_public_key, icac_id,
          ->(state : Matter::Controller::AnchorTransfer::AdministratorFollowUp::Journal) {
            persistence.write_app_document(document_name, state.to_document)
            persistence.flush
            nil
          }, journal, consent: -> { true },
          on_committed_icac: ->(node_id : UInt64, certificate : Bytes) {
            entries = joint_fabric_datastore.admin_list
            unless entries.any?(&.node_id.==(node_id))
              raise Matter::ConfigurationError.new("Follow-up Administrator is absent from candidate Datastore")
            end
            joint_fabric_datastore.admin_list = entries.map do |entry|
              entry.icac = certificate if entry.node_id == node_id
              entry
            end
            unless persistence.save_cluster(joint_fabric_datastore)
              raise Matter::StorageError.new("Could not persist follow-up Administrator ICAC")
            end
            persistence.flush
            nil
          })
        runner.run
      end
    end

    # The console command records Anchor-side consent. An outgoing JFA must
    # also be listed in MATTER_JFA_CONSENTED_REMOVALS after its own user has
    # approved removal. The list contains comma-separated hexadecimal Node IDs.
    private def remove_administrator(outgoing_node_id : UInt64,
                                     interrupt_after_remove_fabric : Bool = false,
                                     interrupt_after_remove_admin : Bool = false,
                                     interrupt_after_anchor_rotation : Bool = false,
                                     interrupt_after_participant_rotation : Bool = false) : Nil
      raise Matter::ConfigurationError.new("Another Joint Fabric operation is running") if @removal_in_progress || @transfer_in_progress
      raise Matter::ConfigurationError.new("This device is not the Anchor") unless @anchor_role
      own_fabric = @propagation_fabric || raise Matter::ConfigurationError.new("Anchor fabric is unavailable")
      bootstrap = provisioned_anchor_bootstrap(own_fabric)
      datastore = joint_fabric_datastore
      remaining = datastore.admin_list.map(&.node_id).reject do |id|
        id == own_fabric.node_id || id == outgoing_node_id
      end
      consented = ENV["MATTER_JFA_CONSENTED_REMOVALS"]?.to_s.split(',').any? do |value|
        value.strip.to_u64?(16) == outgoing_node_id
      end
      unless consented
        raise Matter::CommissioningError.new("Outgoing Administrator user consent is not recorded")
      end
      document_name = "#{APP_REMOVAL_PREFIX}#{outgoing_node_id.to_s(16)}"
      journal = if document = persistence.app_document(document_name)
                  Matter::Controller::AdministratorRemoval::Journal.from_document(document)
                else
                  Matter::Controller::AdministratorRemoval::Journal.new(outgoing_node_id)
                end
      return if journal.stage.completed?
      if journal.stage.ready? && journal.fabric_id.nil? &&
         journal.root_public_key.nil? && journal.anchor_node_id.nil?
        journal.fabric_id = own_fabric.fabric_id
        journal.root_public_key = own_fabric.root_public_key
        journal.anchor_node_id = own_fabric.node_id
        persistence.write_app_document(document_name, journal.to_document)
        persistence.flush
      end
      unless journal.fabric_id == own_fabric.fabric_id &&
             journal.root_public_key == own_fabric.root_public_key &&
             journal.anchor_node_id == own_fabric.node_id
        raise Matter::AuthenticationError.new("Removal journal belongs to another Anchor fabric")
      end
      if journal.administrator_cat_version.nil?
        unless journal.stage.ready?
          raise Matter::CommissioningError.new("Interrupted removal lacks its CAT version; reconcile before retry")
        end
        journal.administrator_cat_version = next_transfer_cat_version(datastore, 0xFFFF_u16)
        persistence.write_app_document(document_name, journal.to_document)
        persistence.flush
      end
      admin_version = journal.administrator_cat_version.as(UInt16)
      scanner = Matter::Controller::Scanner.new
      controller_store = @controller_store || raise Matter::ConfigurationError.new("Anchor controller identity is unavailable")
      identity = controller_store.load.fabric_for(own_fabric.fabric_id, own_fabric.root_public_key, own_fabric.node_id)
      client = Matter::Controller::Client.new(unsecured_source_node_id: own_fabric.node_id)
      im = Matter::Controller::ImClient.new(client)
      @removal_in_progress = true
      begin
        scanner.start
        scanner.query_operational
        outgoing_peer = nil.as(Socket::IPAddress?)
        outgoing_session = nil.as(Matter::Session::SecureContext?)
        if journal.stage.ready?
          outgoing_peer = resolve_transfer_peer(scanner, identity.compressed_fabric_id, outgoing_node_id)
          ::Log.for("matter.example.joint_fabric_administrator").info do
            "Administrator removal CASE pairing with outgoing node 0x#{outgoing_node_id.to_s(16)}"
          end
          outgoing_session = Matter::Controller::Pairing::CasePairing.new.pair(client, outgoing_peer,
            identity, peer_node_id: outgoing_node_id)
        end
        anchor_version = datastore.group_list.find(&.group_cat.==(0xFFFE_u16)).try(&.group_cat_version) ||
                         raise Matter::ConfigurationError.new("Anchor CAT group is unavailable")
        port = Matter::Controller::AdministratorRemoval::ImPort.new(im, outgoing_session,
          outgoing_peer, own_fabric.fabric_id, own_fabric.root_public_key, outgoing_node_id,
          datastore, -> {
          raise Matter::StorageError.new("Could not persist Administrator removal") unless persistence.save_cluster(datastore)
          persistence.flush
          nil
        },
          -> {
            groups = datastore.group_list.map do |group|
              group.group_cat_version = admin_version if group.group_cat == 0xFFFF_u16
              group
            end
            datastore.group_list = groups
            update_datastore_administrator_acl_version(datastore, admin_version)
            raise Matter::StorageError.new("Could not persist Administrator CAT version") unless persistence.save_cluster(datastore)
            persistence.flush
            self_peer = Socket::IPAddress.new("127.0.0.1", self.port)
            ::Log.for("matter.example.joint_fabric_administrator").info do
              "Administrator removal CASE pairing with local Anchor before NOC rotation"
            end
            self_session = Matter::Controller::Pairing::CasePairing.new.pair(client, self_peer,
              identity, peer_node_id: own_fabric.node_id)
            Matter::Controller::AnchorTransfer::AdministratorRotation.new(client, im,
              self_session, self_peer, own_fabric.node_id, bootstrap, admin_version,
              anchor_version, anchor_target: true, existing_fabric: true,
              existing_fabric_index: own_fabric.fabric_index).transition!
            configure_propagator(own_fabric, own_fabric.root_cert.as(Bytes))
            active_identity = controller_store.load.fabric_for(own_fabric.fabric_id,
              own_fabric.root_public_key, own_fabric.node_id)
            ::Log.for("matter.example.joint_fabric_administrator").info do
              "Administrator removal CASE pairing with local Anchor after NOC rotation"
            end
            active_session = Matter::Controller::Pairing::CasePairing.new.pair(client, self_peer,
              active_identity, peer_node_id: own_fabric.node_id)
            tighten_administrator_acl(im, active_session, self_peer, admin_version)
            nil
          },
          ->(node_id : UInt64) {
            active_identity = controller_store.load.fabric_for(own_fabric.fabric_id,
              own_fabric.root_public_key, own_fabric.node_id)
            active_bootstrap = Matter::Controller::JointCommissioning::AnchorBootstrap.new(
              active_identity, bootstrap.anchor_icac_private_key)
            peer = resolve_transfer_peer(scanner, active_identity.compressed_fabric_id, node_id)
            ::Log.for("matter.example.joint_fabric_administrator").info do
              "Administrator removal CASE pairing with participant 0x#{node_id.to_s(16)} before NOC rotation"
            end
            session = Matter::Controller::Pairing::CasePairing.new.pair(client, peer,
              active_identity, peer_node_id: node_id)
            index = remote_fabric_index(im, session, peer, own_fabric)
            Matter::Controller::AnchorTransfer::AdministratorRotation.new(client, im,
              session, peer, node_id, active_bootstrap, admin_version, anchor_version,
              existing_fabric: true, existing_fabric_index: index).transition!
            ::Log.for("matter.example.joint_fabric_administrator").info do
              "Administrator removal CASE pairing with participant 0x#{node_id.to_s(16)} after NOC rotation"
            end
            refreshed_session = Matter::Controller::Pairing::CasePairing.new.pair(client, peer,
              active_identity, peer_node_id: node_id)
            tighten_administrator_acl(im, refreshed_session, peer, admin_version)
            nil
          })
        effective_port = if interrupt_after_remove_fabric || interrupt_after_remove_admin ||
                            interrupt_after_anchor_rotation || interrupt_after_participant_rotation
                           InterruptedRemovalPort.new(port, interrupt_after_remove_fabric,
                             interrupt_after_remove_admin, interrupt_after_anchor_rotation,
                             interrupt_after_participant_rotation)
                         else
                           port
                         end
        workflow = Matter::Controller::AdministratorRemoval::Workflow.new(datastore,
          own_fabric.node_id, remaining, effective_port, -> { true }, -> { consented },
          ->(state : Matter::Controller::AdministratorRemoval::Journal) {
            persistence.write_app_document(document_name, state.to_document)
            persistence.flush
            nil
          }, journal)
        workflow.run
      ensure
        @removal_in_progress = false
        client.close
        scanner.close
      end
    end

    private def reconcile_fabric_removed(outgoing_node_id : UInt64, nonce : String?) : Nil
      raise Matter::ConfigurationError.new("Inspection nonce is required") if nonce.nil? || nonce.empty?
      proof_path = ENV["MATTER_JFA_OUTGOING_INSPECTION_PATH"]? ||
                   raise Matter::ConfigurationError.new("Outgoing inspection channel is unavailable")
      own_fabric = @propagation_fabric || raise Matter::ConfigurationError.new("Anchor fabric is unavailable")
      backend = Matter::Storage::YamlFile.new(proof_path)
      backend.open
      proof = begin
        document = backend.read(COMMAND_RPC_COLLECTION, "result") ||
                   raise Matter::ConfigurationError.new("Outgoing inspection result is absent")
        CommandResult.from_document(document)
      ensure
        backend.close if backend.open?
      end
      unless proof.status == "ok" && proof.fabric_present == false &&
             proof.inspected_fabric_id == own_fabric.fabric_id &&
             proof.inspected_root_public_key == own_fabric.root_public_key &&
             proof.nonce == nonce
        raise Matter::AuthenticationError.new("Outgoing inspection did not prove the selected fabric was removed")
      end
      document_name = "#{APP_REMOVAL_PREFIX}#{outgoing_node_id.to_s(16)}"
      document = persistence.app_document(document_name) ||
                 raise Matter::ConfigurationError.new("Administrator removal journal is absent")
      journal = Matter::Controller::AdministratorRemoval::Journal.from_document(document)
      unless journal.fabric_id == own_fabric.fabric_id &&
             journal.root_public_key == own_fabric.root_public_key &&
             journal.anchor_node_id == own_fabric.node_id
        raise Matter::AuthenticationError.new("Removal journal belongs to another Anchor fabric")
      end
      unless journal.stage.removing_fabric? && journal.outgoing_node_id == outgoing_node_id
        raise Matter::ConfigurationError.new("Administrator removal is not awaiting fabric-removal reconciliation")
      end
      Matter::Controller::AdministratorRemoval::Workflow.reconcile_journal!(journal,
        Matter::Controller::AdministratorRemoval::Stage::FabricRemoved,
        ->(state : Matter::Controller::AdministratorRemoval::Journal) {
          persistence.write_app_document(document_name, state.to_document)
          persistence.flush
          nil
        })
    end

    # The old Anchor's private transfer journal is an opt-in host witness. It
    # is carried through a trusted local command channel, not a Matter wire
    # attribute. An independent Anchor needs its own trusted witness source.
    private def inspect_transfer_requester(requester_node_id : UInt64, nonce : String?) : CommandResult
      raise Matter::ConfigurationError.new("Inspection nonce is required") if nonce.nil? || nonce.empty?
      fabric = @propagation_fabric || raise Matter::ConfigurationError.new("Old Anchor fabric is unavailable")
      document = persistence.app_document(APP_TRANSFER_WATCH_DOCUMENT) ||
                 raise Matter::ConfigurationError.new("Anchor transfer requester journal is absent")
      watch = TransferWatchState.from_document(document)
      if persisted_transfer_complete? || !joint_fabric_datastore.status.state.delete_pending? ||
         watch.requester_node_id != requester_node_id ||
         watch.old_fabric_id != fabric.fabric_id ||
         watch.old_root_public_key != fabric.root_public_key
        raise Matter::AuthenticationError.new("Old Anchor cannot witness this transfer requester")
      end
      CommandResult.new("ok", inspected_node_id: fabric.node_id,
        inspected_fabric_id: fabric.fabric_id,
        inspected_root_public_key: fabric.root_public_key,
        inspected_transfer_requester_node_id: watch.requester_node_id,
        inspected_transfer_frozen: true, nonce: nonce)
    end

    private def reconcile_transfer_requested(old_anchor_node_id : UInt64, nonce : String?) : Nil
      raise Matter::ConfigurationError.new("Inspection nonce is required") if nonce.nil? || nonce.empty?
      proof_path = ENV["MATTER_JFA_OUTGOING_INSPECTION_PATH"]? ||
                   raise Matter::ConfigurationError.new("Old Anchor inspection channel is unavailable")
      own_fabric = @propagation_fabric || raise Matter::ConfigurationError.new("Candidate Anchor fabric is unavailable")
      old_fabrics = fabric_table.all_fabrics.select do |fabric|
        fabric.root_public_key != own_fabric.root_public_key &&
          fabric.cats.any?(&.identity_value.==(0xFFFF_u16))
      end
      unless old_fabrics.size == 1
        raise Matter::ConfigurationError.new("Candidate must have exactly one joined Joint Fabric")
      end
      old_fabric = old_fabrics.first
      document = persistence.app_document(APP_TRANSFER_DOCUMENT) ||
                 raise Matter::ConfigurationError.new("Anchor transfer journal is absent")
      journal = Matter::Controller::AnchorTransfer::Journal.from_document(document)
      unless journal.stage.requesting? && journal.candidate_node_id == old_fabric.node_id
        raise Matter::ConfigurationError.new("Anchor transfer is not awaiting requester reconciliation")
      end
      backend = Matter::Storage::YamlFile.new(proof_path)
      backend.open
      proof = begin
        result = backend.read(COMMAND_RPC_COLLECTION, "result") ||
                 raise Matter::ConfigurationError.new("Old Anchor inspection result is absent")
        CommandResult.from_document(result)
      ensure
        backend.close if backend.open?
      end
      unless proof.status == "ok" && proof.nonce == nonce &&
             proof.inspected_transfer_frozen == true &&
             proof.inspected_transfer_requester_node_id == journal.candidate_node_id &&
             proof.inspected_node_id == old_anchor_node_id &&
             proof.inspected_fabric_id == old_fabric.fabric_id &&
             proof.inspected_root_public_key == old_fabric.root_public_key
        raise Matter::AuthenticationError.new("Old Anchor witness does not match the pending transfer")
      end
      Matter::Controller::AnchorTransfer::Workflow.reconcile_request_journal!(journal,
        Datastore::DatastoreStateEnum::DeletePending,
        ->(state : Matter::Controller::AnchorTransfer::Journal) {
          persistence.write_app_document(APP_TRANSFER_DOCUMENT, state.to_document)
          persistence.flush
          nil
        }, proof.inspected_transfer_requester_node_id)
    end

    private def reconcile_datastore_removed(outgoing_node_id : UInt64) : Nil
      raise Matter::ConfigurationError.new("This device is not the Anchor") unless @anchor_role
      own_fabric = @propagation_fabric || raise Matter::ConfigurationError.new("Anchor fabric is unavailable")
      datastore = joint_fabric_datastore
      unless datastore.anchor_node_id == own_fabric.node_id
        raise Matter::AuthenticationError.new("Datastore belongs to another Anchor")
      end
      document_name = "#{APP_REMOVAL_PREFIX}#{outgoing_node_id.to_s(16)}"
      document = persistence.app_document(document_name) ||
                 raise Matter::ConfigurationError.new("Administrator removal journal is absent")
      journal = Matter::Controller::AdministratorRemoval::Journal.from_document(document)
      unless journal.fabric_id == own_fabric.fabric_id &&
             journal.root_public_key == own_fabric.root_public_key &&
             journal.anchor_node_id == own_fabric.node_id
        raise Matter::AuthenticationError.new("Removal journal belongs to another Anchor fabric")
      end
      Matter::Controller::AdministratorRemoval::Workflow.reconcile_datastore_removed!(journal, datastore,
        ->(state : Matter::Controller::AdministratorRemoval::Journal) {
          persistence.write_app_document(document_name, state.to_document)
          persistence.flush
          nil
        })
    end

    # The nonce is supplied by the host performing recovery. A fresh CASE
    # session and signed OperationalCredentials response bind the observed NOC
    # to that nonce, the target Node ID, and this journal's fabric and CAT.
    private def reconcile_removal_rotation(outgoing_node_id : UInt64, nonce : String?,
                                           anchor : Bool) : Nil
      raise Matter::ConfigurationError.new("This device is not the Anchor") unless @anchor_role
      unless nonce && nonce.size == 64 && nonce.matches?(/\A[0-9a-fA-F]{64}\z/)
        raise Matter::ConfigurationError.new("A 32-byte hexadecimal rotation nonce is required")
      end
      own_fabric = @propagation_fabric || raise Matter::ConfigurationError.new("Anchor fabric is unavailable")
      root_certificate = own_fabric.root_cert || raise Matter::ConfigurationError.new("Anchor root is unavailable")
      datastore = joint_fabric_datastore
      unless datastore.status.state.committed? && datastore.anchor_node_id == own_fabric.node_id &&
             datastore.admin_list.none?(&.node_id.==(outgoing_node_id))
        raise Matter::AuthenticationError.new("Removal Datastore does not match pending rotation")
      end
      document_name = "#{APP_REMOVAL_PREFIX}#{outgoing_node_id.to_s(16)}"
      document = persistence.app_document(document_name) ||
                 raise Matter::ConfigurationError.new("Administrator removal journal is absent")
      journal = Matter::Controller::AdministratorRemoval::Journal.from_document(document)
      unless journal.fabric_id == own_fabric.fabric_id &&
             journal.root_public_key == own_fabric.root_public_key &&
             journal.anchor_node_id == own_fabric.node_id
        raise Matter::AuthenticationError.new("Removal journal belongs to another Anchor fabric")
      end
      stage = anchor ? Matter::Controller::AdministratorRemoval::Stage::RotatingAnchor : Matter::Controller::AdministratorRemoval::Stage::RotatingParticipant
      unless journal.stage == stage && journal.outgoing_node_id == outgoing_node_id
        raise Matter::ConfigurationError.new("Removal journal is not awaiting this rotation")
      end
      version = journal.administrator_cat_version ||
                raise Matter::ConfigurationError.new("Removal journal has no CAT version")
      anchor_version = if anchor
                         datastore.group_list.find(&.group_cat.==(0xFFFE_u16)).try(&.group_cat_version) ||
                           raise Matter::ConfigurationError.new("Removal Datastore has no Anchor CAT version")
                       end
      target_node_id = if anchor
                         raise Matter::ConfigurationError.new("Anchor rotation has an active participant") if journal.active_node_id
                         own_fabric.node_id
                       else
                         journal.active_node_id || raise Matter::ConfigurationError.new("Participant rotation has no active Node ID")
                       end
      if target_node_id == outgoing_node_id || journal.rotated_nodes.includes?(target_node_id) ||
         (!anchor && datastore.admin_list.none?(&.node_id.==(target_node_id)))
        raise Matter::AuthenticationError.new("Rotation target differs from pending Administrator")
      end
      scanner = Matter::Controller::Scanner.new
      controller_store = @controller_store || raise Matter::ConfigurationError.new("Anchor controller identity is unavailable")
      identity = controller_store.load.fabric_for(own_fabric.fabric_id, own_fabric.root_public_key, own_fabric.node_id)
      client = Matter::Controller::Client.new(unsecured_source_node_id: own_fabric.node_id)
      begin
        scanner.start
        scanner.query_operational
        peer = anchor ? Socket::IPAddress.new("127.0.0.1", port) : resolve_transfer_peer(scanner, identity.compressed_fabric_id, target_node_id)
        session = Matter::Controller::Pairing::CasePairing.new.pair(client, peer, identity,
          peer_node_id: target_node_id)
        im = Matter::Controller::ImClient.new(client)
        Matter::Controller::AdministratorRemoval::RotationInspection.verify_completed!(im, session,
          peer, root_certificate, own_fabric.fabric_id, own_fabric.root_public_key,
          target_node_id, version, nonce.hexbytes, anchor_cat_version: anchor_version)
        Matter::Controller::AdministratorRemoval::Workflow.reconcile_journal!(journal,
          Matter::Controller::AdministratorRemoval::Stage::AnchorRotated,
          ->(state : Matter::Controller::AdministratorRemoval::Journal) {
            persistence.write_app_document(document_name, state.to_document)
            persistence.flush
            nil
          }, rotated_node_id: anchor ? nil : target_node_id,
          participant_completed: anchor ? nil : true)
      ensure
        client.close
        scanner.close
      end
    end

    private def update_datastore_administrator_acl_version(datastore : Datastore,
                                                           version : UInt16) : Nil
      old_subject = 0xFFFF_FFFD_FFFF_0000_u64 | (version - 1_u16).to_u64
      new_subject = 0xFFFF_FFFD_FFFF_0000_u64 | version.to_u64
      entries = datastore.node_acl_list.map do |entry|
        if subjects = entry.acl_entry.subjects
          entry.acl_entry.subjects = subjects.map { |subject| subject == old_subject ? new_subject : subject }
        end
        entry
      end
      datastore.node_acl_list = entries
    end

    private def tighten_administrator_acl(im : Matter::Controller::ImClient,
                                          session : Matter::Session::SecureContext,
                                          peer : Socket::IPAddress, version : UInt16) : Nil
      old_subject = 0xFFFF_FFFD_FFFF_0000_u64 | (version - 1_u16).to_u64
      new_subject = 0xFFFF_FFFD_FFFF_0000_u64 | version.to_u64
      report = im.read_attribute(session, peer, 0_u16,
        Matter::Cluster::AccessControl::CLUSTER_ID, Matter::Cluster::AccessControl::ATTR_ACL)
      data = report.attribute_reports.try(&.find(&.attribute_data)).try(&.attribute_data).try(&.data) ||
             raise Matter::ProtocolError.new("Administrator ACL read omitted data")
      entries = Array(Matter::Cluster::AccessControl::AccessControlEntry).from_tlv(data.to_slice)
      changed = false
      entries.each do |entry|
        subjects = entry.subjects
        next unless subjects && subjects.includes?(old_subject)
        entry.subjects = subjects.map { |subject| subject == old_subject ? new_subject : subject }
        changed = true
      end
      return unless changed
      response = im.write_attribute(session, peer, 0_u16,
        Matter::Cluster::AccessControl::CLUSTER_ID, Matter::Cluster::AccessControl::ATTR_ACL,
        entries.to_tlv)
      unless response.write_responses.any? { |item| item.status.status == Matter::InteractionModel::StatusCode::Success.value }
        raise Matter::CommissioningError.new("Administrator CAT ACL update failed")
      end
    end

    private def remote_fabric_index(im : Matter::Controller::ImClient,
                                    session : Matter::Session::SecureContext,
                                    peer : Socket::IPAddress,
                                    fabric : Matter::Fabric) : UInt8
      report = im.read_attribute(session, peer, 0_u16,
        Matter::Cluster::OperationalCredentials::CLUSTER_ID,
        Matter::Cluster::OperationalCredentials::ATTR_FABRICS,
        fabric_filtered: false)
      data = report.attribute_reports.try(&.find(&.attribute_data)).try(&.attribute_data).try(&.data) ||
             raise Matter::ProtocolError.new("Administrator Fabrics read omitted data")
      descriptors = Array(Matter::Cluster::OperationalCredentials::Tlv::FabricDescriptor).from_tlv(data.to_slice)
      descriptor = descriptors.find do |item|
        item.fabric_id == fabric.fabric_id && item.root_public_key == fabric.root_public_key
      end
      descriptor.try(&.fabric_index) || raise Matter::AuthenticationError.new("Administrator is not on the selected Joint Fabric")
    end

    private def provisioned_anchor_bootstrap(fabric : Matter::Fabric) : Matter::Controller::JointCommissioning::AnchorBootstrap
      path = ENV["MATTER_JFA_BOOTSTRAP_STATE_PATH"]? ||
             raise Matter::ConfigurationError.new("Anchor bootstrap state path is required for transfer")
      backend = Matter::Storage::YamlFile.new(path)
      begin
        identity = Matter::Controller::StateStore.new(backend).load.fabrics.find do |candidate|
          candidate.fabric_id == fabric.fabric_id &&
            candidate.root_public_key == fabric.root_public_key
        end || raise Matter::ConfigurationError.new("Candidate Anchor bootstrap identity is missing")
        key = identity.intermediate_private_key ||
              raise Matter::ConfigurationError.new("Candidate Anchor ICAC key is missing")
        Matter::Controller::JointCommissioning::AnchorBootstrap.new(identity, key)
      ensure
        backend.close if backend.open?
      end
    end

    private def next_transfer_cat_version(store : Datastore, cat : UInt16) : UInt16
      current = store.group_list.find(&.group_cat.==(cat)).try(&.group_cat_version) ||
                raise Matter::ConfigurationError.new("Source Datastore lacks CAT group 0x#{cat.to_s(16)}")
      raise Matter::ConfigurationError.new("CAT version exhausted") if current == UInt16::MAX
      current + 1_u16
    end

    private def process_anchor_exchange_request : Nil
      path = ENV["MATTER_JFA_JCM_REQUEST_PATH"]?
      return unless path && File.exists?(path)
      backend = Matter::Storage::YamlFile.new(path)
      backend.open
      begin
        return if backend.read(JCM_RPC_COLLECTION, JCM_RPC_RESULT)
        document = backend.read(JCM_RPC_COLLECTION, JCM_RPC_REQUEST)
        return unless document
        request = AnchorExchangeRequest.from_document(document)
        backend.write(JCM_RPC_COLLECTION, JCM_RPC_RESULT,
          AnchorExchangeResult.new("in-progress").to_document)
        backend.close
        result = begin
          certificate = execute_anchor_exchange(request)
          AnchorExchangeResult.new("ok", certificate)
        rescue ex
          ::Log.for("matter.example.joint_fabric_administrator").error(exception: ex) { "Anchor ICAC exchange failed" }
          AnchorExchangeResult.new("error", error: ex.message)
        end
        backend.open
        backend.write(JCM_RPC_COLLECTION, JCM_RPC_RESULT, result.to_document)
      ensure
        backend.close if backend.open?
      end
    rescue ex : Matter::Error | IO::Error | ArgumentError
      ::Log.for("matter.example.joint_fabric_administrator").error(exception: ex) { "Anchor exchange request failed" }
    end

    private def process_command_request : Nil
      path = ENV["MATTER_JFA_COMMAND_PATH"]?
      return unless path && File.exists?(path)
      backend = Matter::Storage::YamlFile.new(path)
      backend.open
      begin
        return if backend.read(COMMAND_RPC_COLLECTION, "result")
        document = backend.read(COMMAND_RPC_COLLECTION, "request")
        return unless document
        request = CommandRequest.from_document(document)
        backend.write(COMMAND_RPC_COLLECTION, "result", CommandResult.new("in-progress", nonce: request.nonce).to_document)
        backend.close
        result = begin
          case request.operation
          when "transfer-anchor"
            transfer_anchor_from(request.node_id, request.interrupt_before_transfer_follow_up?,
              request.interrupt_after_transfer_request?)
            CommandResult.new("ok")
          when "remove-administrator"
            remove_administrator(request.node_id, request.interrupt_after_remove_fabric?,
              request.interrupt_after_remove_admin?, request.interrupt_after_anchor_rotation?,
              request.interrupt_after_participant_rotation?)
            CommandResult.new("ok")
          when "inspect-fabric"
            fabric_id = request.fabric_id || raise Matter::ConfigurationError.new("Fabric ID is required")
            root_public_key = request.root_public_key || raise Matter::ConfigurationError.new("Root public key is required")
            present = fabric_table.all_fabrics.any? do |fabric|
              fabric.fabric_id == fabric_id && fabric.root_public_key == root_public_key
            end
            CommandResult.new("ok", fabric_present: present, inspected_fabric_id: fabric_id,
              inspected_root_public_key: root_public_key, nonce: request.nonce)
          when "inspect-anchor-identity"
            fabric = @propagation_fabric || raise Matter::ConfigurationError.new("Anchor fabric is unavailable")
            root_certificate = fabric.root_cert || raise Matter::ConfigurationError.new("Anchor root is unavailable")
            icac_certificate = fabric.intermediate_cert || raise Matter::ConfigurationError.new("Anchor ICAC is unavailable")
            CommandResult.new("ok", fabric_present: @joint_fabric_provisioned,
              inspected_fabric_id: fabric.fabric_id, inspected_root_public_key: fabric.root_public_key,
              inspected_root_certificate: root_certificate, inspected_icac_certificate: icac_certificate,
              inspected_node_id: fabric.node_id, inspected_cross_signed_icac: persisted_icac,
              inspected_administrator_fabric_index: joint_fabric_administrator.administrator_fabric_index,
              inspected_fabric_count: fabric_table.all_fabrics.size,
              inspected_datastore_admin_entries: joint_fabric_datastore.admin_list.map(&.to_slice),
              nonce: request.nonce)
          when "inspect-new-anchor"
            CommandResult.new("ok", nonce: request.nonce,
              subscription_committed: @participant_view_current)
          when "set-test-fail-safe-max"
            seconds = request.fail_safe_max_seconds ||
                      raise Matter::ConfigurationError.new("Test fail-safe maximum is required")
            if seconds == 0_u16 ||
               seconds > Matter::Commissioning::FailsafeService::DEFAULT_MAX_CUMULATIVE_SECONDS ||
               general_commissioning.failsafe_armed?
              raise Matter::ConfigurationError.new("Invalid test fail-safe maximum or active fail-safe")
            end
            general_commissioning.max_cumulative_failsafe_seconds = seconds
            CommandResult.new("ok")
          when "inspect-transfer-requester"
            inspect_transfer_requester(request.node_id, request.nonce)
          when "reconcile-transfer-requested"
            reconcile_transfer_requested(request.node_id, request.nonce)
            CommandResult.new("ok")
          when "reconcile-fabric-removed"
            reconcile_fabric_removed(request.node_id, request.nonce)
            CommandResult.new("ok")
          when "reconcile-datastore-removed"
            reconcile_datastore_removed(request.node_id)
            CommandResult.new("ok")
          when "reconcile-anchor-rotated"
            reconcile_removal_rotation(request.node_id, request.nonce, true)
            CommandResult.new("ok", nonce: request.nonce)
          when "reconcile-participant-rotated"
            reconcile_removal_rotation(request.node_id, request.nonce, false)
            CommandResult.new("ok", nonce: request.nonce)
          when "finalize-commissioning"
            certificate = finalize_commissioning(request)
            CommandResult.new("ok", nonce: request.nonce, certificate: certificate)
          when "migrate-device", "reconcile-device-migration",
               "reconcile-device-migration-no-effect", "rollback-device-migration",
               "resume-rollback-device-migration", "resume-anchor-registration"
            migrate_device(request)
            CommandResult.new("ok", nonce: request.nonce)
          else
            raise Matter::ConfigurationError.new("Unknown Joint Fabric command")
          end
        rescue ex
          ::Log.for("matter.example.joint_fabric_administrator").error(exception: ex) { "Joint Fabric command failed" }
          CommandResult.new("error", ex.message, nonce: request.nonce)
        end
        backend.open
        backend.write(COMMAND_RPC_COLLECTION, "result", result.to_document)
      ensure
        backend.close if backend.open?
      end
    rescue ex : Matter::Error | IO::Error | ArgumentError
      ::Log.for("matter.example.joint_fabric_administrator").error(exception: ex) { "Joint Fabric command request failed" }
    end

    # A local, consented command. Neither B's ICAC signing key nor A's joined
    # operational private key crosses the command channel.
    private def migrate_device(request : CommandRequest) : Nil
      allowed = ENV["MATTER_JFA_CONSENTED_MIGRATIONS"]?.to_s.split(',').any? do |id|
        id.to_u64?(16) == request.node_id
      end
      raise Matter::CommissioningError.new("Device migration consent is missing") unless allowed
      verifier = migration_attestation_verifier
      anchor_fabric_id = request.fabric_id || raise Matter::ConfigurationError.new("Anchor fabric ID is required")
      anchor_root = request.root_public_key || raise Matter::ConfigurationError.new("Anchor root public key is required")
      anchor_node_id = request.anchor_node_id || raise Matter::ConfigurationError.new("Anchor device Node ID is required")
      address = request.peer_address || raise Matter::ConfigurationError.new("Device address is required")
      target_peer = Socket::IPAddress.new(address, request.peer_port || 5540)
      old_device_fabric = fabric_table.all_fabrics.find do |fabric|
        provisioned_bootstrap_fabric?(fabric)
      end || raise Matter::ConfigurationError.new("Bootstrap Fabric B is not installed")
      joined_device_fabric = fabric_table.all_fabrics.find do |fabric|
        fabric.fabric_id == anchor_fabric_id && fabric.root_public_key == anchor_root
      end || raise Matter::ConfigurationError.new("Joined Anchor fabric is not installed")
      unless bootstrap_joint_fabric_datastore.joint_fabric_index == old_device_fabric.fabric_index &&
             bootstrap_joint_fabric_datastore.access_mode.active?
        raise Matter::ConfigurationError.new("Fabric B Datastore is unavailable")
      end
      bootstrap = provisioned_anchor_bootstrap(old_device_fabric).fabric
      old_fabric = migration_identity(old_device_fabric, bootstrap)
      anchor_fabric = migration_identity(joined_device_fabric)
      cross_icac = persisted_icac || raise Matter::ConfigurationError.new("Cross-signed ICAC is unavailable")
      issuer_key = bootstrap.intermediate_private_key ||
                   raise Matter::ConfigurationError.new("Fabric B ICAC signer is unavailable")
      issuer = Matter::Controller::JointFabricDeviceMigration.cross_signed_issuer(
        old_fabric, anchor_fabric, cross_icac, issuer_key)
      # The trusted Anchor Node ID is published by the provisioned controller
      # fixture. It is resolved to an address only after the identity is fixed.
      anchor_datastore_node_id = ENV["MATTER_JFA_ANCHOR_NODE_ID"]?.try(&.to_u64?(16)) ||
                                 raise Matter::ConfigurationError.new("Anchor Node ID is required")
      anchor_peer = configured_peer_hints[anchor_datastore_node_id]? ||
                    raise Matter::ConfigurationError.new("Anchor operational address is unavailable")
      admin_group = bootstrap_joint_fabric_datastore.group_list.find(&.group_cat.==(0xFFFF_u16)) ||
                    raise Matter::ConfigurationError.new("Fabric B Administrator CAT group is missing")
      admin_version = admin_group.group_cat_version ||
                      raise Matter::ConfigurationError.new("Fabric B Administrator CAT version is missing")
      admin_cat = (0xFFFF_u32 << 16) | admin_version.to_u32
      store = @controller_store || Matter::Controller::StateStore.new(persistence.backend)
      state = store.load
      [old_fabric, anchor_fabric].each do |identity|
        existing = state.fabrics.find do |fabric|
          fabric.fabric_id == identity.fabric_id &&
            fabric.root_public_key == identity.root_public_key &&
            fabric.controller_node_id == identity.controller_node_id
        end
        state.install_fabric(identity) unless existing
      end
      store.save(state)
      journal_store = Matter::Controller::JointFabricDeviceMigration::JournalStore.new(persistence.backend)
      stored_journal = journal_store.load(old_fabric.fabric_id, old_fabric.root_public_key,
        request.node_id, anchor_fabric.fabric_id, anchor_fabric.root_public_key,
        anchor_node_id)
      if request.operation != "migrate-device" && !stored_journal
        raise Matter::ConfigurationError.new("No device migration journal exists to recover")
      end
      journal = stored_journal || Matter::Controller::JointFabricDeviceMigration::Journal.new(
        old_fabric.fabric_id, anchor_fabric.fabric_id, request.node_id, anchor_node_id,
        old_fabric.root_public_key, anchor_fabric.root_public_key)
      local_peer = Socket::IPAddress.new("127.0.0.1", port)
      network = Matter::Controller::JointFabricDeviceMigration::NetworkPort.new(
        store, old_fabric, anchor_fabric, issuer, request.node_id, anchor_node_id,
        target_peer, old_device_fabric.node_id, local_peer, 2_u16,
        anchor_datastore_node_id, anchor_peer, 1_u16, "Migrated device", admin_cat,
        verifier,
        commissioning_ack: -> {
          acknowledged = journal_store.load(old_fabric.fabric_id,
            old_fabric.root_public_key, request.node_id,
            anchor_fabric.fabric_id, anchor_fabric.root_public_key,
            anchor_node_id) ||
                         raise Matter::StorageError.new("Migration journal is missing at CommissioningComplete")
          acknowledged.commissioning_acknowledged = true
          journal_store.save(acknowledged)
        },
        fail_safe_deadline: ->(deadline : Int64, max_seconds : UInt16) {
          armed = journal_store.load(old_fabric.fabric_id,
            old_fabric.root_public_key, request.node_id,
            anchor_fabric.fabric_id, anchor_fabric.root_public_key,
            anchor_node_id) ||
                  raise Matter::StorageError.new("Migration journal is missing after ArmFailSafe")
          armed.fail_safe_deadline_unix = deadline
          armed.fail_safe_max_seconds = max_seconds
          journal_store.save(armed)
        },
        timeout: 30.seconds)
      begin
        workflow = Matter::Controller::JointFabricDeviceMigration::Workflow.new(
          journal, network, -> { true },
          ->(entry : Matter::Controller::JointFabricDeviceMigration::Journal) {
            journal_store.save(entry)
          })
        case request.operation
        when "migrate-device"
          workflow.run
        when "rollback-device-migration"
          workflow.rollback!
        when "resume-rollback-device-migration"
          workflow.resume_rollback!
        when "resume-anchor-registration"
          workflow.resume_anchor_registration!
        when "reconcile-device-migration-no-effect"
          workflow.reconcile_no_effect!
        when "reconcile-device-migration"
          stage = case workflow.journal.stage
                  when Matter::Controller::JointFabricDeviceMigration::Stage::CommissioningAnchor
                    Matter::Controller::JointFabricDeviceMigration::Stage::AnchorCommissioned
                  when Matter::Controller::JointFabricDeviceMigration::Stage::VerifyingAnchor
                    Matter::Controller::JointFabricDeviceMigration::Stage::AnchorVerified
                  when Matter::Controller::JointFabricDeviceMigration::Stage::AddingAnchorNode
                    Matter::Controller::JointFabricDeviceMigration::Stage::AnchorNodeAdded
                  when Matter::Controller::JointFabricDeviceMigration::Stage::RemovingOldFabric
                    Matter::Controller::JointFabricDeviceMigration::Stage::OldFabricRemoved
                  when Matter::Controller::JointFabricDeviceMigration::Stage::RemovingOldNode
                    Matter::Controller::JointFabricDeviceMigration::Stage::Complete
                  when Matter::Controller::JointFabricDeviceMigration::Stage::RollingBack
                    Matter::Controller::JointFabricDeviceMigration::Stage::RolledBack
                  else
                    raise Matter::ConfigurationError.new("Migration journal does not need reconciliation")
                  end
          workflow.reconcile!(stage)
        end
      ensure
        network.close
      end
    end

    private def migration_identity(fabric : Matter::Fabric,
                                   bootstrap : Matter::Controller::FabricInfo? = nil) : Matter::Controller::FabricInfo
      root = fabric.root_cert || raise Matter::ConfigurationError.new("Migration fabric root is unavailable")
      Matter::Controller::FabricInfo.new(
        fabric_id: fabric.fabric_id,
        controller_node_id: fabric.node_id,
        ipk_value: fabric.ipk,
        root_cert: root,
        root_public_key: fabric.root_public_key,
        controller_noc: fabric.operational_cert,
        controller_private_key: fabric.operational_private_key,
        root_private_key: bootstrap.try(&.root_private_key),
        admin_vendor_id: fabric.vendor_id,
        intermediate_cert: fabric.intermediate_cert,
        intermediate_private_key: bootstrap.try(&.intermediate_private_key)
      )
    end

    private def provisioned_bootstrap_fabric?(fabric : Matter::Fabric) : Bool
      provisioned_anchor_bootstrap(fabric)
      true
    rescue Matter::ConfigurationError
      false
    end

    private def finalize_commissioning(request : CommandRequest) : Bytes?
      raise Matter::ConfigurationError.new("Finalization requires a target Node ID") if request.node_id == 0_u64
      nonce = request.nonce
      raise Matter::ConfigurationError.new("Finalization nonce is required") if nonce.nil? || nonce.empty?
      jcm_parameters = joint_handoff_parameters(request) if request.jcm?
      own_fabric = @propagation_fabric || raise Matter::ConfigurationError.new("Anchor fabric is unavailable")
      unless @anchor_role && has_anchor_cat?(own_fabric)
        raise Matter::AuthenticationError.new("Device is not the active Anchor")
      end
      unless request.fabric_id == own_fabric.fabric_id && request.root_public_key == own_fabric.root_public_key
        raise Matter::AuthenticationError.new("Finalization requested for a different fabric")
      end
      store = @controller_store || raise Matter::ConfigurationError.new("Anchor controller identity is unavailable")
      identity = store.load.fabric_for(own_fabric.fabric_id, own_fabric.root_public_key, own_fabric.node_id)
      unless identity.controller_node_id == own_fabric.node_id && identity.controller_noc == own_fabric.operational_cert
        raise Matter::AuthenticationError.new("Anchor CASE identity does not match its operational fabric")
      end
      if jcm_parameters && identity.root_private_key.nil?
        raise Matter::ConfigurationError.new("JCM Anchor signing requires a local root issuer")
      end

      scanner = Matter::Controller::Scanner.new
      client = Matter::Controller::Client.new(unsecured_source_node_id: own_fabric.node_id)
      cross_signed_icac = nil
      begin
        scanner.start
        scanner.query_operational
        peer = resolve_transfer_peer(scanner, identity.compressed_fabric_id, request.node_id)
        if parameters = jcm_parameters
          public_key, endpoint = parameters
          anchor_icac = identity.intermediate_cert ||
                        raise Matter::ConfigurationError.new("Anchor ICAC is unavailable")
          icac_id = Matter::Crypto::MatterCertificate.from_slice(anchor_icac).subject.icac_id ||
                    raise Matter::ConfigurationError.new("Anchor ICAC ID is unavailable")
          exchange_request = AnchorExchangeRequest.new(identity.fabric_id, identity.root_public_key,
            request.node_id, peer, endpoint, public_key, icac_id)
          cross_signed_icac = execute_anchor_exchange(exchange_request)
          Matter::Controller::JointCommissioning.validate_cross_signed_icac(
            cross_signed_icac, identity, public_key, icac_id)
        end
        session = Matter::Controller::Pairing::CasePairing.new.pair(client, peer,
          identity, peer_node_id: request.node_id)
        response = Matter::Controller::ImClient.new(client, 45.seconds).invoke(
          session: session, peer: peer, endpoint_id: 0_u16,
          cluster_id: Matter::Cluster::GeneralCommissioning::CLUSTER_ID,
          command_id: Matter::Cluster::GeneralCommissioning::CMD_COMMISSIONING_COMPLETE,
          fields: Bytes.empty)
        assert_standard_commissioning_complete!(response)
      ensure
        client.close
        scanner.close
      end
      cross_signed_icac
    end

    private def joint_handoff_parameters(request : CommandRequest) : {Bytes, UInt16}
      public_key = request.trusted_icac_public_key_b ||
                   raise Matter::ConfigurationError.new("JCM requires the authenticated Administrator ICAC public key")
      unless public_key.size == 65 && public_key[0] == 0x04_u8
        raise Matter::AuthenticationError.new("JCM Administrator ICAC public key is not uncompressed P-256")
      end
      endpoint = request.peer_admin_jfa_endpoint_id ||
                 raise Matter::ConfigurationError.new("JCM requires the peer Administrator endpoint")
      if endpoint == UInt16::MAX
        raise Matter::ConfigurationError.new("JCM peer Administrator endpoint is invalid")
      end
      {public_key, endpoint}
    end

    private def assert_standard_commissioning_complete!(response : Matter::InteractionModel::InvokeResponseMessage) : Nil
      response.invoke_responses.each do |entry|
        if status = entry.command_status
          raise Matter::CommissioningError.new("CommissioningComplete failed: IM status #{status.status.status}")
        end
        command = entry.command_data
        next unless command && command.command_path.command ==
                      Matter::Cluster::GeneralCommissioning::CMD_COMMISSIONING_COMPLETE_RESPONSE
        fields = command.command_fields || raise Matter::ProtocolError.new("CommissioningComplete response omitted fields")
        result = Matter::Cluster::GeneralCommissioning::CommissioningCompleteResponse.from_slice(fields.to_slice)
        unless result.error_code.ok?
          raise Matter::CommissioningError.new("CommissioningComplete failed: #{result.error_code} #{result.debug_text}")
        end
        return
      end
      raise Matter::ProtocolError.new("CommissioningComplete response omitted command data")
    end

    private def execute_anchor_exchange(request : AnchorExchangeRequest) : Bytes
      own_fabric = @propagation_fabric || raise Matter::ConfigurationError.new("Anchor device has no provisioned fabric")
      unless request.fabric_id == own_fabric.fabric_id &&
             request.root_public_key == own_fabric.root_public_key
        raise Matter::AuthenticationError.new("Anchor exchange requested for a different fabric")
      end
      unless @anchor_role && has_anchor_cat?(own_fabric)
        raise Matter::AuthenticationError.new("Device is not the active Anchor")
      end
      identity = @controller_store.as(Matter::Controller::StateStore).load.fabric_for(
        own_fabric.fabric_id, own_fabric.root_public_key, own_fabric.node_id)
      # CASE must identify this reachable JFA device, not a controller process.
      unless identity.controller_node_id == own_fabric.node_id &&
             identity.controller_noc == own_fabric.operational_cert
        raise Matter::AuthenticationError.new("Anchor device CASE identity does not match its operational fabric")
      end
      identity.certificate_authority_key
      peer = Socket::IPAddress.new(request.peer_address, request.peer_port)
      client = Matter::Controller::Client.new(unsecured_source_node_id: own_fabric.node_id)
      begin
        session = Matter::Controller::Pairing::CasePairing.new.pair(client, peer,
          identity, peer_node_id: request.joining_node_id)
        im = Matter::Controller::ImClient.new(client, 45.seconds)
        endpoint = Matter::Controller::JointCommissioning.discover_administrator_endpoint(im, session, peer)
        unless endpoint == request.administrator_endpoint
          raise Matter::AuthenticationError.new("Joining Administrator endpoint changed before Anchor exchange")
        end
        response = im.invoke(session: session, peer: peer, endpoint_id: endpoint,
          cluster_id: Admin::CLUSTER_ID,
          command_id: Admin::CMD_ANNOUNCE_JOINT_FABRIC_ADMINISTRATOR,
          fields: Admin::AnnounceJointFabricAdministratorRequest.new(endpoint).to_slice)
        Matter::Controller::JointCommissioning.assert_status_success(response)
        Matter::Controller::JointCommissioning.exchange_icac(im, session, peer,
          endpoint, identity.root_cert, identity.certificate_authority_key,
          identity.fabric_id, request.icac_public_key, request.icac_id)
      ensure
        client.close
      end
    end

    private def resolve_transfer_peer(scanner : Matter::Controller::Scanner,
                                      compressed_fabric_id : UInt64,
                                      node_id : UInt64,
                                      timeout : Time::Span = 10.seconds) : Socket::IPAddress
      deadline = Time.instant + timeout
      loop do
        if device = scanner.operational_devices.find { |entry| entry.fabric_id == compressed_fabric_id && entry.node_id == node_id }
          if address = device.addresses.find(&.family.inet?) || device.addresses.first?
            return Socket::IPAddress.new(address.address, device.port)
          end
        end
        break if Time.instant >= deadline
        sleep 100.milliseconds
      end
      if configured = configured_transfer_peer(node_id)
        return configured
      end
      raise Matter::TransportError.new("Could not discover transfer participant 0x#{node_id.to_s(16)}")
    end

    # A configured host is only a reachability hint. Every caller establishes
    # CASE for the selected fabric and expected Node ID before trusting it.
    private def configured_transfer_peer(node_id : UInt64) : Socket::IPAddress?
      address = configured_peer_hints[node_id]?
      return unless address
      ::Log.for("matter.example.joint_fabric_administrator").info do
        "Operational mDNS did not locate transfer participant 0x#{node_id.to_s(16)}; trying configured host"
      end
      address
    end

    # Route hints are only used after operational discovery fails. Every
    # caller still establishes CASE with the selected fabric and Node ID.
    private def configured_peer_hints : Hash(UInt64, Socket::IPAddress)
      hints = {} of UInt64 => Socket::IPAddress
      entries = ENV["MATTER_JFA_TRANSFER_PEERS"]?
      return hints unless entries
      port = ENV["MATTER_JFA_ANCHOR_OPERATIONAL_PORT"]?.try(&.to_i?) || DEFAULT_OPERATIONAL_PORT
      entries.split(',').each do |entry|
        parts = entry.split('=', 2)
        node_id = parts.first.to_u64?(16)
        host = parts[1]?
        if !node_id || !host || host.empty? || hints.has_key?(node_id)
          raise Matter::ConfigurationError.new("Invalid or duplicate configured Joint Fabric peer")
        end
        address = Socket::Addrinfo.resolve(host, port.to_s, type: Socket::Type::DGRAM)
          .find(&.ip_address.family.inet?) ||
                  raise Matter::TransportError.new("Configured Joint Fabric peer hostname did not resolve")
        hints[node_id] = address.ip_address
      end
      hints
    end

    private def compliant_anchor_fabric?(fabric : Matter::Fabric) : Bool
      return false unless ENV["MATTER_JFA_PROVISIONED_ANCHOR"]? == "1"
      return false unless has_anchor_cat?(fabric)
      icac = fabric.intermediate_cert
      return false unless icac
      Matter::Crypto::MatterCertificate::Validation.verify_intermediate_profile(icac, fabric.fabric_id)
      true
    rescue Matter::Error
      false
    end

    private def has_anchor_cat?(fabric : Matter::Fabric) : Bool
      fabric.cats.any? { |cat| cat.identity_value == ANCHOR_CAT_ID && cat.version > 0_u16 }
    end

    private def verify_anchor_initiator(node_id : UInt64, fabric_index : UInt8,
                                        source : Socket::IPAddress) : Bool
      fabric = fabric_table.get_fabric(fabric_index)
      return false unless fabric
      trust = anchor_trust(fabric.vendor_id, ENV["MATTER_JFA_VID_TRUST_ROOT_PATH"]?,
        ENV["MATTER_JFA_TEST_DCL_GATEWAY_URL"]?, ENV["MATTER_JFA_DCL_GATEWAY_URL"]?)
      scanner = Matter::Controller::Scanner.new
      begin
        scanner.start
        scanner.query_operational
        compressed = IO::ByteFormat::BigEndian.decode(UInt64, fabric.compressed_fabric_id)
        peer = resolve_anchor_verification_peer(scanner, compressed, node_id, source)
      ensure
        scanner.close
      end
      # The fresh CASE verification must originate from this node's operational
      # listener. Some peers update the route for our Node ID from each CASE
      # handshake; an ephemeral verifier socket would divert their next JCM
      # command away from the JFA device.
      client = anchor_verification_client(fabric.node_id)
      begin
        Matter::Controller::JointCommissioning.verify_anchor_from_fabric(fabric, node_id, peer, trust,
          timeout: 15.seconds, client: client,
          on_verified_session: ->(session : Matter::Session::SecureContext) {
            # SDK Administrators can reuse this newly authenticated CASE
            # session for ICACCSRRequest immediately after Announce. The
            # listener must continue to receive it once this client closes.
            message_handler.registry.establish_session(session, preserve_existing: true)
          })
      ensure
        client.close
      end
      true
    rescue ex : Matter::Error | IO::Error
      ::Log.for("matter.example.joint_fabric_administrator").warn(exception: ex) { "Anchor VID verification failed" }
      false
    end

    # Only the opt-in interoperability fixture may use this local test mirror.
    # A VVS requires its DCL signer even when a static root is also configured
    # for the fixture's other, no-VVS fabrics.
    private def anchor_trust(vendor_id : UInt16, root_path : String?,
                             test_dcl_url : String?, dcl_url : String? = nil) : Matter::Controller::VidVerification::OperationalTrustAnchors
      if test_dcl_url && dcl_url
        raise Matter::ConfigurationError.new("Configure one Joint Fabric DCL gateway")
      end
      root_trust = if path = root_path
                     trusted_roots = path.split(',').map { |entry| File.read(entry.strip).to_slice.dup }
                     Matter::Controller::VidVerification::StaticOperationalTrustAnchors.new(
                       {vendor_id => trusted_roots})
                   end
      if url = test_dcl_url || dcl_url
        source = Matter::Controller::VidVerification::HttpDclSource.new(url)
        if test_dcl_url && !URI.parse(url).host.in?("127.0.0.1", "tests")
          raise Matter::ConfigurationError.new("Test DCL mirror must use loopback or the Compose tests service")
        end
        signer_trust = Matter::Controller::VidVerification::DclOperationalTrustAnchors.new(source)
        return root_trust ? Matter::Controller::VidVerification::CompositeOperationalTrustAnchors.new(
          root_trust, signer_trust) : signer_trust
      end
      root_trust || raise Matter::ConfigurationError.new("No operational Vendor ID trust source configured")
    end

    private def anchor_verification_client(node_id : UInt64) : Matter::Controller::Client
      Matter::Controller::Client.new(
        transport: message_handler.transport,
        unsecured_source_node_id: node_id,
        session_id_in_use: ->(id : UInt16) { message_handler.sessions.has_key?(id) }
      )
    end

    # Announce arrived over an authenticated CASE session. Its UDP source is
    # therefore a route hint when operational DNS-SD misses a peer, including
    # SDK Administrators that listen on a dynamic port. The fresh outbound
    # CASE and VID verification above still authenticate the expected node.
    private def resolve_anchor_verification_peer(scanner : Matter::Controller::Scanner,
                                                 compressed_fabric_id : UInt64, node_id : UInt64,
                                                 source : Socket::IPAddress,
                                                 timeout : Time::Span = 2.seconds) : Socket::IPAddress
      resolve_transfer_peer(scanner, compressed_fabric_id, node_id, timeout)
    rescue Matter::TransportError
      listener_port = ENV["MATTER_JFA_ANCHOR_OPERATIONAL_PORT"]?.try(&.to_i?) || source.port
      raise Matter::TransportError.new("Anchor operational port is unavailable") unless listener_port > 0
      ::Log.for("matter.example.joint_fabric_administrator").info do
        "Operational mDNS did not locate authenticated Anchor; trying CASE source route"
      end
      Socket::IPAddress.new(source.address, listener_port)
    end

    private def accessing_fabric_identity(index : UInt8) : Matter::Commissioning::JointFabricAdministratorService::FabricIdentity?
      fabric = fabric_table.get_fabric(index)
      return unless fabric
      root = fabric.root_cert
      return unless root
      Matter::Commissioning::JointFabricAdministratorService::FabricIdentity.new(root, fabric.fabric_id)
    end

    private def provisioned_icac_key(fabric : Matter::Fabric, icac : Bytes) : Matter::Crypto::Key?
      public_key = Matter::Crypto::MatterCertificate.public_key_from_tlv(icac)
      state = if document = persistence.app_document(APP_KEY_DOCUMENT)
                IcacKeyState.from_document(document)
              else
                import_bootstrap_icac_key(fabric, icac, public_key)
              end
      return unless state && state.public_key == public_key
      key = Matter::Crypto::Key.new(Matter::Crypto::KeyType::EC, Matter::Crypto::CurveType::P256)
      key.private_bits = state.private_key
      return unless key.public_key == public_key
      persistence.write_app_document(APP_KEY_DOCUMENT, state.to_document) unless persistence.app_document(APP_KEY_DOCUMENT)
      key
    end

    private def import_bootstrap_icac_key(fabric : Matter::Fabric, icac : Bytes, public_key : Bytes) : IcacKeyState?
      path = ENV["MATTER_JFA_BOOTSTRAP_STATE_PATH"]?
      return unless path
      backend = Matter::Storage::YamlFile.new(path)
      begin
        source = Matter::Controller::StateStore.new(backend).load
        identity = source.fabrics.find do |candidate|
          candidate.fabric_id == fabric.fabric_id &&
            candidate.root_public_key == fabric.root_public_key &&
            candidate.intermediate_cert == icac
        end
        private_key = identity.try(&.intermediate_private_key)
        return unless private_key
        IcacKeyState.new(private_key, public_key)
      ensure
        backend.close if backend.open?
      end
    end

    private def open_joint_window(request : Admin::OpenJointCommissioningWindowRequest, fabric : Matter::Fabric) : Matter::InteractionModel::Status
      unless @anchor_role
        return Matter::InteractionModel::Status.unsupported_access
      end
      if persistence.app_document(APP_TRANSFER_WATCH_DOCUMENT) && !@participant_view_current
        ::Log.for("matter.example.joint_fabric_administrator").warn do
          "Joint Commissioning denied while the new Anchor Datastore view is stale"
        end
        return Matter::InteractionModel::Status.unsupported_access
      end
      unless ENV["MATTER_JFA_ALLOW_JCM"]? == "1"
        ::Log.for("matter.example.joint_fabric_administrator").info { "Joint Commissioning window denied by local consent policy" }
        return Matter::InteractionModel::Status.unsupported_access
      end
      open_joint_window_on_fabric(request, fabric)
    end

    private def open_bootstrap_joint_window(request : Admin::OpenJointCommissioningWindowRequest,
                                            fabric : Matter::Fabric) : Matter::InteractionModel::Status
      unless bootstrap_anchor_role? && bootstrap_joint_fabric_datastore.access_mode.active? &&
             ENV["MATTER_JFA_ALLOW_JCM"]? == "1"
        return Matter::InteractionModel::Status.unsupported_access
      end
      open_joint_window_on_fabric(request, fabric)
    end

    private def open_joint_window_on_fabric(request : Admin::OpenJointCommissioningWindowRequest,
                                            fabric : Matter::Fabric) : Matter::InteractionModel::Status
      normal = Matter::Cluster::AdministratorCommissioning::OpenCommissioningWindowRequest.new(
        request.commissioning_timeout,
        request.pake_passcode_verifier,
        request.discriminator,
        request.iterations,
        request.salt
      )
      administrator_commissioning.open_commissioning_window(normal, fabric.fabric_index, fabric.vendor_id, joint: true)
      Matter::InteractionModel::Status.success
    rescue ex : Matter::ClusterError
      ex.to_status
    rescue ArgumentError
      Matter::InteractionModel::Status.constraint_error
    end
  end
end
