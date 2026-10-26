require "log"

require "../cluster/joint_fabric_datastore"
require "../cluster/group_key_management"
require "../cluster/groupcast"
require "../cluster/groups"
require "../cluster/access_control"
require "../cluster/binding"
require "../cluster/descriptor"
require "../cluster/operational_credentials"
require "./im_client"

module Matter
  module Controller
    # Applies an anchor's pending Datastore records to one operational node.
    # Completion is recorded only after the device confirms the IM operation.
    class DatastoreSynchronizer
      Log = ::Log.for("matter.controller.datastore_synchronizer")

      alias Store = Cluster::JointFabricDatastore
      FAILURE_CODE = InteractionModel::StatusCode::Failure.value

      def initialize(@im : ImClient)
      end

      def sync_node(store : Store, node_id : UInt64, session : Session::SecureContext, peer : Socket::IPAddress) : Nil
        root_servers = read_list(UInt32, session, peer, 0_u16,
          Cluster::Descriptor::CLUSTER_ID, Cluster::Descriptor::ATTR_SERVER_LIST)
        groupcast_target = groupcast_available?(root_servers, session, peer)
        refreshing = store.node_list.any? { |entry| entry.node_id == node_id && entry.commissioning_status_entry.state == Store::DatastoreStateEnum::Pending }
        if refreshing
          # Reject privileges JFDS cannot represent before changing any local
          # Datastore lists; pending ACL writes may require a later reread.
          if root_servers.includes?(Cluster::AccessControl::CLUSTER_ID)
            validate_representable_acls!(read_list(Cluster::AccessControl::AccessControlEntry,
              session, peer, 0_u16, Cluster::AccessControl::CLUSTER_ID, Cluster::AccessControl::ATTR_ACL), node_id)
          end
          endpoint_ids = read_list(UInt16, session, peer, 0_u16, Cluster::Descriptor::CLUSTER_ID, Cluster::Descriptor::ATTR_PARTS_LIST)
          status = store.reconcile_node_endpoints(node_id, endpoint_ids)
          raise Matter::ProtocolError.new("Datastore endpoint reconciliation failed") unless status.success?
        end

        store.node_key_set_list.select { |entry| entry.node_id == node_id && entry.status_entry.state == Store::DatastoreStateEnum::Pending }.each do |entry|
          status = apply do
            sync_key_set(store, entry, session, peer)
          end
          store.complete_node_key_set(node_id, entry.group_key_set_id, status)
        end

        pending_groups = store.endpoint_group_id_list.select { |entry| entry.node_id == node_id && pending?(entry.status_entry) }
        pending_groups.each do |entry|
          status = apply do
            adopt_groupcast(session, peer) if groupcast_target
            sync_group(store, entry, session, peer, groupcast_target)
          end
          store.complete_group_membership(node_id, entry.endpoint_id, entry.group_id, status)
        end

        store.node_key_set_list.select { |entry| entry.node_id == node_id && entry.status_entry.state == Store::DatastoreStateEnum::DeletePending && entry.status_entry.failure_code == 0_u8 }.each do |entry|
          status = apply do
            sync_key_set(store, entry, session, peer)
          end
          store.complete_node_key_set(node_id, entry.group_key_set_id, status)
        end

        store.node_acl_list.select { |entry| entry.node_id == node_id && pending?(entry.status_entry) }.each do |entry|
          status = apply do
            sync_acl(store, entry, session, peer)
          end
          store.complete_acl(node_id, entry.list_id, status)
        end

        store.endpoint_binding_list.select { |entry| entry.node_id == node_id && pending?(entry.status_entry) }.each do |entry|
          status = apply do
            sync_binding(store, entry, session, peer)
          end
          store.complete_binding(node_id, entry.endpoint_id, entry.list_id, status)
        end

        if refreshing
          reconcile_target_state(store, node_id, session, peer, root_servers, groupcast_target)
          failed = store.node_key_set_list.any? { |entry| entry.node_id == node_id && failed?(entry.status_entry) } ||
                   store.endpoint_group_id_list.any? { |entry| entry.node_id == node_id && failed?(entry.status_entry) } ||
                   store.node_acl_list.any? { |entry| entry.node_id == node_id && failed?(entry.status_entry) } ||
                   store.endpoint_binding_list.any? { |entry| entry.node_id == node_id && failed?(entry.status_entry) }
          store.complete_node(node_id, failed ? FAILURE_CODE : 0_u8)
        end
      end

      private def reconcile_target_state(store : Store, node_id : UInt64,
                                         session : Session::SecureContext, peer : Socket::IPAddress,
                                         root_servers : Array(UInt32), groupcast_target : Bool) : Nil
        groupcast_memberships = groupcast_target ? read_list(Cluster::Groupcast::MembershipStruct,
          session, peer, 0_u16, Cluster::Groupcast::CLUSTER_ID, Cluster::Groupcast::ATTR_MEMBERSHIP) : [] of Cluster::Groupcast::MembershipStruct
        store.node_endpoint_list.select(&.node_id.==(node_id)).each do |endpoint|
          servers = read_list(UInt32, session, peer, endpoint.endpoint_id, Cluster::Descriptor::CLUSTER_ID, Cluster::Descriptor::ATTR_SERVER_LIST)
          if groupcast_target
            group_ids = groupcast_memberships.select { |member| member.endpoints.includes?(endpoint.endpoint_id) }.map(&.group_id)
            ensure_reconciled!(store.reconcile_node_groups(node_id, endpoint.endpoint_id, group_ids))
          elsif servers.includes?(Cluster::Groups::CLUSTER_ID)
            request = Cluster::Groups::GetGroupMembershipRequest.new([] of DataType::GroupId)
            fields = invoke_data(session, peer, endpoint.endpoint_id, Cluster::Groups::CLUSTER_ID,
              Cluster::Groups::CMD_GET_GROUP_MEMBERSHIP, request.to_slice)
            group_ids = Cluster::Groups::GetGroupMembershipResponse.from_slice(fields).group_list.map(&.id)
            ensure_reconciled!(store.reconcile_node_groups(node_id, endpoint.endpoint_id, group_ids))
          end
          if servers.includes?(Cluster::Binding::CLUSTER_ID)
            bindings = read_list(Cluster::Binding::Target, session, peer, endpoint.endpoint_id,
              Cluster::Binding::CLUSTER_ID, Cluster::Binding::ATTR_BINDING).map do |target|
              Store::DatastoreBindingTargetStruct.new(target.node, target.group, target.endpoint, target.cluster)
            end
            ensure_reconciled!(store.reconcile_node_bindings(node_id, endpoint.endpoint_id, bindings))
          end
        end

        if root_servers.includes?(Cluster::GroupKeyManagement::CLUSTER_ID)
          fields = invoke_data(session, peer, 0_u16, Cluster::GroupKeyManagement::CLUSTER_ID,
            Cluster::GroupKeyManagement::CMD_KEY_SET_READ_ALL_INDICES, Bytes.empty)
          ids = Cluster::GroupKeyManagement::KeySetReadAllIndicesResponse.from_slice(fields).group_key_set_i_ds
          ensure_reconciled!(store.reconcile_node_key_sets(node_id, ids))
        end
        if root_servers.includes?(Cluster::AccessControl::CLUSTER_ID)
          target_acls = read_list(Cluster::AccessControl::AccessControlEntry, session, peer, 0_u16,
            Cluster::AccessControl::CLUSTER_ID, Cluster::AccessControl::ATTR_ACL)
          validate_representable_acls!(target_acls, node_id)
          acls = target_acls.map do |entry|
            Store::DatastoreAccessControlEntryStruct.new(
              Store::DatastoreAccessControlEntryPrivilegeEnum.from_value(entry.privilege.value),
              Store::DatastoreAccessControlEntryAuthModeEnum.from_value(entry.auth_mode.value),
              entry.subjects,
              entry.targets.try(&.map { |target| Store::DatastoreAccessControlTargetStruct.new(target.cluster, target.endpoint, target.device_type) })
            )
          end
          ensure_reconciled!(store.reconcile_node_acls(node_id, acls))
        end
      end

      private def validate_representable_acls!(acls : Array(Cluster::AccessControl::AccessControlEntry), node_id : UInt64) : Nil
        if acls.any?(&.privilege.==(Cluster::AccessControl::AccessControlEntryPrivilege::ProxyView))
          raise Matter::ProtocolError.new("Joint Fabric Datastore cannot encode ProxyView ACL for node 0x#{node_id.to_s(16)}")
        end
      end

      private def ensure_reconciled!(status : InteractionModel::Status) : Nil
        raise Matter::ClusterError.new("Datastore target reconciliation failed", status.status, status.cluster_status) unless status.success?
      end

      private def invoke_data(session : Session::SecureContext, peer : Socket::IPAddress, endpoint_id : UInt16,
                              cluster_id : UInt32, command_id : UInt32, fields : Bytes) : Bytes
        response = @im.invoke(session, peer, endpoint_id, cluster_id, command_id, fields)
        data = response.invoke_responses.find(&.command_data).try(&.command_data).try(&.command_fields)
        if !data && (status = response.invoke_responses.compact_map(&.command_status).first?.try(&.status))
          raise Matter::ClusterError.from_wire("Datastore target command failed", status.status, status.cluster_status)
        end
        raise Matter::ProtocolError.new("Datastore target command returned no data") unless data
        data.to_slice
      end

      private def pending?(status : Store::DatastoreStatusEntryStruct) : Bool
        status.state == Store::DatastoreStateEnum::Pending ||
          (status.state == Store::DatastoreStateEnum::DeletePending && status.failure_code == 0_u8)
      end

      private def failed?(status : Store::DatastoreStatusEntryStruct) : Bool
        status.state == Store::DatastoreStateEnum::CommitFailed ||
          (status.state == Store::DatastoreStateEnum::DeletePending && status.failure_code != 0_u8)
      end

      private def apply(& : -> Nil) : UInt8
        yield
        0_u8
      rescue ex : Matter::ClusterError
        Log.error(exception: ex) { "Failed to synchronize Joint Fabric Datastore entry" }
        ex.status.value
      rescue ex : Matter::TimeoutError
        Log.error(exception: ex) { "Timed out synchronizing Joint Fabric Datastore entry" }
        InteractionModel::StatusCode::Timeout.value
      rescue ex
        Log.error(exception: ex) { "Failed to synchronize Joint Fabric Datastore entry" }
        FAILURE_CODE
      end

      private def sync_key_set(store : Store, entry : Store::DatastoreNodeKeySetEntryStruct,
                               session : Session::SecureContext, peer : Socket::IPAddress) : Nil
        if entry.status_entry.state == Store::DatastoreStateEnum::DeletePending
          request = Cluster::GroupKeyManagement::KeySetRemoveRequest.new(entry.group_key_set_id)
          invoke_ok!(session, peer, 0_u16, Cluster::GroupKeyManagement::CLUSTER_ID, Cluster::GroupKeyManagement::CMD_KEY_SET_REMOVE, request.to_slice)
        else
          source = store.group_key_set_list.find(&.group_key_set_id.==(entry.group_key_set_id)) ||
                   raise Matter::ConfigurationError.new("Datastore key set #{entry.group_key_set_id} is missing")
          key_set = Cluster::GroupKeyManagement::GroupKeySetStruct.new(
            group_key_set_id: source.group_key_set_id,
            epoch_key0: source.epoch_key0,
            epoch_start_time0: source.epoch_start_time0,
            epoch_key1: source.epoch_key1,
            epoch_start_time1: source.epoch_start_time1,
            epoch_key2: source.epoch_key2,
            epoch_start_time2: source.epoch_start_time2
          )
          request = Cluster::GroupKeyManagement::KeySetWriteRequest.new(key_set)
          invoke_ok!(session, peer, 0_u16, Cluster::GroupKeyManagement::CLUSTER_ID, Cluster::GroupKeyManagement::CMD_KEY_SET_WRITE, request.to_slice)
        end
      end

      private def sync_group(store : Store, entry : Store::DatastoreEndpointGroupIDEntryStruct,
                             session : Session::SecureContext, peer : Socket::IPAddress,
                             groupcast_target : Bool) : Nil
        if groupcast_target
          sync_groupcast(store, entry, session, peer)
          return
        end
        update_group_key_map(store, entry, session, peer)
        if entry.status_entry.state == Store::DatastoreStateEnum::DeletePending
          request = Cluster::Groups::RemoveGroupRequest.new(DataType::GroupId.new(entry.group_id))
          response_id = Cluster::Groups::CMD_REMOVE_GROUP_RESPONSE
          command_id = Cluster::Groups::CMD_REMOVE_GROUP
        else
          group = store.group_list.find(&.group_id.==(entry.group_id.to_u64)) ||
                  raise Matter::ConfigurationError.new("Datastore group #{entry.group_id} is missing")
          request = Cluster::Groups::AddGroupRequest.new(DataType::GroupId.new(entry.group_id), group.friendly_name)
          response_id = Cluster::Groups::CMD_ADD_GROUP_RESPONSE
          command_id = Cluster::Groups::CMD_ADD_GROUP
        end
        response = @im.invoke(session, peer, entry.endpoint_id, Cluster::Groups::CLUSTER_ID, command_id, request.to_slice)
        fields = response.invoke_responses.find(&.command_data).try(&.command_data).try(&.command_fields)
        if !fields && (status = response.invoke_responses.compact_map(&.command_status).first?.try(&.status))
          raise Matter::ClusterError.from_wire("Groups command failed", status.status, status.cluster_status)
        end
        raise Matter::ProtocolError.new("Groups command returned no response data") unless fields
        status = if response_id == Cluster::Groups::CMD_ADD_GROUP_RESPONSE
                   Cluster::Groups::AddGroupResponse.from_slice(fields.to_slice).status_code
                 else
                   Cluster::Groups::RemoveGroupResponse.from_slice(fields.to_slice).status_code
                 end
        unless status == InteractionModel::StatusCode::Success
          raise Matter::ClusterError.new("Groups command failed with status #{status}", status)
        end
      end

      private def adopt_groupcast(session : Session::SecureContext, peer : Socket::IPAddress) : Nil
        entries = read_list(Cluster::GroupKeyManagement::GroupcastAdoptionStruct, session, peer,
          0_u16, Cluster::GroupKeyManagement::CLUSTER_ID,
          Cluster::GroupKeyManagement::ATTR_GROUPCAST_ADOPTION)
        return if entries.any?(&.groupcast_adopted?)
        adoption = [Cluster::GroupKeyManagement::GroupcastAdoptionStruct.new(true)]
        write_ok!(session, peer, 0_u16, Cluster::GroupKeyManagement::CLUSTER_ID,
          Cluster::GroupKeyManagement::ATTR_GROUPCAST_ADOPTION, adoption.to_tlv)
      end

      private def groupcast_available?(root_servers : Array(UInt32), session : Session::SecureContext,
                                       peer : Socket::IPAddress) : Bool
        return false unless root_servers.includes?(Cluster::Groupcast::CLUSTER_ID)
        read_list(Cluster::GroupKeyManagement::GroupcastAdoptionStruct, session, peer,
          0_u16, Cluster::GroupKeyManagement::CLUSTER_ID,
          Cluster::GroupKeyManagement::ATTR_GROUPCAST_ADOPTION)
        true
      rescue ex : Matter::ClusterError
        return false if ex.status == InteractionModel::StatusCode::UnsupportedAttribute
        raise ex
      end

      private def sync_groupcast(store : Store, entry : Store::DatastoreEndpointGroupIDEntryStruct,
                                 session : Session::SecureContext, peer : Socket::IPAddress) : Nil
        memberships = read_list(Cluster::Groupcast::MembershipStruct, session, peer,
          0_u16, Cluster::Groupcast::CLUSTER_ID, Cluster::Groupcast::ATTR_MEMBERSHIP)
        existing = memberships.find(&.group_id.==(entry.group_id))
        if entry.status_entry.state == Store::DatastoreStateEnum::DeletePending
          return unless existing && existing.endpoints.includes?(entry.endpoint_id)
          request = Cluster::Groupcast::LeaveGroupRequest.new(entry.group_id, [entry.endpoint_id])
          fields = invoke_data(session, peer, 0_u16, Cluster::Groupcast::CLUSTER_ID,
            Cluster::Groupcast::CMD_LEAVE_GROUP, request.to_slice)
          response = Cluster::Groupcast::LeaveGroupResponse.from_slice(fields)
          unless response.group_id == entry.group_id && response.endpoints.includes?(entry.endpoint_id)
            raise Matter::ProtocolError.new("Groupcast LeaveGroup did not confirm endpoint removal")
          end
        else
          group = store.group_list.find(&.group_id.==(entry.group_id.to_u64)) ||
                  raise Matter::ConfigurationError.new("Datastore group #{entry.group_id} is missing")
          key_set_id = group.group_key_set_id ||
                       raise Matter::ConfigurationError.new("Groupcast group #{entry.group_id} has no key set")
          return if existing && existing.endpoints.includes?(entry.endpoint_id) && existing.key_set_id == key_set_id
          request = Cluster::Groupcast::JoinGroupRequest.new(entry.group_id, [entry.endpoint_id], key_set_id)
          invoke_ok!(session, peer, 0_u16, Cluster::Groupcast::CLUSTER_ID,
            Cluster::Groupcast::CMD_JOIN_GROUP, request.to_slice)
        end
      end

      private def update_group_key_map(store : Store, entry : Store::DatastoreEndpointGroupIDEntryStruct,
                                       session : Session::SecureContext, peer : Socket::IPAddress) : Nil
        group = store.group_list.find(&.group_id.==(entry.group_id.to_u64))
        key_set_id = group.try(&.group_key_set_id)
        deleting = entry.status_entry.state == Store::DatastoreStateEnum::DeletePending
        return unless key_set_id || deleting

        mappings = read_list(Cluster::GroupKeyManagement::GroupKeyMapStruct, session, peer, 0_u16, Cluster::GroupKeyManagement::CLUSTER_ID, Cluster::GroupKeyManagement::ATTR_GROUP_KEY_MAP)
        fabric_index = read_target_fabric_index(session, peer)
        if mappings.any? { |mapping| mapping.fabric_index != fabric_index }
          raise Matter::ProtocolError.new("Target GroupKeyMap contains another fabric's entry")
        end
        mappings.reject! { |mapping| mapping.group_id == entry.group_id }
        if !deleting || store.endpoint_group_id_list.any? { |other| other.node_id == entry.node_id && other.group_id == entry.group_id && other.endpoint_id != entry.endpoint_id && other.status_entry.state != Store::DatastoreStateEnum::DeletePending }
          if key_set_id
            mappings << Cluster::GroupKeyManagement::GroupKeyMapStruct.new(entry.group_id, key_set_id, fabric_index)
          end
        end
        write_ok!(session, peer, 0_u16, Cluster::GroupKeyManagement::CLUSTER_ID, Cluster::GroupKeyManagement::ATTR_GROUP_KEY_MAP, mappings.to_tlv)
      end

      private def read_target_fabric_index(session : Session::SecureContext, peer : Socket::IPAddress) : UInt8
        response = @im.read_attribute(session, peer, 0_u16,
          Cluster::OperationalCredentials::CLUSTER_ID,
          Cluster::OperationalCredentials::ATTR_CURRENT_FABRIC_INDEX)
        data = response.attribute_reports.try(&.find(&.attribute_data)).try(&.attribute_data).try(&.data)
        if !data && (status = response.attribute_reports.try(&.compact_map(&.attribute_status)).try(&.first?).try(&.status))
          raise Matter::ClusterError.from_wire("Target CurrentFabricIndex read failed", status.status, status.cluster_status)
        end
        raise Matter::ProtocolError.new("Target CurrentFabricIndex read returned no data") unless data
        index = UInt8.from_tlv(data.to_slice)
        raise Matter::ProtocolError.new("Target CurrentFabricIndex is undefined") if index == 0_u8
        index
      end

      private def sync_acl(store : Store, entry : Store::DatastoreACLEntryStruct,
                           session : Session::SecureContext, peer : Socket::IPAddress) : Nil
        current = read_list(Cluster::AccessControl::AccessControlEntry, session, peer, 0_u16, Cluster::AccessControl::CLUSTER_ID, Cluster::AccessControl::ATTR_ACL)
        wanted = target_acl(entry.acl_entry)
        if prior = entry.prior_acl_entry
          old = target_acl(prior)
          if acl_required_by_other_entry?(store, entry, old)
            current << old unless current.any? { |item| same_acl?(item, old) }
          else
            current.reject! { |item| same_acl?(item, old) }
          end
        end
        if entry.status_entry.state == Store::DatastoreStateEnum::DeletePending
          if acl_required_by_other_entry?(store, entry, wanted)
            current << wanted unless current.any? { |item| same_acl?(item, wanted) }
          else
            current.reject! { |item| same_acl?(item, wanted) }
          end
        elsif !current.any? { |item| same_acl?(item, wanted) }
          current << wanted
        end
        write_ok!(session, peer, 0_u16, Cluster::AccessControl::CLUSTER_ID, Cluster::AccessControl::ATTR_ACL, current.to_tlv)
      end

      private def acl_required_by_other_entry?(store : Store, entry : Store::DatastoreACLEntryStruct,
                                               wanted : Cluster::AccessControl::AccessControlEntry) : Bool
        store.node_acl_list.any? do |other|
          other.node_id == entry.node_id && other.list_id != entry.list_id &&
            other.status_entry.state == Store::DatastoreStateEnum::Committed &&
            same_acl?(target_acl(other.acl_entry), wanted)
        end
      end

      private def target_acl(source : Store::DatastoreAccessControlEntryStruct) : Cluster::AccessControl::AccessControlEntry
        Cluster::AccessControl::AccessControlEntry.new(
          privilege: Cluster::AccessControl::AccessControlEntryPrivilege.from_value(source.privilege.value),
          auth_mode: Cluster::AccessControl::AccessControlEntryAuthMode.from_value(source.auth_mode.value),
          subjects: source.subjects || [] of UInt64,
          targets: source.targets.try(&.map { |target| Cluster::AccessControl::Target.new(target.cluster, target.endpoint, target.device_type) })
        )
      end

      private def sync_binding(store : Store, entry : Store::DatastoreEndpointBindingEntryStruct,
                               session : Session::SecureContext, peer : Socket::IPAddress) : Nil
        current = read_list(Cluster::Binding::Target, session, peer, entry.endpoint_id, Cluster::Binding::CLUSTER_ID, Cluster::Binding::ATTR_BINDING)
        source = entry.binding
        wanted = Cluster::Binding::Target.new(source.node, source.group, source.endpoint, source.cluster)
        another_active_binding = store.endpoint_binding_list.any? do |other|
          other.node_id == entry.node_id && other.endpoint_id == entry.endpoint_id &&
            other.list_id != entry.list_id && other.binding == source &&
            other.status_entry.state == Store::DatastoreStateEnum::Committed
        end
        if entry.status_entry.state == Store::DatastoreStateEnum::DeletePending && !another_active_binding
          current.reject! { |item| same_binding?(item, wanted) }
        elsif !current.any? { |item| same_binding?(item, wanted) }
          current << wanted
        end
        write_ok!(session, peer, entry.endpoint_id, Cluster::Binding::CLUSTER_ID, Cluster::Binding::ATTR_BINDING, current.to_tlv)
      end

      private def same_acl?(left : Cluster::AccessControl::AccessControlEntry,
                            right : Cluster::AccessControl::AccessControlEntry) : Bool
        left.privilege == right.privilege && left.auth_mode == right.auth_mode &&
          left.subjects == right.subjects && left.targets == right.targets
      end

      private def same_binding?(left : Cluster::Binding::Target, right : Cluster::Binding::Target) : Bool
        left.node == right.node && left.group == right.group && left.endpoint == right.endpoint && left.cluster == right.cluster
      end

      private def read_list(type : T.class, session : Session::SecureContext, peer : Socket::IPAddress,
                            endpoint_id : UInt16, cluster_id : UInt32, attribute_id : UInt32) : Array(T) forall T
        response = @im.read_attribute(session, peer, endpoint_id, cluster_id, attribute_id)
        data = response.attribute_reports.try(&.find(&.attribute_data)).try(&.attribute_data).try(&.data)
        if !data && (status = response.attribute_reports.try(&.compact_map(&.attribute_status)).try(&.first?).try(&.status))
          raise Matter::ClusterError.from_wire("Datastore target read failed", status.status, status.cluster_status)
        end
        raise Matter::ProtocolError.new("Datastore target read returned no data") unless data
        Array(T).from_tlv(data.to_slice)
      end

      private def write_ok!(session : Session::SecureContext, peer : Socket::IPAddress,
                            endpoint_id : UInt16, cluster_id : UInt32, attribute_id : UInt32, value : Bytes) : Nil
        response = @im.write_attribute(session, peer, endpoint_id, cluster_id, attribute_id, value)
        return if response.write_responses.any? { |entry| entry.status.status == InteractionModel::StatusCode::Success.value }
        status = response.write_responses.first?.try(&.status)
        raise Matter::ClusterError.from_wire("Datastore target write failed", status.status, status.cluster_status) if status
        raise Matter::ProtocolError.new("Datastore target write returned no status")
      end

      private def invoke_ok!(session : Session::SecureContext, peer : Socket::IPAddress,
                             endpoint_id : UInt16, cluster_id : UInt32, command_id : UInt32, fields : Bytes) : Nil
        response = @im.invoke(session, peer, endpoint_id, cluster_id, command_id, fields)
        return if response.invoke_responses.any? { |entry| entry.command_status.try(&.status.status) == InteractionModel::StatusCode::Success.value }
        status = response.invoke_responses.compact_map(&.command_status).first?.try(&.status)
        raise Matter::ClusterError.from_wire("Datastore target command failed", status.status, status.cluster_status) if status
        raise Matter::ProtocolError.new("Datastore target command returned no status")
      end
    end
  end
end
