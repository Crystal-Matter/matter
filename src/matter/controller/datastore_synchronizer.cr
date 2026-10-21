require "log"

require "../cluster/joint_fabric_datastore"
require "../cluster/group_key_management"
require "../cluster/groups"
require "../cluster/access_control"
require "../cluster/binding"
require "../cluster/descriptor"
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
        refreshing = store.node_list.any? { |entry| entry.node_id == node_id && entry.commissioning_status_entry.state == Store::DatastoreStateEnum::Pending }
        if refreshing
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

        store.endpoint_group_id_list.select { |entry| entry.node_id == node_id && pending?(entry.status_entry) }.each do |entry|
          status = apply do
            sync_group(store, entry, session, peer)
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
            sync_acl(entry, session, peer)
          end
          store.complete_acl(node_id, entry.list_id, status)
        end

        store.endpoint_binding_list.select { |entry| entry.node_id == node_id && pending?(entry.status_entry) }.each do |entry|
          status = apply do
            sync_binding(entry, session, peer)
          end
          store.complete_binding(node_id, entry.endpoint_id, entry.list_id, status)
        end

        if refreshing
          reconcile_target_state(store, node_id, session, peer)
          failed = store.node_key_set_list.any? { |entry| entry.node_id == node_id && failed?(entry.status_entry) } ||
                   store.endpoint_group_id_list.any? { |entry| entry.node_id == node_id && failed?(entry.status_entry) } ||
                   store.node_acl_list.any? { |entry| entry.node_id == node_id && failed?(entry.status_entry) } ||
                   store.endpoint_binding_list.any? { |entry| entry.node_id == node_id && failed?(entry.status_entry) }
          store.complete_node(node_id, failed ? FAILURE_CODE : 0_u8)
        end
      end

      private def reconcile_target_state(store : Store, node_id : UInt64,
                                         session : Session::SecureContext, peer : Socket::IPAddress) : Nil
        root_servers = read_list(UInt32, session, peer, 0_u16, Cluster::Descriptor::CLUSTER_ID, Cluster::Descriptor::ATTR_SERVER_LIST)
        store.node_endpoint_list.select(&.node_id.==(node_id)).each do |endpoint|
          servers = read_list(UInt32, session, peer, endpoint.endpoint_id, Cluster::Descriptor::CLUSTER_ID, Cluster::Descriptor::ATTR_SERVER_LIST)
          if servers.includes?(Cluster::Groups::CLUSTER_ID)
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
          acls = read_list(Cluster::AccessControl::AccessControlEntry, session, peer, 0_u16,
            Cluster::AccessControl::CLUSTER_ID, Cluster::AccessControl::ATTR_ACL).compact_map do |entry|
            if entry.privilege == Cluster::AccessControl::AccessControlEntryPrivilege::ProxyView
              Log.warn { "Ignoring ProxyView ACL that Joint Fabric Datastore cannot encode for node 0x#{node_id.to_s(16)}" }
              next
            end
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
                             session : Session::SecureContext, peer : Socket::IPAddress) : Nil
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

      private def update_group_key_map(store : Store, entry : Store::DatastoreEndpointGroupIDEntryStruct,
                                       session : Session::SecureContext, peer : Socket::IPAddress) : Nil
        group = store.group_list.find(&.group_id.==(entry.group_id.to_u64))
        key_set_id = group.try(&.group_key_set_id)
        deleting = entry.status_entry.state == Store::DatastoreStateEnum::DeletePending
        return unless key_set_id || deleting

        mappings = read_list(Cluster::GroupKeyManagement::GroupKeyMapStruct, session, peer, 0_u16, Cluster::GroupKeyManagement::CLUSTER_ID, Cluster::GroupKeyManagement::ATTR_GROUP_KEY_MAP)
        mappings.reject! { |mapping| mapping.group_id == entry.group_id }
        if !deleting || store.endpoint_group_id_list.any? { |other| other.node_id == entry.node_id && other.group_id == entry.group_id && other.endpoint_id != entry.endpoint_id && other.status_entry.state != Store::DatastoreStateEnum::DeletePending }
          if key_set_id
            mappings << Cluster::GroupKeyManagement::GroupKeyMapStruct.new(entry.group_id, key_set_id, mappings.first?.try(&.fabric_index) || 0_u8)
          end
        end
        write_ok!(session, peer, 0_u16, Cluster::GroupKeyManagement::CLUSTER_ID, Cluster::GroupKeyManagement::ATTR_GROUP_KEY_MAP, mappings.to_tlv)
      end

      private def sync_acl(entry : Store::DatastoreACLEntryStruct,
                           session : Session::SecureContext, peer : Socket::IPAddress) : Nil
        current = read_list(Cluster::AccessControl::AccessControlEntry, session, peer, 0_u16, Cluster::AccessControl::CLUSTER_ID, Cluster::AccessControl::ATTR_ACL)
        wanted = target_acl(entry.acl_entry)
        if prior = entry.prior_acl_entry
          old = target_acl(prior)
          current.reject! { |item| same_acl?(item, old) }
        end
        if entry.status_entry.state == Store::DatastoreStateEnum::DeletePending
          current.reject! { |item| same_acl?(item, wanted) }
        elsif !current.any? { |item| same_acl?(item, wanted) }
          current << wanted
        end
        write_ok!(session, peer, 0_u16, Cluster::AccessControl::CLUSTER_ID, Cluster::AccessControl::ATTR_ACL, current.to_tlv)
      end

      private def target_acl(source : Store::DatastoreAccessControlEntryStruct) : Cluster::AccessControl::AccessControlEntry
        Cluster::AccessControl::AccessControlEntry.new(
          privilege: Cluster::AccessControl::AccessControlEntryPrivilege.from_value(source.privilege.value),
          auth_mode: Cluster::AccessControl::AccessControlEntryAuthMode.from_value(source.auth_mode.value),
          subjects: source.subjects || [] of UInt64,
          targets: source.targets.try(&.map { |target| Cluster::AccessControl::Target.new(target.cluster, target.endpoint, target.device_type) })
        )
      end

      private def sync_binding(entry : Store::DatastoreEndpointBindingEntryStruct,
                               session : Session::SecureContext, peer : Socket::IPAddress) : Nil
        current = read_list(Cluster::Binding::Target, session, peer, entry.endpoint_id, Cluster::Binding::CLUSTER_ID, Cluster::Binding::ATTR_BINDING)
        source = entry.binding
        wanted = Cluster::Binding::Target.new(source.node, source.group, source.endpoint, source.cluster)
        if entry.status_entry.state == Store::DatastoreStateEnum::DeletePending
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
