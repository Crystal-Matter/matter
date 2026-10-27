require "../spec_helper"

private alias SenderGC = Matter::Cluster::Groupcast
private alias SenderGKM = Matter::Cluster::GroupKeyManagement
private alias SenderACL = Matter::Cluster::AccessControl
private alias SenderStatus = Matter::InteractionModel::Status

private def sender_cluster(features : SenderGC::Feature)
  root = Matter::DataType::EndpointNumber.new(0_u16)
  keys = SenderGKM.new(root, feature_map: SenderGKM::Feature::Groupcast,
    max_groups_per_fabric: 0_u16)
  acl_features = SenderACL::Feature::Extension
  acl_features |= SenderACL::Feature::Auxiliary if features.listener?
  acl = SenderACL.new(root, feature_map: acl_features)
  acl.acl = [SenderACL::AccessControlEntry.new(
    SenderACL::AccessControlEntryPrivilege::Administer,
    SenderACL::AccessControlEntryAuthMode::CASE, [10_u64], nil, 1_u8)]
  cluster = SenderGC.new(root, keys, acl, feature_map: features)
  cluster.request_is_case_session = true
  cluster.request_fabric_index = 1_u8
  cluster.request_peer_node_id = 10_u64
  cluster.request_peer_subject_ids = [10_u64]
  {cluster, keys, acl}
end

describe "Matter 1.6 Groupcast Sender" do
  it "reports AlreadyExists when a supplied key reuses an installed KeySetID" do
    sender, keys, _acl = sender_cluster(SenderGC::Feature::Sender)
    first_key = Bytes.new(16, 0xAA_u8)
    sender.join_group(SenderGC::JoinGroupRequest.new(0x1234_u16, [] of UInt16, 7_u16,
      key: first_key)).should eq(SenderStatus.success)

    sender.join_group(SenderGC::JoinGroupRequest.new(0x1235_u16, [] of UInt16, 7_u16,
      key: Bytes.new(16, 0xBB_u8))).should eq(SenderStatus.already_exists)
    sender.join_group(SenderGC::JoinGroupRequest.new(0x1235_u16, [] of UInt16, 7_u16,
      key: Bytes.new(17, 0xBB_u8))).should eq(SenderStatus.constraint_error)
    sender.membership(1_u8).map(&.group_id).should eq([0x1234_u16])
    keys.get_key_set(7_u16, 1_u8).as(SenderGKM::GroupKeySetStruct).epoch_key0.should eq(first_key)
  end

  it "reports the same duplicate-key status for a Listener-only membership" do
    listener, keys, _acl = sender_cluster(SenderGC::Feature::Listener)
    listener.join_group(SenderGC::JoinGroupRequest.new(0x1234_u16, [1_u16], 7_u16,
      key: Bytes.new(16, 0xAA_u8))).should eq(SenderStatus.success)

    listener.join_group(SenderGC::JoinGroupRequest.new(0x1235_u16, [1_u16], 7_u16,
      key: Bytes.new(16, 0xBB_u8))).should eq(SenderStatus.already_exists)
    listener.membership(1_u8).map(&.group_id).should eq([0x1234_u16])
    keys.operational_group_table(1_u8).map(&.group_id).should eq([0x1234_u16])
  end

  it "advertises SD without LN and records a send-only membership with no multicast listener" do
    sender, keys, acl = sender_cluster(SenderGC::Feature::Sender)
    sender.feature_map.sender?.should be_true
    sender.feature_map.listener?.should be_false
    sender.get_command_metadata(SenderGC::CMD_CONFIGURE_AUXILIARY_ACL).should be_nil

    request = SenderGC::JoinGroupRequest.from_slice(SenderGC::JoinGroupRequest.new(
      0x1234_u16, [] of UInt16, 7_u16, key: Bytes.new(16, 0xAA_u8)).to_slice)
    sender.join_group(request).should eq(SenderStatus.success)
    member = sender.membership(1_u8).first
    member.group_id.should eq(0x1234_u16)
    member.endpoints.should be_empty
    member.has_auxiliary_acl?.should be_false
    fields = member.to_tlv(nil).as_structure
    fields.has_key?(1_u8).should be_false
    fields.has_key?(3_u8).should be_false
    keys.get_key_set(7_u16, 1_u8).should_not be_nil
    keys.operational_group_table(1_u8).should be_empty
    acl.auxiliary_acl(1_u8).should be_empty
    sender.membership(2_u8).should be_empty
    sender.groupcast_testing(SenderGC::GroupcastTestingRequest.new(
      SenderGC::GroupcastTestingEnum::EnableSenderTesting, 10_u16)).should eq(SenderStatus.success)
    sender.fabric_under_test.should eq(1_u8)
  end

  it "rejects listener endpoints and AUX configuration on an SD-only node" do
    sender, keys, _acl = sender_cluster(SenderGC::Feature::Sender)
    sender.join_group(SenderGC::JoinGroupRequest.new(0x1234_u16, [1_u16], 7_u16,
      key: Bytes.new(16, 0xAA_u8))).should eq(SenderStatus.constraint_error)
    sender.join_group(SenderGC::JoinGroupRequest.new(0x1234_u16, [] of UInt16, 7_u16,
      key: Bytes.new(16, 0xAA_u8), use_auxiliary_acl: true)).should eq(SenderStatus.constraint_error)
    keys.get_key_set(7_u16, 1_u8).should be_nil
    sender.membership(1_u8).should be_empty
    sender.groupcast_testing(SenderGC::GroupcastTestingRequest.new(
      SenderGC::GroupcastTestingEnum::EnableListenerTesting)).should eq(SenderStatus.constraint_error)
  end

  it "does not erase an existing legacy listener mapping when SD-only membership changes" do
    sender, keys, _acl = sender_cluster(SenderGC::Feature::Sender)
    group_id = 0x1234_u16
    keys.replace_groupcast_membership(group_id, [1_u16], 2_u16, 1_u8)
    sender.join_group(SenderGC::JoinGroupRequest.new(group_id, [] of UInt16, 7_u16,
      key: Bytes.new(16, 0xAA_u8))).should eq(SenderStatus.success)
    keys.operational_group_table(1_u8).first.endpoints.should eq([1_u16])
    keys.operational_group_key_map(1_u8).first.group_key_set_id.should eq(2_u16)
    sender.leave_group(SenderGC::LeaveGroupRequest.new(group_id))
      .should eq(SenderGC::LeaveGroupResponse.new(group_id, [] of UInt16))
    keys.operational_group_table(1_u8).first.endpoints.should eq([1_u16])
  end

  it "lets one node send and listen when both features are advertised" do
    combined, keys, _acl = sender_cluster(SenderGC::Feature::Sender | SenderGC::Feature::Listener)
    combined.join_group(SenderGC::JoinGroupRequest.new(0x1234_u16, [1_u16], 7_u16,
      key: Bytes.new(16, 0xAA_u8))).should eq(SenderStatus.success)
    combined.membership(1_u8).first.endpoints.should eq([1_u16])
    combined.membership(1_u8).first.to_tlv(nil).as_structure.has_key?(1_u8).should be_true
    keys.operational_group_table(1_u8).first.endpoints.should eq([1_u16])
    combined.groupcast_testing(SenderGC::GroupcastTestingRequest.new(
      SenderGC::GroupcastTestingEnum::EnableSenderTesting, 10_u16)).should eq(SenderStatus.success)
  end

  it "emits only the selected direction's test events on an LN+SD node" do
    combined, _keys, _acl = sender_cluster(SenderGC::Feature::Sender | SenderGC::Feature::Listener)
    events = [] of Tuple(UInt32, UInt8?)
    combined.on_event_emitted = ->(_endpoint : UInt16, _cluster : UInt32, id : UInt32, _priority : Matter::InteractionModel::EventPriority, _payload : TLV::Any, fabric : UInt8?) do
      events << {id, fabric}
      nil
    end
    event = SenderGC::EVENT_GROUPCAST_TESTING
    result = SenderGC::GroupcastTestResultEnum::Success

    combined.groupcast_testing(SenderGC::GroupcastTestingRequest.new(
      SenderGC::GroupcastTestingEnum::EnableListenerTesting, 10_u16)).should eq(SenderStatus.success)
    combined.record_group_message(1_u8, 0x1234_u16, result, sender: true)
    events.should be_empty
    combined.record_group_message(1_u8, 0x1234_u16, result)
    events.should eq([{event, 1_u8}])

    combined.groupcast_testing(SenderGC::GroupcastTestingRequest.new(
      SenderGC::GroupcastTestingEnum::EnableSenderTesting, 10_u16)).should eq(SenderStatus.success)
    combined.record_group_message(1_u8, 0x1234_u16, result)
    events.should eq([{event, 1_u8}])
    combined.record_group_message(1_u8, 0x1234_u16, result, sender: true)
    events.should eq([{event, 1_u8}, {event, 1_u8}])
  end
end
