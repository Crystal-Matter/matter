require "../spec_helper"
require "../../src/matter/controller"

describe Matter::Controller::Clusters::AccessControl do
  it "parses ACL JSON and encodes TLV accepted by AccessControl" do
    # Use a subject > Int64::MAX to ensure the parser doesn't rely on `JSON.parse` (which uses Int64).
    json = %([{"fabricIndex":2,"privilege":1,"authMode":2,"subjects":[16234001066904631842],"targets":[{"endpoint":1,"cluster":6,"deviceType":null}]}])

    entries = Matter::Controller::Clusters::AccessControl.parse_acl_json(json)
    entries.size.should eq 1
    entries[0].fabric_index.should be_nil

    tlv = Matter::Controller::Clusters::AccessControl.encode_acl_tlv(entries)

    cluster = build(Matter::Cluster::AccessControl, 0)
    cluster.acl << Matter::Cluster::AccessControl::AccessControlEntry.new(
      Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer,
      Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
      [16234001066904631842_u64], nil, 1_u8)
    status = write(cluster, Matter::Cluster::AccessControl::ATTR_ACL, TLV::Any.from_slice(tlv),
      is_case_session: true, fabric_index: 1_u8, peer_subject_ids: [16234001066904631842_u64])
    status.status.should eq Matter::InteractionModel::StatusCode::Success

    cluster.acl.size.should eq 1
    entry = cluster.acl[0]
    entry.privilege.should eq Matter::Cluster::AccessControl::AccessControlEntryPrivilege::View
    entry.auth_mode.should eq Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE
    entry.subjects.should eq [16234001066904631842_u64]
    entry.targets.as(Array(Matter::Cluster::AccessControl::Target)).size.should eq 1
    entry.targets.as(Array(Matter::Cluster::AccessControl::Target))[0].endpoint.should eq 1_u16
    entry.targets.as(Array(Matter::Cluster::AccessControl::Target))[0].cluster.should eq 6_u32
    entry.targets.as(Array(Matter::Cluster::AccessControl::Target))[0].device_type.should be_nil
  end

  it "does not discard a Matter 1.6 AuxiliaryType supplied to the primary ACL writer" do
    json = %([{"privilege":5,"authMode":2,"subjects":[202],"targets":null,"auxiliaryType":1}])
    expect_raises(ArgumentError, /AuxiliaryType/) do
      Matter::Controller::Clusters::AccessControl.parse_acl_json(json)
    end
  end
end
