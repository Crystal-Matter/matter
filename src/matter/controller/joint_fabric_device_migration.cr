require "../node"
require "../cluster/joint_fabric_datastore"
require "../cluster/operational_credentials"
require "./commissioning/commissioner"
require "./commissioning/window_opener"
require "./joint_commissioning"

module Matter
  module Controller
    # Moves an existing Fabric B device to the Anchor Fabric after JCM. The
    # old operational identity remains valid until the new one has been
    # commissioned, authenticated over CASE, and registered with the Anchor.
    module JointFabricDeviceMigration
      ADMINISTRATOR_CAT_ID     = Cluster::JointFabricDatastore::ADMINISTRATOR_CAT.to_u32
      CERTIFICATE_SERIAL_BYTES = 8

      enum Stage : UInt8
        Ready
        CommissioningAnchor
        AnchorCommissioned
        VerifyingAnchor
        AnchorVerified
        AddingAnchorNode
        AnchorNodeAdded
        RemovingOldFabric
        OldFabricRemoved
        RemovingOldNode
        Complete
        RollingBack
        RolledBack
      end

      struct Journal
        include Storage::Record

        getter old_fabric_id : UInt64
        getter anchor_fabric_id : UInt64
        getter old_node_id : UInt64
        getter anchor_node_id : UInt64
        getter old_root_public_key : Bytes
        getter anchor_root_public_key : Bytes
        property stage : Stage
        property? commissioning_acknowledged : Bool = false
        property fail_safe_deadline_unix : Int64? = nil
        property fail_safe_max_seconds : UInt16? = nil

        def initialize(@old_fabric_id : UInt64, @anchor_fabric_id : UInt64,
                       @old_node_id : UInt64, @anchor_node_id : UInt64,
                       @old_root_public_key : Bytes, @anchor_root_public_key : Bytes,
                       @stage : Stage = Stage::Ready,
                       @commissioning_acknowledged : Bool = false,
                       @fail_safe_deadline_unix : Int64? = nil,
                       @fail_safe_max_seconds : UInt16? = nil)
        end
      end

      # Durable per-device progress. Keep completed journals so a retry after
      # process restart can report completion without repeating RemoveFabric.
      class JournalStore
        COLLECTION = "joint_fabric_device_migration"

        def initialize(@backend : Storage::Backend)
        end

        def save(journal : Journal) : Nil
          @backend.open unless @backend.open?
          @backend.write(COLLECTION, document_id(journal), journal.to_document)
        end

        def load(old_fabric_id : UInt64, old_root_public_key : Bytes,
                 old_node_id : UInt64, anchor_fabric_id : UInt64,
                 anchor_root_public_key : Bytes, anchor_node_id : UInt64) : Journal?
          @backend.open unless @backend.open?
          id = identity_key(old_fabric_id, old_root_public_key, old_node_id,
            anchor_fabric_id, anchor_root_public_key, anchor_node_id)
          @backend.read(COLLECTION, id).try { |document| Journal.from_document(document) }
        end

        private def document_id(journal : Journal) : String
          identity_key(journal.old_fabric_id, journal.old_root_public_key,
            journal.old_node_id, journal.anchor_fabric_id,
            journal.anchor_root_public_key, journal.anchor_node_id)
        end

        private def identity_key(old_fabric_id : UInt64, old_root_public_key : Bytes,
                                 old_node_id : UInt64, anchor_fabric_id : UInt64,
                                 anchor_root_public_key : Bytes, anchor_node_id : UInt64) : String
          "#{old_fabric_id.to_s(16)}-#{old_root_public_key.hexstring}-#{old_node_id.to_s(16)}-#{anchor_fabric_id.to_s(16)}-#{anchor_root_public_key.hexstring}-#{anchor_node_id.to_s(16)}"
        end
      end

      abstract class Port
        abstract def commission_anchor! : Nil
        abstract def verify_anchor! : Nil
        abstract def add_anchor_node! : Nil
        abstract def refresh_anchor_registration! : Nil
        abstract def remove_old_fabric! : Nil
        abstract def remove_old_node! : Nil
        abstract def verify_postcondition!(stage : Stage) : Nil
        abstract def verify_no_effect!(stage : Stage) : Nil

        def cleanup_failed_anchor_registration! : Nil
        end

        abstract def rollback_anchor!(anchor_registered : Bool) : Nil
        abstract def resume_rollback! : Nil
        abstract def finalize_rollback! : Nil
        abstract def finalize_migration! : Nil
        abstract def validate_journal!(journal : Journal) : Nil
      end

      # Network implementation for a B Administrator that already has a
      # cross-signed A identity. Every CASE peer is pinned to the selected
      # fabric's root and Node ID. The Anchor registration must reach Committed
      # before the B fabric is removed from the device.
      class NetworkPort < Port
        DEFAULT_WINDOW_SECONDS   =   180_u16
        DEFAULT_PBKDF_ITERATIONS = 1_000_u32
        REGISTRATION_POLL        = 250.milliseconds

        @journal : Journal? = nil

        def initialize(@store : StateStore, @old_fabric : FabricInfo,
                       @anchor_fabric : FabricInfo, @issuer : CrossSignedIssuer,
                       @old_node_id : UInt64, @anchor_node_id : UInt64,
                       @device_peer : Socket::IPAddress,
                       @old_datastore_node_id : UInt64,
                       @old_datastore_peer : Socket::IPAddress,
                       @old_datastore_endpoint : UInt16,
                       @anchor_datastore_node_id : UInt64,
                       @anchor_datastore_peer : Socket::IPAddress,
                       @anchor_datastore_endpoint : UInt16,
                       @friendly_name : String,
                       @administrator_cat : UInt32,
                       @attestation_verifier : DeviceAttestationVerifier,
                       @commissioning_ack : Proc(Nil)? = nil,
                       @fail_safe_deadline : Proc(Int64, UInt16, Nil)? = nil,
                       @anchor_registration_committed : Proc(Nil)? = nil,
                       @anchor_node_removed : Proc(Nil)? = nil,
                       @anchor_fabric_removed : Proc(Nil)? = nil,
                       @old_fabric_removed : Proc(Nil)? = nil,
                       @old_node_removed : Proc(Nil)? = nil,
                       @timeout : Time::Span = 15.seconds,
                       @crypto : Crypto::CryptoBase = Crypto::StandardCrypto.new,
                       @client : Client = Client.new,
                       @monotonic_now : Proc(Time::Instant) = -> { Time.instant },
                       @recovery_sleep : Proc(Time::Span, Nil) = ->(duration : Time::Span) { sleep duration })
          if @old_node_id == DataType::NodeId::UNSPECIFIED || @anchor_node_id == DataType::NodeId::UNSPECIFIED ||
             (@old_fabric.fabric_id == @anchor_fabric.fabric_id &&
             @old_fabric.root_public_key == @anchor_fabric.root_public_key)
            raise Matter::ConfigurationError.new("Migration requires distinct B and Anchor fabric identities")
          end
          installed = @store.load.fabric_for(@anchor_fabric.fabric_id,
            @anchor_fabric.root_public_key, @anchor_fabric.controller_node_id)
          unless installed.intermediate_cert == @anchor_fabric.intermediate_cert &&
                 installed.controller_noc == @anchor_fabric.controller_noc &&
                 installed.controller_private_key == @anchor_fabric.controller_private_key
            raise Matter::ConfigurationError.new("Installed Anchor operational identity differs from selected identity")
          end
          @issuer.validate_fabrics!(@old_fabric, @anchor_fabric)
        end

        def close : Nil
          @client.close
        end

        def validate_journal!(journal : Journal) : Nil
          unless journal.old_fabric_id == @old_fabric.fabric_id &&
                 journal.old_root_public_key == @old_fabric.root_public_key &&
                 journal.old_node_id == @old_node_id &&
                 journal.anchor_fabric_id == @anchor_fabric.fabric_id &&
                 journal.anchor_root_public_key == @anchor_fabric.root_public_key &&
                 journal.anchor_node_id == @anchor_node_id
            raise Matter::AuthenticationError.new("Migration journal does not match selected network identities")
          end
          @journal = journal
        end

        def commission_anchor! : Nil
          verify_anchor_material!
          anchor_state = @store.load
          if anchor_state.nodes_for(@anchor_fabric.fabric_id,
               @anchor_fabric.root_public_key, @anchor_fabric.controller_node_id).has_key?(@anchor_node_id)
            raise Matter::ConfigurationError.new("Selected Anchor Node ID is already commissioned")
          end
          anchor_session = case_session(@anchor_fabric, @anchor_datastore_node_id, @anchor_datastore_peer)
          if datastore_nodes(ImClient.new(@client, @timeout), anchor_session,
               @anchor_datastore_peer, @anchor_datastore_endpoint).any?(&.node_id.==(@anchor_node_id))
            raise Matter::ConfigurationError.new("Selected Anchor Node ID already exists in NodeList")
          end
          datastore_session = case_session(@old_fabric, @old_datastore_node_id, @old_datastore_peer)
          current_admin_cat, _anchor_cat = JointCommissioning.read_joint_cat_versions(
            ImClient.new(@client, @timeout), datastore_session,
            @old_datastore_peer, @old_datastore_endpoint)
          unless @administrator_cat == DataType::CaseAuthenticatedTag.create(
                   Cluster::JointFabricDatastore::ADMINISTRATOR_CAT, current_admin_cat).value
            raise Matter::AuthenticationError.new("Selected Administrator CAT differs from Fabric B Datastore")
          end
          JointCommissioning.require_administrator_cat!(@old_fabric.controller_noc, current_admin_cat)
          old_session = case_session(@old_fabric, @old_node_id, @device_peer)
          window = Commissioning::CommissioningWindowOpener.new(@crypto).open_enhanced(
            ImClient.new(@client, @timeout), old_session, @device_peer,
            DEFAULT_WINDOW_SECONDS, DEFAULT_PBKDF_ITERATIONS,
            Random::Secure.rand(0_u16..SetupPayload::MAX_DISCRIMINATOR))
          deadline_callback = @fail_safe_deadline ? ->(deadline : Int64, max_seconds : UInt16) { persist_fail_safe_deadline!(deadline, max_seconds) } : nil
          hooks = Credentials.new(@issuer, @administrator_cat, @old_fabric.admin_vendor_id,
            @crypto, -> { persist_commissioning_ack! }, deadline_callback)
          registrar = datastore_registrar
          commissioner = Commissioning::Commissioner.new(@store, @client, @timeout,
            @crypto, hooks: hooks, attestation_verifier: @attestation_verifier,
            datastore_registrar: registrar)
          commissioner.pairing_code(@anchor_node_id, window.manual_pairing_code,
            peer: @device_peer, fabric_id: @anchor_fabric.fabric_id,
            root_public_key: @anchor_fabric.root_public_key,
            controller_node_id: @anchor_fabric.controller_node_id,
            friendly_name: @friendly_name)
        end

        private def datastore_registrar : DatastoreNodeRegistrar
          delivery = DatastoreNodeRegistrar::NetworkDelivery.new(@store, @client,
            @anchor_datastore_node_id, @anchor_datastore_endpoint, @timeout,
            @crypto, @anchor_datastore_peer)
          DatastoreNodeRegistrar.new(@store, delivery)
        end

        private def verify_anchor_material! : Nil
          session = case_session(@anchor_fabric, @anchor_datastore_node_id, @anchor_datastore_peer)
          im = ImClient.new(@client, @timeout)
          root_data = datastore_attribute(im, session, @anchor_datastore_peer,
            @anchor_datastore_endpoint, Cluster::JointFabricDatastore::ATTR_ANCHOR_ROOT_CA)
          unless Bytes.from_tlv(root_data.to_slice) == @anchor_fabric.root_cert
            raise Matter::AuthenticationError.new("Anchor Datastore RCAC differs from selected fabric")
          end
          key_data = datastore_attribute(im, session, @anchor_datastore_peer,
            @anchor_datastore_endpoint, Cluster::JointFabricDatastore::ATTR_GROUP_KEY_SET_LIST)
          sets = Array(Cluster::JointFabricDatastore::DatastoreGroupKeySetStruct).from_tlv(key_data.to_slice)
          JointFabricDeviceMigration.validate_anchor_ipk!(sets, @anchor_fabric.ipk_value)
        end

        private def persist_commissioning_ack! : Nil
          if callback = @commissioning_ack
            callback.call
            if journal = @journal
              journal.commissioning_acknowledged = true
              @journal = journal
            end
          end
        end

        private def persist_fail_safe_deadline!(deadline_unix : Int64, max_seconds : UInt16) : Nil
          if callback = @fail_safe_deadline
            callback.call(deadline_unix, max_seconds)
            if journal = @journal
              journal.fail_safe_deadline_unix = deadline_unix
              journal.fail_safe_max_seconds = max_seconds
              @journal = journal
            end
          end
        end

        def verify_anchor! : Nil
          session = case_session(@anchor_fabric, @anchor_node_id, @device_peer)
          descriptors = fabrics(session, @device_peer)
          unless descriptors.any? do |entry|
                   entry.fabric_id == @anchor_fabric.fabric_id &&
                   entry.root_public_key == @anchor_fabric.root_public_key &&
                   entry.node_id == @anchor_node_id
                 end
            raise Matter::AuthenticationError.new("Device CASE succeeded but Anchor fabric descriptor differs")
          end
        end

        def add_anchor_node! : Nil
          session = case_session(@anchor_fabric, @anchor_datastore_node_id, @anchor_datastore_peer)
          im = ImClient.new(@client, @timeout)
          entry = datastore_nodes(im, session, @anchor_datastore_peer,
            @anchor_datastore_endpoint).find(&.node_id.==(@anchor_node_id)) ||
                  raise Matter::CommissioningError.new("Anchor Datastore has no staged migrated node")
          unless entry.friendly_name == @friendly_name
            raise Matter::AuthenticationError.new("Anchor Datastore migrated node identity changed")
          end
          refresh_anchor_registration! unless entry.commissioning_status_entry.state.committed?
          wait_anchor_node_committed!(im, session)
          @anchor_registration_committed.try(&.call)
        end

        def refresh_anchor_registration! : Nil
          verify_anchor!
          require_old_fabric_present!
          entry = anchor_node_entry ||
                  raise Matter::CommissioningError.new("Anchor Datastore has no pending migrated node to refresh")
          return if entry.commissioning_status_entry.state.committed?
          session = case_session(@anchor_fabric, @anchor_datastore_node_id, @anchor_datastore_peer)
          im = ImClient.new(@client, @timeout)
          response = im.invoke(session, @anchor_datastore_peer, @anchor_datastore_endpoint,
            Cluster::JointFabricDatastore::CLUSTER_ID,
            Cluster::JointFabricDatastore::CMD_REFRESH_NODE,
            Cluster::JointFabricDatastore::RefreshNodeRequest.new(@anchor_node_id).to_slice)
          assert_status_success!(response, "RefreshNode")
          wait_anchor_node_committed!(im, session)
        end

        def cleanup_failed_anchor_registration! : Nil
          return unless owned_pending_registration?
          if entry = anchor_node_entry
            unless entry.friendly_name == @friendly_name
              raise Matter::AuthenticationError.new("Anchor Datastore migrated node identity changed")
            end
            session = case_session(@anchor_fabric, @anchor_datastore_node_id, @anchor_datastore_peer)
            response = ImClient.new(@client, @timeout).invoke(session, @anchor_datastore_peer,
              @anchor_datastore_endpoint, Cluster::JointFabricDatastore::CLUSTER_ID,
              Cluster::JointFabricDatastore::CMD_REMOVE_NODE,
              Cluster::JointFabricDatastore::RemoveNodeRequest.new(@anchor_node_id).to_slice)
            assert_status_success!(response, "RemoveNode after failed commissioning")
          end
          @store.update do |state|
            state.pending_datastore_nodes.reject! do |item|
              item.fabric_id == @anchor_fabric.fabric_id &&
                item.root_public_key == @anchor_fabric.root_public_key &&
                item.controller_node_id == @anchor_fabric.controller_node_id &&
                item.node_id == @anchor_node_id &&
                item.friendly_name == @friendly_name
            end
          end
        end

        private def wait_anchor_node_committed!(im : ImClient,
                                                session : Session::SecureContext) : Nil
          deadline = Time.instant + @timeout
          loop do
            nodes = datastore_nodes(im, session, @anchor_datastore_peer, @anchor_datastore_endpoint)
            entry = nodes.find(&.node_id.==(@anchor_node_id))
            if entry && entry.commissioning_status_entry.state.committed?
              return
            end
            if entry && entry.commissioning_status_entry.state.commit_failed?
              raise Matter::CommissioningError.new("Anchor Datastore failed to commit the migrated node")
            end
            raise Matter::TimeoutError.new("Anchor Datastore did not commit the migrated node") if Time.instant >= deadline
            sleep REGISTRATION_POLL
          end
        end

        def remove_old_fabric! : Nil
          session = case_session(@anchor_fabric, @anchor_node_id, @device_peer)
          descriptor = fabrics(session, @device_peer).find do |entry|
            entry.fabric_id == @old_fabric.fabric_id &&
              entry.root_public_key == @old_fabric.root_public_key &&
              entry.node_id == @old_node_id
          end
          raise Matter::AuthenticationError.new("Selected Fabric B is absent or has a different device Node ID") unless descriptor
          response = ImClient.new(@client, @timeout).invoke(session, @device_peer, Node::ROOT_ENDPOINT_ID,
            Cluster::OperationalCredentials::CLUSTER_ID,
            Cluster::OperationalCredentials::CMD_REMOVE_FABRIC,
            Cluster::OperationalCredentials::Tlv::RemoveFabricRequest.new(descriptor.fabric_index).to_slice)
          assert_noc_success!(response, "RemoveFabric")
          if fabrics(session, @device_peer).any? do |entry|
               entry.fabric_id == @old_fabric.fabric_id && entry.root_public_key == @old_fabric.root_public_key
             end
            raise Matter::CommissioningError.new("Fabric B remained installed after RemoveFabric")
          end
          @old_fabric_removed.try(&.call)
        end

        def remove_old_node! : Nil
          session = case_session(@old_fabric, @old_datastore_node_id, @old_datastore_peer)
          response = ImClient.new(@client, @timeout).invoke(session, @old_datastore_peer,
            @old_datastore_endpoint, Cluster::JointFabricDatastore::CLUSTER_ID,
            Cluster::JointFabricDatastore::CMD_REMOVE_NODE,
            Cluster::JointFabricDatastore::RemoveNodeRequest.new(@old_node_id).to_slice)
          assert_status_success!(response, "RemoveNode")
          verify_postcondition!(Stage::Complete)
          @old_node_removed.try(&.call)
        end

        def rollback_anchor!(anchor_registered : Bool) : Nil
          resume_rollback!
        end

        # An interrupted rollback may have removed only the Anchor NodeList
        # entry. Every retry first reads both peers over CASE and issues only
        # the removal whose target is still present.
        def resume_rollback! : Nil
          require_old_fabric_present!
          if anchor_node_entry
            session = case_session(@anchor_fabric, @anchor_datastore_node_id, @anchor_datastore_peer)
            response = ImClient.new(@client, @timeout).invoke(session, @anchor_datastore_peer,
              @anchor_datastore_endpoint, Cluster::JointFabricDatastore::CLUSTER_ID,
              Cluster::JointFabricDatastore::CMD_REMOVE_NODE,
              Cluster::JointFabricDatastore::RemoveNodeRequest.new(@anchor_node_id).to_slice)
            assert_status_success!(response, "Anchor RemoveNode")
            @anchor_node_removed.try(&.call)
          end
          session = case_session(@old_fabric, @old_node_id, @device_peer)
          descriptor = fabrics(session, @device_peer).find do |entry|
            entry.fabric_id == @anchor_fabric.fabric_id &&
              entry.root_public_key == @anchor_fabric.root_public_key &&
              entry.node_id == @anchor_node_id
          end
          if descriptor
            response = ImClient.new(@client, @timeout).invoke(session, @device_peer, Node::ROOT_ENDPOINT_ID,
              Cluster::OperationalCredentials::CLUSTER_ID,
              Cluster::OperationalCredentials::CMD_REMOVE_FABRIC,
              Cluster::OperationalCredentials::Tlv::RemoveFabricRequest.new(descriptor.fabric_index).to_slice)
            assert_noc_success!(response, "Anchor RemoveFabric")
            @anchor_fabric_removed.try(&.call)
          end
          verify_postcondition!(Stage::RolledBack)
        end

        # The controller's A node record was saved during commissioning. Keep
        # it until authenticated reads prove that both remote removals took
        # effect; if this save fails, the RollingBack journal can retry it.
        def finalize_rollback! : Nil
          verify_postcondition!(Stage::RolledBack)
          state = @store.load
          nodes = state.nodes_for(@anchor_fabric.fabric_id,
            @anchor_fabric.root_public_key, @anchor_fabric.controller_node_id)
          @store.save(state) if nodes.delete(@anchor_node_id)
        end

        # The old controller node is no longer reachable after the device's
        # B fabric and B Datastore entry have been removed. Keep it until
        # authenticated completion proof, then clear it before journaling
        # Complete so a failed local save remains recoverable.
        def finalize_migration! : Nil
          verify_postcondition!(Stage::Complete)
          state = @store.load
          nodes = state.nodes_for(@old_fabric.fabric_id,
            @old_fabric.root_public_key, @old_fabric.controller_node_id)
          @store.save(state) if nodes.delete(@old_node_id)
        end

        # These are read-only postconditions for explicit journal
        # reconciliation after a timeout. They do not retry a command.
        def anchor_present? : Bool
          session = case_session(@anchor_fabric, @anchor_node_id, @device_peer)
          fabrics(session, @device_peer).any? do |entry|
            entry.fabric_id == @anchor_fabric.fabric_id &&
              entry.root_public_key == @anchor_fabric.root_public_key &&
              entry.node_id == @anchor_node_id
          end
        end

        def old_fabric_absent? : Bool
          session = case_session(@anchor_fabric, @anchor_node_id, @device_peer)
          !fabrics(session, @device_peer).any? do |entry|
            entry.fabric_id == @old_fabric.fabric_id &&
              entry.root_public_key == @old_fabric.root_public_key
          end
        end

        def verify_postcondition!(stage : Stage) : Nil
          case stage
          when Stage::AnchorCommissioned
            wait_for_fail_safe_expiry! unless @journal.try(&.commissioning_acknowledged?)
            state = @store.load
            unless state.nodes_for(@anchor_fabric.fabric_id,
                     @anchor_fabric.root_public_key,
                     @anchor_fabric.controller_node_id).has_key?(@anchor_node_id)
              verify_handoff_baseline!
              verify_anchor!
              @store.update do |current|
                current.record_node(@anchor_fabric.fabric_id,
                  NodeInfo.new(node_id: @anchor_node_id,
                    address: OperationalPeerResolver.address_hint(@device_peer),
                    port: @device_peer.port), @anchor_fabric.root_public_key,
                  @anchor_fabric.controller_node_id)
              end
              datastore_registrar.resume(@anchor_fabric)
              return
            end
            verify_anchor!
            datastore_registrar.resume(@anchor_fabric)
          when Stage::AnchorVerified
            verify_anchor!
          when Stage::AnchorNodeAdded
            session = case_session(@anchor_fabric, @anchor_datastore_node_id, @anchor_datastore_peer)
            entry = datastore_nodes(ImClient.new(@client, @timeout), session,
              @anchor_datastore_peer, @anchor_datastore_endpoint).find(&.node_id.==(@anchor_node_id))
            unless entry && entry.commissioning_status_entry.state.committed?
              raise Matter::CommissioningError.new("Anchor Datastore has not committed the migrated node")
            end
          when Stage::OldFabricRemoved
            raise Matter::CommissioningError.new("Fabric B remains installed") unless old_fabric_absent?
            verify_postcondition!(Stage::AnchorNodeAdded)
          when Stage::Complete
            verify_postcondition!(Stage::OldFabricRemoved)
            session = case_session(@old_fabric, @old_datastore_node_id, @old_datastore_peer)
            if datastore_nodes(ImClient.new(@client, @timeout), session,
                 @old_datastore_peer, @old_datastore_endpoint).any?(&.node_id.==(@old_node_id))
              raise Matter::CommissioningError.new("Fabric B Datastore still contains the migrated node")
            end
          when Stage::RolledBack
            require_old_fabric_present!
            session = case_session(@old_fabric, @old_node_id, @device_peer)
            if fabrics(session, @device_peer).any? do |entry|
                 entry.fabric_id == @anchor_fabric.fabric_id &&
                 entry.root_public_key == @anchor_fabric.root_public_key
               end
              raise Matter::CommissioningError.new("Anchor fabric remains installed after rollback")
            end
            anchor_session = case_session(@anchor_fabric, @anchor_datastore_node_id, @anchor_datastore_peer)
            if datastore_nodes(ImClient.new(@client, @timeout), anchor_session,
                 @anchor_datastore_peer, @anchor_datastore_endpoint).any?(&.node_id.==(@anchor_node_id))
              raise Matter::CommissioningError.new("Anchor Datastore still contains the rolled-back node")
            end
          else
            raise Matter::ConfigurationError.new("Stage has no observable migration postcondition")
          end
        end

        # A failed command response does not establish whether the peer
        # committed it. A retry is permitted only when authenticated reads
        # establish the exact pre-command state on both sides of the handoff.
        def verify_no_effect!(stage : Stage) : Nil
          case stage
          when Stage::CommissioningAnchor
            if @journal.try(&.commissioning_acknowledged?)
              raise Matter::CommissioningError.new("Durable CommissioningComplete acknowledgement exists")
            end
            wait_for_fail_safe_expiry!
            state = @store.load
            if state.nodes_for(@anchor_fabric.fabric_id,
                 @anchor_fabric.root_public_key,
                 @anchor_fabric.controller_node_id).has_key?(@anchor_node_id)
              raise Matter::CommissioningError.new("Controller already stores the Anchor device identity")
            end
            require_old_fabric_present!
            if anchor_fabric_present_over_old_case?
              raise Matter::CommissioningError.new("Anchor fabric is present on the device")
            end
            if anchor_entry = anchor_node_entry
              unless anchor_entry.friendly_name == @friendly_name && owned_pending_registration?
                raise Matter::CommissioningError.new("Anchor Datastore contains an unrelated migrated node")
              end
            end
          when Stage::VerifyingAnchor
            verify_postcondition!(Stage::AnchorCommissioned)
          when Stage::AddingAnchorNode
            verify_anchor!
            require_old_fabric_present!
            anchor_entry = anchor_node_entry ||
                           raise Matter::CommissioningError.new("Staged Anchor Datastore node is missing")
            unless anchor_entry.friendly_name == @friendly_name &&
                   anchor_entry.commissioning_status_entry.state.pending?
              raise Matter::CommissioningError.new("Anchor Datastore registration already changed")
            end
          when Stage::RemovingOldFabric
            verify_postcondition!(Stage::AnchorNodeAdded)
            require_old_fabric_present!
          when Stage::RemovingOldNode
            verify_postcondition!(Stage::OldFabricRemoved)
            unless old_node_entry
              raise Matter::CommissioningError.new("Fabric B Datastore no longer contains the migrated node")
            end
          else
            raise Matter::ConfigurationError.new("Stage has no observable no-effect migration condition")
          end
        end

        # A stored UTC deadline is diagnostic only: the local clock may have
        # jumped while this process was stopped. A fresh monotonic interval
        # covers the device's whole reported cumulative fail-safe bound before
        # an unacknowledged commissioning result can be classified.
        private def wait_for_fail_safe_expiry! : Nil
          max_seconds = @journal.try(&.fail_safe_max_seconds)
          unless max_seconds && max_seconds > 0
            raise Matter::CommissioningError.new("Controller has no durable CommissioningComplete acknowledgement or fail-safe recovery bound for Fabric A")
          end
          interval = (max_seconds.to_i64 + Commissioning::Commissioner::FAIL_SAFE_RECOVERY_GRACE_SECONDS).seconds
          start = @monotonic_now.call
          while (remaining = interval - (@monotonic_now.call - start)) > Time::Span.zero
            @recovery_sleep.call(remaining)
          end
        end

        private def anchor_fabric_present_over_old_case? : Bool
          session = case_session(@old_fabric, @old_node_id, @device_peer)
          fabrics(session, @device_peer).any? do |entry|
            entry.fabric_id == @anchor_fabric.fabric_id &&
              entry.root_public_key == @anchor_fabric.root_public_key
          end
        end

        private def require_old_fabric_present! : Nil
          session = case_session(@old_fabric, @old_node_id, @device_peer)
          unless fabrics(session, @device_peer).any? do |entry|
                   entry.fabric_id == @old_fabric.fabric_id &&
                   entry.root_public_key == @old_fabric.root_public_key &&
                   entry.node_id == @old_node_id
                 end
            raise Matter::CommissioningError.new("Fabric B device identity is no longer present")
          end
        end

        private def verify_handoff_baseline! : Nil
          require_old_fabric_present!
          entry = old_node_entry
          unless entry && entry.commissioning_status_entry.state.committed?
            raise Matter::CommissioningError.new("Fabric B Datastore no longer owns the committed device node")
          end
          if anchor_entry = anchor_node_entry
            unless anchor_entry.friendly_name == @friendly_name && owned_pending_registration?
              raise Matter::CommissioningError.new("Anchor Datastore contains an unrelated device registration")
            end
          end
        end

        private def owned_pending_registration? : Bool
          @store.load.pending_datastore_nodes.any? do |item|
            item.fabric_id == @anchor_fabric.fabric_id &&
              item.root_public_key == @anchor_fabric.root_public_key &&
              item.controller_node_id == @anchor_fabric.controller_node_id &&
              item.node_id == @anchor_node_id &&
              item.friendly_name == @friendly_name &&
              item.peer_address == OperationalPeerResolver.address_hint(@device_peer) &&
              item.peer_port == @device_peer.port
          end
        end

        private def anchor_node_entry : Cluster::JointFabricDatastore::DatastoreNodeInformationEntryStruct?
          session = case_session(@anchor_fabric, @anchor_datastore_node_id, @anchor_datastore_peer)
          datastore_nodes(ImClient.new(@client, @timeout), session,
            @anchor_datastore_peer, @anchor_datastore_endpoint).find(&.node_id.==(@anchor_node_id))
        end

        private def old_node_entry : Cluster::JointFabricDatastore::DatastoreNodeInformationEntryStruct?
          session = case_session(@old_fabric, @old_datastore_node_id, @old_datastore_peer)
          datastore_nodes(ImClient.new(@client, @timeout), session,
            @old_datastore_peer, @old_datastore_endpoint).find(&.node_id.==(@old_node_id))
        end

        private def case_session(fabric : FabricInfo, node_id : UInt64,
                                 peer : Socket::IPAddress) : Session::SecureContext
          session = Pairing::CasePairing.new(@crypto).pair(@client, peer, fabric,
            peer_node_id: node_id, timeout: @timeout)
          session
        end

        private def fabrics(session : Session::SecureContext,
                            peer : Socket::IPAddress) : Array(Cluster::OperationalCredentials::Tlv::FabricDescriptor)
          report = ImClient.new(@client, @timeout).read_attribute(session, peer, Node::ROOT_ENDPOINT_ID,
            Cluster::OperationalCredentials::CLUSTER_ID,
            Cluster::OperationalCredentials::ATTR_FABRICS, fabric_filtered: false)
          data = report.attribute_reports.try(&.find(&.attribute_data)).try(&.attribute_data).try(&.data) ||
                 raise Matter::ProtocolError.new("OperationalCredentials Fabrics read omitted data")
          Array(Cluster::OperationalCredentials::Tlv::FabricDescriptor).from_tlv(data.to_slice)
        end

        private def datastore_nodes(im : ImClient, session : Session::SecureContext,
                                    peer : Socket::IPAddress, endpoint : UInt16) : Array(Cluster::JointFabricDatastore::DatastoreNodeInformationEntryStruct)
          data = datastore_attribute(im, session, peer, endpoint,
            Cluster::JointFabricDatastore::ATTR_NODE_LIST)
          Array(Cluster::JointFabricDatastore::DatastoreNodeInformationEntryStruct).from_tlv(data.to_slice)
        end

        private def datastore_attribute(im : ImClient, session : Session::SecureContext,
                                        peer : Socket::IPAddress, endpoint : UInt16,
                                        attribute : UInt32) : TLV::Any
          report = im.read_attribute(session, peer, endpoint,
            Cluster::JointFabricDatastore::CLUSTER_ID, attribute)
          data = report.attribute_reports.try(&.find(&.attribute_data)).try(&.attribute_data).try(&.data) ||
                 raise Matter::ProtocolError.new("Datastore attribute #{attribute} read omitted data")
          data
        end

        private def assert_status_success!(response : InteractionModel::InvokeResponseMessage,
                                           name : String) : Nil
          ImClient.single_invoke_response!(response, name)
          status = response.invoke_responses.first?.try(&.command_status).try(&.status) ||
                   raise Matter::ProtocolError.new("#{name} omitted command status")
          unless status.status == InteractionModel::StatusCode::Success.value
            raise Matter::CommissioningError.new("#{name} failed with IM status #{status.status}")
          end
        end

        private def assert_noc_success!(response : InteractionModel::InvokeResponseMessage,
                                        name : String) : Nil
          entry = ImClient.single_invoke_response!(response, name)
          fields = entry.command_data.try do |command|
            command.command_fields if command.command_path.command == Cluster::OperationalCredentials::CMD_ADD_NOC_RESPONSE
          end ||
                   raise Matter::ProtocolError.new("#{name} omitted NOCResponse")
          result = Cluster::OperationalCredentials::Tlv::TlvNocResponse.from_slice(fields.to_slice)
          unless result.status_code.ok?
            raise Matter::CommissioningError.new("#{name} failed: #{result.status_code}")
          end
        end
      end

      def self.validate_anchor_ipk!(sets : Array(Cluster::JointFabricDatastore::DatastoreGroupKeySetStruct),
                                    expected_ipk : Bytes) : Nil
        ipks = sets.select(&.group_key_set_id.==(Cluster::JointFabricDatastore::IPK_KEY_SET_ID))
        unless expected_ipk.size == Fabric::IPK_SIZE && ipks.size == 1 &&
               ipks.first.epoch_key0 == expected_ipk
          raise Matter::AuthenticationError.new("Anchor Datastore IPK is absent or differs from selected fabric")
        end
      end

      # Operational CASE and NOC issuance have distinct ICAC chains. The B
      # Administrator presents its A-issued operational ICAC for CASE while
      # this local issuer signs migrated device NOCs with B's cross-signed
      # ICAC. Neither chain may be substituted for the other.
      struct CrossSignedIssuer
        getter icac : Bytes
        getter fabric_id : UInt64
        getter root_public_key : Bytes
        getter old_icac_public_key : Bytes
        getter admin_vendor_id : UInt16

        def initialize(@icac : Bytes, @private_key : Bytes,
                       @fabric_id : UInt64, @root_public_key : Bytes,
                       @old_icac_public_key : Bytes,
                       @admin_vendor_id : UInt16 = FabricInfo::DEFAULT_ADMIN_VENDOR_ID)
        end

        def validate_fabrics!(old_fabric : FabricInfo, anchor : FabricInfo) : Nil
          old_icac = old_fabric.intermediate_cert ||
                     raise Matter::ConfigurationError.new("Fabric B has no original ICAC")
          unless @fabric_id == anchor.fabric_id && @root_public_key == anchor.root_public_key &&
                 @old_icac_public_key == Crypto::MatterCertificate.public_key_from_tlv(old_icac)
            raise Matter::AuthenticationError.new("Cross-signed issuer does not match B and Anchor fabric identities")
          end
        end

        def issue_noc(anchor : FabricInfo, node_id : UInt64, public_key : Bytes,
                      crypto : Crypto::CryptoBase,
                      case_authenticated_tags : Array(UInt32) = [] of UInt32) : Bytes
          unless @fabric_id == anchor.fabric_id && @root_public_key == anchor.root_public_key
            raise Matter::AuthenticationError.new("Cross-signed issuer selected another Anchor fabric")
          end
          icac_id = Crypto::MatterCertificate.from_slice(@icac).subject.icac_id ||
                    raise Matter::CertificateError.new("Cross-signed ICAC has no identifier")
          rcac_id = Crypto::MatterCertificate.from_slice(anchor.root_cert).subject.rcac_id ||
                    raise Matter::CertificateError.new("Anchor RCAC has no identifier")
          key = Crypto::Key.new(Crypto::KeyType::EC, Crypto::CurveType::P256)
          key.private_bits = @private_key
          Crypto::MatterCertificate::Builder.node(
            public_key: public_key, fabric_id: anchor.fabric_id, node_id: node_id,
            issuer_key: key, issuer_rcac_id: rcac_id, issuer_icac_id: icac_id,
            issuer_certificate: @icac, serial: crypto.random_bytes(CERTIFICATE_SERIAL_BYTES),
            crypto: crypto, case_authenticated_tags: case_authenticated_tags)
        end

        # B can issue a controller identity on A's fabric using the same
        # cross-signed ICAC it uses for migrated devices. Only the operational
        # private key is returned; B keeps its ICAC signing key with the issuer.
        def delegate_controller(anchor : FabricInfo, node_id : UInt64,
                                group_cat : UInt16, group_cat_version : UInt16,
                                crypto : Crypto::CryptoBase = Crypto::StandardCrypto.new) : FabricInfo
          unless DataType::NodeId.valid_joint_fabric?(node_id) && node_id != anchor.controller_node_id
            raise Matter::ConfigurationError.new("Delegated Joint Fabric controller needs a distinct operational Node ID")
          end
          if group_cat == Cluster::JointFabricDatastore::UNSPECIFIED_GROUP_CAT || group_cat.in?(Cluster::JointFabricDatastore::ANCHOR_CAT,
               Cluster::JointFabricDatastore::ADMINISTRATOR_CAT) ||
             group_cat_version.in?(Cluster::JointFabricDatastore::UNSPECIFIED_GROUP_CAT_VERSION,
               Cluster::JointFabricDatastore::RESERVED_GROUP_CAT_VERSION)
            raise Matter::ConfigurationError.new("Invalid Joint Fabric group CAT or version")
          end
          unless @fabric_id == anchor.fabric_id && @root_public_key == anchor.root_public_key
            raise Matter::AuthenticationError.new("Cross-signed issuer selected another Anchor fabric")
          end
          tag = DataType::CaseAuthenticatedTag.create(group_cat, group_cat_version)
          controller_key = crypto.create_key_pair
          noc = issue_noc(anchor, node_id, controller_key.public_key, crypto, [tag.value])
          Crypto::MatterCertificate::Validation.verify_chain(noc, @icac,
            anchor.root_public_key, anchor.root_cert)
          FabricInfo.new(anchor.fabric_id, node_id, anchor.ipk_value.dup,
            anchor.root_cert.dup, anchor.root_public_key.dup, noc, controller_key.private_key,
            admin_vendor_id: @admin_vendor_id, intermediate_cert: @icac.dup,
            ipk_epoch_keys: anchor.ipk_epoch_keys)
        end
      end

      def self.cross_signed_issuer(old_fabric : FabricInfo, anchor : FabricInfo,
                                   cross_signed_icac : Bytes,
                                   icac_private_key : Bytes) : CrossSignedIssuer
        old_icac = old_fabric.intermediate_cert ||
                   raise Matter::ConfigurationError.new("Fabric B has no original ICAC")
        old_public = Crypto::MatterCertificate.public_key_from_tlv(old_icac)
        icac = Crypto::MatterCertificate.from_slice(cross_signed_icac)
        icac_id = icac.subject.icac_id ||
                  raise Matter::CertificateError.new("Cross-signed certificate has no ICAC ID")
        key = Crypto::Key.new(Crypto::KeyType::EC, Crypto::CurveType::P256)
        key.private_bits = icac_private_key
        unless key.public_key == old_public && key.public_key == icac.ec_public_key
          raise Matter::CertificateError.new("B ICAC private key does not match original and cross-signed ICACs")
        end
        JointCommissioning.validate_cross_signed_icac(cross_signed_icac, anchor,
          old_public, icac_id)
        Crypto::MatterCertificate::Validation.verify_chain(anchor.controller_noc,
          anchor.intermediate_cert, anchor.root_public_key, anchor.root_cert)
        controller = Crypto::MatterCertificate.from_slice(anchor.controller_noc)
        unless controller.fabric_id == anchor.fabric_id && controller.node_id == anchor.controller_node_id
          raise Matter::CertificateError.new("Administrator NOC does not identify the Anchor fabric controller")
        end
        controller_key = Crypto::Key.new(Crypto::KeyType::EC, Crypto::CurveType::P256)
        controller_key.private_bits = anchor.controller_private_key
        unless controller_key.public_key == controller.ec_public_key
          raise Matter::CertificateError.new("Administrator private key does not match its NOC")
        end
        subjects = Crypto::MatterCertificate.subject_ids_from_tlv(anchor.controller_noc)
        unless subjects.any? do |subject|
                 cat = DataType::NodeId.case_authenticated_tag_from_subject?(subject)
                 cat && cat.identity_value == Cluster::JointFabricDatastore::ADMINISTRATOR_CAT
               end
          raise Matter::CertificateError.new("Administrator NOC lacks the Administrator CAT")
        end
        if subjects.any? do |subject|
             cat = DataType::NodeId.case_authenticated_tag_from_subject?(subject)
             cat && cat.identity_value == Cluster::JointFabricDatastore::ANCHOR_CAT
           end
          raise Matter::CertificateError.new("Migration requires the joining Administrator identity, not the Anchor identity")
        end
        CrossSignedIssuer.new(cross_signed_icac.dup, icac_private_key.dup,
          anchor.fabric_id, anchor.root_public_key.dup, old_public.dup,
          old_fabric.admin_vendor_id)
      end

      # Commissioner's hook ensures the AddNOC ACL grants the Administrator
      # CAT version published by Fabric B's authenticated GroupList.
      class Credentials < Commissioning::Commissioner::Hooks
        def initialize(@issuer : CrossSignedIssuer,
                       @administrator_cat : UInt32, @admin_vendor_id : UInt16,
                       @crypto : Crypto::CryptoBase = Crypto::StandardCrypto.new,
                       @commissioning_ack : Proc(Nil)? = nil,
                       @fail_safe_deadline : Proc(Int64, UInt16, Nil)? = nil)
          unless @administrator_cat >> 16 == ADMINISTRATOR_CAT_ID &&
                 (@administrator_cat & DataType::CaseAuthenticatedTag::VERSION_MASK) != 0_u32
            raise Matter::ConfigurationError.new("A current Administrator CAT is required")
          end
        end

        def prepare_credentials(fabric : FabricInfo, node_id : UInt64,
                                csr_public_key : Bytes, im : ImClient,
                                pase_session : Session::SecureContext,
                                peer : Socket::IPAddress) : Commissioning::Commissioner::OperationalCredentials
          issue(fabric, node_id, csr_public_key)
        end

        def issue(fabric : FabricInfo, node_id : UInt64,
                  csr_public_key : Bytes) : Commissioning::Commissioner::OperationalCredentials
          noc = @issuer.issue_noc(fabric, node_id, csr_public_key, @crypto)
          Commissioning::Commissioner::OperationalCredentials.new(noc, @issuer.icac,
            fabric.ipk_value, DataType::NodeId.from_case_authenticated_tag(
            DataType::CaseAuthenticatedTag.new(@administrator_cat)).id,
            @admin_vendor_id)
        end

        def before_complete(fabric : FabricInfo, node_id : UInt64, im : ImClient,
                            case_session : Session::SecureContext,
                            peer : Socket::IPAddress) : Nil
        end

        def complete_acknowledged(fabric : FabricInfo, node_id : UInt64,
                                  peer : Socket::IPAddress) : Nil
          @commissioning_ack.try(&.call)
        end

        def record_fail_safe_deadline? : Bool
          !@fail_safe_deadline.nil?
        end

        def fail_safe_deadline_observed(deadline_unix : Int64, max_seconds : UInt16) : Nil
          @fail_safe_deadline.try(&.call(deadline_unix, max_seconds))
        end
      end

      class Workflow
        alias SaveJournal = Proc(Journal, Nil)
        alias Consent = Proc(Bool)

        getter journal : Journal

        def initialize(@journal : Journal, @port : Port, @consent : Consent,
                       @save : SaveJournal)
          if @journal.old_fabric_id == Fabric::RESERVED_FABRIC_ID || @journal.anchor_fabric_id == Fabric::RESERVED_FABRIC_ID ||
             @journal.old_node_id == DataType::NodeId::UNSPECIFIED || @journal.anchor_node_id == DataType::NodeId::UNSPECIFIED ||
             @journal.old_root_public_key.empty? || @journal.anchor_root_public_key.empty? ||
             (@journal.old_fabric_id == @journal.anchor_fabric_id &&
             @journal.old_root_public_key == @journal.anchor_root_public_key)
            raise Matter::ConfigurationError.new("Migration needs distinct complete fabric identities")
          end
          @port.validate_journal!(@journal)
        end

        def run : Nil
          return if @journal.stage.complete? || @journal.stage.rolled_back?
          if @journal.stage.commissioning_anchor?
            # Recovery after a lost CommissioningComplete response only reads
            # authenticated state. The port enforces the durable acknowledgement
            # or elapsed fail-safe deadline before this can advance.
            @port.verify_postcondition!(Stage::AnchorCommissioned)
            advance(Stage::AnchorCommissioned)
          end
          if @journal.stage.in?(Stage::VerifyingAnchor,
               Stage::AddingAnchorNode, Stage::RemovingOldFabric, Stage::RemovingOldNode,
               Stage::RollingBack)
            raise Matter::CommissioningError.new("Migration stage #{@journal.stage} needs authenticated reconciliation")
          end
          if @journal.stage.ready?
            raise Matter::CommissioningError.new("Device migration requires user consent") unless @consent.call
            advance(Stage::CommissioningAnchor)
            @port.commission_anchor!
            advance(Stage::AnchorCommissioned)
          end
          if @journal.stage.anchor_commissioned?
            advance(Stage::VerifyingAnchor)
            @port.verify_anchor!
            advance(Stage::AnchorVerified)
          end
          if @journal.stage.anchor_verified?
            advance(Stage::AddingAnchorNode)
            @port.add_anchor_node!
            advance(Stage::AnchorNodeAdded)
          end
          if @journal.stage.anchor_node_added?
            advance(Stage::RemovingOldFabric)
            @port.remove_old_fabric!
            advance(Stage::OldFabricRemoved)
          end
          if @journal.stage.old_fabric_removed?
            advance(Stage::RemovingOldNode)
            @port.remove_old_node!
            advance(Stage::Complete)
          end
        end

        # Rollback is allowed only while Fabric B is still present. A failure
        # at either removal command leaves RollingBack for read-only
        # reconciliation, never an automatic second RemoveFabric.
        def rollback! : Nil
          unless @journal.stage.in?(Stage::AnchorCommissioned,
                   Stage::AnchorVerified, Stage::AnchorNodeAdded)
            raise Matter::CommissioningError.new("Cannot roll back after Fabric B removal began or while a step is uncertain")
          end
          registered = @journal.stage.anchor_node_added?
          advance(Stage::RollingBack)
          @port.rollback_anchor!(registered)
          advance(Stage::RolledBack)
        end

        def resume_anchor_registration! : Nil
          unless @journal.stage.adding_anchor_node?
            raise Matter::ConfigurationError.new("Anchor registration is not awaiting recovery")
          end
          @port.refresh_anchor_registration!
          @port.verify_postcondition!(Stage::AnchorNodeAdded)
          advance(Stage::AnchorNodeAdded)
        end

        def resume_rollback! : Nil
          unless @journal.stage.rolling_back?
            raise Matter::ConfigurationError.new("Migration rollback is not awaiting recovery")
          end
          @port.resume_rollback!
          advance(Stage::RolledBack)
        end

        # An uncertain operation is never replayed by run. The caller must
        # inspect the device or Datastore over authenticated CASE and then
        # explicitly record the observed postcondition before resuming.
        def reconcile!(completed : Stage) : Nil
          # Journals written before controller node cleanup can already be
          # terminal while their local node record is stale. An explicit
          # reconciliation proves the remote terminal state before cleanup;
          # it does not replay either removal command or rewrite the journal.
          if @journal.stage.in?(Stage::Complete, Stage::RolledBack)
            unless completed == @journal.stage
              raise Matter::ConfigurationError.new("Invalid migration reconciliation stage")
            end
            @port.verify_postcondition!(completed)
            @port.finalize_migration! if completed.complete?
            @port.finalize_rollback! if completed.rolled_back?
            return
          end
          expected = case @journal.stage
                     when Stage::CommissioningAnchor then Stage::AnchorCommissioned
                     when Stage::VerifyingAnchor     then Stage::AnchorVerified
                     when Stage::AddingAnchorNode    then Stage::AnchorNodeAdded
                     when Stage::RemovingOldFabric   then Stage::OldFabricRemoved
                     when Stage::RemovingOldNode     then Stage::Complete
                     when Stage::RollingBack         then Stage::RolledBack
                     else
                       raise Matter::ConfigurationError.new("Migration is not awaiting reconciliation")
                     end
          unless completed == expected
            raise Matter::ConfigurationError.new("Invalid migration reconciliation stage")
          end
          @port.verify_postcondition!(completed)
          advance(completed)
        end

        # Record an authenticated observation that an interrupted operation
        # did not take effect. The next run may then issue that command once.
        def reconcile_no_effect! : Nil
          previous = case @journal.stage
                     when Stage::CommissioningAnchor then Stage::Ready
                     when Stage::VerifyingAnchor     then Stage::AnchorCommissioned
                     when Stage::AddingAnchorNode    then Stage::AnchorVerified
                     when Stage::RemovingOldFabric   then Stage::AnchorNodeAdded
                     when Stage::RemovingOldNode     then Stage::OldFabricRemoved
                     else
                       raise Matter::ConfigurationError.new("Migration is not awaiting a command outcome")
                     end
          @port.verify_no_effect!(@journal.stage)
          @port.cleanup_failed_anchor_registration! if @journal.stage.commissioning_anchor?
          advance(previous)
        end

        private def advance(stage : Stage) : Nil
          @port.finalize_migration! if stage.complete?
          @port.finalize_rollback! if stage.rolled_back?
          updated = @journal
          updated.stage = stage
          @save.call(updated)
          @journal = updated
        end
      end
    end
  end
end
