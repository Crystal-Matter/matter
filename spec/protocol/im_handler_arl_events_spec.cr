require "../spec_helper"
require "../../src/matter/cluster/access_control"
require "../support/allowed_arl_event_cluster"
require "../../src/matter/protocol/im_handler"

private alias EventAcl = Matter::Cluster::AccessControl
private alias EventLock = AllowedArlEventCluster
private EVENT_SUBJECT = 0x1234_u64

private def arl_event_fixture
  node = Matter::Node.new
  root = Matter::Endpoint.new(endpoint(0))
  acl = EventAcl.new(endpoint(0))
  root.add_cluster(acl)
  node.add_endpoint(root)
  endpoint_1 = Matter::Endpoint.new(endpoint(1))
  endpoint_1.add_cluster(build(EventLock, 1))
  node.add_endpoint(endpoint_1)

  [1_u8, 2_u8].each do |fabric_index|
    acl.acl << EventAcl::AccessControlEntry.new(
      EventAcl::AccessControlEntryPrivilege::Administer,
      EventAcl::AccessControlEntryAuthMode::CASE,
      [EVENT_SUBJECT], nil, fabric_index)
  end
  {node, acl}
end

private def arl_event_reports(node : Matter::Node, fabric_index : UInt8,
                              paths : Array(Matter::InteractionModel::EventPath))
  Matter::Protocol::IMHandler.read_events(paths, node.event_journal, node.clusters,
    fabric_index: fabric_index, is_case_session: true,
    peer_subject_ids: [EVENT_SUBJECT])
end

private def arl_event_path(event : UInt32?)
  Matter::InteractionModel::EventPath.new(
    endpoint: 1_u16, cluster: EventLock::CLUSTER_ID, event: event)
end

describe "host-configured ARL event reads" do
  it "returns AccessRestricted for a concrete path only on the restricted fabric" do
    node, acl = arl_event_fixture
    acl.configure_access_restrictions(1_u8, [
      EventAcl::AccessRestrictionEntry.new(1_u16, EventLock::CLUSTER_ID, [
        EventAcl::AccessRestriction.new(EventAcl::AccessRestrictionType::EventForbidden,
          EventLock::EVENT_RESTRICTED),
      ]),
    ])
    node.event_journal.record(1_u16, EventLock::CLUSTER_ID, EventLock::EVENT_RESTRICTED,
      :critical, TLV::Any.new(1_u32, nil))
    node.event_journal.record(1_u16, EventLock::CLUSTER_ID, EventLock::EVENT_ALLOWED,
      :critical, TLV::Any.new(2_u32, nil))

    restricted = arl_event_reports(node, 1_u8, [arl_event_path(EventLock::EVENT_RESTRICTED)])
    restricted.compact_map(&.event_status).map(&.status.status).should eq([0x9d_u8])
    restricted.compact_map(&.event_data).should be_empty

    allowed = arl_event_reports(node, 2_u8, [arl_event_path(EventLock::EVENT_RESTRICTED)])
    allowed.compact_map(&.event_status).should be_empty
    allowed.compact_map(&.event_data).size.should eq(1)

    wildcard = arl_event_reports(node, 1_u8, [arl_event_path(nil)])
    wildcard.compact_map(&.event_status).should be_empty
    wildcard.compact_map(&.event_data).map(&.path.event).should eq([EventLock::EVENT_ALLOWED])
    arl_event_reports(node, 2_u8, [arl_event_path(nil)])
      .compact_map(&.event_data).size.should eq(2)

    acl.configure_access_restrictions(1_u8, [
      EventAcl::AccessRestrictionEntry.new(1_u16, EventLock::CLUSTER_ID, [
        EventAcl::AccessRestriction.new(EventAcl::AccessRestrictionType::EventForbidden, nil),
      ]),
    ])
    arl_event_reports(node, 1_u8, [arl_event_path(nil)]).should be_empty
    arl_event_reports(node, 1_u8, [arl_event_path(EventLock::EVENT_ALLOWED)])
      .compact_map(&.event_status).map(&.status.status).should eq([0x9d_u8])
    acl.feature_map.value.should eq(EventAcl::Feature::Extension.value)
  end

  it "preserves ordinary ACL denial before an ARL restriction" do
    node, acl = arl_event_fixture
    acl.acl.clear
    acl.configure_access_restrictions(1_u8, [
      EventAcl::AccessRestrictionEntry.new(1_u16, EventLock::CLUSTER_ID, [
        EventAcl::AccessRestriction.new(EventAcl::AccessRestrictionType::EventForbidden, nil),
      ]),
    ])
    arl_event_reports(node, 1_u8, [arl_event_path(EventLock::EVENT_RESTRICTED)])
      .compact_map(&.event_status).map(&.status.status)
      .should eq([Matter::InteractionModel::StatusCode::UnsupportedAccess.value])
  end
end
