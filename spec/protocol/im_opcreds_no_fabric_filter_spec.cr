require "../support/operational_credentials_helpers"
require "../../src/matter/cluster/access_control"
require "../../src/matter/protocol/im_handler"

private alias FilteredOpCreds = Matter::Cluster::OperationalCredentials
private alias FilteredOpCredsAcl = Matter::Cluster::AccessControl

private def read_opcreds_fabric_list(cluster : FilteredOpCreds, acl : FilteredOpCredsAcl,
                                     attribute_id : UInt32, fabric_index : UInt8?,
                                     fabric_filtered : Bool, is_case_session : Bool,
                                     peer_node_id : UInt64) : TLV::Any
  path = Matter::InteractionModel::AttributePath.new(
    endpoint: Matter::Node::ROOT_ENDPOINT_ID,
    cluster: FilteredOpCreds::CLUSTER_ID,
    attribute: attribute_id)
  request = Matter::InteractionModel::ReadRequestMessage.new(
    attribute_requests: [path], fabric_filtered: fabric_filtered)
  parsed = Matter::Protocol::IMHandler.parse_read_request(request.to_slice)
    .as(Matter::InteractionModel::ReadRequestMessage)
  clusters = {
    {Matter::Node::ROOT_ENDPOINT_ID, FilteredOpCredsAcl::CLUSTER_ID} => acl.as(Matter::Cluster::Base),
    {Matter::Node::ROOT_ENDPOINT_ID, FilteredOpCreds::CLUSTER_ID}    => cluster.as(Matter::Cluster::Base),
  }
  reports = Matter::Protocol::IMHandler.read_attributes(parsed.attribute_requests, clusters,
    fabric_index: fabric_index, is_case_session: is_case_session,
    peer_subject_ids: [peer_node_id], fabric_filtered: parsed.fabric_filtered != false)
  reports.size.should eq(1)
  reports.first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data
end

private def opcreds_list_indices(data : TLV::Any, attribute_id : UInt32) : Array(UInt8)
  case attribute_id
  when FilteredOpCreds::ATTR_NOCS
    TLV::Serializable.deserialize_value(data, Array(FilteredOpCreds::Tlv::NOC)).map(&.fabric_index)
  when FilteredOpCreds::ATTR_FABRICS
    TLV::Serializable.deserialize_value(data, Array(FilteredOpCreds::Tlv::FabricDescriptor)).map(&.fabric_index)
  else
    fail "expected an Operational Credentials fabric-scoped list"
  end
end

describe "Operational Credentials fabric-scoped list reads without a fabric" do
  it "filters CASE reads but gives a filtered fabricless PASE read an empty list" do
    table = OpCredsTestHelpers.create_fabric_table
    table.add_fabric(OpCredsTestHelpers.create_test_fabric(0x111_u64, 1_u8, "First"))
    table.add_fabric(OpCredsTestHelpers.create_test_fabric(0x222_u64, 2_u8, "Second"))
    cluster = FilteredOpCreds.new(table, endpoint(0), nil)
    acl = FilteredOpCredsAcl.new(endpoint(0))
    {1_u8 => 101_u64, 2_u8 => 202_u64}.each do |fabric_index, node|
      acl.acl << FilteredOpCredsAcl::AccessControlEntry.new(
        FilteredOpCredsAcl::AccessControlEntryPrivilege::Administer,
        FilteredOpCredsAcl::AccessControlEntryAuthMode::CASE,
        [node], nil, fabric_index)
    end

    [FilteredOpCreds::ATTR_NOCS, FilteredOpCreds::ATTR_FABRICS].each do |attribute_id|
      {1_u8 => 101_u64, 2_u8 => 202_u64}.each do |fabric_index, node|
        filtered = read_opcreds_fabric_list(cluster, acl, attribute_id, fabric_index,
          true, true, node)
        opcreds_list_indices(filtered, attribute_id).should eq([fabric_index])
        unfiltered = read_opcreds_fabric_list(cluster, acl, attribute_id, fabric_index,
          false, true, node)
        opcreds_list_indices(unfiltered, attribute_id).should eq([1_u8, 2_u8])
      end

      filtered_pase = read_opcreds_fabric_list(cluster, acl, attribute_id, nil,
        true, false, 0_u64)
      opcreds_list_indices(filtered_pase, attribute_id).should be_empty
      unfiltered_pase = read_opcreds_fabric_list(cluster, acl, attribute_id, nil,
        false, false, 0_u64)
      opcreds_list_indices(unfiltered_pase, attribute_id).should eq([1_u8, 2_u8])
    end
  end
end
