require "../spec_helper"

private class GroupCaptureTransport < Matter::Spec::CaptureTransport
  getter group_memberships : Array(Socket::IPAddress) = [] of Socket::IPAddress

  protected def initialize_for_spec : Nil
    super
    @group_memberships = [] of Socket::IPAddress
  end

  def group_memberships=(addresses : Array(Socket::IPAddress)) : Nil
    @group_memberships = addresses
  end
end

private def group_test_fabric(index : UInt8, fabric_id : UInt64) : Matter::Fabric
  root_key = Bytes.new(65, 1_u8)
  root_key[0] = 4_u8
  Matter::Fabric.new(fabric_id, index, 1_u64, root_key, Bytes.new(200, 1_u8),
    Matter::Crypto::Key.generate_key_pair, Bytes.new(16, 1_u8))
end

describe "group fabric removal" do
  it "reports authenticated, replayed, failed-auth and unavailable-key group packets during listener testing" do
    fabric_table = Matter::FabricTable.new(Matter::Storage::Memory.new)
    fabric = group_test_fabric(1_u8, 0x100_u64)
    fabric_table.add_fabric(fabric).should be_true
    transport = GroupCaptureTransport.new_for_spec
    handler = Matter::Protocol::MessageHandler.new(transport, 20202021_u32, 3840_u16, fabric_table)
    root = handler.node.endpoint!(0_u16)
    endpoint_id = Matter::DataType::EndpointNumber.new(0_u16)
    gkm = Matter::Cluster::GroupKeyManagement.new(endpoint_id,
      feature_map: Matter::Cluster::GroupKeyManagement::Feature::Groupcast,
      max_groups_per_fabric: 0_u16)
    acl = Matter::Cluster::AccessControl.new(endpoint_id,
      feature_map: Matter::Cluster::AccessControl::Feature::Auxiliary)
    listener = Matter::Cluster::Groupcast.new(endpoint_id, gkm, acl)
    root.add_cluster(gkm)
    root.add_cluster(acl)
    root.add_cluster(listener)
    handler.node.add_endpoint(root)
    handler.setup_cluster_notifications
    results = [] of Matter::Cluster::Groupcast::GroupcastTestResultEnum
    listener.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, _event : UInt32, _priority : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) do
      result_value = data.value.as(TLV::Structure)[7_u8].value.as(UInt8)
      results << Matter::Cluster::Groupcast::GroupcastTestResultEnum.from_value(result_value)
      nil
    end

    epoch_key = Bytes.new(16, 0x55_u8)
    key_set = Matter::Cluster::GroupKeyManagement::GroupKeySetStruct.new(5_u16,
      epoch_key0: epoch_key, epoch_start_time0: 1_u64)
    gkm.handle_key_set_write(Matter::Cluster::GroupKeyManagement::KeySetWriteRequest.new(key_set), 1_u8)
    listener.with_request_context do
      listener.request_fabric_index = 1_u8
      listener.request_is_case_session = true
      listener.join_group(Matter::Cluster::Groupcast::JoinGroupRequest.new(
        1_u16, [1_u16], 5_u16)).success?.should be_true
      listener.groupcast_testing(Matter::Cluster::Groupcast::GroupcastTestingRequest.new(
        Matter::Cluster::Groupcast::GroupcastTestingEnum::EnableListenerTesting, 10_u16)).success?.should be_true
    end
    operational = Matter::Session::GroupSecurePacket.derive_operational_key(
      epoch_key, fabric.compressed_fabric_id)
    key = Matter::Session::GroupSecurePacket::Key.new(1_u8, 1_u16, operational)
    sender = Matter::Session::GroupSecurePacket.new([key])
    header = Matter::Codec::MessageCodec::PayloadHeader.new(9_u16, 1_u16,
      Matter::Protocol::IMHandler::MSG_INVOKE_REQUEST, true, false)
    wire = sender.encode(key, 0x1111_u64, 100_u32, header, Bytes.empty)
    peer = Socket::IPAddress.new("::1", 5540)
    handler.handle_group_packet(wire, peer)
    handler.handle_group_packet(wire, peer)
    tampered = sender.encode(key, 0x1111_u64, 101_u32, header, Bytes.empty)
    tampered[tampered.size - 1] ^= 1_u8
    handler.handle_group_packet(tampered, peer)
    missing_key = Matter::Session::GroupSecurePacket::Key.new(1_u8, 1_u16,
      Bytes.new(16, 0x77_u8))
    missing_wire = Matter::Session::GroupSecurePacket.new([missing_key]).encode(
      missing_key, 0x1111_u64, 102_u32, header, Bytes.empty)
    handler.handle_group_packet(missing_wire, peer)
    results.should eq([
      Matter::Cluster::Groupcast::GroupcastTestResultEnum::Success,
      Matter::Cluster::Groupcast::GroupcastTestResultEnum::MessageReplay,
      Matter::Cluster::Groupcast::GroupcastTestResultEnum::FailedAuth,
      Matter::Cluster::Groupcast::GroupcastTestResultEnum::NoAvailableKey,
    ])
  end

  it "keeps legacy multicast joins beside an opted-in IANA Groupcast Listener" do
    fabric_table = Matter::FabricTable.new(Matter::Storage::Memory.new)
    fabric_id = 0x100_u64
    fabric_table.add_fabric(group_test_fabric(1_u8, fabric_id)).should be_true
    transport = GroupCaptureTransport.new_for_spec
    handler = Matter::Protocol::MessageHandler.new(transport, 20202021_u32, 3840_u16, fabric_table)
    root = handler.node.endpoint!(0_u16)
    endpoint_id = Matter::DataType::EndpointNumber.new(0_u16)
    gkm = Matter::Cluster::GroupKeyManagement.new(endpoint_id,
      feature_map: Matter::Cluster::GroupKeyManagement::Feature::Groupcast,
      max_groups_per_fabric: 0_u16)
    acl = Matter::Cluster::AccessControl.new(endpoint_id,
      feature_map: Matter::Cluster::AccessControl::Feature::Auxiliary)
    listener = Matter::Cluster::Groupcast.new(endpoint_id, gkm, acl)
    root.add_cluster(gkm)
    root.add_cluster(acl)
    root.add_cluster(listener)
    handler.node.add_endpoint(root)
    handler.setup_cluster_notifications

    key_set = Matter::Cluster::GroupKeyManagement::GroupKeySetStruct.new(5_u16,
      epoch_key0: Bytes.new(16, 0x55_u8), epoch_start_time0: 1_u64)
    gkm.handle_key_set_write(Matter::Cluster::GroupKeyManagement::KeySetWriteRequest.new(key_set), 1_u8)
    gkm.replace_groupcast_membership(2_u16, [1_u16], 5_u16, 1_u8)
    listener.with_request_context do
      listener.request_fabric_index = 1_u8
      listener.request_is_case_session = true
      listener.join_group(Matter::Cluster::Groupcast::JoinGroupRequest.new(
        1_u16, [1_u16], 5_u16)).success?.should be_true
    end
    handler.refresh_group_memberships
    transport.group_memberships.should contain(Matter::Transport::GroupMulticast.iana_address(transport.port))
    transport.group_memberships.should contain(Matter::Transport::GroupMulticast.address(fabric_id, 2_u16, transport.port))
    transport.group_memberships.should_not contain(Matter::Transport::GroupMulticast.address(fabric_id, 1_u16, transport.port))
  end

  it "purges old credentials, names, and multicast joins before index reuse" do
    fabric_table = Matter::FabricTable.new(Matter::Storage::Memory.new)
    fabric_table.add_fabric(group_test_fabric(1_u8, 0x100_u64)).should be_true
    fabric_table.add_fabric(group_test_fabric(2_u8, 0x200_u64)).should be_true
    transport = GroupCaptureTransport.new_for_spec
    handler = Matter::Protocol::MessageHandler.new(transport, 20202021_u32, 3840_u16, fabric_table)
    root = handler.node.endpoint!(0_u16)
    gkm = Matter::Cluster::GroupKeyManagement.new(Matter::DataType::EndpointNumber.new(0_u16))
    root.add_cluster(gkm)
    handler.node.add_endpoint(root)
    endpoint = Matter::Endpoint.new(Matter::DataType::EndpointNumber.new(1_u16))
    groups = Matter::Cluster::Groups.new(Matter::DataType::EndpointNumber.new(1_u16))
    endpoint.add_cluster(groups)
    scenes = Matter::Cluster::ScenesManagement.new(Matter::DataType::EndpointNumber.new(1_u16))
    endpoint.add_cluster(scenes)
    handler.node.add_endpoint(endpoint)
    handler.setup_cluster_notifications

    {1_u8, 2_u8}.each do |index|
      key_set = Matter::Cluster::GroupKeyManagement::GroupKeySetStruct.new(5_u16,
        epoch_key0: Bytes.new(16, index), epoch_start_time0: 1_u64)
      gkm.handle_key_set_write(Matter::Cluster::GroupKeyManagement::KeySetWriteRequest.new(key_set), index)
      groups.with_request_context do
        groups.request_fabric_index = index
        groups.add_group(Matter::Cluster::Groups::AddGroupRequest.new(
          Matter::DataType::GroupId.new(index.to_u16), "Fabric #{index}"))
      end
      scenes.invoke_command(Matter::Cluster::ScenesManagement::CMD_ADD_SCENE,
        Matter::Cluster::AddSceneRequest.new(1_u16, index, 0_u32, "Fabric #{index}", [] of TLV::Any).to_tlv(nil),
        is_case_session: true, fabric_index: index)
      gkm.group_table(index).size.should eq(1)
      transport.group_memberships.size.should eq(index.to_i - 1)
      gkm.add_group_key_map(index.to_u16, 5_u16, index)
      handler.refresh_group_memberships
    end
    transport.group_memberships.size.should eq(2)

    fabric_table.remove_fabric(1_u8).should be_true
    handler.forget_group_fabric(1_u8)
    gkm.get_key_set(5_u16, 1_u8).should be_nil
    gkm.group_key_map(1_u8).should be_empty
    gkm.group_table(1_u8).should be_empty
    gkm.get_key_set(5_u16, 2_u8).should_not be_nil
    gkm.group_key_map(2_u8).size.should eq(1)
    gkm.group_table(2_u8).size.should eq(1)
    transport.group_memberships.map(&.address).should eq([
      Matter::Transport::GroupMulticast.address(0x200_u64, 2_u16, transport.port).address,
    ])
    groups.with_request_context do
      groups.request_fabric_index = 1_u8
      groups.member_of?(1_u16).should be_false
      groups.request_fabric_index = 2_u8
      groups.member_of?(2_u16).should be_true
    end
    scenes.has_scene?(1_u16, 1_u8, 1_u8).should be_false
    scenes.has_scene?(1_u16, 2_u8, 2_u8).should be_true

    fabric_table.add_fabric(group_test_fabric(1_u8, 0x300_u64)).should be_true
    handler.refresh_group_memberships
    transport.group_memberships.size.should eq(1)
    groups.with_request_context do
      groups.request_fabric_index = 1_u8
      groups.group_count.should eq(0)
    end
    scenes.scene_count(1_u8).should eq(0)
  end
end
