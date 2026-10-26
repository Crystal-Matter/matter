require "../spec_helper"
require "../../src/matter/cluster/network_commissioning"
require "../support/network_commissioning_failsafe"

private alias RollbackNetwork = Matter::Cluster::NetworkCommissioning

private class DurableNetworkBackend < Matter::Network::TestBackend
  getter commits = 0
  getter durable_networks = {} of Bytes => Bytes

  def commit_configuration : Bool
    @commits += 1
    @durable_networks = @configured_networks.transform_values(&.dup)
    true
  end

  def restore_configuration(snapshot : Matter::Storage::Document) : Bool
    return false unless super
    @durable_networks = @configured_networks.transform_values(&.dup)
    true
  end
end

private class NoCheckpointNetworkBackend < Matter::Network::TestBackend
  def checkpoint_configuration : Matter::Storage::Document?
    nil
  end
end

private class NoCommitNetworkBackend < Matter::Network::TestBackend
  def commit_configuration : Bool
    false
  end
end

private class NoRestoreNetworkBackend < Matter::Network::TestBackend
  def restore_configuration(snapshot : Matter::Storage::Document) : Bool
    false
  end
end

describe Matter::Cluster::NetworkCommissioning do
  it "does not mutate a backend that cannot supply a rollback checkpoint" do
    backend = NoCheckpointNetworkBackend.new
    cluster = build(RollbackNetwork, network_type: RollbackNetwork::NetworkType::WiFi, backend: backend)
    arm_network_commissioning(cluster)
    request = RollbackNetwork::Tlv::AddOrUpdateWiFiNetworkRequest.new(
      ssid: "refused".to_slice, credentials: "password".to_slice)

    expect_status(invoke(cluster, RollbackNetwork::CMD_ADD_OR_UPDATE_WIFI_NETWORK, request),
      Matter::InteractionModel::StatusCode::Failure)
    backend.configured_networks.should be_empty
    cluster.networks.should be_empty
  end

  it "restores the original backend and network list after multiple tentative writes expire" do
    backend = Matter::Network::TestBackend.new
    cluster = build(RollbackNetwork, network_type: RollbackNetwork::NetworkType::WiFi,
      max_networks: 3_u8, backend: backend)
    original = RollbackNetwork::AddOrUpdateWiFiNetworkRequest.new(
      ssid: "original".to_slice, credentials: "old-password".to_slice)
    cluster.handle_add_or_update_wifi_network(original, failsafe_armed: true).networking_status.success?.should be_true
    commissioning = arm_network_commissioning(cluster)
    commissioning.network_state_store = cluster

    update = RollbackNetwork::Tlv::AddOrUpdateWiFiNetworkRequest.new(
      ssid: "original".to_slice, credentials: "new-password".to_slice)
    added = RollbackNetwork::Tlv::AddOrUpdateWiFiNetworkRequest.new(
      ssid: "tentative".to_slice, credentials: "temporary".to_slice)
    invoke(cluster, RollbackNetwork::CMD_ADD_OR_UPDATE_WIFI_NETWORK, update).should be_a(Matter::Cluster::CommandResponse)
    invoke(cluster, RollbackNetwork::CMD_ADD_OR_UPDATE_WIFI_NETWORK, added).should be_a(Matter::Cluster::CommandResponse)
    backend.configured_networks.size.should eq(2)

    commissioning.arm_failsafe(
      Matter::Cluster::GeneralCommissioning::ArmFailSafeRequest.new(0_u16, 0_u64),
      session_fabric_index: nil, is_pase_session: true)

    cluster.networks.map(&.network_id).should eq(["original".to_slice])
    backend.configured_networks["original".to_slice].should eq("old-password".to_slice)
    backend.configured_networks.has_key?("tentative".to_slice).should be_false
  end

  it "keeps successful CASE network changes after CommissioningComplete" do
    backend = DurableNetworkBackend.new
    cluster = build(RollbackNetwork, network_type: RollbackNetwork::NetworkType::WiFi, backend: backend)
    commissioning = Matter::Cluster::GeneralCommissioning.new(endpoint(0))
    cluster.general_commissioning = commissioning
    commissioning.network_state_store = cluster
    arm = Matter::Cluster::GeneralCommissioning::ArmFailSafeRequest.new(60_u16, 0_u64)
    commissioning.arm_failsafe(arm, session_fabric_index: 1_u8,
      is_pase_session: false).error_code.ok?.should be_true

    request = RollbackNetwork::Tlv::AddOrUpdateWiFiNetworkRequest.new(
      ssid: "committed".to_slice, credentials: "password".to_slice)
    invoke(cluster, RollbackNetwork::CMD_ADD_OR_UPDATE_WIFI_NETWORK, request,
      is_case_session: true, fabric_index: 1_u8).should be_a(Matter::Cluster::CommandResponse)
    commissioning.commissioning_complete(session_fabric_index: 1_u8,
      is_case_session: true).error_code.ok?.should be_true

    cluster.networks.map(&.network_id).should eq(["committed".to_slice])
    backend.configured_networks["committed".to_slice].should eq("password".to_slice)
    backend.commits.should eq(1)
    backend.durable_networks["committed".to_slice].should eq("password".to_slice)
  end

  it "keeps the fail-safe armed when the backend refuses a commit" do
    backend = NoCommitNetworkBackend.new
    cluster = build(RollbackNetwork, network_type: RollbackNetwork::NetworkType::WiFi, backend: backend)
    commissioning = Matter::Cluster::GeneralCommissioning.new(endpoint(0))
    cluster.general_commissioning = commissioning
    commissioning.network_state_store = cluster
    commissioning.arm_failsafe(Matter::Cluster::GeneralCommissioning::ArmFailSafeRequest.new(60_u16, 0_u64),
      session_fabric_index: 1_u8, is_pase_session: false)
    request = RollbackNetwork::Tlv::AddOrUpdateWiFiNetworkRequest.new(
      ssid: "temporary".to_slice, credentials: "password".to_slice)
    invoke(cluster, RollbackNetwork::CMD_ADD_OR_UPDATE_WIFI_NETWORK, request,
      is_case_session: true, fabric_index: 1_u8)

    expect_raises(Matter::CommissioningError) do
      commissioning.commissioning_complete(session_fabric_index: 1_u8, is_case_session: true)
    end
    commissioning.failsafe_context.as(Matter::Commissioning::FailsafeContext).armed?.should be_true
    commissioning.arm_failsafe(Matter::Cluster::GeneralCommissioning::ArmFailSafeRequest.new(0_u16, 0_u64),
      session_fabric_index: 1_u8, is_pase_session: false)
    backend.configured_networks.should be_empty
    cluster.networks.should be_empty
  end

  it "undoes a durable network commit when a later commissioning commit fails" do
    backend = DurableNetworkBackend.new
    cluster = build(RollbackNetwork, network_type: RollbackNetwork::NetworkType::WiFi, backend: backend)
    commissioning = Matter::Cluster::GeneralCommissioning.new(endpoint(0))
    cluster.general_commissioning = commissioning
    commissioning.network_state_store = cluster
    commissioning.on_failsafe_success = -> { raise Matter::StorageError.new("credential commit failed") }
    commissioning.arm_failsafe(Matter::Cluster::GeneralCommissioning::ArmFailSafeRequest.new(60_u16, 0_u64),
      session_fabric_index: 1_u8, is_pase_session: false)
    request = RollbackNetwork::Tlv::AddOrUpdateWiFiNetworkRequest.new(
      ssid: "temporary".to_slice, credentials: "password".to_slice)
    invoke(cluster, RollbackNetwork::CMD_ADD_OR_UPDATE_WIFI_NETWORK, request,
      is_case_session: true, fabric_index: 1_u8)

    expect_raises(Matter::StorageError) do
      commissioning.commissioning_complete(session_fabric_index: 1_u8, is_case_session: true)
    end
    backend.durable_networks.size.should eq(1)
    commissioning.failsafe_context.as(Matter::Commissioning::FailsafeContext).armed?.should be_true
    commissioning.arm_failsafe(Matter::Cluster::GeneralCommissioning::ArmFailSafeRequest.new(0_u16, 0_u64),
      session_fabric_index: 1_u8, is_pase_session: false)
    backend.durable_networks.should be_empty
    backend.configured_networks.should be_empty
    cluster.networks.should be_empty
  end

  it "reports a backend restore failure after fail-safe expiry" do
    backend = NoRestoreNetworkBackend.new
    cluster = build(RollbackNetwork, network_type: RollbackNetwork::NetworkType::WiFi, backend: backend)
    commissioning = arm_network_commissioning(cluster)
    commissioning.network_state_store = cluster
    request = RollbackNetwork::Tlv::AddOrUpdateWiFiNetworkRequest.new(
      ssid: "temporary".to_slice, credentials: "password".to_slice)
    invoke(cluster, RollbackNetwork::CMD_ADD_OR_UPDATE_WIFI_NETWORK, request)

    commissioning.arm_failsafe(Matter::Cluster::GeneralCommissioning::ArmFailSafeRequest.new(0_u16, 0_u64),
      session_fabric_index: nil, is_pase_session: true)

    commissioning.failsafe.network_rollback_failed?.should be_true
    backend.configured_networks.size.should eq(1)
  end

  it "persists committed network metadata for restart without duplicating backend credentials" do
    backend = DurableNetworkBackend.new
    cluster = build(RollbackNetwork, network_type: RollbackNetwork::NetworkType::WiFi, backend: backend)
    commissioning = Matter::Cluster::GeneralCommissioning.new(endpoint(0))
    cluster.general_commissioning = commissioning
    commissioning.network_state_store = cluster
    saved = nil.as(Matter::Storage::Document?)
    cluster.on_persist_network_state = -> { saved = cluster.save_state }
    commissioning.arm_failsafe(Matter::Cluster::GeneralCommissioning::ArmFailSafeRequest.new(60_u16, 0_u64),
      session_fabric_index: 1_u8, is_pase_session: false)

    request = RollbackNetwork::Tlv::AddOrUpdateWiFiNetworkRequest.new(
      ssid: "restart".to_slice, credentials: "sensitive-password".to_slice)
    invoke(cluster, RollbackNetwork::CMD_ADD_OR_UPDATE_WIFI_NETWORK, request,
      is_case_session: true, fabric_index: 1_u8)
    saved.should be_nil
    commissioning.commissioning_complete(session_fabric_index: 1_u8,
      is_case_session: true).error_code.ok?.should be_true

    document = saved.as(Matter::Storage::Document)
    document.has_key?("wifi_credentials").should be_false
    document.has_key?("thread_credentials").should be_false
    reloaded = build(RollbackNetwork, network_type: RollbackNetwork::NetworkType::WiFi,
      backend: backend)
    reloaded.restore_state(document)
    reloaded.networks.map(&.network_id).should eq(["restart".to_slice])
  end

  it "keeps direct InterfaceEnabled writes outside network command persistence" do
    cluster = build(RollbackNetwork, network_type: RollbackNetwork::NetworkType::WiFi)
    cluster.interface_enabled = false
    document = cluster.save_state.as(Matter::Storage::Document)
    document.has_key?("interface_enabled").should be_false

    reloaded = build(RollbackNetwork, network_type: RollbackNetwork::NetworkType::WiFi)
    reloaded.restore_state(document)
    reloaded.interface_enabled?.should be_true
  end
end
