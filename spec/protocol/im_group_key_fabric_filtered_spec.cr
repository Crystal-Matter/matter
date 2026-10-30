require "../spec_helper"
require "../support/group_key_management_helpers"
require "../../src/matter/cluster/access_control"
require "../../src/matter/cluster/group_key_management"
require "../../src/matter/protocol/im_handler"

private alias FabricGroupKeys = Matter::Cluster::GroupKeyManagement
private alias FabricGroupAcl = Matter::Cluster::AccessControl

private def read_group_key_list(cluster : FabricGroupKeys, acl : FabricGroupAcl,
                                attribute_id : UInt32, fabric_filtered : Bool) : TLV::Any
  path = Matter::InteractionModel::AttributePath.new(
    endpoint: Matter::Node::ROOT_ENDPOINT_ID,
    cluster: FabricGroupKeys::CLUSTER_ID,
    attribute: attribute_id)
  request = Matter::InteractionModel::ReadRequestMessage.new(
    attribute_requests: [path], fabric_filtered: fabric_filtered)
  parsed = Matter::Protocol::IMHandler.parse_read_request(request.to_slice)
    .as(Matter::InteractionModel::ReadRequestMessage)
  clusters = {
    {Matter::Node::ROOT_ENDPOINT_ID, FabricGroupAcl::CLUSTER_ID}  => acl.as(Matter::Cluster::Base),
    {Matter::Node::ROOT_ENDPOINT_ID, FabricGroupKeys::CLUSTER_ID} => cluster.as(Matter::Cluster::Base),
  }
  reports = Matter::Protocol::IMHandler.read_attributes(parsed.attribute_requests, clusters,
    fabric_index: 1_u8, is_case_session: true, peer_subject_ids: [101_u64],
    fabric_filtered: parsed.fabric_filtered != false)
  reports.size.should eq(1)
  data = reports.first.attribute_data || fail "expected group key attribute data"
  data.data
end

describe "Group Key Management fabric filtering" do
  it "returns both fabrics for unfiltered GroupKeyMap and GroupTable reads" do
    acl = FabricGroupAcl.new(endpoint(0))
    acl.acl << FabricGroupAcl::AccessControlEntry.new(
      FabricGroupAcl::AccessControlEntryPrivilege::Administer,
      FabricGroupAcl::AccessControlEntryAuthMode::CASE, [101_u64], nil, 1_u8)
    keys = FabricGroupKeys.new(endpoint(0))
    [1_u8, 2_u8].each do |fabric_index|
      keys.handle_key_set_write(
        FabricGroupKeys::KeySetWriteRequest.new(Matter::Cluster.create_key_set(id: 1_u16)),
        fabric_index)
      keys.add_group_key_map(100_u16, 1_u16, fabric_index)
      keys.add_group(100_u16, endpoint_id: 1_u16, group_name: nil, fabric_index: fabric_index)
    end

    filtered_map = TLV::Serializable.deserialize_value(
      read_group_key_list(keys, acl, FabricGroupKeys::ATTR_GROUP_KEY_MAP, true),
      Array(FabricGroupKeys::GroupKeyMapStruct))
    unfiltered_map = TLV::Serializable.deserialize_value(
      read_group_key_list(keys, acl, FabricGroupKeys::ATTR_GROUP_KEY_MAP, false),
      Array(FabricGroupKeys::GroupKeyMapStruct))
    filtered_table = TLV::Serializable.deserialize_value(
      read_group_key_list(keys, acl, FabricGroupKeys::ATTR_GROUP_TABLE, true),
      Array(FabricGroupKeys::GroupInfoMapStruct))
    unfiltered_table = TLV::Serializable.deserialize_value(
      read_group_key_list(keys, acl, FabricGroupKeys::ATTR_GROUP_TABLE, false),
      Array(FabricGroupKeys::GroupInfoMapStruct))

    filtered_map.map(&.fabric_index).should eq([1_u8])
    unfiltered_map.map(&.fabric_index).should eq([1_u8, 2_u8])
    filtered_table.map(&.fabric_index).should eq([1_u8])
    unfiltered_table.map(&.fabric_index).should eq([1_u8, 2_u8])

    keys.request_fabric_index = 2_u8
    keys.groupcast_adoption = [FabricGroupKeys::GroupcastAdoptionStruct.new(true)]
    TLV::Serializable.deserialize_value(
      read_group_key_list(keys, acl, FabricGroupKeys::ATTR_GROUP_KEY_MAP, false),
      Array(FabricGroupKeys::GroupKeyMapStruct)).map(&.fabric_index).should eq([1_u8])
    TLV::Serializable.deserialize_value(
      read_group_key_list(keys, acl, FabricGroupKeys::ATTR_GROUP_TABLE, false),
      Array(FabricGroupKeys::GroupInfoMapStruct)).map(&.fabric_index).should eq([1_u8])
  end
end
