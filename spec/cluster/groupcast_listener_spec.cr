require "../spec_helper"

private alias GroupcastServer = Matter::Cluster::Groupcast
private alias GroupKeys = Matter::Cluster::GroupKeyManagement
private alias GroupAcl = Matter::Cluster::AccessControl
private alias IMStatus = Matter::InteractionModel::StatusCode

private def listener_fixture
  root = Matter::DataType::EndpointNumber.new(0_u16)
  keys = GroupKeys.new(root, feature_map: GroupKeys::Feature::Groupcast,
    max_groups_per_fabric: 0_u16)
  acl = GroupAcl.new(root, feature_map: GroupAcl::Feature::Extension | GroupAcl::Feature::Auxiliary)
  listener = GroupcastServer.new(root, keys, acl)
  {listener, keys, acl}
end

private def as_fabric(cluster : Matter::Cluster::Base, index : UInt8, admin : UInt64 = 10_u64, &)
  cluster.with_request_context do
    cluster.request_fabric_index = index
    cluster.request_is_case_session = true
    cluster.request_peer_node_id = admin
    cluster.request_peer_subject_ids = [admin]
    yield
  ensure
    cluster.request_fabric_index = nil
    cluster.request_is_case_session = false
    cluster.request_peer_node_id = nil
    cluster.request_peer_subject_ids = nil
  end
end

describe "Matter 1.6 Groupcast Listener" do
  it "keeps adopted membership and its effective group ACL fabric-scoped" do
    listener, keys, acl = listener_fixture
    key = Bytes.new(16, 0xAA_u8)
    acl.acl = [GroupAcl::AccessControlEntry.new(GroupAcl::AccessControlEntryPrivilege::Administer,
      GroupAcl::AccessControlEntryAuthMode::CASE, [10_u64], nil, 1_u8)]

    as_fabric(listener, 1_u8) do
      listener.join_group(GroupcastServer::JoinGroupRequest.new(0x1234_u16, [1_u16], 1_u16,
        key: key, use_auxiliary_acl: true)).should eq(Matter::InteractionModel::Status.success)
    end
    listener.membership(1_u8).map(&.group_id).should eq([0x1234_u16])
    listener.membership(2_u8).should be_empty
    listener.read_attribute(GroupcastServer::ATTR_MEMBERSHIP, nil).as(TLV::Any).as_list.should be_empty
    acl.auxiliary_acl(1_u8).size.should eq(1)
    acl.auxiliary_acl(2_u8).should be_empty
    acl.read_attribute(GroupAcl::ATTR_AUXILIARY_ACL, nil).as(TLV::Any).as_list.should be_empty
    acl.check_access(0x1234_u64, 1_u8, GroupAcl::AccessControlEntryPrivilege::Operate,
      endpoint: 1_u16, auth_mode: GroupAcl::AccessControlEntryAuthMode::Group).should be_true
    acl.check_access(0x1234_u64, 2_u8, GroupAcl::AccessControlEntryPrivilege::Operate,
      endpoint: 1_u16, auth_mode: GroupAcl::AccessControlEntryAuthMode::Group).should be_false

    as_fabric(keys, 1_u8) do
      keys.groupcast_adoption = [GroupKeys::GroupcastAdoptionStruct.new(true)]
    end
    keys.group_key_map(1_u8).should be_empty
    keys.group_table(1_u8).should be_empty
    keys.operational_group_key_map(1_u8).map(&.group_id).should eq([0x1234_u16])
    keys.operational_group_table(1_u8).first.endpoints.should eq([1_u16])
    keys.write_group_key_map(TLV::Serializable.serialize_value([] of GroupKeys::GroupKeyMapStruct, nil),
      1_u8).status.should eq(IMStatus::InvalidInState)
  end

  it "restores membership and adoption, then removes both before fabric index reuse" do
    listener, keys, acl = listener_fixture
    acl.acl = [GroupAcl::AccessControlEntry.new(GroupAcl::AccessControlEntryPrivilege::Administer,
      GroupAcl::AccessControlEntryAuthMode::CASE, [10_u64], nil, 1_u8)]
    keys.handle_key_set_write(GroupKeys::KeySetWriteRequest.new(
      GroupKeys::GroupKeySetStruct.new(1_u16, epoch_key0: Bytes.new(16, 0xAA_u8),
        epoch_start_time0: 1_u64)), 1_u8)
    as_fabric(listener, 1_u8) do
      listener.join_group(GroupcastServer::JoinGroupRequest.new(0x1234_u16, [1_u16], 1_u16,
        use_auxiliary_acl: true)).should eq(Matter::InteractionModel::Status.success)
    end
    as_fabric(keys, 1_u8) do
      keys.groupcast_adoption = [GroupKeys::GroupcastAdoptionStruct.new(true)]
    end

    saved_keys = keys.save_state.as(Matter::Storage::Document)
    saved_listener = listener.save_state.as(Matter::Storage::Document)
    recovered, recovered_keys, recovered_acl = listener_fixture
    recovered_keys.restore_state(saved_keys)
    recovered.restore_state(saved_listener)
    recovered_keys.groupcast_adopted?(1_u8).should be_true
    recovered.membership(1_u8).size.should eq(1)
    recovered_acl.auxiliary_acl(1_u8).size.should eq(1)

    recovered.remove_fabric(1_u8)
    recovered_keys.remove_fabric(1_u8)
    recovered_acl.remove_fabric_acl(1_u8)
    recovered.membership(1_u8).should be_empty
    recovered_keys.groupcast_adopted?(1_u8).should be_false
    recovered_acl.auxiliary_acl(1_u8).should be_empty
  end

  it "keeps LeaveGroupResponse within its 20-endpoint wire bound" do
    listener, keys, acl = listener_fixture
    acl.acl = [GroupAcl::AccessControlEntry.new(GroupAcl::AccessControlEntryPrivilege::Administer,
      GroupAcl::AccessControlEntryAuthMode::CASE, [10_u64], nil, 1_u8)]
    endpoints = (1_u16..21_u16).to_a
    as_fabric(listener, 1_u8) do
      listener.join_group(GroupcastServer::JoinGroupRequest.new(0x1234_u16, endpoints.first(20), 1_u16,
        key: Bytes.new(16, 0xAA_u8))).should eq(Matter::InteractionModel::Status.success)
      listener.join_group(GroupcastServer::JoinGroupRequest.new(0x1234_u16, [21_u16], 1_u16))
        .should eq(Matter::InteractionModel::Status.success)

      removed = listener.leave_group(GroupcastServer::LeaveGroupRequest.new(0x1234_u16, endpoints.first(20)))
        .as(GroupcastServer::LeaveGroupResponse)
      removed.endpoints.should eq(endpoints.first(20))
      listener.join_group(GroupcastServer::JoinGroupRequest.new(0x1234_u16, endpoints.first(20), 1_u16))
        .should eq(Matter::InteractionModel::Status.success)
      listener.membership(1_u8).first.endpoints.size.should eq(21)
      keys.operational_group_table(1_u8).first.endpoints.size.should eq(21)

      listener.leave_group(GroupcastServer::LeaveGroupRequest.new(0x1234_u16))
        .as(GroupcastServer::LeaveGroupResponse).endpoints.should be_empty
      listener.membership(1_u8).should be_empty
      keys.operational_group_table(1_u8).should be_empty
    end
  end

  it "rejects a present empty LeaveGroup endpoints list without changing membership" do
    listener, keys, acl = listener_fixture
    acl.acl = [GroupAcl::AccessControlEntry.new(GroupAcl::AccessControlEntryPrivilege::Administer,
      GroupAcl::AccessControlEntryAuthMode::CASE, [10_u64], nil, 1_u8)]
    as_fabric(listener, 1_u8) do
      listener.join_group(GroupcastServer::JoinGroupRequest.new(0x1234_u16, [1_u16], 1_u16,
        key: Bytes.new(16, 0xAA_u8))).should eq(Matter::InteractionModel::Status.success)

      [0x1234_u16, 0_u16].each do |group_id|
        request = GroupcastServer::LeaveGroupRequest.from_slice(
          GroupcastServer::LeaveGroupRequest.new(group_id, [] of UInt16).to_slice)
        request.endpoints.should eq([] of UInt16)
        listener.leave_group(request).should eq(Matter::InteractionModel::Status.constraint_error)
        listener.membership(1_u8).first.endpoints.should eq([1_u16])
        keys.operational_group_table(1_u8).first.endpoints.should eq([1_u16])
      end
    end
  end
end
