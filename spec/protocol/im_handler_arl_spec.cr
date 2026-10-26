require "../spec_helper"
require "../../src/matter/cluster/access_control"
require "../../src/matter/cluster/on_off"
require "../../src/matter/cluster/wi_fi_network_management"
require "../../src/matter/cluster/thread_border_router_management"
require "../../src/matter/cluster/thread_network_directory"
require "../../src/matter/protocol/im_handler"

private alias ArlAcl = Matter::Cluster::AccessControl
private alias ArlWiFi = Matter::Cluster::WiFiNetworkManagement

private def arl_read(clusters, fabric_index : UInt8, attribute : UInt32?)
  path = Matter::InteractionModel::AttributePath.new(
    endpoint: 1_u16, cluster: ArlWiFi::CLUSTER_ID, attribute: attribute)
  Matter::Protocol::IMHandler.read_attributes([path], clusters,
    is_case_session: true, fabric_index: fabric_index, peer_subject_ids: [0x1234_u64])
end

describe "host-configured Access Restriction List reads" do
  it "returns AccessRestricted only on the configured fabric and preserves public global reads" do
    acl = ArlAcl.new(endpoint(0))
    wifi = ArlWiFi.new(endpoint(1))
    clusters = {
      {0_u16, ArlAcl::CLUSTER_ID}  => acl.as(Matter::Cluster::Base),
      {1_u16, ArlWiFi::CLUSTER_ID} => wifi.as(Matter::Cluster::Base),
    }
    [1_u8, 2_u8].each do |fabric_index|
      acl.acl << ArlAcl::AccessControlEntry.new(
        ArlAcl::AccessControlEntryPrivilege::Administer,
        ArlAcl::AccessControlEntryAuthMode::CASE,
        [0x1234_u64], nil, fabric_index)
    end

    acl.configure_access_restrictions(1_u8, [
      ArlAcl::AccessRestrictionEntry.new(1_u16, ArlWiFi::CLUSTER_ID, [
        ArlAcl::AccessRestriction.new(ArlAcl::AccessRestrictionType::AttributeAccessForbidden,
          ArlWiFi::ATTR_SSID),
      ]),
    ])

    restricted = arl_read(clusters, 1_u8, ArlWiFi::ATTR_SSID)
    restricted.first.attribute_data.should be_nil
    restricted.first.attribute_status.try(&.status.status).should eq(0x9d_u8)

    allowed = arl_read(clusters, 2_u8, ArlWiFi::ATTR_SSID)
    allowed.first.attribute_data.should_not be_nil
    allowed.first.attribute_status.should be_nil

    global = arl_read(clusters, 1_u8, Matter::Cluster::Base::GLOBAL_FEATURE_MAP)
    global.first.attribute_data.should_not be_nil
    global.first.attribute_status.should be_nil

    wildcard = arl_read(clusters, 1_u8, nil)
    wildcard.find! { |report| report.attribute_status.try(&.path.attribute) == ArlWiFi::ATTR_SSID }
      .attribute_status.try(&.status.status).should eq(0x9d_u8)
    wildcard.find { |report| report.attribute_data.try(&.path.attribute) == Matter::Cluster::Base::GLOBAL_FEATURE_MAP }
      .should_not be_nil

    acl.feature_map.value.should eq(ArlAcl::Feature::Extension.value)

    acl.configure_access_restrictions(1_u8, [
      ArlAcl::AccessRestrictionEntry.new(1_u16, ArlWiFi::CLUSTER_ID, [
        ArlAcl::AccessRestriction.new(ArlAcl::AccessRestrictionType::AttributeAccessForbidden, nil),
      ]),
    ])
    arl_read(clusters, 1_u8, ArlWiFi::ATTR_SSID).first
      .attribute_status.try(&.status.status).should eq(0x9d_u8)
    arl_read(clusters, 1_u8, Matter::Cluster::Base::GLOBAL_FEATURE_MAP).first
      .attribute_data.should_not be_nil

    acl.configure_access_restrictions(1_u8, [] of ArlAcl::AccessRestrictionEntry)
    arl_read(clusters, 1_u8, ArlWiFi::ATTR_SSID).first
      .attribute_data.should_not be_nil
  end

  it "accepts only network infrastructure clusters on non-root endpoints" do
    acl = ArlAcl.new(endpoint(0))
    restriction = ArlAcl::AccessRestriction.new(
      ArlAcl::AccessRestrictionType::AttributeAccessForbidden, nil)
    allowed_clusters = [ArlWiFi::CLUSTER_ID,
                        Matter::Cluster::ThreadBorderRouterManagement::CLUSTER_ID,
                        Matter::Cluster::ThreadNetworkDirectory::CLUSTER_ID]

    allowed_clusters.each do |cluster_id|
      acl.configure_access_restrictions(1_u8, [
        ArlAcl::AccessRestrictionEntry.new(1_u16, cluster_id, [restriction]),
      ])
      acl.attribute_read_restricted?(1_u8, 1_u16, cluster_id, 0_u32).should be_true

      expect_raises(Matter::ConfigurationError) do
        acl.configure_access_restrictions(1_u8, [
          ArlAcl::AccessRestrictionEntry.new(0_u16, cluster_id, [restriction]),
        ])
      end
      acl.attribute_read_restricted?(1_u8, 0_u16, cluster_id, 0_u32).should be_false
      acl.attribute_read_restricted?(1_u8, 1_u16, cluster_id, 0_u32).should be_true
    end

    [Matter::Cluster::OnOff::CLUSTER_ID, ArlAcl::CLUSTER_ID].each do |cluster_id|
      expect_raises(Matter::ConfigurationError) do
        acl.configure_access_restrictions(1_u8, [
          ArlAcl::AccessRestrictionEntry.new(1_u16, cluster_id, [restriction]),
        ])
      end
      acl.attribute_read_restricted?(1_u8, 1_u16, cluster_id, 0_u32).should be_false
    end
  end
end
