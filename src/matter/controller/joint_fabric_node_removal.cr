require "../cluster/joint_fabric_datastore"
require "./im_client"
require "./pairing/case_pairing"
require "./shared_fabric"
require "./state_store"

module Matter
  module Controller
    # Removes a committed ordinary node from a Joint Fabric. The Datastore
    # deletes its NodeList entry only after every direct grant held by this
    # Node ID has been removed from other nodes. A controller with a group CAT
    # must first be revoked through SharedFabric's CAT rotation workflow.
    module JointFabricNodeRemoval
      alias Datastore = Cluster::JointFabricDatastore

      enum Stage
        Revoking
        Removing
        Complete
      end

      struct GroupCleanup
        include Storage::Record

        getter node_id : UInt64
        getter endpoint_id : UInt16
        getter group_id : UInt16

        def initialize(@node_id : UInt64, @endpoint_id : UInt16, @group_id : UInt16)
        end
      end

      struct BindingCleanup
        include Storage::Record

        getter node_id : UInt64
        getter endpoint_id : UInt16
        getter list_id : UInt16
        getter binding : Datastore::DatastoreBindingTargetStruct
        getter owner_noc : Bytes

        def initialize(@node_id : UInt64, @endpoint_id : UInt16, @list_id : UInt16,
                       @binding : Datastore::DatastoreBindingTargetStruct, @owner_noc : Bytes)
        end
      end

      struct CleanupSnapshot
        getter groups : Array(GroupCleanup)
        getter bindings : Array(BindingCleanup)
        getter key_set_ids : Array(UInt16)

        def initialize(@groups : Array(GroupCleanup), @bindings : Array(BindingCleanup),
                       @key_set_ids : Array(UInt16))
        end
      end

      struct Journal
        include Storage::Record

        getter fabric_id : UInt64
        getter root_public_key : Bytes
        getter controller_node_id : UInt64
        getter anchor_node_id : UInt64
        getter node_id : UInt64
        getter friendly_name : String
        getter target_noc : Bytes
        getter group_revocations : Array(SharedFabric::JointGroupRevocation)
        property? cleanup_recorded : Bool = false
        property cleanup_groups : Array(GroupCleanup) = [] of GroupCleanup
        property cleanup_bindings : Array(BindingCleanup) = [] of BindingCleanup
        property cleanup_key_set_ids : Array(UInt16) = [] of UInt16
        property stage : Stage
        property stage_version : UInt64

        def initialize(@fabric_id, @root_public_key, @controller_node_id,
                       @anchor_node_id, @node_id, @friendly_name, @target_noc,
                       @group_revocations = [] of SharedFabric::JointGroupRevocation,
                       @stage = Stage::Revoking, @stage_version = 0_u64,
                       @cleanup_recorded = false,
                       @cleanup_groups = [] of GroupCleanup,
                       @cleanup_bindings = [] of BindingCleanup,
                       @cleanup_key_set_ids = [] of UInt16)
        end
      end

      class JournalStore
        COLLECTION = "joint_fabric_node_removal"

        def initialize(@backend : Storage::Backend)
        end

        # Load before contacting the target on restart: it may already have
        # been removed and therefore be unavailable for a fresh NOC read.
        def load(fabric_id : UInt64, root_public_key : Bytes,
                 controller_node_id : UInt64, node_id : UInt64) : Journal?
          @backend.open unless @backend.open?
          id = document_id(fabric_id, root_public_key, controller_node_id, node_id)
          document = @backend.read(COLLECTION, id)
          document.try { |value| Journal.from_document(value) }
        end

        def load_or_create(journal : Journal) : Journal
          if journal.node_id == DataType::NodeId::UNSPECIFIED || journal.friendly_name.empty? || journal.target_noc.empty?
            raise Matter::ConfigurationError.new("Joint Fabric node removal needs a Node ID, name, and authenticated NOC")
          end
          @backend.open unless @backend.open?
          id = document_id(journal)
          result = nil.as(Journal?)
          @backend.transaction do
            if document = @backend.read(COLLECTION, id)
              current = Journal.from_document(document)
              unless same_identity?(current, journal)
                raise Matter::StorageError.new("Joint Fabric node removal identity changed")
              end
              result = current
            else
              unless @backend.compare_and_swap(COLLECTION, id, nil, journal.to_document)
                raise Matter::StorageError.new("Joint Fabric node removal was created concurrently")
              end
              result = journal
            end
          end
          result || raise Matter::StorageError.new("Joint Fabric node removal journal was not returned")
        end

        def save(journal : Journal) : Nil
          @backend.open unless @backend.open?
          @backend.transaction do
            id = document_id(journal)
            document = @backend.read(COLLECTION, id) ||
                       raise Matter::StorageError.new("Joint Fabric node removal journal is missing")
            previous = Journal.from_document(document)
            unless same_identity?(previous, journal) && journal.stage_version == previous.stage_version + 1_u64
              raise Matter::StorageError.new("Joint Fabric node removal journal changed since load")
            end
            unless @backend.compare_and_swap(COLLECTION, id, document, journal.to_document)
              raise Matter::StorageError.new("Joint Fabric node removal journal changed concurrently")
            end
          end
        end

        private def document_id(journal : Journal) : String
          document_id(journal.fabric_id, journal.root_public_key,
            journal.controller_node_id, journal.node_id)
        end

        private def document_id(fabric_id : UInt64, root_public_key : Bytes,
                                controller_node_id : UInt64, node_id : UInt64) : String
          "#{fabric_id.to_s(16)}-#{root_public_key.hexstring}-#{controller_node_id.to_s(16)}-#{node_id.to_s(16)}"
        end

        private def same_identity?(left : Journal, right : Journal) : Bool
          left.fabric_id == right.fabric_id && left.root_public_key == right.root_public_key &&
            left.controller_node_id == right.controller_node_id && left.anchor_node_id == right.anchor_node_id &&
            left.node_id == right.node_id && left.friendly_name == right.friendly_name &&
            left.target_noc == right.target_noc && left.group_revocations == right.group_revocations
        end
      end

      abstract class Port
        abstract def snapshot_cleanup(journal : Journal) : CleanupSnapshot
        abstract def cleanup!(journal : Journal) : Nil
        abstract def cleanup_complete?(journal : Journal) : Bool
        abstract def revoke_direct_access!(journal : Journal) : Nil
        abstract def access_revoked?(journal : Journal) : Bool
        abstract def remove_node!(journal : Journal) : Nil
        abstract def node_absent?(journal : Journal) : Bool
      end

      # Group CAT controllers require a completed CAT rotation receipt.
      class NetworkPort < Port
        def self.cleanup_binding?(entry : Datastore::DatastoreEndpointBindingEntryStruct,
                                  node_id : UInt64) : Bool
          entry.node_id == node_id || entry.binding.node == node_id
        end

        def self.cleanup_key_set?(entry : Datastore::DatastoreNodeKeySetEntryStruct,
                                  node_id : UInt64) : Bool
          entry.node_id == node_id && entry.group_key_set_id != Datastore::IPK_KEY_SET_ID
        end

        def initialize(@store : StateStore, @fabric : FabricInfo,
                       @anchor_node_id : UInt64, @anchor_peer : Socket::IPAddress,
                       @datastore_endpoint : UInt16,
                       @client : Client = Client.new,
                       @timeout : Time::Span = 15.seconds,
                       @crypto : Crypto::CryptoBase = Crypto::StandardCrypto.new)
        end

        def close : Nil
          @client.close
        end

        # Start only after authenticating the target over CASE. The saved NOC
        # prevents a later Node ID reuse from inheriting this removal journal.
        def initial_journal(node_id : UInt64, friendly_name : String,
                            group_revocations : Array(SharedFabric::JointGroupRevocation) = [] of SharedFabric::JointGroupRevocation) : Journal
          provisional = Journal.new(@fabric.fabric_id, @fabric.root_public_key.dup,
            @fabric.controller_node_id, @anchor_node_id, node_id, friendly_name, Bytes.empty,
            group_revocations)
          Journal.new(@fabric.fabric_id, @fabric.root_public_key.dup,
            @fabric.controller_node_id, @anchor_node_id, node_id, friendly_name,
            target_noc(provisional), group_revocations)
        end

        def snapshot_cleanup(journal : Journal) : CleanupSnapshot
          groups = [] of GroupCleanup
          bindings = [] of BindingCleanup
          key_set_ids = [] of UInt16
          with_anchor(journal) do |im, session|
            validate_removable!(im, session, journal, allow_cleanup: true)
            groups = read_list(Datastore::DatastoreEndpointGroupIDEntryStruct,
              im, session, Datastore::ATTR_ENDPOINT_GROUP_ID_LIST)
              .select(&.node_id.==(journal.node_id))
              .map { |entry| GroupCleanup.new(entry.node_id, entry.endpoint_id, entry.group_id) }
            entries = read_list(Datastore::DatastoreEndpointBindingEntryStruct,
              im, session, Datastore::ATTR_ENDPOINT_BINDING_LIST)
              .select { |entry| self.class.cleanup_binding?(entry, journal.node_id) }
            entries.each do |entry|
              owner_noc = entry.node_id == journal.node_id ? journal.target_noc : peer_noc(journal, entry.node_id)
              bindings << BindingCleanup.new(entry.node_id, entry.endpoint_id, entry.list_id,
                entry.binding, owner_noc)
            end
            key_set_ids = read_list(Datastore::DatastoreNodeKeySetEntryStruct,
              im, session, Datastore::ATTR_NODE_KEY_SET_LIST)
              .select { |entry| self.class.cleanup_key_set?(entry, journal.node_id) }
              .map(&.group_key_set_id)
          end
          CleanupSnapshot.new(groups, bindings, key_set_ids)
        end

        def cleanup!(journal : Journal) : Nil
          raise Matter::CommissioningError.new("Joint Fabric node cleanup snapshot is missing") unless journal.cleanup_recorded?
          with_anchor(journal) do |im, session|
            validate_removable!(im, session, journal, allow_cleanup: true)
            current_groups = read_list(Datastore::DatastoreEndpointGroupIDEntryStruct,
              im, session, Datastore::ATTR_ENDPOINT_GROUP_ID_LIST)
            current_bindings = read_list(Datastore::DatastoreEndpointBindingEntryStruct,
              im, session, Datastore::ATTR_ENDPOINT_BINDING_LIST)
            key_sets = read_list(Datastore::DatastoreNodeKeySetEntryStruct,
              im, session, Datastore::ATTR_NODE_KEY_SET_LIST)
            assert_cleanup_snapshot!(journal, current_groups, current_bindings, key_sets)
            journal.cleanup_groups.each do |saved|
              entry = current_groups.find do |candidate|
                candidate.node_id == saved.node_id && candidate.endpoint_id == saved.endpoint_id && candidate.group_id == saved.group_id
              end
              next unless entry
              next if entry.status_entry.state == Datastore::DatastoreStateEnum::DeletePending &&
                      entry.status_entry.failure_code == Datastore::NO_FAILURE_CODE
              invoke!(im, session, Datastore::CMD_REMOVE_GROUP_ID_FROM_ENDPOINT_FOR_NODE,
                Datastore::RemoveGroupIDFromEndpointForNodeRequest.new(saved.node_id,
                  saved.endpoint_id, saved.group_id).to_slice)
            end
            journal.cleanup_bindings.each do |saved|
              entry = current_bindings.find do |candidate|
                candidate.node_id == saved.node_id && candidate.endpoint_id == saved.endpoint_id && candidate.list_id == saved.list_id
              end
              next unless entry
              assert_binding_identity!(saved, entry, journal)
              next if entry.status_entry.state == Datastore::DatastoreStateEnum::DeletePending &&
                      entry.status_entry.failure_code == Datastore::NO_FAILURE_CODE
              invoke!(im, session, Datastore::CMD_REMOVE_BINDING_FROM_ENDPOINT_FOR_NODE,
                Datastore::RemoveBindingFromEndpointForNodeRequest.new(saved.list_id,
                  saved.endpoint_id, saved.node_id).to_slice)
            end
            failed_keys = key_sets.select { |entry| self.class.cleanup_key_set?(entry, journal.node_id) &&
              entry.status_entry.failure_code != Datastore::NO_FAILURE_CODE }
            if failed_keys.any? { |entry| terminal_cleanup_failure?(entry.status_entry) }
              raise Matter::CommissioningError.new("Joint Fabric key-set deletion needs operator repair")
            end
            if failed_keys.any?
              invoke!(im, session, Datastore::CMD_REFRESH_NODE,
                Datastore::RefreshNodeRequest.new(journal.node_id).to_slice)
            end
          end
        end

        def cleanup_complete?(journal : Journal) : Bool
          raise Matter::CommissioningError.new("Joint Fabric node cleanup snapshot is missing") unless journal.cleanup_recorded?
          with_anchor(journal) do |im, session|
            validate_removable!(im, session, journal, allow_cleanup: true)
            groups = read_list(Datastore::DatastoreEndpointGroupIDEntryStruct,
              im, session, Datastore::ATTR_ENDPOINT_GROUP_ID_LIST)
            bindings = read_list(Datastore::DatastoreEndpointBindingEntryStruct,
              im, session, Datastore::ATTR_ENDPOINT_BINDING_LIST)
            key_sets = read_list(Datastore::DatastoreNodeKeySetEntryStruct,
              im, session, Datastore::ATTR_NODE_KEY_SET_LIST)
            assert_cleanup_snapshot!(journal, groups, bindings, key_sets)
            journal.cleanup_bindings.each do |saved|
              if entry = bindings.find { |item| item.node_id == saved.node_id &&
                 item.endpoint_id == saved.endpoint_id && item.list_id == saved.list_id }
                assert_binding_identity!(saved, entry, journal)
              end
            end
            return false if groups.any?(&.node_id.==(journal.node_id))
            return false if bindings.any? { |entry| self.class.cleanup_binding?(entry, journal.node_id) }
            return false if key_sets.any? { |entry| self.class.cleanup_key_set?(entry, journal.node_id) }
            return true
          end
          false
        end

        def revoke_direct_access!(journal : Journal) : Nil
          with_anchor(journal) do |im_client, session|
            validate_removable!(im_client, session, journal)
            direct_grants(im_client, session, journal).each do |entry|
              next if entry.status_entry.state == Datastore::DatastoreStateEnum::DeletePending
              invoke!(im_client, session, Datastore::CMD_REMOVE_ACL_FROM_NODE,
                Datastore::RemoveACLFromNodeRequest.new(entry.list_id, entry.node_id).to_slice)
            end
          end
        end

        def access_revoked?(journal : Journal) : Bool
          with_anchor(journal) do |im_client, session|
            validate_removable!(im_client, session, journal)
            return direct_grants(im_client, session, journal).empty?
          end
          false
        end

        def remove_node!(journal : Journal) : Nil
          with_anchor(journal) do |im_client, session|
            validate_removable!(im_client, session, journal)
            unless direct_grants(im_client, session, journal).empty?
              raise Matter::CommissioningError.new("Joint Fabric node still has direct access grants")
            end
            invoke!(im_client, session, Datastore::CMD_REMOVE_NODE,
              Datastore::RemoveNodeRequest.new(journal.node_id).to_slice)
          end
        end

        def node_absent?(journal : Journal) : Bool
          with_anchor(journal) do |im_client, session|
            return node_entry(im_client, session, journal).nil?
          end
          false
        end

        private def with_anchor(journal : Journal, & : ImClient, Session::SecureContext ->) : Nil
          unless journal.fabric_id == @fabric.fabric_id && journal.root_public_key == @fabric.root_public_key &&
                 journal.controller_node_id == @fabric.controller_node_id && journal.anchor_node_id == @anchor_node_id
            raise Matter::AuthenticationError.new("Joint Fabric node removal journal identifies another fabric or Anchor")
          end
          installed = @store.load.fabric_for(@fabric.fabric_id, @fabric.root_public_key, @fabric.controller_node_id)
          unless installed.controller_noc == @fabric.controller_noc && installed.controller_private_key == @fabric.controller_private_key
            raise Matter::AuthenticationError.new("Joint Fabric node removal controller identity changed")
          end
          session = Pairing::CasePairing.new(@crypto).pair(@client, @anchor_peer, installed,
            peer_node_id: @anchor_node_id, timeout: @timeout)
          anchor_cat = session.peer_subject_ids.any? do |subject|
            cat = DataType::NodeId.case_authenticated_tag_from_subject?(subject)
            cat && cat.identity_value == Datastore::ANCHOR_CAT
          end
          anchor_icac = session.peer_icac.try { |icac| Crypto::MatterCertificate.anchor_icac?(icac) }
          unless anchor_cat && anchor_icac
            raise Matter::AuthenticationError.new("Joint Fabric node removal peer is not an Anchor")
          end
          im = ImClient.new(@client, @timeout)
          root = read_value(im, session, Datastore::ATTR_ANCHOR_ROOT_CA)
          anchor = read_value(im, session, Datastore::ATTR_ANCHOR_NODE_ID)
          unless Bytes.from_tlv(root.to_slice) == installed.root_cert && UInt64.from_tlv(anchor.to_slice) == @anchor_node_id
            raise Matter::AuthenticationError.new("Joint Fabric Datastore identity differs from selected Anchor")
          end
          yield im, session
        end

        private def validate_removable!(im : ImClient, session : Session::SecureContext,
                                        journal : Journal, allow_cleanup : Bool = false) : Nil
          entry = node_entry(im, session, journal) ||
                  raise Matter::CommissioningError.new("Committed Joint Fabric node is absent")
          unless entry.friendly_name == journal.friendly_name && entry.commissioning_status_entry.state.committed?
            raise Matter::CommissioningError.new("Joint Fabric node identity or committed state changed")
          end
          admins = read_list(Datastore::DatastoreAdministratorInformationEntryStruct,
            im, session, Datastore::ATTR_ADMIN_LIST)
          if admins.any?(&.node_id.==(journal.node_id))
            raise Matter::CommissioningError.new("Joint Fabric Administrator removal requires the Administrator workflow")
          end
          memberships = read_list(Datastore::DatastoreEndpointGroupIDEntryStruct,
            im, session, Datastore::ATTR_ENDPOINT_GROUP_ID_LIST)
          bindings = read_list(Datastore::DatastoreEndpointBindingEntryStruct,
            im, session, Datastore::ATTR_ENDPOINT_BINDING_LIST)
          key_sets = read_list(Datastore::DatastoreNodeKeySetEntryStruct,
            im, session, Datastore::ATTR_NODE_KEY_SET_LIST)
          if !allow_cleanup && (memberships.any?(&.node_id.==(journal.node_id)) ||
             bindings.any? { |item| self.class.cleanup_binding?(item, journal.node_id) } ||
             key_sets.any? { |item| self.class.cleanup_key_set?(item, journal.node_id) })
            raise Matter::CommissioningError.new("Joint Fabric node group or binding removal is still required")
          end
          acls = read_list(Datastore::DatastoreACLEntryStruct, im, session, Datastore::ATTR_NODE_ACL_LIST)
          target_noc(journal, im, session)
          acls.each do |acl|
            next if acl.node_id == journal.node_id
            subjects = acl.acl_entry.subjects
            raise Matter::CommissioningError.new("Wildcard ACL grants require explicit removal") unless subjects && subjects.present?
            if subjects.includes?(journal.node_id) && acl.acl_entry.auth_mode != Datastore::DatastoreAccessControlEntryAuthModeEnum::CASE
              raise Matter::CommissioningError.new("Non-CASE ACL subject collides with the removed Node ID")
            end
            if subjects.includes?(journal.node_id) && subjects != [journal.node_id]
              raise Matter::CommissioningError.new("Shared direct ACL must be split before node removal")
            end
          end
        end

        private def assert_binding_identity!(saved : BindingCleanup,
                                             current : Datastore::DatastoreEndpointBindingEntryStruct,
                                             journal : Journal) : Nil
          left = saved.binding
          right = current.binding
          unless left.node == right.node && left.group == right.group &&
                 left.endpoint == right.endpoint && left.cluster == right.cluster
            raise Matter::AuthenticationError.new("Joint Fabric binding ListID was reused during node removal")
          end
          current_noc = saved.node_id == journal.node_id ? target_noc(journal) : peer_noc(journal, saved.node_id)
          unless current_noc == saved.owner_noc
            raise Matter::AuthenticationError.new("Joint Fabric binding owner identity changed during node removal")
          end
        end

        private def assert_cleanup_snapshot!(journal : Journal,
                                             groups : Array(Datastore::DatastoreEndpointGroupIDEntryStruct),
                                             bindings : Array(Datastore::DatastoreEndpointBindingEntryStruct),
                                             key_sets : Array(Datastore::DatastoreNodeKeySetEntryStruct)) : Nil
          groups.each do |entry|
            next unless entry.node_id == journal.node_id
            unless journal.cleanup_groups.any? { |saved| saved.node_id == entry.node_id &&
                   saved.endpoint_id == entry.endpoint_id && saved.group_id == entry.group_id }
              raise Matter::AuthenticationError.new("Joint Fabric group membership changed during node removal")
            end
          end
          bindings.each do |entry|
            next unless self.class.cleanup_binding?(entry, journal.node_id)
            saved = journal.cleanup_bindings.find { |candidate| candidate.node_id == entry.node_id &&
              candidate.endpoint_id == entry.endpoint_id && candidate.list_id == entry.list_id } ||
                    raise Matter::AuthenticationError.new("Joint Fabric binding changed during node removal")
            assert_binding_identity!(saved, entry, journal)
          end
          key_sets.each do |entry|
            next unless self.class.cleanup_key_set?(entry, journal.node_id)
            unless journal.cleanup_key_set_ids.includes?(entry.group_key_set_id)
              raise Matter::AuthenticationError.new("Joint Fabric key set changed during node removal")
            end
          end
        end

        private def terminal_cleanup_failure?(status : Datastore::DatastoreStatusEntryStruct) : Bool
          status.failure_code.in?(InteractionModel::StatusCode::ResourceExhausted.value,
            InteractionModel::StatusCode::ConstraintError.value)
        end

        private def target_noc(journal : Journal, anchor_im : ImClient? = nil,
                               anchor_session : Session::SecureContext? = nil) : Bytes
          state = @store.load
          installed = state.fabric_for(journal.fabric_id, journal.root_public_key, journal.controller_node_id)
          node = state.nodes_for(journal.fabric_id, journal.root_public_key,
            journal.controller_node_id)[journal.node_id]? ||
                 raise Matter::CommissioningError.new("Joint Fabric target has no controller peer record")
          address = node.address || raise Matter::CommissioningError.new("Joint Fabric target address is missing")
          peer = Socket::IPAddress.new(address, node.port)
          target_session = Pairing::CasePairing.new(@crypto).pair(@client, peer, installed,
            peer_node_id: journal.node_id, timeout: @timeout)
          if anchor_im && anchor_session
            target_session.peer_subject_ids.each do |subject|
              tag = DataType::NodeId.case_authenticated_tag_from_subject?(subject)
              next unless tag
              if tag.identity_value.in?(Datastore::ADMINISTRATOR_CAT, Datastore::ANCHOR_CAT)
                raise Matter::CommissioningError.new("Joint Fabric Administrator removal requires the Administrator workflow")
              end
              receipt = journal.group_revocations.find do |candidate|
                candidate.group_cat == tag.identity_value && candidate.previous_version == tag.version &&
                  candidate.anchor_node_id == journal.anchor_node_id &&
                  candidate.anchor_root_cert == installed.root_cert
              end || raise Matter::CommissioningError.new("Controller CAT removal requires a matching group revocation receipt")
              unless SharedFabric.joint_group_revocation_status(anchor_im, anchor_session,
                       @anchor_peer, @datastore_endpoint, receipt).effective?
                raise Matter::CommissioningError.new("Joint Fabric group revocation has not reached every target")
              end
            end
          end
          report = ImClient.new(@client, @timeout).read_attribute(session: target_session, peer: peer,
            endpoint_id: Node::ROOT_ENDPOINT_ID, cluster_id: Cluster::OperationalCredentials::CLUSTER_ID,
            attribute_id: Cluster::OperationalCredentials::ATTR_NOCS)
          data = report.attribute_reports.try(&.find(&.attribute_data)).try(&.attribute_data).try(&.data) ||
                 raise Matter::ProtocolError.new("Joint Fabric target NOCs read returned no data")
          matching = Array(Cluster::OperationalCredentials::Tlv::NOC).from_tlv(data.to_slice).select do |entry|
            certificate = Crypto::MatterCertificate.from_slice(entry.noc)
            certificate.fabric_id == journal.fabric_id && certificate.node_id == journal.node_id
          end
          unless matching.size == 1
            raise Matter::AuthenticationError.new("Joint Fabric target has no unique selected-fabric NOC")
          end
          selected = matching.first
          Crypto::MatterCertificate::Validation.verify_chain(selected.noc, selected.icac,
            installed.root_public_key, installed.root_cert)
          unless journal.target_noc.empty? || selected.noc == journal.target_noc
            raise Matter::AuthenticationError.new("Joint Fabric target NOC changed since removal began")
          end
          selected.noc.dup
        end

        private def peer_noc(journal : Journal, node_id : UInt64) : Bytes
          state = @store.load
          installed = state.fabric_for(journal.fabric_id, journal.root_public_key, journal.controller_node_id)
          node = state.nodes_for(journal.fabric_id, journal.root_public_key,
            journal.controller_node_id)[node_id]? ||
                 raise Matter::CommissioningError.new("Joint Fabric binding owner has no controller peer record")
          address = node.address || raise Matter::CommissioningError.new("Joint Fabric binding owner address is missing")
          peer = Socket::IPAddress.new(address, node.port)
          session = Pairing::CasePairing.new(@crypto).pair(@client, peer, installed,
            peer_node_id: node_id, timeout: @timeout)
          report = ImClient.new(@client, @timeout).read_attribute(session: session, peer: peer,
            endpoint_id: Node::ROOT_ENDPOINT_ID, cluster_id: Cluster::OperationalCredentials::CLUSTER_ID,
            attribute_id: Cluster::OperationalCredentials::ATTR_NOCS)
          data = report.attribute_reports.try(&.find(&.attribute_data)).try(&.attribute_data).try(&.data) ||
                 raise Matter::ProtocolError.new("Joint Fabric binding owner NOCs read returned no data")
          matching = Array(Cluster::OperationalCredentials::Tlv::NOC).from_tlv(data.to_slice).select do |entry|
            certificate = Crypto::MatterCertificate.from_slice(entry.noc)
            certificate.fabric_id == journal.fabric_id && certificate.node_id == node_id
          end
          unless matching.size == 1
            raise Matter::AuthenticationError.new("Joint Fabric binding owner has no unique selected-fabric NOC")
          end
          selected = matching.first
          Crypto::MatterCertificate::Validation.verify_chain(selected.noc, selected.icac,
            installed.root_public_key, installed.root_cert)
          selected.noc.dup
        end

        private def direct_grants(im : ImClient, session : Session::SecureContext,
                                  journal : Journal) : Array(Datastore::DatastoreACLEntryStruct)
          read_list(Datastore::DatastoreACLEntryStruct, im, session, Datastore::ATTR_NODE_ACL_LIST).select do |entry|
            entry.node_id != journal.node_id && direct_grant?(entry.acl_entry, journal.node_id)
          end
        end

        def self.direct_grant?(acl : Datastore::DatastoreAccessControlEntryStruct,
                               node_id : UInt64) : Bool
          acl.auth_mode == Datastore::DatastoreAccessControlEntryAuthModeEnum::CASE && acl.subjects == [node_id]
        end

        private def direct_grant?(acl : Datastore::DatastoreAccessControlEntryStruct,
                                  node_id : UInt64) : Bool
          self.class.direct_grant?(acl, node_id)
        end

        private def node_entry(im : ImClient, session : Session::SecureContext,
                               journal : Journal) : Datastore::DatastoreNodeInformationEntryStruct?
          read_list(Datastore::DatastoreNodeInformationEntryStruct, im, session,
            Datastore::ATTR_NODE_LIST).find(&.node_id.==(journal.node_id))
        end

        private def read_list(type : T.class, im : ImClient, session : Session::SecureContext,
                              attribute : UInt32) : Array(T) forall T
          Array(T).from_tlv(read_value(im, session, attribute).to_slice)
        end

        private def read_value(im : ImClient, session : Session::SecureContext,
                               attribute : UInt32) : TLV::Any
          report = im.read_attribute(session: session, peer: @anchor_peer,
            endpoint_id: @datastore_endpoint, cluster_id: Datastore::CLUSTER_ID, attribute_id: attribute)
          report.attribute_reports.try(&.find(&.attribute_data)).try(&.attribute_data).try(&.data) ||
            raise Matter::ProtocolError.new("Joint Fabric Datastore attribute #{attribute} returned no data")
        end

        private def invoke!(im : ImClient, session : Session::SecureContext,
                            command : UInt32, fields : Bytes) : Nil
          response = im.invoke(session: session, peer: @anchor_peer,
            endpoint_id: @datastore_endpoint, cluster_id: Datastore::CLUSTER_ID,
            command_id: command, fields: fields)
          status = response.invoke_responses.compact_map(&.command_status).first?.try(&.status)
          unless status && status.status == InteractionModel::StatusCode::Success.value
            raise Matter::CommissioningError.new("Joint Fabric Datastore command #{command} failed (#{status.try(&.status)})")
          end
        end
      end

      class Workflow
        getter journal : Journal

        def initialize(@journal : Journal, @port : Port, @store : JournalStore)
        end

        def run : Nil
          return if @journal.stage.complete?
          if @journal.stage.removing?
            raise Matter::CommissioningError.new("RemoveNode outcome needs authenticated reconciliation")
          end
          unless @journal.cleanup_recorded?
            snapshot = @port.snapshot_cleanup(@journal)
            updated = @journal
            updated.cleanup_groups = snapshot.groups
            updated.cleanup_bindings = snapshot.bindings
            updated.cleanup_key_set_ids = snapshot.key_set_ids
            updated.cleanup_recorded = true
            updated.stage_version += 1_u64
            @store.save(updated)
            @journal = updated
          end
          @port.cleanup!(@journal)
          unless @port.cleanup_complete?(@journal)
            raise Matter::CommissioningError.new("Joint Fabric node cleanup is pending delivery")
          end
          @port.revoke_direct_access!(@journal)
          unless @port.access_revoked?(@journal)
            raise Matter::CommissioningError.new("Joint Fabric node access revocation is pending delivery")
          end
          advance(Stage::Removing)
          @port.remove_node!(@journal)
          reconcile_removed!
        end

        def reconcile_removed! : Nil
          unless @journal.stage.removing? && @port.node_absent?(@journal)
            raise Matter::CommissioningError.new("Joint Fabric RemoveNode is not proven complete")
          end
          advance(Stage::Complete)
        end

        private def advance(stage : Stage) : Nil
          updated = @journal
          updated.stage = stage
          updated.stage_version += 1_u64
          @store.save(updated)
          @journal = updated
        end
      end
    end
  end
end
