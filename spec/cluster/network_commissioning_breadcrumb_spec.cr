require "../spec_helper"
require "../../src/matter/cluster/network_commissioning"
require "tlv"

describe Matter::Cluster::NetworkCommissioning do
  it "publishes Breadcrumb only after successful WiFi network commands" do
    cluster = Matter::Cluster::NetworkCommissioning.new(
      network_type: Matter::Cluster::NetworkCommissioning::NetworkType::WiFi,
      backend: Matter::Network::TestBackend.new,
      max_networks: 2_u8
    )
    breadcrumbs = [] of UInt64
    cluster.on_breadcrumb_success = ->(value : UInt64) { breadcrumbs << value; nil }

    cluster.handle_scan_networks(
      Matter::Cluster::NetworkCommissioning::ScanNetworksRequest.new(breadcrumb: 1_u64),
      failsafe_armed: true
    ).networking_status.should eq(Matter::Cluster::NetworkCommissioning::NetworkCommissioningStatus::Success)

    ["first", "second"].each_with_index do |name, index|
      cluster.handle_add_or_update_wifi_network(
        Matter::Cluster::NetworkCommissioning::AddOrUpdateWiFiNetworkRequest.new(
          ssid: name.to_slice,
          credentials: "password".to_slice,
          breadcrumb: (index + 2).to_u64
        ),
        failsafe_armed: true
      ).networking_status.should eq(Matter::Cluster::NetworkCommissioning::NetworkCommissioningStatus::Success)
    end

    cluster.handle_reorder_network(
      Matter::Cluster::NetworkCommissioning::ReorderNetworkRequest.new(
        network_id: "second".to_slice,
        network_index: 0_u8,
        breadcrumb: 4_u64
      ),
      failsafe_armed: true
    ).networking_status.should eq(Matter::Cluster::NetworkCommissioning::NetworkCommissioningStatus::Success)

    cluster.handle_connect_network(
      Matter::Cluster::NetworkCommissioning::ConnectNetworkRequest.new(
        network_id: "second".to_slice,
        breadcrumb: 5_u64
      ),
      failsafe_armed: true
    ).networking_status.should eq(Matter::Cluster::NetworkCommissioning::NetworkCommissioningStatus::Success)

    cluster.handle_remove_network(
      Matter::Cluster::NetworkCommissioning::RemoveNetworkRequest.new(
        network_id: "first".to_slice,
        breadcrumb: 6_u64
      ),
      failsafe_armed: true
    ).networking_status.should eq(Matter::Cluster::NetworkCommissioning::NetworkCommissioningStatus::Success)

    cluster.handle_add_or_update_wifi_network(
      Matter::Cluster::NetworkCommissioning::AddOrUpdateWiFiNetworkRequest.new(
        ssid: "second".to_slice,
        credentials: "password".to_slice
      ),
      failsafe_armed: true
    ).networking_status.should eq(Matter::Cluster::NetworkCommissioning::NetworkCommissioningStatus::Success)

    cluster.handle_add_or_update_wifi_network(
      Matter::Cluster::NetworkCommissioning::AddOrUpdateWiFiNetworkRequest.new(
        ssid: Bytes.new(0),
        credentials: "password".to_slice,
        breadcrumb: 7_u64
      ),
      failsafe_armed: true
    ).networking_status.should eq(Matter::Cluster::NetworkCommissioning::NetworkCommissioningStatus::OutOfRange)

    breadcrumbs.should eq([1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64])
  end

  it "publishes Breadcrumb after successful Thread provisioning" do
    cluster = Matter::Cluster::NetworkCommissioning.new(
      network_type: Matter::Cluster::NetworkCommissioning::NetworkType::Thread,
      backend: Matter::Network::TestBackend.new
    )
    breadcrumbs = [] of UInt64
    cluster.on_breadcrumb_success = ->(value : UInt64) { breadcrumbs << value; nil }

    cluster.handle_add_or_update_thread_network(
      Matter::Cluster::NetworkCommissioning::AddOrUpdateThreadNetworkRequest.new(
        operational_dataset: Bytes[0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA],
        breadcrumb: 8_u64
      ),
      failsafe_armed: true
    ).networking_status.should eq(Matter::Cluster::NetworkCommissioning::NetworkCommissioningStatus::Success)

    breadcrumbs.should eq([8_u64])
  end

  it "carries the wire Breadcrumb through the command handler" do
    cluster = Matter::Cluster::NetworkCommissioning.new(
      network_type: Matter::Cluster::NetworkCommissioning::NetworkType::WiFi,
      backend: Matter::Network::TestBackend.new
    )
    breadcrumbs = [] of UInt64
    cluster.on_breadcrumb_success = ->(value : UInt64) { breadcrumbs << value; nil }
    request = Matter::Cluster::NetworkCommissioning::Tlv::AddOrUpdateWiFiNetworkRequest.new(
      ssid: "wire".to_slice,
      credentials: "password".to_slice,
      breadcrumb: 0x1234_u64
    ).to_tlv(nil)

    response = invoke(cluster, Matter::Cluster::NetworkCommissioning::CMD_ADD_OR_UPDATE_WIFI_NETWORK, request)
    payload = response.as(Matter::Cluster::CommandResponse).response.as(TLV::Any)
    decoded = Matter::Cluster::NetworkCommissioning::Tlv::NetworkConfigurationResponse.from_tlv(payload)

    decoded.status_code.should eq(Matter::Cluster::NetworkCommissioning::Tlv::StatusCode::Success)
    breadcrumbs.should eq([0x1234_u64])
  end
end
