require "../spec_helper"
require "../../src/matter/cluster/network_commissioning"
require "tlv"

describe Matter::Cluster::NetworkCommissioning do
  describe "protocol-level TLV command handling" do
    it "handles ScanNetworks TLV command" do
      backend = Matter::Network::TestBackend.new
      cluster = build(Matter::Cluster::NetworkCommissioning,
        network_type: Matter::Cluster::NetworkCommissioning::NetworkType::WiFi,
        backend: backend
      )

      # Use TLV::Serializable struct for request
      request_bytes = Matter::Cluster::NetworkCommissioning::Tlv::ScanAvailableNetworksRequest.new.to_tlv(nil)

      # Invoke command
      result = invoke(cluster, Matter::Cluster::NetworkCommissioning::CMD_SCAN_NETWORKS, request_bytes)
      result.should be_a(Matter::Cluster::CommandResponse)

      # Parse response using TLV::Serializable
      response = Matter::Cluster::NetworkCommissioning::Tlv::ScanNetworksResponse.from_tlv(result.as(Matter::Cluster::CommandResponse).response.as(TLV::Any))
      response.status_code.should eq(Matter::Cluster::NetworkCommissioning::Tlv::StatusCode::Success)
      response.wifi_scan_results.should_not be_nil
    end

    it "handles AddOrUpdateWiFiNetwork TLV command" do
      backend = Matter::Network::TestBackend.new
      cluster = build(Matter::Cluster::NetworkCommissioning,
        network_type: Matter::Cluster::NetworkCommissioning::NetworkType::WiFi,
        backend: backend
      )

      # Use TLV::Serializable struct for request
      request_bytes = Matter::Cluster::NetworkCommissioning::Tlv::AddOrUpdateWiFiNetworkRequest.new(
        ssid: "TestSSID".to_slice,
        credentials: "password".to_slice
      ).to_tlv(nil)

      # Invoke command
      result = invoke(cluster, Matter::Cluster::NetworkCommissioning::CMD_ADD_OR_UPDATE_WIFI_NETWORK, request_bytes)
      result.should be_a(Matter::Cluster::CommandResponse)

      # Parse response using TLV::Serializable
      response = Matter::Cluster::NetworkCommissioning::Tlv::NetworkConfigurationResponse.from_tlv(result.as(Matter::Cluster::CommandResponse).response.as(TLV::Any))
      response.status_code.should eq(Matter::Cluster::NetworkCommissioning::Tlv::StatusCode::Success)
    end

    it "answers OutOfRange when a request field violates its length constraint" do
      backend = Matter::Network::TestBackend.new
      cluster = build(Matter::Cluster::NetworkCommissioning,
        network_type: Matter::Cluster::NetworkCommissioning::NetworkType::WiFi,
        backend: backend
      )
      request_bytes = Matter::Cluster::NetworkCommissioning::Tlv::AddOrUpdateWiFiNetworkRequest.new(
        ssid: Bytes.new(33, 0x41_u8),
        credentials: "password".to_slice
      ).to_tlv(nil)

      result = invoke(cluster, Matter::Cluster::NetworkCommissioning::CMD_ADD_OR_UPDATE_WIFI_NETWORK, request_bytes)

      response = Matter::Cluster::NetworkCommissioning::Tlv::NetworkConfigurationResponse.from_tlv(result.as(Matter::Cluster::CommandResponse).response.as(TLV::Any))
      response.status_code.should eq(Matter::Cluster::NetworkCommissioning::Tlv::StatusCode::OutOfRange)
      response.debug_text.should eq("ssid must be max 32 bytes")
      cluster.networks.should be_empty
    end

    it "handles ConnectNetwork TLV command" do
      backend = Matter::Network::TestBackend.new
      cluster = build(Matter::Cluster::NetworkCommissioning,
        network_type: Matter::Cluster::NetworkCommissioning::NetworkType::WiFi,
        backend: backend
      )

      # First add a network
      add_req = Matter::Cluster::NetworkCommissioning::AddOrUpdateWiFiNetworkRequest.new(
        ssid: "TestNet".to_slice,
        credentials: "password".to_slice
      )
      cluster.handle_add_or_update_wifi_network(add_req, failsafe_armed: true)

      # Use TLV::Serializable struct for request
      request_bytes = Matter::Cluster::NetworkCommissioning::Tlv::ConnectNetworkRequest.new(
        network_id: "TestNet".to_slice
      ).to_tlv(nil)

      # Invoke command
      result = invoke(cluster, Matter::Cluster::NetworkCommissioning::CMD_CONNECT_NETWORK, request_bytes)
      result.should be_a(Matter::Cluster::CommandResponse)

      # Parse response using TLV::Serializable
      response = Matter::Cluster::NetworkCommissioning::Tlv::ConnectNetworkResponse.from_tlv(result.as(Matter::Cluster::CommandResponse).response.as(TLV::Any))
      response.status_code.should eq(Matter::Cluster::NetworkCommissioning::Tlv::StatusCode::Success)
    end
  end

  describe "ScanNetworks command" do
    it "validates request parameters" do
      expect_raises(ArgumentError, "ssid must be 1-32 bytes") do
        Matter::Cluster::NetworkCommissioning::ScanNetworksRequest.new(ssid: Bytes.new(0))
      end

      expect_raises(ArgumentError, "ssid must be 1-32 bytes") do
        Matter::Cluster::NetworkCommissioning::ScanNetworksRequest.new(ssid: Bytes.new(33))
      end
    end

    it "requires armed failsafe" do
      cluster = Matter::Cluster::NetworkCommissioning.new
      cmd = Matter::Cluster::NetworkCommissioning::ScanNetworksRequest.new

      response = cluster.handle_scan_networks(cmd, failsafe_armed: false)
      response.networking_status.should eq(Matter::Cluster::NetworkCommissioning::NetworkCommissioningStatus::UnknownError)
    end

    it "performs WiFi scan when WiFi feature enabled" do
      backend = Matter::Network::TestBackend.new
      cluster = Matter::Cluster::NetworkCommissioning.new(
        features: Matter::Cluster::NetworkCommissioning::Feature::WiFiNetworkInterface,
        backend: backend
      )
      cmd = Matter::Cluster::NetworkCommissioning::ScanNetworksRequest.new

      response = cluster.handle_scan_networks(cmd, failsafe_armed: true)

      response.networking_status.should eq(Matter::Cluster::NetworkCommissioning::NetworkCommissioningStatus::Success)
      wifi_results = response.wifi_scan_results
      wifi_results.should_not be_nil
      wifi_results.as(Array).size.should be > 0
    end

    it "performs Thread scan when Thread feature enabled" do
      backend = Matter::Network::TestBackend.new
      cluster = Matter::Cluster::NetworkCommissioning.new(
        features: Matter::Cluster::NetworkCommissioning::Feature::ThreadNetworkInterface,
        backend: backend
      )
      cmd = Matter::Cluster::NetworkCommissioning::ScanNetworksRequest.new

      response = cluster.handle_scan_networks(cmd, failsafe_armed: true)

      response.networking_status.should eq(Matter::Cluster::NetworkCommissioning::NetworkCommissioningStatus::Success)
      thread_results = response.thread_scan_results
      thread_results.should_not be_nil
      thread_results.as(Array).size.should be > 0
    end

    it "performs directed WiFi scan with SSID filter" do
      backend = Matter::Network::TestBackend.new
      cluster = Matter::Cluster::NetworkCommissioning.new(
        features: Matter::Cluster::NetworkCommissioning::Feature::WiFiNetworkInterface,
        backend: backend
      )
      ssid = "TestSSID".to_slice
      cmd = Matter::Cluster::NetworkCommissioning::ScanNetworksRequest.new(ssid: ssid)

      response = cluster.handle_scan_networks(cmd, failsafe_armed: true)

      response.networking_status.should eq(Matter::Cluster::NetworkCommissioning::NetworkCommissioningStatus::Success)
      wifi_results = response.wifi_scan_results.as(Array)
      wifi_results.size.should eq(1)
      wifi_results[0].ssid.should eq(ssid)
    end

    it "sorts WiFi results by RSSI (strongest first)" do
      cluster = Matter::Cluster::NetworkCommissioning.new(
        backend: Matter::Network::TestBackend.new,
        features: Matter::Cluster::NetworkCommissioning::Feature::WiFiNetworkInterface
      )
      cmd = Matter::Cluster::NetworkCommissioning::ScanNetworksRequest.new

      response = cluster.handle_scan_networks(cmd, failsafe_armed: true)

      results = response.wifi_scan_results.as(Array)
      # Verify sorted by RSSI descending
      results.each_cons(2) do |pair|
        (pair[0].rssi || -100).should be >= (pair[1].rssi || -100)
      end
    end

    it "sorts Thread results by LQI (highest first)" do
      cluster = Matter::Cluster::NetworkCommissioning.new(
        backend: Matter::Network::TestBackend.new,
        features: Matter::Cluster::NetworkCommissioning::Feature::ThreadNetworkInterface
      )
      cmd = Matter::Cluster::NetworkCommissioning::ScanNetworksRequest.new

      response = cluster.handle_scan_networks(cmd, failsafe_armed: true)

      results = response.thread_scan_results.as(Array)
      # Verify sorted by LQI descending
      results.each_cons(2) do |pair|
        (pair[0].lqi || 0).should be >= (pair[1].lqi || 0)
      end
    end

    it "updates state attributes after scan" do
      cluster = Matter::Cluster::NetworkCommissioning.new(backend: Matter::Network::TestBackend.new)
      cmd = Matter::Cluster::NetworkCommissioning::ScanNetworksRequest.new

      cluster.handle_scan_networks(cmd, failsafe_armed: true)

      cluster.last_networking_status.should eq(Matter::Cluster::NetworkCommissioning::NetworkCommissioningStatus::Success)
    end
  end

  describe "ConnectNetwork command" do
    it "validates request parameters" do
      expect_raises(ArgumentError, "network_id must be 1-32 bytes") do
        Matter::Cluster::NetworkCommissioning::ConnectNetworkRequest.new(
          network_id: Bytes.new(0)
        )
      end
    end

    it "requires armed failsafe" do
      cluster = Matter::Cluster::NetworkCommissioning.new
      cmd = Matter::Cluster::NetworkCommissioning::ConnectNetworkRequest.new(
        network_id: "test".to_slice
      )

      response = cluster.handle_connect_network(cmd, failsafe_armed: false)
      response.networking_status.should eq(Matter::Cluster::NetworkCommissioning::NetworkCommissioningStatus::UnknownError)
    end

    it "returns NetworkIdNotFound for non-existent network" do
      cluster = Matter::Cluster::NetworkCommissioning.new(
        features: Matter::Cluster::NetworkCommissioning::Feature::WiFiNetworkInterface
      )
      cmd = Matter::Cluster::NetworkCommissioning::ConnectNetworkRequest.new(
        network_id: "NonExistent".to_slice
      )

      response = cluster.handle_connect_network(cmd, failsafe_armed: true)
      response.networking_status.should eq(Matter::Cluster::NetworkCommissioning::NetworkCommissioningStatus::NetworkIdNotFound)
    end

    it "connects to network successfully" do
      cluster = Matter::Cluster::NetworkCommissioning.new(
        backend: Matter::Network::TestBackend.new,
        features: Matter::Cluster::NetworkCommissioning::Feature::WiFiNetworkInterface
      )
      ssid = "TestSSID".to_slice

      # Add network first
      add_cmd = Matter::Cluster::NetworkCommissioning::AddOrUpdateWiFiNetworkRequest.new(
        ssid: ssid,
        credentials: "password".to_slice
      )
      cluster.handle_add_or_update_wifi_network(add_cmd, failsafe_armed: true)

      # Connect to network
      connect_cmd = Matter::Cluster::NetworkCommissioning::ConnectNetworkRequest.new(
        network_id: ssid
      )
      response = cluster.handle_connect_network(connect_cmd, failsafe_armed: true)

      response.networking_status.should eq(Matter::Cluster::NetworkCommissioning::NetworkCommissioningStatus::Success)
      response.error_value.should be_nil
      cluster.networks[0].connected?.should be_true
    end

    it "disconnects other networks when connecting to target" do
      cluster = Matter::Cluster::NetworkCommissioning.new(
        backend: Matter::Network::TestBackend.new,
        features: Matter::Cluster::NetworkCommissioning::Feature::WiFiNetworkInterface,
        max_networks: 4_u8
      )

      # Add two networks
      ["Net1", "Net2"].each do |name|
        cmd = Matter::Cluster::NetworkCommissioning::AddOrUpdateWiFiNetworkRequest.new(
          ssid: name.to_slice,
          credentials: "password".to_slice
        )
        cluster.handle_add_or_update_wifi_network(cmd, failsafe_armed: true)
      end

      # Connect to second network
      connect_cmd = Matter::Cluster::NetworkCommissioning::ConnectNetworkRequest.new(
        network_id: "Net2".to_slice
      )
      cluster.handle_connect_network(connect_cmd, failsafe_armed: true)

      cluster.networks[0].connected?.should be_false
      cluster.networks[1].connected?.should be_true
    end

    it "updates state attributes after connect" do
      cluster = Matter::Cluster::NetworkCommissioning.new(
        backend: Matter::Network::TestBackend.new,
        features: Matter::Cluster::NetworkCommissioning::Feature::WiFiNetworkInterface
      )
      ssid = "TestSSID".to_slice

      # Add and connect
      add_cmd = Matter::Cluster::NetworkCommissioning::AddOrUpdateWiFiNetworkRequest.new(
        ssid: ssid,
        credentials: "password".to_slice
      )
      cluster.handle_add_or_update_wifi_network(add_cmd, failsafe_armed: true)

      connect_cmd = Matter::Cluster::NetworkCommissioning::ConnectNetworkRequest.new(
        network_id: ssid
      )
      cluster.handle_connect_network(connect_cmd, failsafe_armed: true)

      cluster.last_networking_status.should eq(Matter::Cluster::NetworkCommissioning::NetworkCommissioningStatus::Success)
      cluster.last_network_id.should eq(ssid)
      cluster.last_connect_error_value.should be_nil
    end
  end
end
