require "../spec_helper"
require "../../src/matter/cluster/thread_network_directory"
require "../../src/matter/cluster/wi_fi_network_management"

private alias GroupArlAcl = Matter::Cluster::AccessControl
private alias GroupArlDirectory = Matter::Cluster::ThreadNetworkDirectory
private GROUP_ARL_XPAN = Bytes[1, 2, 3, 4, 5, 6, 7, 8]

private def group_arl_thread_tlv(type : UInt8, bytes : Bytes) : Bytes
  Bytes[type, bytes.size.to_u8] + bytes
end

private def group_arl_thread_dataset : Bytes
  group_arl_thread_tlv(14_u8, Bytes[0, 0, 0, 0, 0, 0, 0, 1]) +
    group_arl_thread_tlv(0_u8, Bytes[0, 0, 15]) +
    group_arl_thread_tlv(53_u8, Bytes[0, 4, 0, 0, 0, 1]) +
    group_arl_thread_tlv(2_u8, GROUP_ARL_XPAN) +
    group_arl_thread_tlv(5_u8, Bytes.new(16, 0xaa_u8)) +
    group_arl_thread_tlv(7_u8, Bytes.new(8, 0xfd_u8)) +
    group_arl_thread_tlv(3_u8, "Home".to_slice) +
    group_arl_thread_tlv(1_u8, Bytes[0x12, 0x34]) +
    group_arl_thread_tlv(4_u8, Bytes.new(16, 0xbb_u8)) +
    group_arl_thread_tlv(12_u8, Bytes[0, 1, 0, 0])
end

private class GroupArlWiFi < Matter::Cluster::WiFiNetworkManagement
  getter request_count = 0

  def network_passphrase_request : Matter::InteractionModel::Status | NetworkPassphraseResponse
    @request_count += 1
    super
  end
end

private def group_arl_fixture
  group_id = 0x1234_u16
  acl = GroupArlAcl.new(Matter::DataType::EndpointNumber.new(0_u16))
  gkm = Matter::Cluster::GroupKeyManagement.new(Matter::DataType::EndpointNumber.new(0_u16))
  directory = GroupArlDirectory.new(Matter::DataType::EndpointNumber.new(1_u16))
  directory.add_network(GroupArlDirectory::AddNetworkRequest.new(group_arl_thread_dataset))
    .status.should eq(Matter::InteractionModel::StatusCode::Success)
  wifi = GroupArlWiFi.new(Matter::DataType::EndpointNumber.new(1_u16))
  clusters = {
    {0_u16, GroupArlAcl::CLUSTER_ID}       => acl.as(Matter::Cluster::Base),
    {1_u16, GroupArlDirectory::CLUSTER_ID} => directory.as(Matter::Cluster::Base),
    {1_u16, GroupArlWiFi::CLUSTER_ID}      => wifi.as(Matter::Cluster::Base),
  }
  keys = [1_u8, 2_u8].map do |fabric|
    epoch = Bytes.new(16, fabric)
    gkm.handle_key_set_write(Matter::Cluster::GroupKeyManagement::KeySetWriteRequest.new(
      Matter::Cluster::GroupKeyManagement::GroupKeySetStruct.new(fabric.to_u16,
        epoch_key0: epoch, epoch_start_time0: 1_u64)), fabric)
    gkm.add_group_key_map(group_id, fabric.to_u16, fabric)
    gkm.add_group(group_id, 1_u16, nil, fabric)
    acl.acl << GroupArlAcl::AccessControlEntry.new(
      GroupArlAcl::AccessControlEntryPrivilege::Manage,
      GroupArlAcl::AccessControlEntryAuthMode::Group,
      [group_id.to_u64], nil, fabric)
    Matter::Session::GroupSecurePacket::Key.new(fabric, group_id, epoch)
  end
  {acl, directory, wifi, Matter::Protocol::GroupInteractionRouter.new(clusters, gkm), keys}
end

private def deliver_group_arl(router : Matter::Protocol::GroupInteractionRouter,
                              key : Matter::Session::GroupSecurePacket::Key,
                              message_type : UInt8, payload : Bytes, counter : UInt32) : Nil
  codec = Matter::Session::GroupSecurePacket.new([key])
  header = Matter::Codec::MessageCodec::PayloadHeader.new(9_u16, 1_u16,
    message_type, true, false)
  wire = codec.encode(key, 0x1111_u64, counter, header, payload)
  router.handle(Matter::Session::GroupSecurePacket.new([key]).decode(wire))
end

describe Matter::Protocol::GroupInteractionRouter do
  it "applies the fabric ARL after Group ACL for a non-root Thread directory write" do
    acl, directory, _, router, keys = group_arl_fixture
    acl.configure_access_restrictions(1_u8, [
      GroupArlAcl::AccessRestrictionEntry.new(1_u16, GroupArlDirectory::CLUSTER_ID, [
        GroupArlAcl::AccessRestriction.new(
          GroupArlAcl::AccessRestrictionType::AttributeWriteForbidden,
          GroupArlDirectory::ATTR_PREFERRED_EXTENDED_PAN_ID),
      ]),
    ])
    data = Matter::InteractionModel::AttributeDataIB.new(
      Matter::InteractionModel::AttributePath.new(nil, GroupArlDirectory::CLUSTER_ID,
        GroupArlDirectory::ATTR_PREFERRED_EXTENDED_PAN_ID), TLV::Any.new(GROUP_ARL_XPAN, nil))
    request = Matter::InteractionModel::WriteRequestMessage.new(true, false, [data])

    deliver_group_arl(router, keys[0], Matter::Protocol::IMHandler::MSG_WRITE_REQUEST,
      request.to_slice, 100_u32)
    directory.preferred_extended_pan_id.should be_nil

    deliver_group_arl(router, keys[1], Matter::Protocol::IMHandler::MSG_WRITE_REQUEST,
      request.to_slice, 101_u32)
    directory.preferred_extended_pan_id.should eq(GROUP_ARL_XPAN)

    directory.preferred_extended_pan_id = nil
    acl.configure_access_restrictions(1_u8, [] of GroupArlAcl::AccessRestrictionEntry)
    deliver_group_arl(router, keys[0], Matter::Protocol::IMHandler::MSG_WRITE_REQUEST,
      request.to_slice, 102_u32)
    directory.preferred_extended_pan_id.should eq(GROUP_ARL_XPAN)
  end

  it "applies the fabric ARL after Group ACL for a non-root Wi-Fi command" do
    acl, _, wifi, router, keys = group_arl_fixture
    acl.configure_access_restrictions(1_u8, [
      GroupArlAcl::AccessRestrictionEntry.new(1_u16, GroupArlWiFi::CLUSTER_ID, [
        GroupArlAcl::AccessRestriction.new(
          GroupArlAcl::AccessRestrictionType::CommandForbidden,
          GroupArlWiFi::CMD_NETWORK_PASSPHRASE_REQUEST),
      ]),
    ])
    request = Matter::InteractionModel::InvokeRequestMessage.new([
      Matter::InteractionModel::CommandDataIBTlv.new(
        Matter::InteractionModel::CommandPath.new(nil, GroupArlWiFi::CLUSTER_ID,
          GroupArlWiFi::CMD_NETWORK_PASSPHRASE_REQUEST)),
    ])

    deliver_group_arl(router, keys[0], Matter::Protocol::IMHandler::MSG_INVOKE_REQUEST,
      request.to_slice, 100_u32)
    wifi.request_count.should eq(0)

    deliver_group_arl(router, keys[1], Matter::Protocol::IMHandler::MSG_INVOKE_REQUEST,
      request.to_slice, 101_u32)
    wifi.request_count.should eq(1)

    acl.configure_access_restrictions(1_u8, [] of GroupArlAcl::AccessRestrictionEntry)
    deliver_group_arl(router, keys[0], Matter::Protocol::IMHandler::MSG_INVOKE_REQUEST,
      request.to_slice, 102_u32)
    wifi.request_count.should eq(2)
  end
end
