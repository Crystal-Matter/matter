require "../spec_helper"
require "../../src/matter/cluster/network_commissioning"
require "tlv"

describe Matter::Cluster::NetworkCommissioning do
  describe "network management" do
    it "tracks networks list" do
      cluster = build(Matter::Cluster::NetworkCommissioning,
        network_type: Matter::Cluster::NetworkCommissioning::NetworkType::WiFi
      )

      cluster.networks.should be_empty

      # Add network
      ssid = "MyNetwork".to_slice
      cluster.networks << Matter::Cluster::NetworkCommissioning::NetworkInfo.new(ssid, false)

      cluster.networks.size.should eq(1)
      cluster.has_network?(ssid).should be_true
    end

    it "finds connected network" do
      cluster = build(Matter::Cluster::NetworkCommissioning,
        network_type: Matter::Cluster::NetworkCommissioning::NetworkType::WiFi
      )

      ssid1 = "Network1".to_slice
      ssid2 = "Network2".to_slice

      cluster.networks << Matter::Cluster::NetworkCommissioning::NetworkInfo.new(ssid1, false)
      cluster.networks << Matter::Cluster::NetworkCommissioning::NetworkInfo.new(ssid2, true)

      connected = cluster.connected_network
      connected.should_not be_nil
      connected.as(Matter::Cluster::NetworkCommissioning::NetworkInfo).network_id.should eq(ssid2)
    end

    it "returns nil when no network connected" do
      cluster = build(Matter::Cluster::NetworkCommissioning,
        network_type: Matter::Cluster::NetworkCommissioning::NetworkType::WiFi
      )

      cluster.connected_network.should be_nil
    end
  end

  describe "AddOrUpdateWiFiNetwork command" do
    it "validates request parameters" do
      expect_raises(ArgumentError, "ssid must be max 32 bytes") do
        Matter::Cluster::NetworkCommissioning::AddOrUpdateWiFiNetworkRequest.new(
          ssid: Bytes.new(33),
          credentials: Bytes.new(0)
        )
      end

      expect_raises(ArgumentError, "credentials must be max 64 bytes") do
        Matter::Cluster::NetworkCommissioning::AddOrUpdateWiFiNetworkRequest.new(
          ssid: "test".to_slice,
          credentials: Bytes.new(65)
        )
      end
    end

    it "requires armed failsafe" do
      cluster = Matter::Cluster::NetworkCommissioning.new
      cmd = Matter::Cluster::NetworkCommissioning::AddOrUpdateWiFiNetworkRequest.new(
        ssid: "TestSSID".to_slice,
        credentials: "password123".to_slice
      )

      response = cluster.handle_add_or_update_wifi_network(cmd, failsafe_armed: false)
      response.networking_status.should eq(Matter::Cluster::NetworkCommissioning::NetworkCommissioningStatus::UnknownError)
    end

    it "requires WiFi feature" do
      cluster = Matter::Cluster::NetworkCommissioning.new(
        backend: Matter::Network::TestBackend.new,
        features: Matter::Cluster::NetworkCommissioning::Feature::ThreadNetworkInterface
      )
      cmd = Matter::Cluster::NetworkCommissioning::AddOrUpdateWiFiNetworkRequest.new(
        ssid: "TestSSID".to_slice,
        credentials: "password123".to_slice
      )

      response = cluster.handle_add_or_update_wifi_network(cmd, failsafe_armed: true)
      response.networking_status.should eq(Matter::Cluster::NetworkCommissioning::NetworkCommissioningStatus::UnknownError)
    end

    it "rejects empty SSID" do
      cluster = Matter::Cluster::NetworkCommissioning.new(
        backend: Matter::Network::TestBackend.new,
        features: Matter::Cluster::NetworkCommissioning::Feature::WiFiNetworkInterface
      )
      cmd = Matter::Cluster::NetworkCommissioning::AddOrUpdateWiFiNetworkRequest.new(
        ssid: Bytes.new(0),
        credentials: "password123".to_slice
      )

      response = cluster.handle_add_or_update_wifi_network(cmd, failsafe_armed: true)
      response.networking_status.should eq(Matter::Cluster::NetworkCommissioning::NetworkCommissioningStatus::OutOfRange)
    end

    it "adds new WiFi network successfully" do
      cluster = Matter::Cluster::NetworkCommissioning.new(
        backend: Matter::Network::TestBackend.new,
        features: Matter::Cluster::NetworkCommissioning::Feature::WiFiNetworkInterface
      )
      ssid = "TestSSID".to_slice
      cmd = Matter::Cluster::NetworkCommissioning::AddOrUpdateWiFiNetworkRequest.new(
        ssid: ssid,
        credentials: "password123".to_slice
      )

      response = cluster.handle_add_or_update_wifi_network(cmd, failsafe_armed: true)

      response.networking_status.should eq(Matter::Cluster::NetworkCommissioning::NetworkCommissioningStatus::Success)
      response.network_index.should eq(0_u8)
      cluster.networks.size.should eq(1)
      cluster.networks[0].network_id.should eq(ssid)
      cluster.networks[0].connected?.should be_false
    end

    it "updates existing WiFi network" do
      cluster = Matter::Cluster::NetworkCommissioning.new(
        backend: Matter::Network::TestBackend.new,
        features: Matter::Cluster::NetworkCommissioning::Feature::WiFiNetworkInterface
      )
      ssid = "TestSSID".to_slice

      # Add network first
      cmd1 = Matter::Cluster::NetworkCommissioning::AddOrUpdateWiFiNetworkRequest.new(
        ssid: ssid,
        credentials: "oldpassword".to_slice
      )
      cluster.handle_add_or_update_wifi_network(cmd1, failsafe_armed: true)

      # Update with new credentials
      cmd2 = Matter::Cluster::NetworkCommissioning::AddOrUpdateWiFiNetworkRequest.new(
        ssid: ssid,
        credentials: "newpassword".to_slice
      )
      response = cluster.handle_add_or_update_wifi_network(cmd2, failsafe_armed: true)

      response.networking_status.should eq(Matter::Cluster::NetworkCommissioning::NetworkCommissioningStatus::Success)
      response.network_index.should eq(0_u8)
      cluster.networks.size.should eq(1) # Still only one network
    end

    it "rejects when max networks limit reached" do
      cluster = Matter::Cluster::NetworkCommissioning.new(
        backend: Matter::Network::TestBackend.new,
        max_networks: 2_u8,
        features: Matter::Cluster::NetworkCommissioning::Feature::WiFiNetworkInterface
      )

      # Add two networks
      (1..2).each do |i|
        cmd = Matter::Cluster::NetworkCommissioning::AddOrUpdateWiFiNetworkRequest.new(
          ssid: "Network#{i}".to_slice,
          credentials: "password".to_slice
        )
        cluster.handle_add_or_update_wifi_network(cmd, failsafe_armed: true)
      end

      # Try to add third network
      cmd3 = Matter::Cluster::NetworkCommissioning::AddOrUpdateWiFiNetworkRequest.new(
        ssid: "Network3".to_slice,
        credentials: "password".to_slice
      )
      response = cluster.handle_add_or_update_wifi_network(cmd3, failsafe_armed: true)

      response.networking_status.should eq(Matter::Cluster::NetworkCommissioning::NetworkCommissioningStatus::BoundsExceeded)
    end

    it "updates state attributes after add" do
      cluster = Matter::Cluster::NetworkCommissioning.new(
        backend: Matter::Network::TestBackend.new,
        features: Matter::Cluster::NetworkCommissioning::Feature::WiFiNetworkInterface
      )
      ssid = "TestSSID".to_slice
      cmd = Matter::Cluster::NetworkCommissioning::AddOrUpdateWiFiNetworkRequest.new(
        ssid: ssid,
        credentials: "password".to_slice
      )

      cluster.handle_add_or_update_wifi_network(cmd, failsafe_armed: true)

      cluster.last_networking_status.should eq(Matter::Cluster::NetworkCommissioning::NetworkCommissioningStatus::Success)
      cluster.last_network_id.should eq(ssid)
    end
  end

  describe "AddOrUpdateThreadNetwork command" do
    it "validates request parameters" do
      expect_raises(ArgumentError, "operational_dataset must be max 254 bytes") do
        Matter::Cluster::NetworkCommissioning::AddOrUpdateThreadNetworkRequest.new(
          operational_dataset: Bytes.new(255)
        )
      end
    end

    it "requires armed failsafe" do
      cluster = Matter::Cluster::NetworkCommissioning.new
      cmd = Matter::Cluster::NetworkCommissioning::AddOrUpdateThreadNetworkRequest.new(
        operational_dataset: Bytes.new(10)
      )

      response = cluster.handle_add_or_update_thread_network(cmd, failsafe_armed: false)
      response.networking_status.should eq(Matter::Cluster::NetworkCommissioning::NetworkCommissioningStatus::UnknownError)
    end

    it "requires Thread feature" do
      cluster = Matter::Cluster::NetworkCommissioning.new(
        backend: Matter::Network::TestBackend.new,
        features: Matter::Cluster::NetworkCommissioning::Feature::WiFiNetworkInterface
      )
      cmd = Matter::Cluster::NetworkCommissioning::AddOrUpdateThreadNetworkRequest.new(
        operational_dataset: Bytes.new(10)
      )

      response = cluster.handle_add_or_update_thread_network(cmd, failsafe_armed: true)
      response.networking_status.should eq(Matter::Cluster::NetworkCommissioning::NetworkCommissioningStatus::UnknownError)
    end

    it "adds new Thread network successfully" do
      cluster = Matter::Cluster::NetworkCommissioning.new(
        backend: Matter::Network::TestBackend.new,
        features: Matter::Cluster::NetworkCommissioning::Feature::ThreadNetworkInterface
      )
      dataset = Bytes[0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA]
      cmd = Matter::Cluster::NetworkCommissioning::AddOrUpdateThreadNetworkRequest.new(
        operational_dataset: dataset
      )

      response = cluster.handle_add_or_update_thread_network(cmd, failsafe_armed: true)

      response.networking_status.should eq(Matter::Cluster::NetworkCommissioning::NetworkCommissioningStatus::Success)
      response.network_index.should eq(0_u8)
      cluster.networks.size.should eq(1)
    end

    it "updates existing Thread network" do
      cluster = Matter::Cluster::NetworkCommissioning.new(
        backend: Matter::Network::TestBackend.new,
        features: Matter::Cluster::NetworkCommissioning::Feature::ThreadNetworkInterface
      )
      dataset = Bytes[0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA]

      # Add network first
      cmd1 = Matter::Cluster::NetworkCommissioning::AddOrUpdateThreadNetworkRequest.new(
        operational_dataset: dataset
      )
      cluster.handle_add_or_update_thread_network(cmd1, failsafe_armed: true)

      # Update with same XPAN ID (first 8 bytes)
      cmd2 = Matter::Cluster::NetworkCommissioning::AddOrUpdateThreadNetworkRequest.new(
        operational_dataset: dataset
      )
      response = cluster.handle_add_or_update_thread_network(cmd2, failsafe_armed: true)

      response.networking_status.should eq(Matter::Cluster::NetworkCommissioning::NetworkCommissioningStatus::Success)
      cluster.networks.size.should eq(1) # Still only one network
    end
  end

  describe "RemoveNetwork command" do
    it "validates request parameters" do
      expect_raises(ArgumentError, "network_id must be 1-32 bytes") do
        Matter::Cluster::NetworkCommissioning::RemoveNetworkRequest.new(
          network_id: Bytes.new(0)
        )
      end

      expect_raises(ArgumentError, "network_id must be 1-32 bytes") do
        Matter::Cluster::NetworkCommissioning::RemoveNetworkRequest.new(
          network_id: Bytes.new(33)
        )
      end
    end

    it "requires armed failsafe" do
      cluster = Matter::Cluster::NetworkCommissioning.new
      cmd = Matter::Cluster::NetworkCommissioning::RemoveNetworkRequest.new(
        network_id: "test".to_slice
      )

      response = cluster.handle_remove_network(cmd, failsafe_armed: false)
      response.networking_status.should eq(Matter::Cluster::NetworkCommissioning::NetworkCommissioningStatus::UnknownError)
    end

    it "returns NetworkIdNotFound for non-existent network" do
      cluster = Matter::Cluster::NetworkCommissioning.new(
        backend: Matter::Network::TestBackend.new,
        features: Matter::Cluster::NetworkCommissioning::Feature::WiFiNetworkInterface
      )
      cmd = Matter::Cluster::NetworkCommissioning::RemoveNetworkRequest.new(
        network_id: "NonExistent".to_slice
      )

      response = cluster.handle_remove_network(cmd, failsafe_armed: true)
      response.networking_status.should eq(Matter::Cluster::NetworkCommissioning::NetworkCommissioningStatus::NetworkIdNotFound)
    end

    it "removes network successfully" do
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

      # Remove network
      remove_cmd = Matter::Cluster::NetworkCommissioning::RemoveNetworkRequest.new(
        network_id: ssid
      )
      response = cluster.handle_remove_network(remove_cmd, failsafe_armed: true)

      response.networking_status.should eq(Matter::Cluster::NetworkCommissioning::NetworkCommissioningStatus::Success)
      response.network_index.should eq(0_u8)
      cluster.networks.should be_empty
    end

    it "maintains relative order of remaining networks after removal" do
      cluster = Matter::Cluster::NetworkCommissioning.new(
        backend: Matter::Network::TestBackend.new,
        features: Matter::Cluster::NetworkCommissioning::Feature::WiFiNetworkInterface,
        max_networks: 4_u8
      )

      # Add three networks
      ["Net1", "Net2", "Net3"].each do |name|
        cmd = Matter::Cluster::NetworkCommissioning::AddOrUpdateWiFiNetworkRequest.new(
          ssid: name.to_slice,
          credentials: "password".to_slice
        )
        cluster.handle_add_or_update_wifi_network(cmd, failsafe_armed: true)
      end

      # Remove middle network
      remove_cmd = Matter::Cluster::NetworkCommissioning::RemoveNetworkRequest.new(
        network_id: "Net2".to_slice
      )
      cluster.handle_remove_network(remove_cmd, failsafe_armed: true)

      cluster.networks.size.should eq(2)
      cluster.networks[0].network_id.should eq("Net1".to_slice)
      cluster.networks[1].network_id.should eq("Net3".to_slice)
    end
  end

  describe "ReorderNetwork command" do
    it "validates request parameters" do
      expect_raises(ArgumentError, "network_id must be 1-32 bytes") do
        Matter::Cluster::NetworkCommissioning::ReorderNetworkRequest.new(
          network_id: Bytes.new(0),
          network_index: 0_u8
        )
      end
    end

    it "requires armed failsafe" do
      cluster = Matter::Cluster::NetworkCommissioning.new
      cmd = Matter::Cluster::NetworkCommissioning::ReorderNetworkRequest.new(
        network_id: "test".to_slice,
        network_index: 0_u8
      )

      response = cluster.handle_reorder_network(cmd, failsafe_armed: false)
      response.networking_status.should eq(Matter::Cluster::NetworkCommissioning::NetworkCommissioningStatus::UnknownError)
    end

    it "returns NetworkIdNotFound for non-existent network" do
      cluster = Matter::Cluster::NetworkCommissioning.new(
        backend: Matter::Network::TestBackend.new,
        features: Matter::Cluster::NetworkCommissioning::Feature::WiFiNetworkInterface
      )
      cmd = Matter::Cluster::NetworkCommissioning::ReorderNetworkRequest.new(
        network_id: "NonExistent".to_slice,
        network_index: 0_u8
      )

      response = cluster.handle_reorder_network(cmd, failsafe_armed: true)
      response.networking_status.should eq(Matter::Cluster::NetworkCommissioning::NetworkCommissioningStatus::NetworkIdNotFound)
    end

    it "returns OutOfRange for invalid network_index" do
      cluster = Matter::Cluster::NetworkCommissioning.new(
        backend: Matter::Network::TestBackend.new,
        features: Matter::Cluster::NetworkCommissioning::Feature::WiFiNetworkInterface
      )

      # Add one network
      add_cmd = Matter::Cluster::NetworkCommissioning::AddOrUpdateWiFiNetworkRequest.new(
        ssid: "Net1".to_slice,
        credentials: "password".to_slice
      )
      cluster.handle_add_or_update_wifi_network(add_cmd, failsafe_armed: true)

      # Try to reorder to index 5 (out of range)
      reorder_cmd = Matter::Cluster::NetworkCommissioning::ReorderNetworkRequest.new(
        network_id: "Net1".to_slice,
        network_index: 5_u8
      )
      response = cluster.handle_reorder_network(reorder_cmd, failsafe_armed: true)

      response.networking_status.should eq(Matter::Cluster::NetworkCommissioning::NetworkCommissioningStatus::OutOfRange)
    end

    it "reorders network successfully" do
      cluster = Matter::Cluster::NetworkCommissioning.new(
        backend: Matter::Network::TestBackend.new,
        features: Matter::Cluster::NetworkCommissioning::Feature::WiFiNetworkInterface,
        max_networks: 4_u8
      )

      # Add three networks
      ["Net1", "Net2", "Net3"].each do |name|
        cmd = Matter::Cluster::NetworkCommissioning::AddOrUpdateWiFiNetworkRequest.new(
          ssid: name.to_slice,
          credentials: "password".to_slice
        )
        cluster.handle_add_or_update_wifi_network(cmd, failsafe_armed: true)
      end

      # Move Net3 to position 0
      reorder_cmd = Matter::Cluster::NetworkCommissioning::ReorderNetworkRequest.new(
        network_id: "Net3".to_slice,
        network_index: 0_u8
      )
      response = cluster.handle_reorder_network(reorder_cmd, failsafe_armed: true)

      response.networking_status.should eq(Matter::Cluster::NetworkCommissioning::NetworkCommissioningStatus::Success)
      response.network_index.should eq(0_u8)

      # Verify new order
      cluster.networks[0].network_id.should eq("Net3".to_slice)
      cluster.networks[1].network_id.should eq("Net1".to_slice)
      cluster.networks[2].network_id.should eq("Net2".to_slice)
    end

    it "maintains relative order of other networks during reorder" do
      cluster = Matter::Cluster::NetworkCommissioning.new(
        backend: Matter::Network::TestBackend.new,
        features: Matter::Cluster::NetworkCommissioning::Feature::WiFiNetworkInterface,
        max_networks: 4_u8
      )

      # Add three networks
      ["Net1", "Net2", "Net3"].each do |name|
        cmd = Matter::Cluster::NetworkCommissioning::AddOrUpdateWiFiNetworkRequest.new(
          ssid: name.to_slice,
          credentials: "password".to_slice
        )
        cluster.handle_add_or_update_wifi_network(cmd, failsafe_armed: true)
      end

      # Move Net1 to position 2
      reorder_cmd = Matter::Cluster::NetworkCommissioning::ReorderNetworkRequest.new(
        network_id: "Net1".to_slice,
        network_index: 2_u8
      )
      cluster.handle_reorder_network(reorder_cmd, failsafe_armed: true)

      # Verify order: Net2, Net3, Net1
      cluster.networks[0].network_id.should eq("Net2".to_slice)
      cluster.networks[1].network_id.should eq("Net3".to_slice)
      cluster.networks[2].network_id.should eq("Net1".to_slice)
    end

    it "allows reordering to same position (no-op)" do
      cluster = Matter::Cluster::NetworkCommissioning.new(
        backend: Matter::Network::TestBackend.new,
        features: Matter::Cluster::NetworkCommissioning::Feature::WiFiNetworkInterface
      )

      # Add two networks
      ["Net1", "Net2"].each do |name|
        cmd = Matter::Cluster::NetworkCommissioning::AddOrUpdateWiFiNetworkRequest.new(
          ssid: name.to_slice,
          credentials: "password".to_slice
        )
        cluster.handle_add_or_update_wifi_network(cmd, failsafe_armed: true)
      end

      # Reorder Net1 to position 0 (same position)
      reorder_cmd = Matter::Cluster::NetworkCommissioning::ReorderNetworkRequest.new(
        network_id: "Net1".to_slice,
        network_index: 0_u8
      )
      response = cluster.handle_reorder_network(reorder_cmd, failsafe_armed: true)

      response.networking_status.should eq(Matter::Cluster::NetworkCommissioning::NetworkCommissioningStatus::Success)
      cluster.networks[0].network_id.should eq("Net1".to_slice)
    end
  end
end
