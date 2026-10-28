require "../spec_helper"
require "../../src/matter/cluster/access_control"
require "../../src/matter/cluster/descriptor"
require "../../src/matter/protocol/im_handler"

private alias EmptyAclAccess = Matter::Cluster::AccessControl
private alias EmptyAclDescriptor = Matter::Cluster::Descriptor
private alias EmptyAclIm = Matter::InteractionModel

describe "CASE access after a fabric loses its ACL" do
  it "does not let a removed controller restore its Administrator grant" do
    root = endpoint(0)
    acl = EmptyAclAccess.new(root)
    descriptor = EmptyAclDescriptor.new(root)
    clusters = {
      {0_u16, EmptyAclAccess::CLUSTER_ID}     => acl.as(Matter::Cluster::Base),
      {0_u16, EmptyAclDescriptor::CLUSTER_ID} => descriptor.as(Matter::Cluster::Base),
    }

    admin_subject = 101_u64
    grant = EmptyAclAccess::AccessControlEntry.new(
      EmptyAclAccess::AccessControlEntryPrivilege::Administer,
      EmptyAclAccess::AccessControlEntryAuthMode::CASE,
      [admin_subject], nil, 1_u8)
    acl.acl << grant

    acl_path = EmptyAclIm::AttributePath.new(endpoint: 0_u16,
      cluster: EmptyAclAccess::CLUSTER_ID, attribute: EmptyAclAccess::ATTR_ACL)
    removal = EmptyAclIm::AttributeDataIB.new(acl_path,
      TLV::Serializable.serialize_value([] of EmptyAclAccess::AccessControlEntry, nil))
    Matter::Protocol::IMHandler.write_attributes([removal], clusters,
      is_case_session: true, fabric_index: 1_u8, peer_subject_ids: [admin_subject]).first.status.status
      .should eq(EmptyAclIm::StatusCode::Success.value)
    acl.get_acl_for_fabric(1_u8).should be_empty

    acl_read = Matter::Protocol::IMHandler.read_attributes([acl_path], clusters,
      is_case_session: true, fabric_index: 1_u8, peer_subject_ids: [admin_subject]).first
    acl_read.attribute_status.try(&.status.status).should eq(EmptyAclIm::StatusCode::UnsupportedAccess.value)

    write = EmptyAclIm::AttributeDataIB.new(acl_path,
      TLV::Serializable.serialize_value([grant], nil))
    acl_write = Matter::Protocol::IMHandler.write_attributes([write], clusters,
      is_case_session: true, fabric_index: 1_u8, peer_subject_ids: [admin_subject]).first
    acl_write.status.status.should eq(EmptyAclIm::StatusCode::UnsupportedAccess.value)
    acl.get_acl_for_fabric(1_u8).should be_empty

    descriptor_path = EmptyAclIm::AttributePath.new(endpoint: 0_u16,
      cluster: EmptyAclDescriptor::CLUSTER_ID,
      attribute: EmptyAclDescriptor::ATTR_DEVICE_TYPE_LIST)
    Matter::Protocol::IMHandler.read_attributes([descriptor_path], clusters).first
      .attribute_data.should_not be_nil
    Matter::Protocol::IMHandler.write_attributes([write], clusters).first.status.status
      .should eq(EmptyAclIm::StatusCode::UnsupportedAccess.value)
  end

  it "fails closed if the mandatory Access Control cluster is unavailable" do
    descriptor = EmptyAclDescriptor.new(endpoint(0))
    clusters = {
      {0_u16, EmptyAclDescriptor::CLUSTER_ID} => descriptor.as(Matter::Cluster::Base),
    }
    descriptor_path = EmptyAclIm::AttributePath.new(endpoint: 0_u16,
      cluster: EmptyAclDescriptor::CLUSTER_ID,
      attribute: EmptyAclDescriptor::ATTR_DEVICE_TYPE_LIST)

    Matter::Protocol::IMHandler.read_attributes([descriptor_path], clusters,
      is_case_session: true, fabric_index: 1_u8, peer_subject_ids: [101_u64]).first
      .attribute_status.try(&.status.status).should eq(EmptyAclIm::StatusCode::UnsupportedAccess.value)
    Matter::Protocol::IMHandler.read_attributes([descriptor_path], clusters).first
      .attribute_data.should_not be_nil
  end
end
