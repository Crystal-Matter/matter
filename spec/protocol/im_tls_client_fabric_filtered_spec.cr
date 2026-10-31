require "../spec_helper"
require "../../src/matter/cluster/access_control"
require "../../src/matter/cluster/tls_client_management"
require "../../src/matter/protocol/im_handler"

private alias TlsFabricClient = Matter::Cluster::TlsClientManagement
private alias TlsFabricAcl = Matter::Cluster::AccessControl

private def tls_endpoint_reports(client : TlsFabricClient, acl : TlsFabricAcl,
                                 fabric_index : UInt8?, is_case_session : Bool,
                                 fabric_filtered : Bool) : Array(Matter::InteractionModel::AttributeReportIB)
  path = Matter::InteractionModel::AttributePath.new(
    endpoint: Matter::Node::ROOT_ENDPOINT_ID,
    cluster: TlsFabricClient::CLUSTER_ID,
    attribute: TlsFabricClient::ATTR_PROVISIONED_ENDPOINTS)
  request = Matter::InteractionModel::ReadRequestMessage.new(
    attribute_requests: [path], fabric_filtered: fabric_filtered)
  parsed = Matter::Protocol::IMHandler.parse_read_request(request.to_slice)
    .as(Matter::InteractionModel::ReadRequestMessage)
  clusters = {
    {Matter::Node::ROOT_ENDPOINT_ID, TlsFabricAcl::CLUSTER_ID}    => acl.as(Matter::Cluster::Base),
    {Matter::Node::ROOT_ENDPOINT_ID, TlsFabricClient::CLUSTER_ID} => client.as(Matter::Cluster::Base),
  }
  Matter::Protocol::IMHandler.read_attributes(parsed.attribute_requests, clusters,
    fabric_index: fabric_index, is_case_session: is_case_session, peer_subject_ids: [101_u64],
    fabric_filtered: parsed.fabric_filtered != false)
end

describe "TLS Client Management fabric-scoped endpoint reads" do
  it "returns the requesting fabric or both fabrics over authenticated IM and encodes fabricIndex" do
    acl = TlsFabricAcl.new(endpoint(0))
    acl.acl << TlsFabricAcl::AccessControlEntry.new(
      TlsFabricAcl::AccessControlEntryPrivilege::Administer,
      TlsFabricAcl::AccessControlEntryAuthMode::CASE, [101_u64], nil, 1_u8)
    client = TlsFabricClient.new
    client.restore_state(TlsFabricClient::PersistedState.new(0_u32, [
      TlsFabricClient::EndpointRecord.new(7_u16, "a.example".to_slice, 443_u16, 1_u16, nil, 0_u8, 1_u8),
      TlsFabricClient::EndpointRecord.new(7_u16, "b.example".to_slice, 8443_u16, 1_u16, nil, 0_u8, 2_u8),
    ], {} of UInt8 => UInt16).to_document)

    filtered = tls_endpoint_reports(client, acl, 1_u8, true, true)
    unfiltered = tls_endpoint_reports(client, acl, 1_u8, true, false)
    filtered.size.should eq(1)
    unfiltered.size.should eq(1)
    filtered_data = filtered.first.attribute_data || fail "expected filtered endpoint data"
    unfiltered_data = unfiltered.first.attribute_data || fail "expected unfiltered endpoint data"
    filtered_endpoints = TLV::Serializable.deserialize_value(filtered_data.data, Array(TlsFabricClient::Tlv::Endpoint))
    unfiltered_endpoints = TLV::Serializable.deserialize_value(unfiltered_data.data, Array(TlsFabricClient::Tlv::Endpoint))
    filtered_endpoints.map(&.fabric_index).should eq([1_u8])
    unfiltered_endpoints.map(&.fabric_index).should eq([1_u8, 2_u8])
    unfiltered_endpoints.map(&.hostname).should eq(["a.example".to_slice, "b.example".to_slice])
    unfiltered_endpoints.each do |entry|
      encoded = entry.to_tlv(nil)
      encoded.as_structure.has_key?(254_u8).should be_true
      TlsFabricClient::Tlv::Endpoint.from_tlv(encoded).fabric_index.should eq(entry.fabric_index)
    end

    client.request_fabric_index = 1_u8
    client.request_is_case_session = true
    client.find_endpoint(TlsFabricClient::Tlv::FindEndpointRequest.new(7_u16))
      .as(TlsFabricClient::Tlv::FindEndpointResponse).endpoint.hostname.should eq("a.example".to_slice)
    client.request_fabric_index = 2_u8
    client.find_endpoint(TlsFabricClient::Tlv::FindEndpointRequest.new(7_u16))
      .as(TlsFabricClient::Tlv::FindEndpointResponse).endpoint.hostname.should eq("b.example".to_slice)
  end

  it "denies missing-fabric and unauthenticated endpoint reads" do
    acl = TlsFabricAcl.new(endpoint(0))
    acl.acl << TlsFabricAcl::AccessControlEntry.new(
      TlsFabricAcl::AccessControlEntryPrivilege::Administer,
      TlsFabricAcl::AccessControlEntryAuthMode::CASE, [101_u64], nil, 1_u8)
    client = TlsFabricClient.new
    {nil, 1_u8}.each do |fabric_index|
      reports = tls_endpoint_reports(client, acl, fabric_index, false, false)
      reports.first.attribute_data.should be_nil
      reports.first.attribute_status.try(&.status.status).should eq(Matter::InteractionModel::StatusCode::UnsupportedAccess.value)
    end
    tls_endpoint_reports(client, acl, nil, true, false).first.attribute_status.try(&.status.status)
      .should eq(Matter::InteractionModel::StatusCode::UnsupportedAccess.value)
  end
end
