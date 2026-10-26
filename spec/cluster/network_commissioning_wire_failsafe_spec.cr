require "../spec_helper"
require "../../src/matter/cluster/network_commissioning"
require "../support/network_commissioning_failsafe"

private alias NetworkCommissioningWire = Matter::Cluster::NetworkCommissioning
private alias NetworkCommissioningStatus = Matter::InteractionModel::StatusCode

private class CountingNetworkBackend < Matter::Network::TestBackend
  getter scans = 0

  def scan_wifi(ssid : String?) : Array(Matter::Cluster::NetworkCommissioning::WiFiInterfaceScanResult)
    @scans += 1
    super
  end
end

describe Matter::Cluster::NetworkCommissioning do
  it "rejects ScanNetworks on the wire without an armed fail-safe before scanning" do
    backend = CountingNetworkBackend.new
    cluster = build(NetworkCommissioningWire, network_type: NetworkCommissioningWire::NetworkType::WiFi, backend: backend)

    expect_status(invoke(cluster, NetworkCommissioningWire::CMD_SCAN_NETWORKS,
      NetworkCommissioningWire::Tlv::ScanAvailableNetworksRequest.new), NetworkCommissioningStatus::FailsafeRequired)
    backend.scans.should eq(0)
  end

  it "rejects network configuration on the wire without an armed fail-safe" do
    backend = CountingNetworkBackend.new
    cluster = build(NetworkCommissioningWire, network_type: NetworkCommissioningWire::NetworkType::WiFi, backend: backend)
    request = NetworkCommissioningWire::Tlv::AddOrUpdateWiFiNetworkRequest.new(
      ssid: "TestSSID".to_slice, credentials: "password".to_slice)

    expect_status(invoke(cluster, NetworkCommissioningWire::CMD_ADD_OR_UPDATE_WIFI_NETWORK, request),
      NetworkCommissioningStatus::FailsafeRequired)
    backend.configured_networks.should be_empty
    cluster.networks.should be_empty
  end

  it "guards every Wi-Fi network mutation before dispatch" do
    backend = CountingNetworkBackend.new
    cluster = build(NetworkCommissioningWire, network_type: NetworkCommissioningWire::NetworkType::WiFi, backend: backend)
    id = "TestSSID".to_slice

    expect_status(invoke(cluster, NetworkCommissioningWire::CMD_REMOVE_NETWORK,
      NetworkCommissioningWire::Tlv::RemoveNetworkRequest.new(id)), NetworkCommissioningStatus::FailsafeRequired)
    expect_status(invoke(cluster, NetworkCommissioningWire::CMD_CONNECT_NETWORK,
      NetworkCommissioningWire::Tlv::ConnectNetworkRequest.new(id)), NetworkCommissioningStatus::FailsafeRequired)
    expect_status(invoke(cluster, NetworkCommissioningWire::CMD_REORDER_NETWORK,
      NetworkCommissioningWire::Tlv::ReorderNetworkRequest.new(id, 0_u8, 0_u64)), NetworkCommissioningStatus::FailsafeRequired)
    backend.configured_networks.should be_empty
    cluster.networks.should be_empty
  end

  it "guards Thread provisioning before dispatch" do
    backend = CountingNetworkBackend.new
    cluster = build(NetworkCommissioningWire, network_type: NetworkCommissioningWire::NetworkType::Thread, backend: backend)

    expect_status(invoke(cluster, NetworkCommissioningWire::CMD_ADD_OR_UPDATE_THREAD_NETWORK,
      NetworkCommissioningWire::Tlv::AddOrUpdateThreadNetworkRequest.new(Bytes[1, 2], 0_u64)),
      NetworkCommissioningStatus::FailsafeRequired)
    backend.configured_networks.should be_empty
    cluster.networks.should be_empty
  end

  it "accepts a matching PASE fail-safe and rejects commands after disarm" do
    backend = CountingNetworkBackend.new
    cluster = build(NetworkCommissioningWire, network_type: NetworkCommissioningWire::NetworkType::WiFi, backend: backend)
    commissioning = arm_network_commissioning(cluster)
    scan = NetworkCommissioningWire::Tlv::ScanAvailableNetworksRequest.new

    invoke(cluster, NetworkCommissioningWire::CMD_SCAN_NETWORKS, scan).should be_a(Matter::Cluster::CommandResponse)
    backend.scans.should eq(1)

    commissioning.disarm_fail_safe
    expect_status(invoke(cluster, NetworkCommissioningWire::CMD_SCAN_NETWORKS, scan),
      NetworkCommissioningStatus::FailsafeRequired)
    backend.scans.should eq(1)
  end

  it "accepts only the fabric that armed a CASE fail-safe" do
    backend = CountingNetworkBackend.new
    cluster = build(NetworkCommissioningWire, network_type: NetworkCommissioningWire::NetworkType::WiFi, backend: backend)
    commissioning = Matter::Cluster::GeneralCommissioning.new(endpoint(0))
    cluster.general_commissioning = commissioning
    response = commissioning.arm_failsafe(
      Matter::Cluster::GeneralCommissioning::ArmFailSafeRequest.new(60_u16, 0_u64),
      session_fabric_index: 1_u8, is_pase_session: false)
    response.error_code.ok?.should be_true
    scan = NetworkCommissioningWire::Tlv::ScanAvailableNetworksRequest.new

    expect_status(invoke(cluster, NetworkCommissioningWire::CMD_SCAN_NETWORKS, scan,
      is_case_session: true, fabric_index: 2_u8), NetworkCommissioningStatus::UnsupportedAccess)
    expect_status(invoke(cluster, NetworkCommissioningWire::CMD_SCAN_NETWORKS, scan),
      NetworkCommissioningStatus::UnsupportedAccess)
    backend.scans.should eq(0)

    invoke(cluster, NetworkCommissioningWire::CMD_SCAN_NETWORKS, scan,
      is_case_session: true, fabric_index: 1_u8).should be_a(Matter::Cluster::CommandResponse)
    backend.scans.should eq(1)
  end
end
