require "../spec_helper"
require "../../src/matter/controller"

private alias Datastore = Matter::Cluster::JointFabricDatastore

private class DatastoreImClient < Matter::Controller::ImClient
  getter commands = [] of UInt32
  getter writes = [] of Tuple(UInt32, UInt32, Bytes)
  property? success = true
  property response_code : Matter::InteractionModel::StatusCode? = nil
  property acl_entries = [] of Matter::Cluster::AccessControl::AccessControlEntry
  property parts_list = [] of UInt16
  getter server_lists = Hash(UInt16, Array(UInt32)).new
  getter group_memberships = Hash(UInt16, Array(Matter::DataType::GroupId)).new
  getter binding_entries = Hash(UInt16, Array(Matter::Cluster::Binding::Target)).new
  property key_set_ids = [] of UInt16

  def initialize(@client : Matter::Controller::Client)
    super(@client)
  end

  def invoke(
    session : Matter::Session::SecureContext,
    peer : Socket::IPAddress,
    endpoint_id : UInt16,
    cluster_id : UInt32,
    command_id : UInt32,
    fields : Bytes = Bytes.empty,
  ) : Matter::InteractionModel::InvokeResponseMessage
    @commands << command_id
    response_id = command_id
    response_fields = nil.as(TLV::Any?)
    if cluster_id == Matter::Cluster::Groups::CLUSTER_ID
      if command_id == Matter::Cluster::Groups::CMD_ADD_GROUP
        request = Matter::Cluster::Groups::AddGroupRequest.from_slice(fields)
        response_id = Matter::Cluster::Groups::CMD_ADD_GROUP_RESPONSE
        response_fields = TLV::Any.from_slice(Matter::Cluster::Groups::AddGroupResponse.new(Matter::InteractionModel::StatusCode::Success, request.group_id).to_slice)
      elsif command_id == Matter::Cluster::Groups::CMD_GET_GROUP_MEMBERSHIP
        response_id = Matter::Cluster::Groups::CMD_GET_GROUP_MEMBERSHIP_RESPONSE
        groups = @group_memberships[endpoint_id]? || [] of Matter::DataType::GroupId
        response_fields = TLV::Any.from_slice(Matter::Cluster::Groups::GetGroupMembershipResponse.new(nil, groups).to_slice)
      end
    elsif cluster_id == Matter::Cluster::GroupKeyManagement::CLUSTER_ID &&
          command_id == Matter::Cluster::GroupKeyManagement::CMD_KEY_SET_READ_ALL_INDICES
      response_id = Matter::Cluster::GroupKeyManagement::CMD_KEY_SET_READ_ALL_INDICES_RESPONSE
      response_fields = TLV::Any.from_slice(Matter::Cluster::GroupKeyManagement::KeySetReadAllIndicesResponse.new(@key_set_ids).to_slice)
    end
    path = Matter::InteractionModel::CommandPath.new(endpoint: endpoint_id, cluster: cluster_id, command: response_id)
    if response_fields
      data = Matter::InteractionModel::CommandDataIBTlv.new(path, response_fields)
      return Matter::InteractionModel::InvokeResponseMessage.new(invoke_responses: [Matter::InteractionModel::InvokeResponseIB.new(command_data: data)])
    end
    code = @response_code || (@success ? Matter::InteractionModel::StatusCode::Success : Matter::InteractionModel::StatusCode::Failure)
    status = Matter::InteractionModel::CommandStatusIB.new(path, Matter::InteractionModel::StatusIB.new(code.value))
    Matter::InteractionModel::InvokeResponseMessage.new(invoke_responses: [Matter::InteractionModel::InvokeResponseIB.new(command_status: status)])
  end

  def read_attribute(
    session : Matter::Session::SecureContext,
    peer : Socket::IPAddress,
    endpoint_id : UInt16,
    cluster_id : UInt32,
    attribute_id : UInt32,
  ) : Matter::InteractionModel::ReportDataMessage
    value = if cluster_id == Matter::Cluster::Descriptor::CLUSTER_ID
              if attribute_id == Matter::Cluster::Descriptor::ATTR_PARTS_LIST
                @parts_list.to_tlv
              else
                (@server_lists[endpoint_id]? || [] of UInt32).to_tlv
              end
            elsif cluster_id == Matter::Cluster::Binding::CLUSTER_ID
              (@binding_entries[endpoint_id]? || [] of Matter::Cluster::Binding::Target).to_tlv
            elsif cluster_id == Matter::Cluster::GroupKeyManagement::CLUSTER_ID
              ([] of Matter::Cluster::GroupKeyManagement::GroupKeyMapStruct).to_tlv
            else
              @acl_entries.to_tlv
            end
    path = Matter::InteractionModel::AttributePath.new(endpoint: endpoint_id, cluster: cluster_id, attribute: attribute_id)
    data = Matter::InteractionModel::AttributeDataIB.new(path: path, data: TLV::Any.from_slice(value))
    Matter::InteractionModel::ReportDataMessage.new(attribute_reports: [Matter::InteractionModel::AttributeReportIB.new(attribute_data: data)])
  end

  def write_attribute(
    session : Matter::Session::SecureContext,
    peer : Socket::IPAddress,
    endpoint_id : UInt16,
    cluster_id : UInt32,
    attribute_id : UInt32,
    value : Bytes,
    timed_request : Bool = false,
    suppress_response : Bool = false,
  ) : Matter::InteractionModel::WriteResponseMessage
    @writes << {cluster_id, attribute_id, value}
    path = Matter::InteractionModel::AttributePath.new(endpoint: endpoint_id, cluster: cluster_id, attribute: attribute_id)
    code = @response_code || (@success ? Matter::InteractionModel::StatusCode::Success : Matter::InteractionModel::StatusCode::Failure)
    status = Matter::InteractionModel::StatusIB.new(code.value)
    Matter::InteractionModel::WriteResponseMessage.new([Matter::InteractionModel::AttributeStatusIB.new(path, status)])
  end
end

private def datastore_session : Matter::Session::SecureContext
  Matter::Session::SecureContext.new(
    session_id: 1_u16,
    peer_session_id: 1_u16,
    session_type: Matter::Session::SessionType::Unicast,
    encryption_key: Bytes.new(16),
    decryption_key: Bytes.new(16)
  )
end

describe Matter::Controller::DatastoreSynchronizer do
  it "reconciles Descriptor PartsList before completing a pending node" do
    client = Matter::Controller::Client.new
    im = DatastoreImClient.new(client)
    im.parts_list = [2_u16, 3_u16]
    store = Datastore.new(Matter::DataType::EndpointNumber.new(0_u16))
    pending = Datastore::DatastoreStatusEntryStruct.new(Datastore::DatastoreStateEnum::Pending, 0_u32, 0_u8)
    store.node_list = [Datastore::DatastoreNodeInformationEntryStruct.new(0x100_u64, "Node", pending)]
    store.record_endpoint(0x100_u64, 1_u16, "Gone")
    store.record_endpoint(0x100_u64, 2_u16, "Kept")

    Matter::Controller::DatastoreSynchronizer.new(im).sync_node(store, 0x100_u64, datastore_session,
      Socket::IPAddress.new("127.0.0.1", 5540))
    store.node_endpoint_list.map(&.endpoint_id).sort!.should eq([2_u16, 3_u16])
    store.node_endpoint_list.find(&.endpoint_id.==(2_u16)).try(&.friendly_name).should eq("Kept")
    store.node_endpoint_list.find(&.endpoint_id.==(3_u16)).try(&.friendly_name).should eq("")
    store.node_list.first.commissioning_status_entry.state.should eq(Datastore::DatastoreStateEnum::Committed)
  ensure
    client.try(&.close)
  end

  it "imports operational groups, bindings, key sets, and ACLs during RefreshNode" do
    client = Matter::Controller::Client.new
    im = DatastoreImClient.new(client)
    im.parts_list = [1_u16]
    im.server_lists[0_u16] = [Matter::Cluster::GroupKeyManagement::CLUSTER_ID,
                              Matter::Cluster::AccessControl::CLUSTER_ID]
    im.server_lists[1_u16] = [Matter::Cluster::Groups::CLUSTER_ID, Matter::Cluster::Binding::CLUSTER_ID]
    im.group_memberships[1_u16] = [Matter::DataType::GroupId.new(5_u16)]
    im.binding_entries[1_u16] = [Matter::Cluster::Binding::Target.new(node: 0x200_u64)]
    im.key_set_ids = [0_u16, 7_u16]
    im.acl_entries = [Matter::Cluster::AccessControl::AccessControlEntry.new(
      Matter::Cluster::AccessControl::AccessControlEntryPrivilege::View,
      Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
      [0x200_u64], nil)]
    store = Datastore.new(Matter::DataType::EndpointNumber.new(0_u16))
    pending = Datastore::DatastoreStatusEntryStruct.new(Datastore::DatastoreStateEnum::Pending, 0_u32, 0_u8)
    store.node_list = [Datastore::DatastoreNodeInformationEntryStruct.new(0x100_u64, "Node", pending)]

    Matter::Controller::DatastoreSynchronizer.new(im).sync_node(store, 0x100_u64, datastore_session,
      Socket::IPAddress.new("127.0.0.1", 5540))
    store.endpoint_group_id_list.map(&.group_id).should eq([5_u16])
    store.endpoint_binding_list.first.binding.node.should eq(0x200_u64)
    store.node_key_set_list.map(&.group_key_set_id).should eq([0_u16, 7_u16])
    store.node_acl_list.first.acl_entry.subjects.should eq([0x200_u64])
    store.node_list.first.commissioning_status_entry.state.should eq(Datastore::DatastoreStateEnum::Committed)
  ensure
    client.try(&.close)
  end

  it "replaces a changed ACL instead of leaving stale access after restart" do
    client = Matter::Controller::Client.new
    im = DatastoreImClient.new(client)
    store = Matter::Cluster::JointFabricDatastore.new(Matter::DataType::EndpointNumber.new(0_u16))
    group_subject = Matter::DataType::NodeId.from_case_authenticated_tag(
      Matter::DataType::CaseAuthenticatedTag.create(1_u16, 1_u16)).id
    old_acl = Datastore::DatastoreAccessControlEntryStruct.new(
      Datastore::DatastoreAccessControlEntryPrivilegeEnum::Administer,
      Datastore::DatastoreAccessControlEntryAuthModeEnum::CASE,
      [group_subject], nil
    )
    old_wire = Matter::Cluster::AccessControl::AccessControlEntry.new(
      privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer,
      auth_mode: Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
      subjects: [group_subject],
      targets: nil
    )
    im.acl_entries = [old_wire]
    committed = Datastore::DatastoreStatusEntryStruct.new(Datastore::DatastoreStateEnum::Committed, 0_u32, 0_u8)
    acl_entry = Datastore::DatastoreACLEntryStruct.new(0x100_u64, 7_u16, old_acl, committed)
    acl_entry.associated_group_id = 1_u16
    store.node_acl_list = [acl_entry]
    store.group_list = [Datastore::DatastoreGroupInformationEntryStruct.new(1_u64, "group", nil, 1_u16, 1_u16,
      Datastore::DatastoreAccessControlEntryPrivilegeEnum::Administer)]
    store.update_group(Datastore::UpdateGroupRequest.new(1_u16, nil, nil, nil, nil,
      Datastore::DatastoreAccessControlEntryPrivilegeEnum::View)).success?.should be_true
    restored = Datastore.new(Matter::DataType::EndpointNumber.new(0_u16))
    restored.restore_state(store.save_state.as(Matter::Storage::Document))
    restored.node_acl_list.first.prior_acl_entry.should_not be_nil
    Datastore::DatastoreACLEntryStruct.from_slice(restored.node_acl_list.first.to_slice).prior_acl_entry.should be_nil

    Matter::Controller::DatastoreSynchronizer.new(im).sync_node(restored, 0x100_u64, datastore_session,
      Socket::IPAddress.new("127.0.0.1", 5540))
    acl_write = im.writes.find { |write| write[0] == Matter::Cluster::AccessControl::CLUSTER_ID } ||
                raise "No ACL write was sent"
    written = Array(Matter::Cluster::AccessControl::AccessControlEntry).from_tlv(acl_write[2])
    written.size.should eq(1)
    written.first.privilege.should eq(Matter::Cluster::AccessControl::AccessControlEntryPrivilege::View)
    restored.node_acl_list.first.status_entry.state.should eq(Datastore::DatastoreStateEnum::Committed)
    restored.node_acl_list.first.prior_acl_entry.should be_nil
  ensure
    client.try(&.close)
  end

  it "keeps the prior ACL journal when the target rejects replacement" do
    client = Matter::Controller::Client.new
    im = DatastoreImClient.new(client)
    im.success = false
    store = Datastore.new(Matter::DataType::EndpointNumber.new(0_u16))
    old_acl = Datastore::DatastoreAccessControlEntryStruct.new(
      Datastore::DatastoreAccessControlEntryPrivilegeEnum::Administer,
      Datastore::DatastoreAccessControlEntryAuthModeEnum::CASE, [1_u64], nil)
    new_acl = Datastore::DatastoreAccessControlEntryStruct.new(
      Datastore::DatastoreAccessControlEntryPrivilegeEnum::View,
      Datastore::DatastoreAccessControlEntryAuthModeEnum::CASE, [1_u64], nil)
    pending = Datastore::DatastoreStatusEntryStruct.new(Datastore::DatastoreStateEnum::Pending, 0_u32, 0_u8)
    entry = Datastore::DatastoreACLEntryStruct.new(0x100_u64, 7_u16, new_acl, pending)
    entry.prior_acl_entry = old_acl
    store.node_acl_list = [entry]

    Matter::Controller::DatastoreSynchronizer.new(im).sync_node(store, 0x100_u64, datastore_session,
      Socket::IPAddress.new("127.0.0.1", 5540))
    store.node_acl_list.first.status_entry.state.should eq(Datastore::DatastoreStateEnum::CommitFailed)
    store.node_acl_list.first.prior_acl_entry.should eq(old_acl)
    restored = Datastore.new(Matter::DataType::EndpointNumber.new(0_u16))
    restored.restore_state(store.save_state.as(Matter::Storage::Document))
    restored.node_acl_list.first.prior_acl_entry.should eq(old_acl)
  ensure
    client.try(&.close)
  end

  it "preserves a target's terminal write status and prunes the failed ACL on RefreshNode" do
    client = Matter::Controller::Client.new
    im = DatastoreImClient.new(client)
    im.response_code = Matter::InteractionModel::StatusCode::ResourceExhausted
    store = Datastore.new(Matter::DataType::EndpointNumber.new(0_u16))
    acl = Datastore::DatastoreAccessControlEntryStruct.new(
      Datastore::DatastoreAccessControlEntryPrivilegeEnum::View,
      Datastore::DatastoreAccessControlEntryAuthModeEnum::CASE, [1_u64], nil)
    pending = Datastore::DatastoreStatusEntryStruct.new(Datastore::DatastoreStateEnum::Pending, 0_u32, 0_u8)
    store.node_acl_list = [Datastore::DatastoreACLEntryStruct.new(0x100_u64, 7_u16, acl, pending)]

    Matter::Controller::DatastoreSynchronizer.new(im).sync_node(store, 0x100_u64, datastore_session,
      Socket::IPAddress.new("127.0.0.1", 5540))
    store.node_acl_list.first.status_entry.state.should eq(Datastore::DatastoreStateEnum::CommitFailed)
    store.node_acl_list.first.status_entry.failure_code.should eq(Matter::InteractionModel::StatusCode::ResourceExhausted.value)

    committed = Datastore::DatastoreStatusEntryStruct.new(Datastore::DatastoreStateEnum::Committed, 0_u32, 0_u8)
    store.node_list = [Datastore::DatastoreNodeInformationEntryStruct.new(0x100_u64, "Node", committed)]
    store.refresh_node(Datastore::RefreshNodeRequest.new(0x100_u64)).success?.should be_true
    store.node_acl_list.should be_empty
  ensure
    client.try(&.close)
  end

  it "retains a target's recoverable invoke status for retry on RefreshNode" do
    client = Matter::Controller::Client.new
    im = DatastoreImClient.new(client)
    im.response_code = Matter::InteractionModel::StatusCode::Busy
    store = Datastore.new(Matter::DataType::EndpointNumber.new(0_u16))
    pending = Datastore::DatastoreStatusEntryStruct.new(Datastore::DatastoreStateEnum::Pending, 0_u32, 0_u8)
    key_set = Datastore::DatastoreGroupKeySetStruct.new(7_u16,
      Datastore::DatastoreGroupKeySecurityPolicyEnum::TrustFirst,
      Bytes.new(16, 0xAA_u8), 1_u64, nil, nil, nil, nil)
    store.group_key_set_list = [key_set]
    store.node_key_set_list = [Datastore::DatastoreNodeKeySetEntryStruct.new(0x100_u64, 7_u16, pending)]

    Matter::Controller::DatastoreSynchronizer.new(im).sync_node(store, 0x100_u64, datastore_session,
      Socket::IPAddress.new("127.0.0.1", 5540))
    store.node_key_set_list.first.status_entry.state.should eq(Datastore::DatastoreStateEnum::CommitFailed)
    store.node_key_set_list.first.status_entry.failure_code.should eq(Matter::InteractionModel::StatusCode::Busy.value)

    committed = Datastore::DatastoreStatusEntryStruct.new(Datastore::DatastoreStateEnum::Committed, 0_u32, 0_u8)
    store.node_list = [Datastore::DatastoreNodeInformationEntryStruct.new(0x100_u64, "Node", committed)]
    store.refresh_node(Datastore::RefreshNodeRequest.new(0x100_u64)).success?.should be_true
    store.node_key_set_list.first.status_entry.state.should eq(Datastore::DatastoreStateEnum::Pending)
    store.node_key_set_list.first.status_entry.failure_code.should eq(0_u8)
  ensure
    client.try(&.close)
  end

  it "keeps failed deletion intent for recoverable codes and drops terminal deletions" do
    store = Datastore.new(Matter::DataType::EndpointNumber.new(0_u16))
    committed = Datastore::DatastoreStatusEntryStruct.new(Datastore::DatastoreStateEnum::Committed, 0_u32, 0_u8)
    deleting = Datastore::DatastoreStatusEntryStruct.new(Datastore::DatastoreStateEnum::DeletePending, 0_u32, 0_u8)
    target = Datastore::DatastoreBindingTargetStruct.new(node: 0x200_u64)
    store.node_list = [Datastore::DatastoreNodeInformationEntryStruct.new(0x100_u64, "Node", committed)]
    store.endpoint_binding_list = [
      Datastore::DatastoreEndpointBindingEntryStruct.new(0x100_u64, 1_u16, 7_u16, target, deleting),
      Datastore::DatastoreEndpointBindingEntryStruct.new(0x100_u64, 1_u16, 8_u16, target, deleting),
    ]
    store.complete_binding(0x100_u64, 1_u16, 7_u16, Matter::InteractionModel::StatusCode::Busy.value)
    store.complete_binding(0x100_u64, 1_u16, 8_u16, Matter::InteractionModel::StatusCode::ConstraintError.value)

    store.refresh_node(Datastore::RefreshNodeRequest.new(0x100_u64)).success?.should be_true
    store.endpoint_binding_list.map(&.list_id).should eq([7_u16])
    store.endpoint_binding_list.first.status_entry.state.should eq(Datastore::DatastoreStateEnum::DeletePending)
    store.endpoint_binding_list.first.status_entry.failure_code.should eq(0_u8)
  end

  it "applies a pending key set and marks it committed only after success" do
    client = Matter::Controller::Client.new
    im = DatastoreImClient.new(client)
    store = Matter::Cluster::JointFabricDatastore.new(Matter::DataType::EndpointNumber.new(0_u16))
    key_set = Matter::Cluster::JointFabricDatastore::DatastoreGroupKeySetStruct.new(
      1_u16,
      Matter::Cluster::JointFabricDatastore::DatastoreGroupKeySecurityPolicyEnum::TrustFirst,
      Bytes.new(16, 0xAA_u8), 1_u64, nil, nil, nil, nil
    )
    store.group_key_set_list = [key_set]
    pending = Matter::Cluster::JointFabricDatastore::DatastoreStatusEntryStruct.new(
      Matter::Cluster::JointFabricDatastore::DatastoreStateEnum::Pending, 0_u32, 0_u8
    )
    store.node_list = [Matter::Cluster::JointFabricDatastore::DatastoreNodeInformationEntryStruct.new(0x100_u64, "test", pending)]
    store.node_key_set_list = [Matter::Cluster::JointFabricDatastore::DatastoreNodeKeySetEntryStruct.new(0x100_u64, 1_u16, pending)]

    Matter::Controller::DatastoreSynchronizer.new(im).sync_node(store, 0x100_u64, datastore_session, Socket::IPAddress.new("127.0.0.1", 5540))
    im.commands.should eq([Matter::Cluster::GroupKeyManagement::CMD_KEY_SET_WRITE])
    store.node_key_set_list.first.status_entry.state.should eq(Matter::Cluster::JointFabricDatastore::DatastoreStateEnum::Committed)
    store.node_list.first.commissioning_status_entry.state.should eq(Matter::Cluster::JointFabricDatastore::DatastoreStateEnum::Committed)
  ensure
    client.try(&.close)
  end

  it "marks a rejected device operation as failed" do
    client = Matter::Controller::Client.new
    im = DatastoreImClient.new(client)
    im.success = false
    store = Matter::Cluster::JointFabricDatastore.new(Matter::DataType::EndpointNumber.new(0_u16))
    pending = Matter::Cluster::JointFabricDatastore::DatastoreStatusEntryStruct.new(
      Matter::Cluster::JointFabricDatastore::DatastoreStateEnum::DeletePending, 0_u32, 0_u8
    )
    store.node_key_set_list = [Matter::Cluster::JointFabricDatastore::DatastoreNodeKeySetEntryStruct.new(0x100_u64, 1_u16, pending)]

    Matter::Controller::DatastoreSynchronizer.new(im).sync_node(store, 0x100_u64, datastore_session, Socket::IPAddress.new("127.0.0.1", 5540))
    im.commands.should eq([Matter::Cluster::GroupKeyManagement::CMD_KEY_SET_REMOVE])
    store.node_key_set_list.first.status_entry.state.should eq(Matter::Cluster::JointFabricDatastore::DatastoreStateEnum::DeletePending)
    store.node_key_set_list.first.status_entry.failure_code.should_not eq(0_u8)
  ensure
    client.try(&.close)
  end

  it "writes a pending binding to the target endpoint before completion" do
    client = Matter::Controller::Client.new
    im = DatastoreImClient.new(client)
    store = Matter::Cluster::JointFabricDatastore.new(Matter::DataType::EndpointNumber.new(0_u16))
    pending = Matter::Cluster::JointFabricDatastore::DatastoreStatusEntryStruct.new(
      Matter::Cluster::JointFabricDatastore::DatastoreStateEnum::Pending, 0_u32, 0_u8
    )
    target = Matter::Cluster::JointFabricDatastore::DatastoreBindingTargetStruct.new(node: 0x200_u64)
    store.endpoint_binding_list = [Matter::Cluster::JointFabricDatastore::DatastoreEndpointBindingEntryStruct.new(0x100_u64, 1_u16, 7_u16, target, pending)]

    Matter::Controller::DatastoreSynchronizer.new(im).sync_node(store, 0x100_u64, datastore_session, Socket::IPAddress.new("127.0.0.1", 5540))
    im.writes.size.should eq(1)
    im.writes.first[0].should eq(Matter::Cluster::Binding::CLUSTER_ID)
    bindings = Array(Matter::Cluster::Binding::Target).from_tlv(im.writes.first[2])
    bindings.first.node.should eq(0x200_u64)
    store.endpoint_binding_list.first.status_entry.state.should eq(Matter::Cluster::JointFabricDatastore::DatastoreStateEnum::Committed)
  ensure
    client.try(&.close)
  end

  it "writes the group key map and adds pending group membership" do
    client = Matter::Controller::Client.new
    im = DatastoreImClient.new(client)
    store = Matter::Cluster::JointFabricDatastore.new(Matter::DataType::EndpointNumber.new(0_u16))
    store.group_list = [Matter::Cluster::JointFabricDatastore::DatastoreGroupInformationEntryStruct.new(
      2_u64, "kitchen", 1_u16, nil, nil,
      Matter::Cluster::JointFabricDatastore::DatastoreAccessControlEntryPrivilegeEnum::Operate
    )]
    pending = Matter::Cluster::JointFabricDatastore::DatastoreStatusEntryStruct.new(
      Matter::Cluster::JointFabricDatastore::DatastoreStateEnum::Pending, 0_u32, 0_u8
    )
    store.endpoint_group_id_list = [Matter::Cluster::JointFabricDatastore::DatastoreEndpointGroupIDEntryStruct.new(0x100_u64, 1_u16, 2_u16, pending)]

    Matter::Controller::DatastoreSynchronizer.new(im).sync_node(store, 0x100_u64, datastore_session, Socket::IPAddress.new("127.0.0.1", 5540))
    im.writes.first[0].should eq(Matter::Cluster::GroupKeyManagement::CLUSTER_ID)
    mappings = Array(Matter::Cluster::GroupKeyManagement::GroupKeyMapStruct).from_tlv(im.writes.first[2])
    mappings.first.group_id.should eq(2_u16)
    mappings.first.group_key_set_id.should eq(1_u16)
    im.commands.should eq([Matter::Cluster::Groups::CMD_ADD_GROUP])
    store.endpoint_group_id_list.first.status_entry.state.should eq(Matter::Cluster::JointFabricDatastore::DatastoreStateEnum::Committed)
  ensure
    client.try(&.close)
  end
end

describe Matter::Cluster::Binding do
  it "isolates and persists bindings by fabric" do
    binding = Matter::Cluster::Binding.new(Matter::DataType::EndpointNumber.new(1_u16))
    binding.request_fabric_index = 1_u8
    binding.binding = [Matter::Cluster::Binding::Target.new(node: 0x100_u64)]
    binding.request_fabric_index = 2_u8
    binding.binding = [Matter::Cluster::Binding::Target.new(group: 2_u16)]

    document = binding.save_state.as(Matter::Storage::Document)
    restored = Matter::Cluster::Binding.new(Matter::DataType::EndpointNumber.new(1_u16))
    restored.restore_state(document)
    restored.request_fabric_index = 1_u8
    restored.binding.map(&.node).should eq([0x100_u64])
    restored.request_fabric_index = 2_u8
    restored.binding.map(&.group).should eq([2_u16])
  end
end
