require "../spec_helper"
require "../../src/matter/cluster/access_control"
require "../../src/matter/cluster/ota_requestor"
require "../../src/matter/protocol/im_handler"

private alias OtaFabric = Matter::Cluster::OtaRequestor
private alias OtaFabricAcl = Matter::Cluster::AccessControl
private alias OtaFabricIM = Matter::InteractionModel

private def ota_provider_report(cluster : OtaFabric, acl : OtaFabricAcl,
                                fabric_index : UInt8?, is_case_session : Bool,
                                fabric_filtered : Bool) : OtaFabricIM::AttributeReportIB
  path = OtaFabricIM::AttributePath.new(
    endpoint: Matter::Node::ROOT_ENDPOINT_ID,
    cluster: OtaFabric::CLUSTER_ID,
    attribute: OtaFabric::ATTR_DEFAULT_OTA_PROVIDERS)
  request = OtaFabricIM::ReadRequestMessage.new(
    attribute_requests: [path], fabric_filtered: fabric_filtered)
  parsed = Matter::Protocol::IMHandler.parse_read_request(request.to_slice)
    .as(OtaFabricIM::ReadRequestMessage)
  clusters = {
    {Matter::Node::ROOT_ENDPOINT_ID, OtaFabricAcl::CLUSTER_ID} => acl.as(Matter::Cluster::Base),
    {Matter::Node::ROOT_ENDPOINT_ID, OtaFabric::CLUSTER_ID}    => cluster.as(Matter::Cluster::Base),
  }
  reports = Matter::Protocol::IMHandler.read_attributes(parsed.attribute_requests, clusters,
    fabric_index: fabric_index, is_case_session: is_case_session,
    peer_subject_ids: is_case_session ? [101_u64] : nil,
    fabric_filtered: parsed.fabric_filtered != false)
  reports.size.should eq(1)
  reports.first
end

private def ota_provider_entries(report : OtaFabricIM::AttributeReportIB) : Array(OtaFabric::ProviderLocation)
  data = report.attribute_data || fail "expected DefaultOTAProviders data"
  TLV::Serializable.deserialize_value(data.data, Array(OtaFabric::ProviderLocation))
end

describe "OTA Requestor DefaultOTAProviders fabric filtering" do
  it "returns only the accessing fabric by default and both fabrics when unfiltered, including after restore" do
    acl = OtaFabricAcl.new(Matter::DataType::EndpointNumber::ROOT)
    acl.acl = [1_u8, 2_u8].map do |fabric|
      OtaFabricAcl::AccessControlEntry.new(
        OtaFabricAcl::AccessControlEntryPrivilege::Administer,
        OtaFabricAcl::AccessControlEntryAuthMode::CASE, [101_u64], nil, fabric)
    end
    cluster = OtaFabric.new
    cluster.default_ota_providers = [
      OtaFabric::ProviderLocation.new(0x1001_u64, 0_u16, 1_u8),
      OtaFabric::ProviderLocation.new(0x2002_u64, 1_u16, 2_u8),
    ]

    ota_provider_entries(ota_provider_report(cluster, acl, 1_u8, true, true))
      .map(&.fabric_index).should eq([1_u8])
    unfiltered = ota_provider_entries(ota_provider_report(cluster, acl, 1_u8, true, false))
    unfiltered.map(&.fabric_index).should eq([1_u8, 2_u8])
    unfiltered.map(&.provider_node_id).should eq([0x1001_u64, 0x2002_u64])
    unfiltered.each do |entry|
      entry.to_tlv(nil).as_structure.has_key?(254_u8).should be_true
    end
    cluster.providers_for_fabric(1_u8).map(&.provider_node_id).should eq([0x1001_u64])

    restored = OtaFabric.new
    restored.restore_state(cluster.save_state.as(Matter::Storage::Document))
    ota_provider_entries(ota_provider_report(restored, acl, 1_u8, true, false))
      .map(&.fabric_index).should eq([1_u8, 2_u8])
  end

  it "does not expose another fabric when no authenticated fabric exists" do
    acl = OtaFabricAcl.new(Matter::DataType::EndpointNumber::ROOT)
    acl.acl << OtaFabricAcl::AccessControlEntry.new(
      OtaFabricAcl::AccessControlEntryPrivilege::Administer,
      OtaFabricAcl::AccessControlEntryAuthMode::CASE, [101_u64], nil, 1_u8)
    cluster = OtaFabric.new
    cluster.default_ota_providers = [OtaFabric::ProviderLocation.new(0x2002_u64, 0_u16, 2_u8)]

    ota_provider_report(cluster, acl, nil, true, false).attribute_status.try(&.status.status)
      .should eq(OtaFabricIM::StatusCode::UnsupportedAccess.value)
    ota_provider_entries(ota_provider_report(cluster, acl, nil, false, false)).should be_empty
  end
end
