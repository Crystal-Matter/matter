require "../spec_helper"
require "../../src/matter/cluster/access_control"
require "../../src/matter/cluster/groups"
require "../../src/matter/protocol/im_handler"

private alias GroupsACL = Matter::Cluster::AccessControl
private alias GroupsWire = Matter::Cluster::Groups
private alias GroupsIM = Matter::InteractionModel

private def invoke_groups_case(
  command_id : UInt32,
  request,
  clusters : Hash(Tuple(UInt16, UInt32), Matter::Cluster::Base),
  subject : UInt64,
) : GroupsIM::InvokeResponseIB
  path = GroupsIM::CommandPath.new(1_u16, GroupsWire::CLUSTER_ID, command_id)
  fields = request.nil? ? nil : TLV::Serializable.serialize_value(request, nil)
  wire = GroupsIM::InvokeRequestMessage.new([GroupsIM::CommandDataIBTlv.new(path, fields)]).to_slice
  parsed = Matter::Protocol::IMHandler.parse_invoke_request(wire)
  parsed.should_not be_nil
  Matter::Protocol::IMHandler.invoke_commands(parsed.as(GroupsIM::InvokeRequestMessage).invoke_requests, clusters,
    fabric_index: 1_u8, is_case_session: true, peer_subject_ids: [subject]).first
end

private def groups_wire_status(response : GroupsIM::InvokeResponseIB) : GroupsIM::StatusCode?
  response.command_status.try { |status| GroupsIM::StatusCode.new(status.status.status) }
end

private def groups_wire_data(response : GroupsIM::InvokeResponseIB) : TLV::Any
  data = response.command_data
  data.should_not be_nil
  fields = data.as(GroupsIM::CommandDataIBTlv).command_fields
  fields.should_not be_nil
  fields.as(TLV::Any)
end

describe "Groups command privileges over CASE InvokeRequest" do
  it "requires Manage for fabric membership changes and permits Operate membership queries" do
    acl = GroupsACL.new(endpoint(0))
    groups = GroupsWire.new(endpoint(1))
    clusters = {} of Tuple(UInt16, UInt32) => Matter::Cluster::Base
    clusters[{0_u16, GroupsACL::CLUSTER_ID}] = acl
    clusters[{1_u16, GroupsWire::CLUSTER_ID}] = groups

    operate_subject = 0x1111_u64
    manage_subject = 0x2222_u64
    acl.acl << GroupsACL::AccessControlEntry.new(
      GroupsACL::AccessControlEntryPrivilege::Operate,
      GroupsACL::AccessControlEntryAuthMode::CASE, [operate_subject], nil, 1_u8)
    acl.acl << GroupsACL::AccessControlEntry.new(
      GroupsACL::AccessControlEntryPrivilege::Manage,
      GroupsACL::AccessControlEntryAuthMode::CASE, [manage_subject], nil, 1_u8)

    group_id = Matter::DataType::GroupId.new(0x1234_u16)
    add = GroupsWire::AddGroupRequest.new(group_id, "Kitchen")
    remove = GroupsWire::RemoveGroupRequest.new(group_id)
    add_if_identifying = GroupsWire::AddGroupIfIdentifyingRequest.new(group_id, "Kitchen")
    view = GroupsWire::ViewGroupRequest.new(group_id)
    membership = GroupsWire::GetGroupMembershipRequest.new([] of Matter::DataType::GroupId)

    # A lower-privilege CASE subject must not be able to create membership.
    groups_wire_status(invoke_groups_case(GroupsWire::CMD_ADD_GROUP, add, clusters, operate_subject))
      .should eq(GroupsIM::StatusCode::UnsupportedAccess)
    groups_wire_status(invoke_groups_case(GroupsWire::CMD_ADD_GROUP_IF_IDENTIFYING,
      add_if_identifying, clusters, operate_subject)).should eq(GroupsIM::StatusCode::UnsupportedAccess)

    # Manage can create membership; Operate can inspect it but cannot delete it.
    manage_add = invoke_groups_case(GroupsWire::CMD_ADD_GROUP, add, clusters, manage_subject)
    manage_add.command_data.should_not be_nil
    visible = invoke_groups_case(GroupsWire::CMD_VIEW_GROUP, view, clusters, operate_subject)
    GroupsWire::ViewGroupResponse.from_tlv(groups_wire_data(visible))
      .group_name.should eq("Kitchen")
    listed = invoke_groups_case(GroupsWire::CMD_GET_GROUP_MEMBERSHIP, membership, clusters, operate_subject)
    GroupsWire::GetGroupMembershipResponse.from_tlv(groups_wire_data(listed))
      .group_list.map(&.id).should eq([group_id.id])

    groups_wire_status(invoke_groups_case(GroupsWire::CMD_REMOVE_GROUP, remove, clusters, operate_subject))
      .should eq(GroupsIM::StatusCode::UnsupportedAccess)
    groups_wire_status(invoke_groups_case(GroupsWire::CMD_REMOVE_ALL_GROUPS, nil, clusters, operate_subject))
      .should eq(GroupsIM::StatusCode::UnsupportedAccess)
    listed = invoke_groups_case(GroupsWire::CMD_GET_GROUP_MEMBERSHIP, membership, clusters, operate_subject)
    GroupsWire::GetGroupMembershipResponse.from_tlv(groups_wire_data(listed))
      .group_list.map(&.id).should eq([group_id.id])

    manage_remove = invoke_groups_case(GroupsWire::CMD_REMOVE_GROUP, remove, clusters, manage_subject)
    manage_remove.command_data.should_not be_nil
    groups_wire_status(invoke_groups_case(GroupsWire::CMD_ADD_GROUP_IF_IDENTIFYING,
      add_if_identifying, clusters, manage_subject)).should eq(GroupsIM::StatusCode::Success)
    groups_wire_status(invoke_groups_case(GroupsWire::CMD_REMOVE_ALL_GROUPS, nil, clusters, manage_subject))
      .should eq(GroupsIM::StatusCode::Success)
    listed = invoke_groups_case(GroupsWire::CMD_GET_GROUP_MEMBERSHIP, membership, clusters, operate_subject)
    GroupsWire::GetGroupMembershipResponse.from_tlv(groups_wire_data(listed)).group_list.should be_empty
  end
end
