require "../spec_helper"
require "../../src/matter/controller"
require "../../src/matter/cluster/on_off"
require "../../src/matter/cluster/level_control"

private alias Datastore = Matter::Cluster::JointFabricDatastore

private class DatastoreImClient < Matter::Controller::ImClient
  getter commands = [] of UInt32
  getter command_paths = [] of Tuple(UInt32, UInt32)
  getter writes = [] of Tuple(UInt32, UInt32, Bytes)
  getter write_response_codes = [] of Matter::InteractionModel::StatusCode
  property? success = true
  property response_code : Matter::InteractionModel::StatusCode? = nil
  property group_response_id : Matter::DataType::GroupId? = nil
  property wrong_data_command_id : UInt32? = nil
  property acl_entries = [] of Matter::Cluster::AccessControl::AccessControlEntry
  property parts_list = [] of UInt16
  getter server_lists = Hash(UInt16, Array(UInt32)).new
  getter client_lists = Hash(UInt16, Array(UInt32)).new
  getter group_memberships = Hash(UInt16, Array(Matter::DataType::GroupId)).new
  getter binding_entries = Hash(UInt16, Array(Matter::Cluster::Binding::Target)).new
  property key_set_ids = [] of UInt16
  property groupcast_memberships = [] of Matter::Cluster::Groupcast::MembershipStruct
  property? groupcast_adopted = false
  property? groupcast_adoption_supported = true
  property? reject_groupcast_adoption = false
  property? reject_unadvertised_commands = false
  property current_fabric_index = 2_u8
  property group_key_map = [] of Matter::Cluster::GroupKeyManagement::GroupKeyMapStruct

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
    @command_paths << {cluster_id, command_id}
    if @reject_unadvertised_commands && !(@server_lists[endpoint_id]? || [] of UInt32).includes?(cluster_id)
      path = Matter::InteractionModel::CommandPath.new(endpoint: endpoint_id, cluster: cluster_id, command: command_id)
      status = Matter::InteractionModel::CommandStatusIB.new(path,
        Matter::InteractionModel::StatusIB.new(Matter::InteractionModel::StatusCode::UnsupportedCluster.value))
      return Matter::InteractionModel::InvokeResponseMessage.new(invoke_responses: [Matter::InteractionModel::InvokeResponseIB.new(command_status: status)])
    end
    response_id = command_id
    response_fields = nil.as(TLV::Any?)
    if cluster_id == Matter::Cluster::Groups::CLUSTER_ID
      if command_id == Matter::Cluster::Groups::CMD_ADD_GROUP
        request = Matter::Cluster::Groups::AddGroupRequest.from_slice(fields)
        response_id = Matter::Cluster::Groups::CMD_ADD_GROUP_RESPONSE
        response_fields = TLV::Any.from_slice(Matter::Cluster::Groups::AddGroupResponse.new(Matter::InteractionModel::StatusCode::Success, @group_response_id || request.group_id).to_slice)
      elsif command_id == Matter::Cluster::Groups::CMD_REMOVE_GROUP
        request = Matter::Cluster::Groups::RemoveGroupRequest.from_slice(fields)
        response_id = Matter::Cluster::Groups::CMD_REMOVE_GROUP_RESPONSE
        response_fields = TLV::Any.from_slice(Matter::Cluster::Groups::RemoveGroupResponse.new(Matter::InteractionModel::StatusCode::Success, @group_response_id || request.group_id).to_slice)
      elsif command_id == Matter::Cluster::Groups::CMD_GET_GROUP_MEMBERSHIP
        response_id = Matter::Cluster::Groups::CMD_GET_GROUP_MEMBERSHIP_RESPONSE
        groups = @group_memberships[endpoint_id]? || [] of Matter::DataType::GroupId
        response_fields = TLV::Any.from_slice(Matter::Cluster::Groups::GetGroupMembershipResponse.new(nil, groups).to_slice)
      end
    elsif cluster_id == Matter::Cluster::GroupKeyManagement::CLUSTER_ID &&
          command_id == Matter::Cluster::GroupKeyManagement::CMD_KEY_SET_READ_ALL_INDICES
      response_id = Matter::Cluster::GroupKeyManagement::CMD_KEY_SET_READ_ALL_INDICES_RESPONSE
      response_fields = TLV::Any.from_slice(Matter::Cluster::GroupKeyManagement::KeySetReadAllIndicesResponse.new(@key_set_ids).to_slice)
    elsif cluster_id == Matter::Cluster::Groupcast::CLUSTER_ID
      if command_id == Matter::Cluster::Groupcast::CMD_JOIN_GROUP
        request = Matter::Cluster::Groupcast::JoinGroupRequest.from_slice(fields)
        existing = @groupcast_memberships.find(&.group_id.==(request.group_id))
        endpoints = ((existing.try(&.endpoints) || [] of UInt16) + request.endpoints).uniq
        @groupcast_memberships.reject! { |entry| entry.group_id == request.group_id }
        @groupcast_memberships << Matter::Cluster::Groupcast::MembershipStruct.new(request.group_id,
          endpoints, request.key_set_id, false, fabric_index: 1_u8)
      elsif command_id == Matter::Cluster::Groupcast::CMD_LEAVE_GROUP
        request = Matter::Cluster::Groupcast::LeaveGroupRequest.from_slice(fields)
        existing = @groupcast_memberships.find(&.group_id.==(request.group_id))
        removed = existing.try(&.endpoints.select { |endpoint| (request.endpoints || [] of UInt16).includes?(endpoint) }) || [] of UInt16
        if existing
          existing.endpoints.reject! { |endpoint| removed.includes?(endpoint) }
          @groupcast_memberships.reject! { |entry| entry.group_id == request.group_id } if existing.endpoints.empty?
        end
        response_id = Matter::Cluster::Groupcast::CMD_LEAVE_GROUP_RESPONSE
        response_fields = TLV::Any.from_slice(Matter::Cluster::Groupcast::LeaveGroupResponse.new(
          request.group_id, removed).to_slice)
      end
    end
    response_id = @wrong_data_command_id || response_id if response_fields
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
    if cluster_id == Matter::Cluster::GroupKeyManagement::CLUSTER_ID &&
       attribute_id == Matter::Cluster::GroupKeyManagement::ATTR_GROUPCAST_ADOPTION &&
       !@groupcast_adoption_supported
      path = Matter::InteractionModel::AttributePath.new(endpoint: endpoint_id, cluster: cluster_id, attribute: attribute_id)
      status = Matter::InteractionModel::StatusIB.new(Matter::InteractionModel::StatusCode::UnsupportedAttribute.value)
      return Matter::InteractionModel::ReportDataMessage.new(attribute_reports: [
        Matter::InteractionModel::AttributeReportIB.new(attribute_status: Matter::InteractionModel::AttributeStatusIB.new(path, status)),
      ])
    end
    value = if cluster_id == Matter::Cluster::Descriptor::CLUSTER_ID
              if attribute_id == Matter::Cluster::Descriptor::ATTR_PARTS_LIST
                @parts_list.to_tlv
              elsif attribute_id == Matter::Cluster::Descriptor::ATTR_CLIENT_LIST
                (@client_lists[endpoint_id]? || [] of UInt32).to_tlv
              else
                (@server_lists[endpoint_id]? || [] of UInt32).to_tlv
              end
            elsif cluster_id == Matter::Cluster::Binding::CLUSTER_ID
              (@binding_entries[endpoint_id]? || [] of Matter::Cluster::Binding::Target).to_tlv
            elsif cluster_id == Matter::Cluster::GroupKeyManagement::CLUSTER_ID
              if attribute_id == Matter::Cluster::GroupKeyManagement::ATTR_GROUPCAST_ADOPTION
                (@groupcast_adopted ? [Matter::Cluster::GroupKeyManagement::GroupcastAdoptionStruct.new(true, 1_u8)] : [] of Matter::Cluster::GroupKeyManagement::GroupcastAdoptionStruct).to_tlv
              else
                @group_key_map.to_tlv
              end
            elsif cluster_id == Matter::Cluster::OperationalCredentials::CLUSTER_ID &&
                  attribute_id == Matter::Cluster::OperationalCredentials::ATTR_CURRENT_FABRIC_INDEX
              @current_fabric_index.to_tlv
            elsif cluster_id == Matter::Cluster::Groupcast::CLUSTER_ID
              @groupcast_memberships.to_tlv
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
    adoption_write = cluster_id == Matter::Cluster::GroupKeyManagement::CLUSTER_ID &&
                     attribute_id == Matter::Cluster::GroupKeyManagement::ATTR_GROUPCAST_ADOPTION
    invalid_group_key_map = cluster_id == Matter::Cluster::GroupKeyManagement::CLUSTER_ID &&
                            attribute_id == Matter::Cluster::GroupKeyManagement::ATTR_GROUP_KEY_MAP &&
                            Array(Matter::Cluster::GroupKeyManagement::GroupKeyMapStruct).from_tlv(value)
                              .any? { |entry| entry.fabric_index != @current_fabric_index }
    if adoption_write && !@reject_groupcast_adoption
      @groupcast_adopted = Array(Matter::Cluster::GroupKeyManagement::GroupcastAdoptionStruct).from_tlv(value).any?(&.groupcast_adopted?)
    end
    path = Matter::InteractionModel::AttributePath.new(endpoint: endpoint_id, cluster: cluster_id, attribute: attribute_id)
    code = @write_response_codes.shift? || @response_code || ((@success && !invalid_group_key_map && !(@reject_groupcast_adoption && adoption_write)) ? Matter::InteractionModel::StatusCode::Success : Matter::InteractionModel::StatusCode::Failure)
    if cluster_id == Matter::Cluster::AccessControl::CLUSTER_ID && code == Matter::InteractionModel::StatusCode::Success
      @acl_entries = Array(Matter::Cluster::AccessControl::AccessControlEntry).from_tlv(value)
    end
    if cluster_id == Matter::Cluster::Binding::CLUSTER_ID && code == Matter::InteractionModel::StatusCode::Success
      @binding_entries[endpoint_id] = Array(Matter::Cluster::Binding::Target).from_tlv(value)
    end
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
  it "rejects another response command while refreshing Groups membership" do
    client = Matter::Controller::Client.new
    im = DatastoreImClient.new(client)
    im.parts_list = [1_u16]
    im.server_lists[1_u16] = [Matter::Cluster::Groups::CLUSTER_ID]
    im.group_memberships[1_u16] = [Matter::DataType::GroupId.new(5_u16)]
    im.wrong_data_command_id = Matter::Cluster::Groups::CMD_ADD_GROUP_RESPONSE
    store = Datastore.new(Matter::DataType::EndpointNumber.new(0_u16))
    pending = Datastore::DatastoreStatusEntryStruct.new(Datastore::DatastoreStateEnum::Pending, 0_u32, 0_u8)
    store.node_list = [Datastore::DatastoreNodeInformationEntryStruct.new(0x100_u64, "Node", pending)]

    expect_raises(Matter::ProtocolError, /response command/) do
      Matter::Controller::DatastoreSynchronizer.new(im).sync_node(store, 0x100_u64, datastore_session,
        Socket::IPAddress.new("127.0.0.1", 5540))
    end
    store.endpoint_group_id_list.should be_empty
  ensure
    client.try(&.close)
  end

  it "does not commit a group from another response command" do
    client = Matter::Controller::Client.new
    im = DatastoreImClient.new(client)
    im.wrong_data_command_id = Matter::Cluster::Groups::CMD_REMOVE_GROUP_RESPONSE
    store = Datastore.new(Matter::DataType::EndpointNumber.new(0_u16))
    store.group_list = [Datastore::DatastoreGroupInformationEntryStruct.new(
      2_u64, "kitchen", 1_u16, nil, nil, Datastore::DatastoreAccessControlEntryPrivilegeEnum::Operate)]
    pending = Datastore::DatastoreStatusEntryStruct.new(Datastore::DatastoreStateEnum::Pending, 0_u32, 0_u8)
    store.endpoint_group_id_list = [Datastore::DatastoreEndpointGroupIDEntryStruct.new(0x100_u64, 1_u16, 2_u16, pending)]

    Matter::Controller::DatastoreSynchronizer.new(im).sync_node(store, 0x100_u64, datastore_session,
      Socket::IPAddress.new("127.0.0.1", 5540))
    store.endpoint_group_id_list.first.status_entry.state.should eq(Datastore::DatastoreStateEnum::CommitFailed)
  ensure
    client.try(&.close)
  end

  it "records adoption rejection against the pending group and does not invoke JoinGroup" do
    client = Matter::Controller::Client.new
    im = DatastoreImClient.new(client)
    im.server_lists[0_u16] = [Matter::Cluster::Groupcast::CLUSTER_ID]
    im.reject_groupcast_adoption = true
    store = Datastore.new(Matter::DataType::EndpointNumber.new(0_u16))
    pending = Datastore::DatastoreStatusEntryStruct.new(Datastore::DatastoreStateEnum::Pending, 0_u32, 0_u8)
    store.group_list = [Datastore::DatastoreGroupInformationEntryStruct.new(0x1234_u64,
      "Shared", 7_u16, nil, nil, Datastore::DatastoreAccessControlEntryPrivilegeEnum::Operate)]
    store.endpoint_group_id_list = [Datastore::DatastoreEndpointGroupIDEntryStruct.new(
      0x100_u64, 1_u16, 0x1234_u16, pending)]

    Matter::Controller::DatastoreSynchronizer.new(im).sync_node(store, 0x100_u64, datastore_session,
      Socket::IPAddress.new("127.0.0.1", 5540))
    im.groupcast_adopted?.should be_false
    im.command_paths.any? { |path| path[0] == Matter::Cluster::Groupcast::CLUSTER_ID }.should be_false
    store.endpoint_group_id_list.first.status_entry.state.should eq(Datastore::DatastoreStateEnum::CommitFailed)
  ensure
    client.try(&.close)
  end

  it "adopts a Groupcast-only target and commits the Anchor group without Groups" do
    client = Matter::Controller::Client.new
    im = DatastoreImClient.new(client)
    im.server_lists[0_u16] = [Matter::Cluster::GroupKeyManagement::CLUSTER_ID,
                              Matter::Cluster::Groupcast::CLUSTER_ID]
    store = Datastore.new(Matter::DataType::EndpointNumber.new(0_u16))
    pending = Datastore::DatastoreStatusEntryStruct.new(Datastore::DatastoreStateEnum::Pending, 0_u32, 0_u8)
    store.group_key_set_list = [Datastore::DatastoreGroupKeySetStruct.new(7_u16,
      Datastore::DatastoreGroupKeySecurityPolicyEnum::TrustFirst,
      Bytes.new(16, 0x77_u8), 1_u64, nil, nil, nil, nil)]
    store.group_list = [Datastore::DatastoreGroupInformationEntryStruct.new(0x1234_u64,
      "Shared", 7_u16, nil, nil, Datastore::DatastoreAccessControlEntryPrivilegeEnum::Operate)]
    store.node_key_set_list = [Datastore::DatastoreNodeKeySetEntryStruct.new(0x100_u64, 7_u16, pending)]
    store.endpoint_group_id_list = [Datastore::DatastoreEndpointGroupIDEntryStruct.new(
      0x100_u64, 1_u16, 0x1234_u16, pending)]

    Matter::Controller::DatastoreSynchronizer.new(im).sync_node(store, 0x100_u64, datastore_session,
      Socket::IPAddress.new("127.0.0.1", 5540))
    im.groupcast_adopted?.should be_true
    im.command_paths.should contain({Matter::Cluster::Groupcast::CLUSTER_ID,
                                     Matter::Cluster::Groupcast::CMD_JOIN_GROUP})
    im.command_paths.any? { |path| path[0] == Matter::Cluster::Groups::CLUSTER_ID }.should be_false
    im.groupcast_memberships.first.endpoints.should eq([1_u16])
    store.endpoint_group_id_list.first.status_entry.state.should eq(Datastore::DatastoreStateEnum::Committed)

    store.endpoint_group_id_list = [Datastore::DatastoreEndpointGroupIDEntryStruct.new(
      0x100_u64, 1_u16, 0x1234_u16,
      Datastore::DatastoreStatusEntryStruct.new(Datastore::DatastoreStateEnum::DeletePending, 0_u32, 0_u8))]
    Matter::Controller::DatastoreSynchronizer.new(im).sync_node(store, 0x100_u64, datastore_session,
      Socket::IPAddress.new("127.0.0.1", 5540))
    im.command_paths.should contain({Matter::Cluster::Groupcast::CLUSTER_ID,
                                     Matter::Cluster::Groupcast::CMD_LEAVE_GROUP})
    im.groupcast_memberships.should be_empty
  ensure
    client.try(&.close)
  end

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

  it "prunes committed groups and bindings when a retained endpoint no longer advertises their clusters" do
    client = Matter::Controller::Client.new
    im = DatastoreImClient.new(client)
    im.parts_list = [1_u16]
    im.server_lists[1_u16] = [] of UInt32
    store = Datastore.new(Matter::DataType::EndpointNumber.new(0_u16))
    pending = Datastore::DatastoreStatusEntryStruct.new(Datastore::DatastoreStateEnum::Pending, 0_u32, 0_u8)
    committed = Datastore::DatastoreStatusEntryStruct.new(Datastore::DatastoreStateEnum::Committed, 0_u32, 0_u8)
    node_id = 0x100_u64
    store.node_list = [Datastore::DatastoreNodeInformationEntryStruct.new(node_id, "Node", pending)]
    store.record_endpoint(node_id, 1_u16, "Endpoint").success?.should be_true
    binding = Datastore::DatastoreBindingTargetStruct.new(node: 0x200_u64, endpoint: 1_u16)
    store.endpoint_group_id_list = [Datastore::DatastoreEndpointGroupIDEntryStruct.new(node_id, 1_u16, 5_u16, committed)]
    store.endpoint_binding_list = [Datastore::DatastoreEndpointBindingEntryStruct.new(node_id, 1_u16, 7_u16, binding, committed)]

    Matter::Controller::DatastoreSynchronizer.new(im).sync_node(store, node_id, datastore_session,
      Socket::IPAddress.new("127.0.0.1", 5540))

    store.node_endpoint_list.map(&.endpoint_id).should eq([1_u16])
    store.endpoint_group_id_list.should be_empty
    store.endpoint_binding_list.should be_empty
    store.node_list.first.commissioning_status_entry.state.should eq(Datastore::DatastoreStateEnum::Committed)
  ensure
    client.try(&.close)
  end

  it "retains failed pending group and binding work when their endpoint clusters are absent" do
    client = Matter::Controller::Client.new
    im = DatastoreImClient.new(client)
    im.parts_list = [1_u16]
    im.server_lists[1_u16] = [] of UInt32
    im.response_code = Matter::InteractionModel::StatusCode::UnsupportedCluster
    im.reject_unadvertised_commands = true
    store = Datastore.new(Matter::DataType::EndpointNumber.new(0_u16))
    pending = Datastore::DatastoreStatusEntryStruct.new(Datastore::DatastoreStateEnum::Pending, 0_u32, 0_u8)
    node_id = 0x100_u64
    store.node_list = [Datastore::DatastoreNodeInformationEntryStruct.new(node_id, "Node", pending)]
    store.record_endpoint(node_id, 1_u16, "Endpoint").success?.should be_true
    store.group_list = [Datastore::DatastoreGroupInformationEntryStruct.new(5_u64, "Group", nil, nil, nil,
      Datastore::DatastoreAccessControlEntryPrivilegeEnum::Operate)]
    binding = Datastore::DatastoreBindingTargetStruct.new(node: 0x200_u64, endpoint: 1_u16)
    store.endpoint_group_id_list = [Datastore::DatastoreEndpointGroupIDEntryStruct.new(node_id, 1_u16, 5_u16, pending)]
    store.endpoint_binding_list = [Datastore::DatastoreEndpointBindingEntryStruct.new(node_id, 1_u16, 7_u16, binding, pending)]

    Matter::Controller::DatastoreSynchronizer.new(im).sync_node(store, node_id, datastore_session,
      Socket::IPAddress.new("127.0.0.1", 5540))

    store.endpoint_group_id_list.first.status_entry.state.should eq(Datastore::DatastoreStateEnum::CommitFailed)
    store.endpoint_binding_list.first.status_entry.state.should eq(Datastore::DatastoreStateEnum::CommitFailed)
    store.node_list.first.commissioning_status_entry.state.should eq(Datastore::DatastoreStateEnum::CommitFailed)
  ensure
    client.try(&.close)
  end

  it "holds pending endpoint group and binding intent until a missing endpoint returns" do
    client = Matter::Controller::Client.new
    im = DatastoreImClient.new(client)
    store = Datastore.new(Matter::DataType::EndpointNumber.new(0_u16))
    store.add_pending_node(Datastore::AddPendingNodeRequest.new(0x100_u64, "Node"))
    store.record_endpoint(0x100_u64, 1_u16, "Temporarily absent")
    store.add_group(Datastore::AddGroupRequest.new(5_u16, "Lights", nil, nil, nil,
      Datastore::DatastoreAccessControlEntryPrivilegeEnum::Operate))
    store.add_group_id_to_endpoint_for_node(Datastore::AddGroupIDToEndpointForNodeRequest.new(0x100_u64, 1_u16, 5_u16))
      .success?.should be_true
    target = Datastore::DatastoreBindingTargetStruct.new(node: 0x200_u64, endpoint: 1_u16)
    store.add_binding_to_endpoint_for_node(Datastore::AddBindingToEndpointForNodeRequest.new(0x100_u64, 1_u16, target))
      .success?.should be_true
    peer = Socket::IPAddress.new("127.0.0.1", 5540)
    synchronizer = Matter::Controller::DatastoreSynchronizer.new(im)

    im.parts_list = [] of UInt16
    synchronizer.sync_node(store, 0x100_u64, datastore_session, peer)
    store.node_endpoint_list.should be_empty
    store.endpoint_group_id_list.first.status_entry.state.should eq(Datastore::DatastoreStateEnum::Pending)
    store.endpoint_binding_list.first.status_entry.state.should eq(Datastore::DatastoreStateEnum::Pending)
    im.commands.should be_empty
    im.writes.should be_empty
    synchronizer.sync_node(store, 0x100_u64, datastore_session, peer)
    im.commands.should be_empty
    im.writes.should be_empty

    store.refresh_node(Datastore::RefreshNodeRequest.new(0x100_u64)).success?.should be_true
    im.parts_list = [1_u16]
    im.server_lists[1_u16] = [Matter::Cluster::Groups::CLUSTER_ID, Matter::Cluster::Binding::CLUSTER_ID]
    im.group_memberships[1_u16] = [Matter::DataType::GroupId.new(5_u16)]
    synchronizer.sync_node(store, 0x100_u64, datastore_session, peer)
    store.node_endpoint_list.map(&.endpoint_id).should eq([1_u16])
    store.endpoint_group_id_list.first.status_entry.state.should eq(Datastore::DatastoreStateEnum::Committed)
    store.endpoint_binding_list.first.status_entry.state.should eq(Datastore::DatastoreStateEnum::Committed)
    im.commands.should contain(Matter::Cluster::Groups::CMD_ADD_GROUP)
    im.writes.any? { |cluster, _, _| cluster == Matter::Cluster::Binding::CLUSTER_ID }.should be_true
  ensure
    client.try(&.close)
  end

  it "delivers pending group and binding removals after an endpoint returns" do
    client = Matter::Controller::Client.new
    im = DatastoreImClient.new(client)
    store = Datastore.new(Matter::DataType::EndpointNumber.new(0_u16))
    store.add_pending_node(Datastore::AddPendingNodeRequest.new(0x100_u64, "Node"))
    store.record_endpoint(0x100_u64, 1_u16, "Temporary endpoint")
    store.add_group(Datastore::AddGroupRequest.new(5_u16, "Lights", nil, nil, nil,
      Datastore::DatastoreAccessControlEntryPrivilegeEnum::Operate))
    store.add_group_id_to_endpoint_for_node(Datastore::AddGroupIDToEndpointForNodeRequest.new(0x100_u64, 1_u16, 5_u16))
      .success?.should be_true
    store.complete_group_membership(0x100_u64, 1_u16, 5_u16).should be_true
    target = Datastore::DatastoreBindingTargetStruct.new(node: 0x200_u64, endpoint: 1_u16)
    store.add_binding_to_endpoint_for_node(Datastore::AddBindingToEndpointForNodeRequest.new(0x100_u64, 1_u16, target))
      .success?.should be_true
    binding_id = store.endpoint_binding_list.first.list_id
    store.complete_binding(0x100_u64, 1_u16, binding_id).should be_true
    store.remove_group_id_from_endpoint_for_node(Datastore::RemoveGroupIDFromEndpointForNodeRequest.new(0x100_u64, 1_u16, 5_u16))
      .success?.should be_true
    store.remove_binding_from_endpoint_for_node(Datastore::RemoveBindingFromEndpointForNodeRequest.new(binding_id, 1_u16, 0x100_u64))
      .success?.should be_true
    peer = Socket::IPAddress.new("127.0.0.1", 5540)
    synchronizer = Matter::Controller::DatastoreSynchronizer.new(im)

    im.parts_list = [] of UInt16
    synchronizer.sync_node(store, 0x100_u64, datastore_session, peer)
    store.node_endpoint_list.should be_empty
    store.endpoint_group_id_list.first.status_entry.state.should eq(Datastore::DatastoreStateEnum::DeletePending)
    store.endpoint_binding_list.first.status_entry.state.should eq(Datastore::DatastoreStateEnum::DeletePending)
    im.commands.should be_empty
    im.writes.should be_empty

    store.refresh_node(Datastore::RefreshNodeRequest.new(0x100_u64)).success?.should be_true
    im.parts_list = [1_u16]
    im.server_lists[1_u16] = [Matter::Cluster::Groups::CLUSTER_ID, Matter::Cluster::Binding::CLUSTER_ID]
    im.binding_entries[1_u16] = [Matter::Cluster::Binding::Target.new(node: 0x200_u64, endpoint: 1_u16)]
    synchronizer.sync_node(store, 0x100_u64, datastore_session, peer)
    store.endpoint_group_id_list.should be_empty
    store.endpoint_binding_list.should be_empty
    im.commands.should contain(Matter::Cluster::Groups::CMD_REMOVE_GROUP)
    im.binding_entries[1_u16].should be_empty
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
    im.binding_entries[1_u16] = [Matter::Cluster::Binding::Target.new(node: 0x200_u64, endpoint: 1_u16)]
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

  it "delivers pending root endpoint groups and bindings without adding root to NodeEndpointList" do
    client = Matter::Controller::Client.new
    im = DatastoreImClient.new(client)
    root_endpoint = Matter::Node::ROOT_ENDPOINT_ID
    node_id = 0x100_u64
    im.parts_list = [1_u16]
    im.server_lists[root_endpoint] = [Matter::Cluster::Groups::CLUSTER_ID, Matter::Cluster::Binding::CLUSTER_ID]
    im.group_memberships[root_endpoint] = [Matter::DataType::GroupId.new(5_u16)]
    store = Datastore.new(Matter::DataType::EndpointNumber::ROOT)
    pending = Datastore::DatastoreStatusEntryStruct.new(Datastore::DatastoreStateEnum::Pending, 0_u32, 0_u8)
    store.node_list = [Datastore::DatastoreNodeInformationEntryStruct.new(node_id, "Node", pending)]
    store.group_list = [Datastore::DatastoreGroupInformationEntryStruct.new(5_u64, "Lights", nil, nil, nil,
      Datastore::DatastoreAccessControlEntryPrivilegeEnum::Operate)]
    store.endpoint_group_id_list = [Datastore::DatastoreEndpointGroupIDEntryStruct.new(node_id, root_endpoint, 5_u16, pending)]
    binding = Datastore::DatastoreBindingTargetStruct.new(node: 0x200_u64, endpoint: 1_u16)
    store.endpoint_binding_list = [Datastore::DatastoreEndpointBindingEntryStruct.new(node_id, root_endpoint, 7_u16, binding, pending)]

    Matter::Controller::DatastoreSynchronizer.new(im).sync_node(store, node_id, datastore_session,
      Socket::IPAddress.new("127.0.0.1", 5540))

    store.node_endpoint_list.map(&.endpoint_id).should eq([1_u16])
    store.endpoint_group_id_list.first.status_entry.state.should eq(Datastore::DatastoreStateEnum::Committed)
    store.endpoint_binding_list.first.status_entry.state.should eq(Datastore::DatastoreStateEnum::Committed)
    im.command_paths.should contain({Matter::Cluster::Groups::CLUSTER_ID, Matter::Cluster::Groups::CMD_ADD_GROUP})
    im.writes.any? { |cluster, attribute, _| cluster == Matter::Cluster::Binding::CLUSTER_ID && attribute == Matter::Cluster::Binding::ATTR_BINDING }.should be_true
  ensure
    client.try(&.close)
  end

  it "imports root endpoint groups and bindings without adding root to NodeEndpointList" do
    client = Matter::Controller::Client.new
    im = DatastoreImClient.new(client)
    root_endpoint = Matter::Node::ROOT_ENDPOINT_ID
    node_id = 0x100_u64
    im.parts_list = [1_u16]
    im.server_lists[root_endpoint] = [Matter::Cluster::Groups::CLUSTER_ID, Matter::Cluster::Binding::CLUSTER_ID]
    im.group_memberships[root_endpoint] = [Matter::DataType::GroupId.new(5_u16)]
    im.binding_entries[root_endpoint] = [Matter::Cluster::Binding::Target.new(node: 0x200_u64, endpoint: 1_u16)]
    store = Datastore.new(Matter::DataType::EndpointNumber::ROOT)
    pending = Datastore::DatastoreStatusEntryStruct.new(Datastore::DatastoreStateEnum::Pending, 0_u32, 0_u8)
    store.node_list = [Datastore::DatastoreNodeInformationEntryStruct.new(node_id, "Node", pending)]
    synchronizer = Matter::Controller::DatastoreSynchronizer.new(im)
    peer = Socket::IPAddress.new("127.0.0.1", 5540)

    synchronizer.sync_node(store, node_id, datastore_session, peer)
    store.node_endpoint_list.map(&.endpoint_id).should eq([1_u16])
    store.endpoint_group_id_list.map { |entry| {entry.endpoint_id, entry.group_id} }.should eq([{root_endpoint, 5_u16}])
    store.endpoint_binding_list.map { |entry| {entry.endpoint_id, entry.binding.node} }.should eq([{root_endpoint, 0x200_u64}])
    store.node_list.first.commissioning_status_entry.state.should eq(Datastore::DatastoreStateEnum::Committed)
    binding = Datastore::DatastoreBindingTargetStruct.new(node: 0x200_u64, endpoint: 1_u16)
    store.add_group_id_to_endpoint_for_node(Datastore::AddGroupIDToEndpointForNodeRequest.new(node_id, root_endpoint, 5_u16))
      .status.should eq(Matter::InteractionModel::StatusCode::NotFound)
    store.add_binding_to_endpoint_for_node(Datastore::AddBindingToEndpointForNodeRequest.new(node_id, root_endpoint, binding))
      .status.should eq(Matter::InteractionModel::StatusCode::NotFound)

    store.refresh_node(Datastore::RefreshNodeRequest.new(node_id)).success?.should be_true
    synchronizer.sync_node(store, node_id, datastore_session, peer)
    store.node_endpoint_list.map(&.endpoint_id).should eq([1_u16])
    store.endpoint_group_id_list.map { |entry| {entry.endpoint_id, entry.group_id} }.should eq([{root_endpoint, 5_u16}])
    store.endpoint_binding_list.map { |entry| {entry.endpoint_id, entry.binding.node} }.should eq([{root_endpoint, 0x200_u64}])
    store.node_list.first.commissioning_status_entry.state.should eq(Datastore::DatastoreStateEnum::Committed)
  ensure
    client.try(&.close)
  end

  it "prunes committed root records when optional clusters disappear and retains pending intent" do
    client = Matter::Controller::Client.new
    im = DatastoreImClient.new(client)
    root_endpoint = Matter::Node::ROOT_ENDPOINT_ID
    node_id = 0x100_u64
    im.parts_list = [1_u16]
    im.server_lists[root_endpoint] = [] of UInt32
    im.response_code = Matter::InteractionModel::StatusCode::UnsupportedCluster
    im.reject_unadvertised_commands = true
    store = Datastore.new(Matter::DataType::EndpointNumber::ROOT)
    pending = Datastore::DatastoreStatusEntryStruct.new(Datastore::DatastoreStateEnum::Pending, 0_u32, 0_u8)
    committed = Datastore::DatastoreStatusEntryStruct.new(Datastore::DatastoreStateEnum::Committed, 0_u32, 0_u8)
    store.node_list = [Datastore::DatastoreNodeInformationEntryStruct.new(node_id, "Node", pending)]
    binding = Datastore::DatastoreBindingTargetStruct.new(node: 0x200_u64, endpoint: 1_u16)
    store.endpoint_group_id_list = [
      Datastore::DatastoreEndpointGroupIDEntryStruct.new(node_id, root_endpoint, 5_u16, committed),
      Datastore::DatastoreEndpointGroupIDEntryStruct.new(node_id, root_endpoint, 6_u16, pending),
    ]
    store.endpoint_binding_list = [
      Datastore::DatastoreEndpointBindingEntryStruct.new(node_id, root_endpoint, 7_u16, binding, committed),
      Datastore::DatastoreEndpointBindingEntryStruct.new(node_id, root_endpoint, 8_u16, binding, pending),
    ]
    store.group_list = [Datastore::DatastoreGroupInformationEntryStruct.new(6_u64, "Group", nil, nil, nil,
      Datastore::DatastoreAccessControlEntryPrivilegeEnum::Operate)]

    Matter::Controller::DatastoreSynchronizer.new(im).sync_node(store, node_id, datastore_session,
      Socket::IPAddress.new("127.0.0.1", 5540))

    store.node_endpoint_list.map(&.endpoint_id).should eq([1_u16])
    store.endpoint_group_id_list.map(&.group_id).should eq([6_u16])
    store.endpoint_binding_list.map(&.list_id).should eq([8_u16])
    store.endpoint_group_id_list.first.status_entry.state.should eq(Datastore::DatastoreStateEnum::CommitFailed)
    store.endpoint_binding_list.first.status_entry.state.should eq(Datastore::DatastoreStateEnum::CommitFailed)
    store.node_list.first.commissioning_status_entry.state.should eq(Datastore::DatastoreStateEnum::CommitFailed)
  ensure
    client.try(&.close)
  end

  it "leaves a refreshing node and its Datastore records pending when the target has an unrepresentable ACL" do
    client = Matter::Controller::Client.new
    im = DatastoreImClient.new(client)
    im.parts_list = [2_u16]
    im.server_lists[0_u16] = [Matter::Cluster::AccessControl::CLUSTER_ID]
    im.acl_entries = [Matter::Cluster::AccessControl::AccessControlEntry.new(
      Matter::Cluster::AccessControl::AccessControlEntryPrivilege::ProxyView,
      Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
      [0x200_u64], nil)]
    store = Datastore.new(Matter::DataType::EndpointNumber.new(0_u16))
    committed = Datastore::DatastoreStatusEntryStruct.new(Datastore::DatastoreStateEnum::Committed, 0_u32, 0_u8)
    store.node_list = [Datastore::DatastoreNodeInformationEntryStruct.new(0x100_u64, "Node", committed)]
    store.record_endpoint(0x100_u64, 1_u16, "Original endpoint")
    acl = Datastore::DatastoreAccessControlEntryStruct.new(
      Datastore::DatastoreAccessControlEntryPrivilegeEnum::View,
      Datastore::DatastoreAccessControlEntryAuthModeEnum::CASE, [0x200_u64], nil)
    store.node_acl_list = [Datastore::DatastoreACLEntryStruct.new(0x100_u64, 7_u16, acl, committed)]
    store.refresh_node(Datastore::RefreshNodeRequest.new(0x100_u64)).success?.should be_true

    expect_raises(Matter::ProtocolError, /ProxyView/) do
      Matter::Controller::DatastoreSynchronizer.new(im).sync_node(store, 0x100_u64, datastore_session,
        Socket::IPAddress.new("127.0.0.1", 5540))
    end
    store.node_list.first.commissioning_status_entry.state.should eq(Datastore::DatastoreStateEnum::Pending)
    store.node_endpoint_list.map(&.endpoint_id).should eq([1_u16])
    store.node_acl_list.size.should eq(1)
    store.node_acl_list.first.acl_entry.should eq(acl)
    im.writes.should be_empty
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

  it "retains an ACL while another datastore ListID still requires it" do
    client = Matter::Controller::Client.new
    im = DatastoreImClient.new(client)
    store = Datastore.new(Matter::DataType::EndpointNumber.new(0_u16))
    store.add_pending_node(Datastore::AddPendingNodeRequest.new(0x100_u64, "Node"))
    store.complete_node(0x100_u64)
    acl = Datastore::DatastoreAccessControlEntryStruct.new(
      Datastore::DatastoreAccessControlEntryPrivilegeEnum::Operate,
      Datastore::DatastoreAccessControlEntryAuthModeEnum::CASE, [0x200_u64], nil)
    request = Datastore::AddACLToNodeRequest.new(0x100_u64, acl)
    store.add_acl_to_node(request).success?.should be_true
    store.add_acl_to_node(request).success?.should be_true
    list_ids = store.node_acl_list.map(&.list_id)
    list_ids.uniq.size.should eq(2)
    synchronizer = Matter::Controller::DatastoreSynchronizer.new(im)
    peer = Socket::IPAddress.new("127.0.0.1", 5540)
    synchronizer.sync_node(store, 0x100_u64, datastore_session, peer)
    store.node_acl_list.all?(&.status_entry.state.committed?).should be_true

    im.acl_entries = [Matter::Cluster::AccessControl::AccessControlEntry.new(
      Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Operate,
      Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE, [0x200_u64], nil)]
    store.remove_acl_from_node(Datastore::RemoveACLFromNodeRequest.new(list_ids[0], 0x100_u64)).success?.should be_true
    synchronizer.sync_node(store, 0x100_u64, datastore_session, peer)
    Array(Matter::Cluster::AccessControl::AccessControlEntry).from_tlv(im.writes.last[2]).size.should eq(1)
    store.node_acl_list.map(&.list_id).should eq([list_ids[1]])

    store.remove_acl_from_node(Datastore::RemoveACLFromNodeRequest.new(list_ids[1], 0x100_u64)).success?.should be_true
    synchronizer.sync_node(store, 0x100_u64, datastore_session, peer)
    Array(Matter::Cluster::AccessControl::AccessControlEntry).from_tlv(im.writes.last[2]).should be_empty
    store.node_acl_list.should be_empty
  ensure
    client.try(&.close)
  end

  it "keeps another active ACL when replacing a matching prior ACL" do
    client = Matter::Controller::Client.new
    im = DatastoreImClient.new(client)
    old_acl = Datastore::DatastoreAccessControlEntryStruct.new(
      Datastore::DatastoreAccessControlEntryPrivilegeEnum::Administer,
      Datastore::DatastoreAccessControlEntryAuthModeEnum::CASE, nil, nil)
    new_acl = Datastore::DatastoreAccessControlEntryStruct.new(
      Datastore::DatastoreAccessControlEntryPrivilegeEnum::View,
      Datastore::DatastoreAccessControlEntryAuthModeEnum::CASE, nil, nil)
    im.acl_entries = [Matter::Cluster::AccessControl::AccessControlEntry.new(
      Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer,
      Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE, [] of UInt64, nil)]
    committed = Datastore::DatastoreStatusEntryStruct.new(Datastore::DatastoreStateEnum::Committed, 0_u32, 0_u8)
    pending = Datastore::DatastoreStatusEntryStruct.new(Datastore::DatastoreStateEnum::Pending, 0_u32, 0_u8)
    rotating = Datastore::DatastoreACLEntryStruct.new(0x100_u64, 0_u16, new_acl, pending)
    rotating.prior_acl_entry = old_acl
    # The synchronizer normalizes nullable and empty subject lists to the same target ACL.
    retained_acl = Datastore::DatastoreAccessControlEntryStruct.new(old_acl.privilege, old_acl.auth_mode,
      [] of UInt64, nil)
    retained = Datastore::DatastoreACLEntryStruct.new(0x100_u64, 1_u16, retained_acl, committed)
    store = Datastore.new(Matter::DataType::EndpointNumber.new(0_u16))
    store.node_acl_list = [rotating, retained]

    Matter::Controller::DatastoreSynchronizer.new(im).sync_node(store, 0x100_u64, datastore_session,
      Socket::IPAddress.new("127.0.0.1", 5540))
    written = Array(Matter::Cluster::AccessControl::AccessControlEntry).from_tlv(im.writes.last[2])
    written.map(&.privilege).sort!.should eq([
      Matter::Cluster::AccessControl::AccessControlEntryPrivilege::View,
      Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer,
    ])
    store.node_acl_list.map(&.status_entry.state).should eq([
      Datastore::DatastoreStateEnum::Committed,
      Datastore::DatastoreStateEnum::Committed,
    ])
  ensure
    client.try(&.close)
  end

  it "does not retain a prior ACL for an entry whose target write failed" do
    client = Matter::Controller::Client.new
    im = DatastoreImClient.new(client)
    old_acl = Datastore::DatastoreAccessControlEntryStruct.new(
      Datastore::DatastoreAccessControlEntryPrivilegeEnum::Administer,
      Datastore::DatastoreAccessControlEntryAuthModeEnum::CASE, [0x200_u64], nil)
    new_acl = Datastore::DatastoreAccessControlEntryStruct.new(
      Datastore::DatastoreAccessControlEntryPrivilegeEnum::View,
      Datastore::DatastoreAccessControlEntryAuthModeEnum::CASE, [0x200_u64], nil)
    im.acl_entries = [Matter::Cluster::AccessControl::AccessControlEntry.new(
      Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer,
      Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE, [0x200_u64], nil)]
    pending = Datastore::DatastoreStatusEntryStruct.new(Datastore::DatastoreStateEnum::Pending, 0_u32, 0_u8)
    failed = Datastore::DatastoreStatusEntryStruct.new(Datastore::DatastoreStateEnum::CommitFailed, 0_u32,
      Matter::InteractionModel::StatusCode::ResourceExhausted.value)
    rotating = Datastore::DatastoreACLEntryStruct.new(0x100_u64, 0_u16, new_acl, pending)
    rotating.prior_acl_entry = old_acl
    store = Datastore.new(Matter::DataType::EndpointNumber.new(0_u16))
    store.node_acl_list = [rotating, Datastore::DatastoreACLEntryStruct.new(0x100_u64, 1_u16, old_acl, failed)]

    Matter::Controller::DatastoreSynchronizer.new(im).sync_node(store, 0x100_u64, datastore_session,
      Socket::IPAddress.new("127.0.0.1", 5540))
    written = Array(Matter::Cluster::AccessControl::AccessControlEntry).from_tlv(im.writes.last[2])
    written.map(&.privilege).should eq([Matter::Cluster::AccessControl::AccessControlEntryPrivilege::View])
  ensure
    client.try(&.close)
  end

  it "removes an ACL before a pending duplicate that later fails its write" do
    client = Matter::Controller::Client.new
    im = DatastoreImClient.new(client)
    acl = Datastore::DatastoreAccessControlEntryStruct.new(
      Datastore::DatastoreAccessControlEntryPrivilegeEnum::Administer,
      Datastore::DatastoreAccessControlEntryAuthModeEnum::CASE, [0x200_u64], nil)
    im.acl_entries = [Matter::Cluster::AccessControl::AccessControlEntry.new(
      Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer,
      Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE, [0x200_u64], nil)]
    im.write_response_codes.concat([
      Matter::InteractionModel::StatusCode::Success,
      Matter::InteractionModel::StatusCode::ResourceExhausted,
    ])
    deleting = Datastore::DatastoreStatusEntryStruct.new(Datastore::DatastoreStateEnum::DeletePending, 0_u32, 0_u8)
    pending = Datastore::DatastoreStatusEntryStruct.new(Datastore::DatastoreStateEnum::Pending, 0_u32, 0_u8)
    store = Datastore.new(Matter::DataType::EndpointNumber.new(0_u16))
    store.node_acl_list = [
      Datastore::DatastoreACLEntryStruct.new(0x100_u64, 0_u16, acl, deleting),
      Datastore::DatastoreACLEntryStruct.new(0x100_u64, 1_u16, acl, pending),
    ]

    Matter::Controller::DatastoreSynchronizer.new(im).sync_node(store, 0x100_u64, datastore_session,
      Socket::IPAddress.new("127.0.0.1", 5540))
    im.acl_entries.should be_empty
    store.node_acl_list.map(&.list_id).should eq([1_u16])
    store.node_acl_list.first.status_entry.state.should eq(Datastore::DatastoreStateEnum::CommitFailed)
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

  it "commits only cluster-specific bindings advertised in the endpoint ClientList" do
    client = Matter::Controller::Client.new
    im = DatastoreImClient.new(client)
    store = Datastore.new(Matter::DataType::EndpointNumber::ROOT)
    node_id = 0x100_u64
    endpoint_id = 1_u16
    im.client_lists[endpoint_id] = [Matter::Cluster::OnOff::CLUSTER_ID]
    invalid = Datastore::DatastoreBindingTargetStruct.new(node: 0x200_u64,
      endpoint: endpoint_id, cluster: Matter::Cluster::LevelControl::CLUSTER_ID)
    valid = Datastore::DatastoreBindingTargetStruct.new(node: 0x200_u64,
      endpoint: endpoint_id, cluster: Matter::Cluster::OnOff::CLUSTER_ID)
    store.endpoint_binding_list = [
      Datastore::DatastoreEndpointBindingEntryStruct.new(node_id, endpoint_id, 1_u16, invalid,
        Datastore::DatastoreStatusEntryStruct.new(Datastore::DatastoreStateEnum::Pending, 0_u32, 0_u8)),
      Datastore::DatastoreEndpointBindingEntryStruct.new(node_id, endpoint_id, 2_u16, valid,
        Datastore::DatastoreStatusEntryStruct.new(Datastore::DatastoreStateEnum::Pending, 0_u32, 0_u8)),
    ]

    Matter::Controller::DatastoreSynchronizer.new(im).sync_node(store, node_id, datastore_session,
      Socket::IPAddress.new("127.0.0.1", 5540))

    rejected = store.endpoint_binding_list.find!(&.list_id.==(1_u16))
    rejected.status_entry.state.should eq(Datastore::DatastoreStateEnum::CommitFailed)
    rejected.status_entry.failure_code.should eq(Matter::InteractionModel::StatusCode::ConstraintError.value)
    committed = store.endpoint_binding_list.find!(&.list_id.==(2_u16))
    committed.status_entry.state.should eq(Datastore::DatastoreStateEnum::Committed)
    im.writes.size.should eq(1)
    im.binding_entries[endpoint_id].map(&.cluster).should eq([Matter::Cluster::OnOff::CLUSTER_ID])
  ensure
    client.try(&.close)
  end

  it "retains a binding while another datastore ListID still requires it" do
    client = Matter::Controller::Client.new
    im = DatastoreImClient.new(client)
    store = Datastore.new(Matter::DataType::EndpointNumber.new(0_u16))
    store.add_pending_node(Datastore::AddPendingNodeRequest.new(0x100_u64, "Node"))
    store.complete_node(0x100_u64)
    store.record_endpoint(0x100_u64, 1_u16, "Endpoint")
    target = Datastore::DatastoreBindingTargetStruct.new(node: 0x200_u64, endpoint: 1_u16)
    request = Datastore::AddBindingToEndpointForNodeRequest.new(0x100_u64, 1_u16, target)
    store.add_binding_to_endpoint_for_node(request).success?.should be_true
    store.add_binding_to_endpoint_for_node(request).success?.should be_true
    list_ids = store.endpoint_binding_list.map(&.list_id)
    list_ids.uniq.size.should eq(2)
    peer = Socket::IPAddress.new("127.0.0.1", 5540)
    synchronizer = Matter::Controller::DatastoreSynchronizer.new(im)
    synchronizer.sync_node(store, 0x100_u64, datastore_session, peer)
    store.endpoint_binding_list.all?(&.status_entry.state.committed?).should be_true

    im.binding_entries[1_u16] = [Matter::Cluster::Binding::Target.new(node: 0x200_u64, endpoint: 1_u16)]
    store.remove_binding_from_endpoint_for_node(Datastore::RemoveBindingFromEndpointForNodeRequest.new(list_ids[0], 1_u16, 0x100_u64))
      .success?.should be_true
    synchronizer.sync_node(store, 0x100_u64, datastore_session, peer)
    first_removal = im.writes.last[2]
    Array(Matter::Cluster::Binding::Target).from_tlv(first_removal).size.should eq(1)
    store.endpoint_binding_list.map(&.list_id).should eq([list_ids[1]])

    store.remove_binding_from_endpoint_for_node(Datastore::RemoveBindingFromEndpointForNodeRequest.new(list_ids[1], 1_u16, 0x100_u64))
      .success?.should be_true
    synchronizer.sync_node(store, 0x100_u64, datastore_session, peer)
    final_removal = im.writes.last[2]
    Array(Matter::Cluster::Binding::Target).from_tlv(final_removal).should be_empty
    store.endpoint_binding_list.should be_empty
  ensure
    client.try(&.close)
  end

  it "does not retain a binding for a ListID whose target write failed" do
    client = Matter::Controller::Client.new
    im = DatastoreImClient.new(client)
    target = Datastore::DatastoreBindingTargetStruct.new(node: 0x200_u64, endpoint: 1_u16)
    im.binding_entries[1_u16] = [Matter::Cluster::Binding::Target.new(node: 0x200_u64, endpoint: 1_u16)]
    deleting = Datastore::DatastoreStatusEntryStruct.new(Datastore::DatastoreStateEnum::DeletePending, 0_u32, 0_u8)
    failed = Datastore::DatastoreStatusEntryStruct.new(Datastore::DatastoreStateEnum::CommitFailed, 0_u32,
      Matter::InteractionModel::StatusCode::ResourceExhausted.value)
    store = Datastore.new(Matter::DataType::EndpointNumber.new(0_u16))
    store.endpoint_binding_list = [
      Datastore::DatastoreEndpointBindingEntryStruct.new(0x100_u64, 1_u16, 0_u16, target, deleting),
      Datastore::DatastoreEndpointBindingEntryStruct.new(0x100_u64, 1_u16, 1_u16, target, failed),
    ]

    Matter::Controller::DatastoreSynchronizer.new(im).sync_node(store, 0x100_u64, datastore_session,
      Socket::IPAddress.new("127.0.0.1", 5540))
    Array(Matter::Cluster::Binding::Target).from_tlv(im.writes.last[2]).should be_empty
    store.endpoint_binding_list.map(&.list_id).should eq([1_u16])
  ensure
    client.try(&.close)
  end

  it "removes a binding before a pending duplicate that later fails its write" do
    client = Matter::Controller::Client.new
    im = DatastoreImClient.new(client)
    target = Datastore::DatastoreBindingTargetStruct.new(node: 0x200_u64, endpoint: 1_u16)
    im.binding_entries[1_u16] = [Matter::Cluster::Binding::Target.new(node: 0x200_u64, endpoint: 1_u16)]
    im.write_response_codes.concat([
      Matter::InteractionModel::StatusCode::Success,
      Matter::InteractionModel::StatusCode::ResourceExhausted,
    ])
    deleting = Datastore::DatastoreStatusEntryStruct.new(Datastore::DatastoreStateEnum::DeletePending, 0_u32, 0_u8)
    pending = Datastore::DatastoreStatusEntryStruct.new(Datastore::DatastoreStateEnum::Pending, 0_u32, 0_u8)
    store = Datastore.new(Matter::DataType::EndpointNumber.new(0_u16))
    store.endpoint_binding_list = [
      Datastore::DatastoreEndpointBindingEntryStruct.new(0x100_u64, 1_u16, 0_u16, target, deleting),
      Datastore::DatastoreEndpointBindingEntryStruct.new(0x100_u64, 1_u16, 1_u16, target, pending),
    ]

    Matter::Controller::DatastoreSynchronizer.new(im).sync_node(store, 0x100_u64, datastore_session,
      Socket::IPAddress.new("127.0.0.1", 5540))
    im.binding_entries[1_u16].should be_empty
    store.endpoint_binding_list.map(&.list_id).should eq([1_u16])
    store.endpoint_binding_list.first.status_entry.state.should eq(Datastore::DatastoreStateEnum::CommitFailed)
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
    mappings.first.fabric_index.should eq(im.current_fabric_index)
    im.commands.should eq([Matter::Cluster::Groups::CMD_ADD_GROUP])
    store.endpoint_group_id_list.first.status_entry.state.should eq(Matter::Cluster::JointFabricDatastore::DatastoreStateEnum::Committed)
  ensure
    client.try(&.close)
  end

  it "does not commit a group when AddGroupResponse names another group" do
    client = Matter::Controller::Client.new
    im = DatastoreImClient.new(client)
    im.group_response_id = Matter::DataType::GroupId.new(3_u16)
    store = Datastore.new(Matter::DataType::EndpointNumber.new(0_u16))
    store.group_list = [Datastore::DatastoreGroupInformationEntryStruct.new(
      2_u64, "kitchen", 1_u16, nil, nil, Datastore::DatastoreAccessControlEntryPrivilegeEnum::Operate)]
    pending = Datastore::DatastoreStatusEntryStruct.new(Datastore::DatastoreStateEnum::Pending, 0_u32, 0_u8)
    store.endpoint_group_id_list = [Datastore::DatastoreEndpointGroupIDEntryStruct.new(0x100_u64, 1_u16, 2_u16, pending)]

    Matter::Controller::DatastoreSynchronizer.new(im).sync_node(store, 0x100_u64, datastore_session,
      Socket::IPAddress.new("127.0.0.1", 5540))
    entry = store.endpoint_group_id_list.first
    entry.status_entry.state.should eq(Datastore::DatastoreStateEnum::CommitFailed)
    entry.status_entry.failure_code.should eq(Matter::InteractionModel::StatusCode::Failure.value)
  ensure
    client.try(&.close)
  end

  it "does not erase a pending deletion when RemoveGroupResponse names another group" do
    client = Matter::Controller::Client.new
    im = DatastoreImClient.new(client)
    im.group_response_id = Matter::DataType::GroupId.new(3_u16)
    store = Datastore.new(Matter::DataType::EndpointNumber.new(0_u16))
    deleting = Datastore::DatastoreStatusEntryStruct.new(Datastore::DatastoreStateEnum::DeletePending, 0_u32, 0_u8)
    store.endpoint_group_id_list = [Datastore::DatastoreEndpointGroupIDEntryStruct.new(0x100_u64, 1_u16, 2_u16, deleting)]

    Matter::Controller::DatastoreSynchronizer.new(im).sync_node(store, 0x100_u64, datastore_session,
      Socket::IPAddress.new("127.0.0.1", 5540))
    entry = store.endpoint_group_id_list.first
    entry.status_entry.state.should eq(Datastore::DatastoreStateEnum::DeletePending)
    entry.status_entry.failure_code.should eq(Matter::InteractionModel::StatusCode::Failure.value)
  ensure
    client.try(&.close)
  end

  it "uses Groups when Groupcast is advertised without GKM adoption" do
    client = Matter::Controller::Client.new
    im = DatastoreImClient.new(client)
    im.server_lists[0_u16] = [Matter::Cluster::Groupcast::CLUSTER_ID]
    im.groupcast_adoption_supported = false
    store = Datastore.new(Matter::DataType::EndpointNumber.new(0_u16))
    store.group_list = [Datastore::DatastoreGroupInformationEntryStruct.new(
      2_u64, "kitchen", 1_u16, nil, nil, Datastore::DatastoreAccessControlEntryPrivilegeEnum::Operate)]
    pending = Datastore::DatastoreStatusEntryStruct.new(Datastore::DatastoreStateEnum::Pending, 0_u32, 0_u8)
    store.endpoint_group_id_list = [Datastore::DatastoreEndpointGroupIDEntryStruct.new(0x100_u64, 1_u16, 2_u16, pending)]

    Matter::Controller::DatastoreSynchronizer.new(im).sync_node(store, 0x100_u64, datastore_session,
      Socket::IPAddress.new("127.0.0.1", 5540))
    im.commands.should eq([Matter::Cluster::Groups::CMD_ADD_GROUP])
    store.endpoint_group_id_list.first.status_entry.state.should eq(Datastore::DatastoreStateEnum::Committed)
  ensure
    client.try(&.close)
  end

  it "refuses to rewrite a group key map from another fabric" do
    client = Matter::Controller::Client.new
    im = DatastoreImClient.new(client)
    im.group_key_map = [Matter::Cluster::GroupKeyManagement::GroupKeyMapStruct.new(3_u16, 1_u16, 1_u8)]
    store = Datastore.new(Matter::DataType::EndpointNumber.new(0_u16))
    store.group_list = [Datastore::DatastoreGroupInformationEntryStruct.new(
      2_u64, "kitchen", 1_u16, nil, nil, Datastore::DatastoreAccessControlEntryPrivilegeEnum::Operate)]
    pending = Datastore::DatastoreStatusEntryStruct.new(Datastore::DatastoreStateEnum::Pending, 0_u32, 0_u8)
    store.endpoint_group_id_list = [Datastore::DatastoreEndpointGroupIDEntryStruct.new(0x100_u64, 1_u16, 2_u16, pending)]

    Matter::Controller::DatastoreSynchronizer.new(im).sync_node(store, 0x100_u64, datastore_session,
      Socket::IPAddress.new("127.0.0.1", 5540))
    im.writes.should be_empty
    im.commands.should be_empty
    store.endpoint_group_id_list.first.status_entry.state.should eq(Datastore::DatastoreStateEnum::CommitFailed)
  ensure
    client.try(&.close)
  end
end

describe Matter::Cluster::Binding do
  it "isolates and persists bindings by fabric" do
    binding = Matter::Cluster::Binding.new(Matter::DataType::EndpointNumber.new(1_u16))
    binding.request_fabric_index = 1_u8
    binding.binding = [Matter::Cluster::Binding::Target.new(node: 0x100_u64, endpoint: 1_u16)]
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
