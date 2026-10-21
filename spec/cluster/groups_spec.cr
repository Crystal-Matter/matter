require "../spec_helper"
require "../../src/matter/cluster/groups"

alias GroupsDef = Matter::Cluster::Groups
alias GroupsStatus = Matter::InteractionModel::StatusCode

def add_test_group(cluster, id : UInt16, name = "")
  invoke_response(cluster, Matter::Cluster::Groups::CMD_ADD_GROUP,
    GroupsDef::AddGroupRequest.new(Matter::DataType::GroupId.new(id), name), GroupsDef::AddGroupResponse)
end

def view_test_group(cluster, id : UInt16)
  invoke_response(cluster, Matter::Cluster::Groups::CMD_VIEW_GROUP,
    GroupsDef::ViewGroupRequest.new(Matter::DataType::GroupId.new(id)), GroupsDef::ViewGroupResponse)
end

def remove_test_group(cluster, id : UInt16)
  invoke_response(cluster, Matter::Cluster::Groups::CMD_REMOVE_GROUP,
    GroupsDef::RemoveGroupRequest.new(Matter::DataType::GroupId.new(id)), GroupsDef::RemoveGroupResponse)
end

def test_group_membership(cluster, ids = [] of UInt16)
  invoke_response(cluster, Matter::Cluster::Groups::CMD_GET_GROUP_MEMBERSHIP,
    GroupsDef::GetGroupMembershipRequest.new(ids.map { |id| Matter::DataType::GroupId.new(id) }), GroupsDef::GetGroupMembershipResponse)
end

describe Matter::Cluster::Groups do
  it "updates the GroupTable through fabric-scoped membership callbacks" do
    groups = GroupsDef.new(Matter::DataType::EndpointNumber.new(1_u16))
    key_management = Matter::Cluster::GroupKeyManagement.new(Matter::DataType::EndpointNumber.new(0_u16))
    key_management.handle_key_set_write(Matter::Cluster::GroupKeyManagement::KeySetWriteRequest.new(
      Matter::Cluster::GroupKeyManagement::GroupKeySetStruct.new(5_u16,
        epoch_key0: Bytes.new(16, 1_u8), epoch_start_time0: 1_u64)), 1_u8)
    key_management.add_group_key_map(257_u16, 5_u16, 1_u8)
    groups.on_group_added = ->(id : UInt16, endpoint : UInt16, name : String, fabric : UInt8) do
      key_management.add_group(id, endpoint, name, fabric)
    end
    groups.on_group_removed = ->(id : UInt16, endpoint : UInt16, fabric : UInt8) do
      key_management.remove_group(id, endpoint, fabric)
    end

    groups.with_request_context do
      groups.request_fabric_index = 1_u8
      groups.add_group(GroupsDef::AddGroupRequest.new(Matter::DataType::GroupId.new(257_u16), "Office"))
      key_management.group_table(1_u8).first.endpoints.should eq([1_u16])
      groups.remove_group(GroupsDef::RemoveGroupRequest.new(Matter::DataType::GroupId.new(257_u16)))
      key_management.group_table(1_u8).should be_empty
      key_management.group_key_map(1_u8).size.should eq(1)
      groups.add_group(GroupsDef::AddGroupRequest.new(Matter::DataType::GroupId.new(257_u16), "Office"))
      groups.remove_all_groups
      key_management.group_table(1_u8).should be_empty
      key_management.group_key_map(1_u8).size.should eq(1)
    end
  end

  it "keeps group names and membership scoped to the requesting fabric across restore" do
    groups = GroupsDef.new(Matter::DataType::EndpointNumber.new(1_u16))
    groups.with_request_context do
      groups.request_fabric_index = 1_u8
      groups.add_group(GroupsDef::AddGroupRequest.new(Matter::DataType::GroupId.new(257_u16), "First"))
      groups.request_fabric_index = 2_u8
      groups.view_group(GroupsDef::ViewGroupRequest.new(Matter::DataType::GroupId.new(257_u16))).status_code.should eq(GroupsStatus::NotFound)
      groups.add_group(GroupsDef::AddGroupRequest.new(Matter::DataType::GroupId.new(257_u16), "Second"))
    end

    restored = GroupsDef.new(Matter::DataType::EndpointNumber.new(1_u16))
    restored.restore_state(groups.save_state.as(Matter::Storage::Document))
    restored.with_request_context do
      restored.request_fabric_index = 1_u8
      restored.view_group(GroupsDef::ViewGroupRequest.new(Matter::DataType::GroupId.new(257_u16))).group_name.should eq("First")
      restored.request_fabric_index = 2_u8
      restored.view_group(GroupsDef::ViewGroupRequest.new(Matter::DataType::GroupId.new(257_u16))).group_name.should eq("Second")
      restored.remove_all_groups
      restored.get_group_membership(GroupsDef::GetGroupMembershipRequest.new([] of Matter::DataType::GroupId)).group_list.should be_empty
      restored.request_fabric_index = 1_u8
      restored.get_group_membership(GroupsDef::GetGroupMembershipRequest.new([] of Matter::DataType::GroupId)).group_list.map(&.id).should eq([257_u16])
    end
  end

  it "creates cluster with default values" do
    cluster = build(Matter::Cluster::Groups)
    cluster.name.should eq("Groups")
    cluster.cluster_id.id.should eq(Matter::Cluster::Groups::CLUSTER_ID)
    cluster.feature_map.group_names?.should be_true
    cluster.groups.should be_empty
    cluster.group_count.should eq(0)
  end

  it "creates cluster without group names" do
    cluster = build(Matter::Cluster::Groups, feature_map: Matter::Cluster::Groups::Feature::None)
    cluster.feature_map.group_names?.should be_false
    read(cluster, Matter::Cluster::Groups::ATTR_NAME_SUPPORT).should eq(0_u8)
  end

  it "reports group name support" do
    cluster = build(Matter::Cluster::Groups)
    read(cluster, Matter::Cluster::Groups::ATTR_NAME_SUPPORT).should eq(1_u8)
    read(cluster, Matter::Cluster::Base::GLOBAL_FEATURE_MAP).should eq(1_u32)
    cluster.attributes.size.should eq(1)
    cluster.attributes.first.name.should eq("nameSupport")
    cluster.attributes.first.writable?.should be_false
  end

  it "advertises its request and response commands" do
    cluster = build(Matter::Cluster::Groups)
    accepted_command_ids(cluster).should eq([0_u32, 1_u32, 2_u32, 3_u32, 4_u32, 5_u32])
    generated_command_ids(cluster).should eq([0_u32, 1_u32, 2_u32, 3_u32])
  end

  it "adds a group and returns a tagged AddGroupResponse" do
    cluster = build(Matter::Cluster::Groups)
    version = cluster.data_version
    response = add_test_group(cluster, 1234_u16, "Living Room")
    response.status_code.should eq(GroupsStatus::Success)
    response.group_id.id.should eq(1234_u16)
    cluster.member_of?(1234_u16).should be_true
    cluster.group_count.should eq(1)
    cluster.data_version.should eq(version + 1)
  end

  it "views an existing group" do
    cluster = build(Matter::Cluster::Groups)
    add_test_group(cluster, 2_u16, "Kitchen")
    response = view_test_group(cluster, 2_u16)
    response.status_code.should eq(GroupsStatus::Success)
    response.group_id.id.should eq(2_u16)
    response.group_name.should eq("Kitchen")
  end

  it "returns NotFound and an empty name for an absent group" do
    cluster = build(Matter::Cluster::Groups)
    response = view_test_group(cluster, 9999_u16)
    response.status_code.should eq(GroupsStatus::NotFound)
    response.group_id.id.should eq(9999_u16)
    response.group_name.should eq("")
  end

  it "returns all memberships for an empty requested list" do
    cluster = build(Matter::Cluster::Groups, max_groups: 16_u8)
    [1_u16, 2_u16, 3_u16].each { |id| add_test_group(cluster, id) }
    response = test_group_membership(cluster)
    response.capacity.should eq(13_u8)
    response.group_list.map(&.id).should eq([1_u16, 2_u16, 3_u16])
  end

  it "filters memberships to requested groups" do
    cluster = build(Matter::Cluster::Groups)
    [1_u16, 2_u16, 3_u16].each { |id| add_test_group(cluster, id) }
    response = test_group_membership(cluster, [2_u16, 9_u16, 2_u16])
    response.group_list.map(&.id).should eq([2_u16])
    response.capacity.should eq(13_u8)
  end

  it "encodes unknown membership capacity as TLV null" do
    response = GroupsDef::GetGroupMembershipResponse.new(nil, [] of Matter::DataType::GroupId)
    value = response.to_tlv(nil)
    value[0_u8].value.should be_nil
    GroupsDef::GetGroupMembershipResponse.from_tlv(value).capacity.should be_nil
  end

  it "removes an existing group and increments the version" do
    cluster = build(Matter::Cluster::Groups)
    add_test_group(cluster, 16_u16, "Bedroom")
    version = cluster.data_version
    response = remove_test_group(cluster, 16_u16)
    response.status_code.should eq(GroupsStatus::Success)
    response.group_id.id.should eq(16_u16)
    cluster.member_of?(16_u16).should be_false
    cluster.group_count.should eq(0)
    cluster.data_version.should eq(version + 1)
  end

  it "returns NotFound when removing an absent group" do
    cluster = build(Matter::Cluster::Groups)
    response = remove_test_group(cluster, 9999_u16)
    response.status_code.should eq(GroupsStatus::NotFound)
    response.group_id.id.should eq(9999_u16)
  end

  it "removes all groups and increments the version" do
    cluster = build(Matter::Cluster::Groups)
    [1_u16, 2_u16].each { |id| add_test_group(cluster, id) }
    version = cluster.data_version
    expect_success(invoke(cluster, Matter::Cluster::Groups::CMD_REMOVE_ALL_GROUPS, GroupsDef::RemoveAllGroupsRequest.new))
    cluster.groups.should be_empty
    cluster.data_version.should eq(version + 1)
  end

  it "decodes AddGroupIfIdentifying" do
    cluster = build(Matter::Cluster::Groups)
    request = GroupsDef::AddGroupIfIdentifyingRequest.new(Matter::DataType::GroupId.new(32_u16), "Office")
    expect_success(invoke(cluster, Matter::Cluster::Groups::CMD_ADD_GROUP_IF_IDENTIFYING, request))
    cluster.groups[32_u16].should eq("Office")
  end

  it "rejects AddGroup when the name field is missing" do
    cluster = build(Matter::Cluster::Groups)
    request = GroupsDef::ViewGroupRequest.new(Matter::DataType::GroupId.new(1_u16))
    expect_status(invoke(cluster, Matter::Cluster::Groups::CMD_ADD_GROUP, request), GroupsStatus::InvalidCommand)
    cluster.groups.should be_empty
  end

  it "rejects missing required command fields" do
    cluster = build(Matter::Cluster::Groups)
    [Matter::Cluster::Groups::CMD_ADD_GROUP, Matter::Cluster::Groups::CMD_VIEW_GROUP,
     Matter::Cluster::Groups::CMD_REMOVE_GROUP, Matter::Cluster::Groups::CMD_GET_GROUP_MEMBERSHIP,
     Matter::Cluster::Groups::CMD_ADD_GROUP_IF_IDENTIFYING].each do |command|
      expect_status(invoke(cluster, command), GroupsStatus::InvalidCommand)
    end
  end

  it "respects the group table capacity" do
    cluster = build(Matter::Cluster::Groups, max_groups: 3_u8)
    [1_u16, 2_u16, 3_u16].each { |id| add_test_group(cluster, id).status_code.should eq(GroupsStatus::Success) }
    add_test_group(cluster, 4_u16).status_code.should eq(GroupsStatus::ResourceExhausted)
    cluster.group_count.should eq(3)
    test_group_membership(cluster).capacity.should eq(0_u8)
  end

  it "updates an existing group when the table is full" do
    cluster = build(Matter::Cluster::Groups, max_groups: 2_u8)
    [1_u16, 2_u16].each { |id| add_test_group(cluster, id) }
    add_test_group(cluster, 1_u16, "Updated").status_code.should eq(GroupsStatus::Success)
    cluster.group_count.should eq(2)
    view_test_group(cluster, 1_u16).group_name.should eq("Updated")
  end

  describe "constraints (Matter 1.4 §1.3.7.1)" do
    reserved_group = Matter::Cluster::Groups::GROUP_ID_MIN - 1
    too_long_name = "x" * (Matter::Cluster::Groups::GROUP_NAME_MAX_LENGTH + 1)
    # 16 bytes of UTF-8 but only 8 characters: the limit is in bytes.
    max_length_name = "é" * (Matter::Cluster::Groups::GROUP_NAME_MAX_LENGTH // "é".bytesize)
    max_length_name.bytesize.should eq(Matter::Cluster::Groups::GROUP_NAME_MAX_LENGTH)

    it "answers AddGroup for the reserved group id with ConstraintError" do
      cluster = build(Matter::Cluster::Groups)
      response = add_test_group(cluster, reserved_group, "Kitchen")
      response.status_code.should eq(GroupsStatus::ConstraintError)
      response.group_id.id.should eq(reserved_group)
      cluster.groups.should be_empty
    end

    it "answers AddGroup with a name over #{Matter::Cluster::Groups::GROUP_NAME_MAX_LENGTH} bytes with ConstraintError" do
      cluster = build(Matter::Cluster::Groups)
      add_test_group(cluster, 1_u16, too_long_name).status_code.should eq(GroupsStatus::ConstraintError)
      cluster.groups.should be_empty
      add_test_group(cluster, 1_u16, max_length_name).status_code.should eq(GroupsStatus::Success)
      cluster.groups[1_u16].should eq(max_length_name)
    end

    it "answers AddGroupIfIdentifying constraint violations with ConstraintError" do
      cluster = build(Matter::Cluster::Groups)
      command = Matter::Cluster::Groups::CMD_ADD_GROUP_IF_IDENTIFYING
      request = GroupsDef::AddGroupIfIdentifyingRequest.new(Matter::DataType::GroupId.new(reserved_group), "Kitchen")
      expect_status(invoke(cluster, command, request), GroupsStatus::ConstraintError)
      request = GroupsDef::AddGroupIfIdentifyingRequest.new(Matter::DataType::GroupId.new(1_u16), too_long_name)
      expect_status(invoke(cluster, command, request), GroupsStatus::ConstraintError)
      cluster.groups.should be_empty
    end

    it "answers ViewGroup and RemoveGroup for the reserved group id with ConstraintError" do
      cluster = build(Matter::Cluster::Groups)
      view = view_test_group(cluster, reserved_group)
      view.status_code.should eq(GroupsStatus::ConstraintError)
      view.group_id.id.should eq(reserved_group)
      view.group_name.should eq("")
      remove = remove_test_group(cluster, reserved_group)
      remove.status_code.should eq(GroupsStatus::ConstraintError)
      remove.group_id.id.should eq(reserved_group)
    end
  end
end
