require "../spec_helper"
require "../../src/matter/cluster/access_control"
require "../../src/matter/cluster/thread_network_directory"
require "../../src/matter/cluster/wi_fi_network_management"
require "../../src/matter/protocol/im_handler"

private alias RestrictionAcl = Matter::Cluster::AccessControl
private alias RestrictedDirectory = Matter::Cluster::ThreadNetworkDirectory
private alias RestrictedWiFi = Matter::Cluster::WiFiNetworkManagement

private ARL_XPAN = Bytes[1, 2, 3, 4, 5, 6, 7, 8]

private def arl_thread_tlv(type : UInt8, bytes : Bytes) : Bytes
  Bytes[type, bytes.size.to_u8] + bytes
end

private def arl_thread_dataset : Bytes
  arl_thread_tlv(14_u8, Bytes[0, 0, 0, 0, 0, 0, 0, 1]) +
    arl_thread_tlv(0_u8, Bytes[0, 0, 15]) +
    arl_thread_tlv(53_u8, Bytes[0, 4, 0, 0, 0, 1]) +
    arl_thread_tlv(2_u8, ARL_XPAN) +
    arl_thread_tlv(5_u8, Bytes.new(16, 0xaa_u8)) +
    arl_thread_tlv(7_u8, Bytes.new(8, 0xfd_u8)) +
    arl_thread_tlv(3_u8, "Home".to_slice) +
    arl_thread_tlv(1_u8, Bytes[0x12, 0x34]) +
    arl_thread_tlv(4_u8, Bytes.new(16, 0xbb_u8)) +
    arl_thread_tlv(12_u8, Bytes[0, 1, 0, 0])
end

private def restriction_clusters
  acl = RestrictionAcl.new(endpoint(0))
  directory = RestrictedDirectory.new(endpoint(1))
  wifi = RestrictedWiFi.new(endpoint(1))
  directory.add_network(RestrictedDirectory::AddNetworkRequest.new(arl_thread_dataset))
    .status.should eq(Matter::InteractionModel::StatusCode::Success)
  wifi.update_credentials("Test Wi-Fi".to_slice, "correct horse".to_slice, 1_u64)
  [1_u8, 2_u8].each do |fabric_index|
    acl.acl << RestrictionAcl::AccessControlEntry.new(
      RestrictionAcl::AccessControlEntryPrivilege::Administer,
      RestrictionAcl::AccessControlEntryAuthMode::CASE,
      [0x1234_u64], nil, fabric_index)
  end
  clusters = {
    {0_u16, RestrictionAcl::CLUSTER_ID}      => acl.as(Matter::Cluster::Base),
    {1_u16, RestrictedDirectory::CLUSTER_ID} => directory.as(Matter::Cluster::Base),
    {1_u16, RestrictedWiFi::CLUSTER_ID}      => wifi.as(Matter::Cluster::Base),
  }
  {acl, directory, wifi, clusters}
end

private def restricted_write(clusters, fabric_index : UInt8, value : Bytes)
  path = Matter::InteractionModel::AttributePath.new(
    endpoint: 1_u16, cluster: RestrictedDirectory::CLUSTER_ID,
    attribute: RestrictedDirectory::ATTR_PREFERRED_EXTENDED_PAN_ID)
  request = Matter::InteractionModel::AttributeDataIB.new(
    path: path, data: TLV::Serializable.serialize_value(value, nil))
  Matter::Protocol::IMHandler.write_attributes([request], clusters,
    is_case_session: true, fabric_index: fabric_index, peer_subject_ids: [0x1234_u64]).first.status.status
end

private def restricted_invoke(clusters, fabric_index : UInt8)
  path = Matter::InteractionModel::CommandPath.new(1_u16, RestrictedWiFi::CLUSTER_ID,
    RestrictedWiFi::CMD_NETWORK_PASSPHRASE_REQUEST)
  request = Matter::InteractionModel::CommandDataIBTlv.new(path, TLV::Any.new(nil))
  Matter::Protocol::IMHandler.invoke_commands([request], clusters,
    is_case_session: true, fabric_index: fabric_index, peer_subject_ids: [0x1234_u64]).first
end

describe "host-configured Access Restriction List writes and invokes" do
  it "blocks writes on only the configured fabric, including AttributeAccessForbidden" do
    acl, directory, _, clusters = restriction_clusters
    acl.configure_access_restrictions(1_u8, [
      RestrictionAcl::AccessRestrictionEntry.new(1_u16, RestrictedDirectory::CLUSTER_ID, [
        RestrictionAcl::AccessRestriction.new(
          RestrictionAcl::AccessRestrictionType::AttributeWriteForbidden,
          RestrictedDirectory::ATTR_PREFERRED_EXTENDED_PAN_ID),
      ]),
    ])

    read_path = Matter::InteractionModel::AttributePath.new(
      endpoint: 1_u16, cluster: RestrictedDirectory::CLUSTER_ID,
      attribute: RestrictedDirectory::ATTR_PREFERRED_EXTENDED_PAN_ID)
    Matter::Protocol::IMHandler.read_attributes([read_path], clusters,
      is_case_session: true, fabric_index: 1_u8, peer_subject_ids: [0x1234_u64]).first
      .attribute_data.should_not be_nil

    restricted_write(clusters, 1_u8, ARL_XPAN).should eq(0x9d_u8)
    directory.preferred_extended_pan_id.should be_nil
    restricted_write(clusters, 2_u8, ARL_XPAN).should eq(Matter::InteractionModel::StatusCode::Success.value)
    directory.preferred_extended_pan_id.should eq(ARL_XPAN)

    acl.configure_access_restrictions(1_u8, [
      RestrictionAcl::AccessRestrictionEntry.new(1_u16, RestrictedDirectory::CLUSTER_ID, [
        RestrictionAcl::AccessRestriction.new(
          RestrictionAcl::AccessRestrictionType::AttributeAccessForbidden, nil),
      ]),
    ])
    restricted_write(clusters, 1_u8, Bytes.empty).should eq(0x9d_u8)
    directory.preferred_extended_pan_id.should eq(ARL_XPAN)
    acl.feature_map.value.should eq(RestrictionAcl::Feature::Extension.value)
  end

  it "blocks Wi-Fi passphrase requests on one fabric without blocking Thread directory writes" do
    acl, directory, wifi, clusters = restriction_clusters
    acl.configure_access_restrictions(1_u8, [
      RestrictionAcl::AccessRestrictionEntry.new(1_u16, RestrictedWiFi::CLUSTER_ID, [
        RestrictionAcl::AccessRestriction.new(
          RestrictionAcl::AccessRestrictionType::CommandForbidden,
          RestrictedWiFi::CMD_NETWORK_PASSPHRASE_REQUEST),
      ]),
    ])

    restricted_invoke(clusters, 1_u8).command_status.try(&.status.status).should eq(0x9d_u8)
    restricted_invoke(clusters, 2_u8).command_data.should_not be_nil
    directory.preferred_extended_pan_id.should be_nil
    restricted_write(clusters, 1_u8, ARL_XPAN).should eq(Matter::InteractionModel::StatusCode::Success.value)
    directory.preferred_extended_pan_id.should eq(ARL_XPAN)

    acl.configure_access_restrictions(1_u8, [
      RestrictionAcl::AccessRestrictionEntry.new(1_u16, RestrictedWiFi::CLUSTER_ID, [
        RestrictionAcl::AccessRestriction.new(
          RestrictionAcl::AccessRestrictionType::CommandForbidden, nil),
      ]),
    ])
    restricted_invoke(clusters, 1_u8).command_status.try(&.status.status).should eq(0x9d_u8)
    wifi.ssid.should eq("Test Wi-Fi".to_slice)
    acl.feature_map.value.should eq(RestrictionAcl::Feature::Extension.value)
  end

  it "keeps an ordinary ACL denial distinct from an ARL restriction" do
    acl, directory, _, clusters = restriction_clusters
    acl.acl.clear
    acl.configure_access_restrictions(1_u8, [
      RestrictionAcl::AccessRestrictionEntry.new(1_u16, RestrictedDirectory::CLUSTER_ID, [
        RestrictionAcl::AccessRestriction.new(
          RestrictionAcl::AccessRestrictionType::AttributeWriteForbidden,
          RestrictedDirectory::ATTR_PREFERRED_EXTENDED_PAN_ID),
      ]),
      RestrictionAcl::AccessRestrictionEntry.new(1_u16, RestrictedWiFi::CLUSTER_ID, [
        RestrictionAcl::AccessRestriction.new(
          RestrictionAcl::AccessRestrictionType::CommandForbidden,
          RestrictedWiFi::CMD_NETWORK_PASSPHRASE_REQUEST),
      ]),
    ])

    restricted_write(clusters, 1_u8, ARL_XPAN)
      .should eq(Matter::InteractionModel::StatusCode::UnsupportedAccess.value)
    restricted_invoke(clusters, 1_u8).command_status.try(&.status.status)
      .should eq(Matter::InteractionModel::StatusCode::UnsupportedAccess.value)
    directory.preferred_extended_pan_id.should be_nil
  end
end
