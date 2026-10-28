require "../spec_helper"

private alias DeviceTypeAcl = Matter::Cluster::AccessControl
private alias DeviceTypeDescriptor = Matter::Cluster::Descriptor
private alias DeviceTypeIm = Matter::Protocol::IMHandler

private def device_type_target_acl(auth_mode : DeviceTypeAcl::AccessControlEntryAuthMode,
                                   subject : UInt64, device_type : UInt32) : DeviceTypeAcl::AccessControlEntry
  DeviceTypeAcl::AccessControlEntry.new(
    privilege: DeviceTypeAcl::AccessControlEntryPrivilege::Operate,
    auth_mode: auth_mode,
    subjects: [subject],
    targets: [DeviceTypeAcl::Target.new(device_type: device_type)],
    fabric_index: 1_u8
  )
end

describe "ACL DeviceType targets" do
  it "authorizes CASE reads and commands for every current Descriptor device type" do
    acl = DeviceTypeAcl.new(endpoint(0))
    descriptor = DeviceTypeDescriptor.new(endpoint(1))
    descriptor.device_type_list << DeviceTypeDescriptor::DeviceTypeStruct.new(Matter::DeviceType::ON_OFF_LIGHT, 1_u16)
    descriptor.device_type_list << DeviceTypeDescriptor::DeviceTypeStruct.new(Matter::DeviceType::BRIDGED_NODE, 1_u16)
    on_off = Matter::Cluster::OnOff.new(endpoint(1))
    clusters = {} of Tuple(UInt16, UInt32) => Matter::Cluster::Base
    clusters[{0_u16, DeviceTypeAcl::CLUSTER_ID}] = acl
    clusters[{1_u16, DeviceTypeDescriptor::CLUSTER_ID}] = descriptor
    clusters[{1_u16, Matter::Cluster::OnOff::CLUSTER_ID}] = on_off
    subject = 0x1234_u64
    acl.acl << device_type_target_acl(DeviceTypeAcl::AccessControlEntryAuthMode::CASE,
      subject, Matter::DeviceType::BRIDGED_NODE)
    path = Matter::InteractionModel::AttributePath.new(1_u16,
      Matter::Cluster::OnOff::CLUSTER_ID, Matter::Cluster::OnOff::ATTR_ON_OFF)
    command = Matter::InteractionModel::CommandDataIBTlv.new(
      Matter::InteractionModel::CommandPath.new(1_u16,
        Matter::Cluster::OnOff::CLUSTER_ID, Matter::Cluster::OnOff::CMD_ON), nil)

    DeviceTypeIm.attribute_read_status(1_u16, Matter::Cluster::OnOff::CLUSTER_ID,
      Matter::Cluster::OnOff::ATTR_ON_OFF, clusters, true, 1_u8, [subject]).should be_nil
    DeviceTypeIm.invoke_commands([command], clusters, fabric_index: 1_u8,
      is_case_session: true, peer_subject_ids: [subject])
      .first.command_status.as(Matter::InteractionModel::CommandStatusIB).status.status
      .should eq(Matter::InteractionModel::StatusCode::Success.value)
    on_off.on?.should be_true

    # A changed composition must affect the next authorization decision.
    descriptor.device_type_list.pop
    DeviceTypeIm.attribute_read_status(1_u16, Matter::Cluster::OnOff::CLUSTER_ID,
      Matter::Cluster::OnOff::ATTR_ON_OFF, clusters, true, 1_u8, [subject])
      .should eq(Matter::InteractionModel::StatusCode::UnsupportedAccess)
    DeviceTypeIm.read_attributes([path], clusters, fabric_index: 1_u8,
      is_case_session: true, peer_subject_ids: [subject]).first.attribute_data.should be_nil
  end
end

describe "Group ACL DeviceType targets" do
  it "fans out writes and invokes only to matching member endpoint types" do
    group_id = 0x1234_u16
    fabric = 1_u8
    root = endpoint(0)
    acl = DeviceTypeAcl.new(root)
    gkm = Matter::Cluster::GroupKeyManagement.new(root)
    clusters = {} of Tuple(UInt16, UInt32) => Matter::Cluster::Base
    clusters[{0_u16, DeviceTypeAcl::CLUSTER_ID}] = acl
    levels = {} of UInt16 => Matter::Cluster::LevelControl
    on_offs = {} of UInt16 => Matter::Cluster::OnOff
    {1_u16 => Matter::DeviceType::ON_OFF_LIGHT,
     2_u16 => Matter::DeviceType::BRIDGED_NODE}.each do |number, type|
      endpoint_id = endpoint(number)
      descriptor = DeviceTypeDescriptor.new(endpoint_id)
      descriptor.device_type_list << DeviceTypeDescriptor::DeviceTypeStruct.new(type, 1_u16)
      levels[number] = Matter::Cluster::LevelControl.new(endpoint_id)
      on_offs[number] = Matter::Cluster::OnOff.new(endpoint_id)
      clusters[{number, DeviceTypeDescriptor::CLUSTER_ID}] = descriptor
      clusters[{number, Matter::Cluster::LevelControl::CLUSTER_ID}] = levels[number]
      clusters[{number, Matter::Cluster::OnOff::CLUSTER_ID}] = on_offs[number]
    end
    acl.acl << device_type_target_acl(DeviceTypeAcl::AccessControlEntryAuthMode::Group,
      group_id.to_u64, Matter::DeviceType::BRIDGED_NODE)
    epoch = Bytes.new(16, 0x11_u8)
    gkm.handle_key_set_write(Matter::Cluster::GroupKeyManagement::KeySetWriteRequest.new(
      Matter::Cluster::GroupKeyManagement::GroupKeySetStruct.new(1_u16,
        epoch_key0: epoch, epoch_start_time0: 1_u64)), fabric)
    gkm.add_group_key_map(group_id, 1_u16, fabric)
    gkm.add_group(group_id, 1_u16, nil, fabric)
    gkm.add_group(group_id, 2_u16, nil, fabric)
    key = Matter::Session::GroupSecurePacket::Key.new(fabric, group_id, epoch)
    codec = Matter::Session::GroupSecurePacket.new([key])
    router = Matter::Protocol::GroupInteractionRouter.new(clusters, gkm)

    write_path = Matter::InteractionModel::AttributePath.new(nil,
      Matter::Cluster::LevelControl::CLUSTER_ID, Matter::Cluster::LevelControl::ATTR_OPTIONS)
    write = Matter::InteractionModel::WriteRequestMessage.new(true, false, [
      Matter::InteractionModel::AttributeDataIB.new(write_path, TLV::Any.new(1_u8, nil)),
    ])
    write_header = Matter::Codec::MessageCodec::PayloadHeader.new(9_u16, 1_u16,
      DeviceTypeIm::MSG_WRITE_REQUEST, true, false)
    write_wire = codec.encode(key, 0x1111_u64, 100_u32, write_header, write.to_slice)
    router.handle(Matter::Session::GroupSecurePacket.new([key]).decode(write_wire))
    levels[1_u16].options.should eq(0_u8)
    levels[2_u16].options.should eq(1_u8)

    invoke = Matter::InteractionModel::InvokeRequestMessage.new([
      Matter::InteractionModel::CommandDataIBTlv.new(
        Matter::InteractionModel::CommandPath.new(nil,
          Matter::Cluster::OnOff::CLUSTER_ID, Matter::Cluster::OnOff::CMD_ON)),
    ])
    invoke_header = Matter::Codec::MessageCodec::PayloadHeader.new(9_u16, 1_u16,
      DeviceTypeIm::MSG_INVOKE_REQUEST, true, false)
    invoke_wire = codec.encode(key, 0x1111_u64, 101_u32, invoke_header, invoke.to_slice)
    router.handle(Matter::Session::GroupSecurePacket.new([key]).decode(invoke_wire))
    on_offs[1_u16].on?.should be_false
    on_offs[2_u16].on?.should be_true
  end
end
