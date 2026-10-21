require "../spec_helper"
require "../../src/matter/cluster/network_commissioning"

describe Matter::Cluster::NetworkCommissioning do
  it "does not claim a WiFi network was provisioned without a platform backend" do
    cluster = Matter::Cluster::NetworkCommissioning.new(
      network_type: Matter::Cluster::NetworkCommissioning::NetworkType::WiFi
    )
    request = Matter::Cluster::NetworkCommissioning::AddOrUpdateWiFiNetworkRequest.new(
      ssid: "unconfigured".to_slice,
      credentials: "password".to_slice
    )

    response = cluster.handle_add_or_update_wifi_network(request, failsafe_armed: true)

    response.networking_status.should eq(Matter::Cluster::NetworkCommissioning::NetworkCommissioningStatus::UnknownError)
    cluster.networks.should be_empty
    cluster.wifi_credentials.should be_empty
    cluster.last_networking_status.should eq(Matter::Cluster::NetworkCommissioning::NetworkCommissioningStatus::UnknownError)
    cluster.last_network_id.should eq("unconfigured".to_slice)
  end

  it "does not report a successful wireless scan without a platform backend" do
    cluster = Matter::Cluster::NetworkCommissioning.new(
      network_type: Matter::Cluster::NetworkCommissioning::NetworkType::WiFi
    )

    response = cluster.handle_scan_networks(
      Matter::Cluster::NetworkCommissioning::ScanNetworksRequest.new,
      failsafe_armed: true
    )

    response.networking_status.should eq(Matter::Cluster::NetworkCommissioning::NetworkCommissioningStatus::UnknownError)
    cluster.last_networking_status.should eq(Matter::Cluster::NetworkCommissioning::NetworkCommissioningStatus::UnknownError)
  end

  it "does not claim a Thread network was provisioned without a platform backend" do
    cluster = Matter::Cluster::NetworkCommissioning.new(
      network_type: Matter::Cluster::NetworkCommissioning::NetworkType::Thread
    )
    request = Matter::Cluster::NetworkCommissioning::AddOrUpdateThreadNetworkRequest.new(
      operational_dataset: Bytes[0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA]
    )

    response = cluster.handle_add_or_update_thread_network(request, failsafe_armed: true)

    response.networking_status.should eq(Matter::Cluster::NetworkCommissioning::NetworkCommissioningStatus::UnknownError)
    cluster.networks.should be_empty
    cluster.thread_credentials.should be_empty
  end

  it "does not claim a stored wireless network was removed or connected without a backend" do
    cluster = Matter::Cluster::NetworkCommissioning.new(
      network_type: Matter::Cluster::NetworkCommissioning::NetworkType::WiFi
    )
    ssid = "stored".to_slice
    cluster.networks << Matter::Cluster::NetworkCommissioning::NetworkInfo.new(ssid, false)

    connect = cluster.handle_connect_network(
      Matter::Cluster::NetworkCommissioning::ConnectNetworkRequest.new(network_id: ssid),
      failsafe_armed: true
    )
    connect.networking_status.should eq(Matter::Cluster::NetworkCommissioning::NetworkCommissioningStatus::UnknownError)
    cluster.networks[0].connected?.should be_false

    remove = cluster.handle_remove_network(
      Matter::Cluster::NetworkCommissioning::RemoveNetworkRequest.new(network_id: ssid),
      failsafe_armed: true
    )
    remove.networking_status.should eq(Matter::Cluster::NetworkCommissioning::NetworkCommissioningStatus::UnknownError)
    cluster.networks.size.should eq(1)
  end
end
