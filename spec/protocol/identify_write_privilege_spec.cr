require "../spec_helper"
require "../../src/matter/cluster/access_control"
require "../../src/matter/cluster/identify"
require "../../src/matter/protocol/im_handler"

describe "IdentifyTime write privilege" do
  it "requires Operate on the wire as declared by Matter 1.6" do
    acl = Matter::Cluster::AccessControl.new(endpoint(0))
    identify = Matter::Cluster::Identify.new(endpoint(1))
    clusters = {
      {0_u16, Matter::Cluster::AccessControl::CLUSTER_ID} => acl.as(Matter::Cluster::Base),
      {1_u16, Matter::Cluster::Identify::CLUSTER_ID}      => identify.as(Matter::Cluster::Base),
    }
    subject = 0x1234_u64
    path = Matter::InteractionModel::AttributePath.new(1_u16,
      Matter::Cluster::Identify::CLUSTER_ID, Matter::Cluster::Identify::ATTR_IDENTIFY_TIME)
    write = Matter::InteractionModel::AttributeDataIB.new(path, TLV::Any.new(0_u16))

    identify.get_attribute_metadata(Matter::Cluster::Identify::ATTR_IDENTIFY_TIME)
      .as(Matter::Cluster::AttributeMetadata).write_access
      .should eq(Matter::InteractionModel::EntryPrivilege::Operate)

    [Matter::Cluster::AccessControl::AccessControlEntryPrivilege::View,
     Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Operate].each do |privilege|
      acl.acl.clear
      acl.acl << Matter::Cluster::AccessControl::AccessControlEntry.new(privilege,
        Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
        [subject], nil, 1_u8)
      status = Matter::Protocol::IMHandler.write_attributes([write], clusters,
        is_case_session: true, fabric_index: 1_u8, peer_subject_ids: [subject]).first
      expected = privilege.view? ? Matter::InteractionModel::StatusCode::UnsupportedAccess : Matter::InteractionModel::StatusCode::Success
      status.status.status.should eq(expected.value)
    end
  end
end
