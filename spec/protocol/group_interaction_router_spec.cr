require "../spec_helper"

describe Matter::Protocol::GroupInteractionRouter do
  it "stores a fabric-scoped scene from an authenticated group invoke" do
    group_id = 0x1234_u16
    fabric = Matter::Fabric::MIN_FABRIC_INDEX
    root = Matter::DataType::EndpointNumber::ROOT
    endpoint_id = 1_u16
    acl = Matter::Cluster::AccessControl.new(root)
    gkm = Matter::Cluster::GroupKeyManagement.new(root)
    scenes = Matter::Cluster::ScenesManagement.new(Matter::DataType::EndpointNumber.new(endpoint_id))
    clusters = {
      {root.number, Matter::Cluster::AccessControl::CLUSTER_ID}    => acl.as(Matter::Cluster::Base),
      {endpoint_id, Matter::Cluster::ScenesManagement::CLUSTER_ID} => scenes.as(Matter::Cluster::Base),
    }

    epoch = Bytes.new(16, 0x11_u8)
    gkm.handle_key_set_write(Matter::Cluster::GroupKeyManagement::KeySetWriteRequest.new(
      Matter::Cluster::GroupKeyManagement::GroupKeySetStruct.new(1_u16,
        epoch_key0: epoch, epoch_start_time0: 1_u64)), fabric)
    gkm.add_group_key_map(group_id, 1_u16, fabric)
    gkm.add_group(group_id, endpoint_id, nil, fabric)
    acl.acl << Matter::Cluster::AccessControl::AccessControlEntry.new(
      Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Manage,
      Matter::Cluster::AccessControl::AccessControlEntryAuthMode::Group,
      [group_id.to_u64], nil, fabric)

    key = Matter::Session::GroupSecurePacket::Key.new(fabric, group_id, epoch)
    payload = Matter::Cluster::AddSceneRequest.new(group_id, 1_u8, 0_u32, "Group scene").to_tlv(nil)
    request = Matter::InteractionModel::InvokeRequestMessage.new([
      Matter::InteractionModel::CommandDataIBTlv.new(
        Matter::InteractionModel::CommandPath.new(nil,
          Matter::Cluster::ScenesManagement::CLUSTER_ID, Matter::Cluster::ScenesManagement::CMD_ADD_SCENE), payload),
    ])
    header = Matter::Codec::MessageCodec::PayloadHeader.new(9_u16, 1_u16,
      Matter::Protocol::IMHandler::MSG_INVOKE_REQUEST, true, false)
    wire = Matter::Session::GroupSecurePacket.new([key]).encode(key, 0x1111_u64, 100_u32, header, request.to_slice)
    Matter::Protocol::GroupInteractionRouter.new(clusters, gkm)
      .handle(Matter::Session::GroupSecurePacket.new([key]).decode(wire))

    scenes.has_scene?(group_id, 1_u8, fabric).should be_true
    scenes.has_scene?(group_id, 1_u8, fabric + 1_u8).should be_false
  end

  it "applies a group WriteRequest only to member endpoints with Group write ACL" do
    group_id = 0x1234_u16
    fabric = 1_u8
    root = Matter::DataType::EndpointNumber.new(0_u16)
    acl = Matter::Cluster::AccessControl.new(root)
    gkm = Matter::Cluster::GroupKeyManagement.new(root)
    first = Matter::Cluster::LevelControl.new(Matter::DataType::EndpointNumber.new(1_u16))
    second = Matter::Cluster::LevelControl.new(Matter::DataType::EndpointNumber.new(2_u16))
    clusters = {} of Tuple(UInt16, UInt32) => Matter::Cluster::Base
    clusters[{0_u16, Matter::Cluster::AccessControl::CLUSTER_ID}] = acl
    clusters[{1_u16, Matter::Cluster::LevelControl::CLUSTER_ID}] = first
    clusters[{2_u16, Matter::Cluster::LevelControl::CLUSTER_ID}] = second
    epoch = Bytes.new(16, 0x11_u8)
    gkm.handle_key_set_write(Matter::Cluster::GroupKeyManagement::KeySetWriteRequest.new(
      Matter::Cluster::GroupKeyManagement::GroupKeySetStruct.new(1_u16,
        epoch_key0: epoch, epoch_start_time0: 1_u64)), fabric)
    gkm.add_group_key_map(group_id, 1_u16, fabric)
    gkm.add_group(group_id, 1_u16, nil, fabric)
    acl.acl << Matter::Cluster::AccessControl::AccessControlEntry.new(
      Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Operate,
      Matter::Cluster::AccessControl::AccessControlEntryAuthMode::Group,
      [group_id.to_u64], nil, fabric)
    key = Matter::Session::GroupSecurePacket::Key.new(fabric, group_id, epoch)
    codec = Matter::Session::GroupSecurePacket.new([key])
    path = Matter::InteractionModel::AttributePath.new(nil,
      Matter::Cluster::LevelControl::CLUSTER_ID, Matter::Cluster::LevelControl::ATTR_OPTIONS)
    data = Matter::InteractionModel::AttributeDataIB.new(path, TLV::Any.new(1_u8, nil))
    request = Matter::InteractionModel::WriteRequestMessage.new(true, false, [data])
    header = Matter::Codec::MessageCodec::PayloadHeader.new(9_u16, 1_u16,
      Matter::Protocol::IMHandler::MSG_WRITE_REQUEST, true, false)
    wire = codec.encode(key, 0x1111_u64, 100_u32, header, request.to_slice)
    router = Matter::Protocol::GroupInteractionRouter.new(clusters, gkm)

    router.handle(Matter::Session::GroupSecurePacket.new([key]).decode(wire))
    first.options.should eq(1_u8)
    second.options.should eq(0_u8)

    first.options = 0_u8
    acl.acl.clear
    router.handle(Matter::Session::GroupSecurePacket.new([key]).decode(wire))
    first.options.should eq(0_u8)

    acl.acl << Matter::Cluster::AccessControl::AccessControlEntry.new(
      Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Operate,
      Matter::Cluster::AccessControl::AccessControlEntryAuthMode::Group,
      [group_id.to_u64], nil, fabric)
    # Official SDK v1.6 chip-tool sends false here despite Core §8.7.2.2.
    sdk_write = Matter::InteractionModel::WriteRequestMessage.new(false, false, [data])
    sdk_wire = codec.encode(key, 0x1111_u64, 101_u32, header, sdk_write.to_slice)
    router.handle(Matter::Session::GroupSecurePacket.new([key]).decode(sdk_wire))
    first.options.should eq(1_u8)
    first.options = 0_u8
    [
      Matter::InteractionModel::WriteRequestMessage.new(true, true, [data]),
      Matter::InteractionModel::WriteRequestMessage.new(true, false, [
        Matter::InteractionModel::AttributeDataIB.new(
          Matter::InteractionModel::AttributePath.new(1_u16,
            Matter::Cluster::LevelControl::CLUSTER_ID, Matter::Cluster::LevelControl::ATTR_OPTIONS),
          TLV::Any.new(1_u8, nil)),
      ]),
    ].each_with_index do |invalid, index|
      bad_wire = codec.encode(key, 0x1111_u64, (102 + index).to_u32, header, invalid.to_slice)
      router.handle(Matter::Session::GroupSecurePacket.new([key]).decode(bad_wire))
      first.options.should eq(0_u8)
    end
  end

  it "keeps wildcard command paths out of unicast Invoke processing" do
    request = Matter::InteractionModel::InvokeRequestMessage.new([
      Matter::InteractionModel::CommandDataIBTlv.new(
        Matter::InteractionModel::CommandPath.new(nil, Matter::Cluster::OnOff::CLUSTER_ID, Matter::Cluster::OnOff::CMD_ON)),
    ])
    Matter::Protocol::IMHandler.parse_invoke_request(request.to_slice).should be_nil
    Matter::Protocol::IMHandler.parse_invoke_request(request.to_slice, allow_group_path: true).should_not be_nil
  end

  it "invokes only for an authenticated member endpoint with a Group ACL and never returns a response" do
    group_id = 0x1234_u16
    fabric = 1_u8
    root = Matter::DataType::EndpointNumber.new(0_u16)
    endpoint_1 = Matter::DataType::EndpointNumber.new(1_u16)
    endpoint_2 = Matter::DataType::EndpointNumber.new(2_u16)
    acl = Matter::Cluster::AccessControl.new(root)
    gkm = Matter::Cluster::GroupKeyManagement.new(root)
    on_1 = Matter::Cluster::OnOff.new(endpoint_1)
    on_2 = Matter::Cluster::OnOff.new(endpoint_2)
    clusters = {} of Tuple(UInt16, UInt32) => Matter::Cluster::Base
    clusters[{0_u16, Matter::Cluster::AccessControl::CLUSTER_ID}] = acl
    clusters[{1_u16, Matter::Cluster::OnOff::CLUSTER_ID}] = on_1
    clusters[{2_u16, Matter::Cluster::OnOff::CLUSTER_ID}] = on_2

    epoch = Bytes.new(16, 0x11_u8)
    gkm.handle_key_set_write(Matter::Cluster::GroupKeyManagement::KeySetWriteRequest.new(
      Matter::Cluster::GroupKeyManagement::GroupKeySetStruct.new(1_u16,
        epoch_key0: epoch, epoch_start_time0: 1_u64)), fabric)
    gkm.add_group_key_map(group_id, 1_u16, fabric)
    gkm.add_group(group_id, 1_u16, nil, fabric)
    acl.acl << Matter::Cluster::AccessControl::AccessControlEntry.new(
      Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Operate,
      Matter::Cluster::AccessControl::AccessControlEntryAuthMode::Group,
      [group_id.to_u64], nil, fabric)

    key = Matter::Session::GroupSecurePacket::Key.new(fabric, group_id, epoch)
    codec = Matter::Session::GroupSecurePacket.new([key])
    request = Matter::InteractionModel::InvokeRequestMessage.new([
      Matter::InteractionModel::CommandDataIBTlv.new(
        Matter::InteractionModel::CommandPath.new(1_u16, Matter::Cluster::OnOff::CLUSTER_ID, Matter::Cluster::OnOff::CMD_ON)),
      Matter::InteractionModel::CommandDataIBTlv.new(
        Matter::InteractionModel::CommandPath.new(2_u16, Matter::Cluster::OnOff::CLUSTER_ID, Matter::Cluster::OnOff::CMD_ON)),
    ])
    payload_header = Matter::Codec::MessageCodec::PayloadHeader.new(
      9_u16, 1_u16, 0x08_u8, true, false)
    wire = codec.encode(key, 0x1111_u64, 100_u32, payload_header, request.to_slice)
    decoded = Matter::Session::GroupSecurePacket.new([key]).decode(wire)
    router = Matter::Protocol::GroupInteractionRouter.new(clusters, gkm)
    router.handle(decoded).should be_nil
    on_1.on?.should be_false
    on_2.on?.should be_false

    on_1.off
    wildcard = Matter::InteractionModel::InvokeRequestMessage.new([
      Matter::InteractionModel::CommandDataIBTlv.new(
        Matter::InteractionModel::CommandPath.new(nil, Matter::Cluster::OnOff::CLUSTER_ID, Matter::Cluster::OnOff::CMD_ON)),
    ])
    wildcard_wire = codec.encode(key, 0x1111_u64, 101_u32, payload_header, wildcard.to_slice)
    router.handle(Matter::Session::GroupSecurePacket.new([key]).decode(wildcard_wire))
    on_1.on?.should be_true
    on_2.on?.should be_false

    on_1.off
    acl.acl.clear
    router.handle(Matter::Session::GroupSecurePacket.new([key]).decode(wire)).should be_nil
    on_1.on?.should be_false
  end
end
