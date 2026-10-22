require "../spec_helper"

describe "adopted Groupcast packet routing" do
  it "uses hidden operational mappings and only auxiliary group ACL endpoints" do
    root = Matter::DataType::EndpointNumber.new(0_u16)
    first_ep = Matter::DataType::EndpointNumber.new(1_u16)
    second_ep = Matter::DataType::EndpointNumber.new(2_u16)
    acl = Matter::Cluster::AccessControl.new(root,
      feature_map: Matter::Cluster::AccessControl::Feature::Auxiliary)
    keys = Matter::Cluster::GroupKeyManagement.new(root,
      feature_map: Matter::Cluster::GroupKeyManagement::Feature::Groupcast,
      max_groups_per_fabric: 0_u16)
    listener = Matter::Cluster::Groupcast.new(root, keys, acl)
    acl.acl = [Matter::Cluster::AccessControl::AccessControlEntry.new(
      Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer,
      Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
      [10_u64], nil, 1_u8)]
    keys.handle_key_set_write(Matter::Cluster::GroupKeyManagement::KeySetWriteRequest.new(
      Matter::Cluster::GroupKeyManagement::GroupKeySetStruct.new(7_u16,
        epoch_key0: Bytes.new(16, 0x66_u8), epoch_start_time0: 1_u64)), 1_u8)
    listener.request_is_case_session = true
    listener.request_fabric_index = 1_u8
    listener.request_peer_subject_ids = [10_u64]
    listener.join_group(Matter::Cluster::Groupcast::JoinGroupRequest.new(0x1234_u16,
      [1_u16], 7_u16, use_auxiliary_acl: true)).status.should eq(Matter::InteractionModel::StatusCode::Success)
    keys.request_fabric_index = 1_u8
    keys.groupcast_adoption = [Matter::Cluster::GroupKeyManagement::GroupcastAdoptionStruct.new(true)]

    first = Matter::Cluster::OnOff.new(first_ep)
    second = Matter::Cluster::OnOff.new(second_ep)
    clusters = {} of Tuple(UInt16, UInt32) => Matter::Cluster::Base
    clusters[{0_u16, Matter::Cluster::AccessControl::CLUSTER_ID}] = acl
    clusters[{1_u16, Matter::Cluster::OnOff::CLUSTER_ID}] = first
    clusters[{2_u16, Matter::Cluster::OnOff::CLUSTER_ID}] = second
    epoch = Bytes.new(16, 0x66_u8)
    key = Matter::Session::GroupSecurePacket::Key.new(1_u8, 0x1234_u16, epoch)
    codec = Matter::Session::GroupSecurePacket.new([key])
    request = Matter::InteractionModel::InvokeRequestMessage.new([
      Matter::InteractionModel::CommandDataIBTlv.new(
        Matter::InteractionModel::CommandPath.new(nil,
          Matter::Cluster::OnOff::CLUSTER_ID, Matter::Cluster::OnOff::CMD_ON)),
    ])
    header = Matter::Codec::MessageCodec::PayloadHeader.new(9_u16, 1_u16,
      Matter::Protocol::IMHandler::MSG_INVOKE_REQUEST, true, false)
    wire = codec.encode(key, 0x1111_u64, 100_u32, header, request.to_slice)
    Matter::Protocol::GroupInteractionRouter.new(clusters, keys).handle(codec.decode(wire))
    first.on?.should be_true
    second.on?.should be_false

    first.off
    first.on?.should be_false
    listener.configure_auxiliary_acl(Matter::Cluster::Groupcast::ConfigureAuxiliaryAclRequest.new(
      0x1234_u16, false)).status.should eq(Matter::InteractionModel::StatusCode::Success)
    acl.auxiliary_acl(1_u8).should be_empty
    second_wire = codec.encode(key, 0x1111_u64, 101_u32, header, request.to_slice)
    Matter::Protocol::GroupInteractionRouter.new(clusters, keys).handle(codec.decode(second_wire))
    first.on?.should be_false
  end
end
