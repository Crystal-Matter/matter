require "../spec_helper"
require "../../src/matter/cluster/access_control"
require "../../src/matter/cluster/group_key_management"
require "../../src/matter/cluster/groupcast"
require "../../src/matter/protocol/im_handler"

private alias FabricGroupcast = Matter::Cluster::Groupcast
private alias FabricGroupcastKeys = Matter::Cluster::GroupKeyManagement
private alias FabricGroupcastAcl = Matter::Cluster::AccessControl
private alias FabricGroupcastIM = Matter::InteractionModel

private def read_membership(cluster : FabricGroupcast, acl : FabricGroupcastAcl,
                            fabric_index : UInt8?, is_case_session : Bool,
                            fabric_filtered : Bool) : FabricGroupcastIM::AttributeReportIB
  path = FabricGroupcastIM::AttributePath.new(
    endpoint: Matter::Node::ROOT_ENDPOINT_ID,
    cluster: FabricGroupcast::CLUSTER_ID,
    attribute: FabricGroupcast::ATTR_MEMBERSHIP)
  request = FabricGroupcastIM::ReadRequestMessage.new(
    attribute_requests: [path], fabric_filtered: fabric_filtered)
  parsed = Matter::Protocol::IMHandler.parse_read_request(request.to_slice)
    .as(FabricGroupcastIM::ReadRequestMessage)
  clusters = {
    {Matter::Node::ROOT_ENDPOINT_ID, FabricGroupcastAcl::CLUSTER_ID} => acl.as(Matter::Cluster::Base),
    {Matter::Node::ROOT_ENDPOINT_ID, FabricGroupcast::CLUSTER_ID}    => cluster.as(Matter::Cluster::Base),
  }
  reports = Matter::Protocol::IMHandler.read_attributes(parsed.attribute_requests, clusters,
    fabric_index: fabric_index, is_case_session: is_case_session,
    peer_subject_ids: is_case_session ? [101_u64] : nil,
    fabric_filtered: parsed.fabric_filtered != false)
  reports.size.should eq(1)
  reports.first
end

private def membership_entries(report : FabricGroupcastIM::AttributeReportIB) : Array(FabricGroupcast::MembershipStruct)
  data = report.attribute_data || fail "expected Groupcast Membership data"
  TLV::Serializable.deserialize_value(data.data, Array(FabricGroupcast::MembershipStruct))
end

describe "Groupcast Membership fabric filtering" do
  it "returns the requesting fabric by default and all fabrics when FabricFiltered is false, including after restore" do
    root = Matter::DataType::EndpointNumber::ROOT
    acl = FabricGroupcastAcl.new(root,
      feature_map: FabricGroupcastAcl::Feature::Extension | FabricGroupcastAcl::Feature::Auxiliary)
    acl.acl = [1_u8, 2_u8].map do |fabric|
      FabricGroupcastAcl::AccessControlEntry.new(
        FabricGroupcastAcl::AccessControlEntryPrivilege::Administer,
        FabricGroupcastAcl::AccessControlEntryAuthMode::CASE, [101_u64], nil, fabric)
    end
    keys = FabricGroupcastKeys.new(root, feature_map: FabricGroupcastKeys::Feature::Groupcast)
    cluster = FabricGroupcast.new(root, keys, acl)

    { {1_u8, 0x1234_u16}, {2_u8, 0x2345_u16} }.each do |fabric, group_id|
      cluster.with_request_context do
        cluster.request_fabric_index = fabric
        cluster.request_is_case_session = true
        cluster.request_peer_subject_ids = [101_u64]
        cluster.join_group(FabricGroupcast::JoinGroupRequest.new(group_id, [1_u16], 1_u16,
          key: Bytes.new(FabricGroupcast::KEY_BYTES, fabric)))
          .should eq(FabricGroupcastIM::Status.success)
      end
    end

    membership_entries(read_membership(cluster, acl, 1_u8, true, true))
      .map(&.fabric_index).should eq([1_u8])
    all = membership_entries(read_membership(cluster, acl, 1_u8, true, false))
    all.map(&.fabric_index).should eq([1_u8, 2_u8])
    all.map(&.group_id).should eq([0x1234_u16, 0x2345_u16])
    cluster.membership(1_u8).map(&.fabric_index).should eq([1_u8])

    recovered_keys = FabricGroupcastKeys.new(root, feature_map: FabricGroupcastKeys::Feature::Groupcast)
    recovered_acl = FabricGroupcastAcl.new(root,
      feature_map: FabricGroupcastAcl::Feature::Extension | FabricGroupcastAcl::Feature::Auxiliary)
    recovered_acl.acl = acl.acl
    recovered = FabricGroupcast.new(root, recovered_keys, recovered_acl)
    recovered_keys.restore_state(keys.save_state.as(Matter::Storage::Document))
    recovered.restore_state(cluster.save_state.as(Matter::Storage::Document))
    membership_entries(read_membership(recovered, recovered_acl, 1_u8, true, false))
      .map(&.fabric_index).should eq([1_u8, 2_u8])
  end

  it "does not expose other fabric memberships without an authenticated fabric" do
    root = Matter::DataType::EndpointNumber::ROOT
    acl = FabricGroupcastAcl.new(root,
      feature_map: FabricGroupcastAcl::Feature::Extension | FabricGroupcastAcl::Feature::Auxiliary)
    keys = FabricGroupcastKeys.new(root, feature_map: FabricGroupcastKeys::Feature::Groupcast)
    cluster = FabricGroupcast.new(root, keys, acl)
    keys.handle_key_set_write(FabricGroupcastKeys::KeySetWriteRequest.new(
      FabricGroupcastKeys::GroupKeySetStruct.new(1_u16,
        epoch_key0: Bytes.new(FabricGroupcast::KEY_BYTES, 2_u8), epoch_start_time0: 1_u64)), 2_u8)
    cluster.with_request_context do
      cluster.request_fabric_index = 2_u8
      cluster.request_is_case_session = true
      cluster.join_group(FabricGroupcast::JoinGroupRequest.new(0x2345_u16, [1_u16], 1_u16))
        .should eq(FabricGroupcastIM::Status.success)
    end

    missing = read_membership(cluster, acl, nil, true, false)
    missing.attribute_status.try(&.status.status)
      .should eq(FabricGroupcastIM::StatusCode::UnsupportedAccess.value)
    membership_entries(read_membership(cluster, acl, nil, false, false)).should be_empty
  end
end
