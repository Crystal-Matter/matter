require "../spec_helper"
require "../../src/matter/cluster/access_control"
require "../../src/matter/protocol/im_handler"

private alias FilteredAcl = Matter::Cluster::AccessControl

private def read_acl_for_fabric(cluster : FilteredAcl, fabric_filtered : Bool) : Array(FilteredAcl::AccessControlEntry)
  path = Matter::InteractionModel::AttributePath.new(
    endpoint: Matter::Node::ROOT_ENDPOINT_ID,
    cluster: FilteredAcl::CLUSTER_ID,
    attribute: FilteredAcl::ATTR_ACL)
  request = Matter::InteractionModel::ReadRequestMessage.new(
    attribute_requests: [path], fabric_filtered: fabric_filtered)
  parsed = Matter::Protocol::IMHandler.parse_read_request(request.to_slice)
    .as(Matter::InteractionModel::ReadRequestMessage)
  clusters = {
    {Matter::Node::ROOT_ENDPOINT_ID, FilteredAcl::CLUSTER_ID} => cluster.as(Matter::Cluster::Base),
  }
  reports = Matter::Protocol::IMHandler.read_attributes(parsed.attribute_requests, clusters,
    fabric_index: 1_u8, is_case_session: true, peer_subject_ids: [101_u64],
    fabric_filtered: parsed.fabric_filtered != false)
  reports.size.should eq(1)
  data = reports.first.attribute_data || fail "expected ACL attribute data"
  TLV::Serializable.deserialize_value(data.data, Array(FilteredAcl::AccessControlEntry))
end

describe "Access Control ACL fabric filtering" do
  it "returns only the requesting fabric for filtered reads and all fabrics for unfiltered reads" do
    cluster = FilteredAcl.new(endpoint(0))
    cluster.acl = [
      FilteredAcl::AccessControlEntry.new(
        FilteredAcl::AccessControlEntryPrivilege::Administer,
        FilteredAcl::AccessControlEntryAuthMode::CASE,
        [101_u64], nil, 1_u8),
      FilteredAcl::AccessControlEntry.new(
        FilteredAcl::AccessControlEntryPrivilege::Administer,
        FilteredAcl::AccessControlEntryAuthMode::CASE,
        [202_u64], nil, 2_u8),
    ]

    read_acl_for_fabric(cluster, true).map(&.fabric_index).should eq([1_u8])
    read_acl_for_fabric(cluster, false).map(&.fabric_index).should eq([1_u8, 2_u8])
  end
end
