require "../spec_helper"
require "../../src/matter/cluster/access_control"
require "../../src/matter/cluster/thread_network_directory"
require "../../src/matter/protocol/im_handler"

private alias CommissioningAcl = Matter::Cluster::AccessControl
private alias CommissioningDirectory = Matter::Cluster::ThreadNetworkDirectory

private def commissioning_arl_fixture
  acl = CommissioningAcl.new(endpoint(0), CommissioningAcl::Feature::ManagedDevice)
  directory = CommissioningDirectory.new(endpoint(1))
  clusters = {
    {0_u16, CommissioningAcl::CLUSTER_ID}       => acl.as(Matter::Cluster::Base),
    {1_u16, CommissioningDirectory::CLUSTER_ID} => directory.as(Matter::Cluster::Base),
  }
  {acl, directory, clusters}
end

describe "Commissioning ARL enforcement" do
  it "blocks PASE reads and writes on configured paths but leaves CASE policy separate" do
    acl, _directory, clusters = commissioning_arl_fixture
    acl.configure_commissioning_access_restrictions([
      CommissioningAcl::CommissioningAccessRestrictionEntry.new(1_u16,
        CommissioningDirectory::CLUSTER_ID, [
        CommissioningAcl::AccessRestriction.new(
          CommissioningAcl::AccessRestrictionType::AttributeAccessForbidden,
          CommissioningDirectory::ATTR_PREFERRED_EXTENDED_PAN_ID),
      ]),
    ])
    path = Matter::InteractionModel::AttributePath.new(endpoint: 1_u16,
      cluster: CommissioningDirectory::CLUSTER_ID,
      attribute: CommissioningDirectory::ATTR_PREFERRED_EXTENDED_PAN_ID)
    read = Matter::Protocol::IMHandler.read_attributes([path], clusters).first
    read.attribute_status.try(&.status.status).should eq(0x9d_u8)
    write = Matter::InteractionModel::AttributeDataIB.new(path: path,
      data: TLV::Serializable.serialize_value(nil, nil))
    result = Matter::Protocol::IMHandler.write_attributes([write], clusters).first
    result.status.status.should eq(0x9d_u8)

    acl.acl << CommissioningAcl::AccessControlEntry.new(
      CommissioningAcl::AccessControlEntryPrivilege::Administer,
      CommissioningAcl::AccessControlEntryAuthMode::CASE, [0x1234_u64], nil, 1_u8)
    Matter::Protocol::IMHandler.read_attributes([path], clusters,
      is_case_session: true, fabric_index: 1_u8, peer_subject_ids: [0x1234_u64]).first
      .attribute_data.should_not be_nil
  end

  it "blocks a configured PASE command before its handler runs" do
    acl, _directory, clusters = commissioning_arl_fixture
    acl.configure_commissioning_access_restrictions([
      CommissioningAcl::CommissioningAccessRestrictionEntry.new(1_u16,
        CommissioningDirectory::CLUSTER_ID, [
        CommissioningAcl::AccessRestriction.new(
          CommissioningAcl::AccessRestrictionType::CommandForbidden,
          CommissioningDirectory::CMD_ADD_NETWORK),
      ]),
    ])
    path = Matter::InteractionModel::CommandPath.new(1_u16,
      CommissioningDirectory::CLUSTER_ID, CommissioningDirectory::CMD_ADD_NETWORK)
    command = Matter::InteractionModel::CommandDataIBTlv.new(path,
      TLV::Serializable.serialize_value(0_u8, nil))
    result = Matter::Protocol::IMHandler.invoke_commands([command], clusters).first
    result.command_status.try(&.status.status).should eq(0x9d_u8)
  end

  it "does not apply CommissioningARL while ManagedDevice is disabled" do
    acl = CommissioningAcl.new(endpoint(0))
    directory = CommissioningDirectory.new(endpoint(1))
    acl.configure_commissioning_access_restrictions([
      CommissioningAcl::CommissioningAccessRestrictionEntry.new(1_u16,
        CommissioningDirectory::CLUSTER_ID, [
        CommissioningAcl::AccessRestriction.new(
          CommissioningAcl::AccessRestrictionType::AttributeAccessForbidden,
          CommissioningDirectory::ATTR_PREFERRED_EXTENDED_PAN_ID),
      ]),
    ])
    path = Matter::InteractionModel::AttributePath.new(endpoint: 1_u16,
      cluster: CommissioningDirectory::CLUSTER_ID,
      attribute: CommissioningDirectory::ATTR_PREFERRED_EXTENDED_PAN_ID)
    clusters = {
      {0_u16, CommissioningAcl::CLUSTER_ID}       => acl.as(Matter::Cluster::Base),
      {1_u16, CommissioningDirectory::CLUSTER_ID} => directory.as(Matter::Cluster::Base),
    }
    Matter::Protocol::IMHandler.read_attributes([path], clusters).first.attribute_data.should_not be_nil
  end

  it "matches EventForbidden against commissioning paths" do
    acl, _directory, _clusters = commissioning_arl_fixture
    acl.configure_commissioning_access_restrictions([
      CommissioningAcl::CommissioningAccessRestrictionEntry.new(1_u16,
        CommissioningDirectory::CLUSTER_ID, [
        CommissioningAcl::AccessRestriction.new(
          CommissioningAcl::AccessRestrictionType::EventForbidden, 7_u32),
      ]),
    ])
    acl.commissioning_event_restricted?(1_u16, CommissioningDirectory::CLUSTER_ID, 7_u32).should be_true
    acl.commissioning_event_restricted?(1_u16, CommissioningDirectory::CLUSTER_ID, 8_u32).should be_false
  end
end
