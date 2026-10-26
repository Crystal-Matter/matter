require "../spec_helper"
require "../../src/matter/cluster/access_control"
require "../../src/matter/cluster/on_off"
require "../../src/matter/protocol/im_handler"

private alias OnOffACL = Matter::Cluster::AccessControl
private alias LightingOnOff = Matter::Cluster::OnOff

describe "OnOff lighting timer write privileges" do
  it "requires Operate for OnTime and OffWaitTime on a CASE fabric" do
    acl = OnOffACL.new(endpoint(0))
    on_off = LightingOnOff.new(endpoint(1), feature_map: LightingOnOff::Feature::Lighting)
    clusters = {
      {0_u16, OnOffACL::CLUSTER_ID}      => acl.as(Matter::Cluster::Base),
      {1_u16, LightingOnOff::CLUSTER_ID} => on_off.as(Matter::Cluster::Base),
    }
    subject = 0x1234_u64

    [LightingOnOff::ATTR_ON_TIME, LightingOnOff::ATTR_OFF_WAIT_TIME].each do |attribute_id|
      path = Matter::InteractionModel::AttributePath.new(1_u16,
        LightingOnOff::CLUSTER_ID, attribute_id)
      write = Matter::InteractionModel::AttributeDataIB.new(path, TLV::Any.new(1_u16))
      request = Matter::InteractionModel::WriteRequestMessage.new(write_requests: [write])
      parsed = Matter::Protocol::IMHandler.parse_write_request(request.to_slice)
      parsed.should_not be_nil
      writes = parsed.as(Matter::InteractionModel::WriteRequestMessage).write_requests

      [OnOffACL::AccessControlEntryPrivilege::View,
       OnOffACL::AccessControlEntryPrivilege::Operate].each do |privilege|
        acl.acl.clear
        acl.acl << OnOffACL::AccessControlEntry.new(privilege,
          OnOffACL::AccessControlEntryAuthMode::CASE, [subject], nil, 1_u8)
        response = Matter::Protocol::IMHandler.write_attributes(writes, clusters,
          is_case_session: true, fabric_index: 1_u8, peer_subject_ids: [subject]).first
        expected = privilege.view? ? Matter::InteractionModel::StatusCode::UnsupportedAccess : Matter::InteractionModel::StatusCode::Success
        response.status.status.should eq(expected.value)
        read(on_off, attribute_id).should eq(privilege.view? ? 0_u16 : 1_u16)
      end
    end
  end
end
