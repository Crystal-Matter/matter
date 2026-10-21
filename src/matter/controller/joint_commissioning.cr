require "../cluster/joint_fabric_administrator"
require "../cluster/joint_fabric_datastore"
require "../cluster/descriptor"
require "../crypto/certificate_builder"
require "../crypto/certificate_validation"
require "../crypto/pkcs10"
require "./im_client"
require "./vid_verification"
require "./commissioning/commissioner"
require "./pairing/case_pairing"

module Matter
  module Controller
    # The cryptographic ICAC exchange in Matter 1.6 Joint Commissioning.
    # The caller must first attest the joining Administrator, verify its
    # Vendor ID, and authenticate its existing ICAC public key. That key is
    # passed here instead of trusting the public key claimed in the CSR.
    module JointCommissioning
      extend self

      CERTIFICATE_SERIAL_BYTES =                         8
      ADMINISTRATOR_CAT_PREFIX = 0xFFFF_FFFD_FFFF_0000_u64
      ADMINISTRATOR_CAT_MASK   = 0xFFFF_FFFF_FFFF_0000_u64
      ANCHOR_CAT_PREFIX        = 0xFFFF_FFFD_FFFE_0000_u64
      BOOTSTRAP_RCAC_ID        =                     1_u64
      BOOTSTRAP_ICAC_ID        =                     3_u64
      BOOTSTRAP_SERIAL_BYTES   =                         8

      # Allocate against the Datastore NodeList supplied by the caller. A
      # collision requires a fresh random candidate rather than a sequential
      # fallback, which could disclose allocation order.
      def allocate_node_id(node_list_ids : Array(UInt64),
                           candidate : Proc(UInt64) = -> { DataType::NodeId.random_joint_fabric.id }) : UInt64
        loop do
          node_id = candidate.call
          return node_id if DataType::NodeId.valid_joint_fabric?(node_id) && !node_list_ids.includes?(node_id)
        end
      end

      # Persist this together with `fabric` to retain the Anchor ICAC issuer
      # across controller restarts. The root key inside FabricInfo is also used
      # for subsequent ICAC cross signing.
      struct AnchorBootstrap
        include Storage::Record

        getter fabric : FabricInfo
        getter anchor_icac_private_key : Bytes

        def initialize(@fabric, @anchor_icac_private_key)
        end

        def issue_noc(node_id : UInt64, public_key : Bytes,
                      cats : Array(UInt32) = [] of UInt32,
                      crypto : Crypto::CryptoBase = Crypto::StandardCrypto.new) : Bytes
          icac = @fabric.intermediate_cert || raise Matter::ConfigurationError.new("Anchor ICAC is missing")
          issuer = Crypto::Key.new(Crypto::KeyType::EC, Crypto::CurveType::P256)
          issuer.public_bits = Crypto::MatterCertificate.public_key_from_tlv(icac)
          issuer.private_bits = @anchor_icac_private_key
          Crypto::MatterCertificate::Builder.node(public_key: public_key,
            fabric_id: @fabric.fabric_id, node_id: node_id,
            issuer_key: issuer, issuer_rcac_id: BOOTSTRAP_RCAC_ID,
            issuer_icac_id: BOOTSTRAP_ICAC_ID,
            issuer_certificate: icac,
            serial: crypto.random_bytes(BOOTSTRAP_SERIAL_BYTES), crypto: crypto,
            case_authenticated_tags: cats)
        end

        def issue_anchor_administrator_noc(node_id : UInt64, public_key : Bytes,
                                           administrator_cat_version : UInt16 = 1_u16,
                                           anchor_cat_version : UInt16 = 1_u16,
                                           crypto : Crypto::CryptoBase = Crypto::StandardCrypto.new) : Bytes
          issue_noc(node_id, public_key,
            [0xFFFF_0000_u32 | administrator_cat_version.to_u32,
             0xFFFE_0000_u32 | anchor_cat_version.to_u32], crypto)
        end
      end

      def bootstrap_anchor_fabric(fabric_id : UInt64, controller_node_id : UInt64,
                                  vendor_id : UInt16,
                                  administrator_cat_version : UInt16 = 1_u16,
                                  anchor_cat_version : UInt16 = 1_u16,
                                  crypto : Crypto::CryptoBase = Crypto::StandardCrypto.new) : AnchorBootstrap
        if fabric_id == 0_u64 || !DataType::NodeId.valid_joint_fabric?(controller_node_id) ||
           administrator_cat_version == 0_u16 || anchor_cat_version == 0_u16
          raise Matter::ConfigurationError.new("Invalid Anchor fabric identity or CAT version")
        end
        root_key = crypto.create_key_pair
        root = Crypto::MatterCertificate::Builder.root(root_key, BOOTSTRAP_RCAC_ID,
          crypto.random_bytes(BOOTSTRAP_SERIAL_BYTES), crypto)
        icac_key = crypto.create_key_pair
        icac = Crypto::MatterCertificate::Builder.intermediate(
          icac_key.public_key, fabric_id, BOOTSTRAP_ICAC_ID, root_key,
          BOOTSTRAP_RCAC_ID, crypto.random_bytes(BOOTSTRAP_SERIAL_BYTES), crypto,
          anchor: true, issuer_certificate: root)
        controller_key = crypto.create_key_pair
        temporary = FabricInfo.new(fabric_id: fabric_id,
          controller_node_id: controller_node_id, ipk_value: crypto.random_bytes(Fabric::IPK_SIZE),
          root_cert: root, root_public_key: root_key.public_key,
          controller_noc: Bytes.empty, controller_private_key: controller_key.private_key,
          root_private_key: root_key.private_key, admin_vendor_id: vendor_id,
          intermediate_cert: icac, intermediate_private_key: icac_key.private_key)
        bootstrap = AnchorBootstrap.new(temporary, icac_key.private_key)
        controller_noc = bootstrap.issue_anchor_administrator_noc(controller_node_id,
          controller_key.public_key, administrator_cat_version, anchor_cat_version, crypto)
        fabric = FabricInfo.new(fabric_id: fabric_id,
          controller_node_id: controller_node_id, ipk_value: temporary.ipk_value,
          root_cert: root, root_public_key: root_key.public_key,
          controller_noc: controller_noc, controller_private_key: controller_key.private_key,
          root_private_key: root_key.private_key, admin_vendor_id: vendor_id,
          intermediate_cert: icac, intermediate_private_key: icac_key.private_key)
        AnchorBootstrap.new(fabric, icac_key.private_key)
      end

      struct PendingRegistration
        include Storage::Record

        getter fabric_id : UInt64
        getter controller_node_id : UInt64
        getter root_public_key : Bytes
        getter node_id : UInt64
        getter vendor_id : UInt16
        getter friendly_name : String
        property icac : Bytes
        property? completion_acknowledged : Bool = false
        getter peer_address : String?
        getter peer_port : Int32?
        getter handoff_nonce : String?
        getter joiner_icac_public_key : Bytes?

        def initialize(@fabric_id, @controller_node_id, @root_public_key, @node_id,
                       @vendor_id, @friendly_name, @icac,
                       @peer_address : String? = nil, @peer_port : Int32? = nil,
                       @completion_acknowledged : Bool = false,
                       @handoff_nonce : String? = nil,
                       @joiner_icac_public_key : Bytes? = nil)
        end

        def add_admin_request : Cluster::JointFabricDatastore::AddAdminRequest
          Cluster::JointFabricDatastore::AddAdminRequest.new(@node_id, @friendly_name, @vendor_id, @icac)
        end
      end

      # The application owns the attestation policy, user consent, certificate
      # issuer and persistent Datastore. These callbacks keep those decisions
      # outside the network transcript while making their ordering mandatory.
      # `register_admin` must be idempotent: `resume_pending` invokes it again
      # after an interrupted post-commissioning write. `add_admin_once` provides
      # that behavior for a local Datastore; network adapters must compare the
      # existing record before treating a duplicate as success.
      class CommissionerHooks < Commissioning::Commissioner::Hooks
        alias NocIssuer = Proc(FabricInfo, UInt64, Bytes, UInt32, Bytes)
        alias JoinerDecision = Proc(VerifiedJoiner, Bool)
        alias AttestJoiner = Proc(ImClient, Session::SecureContext, Socket::IPAddress, VerifiedJoiner, Bool)
        alias RegisterAdmin = Proc(Cluster::JointFabricDatastore::AddAdminRequest, Nil)
        alias PersistICAC = Proc(UInt64, Bytes, Nil)
        alias SavePending = Proc(PendingRegistration?, Nil)
        alias AnchorExchange = Proc(FabricInfo, UInt64, Socket::IPAddress, UInt16, Bytes, UInt64, Bytes)
        alias AnchorFinalize = Proc(FabricInfo, UInt64, Socket::IPAddress, UInt16, Bytes, UInt64, String, Bytes)

        @verified_joiner : VerifiedJoiner?
        @pending_node_id : UInt64?
        @pending : PendingRegistration?

        getter pending : PendingRegistration?

        def initialize(
          @administrator_fabric_index : UInt8,
          @administrator_endpoint : UInt16,
          @administrator_name : String,
          @administrator_cat_version : UInt16,
          @anchor_cat_version : UInt16,
          @icac_id : UInt64,
          @trust : VidVerification::OperationalTrustAnchors,
          @attest : AttestJoiner,
          @consent : JoinerDecision,
          @issue_noc : NocIssuer,
          @register_admin : RegisterAdmin,
          @persist_icac : PersistICAC,
          @save_pending : SavePending,
          initial_pending : PendingRegistration? = nil,
          @crypto : Crypto::CryptoBase = Crypto::StandardCrypto.new,
          @anchor_exchange : AnchorExchange? = nil,
          @anchor_finalize : AnchorFinalize? = nil,
        )
          @pending = initial_pending
          if @administrator_fabric_index == 0_u8 || @administrator_cat_version == 0_u16 ||
             @anchor_cat_version == 0_u16 || @icac_id == 0_u64
            raise Matter::ConfigurationError.new("Invalid Joint Commissioning fabric index, CAT version or ICAC ID")
          end
        end

        def supports_deferred_handoff? : Bool
          !@anchor_finalize.nil?
        end

        def finalize_deferred_handoff(fabric : FabricInfo, node_id : UInt64,
                                      im : ImClient, pase_session : Session::SecureContext,
                                      peer : Socket::IPAddress,
                                      handoff : PendingCommissioningHandoff) : Nil
          joiner = @verified_joiner
          unless joiner && @pending_node_id == node_id &&
                 handoff.fabric_id == fabric.fabric_id && handoff.root_public_key == fabric.root_public_key &&
                 handoff.node_id == node_id
            raise Matter::CommissioningError.new("Joint Commissioning deferred handoff identity is missing")
          end
          finalize = @anchor_finalize || raise Matter::ConfigurationError.new("Anchor finalizer is unavailable")
          pending = PendingRegistration.new(fabric.fabric_id, fabric.controller_node_id,
            fabric.root_public_key, node_id, joiner.fabric.descriptor.vendor_id,
            @administrator_name, Bytes.empty, peer.address, peer.port,
            handoff_nonce: handoff.nonce,
            joiner_icac_public_key: joiner.icac_public_key)
          @save_pending.call(pending)
          @pending = pending
          icac = finalize.call(fabric, node_id, peer, @administrator_endpoint,
            joiner.icac_public_key, @icac_id, handoff.nonce)
          JointCommissioning.validate_cross_signed_icac(icac, fabric, joiner.icac_public_key, @icac_id)
          pending.icac = icac
          @save_pending.call(pending)
          @pending = pending
        end

        def reconcile_handoff_result(fabric : FabricInfo, nonce : String, icac : Bytes,
                                     peer : Socket::IPAddress) : Nil
          pending = @pending || raise Matter::CommissioningError.new("No deferred Joint Commissioning registration")
          key = pending.joiner_icac_public_key ||
                raise Matter::CommissioningError.new("Deferred registration lacks authenticated ICAC key")
          unless pending.handoff_nonce == nonce && pending.fabric_id == fabric.fabric_id &&
                 pending.root_public_key == fabric.root_public_key
            raise Matter::AuthenticationError.new("Deferred Joint Commissioning result identity differs")
          end
          JointCommissioning.validate_cross_signed_icac(icac, fabric, key, @icac_id)
          pending.icac = icac
          @save_pending.call(pending)
          @pending = pending
          complete_acknowledged(fabric, pending.node_id, peer)
        end

        def after_deferred_handoff(fabric : FabricInfo, node_id : UInt64,
                                   peer : Socket::IPAddress) : Nil
          complete_pending(fabric, node_id)
          @verified_joiner = nil
          @pending_node_id = nil
        end

        def prepare_credentials(
          fabric : FabricInfo,
          node_id : UInt64,
          csr_public_key : Bytes,
          im : ImClient,
          pase_session : Session::SecureContext,
          peer : Socket::IPAddress,
        ) : Commissioning::Commissioner::OperationalCredentials
          endpoint = JointCommissioning.discover_administrator_endpoint(im, pase_session, peer)
          unless endpoint == @administrator_endpoint
            raise Matter::AuthenticationError.new("Joining Administrator endpoint differs from Descriptor")
          end
          fabric_index = JointCommissioning.read_administrator_fabric_index(im, pase_session, peer, endpoint)
          unless fabric_index == @administrator_fabric_index
            raise Matter::AuthenticationError.new("Joining Administrator fabric index differs from advertised selection")
          end
          joiner = JointCommissioning.verify_joiner(im, pase_session, peer,
            fabric_index, @trust, @crypto)
          raise Matter::AuthenticationError.new("Joining Administrator attestation failed") unless @attest.call(im, pase_session, peer, joiner)
          raise Matter::CommissioningError.new("Joint Commissioning consent denied") unless @consent.call(joiner)
          admin_version, anchor_version = JointCommissioning.read_joint_cat_versions(im,
            pase_session, peer, endpoint)
          unless admin_version == @administrator_cat_version && anchor_version == @anchor_cat_version
            raise Matter::AuthenticationError.new("Joining Datastore CAT versions differ from selected Joint Fabric versions")
          end
          JointCommissioning.require_administrator_cat!(joiner.fabric.noc.noc, admin_version)
          anchor_subject = ANCHOR_CAT_PREFIX | @anchor_cat_version.to_u64
          unless Crypto::MatterCertificate.subject_ids_from_tlv(fabric.controller_noc).includes?(anchor_subject)
            raise Matter::ConfigurationError.new("Controller NOC lacks the Anchor CAT needed for the ICAC exchange")
          end

          admin_cat = 0xFFFF_0000_u32 | @administrator_cat_version.to_u32
          noc = @issue_noc.call(fabric, node_id, csr_public_key, admin_cat)
          admin_subject = ADMINISTRATOR_CAT_PREFIX | @administrator_cat_version.to_u64
          unless Crypto::MatterCertificate.subject_ids_from_tlv(noc).includes?(admin_subject)
            raise Matter::CertificateError.new("Issued Administrator NOC lacks assigned Administrator CAT")
          end
          @verified_joiner = joiner
          @pending_node_id = node_id
          Commissioning::Commissioner::OperationalCredentials.new(noc, fabric.intermediate_cert,
            fabric.ipk_value, anchor_subject, fabric.admin_vendor_id)
        end

        def before_complete(
          fabric : FabricInfo,
          node_id : UInt64,
          im : ImClient,
          case_session : Session::SecureContext,
          peer : Socket::IPAddress,
        ) : Nil
          joiner = @verified_joiner
          unless joiner && @pending_node_id == node_id
            raise Matter::CommissioningError.new("Joint Commissioning verified joiner state is missing")
          end
          icac = if exchange = @anchor_exchange
                   exchange.call(fabric, node_id, peer, @administrator_endpoint,
                     joiner.icac_public_key, @icac_id)
                 else
                   response = im.invoke(session: case_session, peer: peer,
                     endpoint_id: @administrator_endpoint,
                     cluster_id: Cluster::JointFabricAdministrator::CLUSTER_ID,
                     command_id: Cluster::JointFabricAdministrator::CMD_ANNOUNCE_JOINT_FABRIC_ADMINISTRATOR,
                     fields: Cluster::JointFabricAdministrator::AnnounceJointFabricAdministratorRequest.new(@administrator_endpoint).to_slice)
                   JointCommissioning.assert_status_success(response)
                   JointCommissioning.exchange_icac(im, case_session, peer,
                     @administrator_endpoint, fabric.root_cert, fabric.certificate_authority_key,
                     fabric.fabric_id, joiner.icac_public_key, @icac_id, @crypto)
                 end
          JointCommissioning.validate_cross_signed_icac(icac, fabric, joiner.icac_public_key, @icac_id)
          pending = PendingRegistration.new(fabric.fabric_id, fabric.controller_node_id,
            fabric.root_public_key, node_id, joiner.fabric.descriptor.vendor_id,
            @administrator_name, icac, peer.address, peer.port)
          @save_pending.call(pending)
          @pending = pending
        end

        def after_complete(
          fabric : FabricInfo,
          node_id : UInt64,
          im : ImClient,
          case_session : Session::SecureContext,
          peer : Socket::IPAddress,
        ) : Nil
          unless @verified_joiner && @pending_node_id == node_id
            raise Matter::CommissioningError.new("Completed Joint Commissioning lacks cross-signed ICAC")
          end
          complete_pending(fabric, node_id)
          @verified_joiner = nil
          @pending_node_id = nil
        end

        def complete_acknowledged(fabric : FabricInfo, node_id : UInt64,
                                  peer : Socket::IPAddress) : Nil
          pending = @pending
          unless pending && pending.node_id == node_id && pending.fabric_id == fabric.fabric_id &&
                 pending.root_public_key == fabric.root_public_key &&
                 pending.peer_address == peer.address && pending.peer_port == peer.port && pending.icac.size > 0
            raise Matter::CommissioningError.new("Joint Commissioning completion does not match pending registration")
          end
          pending.completion_acknowledged = true
          @save_pending.call(pending)
          @pending = pending
        end

        # Retry a post-CommissioningComplete Datastore or storage failure after
        # restart. The controller's saved node proves CommissioningComplete was
        # acknowledged; an uncommissioned pending attempt is left untouched.
        def resume_pending(state : State) : Bool
          pending = @pending
          return false unless pending
          fabric = state.fabric_for(pending.fabric_id, pending.root_public_key,
            pending.controller_node_id)
          return false unless pending.completion_acknowledged? ||
                              state.nodes_for(fabric.fabric_id, fabric.root_public_key,
                                fabric.controller_node_id).has_key?(pending.node_id)
          complete_pending(fabric, pending.node_id)
          true
        end

        private def complete_pending(fabric : FabricInfo, node_id : UInt64) : Nil
          pending = @pending
          unless pending && pending.node_id == node_id && pending.fabric_id == fabric.fabric_id &&
                 pending.root_public_key == fabric.root_public_key
            raise Matter::CommissioningError.new("Joint Commissioning pending registration does not match fabric")
          end
          @register_admin.call(pending.add_admin_request)
          @persist_icac.call(node_id, pending.icac)
          @save_pending.call(nil)
          @pending = nil
        end
      end

      # A controller-facing Joint Commissioning entry point. The selected
      # Anchor fabric and its ICAC signing key must already be installed in
      # StateStore. Trust, attestation, consent and Datastore registration are
      # mandatory application policies; no implicit approval is provided.
      class Workflow
        COLLECTION = "joint_commissioning"
        record HandoffResult, nonce : String, certificate : Bytes
        alias HandoffResultLookup = Proc(String, HandoffResult?)

        getter hooks : CommissionerHooks

        def initialize(
          @store : StateStore,
          @fabric_id : UInt64,
          @root_public_key : Bytes,
          @controller_node_id : UInt64,
          administrator_fabric_index : UInt8,
          administrator_endpoint : UInt16,
          @administrator_name : String,
          administrator_cat_version : UInt16,
          anchor_cat_version : UInt16,
          icac_id : UInt64,
          trust : VidVerification::OperationalTrustAnchors,
          attest : CommissionerHooks::AttestJoiner,
          consent : CommissionerHooks::JoinerDecision,
          register_admin : CommissionerHooks::RegisterAdmin,
          anchor_exchange : CommissionerHooks::AnchorExchange,
          @client : Client = Client.new,
          @crypto : Crypto::CryptoBase = Crypto::StandardCrypto.new,
          anchor_finalize : CommissionerHooks::AnchorFinalize? = nil,
          @handoff_result : HandoffResultLookup? = nil,
          @attestation_verifier : DeviceAttestationVerifier? = nil,
          @datastore_registrar : DatastoreNodeRegistrar? = nil,
        )
          fabric = @store.load.fabric_for(@fabric_id, @root_public_key, @controller_node_id)
          validate_anchor_fabric(fabric, anchor_cat_version)
          initial_pending = load_pending
          @hooks = CommissionerHooks.new(
            administrator_fabric_index, administrator_endpoint, @administrator_name,
            administrator_cat_version, anchor_cat_version, icac_id, trust,
            attest, consent,
            ->(identity : FabricInfo, node_id : UInt64, public_key : Bytes, cat : UInt32) {
              JointCommissioning.issue_administrator_noc(identity, node_id, public_key, cat, @crypto)
            },
            register_admin,
            ->(node_id : UInt64, icac : Bytes) { save_icac(node_id, icac) },
            ->(pending : PendingRegistration?) { save_pending(pending) },
            initial_pending, @crypto, anchor_exchange, anchor_finalize
          )
        end

        def commission(node_id : UInt64, manual_code : String,
                       peer : Socket::IPAddress? = nil,
                       defer_completion : Bool = false) : Nil
          unless DataType::NodeId.valid_joint_fabric?(node_id)
            raise Matter::CommissioningError.new("Invalid Joint Fabric Node ID")
          end
          state = @store.load
          if node_id == @controller_node_id ||
             (state.nodes_for(@fabric_id, @root_public_key, @controller_node_id).has_key?(node_id) &&
             @hooks.pending.try(&.node_id) != node_id)
            raise Matter::CommissioningError.new("Joint Fabric Node ID is already in use")
          end
          recovering_node_id = @hooks.pending.try(&.node_id)
          recovered = resume_pending
          return if recovered && recovering_node_id == node_id
          if load_pending
            raise Matter::CommissioningError.new("A Joint Commissioning registration is still pending")
          end
          if @store.load.pending_handoffs.any? do |handoff|
               handoff.fabric_id == @fabric_id && handoff.root_public_key == @root_public_key &&
               handoff.controller_node_id == @controller_node_id
             end
            raise Matter::CommissioningError.new("A Joint Commissioning Anchor handoff needs reconciliation")
          end
          commissioner = Commissioning::Commissioner.new(@store, @client,
            crypto: @crypto, hooks: @hooks, fail_safe_expiry_seconds: 900_u16,
            attestation_verifier: @attestation_verifier,
            datastore_registrar: @datastore_registrar)
          commissioner.pairing_code(node_id, manual_code, peer,
            fabric_id: @fabric_id, root_public_key: @root_public_key,
            controller_node_id: @controller_node_id,
            defer_completion: defer_completion,
            friendly_name: @datastore_registrar ? @administrator_name : nil)
        end

        # Replays a registration only after the Commissioner saved the new
        # node, which proves CommissioningComplete was acknowledged.
        def resume_pending : Bool
          state = @store.load
          if pending = @hooks.pending
            fabric = state.fabric_for(pending.fabric_id, pending.root_public_key, pending.controller_node_id)
            if nonce = pending.handoff_nonce
              if !pending.completion_acknowledged?
                handoff = state.pending_handoffs.find do |entry|
                  entry.fabric_id == fabric.fabric_id && entry.root_public_key == fabric.root_public_key &&
                    entry.controller_node_id == fabric.controller_node_id &&
                    entry.node_id == pending.node_id && entry.nonce == nonce
                end
                return false unless handoff
                if Time.utc.to_unix > handoff.expires_at_unix
                  raise Matter::AuthenticationError.new("Deferred Joint Commissioning result deadline expired")
                end
                result = @handoff_result.try(&.call(nonce))
                return false unless result
                unless result.nonce == nonce
                  raise Matter::AuthenticationError.new("Deferred Joint Commissioning result nonce mismatch")
                end
                address = pending.peer_address || raise Matter::CommissioningError.new("Deferred registration has no peer address")
                port = pending.peer_port || raise Matter::CommissioningError.new("Deferred registration has no peer port")
                @hooks.reconcile_handoff_result(fabric, nonce, result.certificate,
                  Socket::IPAddress.new(address, port))
                pending = @hooks.pending.as(PendingRegistration)
              end
            end
            unless state.nodes_for(fabric.fabric_id, fabric.root_public_key,
                     fabric.controller_node_id).has_key?(pending.node_id)
              return false unless pending.completion_acknowledged?
              if nonce = pending.handoff_nonce
                state.recover_acknowledged_handoff(fabric.fabric_id, fabric.root_public_key,
                  fabric.controller_node_id, pending.node_id, nonce)
              else
                address = pending.peer_address || raise Matter::CommissioningError.new("Acknowledged registration has no peer address")
                port = pending.peer_port || raise Matter::CommissioningError.new("Acknowledged registration has no peer port")
                state.record_node(fabric.fabric_id, NodeInfo.new(node_id: pending.node_id,
                  address: address, port: port), fabric.root_public_key, fabric.controller_node_id)
              end
              @store.save(state)
            end
          end
          recovered = @hooks.resume_pending(state)
          if registrar = @datastore_registrar
            fabric = state.fabric_for(@fabric_id, @root_public_key, @controller_node_id)
            registrar.resume(fabric)
          end
          recovered
        end

        def stored_icac(node_id : UInt64) : Bytes?
          backend = opened_backend
          document = backend.read(COLLECTION, icac_document_id(node_id))
          document.try { |value| value["certificate"]?.as?(Bytes) }
        end

        def close : Nil
          @client.close
        end

        private def validate_anchor_fabric(fabric : FabricInfo, anchor_cat_version : UInt16) : Nil
          icac = fabric.intermediate_cert || raise Matter::ConfigurationError.new("Anchor fabric has no ICAC")
          unless Crypto::MatterCertificate.anchor_icac?(icac)
            raise Matter::ConfigurationError.new("Selected fabric ICAC is not an Anchor ICAC")
          end
          fabric.intermediate_authority_key
          fabric.certificate_authority_key
          anchor_subject = ANCHOR_CAT_PREFIX | anchor_cat_version.to_u64
          unless Crypto::MatterCertificate.subject_ids_from_tlv(fabric.controller_noc).includes?(anchor_subject)
            raise Matter::ConfigurationError.new("Selected controller NOC lacks the required Anchor CAT")
          end
        end

        private def load_pending : PendingRegistration?
          document = opened_backend.read(COLLECTION, pending_document_id)
          document.try { |value| PendingRegistration.from_document(value) }
        end

        private def save_pending(pending : PendingRegistration?) : Nil
          backend = opened_backend
          if value = pending
            backend.write(COLLECTION, pending_document_id, value.to_document)
          else
            backend.delete(COLLECTION, pending_document_id)
          end
        end

        private def save_icac(node_id : UInt64, icac : Bytes) : Nil
          opened_backend.write(COLLECTION, icac_document_id(node_id),
            Storage::Document{"certificate" => icac})
        end

        private def opened_backend : Storage::Backend
          backend = @store.backend
          backend.open unless backend.open?
          backend
        end

        private def pending_document_id : String
          "pending-#{fabric_key}"
        end

        private def icac_document_id(node_id : UInt64) : String
          "icac-#{fabric_key}-#{node_id.to_s(16)}"
        end

        private def fabric_key : String
          "#{@fabric_id.to_s(16)}-#{@root_public_key.hexstring}-#{@controller_node_id.to_s(16)}"
        end
      end

      # Idempotent network AddAdmin adapter for a Datastore on an already
      # commissioned Anchor Administrator. It reads first because a retry
      # after a crash may find that the previous AddAdmin succeeded.
      class RemoteDatastoreRegistrar
        def initialize(@store : StateStore, @client : Client,
                       @fabric_id : UInt64, @root_public_key : Bytes,
                       @controller_node_id : UInt64,
                       @anchor_node_id : UInt64, @datastore_endpoint : UInt16,
                       @timeout : Time::Span = 15.seconds,
                       @crypto : Crypto::CryptoBase = Crypto::StandardCrypto.new)
        end

        def callback : CommissionerHooks::RegisterAdmin
          ->(request : Cluster::JointFabricDatastore::AddAdminRequest) { register(request) }
        end

        def register(request : Cluster::JointFabricDatastore::AddAdminRequest) : Nil
          state = @store.load
          fabric = state.fabric_for(@fabric_id, @root_public_key, @controller_node_id)
          node = state.nodes_for(@fabric_id, @root_public_key, @controller_node_id)[@anchor_node_id]? ||
                 raise Matter::ConfigurationError.new("Anchor Administrator is absent from controller state")
          address = node.address || raise Matter::ConfigurationError.new("Anchor Administrator address is missing")
          peer = Socket::IPAddress.new(address, node.port)
          session = Pairing::CasePairing.new(@crypto).pair(@client, peer, fabric,
            peer_node_id: @anchor_node_id, timeout: @timeout)
          im = ImClient.new(@client, @timeout)
          report = im.read_attribute(session: session, peer: peer,
            endpoint_id: @datastore_endpoint,
            cluster_id: Cluster::JointFabricDatastore::CLUSTER_ID,
            attribute_id: Cluster::JointFabricDatastore::ATTR_ADMIN_LIST)
          data = report.attribute_reports.try(&.find(&.attribute_data)).try(&.attribute_data).try(&.data)
          raise Matter::ProtocolError.new("Datastore AdminList read omitted data") unless data
          admins = Array(Cluster::JointFabricDatastore::DatastoreAdministratorInformationEntryStruct).from_tlv(data.to_slice)
          if existing = admins.find(&.node_id.==(request.node_id))
            unless existing.friendly_name == request.friendly_name &&
                   existing.vendor_id == request.vendor_id && existing.icac == request.icac
              raise Matter::CommissioningError.new("Datastore already has a different Administrator record for this Node ID")
            end
            return
          end
          response = im.invoke(session: session, peer: peer,
            endpoint_id: @datastore_endpoint,
            cluster_id: Cluster::JointFabricDatastore::CLUSTER_ID,
            command_id: Cluster::JointFabricDatastore::CMD_ADD_ADMIN,
            fields: request.to_slice)
          JointCommissioning.assert_status_success(response)
        end
      end

      def issue_administrator_noc(fabric : FabricInfo, node_id : UInt64,
                                  public_key : Bytes, administrator_cat : UInt32,
                                  crypto : Crypto::CryptoBase = Crypto::StandardCrypto.new) : Bytes
        icac = fabric.intermediate_cert || raise Matter::ConfigurationError.new("Anchor fabric has no ICAC")
        issuer_id = Crypto::MatterCertificate.from_slice(icac).subject.icac_id ||
                    raise Matter::CertificateError.new("Anchor ICAC has no ICAC ID")
        root_id = Crypto::MatterCertificate.from_slice(fabric.root_cert).subject.rcac_id ||
                  raise Matter::CertificateError.new("Anchor root has no RCAC ID")
        Crypto::MatterCertificate::Builder.node(public_key: public_key,
          fabric_id: fabric.fabric_id, node_id: node_id,
          issuer_key: fabric.intermediate_authority_key,
          issuer_rcac_id: root_id, issuer_icac_id: issuer_id,
          issuer_certificate: icac,
          serial: crypto.random_bytes(CERTIFICATE_SERIAL_BYTES), crypto: crypto,
          case_authenticated_tags: [administrator_cat])
      end

      struct VerifiedJoiner
        getter fabric : VidVerification::VerifiedFabric
        getter icac_public_key : Bytes

        def initialize(@fabric, @icac_public_key)
        end
      end

      # This is the mandatory trust gate before issuing a NOC to a joining
      # Administrator. It proves the existing fabric's Vendor ID and ICAC key.
      def verify_joiner(
        im : ImClient,
        pase_session : Session::SecureContext,
        peer : Socket::IPAddress,
        administrator_fabric_index : UInt8,
        trust : VidVerification::OperationalTrustAnchors,
        crypto : Crypto::CryptoBase = Crypto::StandardCrypto.new,
      ) : VerifiedJoiner
        fabric = VidVerification.verify(im, pase_session, peer, administrator_fabric_index, trust, crypto)
        subjects = Crypto::MatterCertificate.subject_ids_from_tlv(fabric.noc.noc)
        unless subjects.any? do |subject|
                 (subject & ADMINISTRATOR_CAT_MASK) == ADMINISTRATOR_CAT_PREFIX &&
                 (subject & 0xffff_u64) != 0_u64
               end
          raise Matter::AuthenticationError.new("Joining Administrator NOC lacks Administrator CAT")
        end
        icac = fabric.noc.icac || raise Matter::AuthenticationError.new("Joining Administrator has no ICAC")
        VerifiedJoiner.new(fabric, Crypto::MatterCertificate.public_key_from_tlv(icac))
      end

      # A joining node must be an Administrator on its existing fabric at the
      # Datastore's current CAT version. A stale version has been revoked even
      # though it still has the reserved Administrator CAT identifier.
      def require_administrator_cat!(noc : Bytes, version : UInt16) : Nil
        subject = ADMINISTRATOR_CAT_PREFIX | version.to_u64
        unless version != 0_u16 && Crypto::MatterCertificate.subject_ids_from_tlv(noc).includes?(subject)
          raise Matter::AuthenticationError.new("Joining Administrator NOC lacks the current Administrator CAT")
        end
      end

      def discover_administrator_endpoint(im : ImClient, session : Session::SecureContext,
                                          peer : Socket::IPAddress) : UInt16
        queue = [0_u16]
        seen = Set(UInt16).new
        until queue.empty?
          endpoint = queue.shift
          next unless seen.add?(endpoint)
          types = read_descriptor_list(Cluster::Descriptor::DeviceTypeStruct, im, session, peer,
            endpoint, Cluster::Descriptor::ATTR_DEVICE_TYPE_LIST)
          servers = read_descriptor_list(UInt32, im, session, peer,
            endpoint, Cluster::Descriptor::ATTR_SERVER_LIST)
          if types.any?(&.device_type.==(DeviceType::JOINT_FABRIC_ADMINISTRATOR)) &&
             servers.includes?(Cluster::JointFabricAdministrator::CLUSTER_ID)
            return endpoint
          end
          queue.concat(read_descriptor_list(UInt16, im, session, peer,
            endpoint, Cluster::Descriptor::ATTR_PARTS_LIST))
        end

        # Some Administrators expose the JFA attribute in a wildcard read even
        # when their Descriptor PartsList does not enumerate the endpoint to
        # this fabric. The official SDK uses that attribute path to locate the
        # service. Require one concrete, non-null endpoint and re-read its
        # AdministratorFabricIndex before relying on it.
        path = InteractionModel::AttributePath.new(
          cluster: Cluster::JointFabricAdministrator::CLUSTER_ID,
          attribute: Cluster::JointFabricAdministrator::ATTR_ADMINISTRATOR_FABRIC_INDEX)
        report = im.read(session: session, peer: peer, attribute_paths: [path], fabric_filtered: false)
        endpoints = (report.attribute_reports || [] of InteractionModel::AttributeReportIB).compact_map do |entry|
          data = entry.attribute_data
          next unless data && data.path.cluster == path.cluster && data.path.attribute == path.attribute
          next if data.data.header.element_type.null?
          endpoint = data.path.endpoint
          next unless endpoint
          index = UInt8.from_tlv(data.data.to_slice)
          endpoint if index != 0_u8
        end
        endpoints.uniq!
        return endpoints.first if endpoints.size == 1
        raise Matter::AuthenticationError.new("Joining node has no Joint Fabric Administrator endpoint")
      end

      def read_administrator_fabric_index(im : ImClient, session : Session::SecureContext,
                                          peer : Socket::IPAddress, endpoint : UInt16) : UInt8
        report = im.read_attribute(session: session, peer: peer, endpoint_id: endpoint,
          cluster_id: Cluster::JointFabricAdministrator::CLUSTER_ID,
          attribute_id: Cluster::JointFabricAdministrator::ATTR_ADMINISTRATOR_FABRIC_INDEX,
          fabric_filtered: false)
        data = report.attribute_reports.try(&.find(&.attribute_data)).try(&.attribute_data).try(&.data)
        raise Matter::ProtocolError.new("AdministratorFabricIndex read omitted data") unless data
        index = UInt8.from_tlv(data.to_slice)
        raise Matter::AuthenticationError.new("AdministratorFabricIndex is invalid") if index == 0_u8
        index
      end

      # The joining ecosystem's Datastore declares the versions to use for
      # both reserved Joint Fabric CATs in AddNOC (Core §12.2.5 step 5).
      def read_joint_cat_versions(im : ImClient, session : Session::SecureContext,
                                  peer : Socket::IPAddress, endpoint : UInt16) : {UInt16, UInt16}
        report = im.read_attribute(session: session, peer: peer, endpoint_id: endpoint,
          cluster_id: Cluster::JointFabricDatastore::CLUSTER_ID,
          attribute_id: Cluster::JointFabricDatastore::ATTR_GROUP_LIST,
          fabric_filtered: false)
        data = report.attribute_reports.try(&.find(&.attribute_data)).try(&.attribute_data).try(&.data)
        raise Matter::ProtocolError.new("Joint Fabric Datastore GroupList read omitted data") unless data
        groups = Array(Cluster::JointFabricDatastore::DatastoreGroupInformationEntryStruct).from_tlv(data.to_slice)
        admin_versions = groups.select(&.group_cat.==(0xFFFF_u16)).compact_map(&.group_cat_version)
        anchor_versions = groups.select(&.group_cat.==(0xFFFE_u16)).compact_map(&.group_cat_version)
        unless admin_versions.size == 1 && anchor_versions.size == 1 &&
               admin_versions.first != 0_u16 && anchor_versions.first != 0_u16
          raise Matter::AuthenticationError.new("Joining Datastore lacks unique Joint Fabric CAT versions")
        end
        {admin_versions.first, anchor_versions.first}
      end

      # The joining Administrator performs this independently against the
      # Anchor, using its CASE session on the just-added fabric. The verified
      # original fabric must be the one used by that CASE session.
      def verify_anchor_initiator(im : ImClient, session : Session::SecureContext,
                                  peer : Socket::IPAddress, accessing_root_public_key : Bytes,
                                  accessing_fabric_id : UInt64,
                                  trust : VidVerification::OperationalTrustAnchors,
                                  crypto : Crypto::CryptoBase = Crypto::StandardCrypto.new) : VidVerification::VerifiedFabric
        endpoint = discover_administrator_endpoint(im, session, peer)
        fabric_index = read_administrator_fabric_index(im, session, peer, endpoint)
        verified = VidVerification.verify(im, session, peer, fabric_index, trust, crypto)
        unless verified.descriptor.root_public_key == accessing_root_public_key &&
               verified.descriptor.fabric_id == accessing_fabric_id
          raise Matter::AuthenticationError.new("Verified Anchor fabric differs from accessing CASE fabric")
        end
        verified
      end

      # Joining Administrator adapter. It opens a fresh outbound CASE session
      # using the NOC just installed on the Anchor fabric, then verifies the
      # Anchor Administrator's original fabric Vendor ID and fabric binding.
      def verify_anchor_from_fabric(fabric : Fabric, peer_node_id : UInt64,
                                    peer : Socket::IPAddress,
                                    trust : VidVerification::OperationalTrustAnchors,
                                    timeout : Time::Span = 10.seconds,
                                    crypto : Crypto::CryptoBase = Crypto::StandardCrypto.new) : VidVerification::VerifiedFabric
        root = fabric.root_cert || raise Matter::ConfigurationError.new("Joining fabric has no RCAC")
        identity = FabricInfo.new(fabric_id: fabric.fabric_id,
          controller_node_id: fabric.node_id,
          ipk_value: fabric.ipk,
          root_cert: root,
          root_public_key: fabric.root_public_key,
          controller_noc: fabric.operational_cert,
          controller_private_key: fabric.operational_private_key,
          admin_vendor_id: fabric.vendor_id,
          intermediate_cert: fabric.intermediate_cert)
        client = Client.new(unsecured_source_node_id: fabric.node_id, crypto: crypto)
        begin
          session = Pairing::CasePairing.new(crypto).pair(client, peer, identity,
            peer_node_id: peer_node_id, timeout: timeout)
          verify_anchor_initiator(ImClient.new(client, timeout), session, peer,
            fabric.root_public_key, fabric.fabric_id, trust, crypto)
        ensure
          client.close
        end
      end

      private def read_descriptor_list(type : T.class, im : ImClient, session : Session::SecureContext,
                                       peer : Socket::IPAddress, endpoint : UInt16,
                                       attribute_id : UInt32) : Array(T) forall T
        report = im.read_attribute(session: session, peer: peer, endpoint_id: endpoint,
          cluster_id: Cluster::Descriptor::CLUSTER_ID, attribute_id: attribute_id,
          fabric_filtered: false)
        data = report.attribute_reports.try(&.find(&.attribute_data)).try(&.attribute_data).try(&.data)
        raise Matter::ProtocolError.new("Descriptor read omitted attribute #{attribute_id}") unless data
        Array(T).from_tlv(data.to_slice)
      end

      # Local Datastore adapter for the resumable completion callback. A retry
      # may find the record already committed if the process stopped between
      # AddAdmin and clearing PendingRegistration.
      def add_admin_once(datastore : Cluster::JointFabricDatastore,
                         request : Cluster::JointFabricDatastore::AddAdminRequest) : Nil
        if existing = datastore.admin_list.find(&.node_id.==(request.node_id))
          unless existing.friendly_name == request.friendly_name &&
                 existing.vendor_id == request.vendor_id && existing.icac == request.icac
            raise Matter::CommissioningError.new("Datastore has a conflicting Administrator record")
          end
          return
        end
        outcome = datastore.add_admin(request)
        raise Matter::CommissioningError.new("Datastore AddAdmin failed (#{outcome})") unless outcome.success?
      end

      def cross_sign_icac(
        anchor_root_certificate : Bytes,
        anchor_root_key : Crypto::Key,
        anchor_fabric_id : UInt64,
        joining_icac_public_key : Bytes,
        csr : Bytes,
        icac_id : UInt64,
        crypto : Crypto::CryptoBase = Crypto::StandardCrypto.new,
      ) : Bytes
        root = Crypto::MatterCertificate.from_slice(anchor_root_certificate)
        unless root.ec_public_key == anchor_root_key.public_key && root.subject.rcac_id &&
               Crypto::MatterCertificate::Validation.certificate_authority?(anchor_root_certificate)
          raise Matter::CertificateError.new("Anchor root signing key and certificate do not match")
        end
        Crypto::MatterCertificate::Validation.verify_signature(anchor_root_certificate, root.ec_public_key)
        Crypto::Pkcs10.verify(csr, joining_icac_public_key, crypto)
        rcac_id = root.subject.rcac_id || raise Matter::CertificateError.new("Anchor root has no RCAC ID")

        icac = Crypto::MatterCertificate::Builder.intermediate(
          public_key: joining_icac_public_key,
          fabric_id: anchor_fabric_id,
          icac_id: icac_id,
          issuer_key: anchor_root_key,
          issuer_rcac_id: rcac_id,
          serial: crypto.random_bytes(CERTIFICATE_SERIAL_BYTES),
          crypto: crypto,
          issuer_certificate: anchor_root_certificate
        )
        Crypto::MatterCertificate::Validation.verify_signature(icac, root.ec_public_key)
        icac
      end

      # Execute the CASE-protected request/response pair after the joining
      # Administrator has received its NOC on the Anchor fabric.
      def exchange_icac(
        im : ImClient,
        session : Session::SecureContext,
        peer : Socket::IPAddress,
        administrator_endpoint : UInt16,
        anchor_root_certificate : Bytes,
        anchor_root_key : Crypto::Key,
        anchor_fabric_id : UInt64,
        verified_joiner : VerifiedJoiner,
        icac_id : UInt64,
        crypto : Crypto::CryptoBase = Crypto::StandardCrypto.new,
      ) : Bytes
        exchange_icac(im, session, peer, administrator_endpoint, anchor_root_certificate,
          anchor_root_key, anchor_fabric_id, verified_joiner.icac_public_key, icac_id, crypto)
      end

      def exchange_icac(
        im : ImClient,
        session : Session::SecureContext,
        peer : Socket::IPAddress,
        administrator_endpoint : UInt16,
        anchor_root_certificate : Bytes,
        anchor_root_key : Crypto::Key,
        anchor_fabric_id : UInt64,
        icac_public_key : Bytes,
        icac_id : UInt64,
        crypto : Crypto::CryptoBase = Crypto::StandardCrypto.new,
      ) : Bytes
        response = im.invoke(
          session: session,
          peer: peer,
          endpoint_id: administrator_endpoint,
          cluster_id: Cluster::JointFabricAdministrator::CLUSTER_ID,
          command_id: Cluster::JointFabricAdministrator::CMD_ICACCSR_REQUEST
        )
        csr_response = Cluster::JointFabricAdministrator::ICACCSRResponse.from_slice(
          command_fields(response, Cluster::JointFabricAdministrator::CMD_ICACCSR_REQUEST_RESPONSE)
        )
        unless csr_response.status_code.ok? && (csr = csr_response.icaccsr)
          raise Matter::CommissioningError.new("Joining Administrator refused ICAC CSR")
        end

        icac = cross_sign_icac(anchor_root_certificate, anchor_root_key, anchor_fabric_id,
          icac_public_key, csr, icac_id, crypto)
        add_response = im.invoke(
          session: session,
          peer: peer,
          endpoint_id: administrator_endpoint,
          cluster_id: Cluster::JointFabricAdministrator::CLUSTER_ID,
          command_id: Cluster::JointFabricAdministrator::CMD_ADD_ICAC,
          fields: Cluster::JointFabricAdministrator::AddICACRequest.new(icac).to_slice
        )
        outcome = Cluster::JointFabricAdministrator::ICACResponse.from_slice(
          command_fields(add_response, Cluster::JointFabricAdministrator::CMD_ADD_ICAC_RESPONSE)
        )
        unless outcome.status_code.ok?
          raise Matter::CommissioningError.new("Joining Administrator rejected cross-signed ICAC (#{outcome.status_code})")
        end
        icac
      end

      def validate_cross_signed_icac(icac : Bytes, fabric : FabricInfo,
                                     expected_public_key : Bytes, icac_id : UInt64) : Nil
        certificate = Crypto::MatterCertificate.from_slice(icac)
        unless certificate.ec_public_key == expected_public_key &&
               certificate.subject.fabric_id == fabric.fabric_id &&
               certificate.subject.icac_id == icac_id &&
               Crypto::MatterCertificate::Validation.certificate_authority?(icac)
          raise Matter::CertificateError.new("Anchor exchange returned an ICAC with the wrong identity")
        end
        Crypto::MatterCertificate::Validation.verify_intermediate_profile(icac, fabric.fabric_id)
        Crypto::MatterCertificate::Validation.verify_issued_by(icac, fabric.root_cert)
        Crypto::MatterCertificate::Validation.verify_signature(icac, fabric.root_public_key)
      end

      private def command_fields(response : InteractionModel::InvokeResponseMessage, command_id : UInt32) : Bytes
        response.invoke_responses.each do |item|
          if command = item.command_data
            if command.command_path.command == command_id
              fields = command.command_fields
              return fields ? fields.to_slice : Bytes.empty
            end
          end
          if status = item.command_status
            raise Matter::CommissioningError.new("Joint Fabric Administrator command failed (#{status.status.status})")
          end
        end
        raise Matter::ProtocolError.new("Joint Fabric Administrator response missing command #{command_id}")
      end

      def assert_status_success(response : InteractionModel::InvokeResponseMessage) : Nil
        response.invoke_responses.each do |item|
          if status = item.command_status
            return if status.status.status == InteractionModel::StatusCode::Success.value
            raise Matter::CommissioningError.new("Joint Fabric Administrator command failed (#{status.status.status})")
          end
        end
        raise Matter::ProtocolError.new("Joint Fabric Administrator returned no command status")
      end
    end
  end
end
