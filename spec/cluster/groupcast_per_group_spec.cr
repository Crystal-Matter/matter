require "../spec_helper"

private alias GC = Matter::Cluster::Groupcast
private alias GKM = Matter::Cluster::GroupKeyManagement
private alias ACL = Matter::Cluster::AccessControl
private alias Status = Matter::InteractionModel::Status

private def per_group_fixture(features = GC::Feature::Listener | GC::Feature::PerGroup,
                              max_addresses = 4_u16)
  root = Matter::DataType::EndpointNumber.new(0_u16)
  keys = GKM.new(root, feature_map: GKM::Feature::Groupcast, max_groups_per_fabric: 0_u16)
  acl_features = ACL::Feature::Extension
  acl_features |= ACL::Feature::Auxiliary if features.listener?
  acl = ACL.new(root, feature_map: acl_features)
  acl.acl = [ACL::AccessControlEntry.new(ACL::AccessControlEntryPrivilege::Administer,
    ACL::AccessControlEntryAuthMode::CASE, [10_u64], nil, 1_u8)]
  cluster = GC.new(root, keys, acl, feature_map: features, max_mcast_addr_count: max_addresses)
  cluster.request_is_case_session = true
  cluster.request_fabric_index = 1_u8
  cluster.request_peer_node_id = 10_u64
  cluster.request_peer_subject_ids = [10_u64]
  {cluster, keys}
end

private def join_per_group(cluster : GC, id : UInt16, key_set : UInt16 = 7_u16)
  cluster.join_group(GC::JoinGroupRequest.new(id, [1_u16], key_set,
    mcast_addr_policy: GC::MulticastAddrPolicyEnum::PerGroup))
end

describe "Matter 1.6 Groupcast PerGroup" do
  it "requires an explicit PGA feature and retains the legacy IANA policy by default" do
    plain, keys = per_group_fixture(GC::Feature::Listener)
    keys.handle_key_set_write(GKM::KeySetWriteRequest.new(
      GKM::GroupKeySetStruct.new(7_u16, epoch_key0: Bytes.new(16, 0x77_u8),
        epoch_start_time0: 1_u64)), 1_u8)
    join_per_group(plain, 0x1234_u16).should eq(Status.constraint_error)
    plain.join_group(GC::JoinGroupRequest.new(0x1234_u16, [1_u16], 7_u16)).should eq(Status.success)
    plain.membership(1_u8).first.mcast_addr_policy.iana_addr?.should be_true

    enabled, _ = per_group_fixture
    enabled.feature_map.per_group?.should be_true
  end

  it "counts policy addresses before changing keys or membership" do
    cluster, keys = per_group_fixture(max_addresses: 4_u16)
    keys.handle_key_set_write(GKM::KeySetWriteRequest.new(
      GKM::GroupKeySetStruct.new(7_u16, epoch_key0: Bytes.new(16, 0x77_u8),
        epoch_start_time0: 1_u64)), 1_u8)
    cluster.used_mcast_addr_count.should eq(0)
    cluster.join_group(GC::JoinGroupRequest.new(0x1111_u16, [1_u16], 7_u16)).should eq(Status.success)
    cluster.join_group(GC::JoinGroupRequest.new(0x2222_u16, [1_u16], 7_u16)).should eq(Status.success)
    cluster.used_mcast_addr_count.should eq(1)
    join_per_group(cluster, 0x1111_u16).should eq(Status.success)
    cluster.used_mcast_addr_count.should eq(2)
    join_per_group(cluster, 0x3333_u16).should eq(Status.success)
    join_per_group(cluster, 0x4444_u16).should eq(Status.success)
    cluster.used_mcast_addr_count.should eq(4)
    cluster.join_group(GC::JoinGroupRequest.new(0x5555_u16, [1_u16], 8_u16,
      key: Bytes.new(16, 0x88_u8),
      mcast_addr_policy: GC::MulticastAddrPolicyEnum::PerGroup)).should eq(Status.resource_exhausted)
    keys.get_key_set(8_u16, 1_u8).should be_nil
    cluster.membership(1_u8).size.should eq(4)
    cluster.leave_group(GC::LeaveGroupRequest.new(0x2222_u16)).should be_a(GC::LeaveGroupResponse)
    cluster.used_mcast_addr_count.should eq(3)
    join_per_group(cluster, 0x5555_u16, 8_u16).should eq(Status.not_found)
    join_per_group(cluster, 0x5555_u16, 7_u16).should eq(Status.success)
    cluster.used_mcast_addr_count.should eq(4)
    # Matter 1.6 defines an omitted policy on JoinGroup as IanaAddr, even
    # when the group previously used PerGroup.
    cluster.join_group(GC::JoinGroupRequest.new(0x1111_u16, [1_u16], 7_u16)).should eq(Status.success)
    cluster.membership(1_u8).find(&.group_id.==(0x1111_u16)).as(GC::MembershipStruct)
      .mcast_addr_policy.iana_addr?.should be_true
    cluster.used_mcast_addr_count.should eq(4)
  end

  it "restores PerGroup policy and releases addresses on fabric removal" do
    cluster, keys = per_group_fixture
    keys.handle_key_set_write(GKM::KeySetWriteRequest.new(
      GKM::GroupKeySetStruct.new(7_u16, epoch_key0: Bytes.new(16, 0x77_u8),
        epoch_start_time0: 1_u64)), 1_u8)
    join_per_group(cluster, 0x1111_u16).should eq(Status.success)
    saved = cluster.save_state.as(Matter::Storage::Document)
    disabled, _ = per_group_fixture(GC::Feature::Listener)
    expect_raises(Matter::ConfigurationError, /requires PGA/) { disabled.restore_state(saved) }
    restored, restored_keys = per_group_fixture
    restored_keys.restore_state(keys.save_state.as(Matter::Storage::Document))
    restored.restore_state(saved)
    restored.membership(1_u8).first.mcast_addr_policy.per_group?.should be_true
    restored.used_mcast_addr_count.should eq(1)
    restored.remove_fabric(1_u8)
    restored.used_mcast_addr_count.should eq(0)
  end

  it "counts PerGroup addresses separately for two fabrics" do
    cluster, keys = per_group_fixture(max_addresses: 4_u16)
    (1_u8..2_u8).each do |fabric|
      keys.handle_key_set_write(GKM::KeySetWriteRequest.new(
        GKM::GroupKeySetStruct.new(7_u16, epoch_key0: Bytes.new(16, 0x77_u8),
          epoch_start_time0: 1_u64)), fabric)
      cluster.request_fabric_index = fabric
      join_per_group(cluster, 0x1111_u16).should eq(Status.success)
    end
    cluster.used_mcast_addr_count.should eq(2)
    cluster.membership(1_u8).size.should eq(1)
    cluster.membership(2_u8).size.should eq(1)
    cluster.remove_fabric(1_u8)
    cluster.used_mcast_addr_count.should eq(1)
    cluster.membership(2_u8).size.should eq(1)
  end

  it "counts sender policy addresses without joining a receive socket" do
    sender, keys = per_group_fixture(GC::Feature::Sender | GC::Feature::PerGroup)
    keys.handle_key_set_write(GKM::KeySetWriteRequest.new(
      GKM::GroupKeySetStruct.new(7_u16, epoch_key0: Bytes.new(16, 0x77_u8),
        epoch_start_time0: 1_u64)), 1_u8)
    sender.join_group(GC::JoinGroupRequest.new(0x1111_u16, [] of UInt16, 7_u16,
      mcast_addr_policy: GC::MulticastAddrPolicyEnum::PerGroup)).should eq(Status.success)
    sender.used_mcast_addr_count.should eq(1)
  end

  it "rejects PGA configurations with fewer than four multicast addresses" do
    root = Matter::DataType::EndpointNumber.new(0_u16)
    keys = GKM.new(root, feature_map: GKM::Feature::Groupcast, max_groups_per_fabric: 0_u16)
    acl = ACL.new(root, feature_map: ACL::Feature::Extension | ACL::Feature::Auxiliary)
    expect_raises(Matter::ConfigurationError, /at least four addresses/) do
      GC.new(root, keys, acl, feature_map: GC::Feature::Listener | GC::Feature::PerGroup,
        max_mcast_addr_count: 3_u16)
    end
  end
end
