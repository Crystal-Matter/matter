require "../spec_helper"
require "../../src/matter/cluster/access_control"
require "../../src/matter/cluster/network_commissioning"
require "../../src/matter/protocol/im_handler"
require "../support/test_network_backend"

private alias InterfaceNetwork = Matter::Cluster::NetworkCommissioning
private alias InterfaceAcl = Matter::Cluster::AccessControl

private alias InterfaceBackend = Matter::Network::TestBackend

private def interface_clusters(network : InterfaceNetwork, privilege = InterfaceAcl::AccessControlEntryPrivilege::Administer)
  acl = InterfaceAcl.new(endpoint(0))
  acl.acl << InterfaceAcl::AccessControlEntry.new(privilege,
    InterfaceAcl::AccessControlEntryAuthMode::CASE, [0x1234_u64], nil, 1_u8)
  {
    {0_u16, InterfaceAcl::CLUSTER_ID}     => acl.as(Matter::Cluster::Base),
    {0_u16, InterfaceNetwork::CLUSTER_ID} => network.as(Matter::Cluster::Base),
  }
end

private def interface_write(clusters, enabled : Bool)
  path = Matter::InteractionModel::AttributePath.new(0_u16,
    InterfaceNetwork::CLUSTER_ID, InterfaceNetwork::ATTR_INTERFACE_ENABLED)
  write = Matter::InteractionModel::AttributeDataIB.new(path, TLV::Any.new(enabled))
  Matter::Protocol::IMHandler.write_attributes([write], clusters,
    is_case_session: true, fabric_index: 1_u8, peer_subject_ids: [0x1234_u64]).first.status.status
end

private def interface_read(clusters) : Bool
  path = Matter::InteractionModel::AttributePath.new(0_u16,
    InterfaceNetwork::CLUSTER_ID, InterfaceNetwork::ATTR_INTERFACE_ENABLED)
  report = Matter::Protocol::IMHandler.read_attributes([path], clusters,
    is_case_session: true, fabric_index: 1_u8, peer_subject_ids: [0x1234_u64]).first
  report.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as_bool
end

describe "Network Commissioning InterfaceEnabled over authenticated IM" do
  it "rejects unsupported disable without changing the attribute or its version" do
    backend = InterfaceBackend.new
    network = InterfaceNetwork.new(endpoint(0), backend: backend)
    clusters = interface_clusters(network)
    version = network.data_version

    interface_write(clusters, false).should eq(Matter::InteractionModel::StatusCode::InvalidAction.value)
    interface_read(clusters).should be_true
    backend.enabled.should be_true
    network.data_version.should eq(version)
  end

  it "applies a supported disable and enable to the backend and persists across restart" do
    backend = InterfaceBackend.new
    backend.allow_disable = true
    network = InterfaceNetwork.new(endpoint(0), backend: backend)
    clusters = interface_clusters(network)

    interface_write(clusters, false).should eq(Matter::InteractionModel::StatusCode::Success.value)
    interface_read(clusters).should be_false
    backend.enabled.should be_false

    snapshot = network.save_state.as(Matter::Storage::Document)
    snapshot["interface_enabled"].should eq(false)
    restarted_backend = InterfaceBackend.new
    restarted_backend.allow_disable = true
    restarted = InterfaceNetwork.new(endpoint(0), backend: restarted_backend)
    restarted.restore_state(snapshot)
    interface_read(interface_clusters(restarted)).should be_false
    restarted_backend.enabled.should be_false

    interface_write(clusters, true).should eq(Matter::InteractionModel::StatusCode::Success.value)
    interface_read(clusters).should be_true
    backend.enabled.should be_true
  end

  it "fails without mutation when the backend cannot apply a supported change" do
    backend = InterfaceBackend.new
    backend.allow_disable = true
    backend.fail_next = true
    network = InterfaceNetwork.new(endpoint(0), backend: backend)
    clusters = interface_clusters(network)

    interface_write(clusters, false).should eq(Matter::InteractionModel::StatusCode::Failure.value)
    interface_read(clusters).should be_true
    backend.enabled.should be_true
  end

  it "accepts an older persisted record without InterfaceEnabled" do
    network = InterfaceNetwork.new(endpoint(0))
    snapshot = network.save_state.as(Matter::Storage::Document)
    snapshot.delete("interface_enabled")

    restarted_backend = InterfaceBackend.new
    restarted = InterfaceNetwork.new(endpoint(0), backend: restarted_backend)
    restarted.restore_state(snapshot)

    interface_read(interface_clusters(restarted)).should be_true
    restarted_backend.enabled.should be_true
  end

  it "requires Administer privilege for a disable write" do
    backend = InterfaceBackend.new
    backend.allow_disable = true
    network = InterfaceNetwork.new(endpoint(0), backend: backend)
    clusters = interface_clusters(network, InterfaceAcl::AccessControlEntryPrivilege::View)

    interface_write(clusters, false).should eq(Matter::InteractionModel::StatusCode::UnsupportedAccess.value)
    interface_read(clusters).should be_true
    backend.enabled.should be_true
  end
end
