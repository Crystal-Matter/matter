require "../spec_helper"
require "../../src/matter/cluster/access_control"
require "../../src/matter/cluster/binding"
require "../../src/matter/protocol/im_handler"

private alias FabricReadAcl = Matter::Cluster::AccessControl
private alias FabricReadBinding = Matter::Cluster::Binding

private def fabric_read_extension_data(value : UInt8) : Bytes
  TLV::Any.new(TLV::List{TLV::Any.new(value, {1_u16, 1_u16})}).to_slice
end

private def read_fabric_list(cluster : Matter::Cluster::Base, attribute_id : UInt32,
                             acl : FabricReadAcl, fabric_filtered : Bool) : TLV::Any
  path = Matter::InteractionModel::AttributePath.new(
    endpoint: cluster.endpoint_id.number, cluster: cluster.cluster_id.id, attribute: attribute_id)
  request = Matter::InteractionModel::ReadRequestMessage.new(
    attribute_requests: [path], fabric_filtered: fabric_filtered)
  parsed = Matter::Protocol::IMHandler.parse_read_request(request.to_slice)
    .as(Matter::InteractionModel::ReadRequestMessage)
  clusters = { {Matter::Node::ROOT_ENDPOINT_ID, FabricReadAcl::CLUSTER_ID} => acl.as(Matter::Cluster::Base) }
  clusters[{cluster.endpoint_id.number, cluster.cluster_id.id}] = cluster
  reports = Matter::Protocol::IMHandler.read_attributes(parsed.attribute_requests, clusters,
    fabric_index: 1_u8, is_case_session: true, peer_subject_ids: [101_u64],
    fabric_filtered: parsed.fabric_filtered != false)
  reports.size.should eq(1)
  data = reports.first.attribute_data || fail "expected fabric-scoped attribute data"
  data.data
end

describe "fabric-scoped Binding and Access Control Extension reads" do
  it "honors FabricFiltered for Binding on an authenticated fabric" do
    acl = FabricReadAcl.new(endpoint(0))
    acl.acl << FabricReadAcl::AccessControlEntry.new(
      FabricReadAcl::AccessControlEntryPrivilege::Administer,
      FabricReadAcl::AccessControlEntryAuthMode::CASE, [101_u64], nil, 1_u8)
    binding = FabricReadBinding.new(endpoint(1))
    binding.binding = [
      FabricReadBinding::Target.new(node: 11_u64, endpoint: 1_u16, fabric_index: 1_u8),
      FabricReadBinding::Target.new(node: 22_u64, endpoint: 1_u16, fabric_index: 2_u8),
    ]

    filtered = TLV::Serializable.deserialize_value(
      read_fabric_list(binding, FabricReadBinding::ATTR_BINDING, acl, true),
      Array(FabricReadBinding::Target))
    unfiltered = TLV::Serializable.deserialize_value(
      read_fabric_list(binding, FabricReadBinding::ATTR_BINDING, acl, false),
      Array(FabricReadBinding::Target))
    filtered.map(&.fabric_index).should eq([1_u8])
    unfiltered.map(&.fabric_index).should eq([1_u8, 2_u8])
  end

  it "honors FabricFiltered for Access Control Extension on an authenticated fabric" do
    acl = FabricReadAcl.new(endpoint(0))
    acl.acl << FabricReadAcl::AccessControlEntry.new(
      FabricReadAcl::AccessControlEntryPrivilege::Administer,
      FabricReadAcl::AccessControlEntryAuthMode::CASE, [101_u64], nil, 1_u8)
    acl.extension = [
      FabricReadAcl::ExtensionEntry.new(fabric_read_extension_data(1_u8), 1_u8),
      FabricReadAcl::ExtensionEntry.new(fabric_read_extension_data(2_u8), 2_u8),
    ]

    filtered = TLV::Serializable.deserialize_value(
      read_fabric_list(acl, FabricReadAcl::ATTR_EXTENSION, acl, true),
      Array(FabricReadAcl::ExtensionEntry))
    unfiltered = TLV::Serializable.deserialize_value(
      read_fabric_list(acl, FabricReadAcl::ATTR_EXTENSION, acl, false),
      Array(FabricReadAcl::ExtensionEntry))
    filtered.map(&.fabric_index).should eq([1_u8])
    unfiltered.map(&.fabric_index).should eq([1_u8, 2_u8])
  end
end
