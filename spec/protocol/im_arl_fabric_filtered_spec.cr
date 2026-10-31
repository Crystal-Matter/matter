require "../spec_helper"
require "../../src/matter/cluster/access_control"
require "../../src/matter/cluster/wi_fi_network_management"
require "../../src/matter/protocol/im_handler"

private alias FabricArlAcl = Matter::Cluster::AccessControl
private alias FabricArlWifi = Matter::Cluster::WiFiNetworkManagement
private FABRIC_ARL_SUBJECT = 101_u64

private def read_fabric_arl(acl : FabricArlAcl, fabric_filtered : Bool,
                            subject : UInt64 = FABRIC_ARL_SUBJECT) : Matter::InteractionModel::AttributeReportIB
  path = Matter::InteractionModel::AttributePath.new(
    endpoint: Matter::Node::ROOT_ENDPOINT_ID, cluster: FabricArlAcl::CLUSTER_ID,
    attribute: FabricArlAcl::ATTR_ARL)
  request = Matter::InteractionModel::ReadRequestMessage.new(
    attribute_requests: [path], fabric_filtered: fabric_filtered)
  parsed = Matter::Protocol::IMHandler.parse_read_request(request.to_slice)
    .as(Matter::InteractionModel::ReadRequestMessage)
  clusters = {
    {Matter::Node::ROOT_ENDPOINT_ID, FabricArlAcl::CLUSTER_ID} => acl.as(Matter::Cluster::Base),
  }
  reports = Matter::Protocol::IMHandler.read_attributes(parsed.attribute_requests, clusters,
    fabric_index: 1_u8, is_case_session: true, peer_subject_ids: [subject],
    fabric_filtered: parsed.fabric_filtered != false)
  reports.size.should eq(1)
  reports.first
end

private def fabric_arl_entries(report : Matter::InteractionModel::AttributeReportIB) : Array(FabricArlAcl::AccessRestrictionEntry)
  data = report.attribute_data || fail "expected ARL attribute data"
  TLV::Serializable.deserialize_value(data.data, Array(FabricArlAcl::AccessRestrictionEntry))
end

describe "Access Control ARL fabric filtering" do
  it "returns only the caller's policy by default and both policies when FabricFiltered is false" do
    acl = FabricArlAcl.new(endpoint(0), FabricArlAcl::Feature::ManagedDevice)
    acl.acl << FabricArlAcl::AccessControlEntry.new(
      FabricArlAcl::AccessControlEntryPrivilege::View,
      FabricArlAcl::AccessControlEntryAuthMode::CASE,
      [FABRIC_ARL_SUBJECT], nil, 1_u8)
    [1_u8, 2_u8].each do |fabric|
      acl.configure_access_restrictions(fabric, [FabricArlAcl::AccessRestrictionEntry.new(
        1_u16, FabricArlWifi::CLUSTER_ID, [FabricArlAcl::AccessRestriction.new(
        FabricArlAcl::AccessRestrictionType::AttributeAccessForbidden,
        FabricArlWifi::ATTR_SSID)])])
    end

    fabric_arl_entries(read_fabric_arl(acl, true)).map(&.fabric_index).should eq([1_u8])
    fabric_arl_entries(read_fabric_arl(acl, false)).map(&.fabric_index).should eq([1_u8, 2_u8])
    # Explicit host reads stay scoped even after an unfiltered wire read.
    acl.arl(1_u8).map(&.fabric_index).should eq([1_u8])
    read_fabric_arl(acl, false, 202_u64).attribute_status.try(&.status.status)
      .should eq(Matter::InteractionModel::StatusCode::UnsupportedAccess.value)
  end

  it "fails closed when another fabric's stale policy cannot be durably removed" do
    acl = FabricArlAcl.new(endpoint(0), FabricArlAcl::Feature::ManagedDevice)
    acl.acl << FabricArlAcl::AccessControlEntry.new(
      FabricArlAcl::AccessControlEntryPrivilege::View,
      FabricArlAcl::AccessControlEntryAuthMode::CASE,
      [FABRIC_ARL_SUBJECT], nil, 1_u8)
    identities = {1_u8 => "fabric-a", 2_u8 => "fabric-b"}
    acl.review_fabric_identity = ->(index : UInt8) { identities[index]? }
    fail_cleanup = false
    acl.on_persist = -> do
      raise Matter::StorageError.new("Injected stale ARL cleanup failure") if fail_cleanup
      nil
    end
    [1_u8, 2_u8].each do |fabric|
      acl.configure_access_restrictions(fabric, [FabricArlAcl::AccessRestrictionEntry.new(
        1_u16, FabricArlWifi::CLUSTER_ID, [FabricArlAcl::AccessRestriction.new(
        FabricArlAcl::AccessRestrictionType::AttributeAccessForbidden,
        FabricArlWifi::ATTR_SSID)])])
    end
    identities[2_u8] = "replacement-fabric"
    fail_cleanup = true

    read_fabric_arl(acl, false).attribute_status.try(&.status.status)
      .should eq(Matter::InteractionModel::StatusCode::Failure.value)
    fabric_arl_entries(read_fabric_arl(acl, true)).map(&.fabric_index).should eq([1_u8])

    fail_cleanup = false
    fabric_arl_entries(read_fabric_arl(acl, false)).map(&.fabric_index).should eq([1_u8])
  end
end
