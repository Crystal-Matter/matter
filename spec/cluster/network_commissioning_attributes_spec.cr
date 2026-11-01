require "../spec_helper"
require "../../src/matter/cluster/network_commissioning"
require "tlv"

describe Matter::Cluster::NetworkCommissioning do
  describe "initialization" do
    it "creates WiFi network commissioning cluster" do
      cluster = build(Matter::Cluster::NetworkCommissioning,
        network_type: Matter::Cluster::NetworkCommissioning::NetworkType::WiFi,
        feature_map: Matter::Cluster::NetworkCommissioning::Feature::WiFiNetworkInterface
      )

      cluster.cluster_id.id.should eq(0x0031_u32)
      cluster.network_type.should eq(Matter::Cluster::NetworkCommissioning::NetworkType::WiFi)
      cluster.max_networks.should eq(1_u8)
      cluster.interface_enabled?.should be_true
      cluster.name.should eq("NetworkCommissioning")
    end

    it "creates Thread network commissioning cluster" do
      cluster = build(Matter::Cluster::NetworkCommissioning,
        network_type: Matter::Cluster::NetworkCommissioning::NetworkType::Thread,
        feature_map: Matter::Cluster::NetworkCommissioning::Feature::ThreadNetworkInterface
      )

      cluster.network_type.should eq(Matter::Cluster::NetworkCommissioning::NetworkType::Thread)
    end

    it "creates Ethernet network commissioning cluster" do
      cluster = build(Matter::Cluster::NetworkCommissioning,
        network_type: Matter::Cluster::NetworkCommissioning::NetworkType::Ethernet,
        feature_map: Matter::Cluster::NetworkCommissioning::Feature::EthernetNetworkInterface
      )

      cluster.network_type.should eq(Matter::Cluster::NetworkCommissioning::NetworkType::Ethernet)
    end

    it "creates cluster with custom max networks" do
      cluster = Matter::Cluster::NetworkCommissioning.new(max_networks: 8_u8)
      cluster.max_networks.should eq(8_u8)
    end

    it "validates max_networks >= 1" do
      expect_raises(ArgumentError, "max_networks must be >= 1") do
        Matter::Cluster::NetworkCommissioning.new(max_networks: 0_u8)
      end
    end

    it "initializes WiFi-specific attributes when WiFi feature enabled" do
      cluster = Matter::Cluster::NetworkCommissioning.new(
        features: Matter::Cluster::NetworkCommissioning::Feature::WiFiNetworkInterface
      )

      wifi_bands = cluster.supported_wifi_bands
      wifi_bands.should_not be_nil
      wifi_bands.as(Array).should contain(Matter::Cluster::NetworkCommissioning::WiFiBandEnum::Band2G4)
    end

    it "initializes Thread-specific attributes when Thread feature enabled" do
      cluster = Matter::Cluster::NetworkCommissioning.new(
        features: Matter::Cluster::NetworkCommissioning::Feature::ThreadNetworkInterface
      )

      cluster.supported_thread_features.should_not be_nil
      cluster.thread_version.should eq(4_u16)
    end
  end

  describe "attributes" do
    it "reads MaxNetworks attribute" do
      cluster = build(Matter::Cluster::NetworkCommissioning,
        network_type: Matter::Cluster::NetworkCommissioning::NetworkType::WiFi
      )

      read(cluster, Matter::Cluster::NetworkCommissioning::ATTR_MAX_NETWORKS).should eq(1_u8)
    end

    it "reads ScanMaxTimeSeconds attribute" do
      cluster = build(Matter::Cluster::NetworkCommissioning,
        network_type: Matter::Cluster::NetworkCommissioning::NetworkType::WiFi
      )

      read(cluster, Matter::Cluster::NetworkCommissioning::ATTR_SCAN_MAX_TIME_SECONDS).should eq(30_u8)
    end

    it "reads ConnectMaxTimeSeconds attribute" do
      cluster = build(Matter::Cluster::NetworkCommissioning,
        network_type: Matter::Cluster::NetworkCommissioning::NetworkType::WiFi
      )

      read(cluster, Matter::Cluster::NetworkCommissioning::ATTR_CONNECT_MAX_TIME_SECONDS).should eq(60_u8)
    end

    it "reads InterfaceEnabled attribute" do
      cluster = build(Matter::Cluster::NetworkCommissioning,
        network_type: Matter::Cluster::NetworkCommissioning::NetworkType::WiFi
      )

      read(cluster, Matter::Cluster::NetworkCommissioning::ATTR_INTERFACE_ENABLED).should be_true
    end

    it "writes InterfaceEnabled attribute" do
      backend = Matter::Network::TestBackend.new
      backend.allow_disable = true
      cluster = build(Matter::Cluster::NetworkCommissioning,
        network_type: Matter::Cluster::NetworkCommissioning::NetworkType::WiFi,
        backend: backend
      )

      status = write(cluster,
        Matter::Cluster::NetworkCommissioning::ATTR_INTERFACE_ENABLED,
        false
      )

      status.status.should eq(Matter::InteractionModel::StatusCode::Success)
      cluster.interface_enabled?.should be_false
      backend.enabled.should be_false
    end

    it "reads LastNetworkingStatus when nil" do
      cluster = build(Matter::Cluster::NetworkCommissioning,
        network_type: Matter::Cluster::NetworkCommissioning::NetworkType::WiFi
      )

      # TLV null encoding - check it's a null type
      read_tlv(cluster, Matter::Cluster::NetworkCommissioning::ATTR_LAST_NETWORKING_STATUS).as_nil.should be_nil
    end

    it "returns status for unsupported attribute write" do
      cluster = build(Matter::Cluster::NetworkCommissioning,
        network_type: Matter::Cluster::NetworkCommissioning::NetworkType::WiFi
      )

      status = write(cluster,
        Matter::Cluster::NetworkCommissioning::ATTR_MAX_NETWORKS,
        5_u8
      )

      status.status.should eq(Matter::InteractionModel::StatusCode::UnsupportedWrite)
    end
  end

  it "allows setting interface_enabled" do
    backend = Matter::Network::TestBackend.new
    backend.allow_disable = true
    cluster = Matter::Cluster::NetworkCommissioning.new(backend: backend)

    cluster.interface_enabled = false
    cluster.interface_enabled?.should be_false
    backend.enabled.should be_false

    cluster.interface_enabled = true
    cluster.interface_enabled?.should be_true
    backend.enabled.should be_true
  end

  describe "metadata" do
    it "provides attribute metadata" do
      cluster = build(Matter::Cluster::NetworkCommissioning,
        network_type: Matter::Cluster::NetworkCommissioning::NetworkType::WiFi
      )

      attributes = cluster.attributes
      attributes.should_not be_empty
      attributes.size.should be >= 4

      max_networks = attributes.find { |attr| attr.id.id == Matter::Cluster::NetworkCommissioning::ATTR_MAX_NETWORKS }
      max_networks.should_not be_nil
      max_networks_attr = max_networks.as(Matter::Cluster::AttributeMetadata)
      max_networks_attr.name.should eq("maxNetworks")
      max_networks_attr.writable?.should be_false
    end

    it "provides command metadata" do
      cluster = build(Matter::Cluster::NetworkCommissioning,
        network_type: Matter::Cluster::NetworkCommissioning::NetworkType::WiFi
      )

      commands = cluster.commands
      commands.should_not be_empty
      commands.size.should be >= 5

      scan_command = commands.find { |cmd| cmd.id.id == Matter::Cluster::NetworkCommissioning::CMD_SCAN_NETWORKS }
      scan_command.should_not be_nil
      scan_command.as(Matter::Cluster::CommandMetadata).name.should eq("scanNetworks")
    end
  end

  describe "network info" do
    it "creates network info" do
      ssid = "MyNetwork".to_slice
      info = Matter::Cluster::NetworkCommissioning::NetworkInfo.new(ssid, false)

      info.network_id.should eq(ssid)
      info.connected?.should be_false
    end

    it "tracks connected status" do
      ssid = "MyNetwork".to_slice
      info = Matter::Cluster::NetworkCommissioning::NetworkInfo.new(ssid, true)

      info.connected?.should be_true
      info.connected = false
      info.connected?.should be_false
    end
  end

  describe "WiFi scan results" do
    it "creates WiFi scan result" do
      result = Matter::Cluster::NetworkCommissioning::WiFiInterfaceScanResult.new(
        security: Matter::Cluster::NetworkCommissioning::WiFiSecurityType::WPA2,
        ssid: "TestNetwork".to_slice,
        bssid: Bytes[0x01, 0x02, 0x03, 0x04, 0x05, 0x06],
        channel: 6_u16,
        wifi_band: Matter::Cluster::NetworkCommissioning::WiFiBandEnum::Band3G65,
        rssi: -45_i8
      )

      result.security.should eq(Matter::Cluster::NetworkCommissioning::WiFiSecurityType::WPA2)
      result.ssid.should eq("TestNetwork".to_slice)
      result.channel.should eq(6_u16)
      result.rssi.should eq(-45_i8)
    end
  end

  describe "Thread scan results" do
    it "creates Thread scan result" do
      result = Matter::Cluster::NetworkCommissioning::ThreadInterfaceScanResult.new(
        pan_id: 0x1234_u16,
        extended_pan_id: 0x0102030405060708_u64,
        network_name: "TestThread",
        channel: 15_u16,
        version: 2_u8,
        extended_address: Bytes[0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88],
        rssi: -50_i8,
        lqi: 200_u8
      )

      result.pan_id.should eq(0x1234_u16)
      result.network_name.should eq("TestThread")
      result.channel.should eq(15_u16)
      result.rssi.should eq(-50_i8)
    end
  end

  describe "network types" do
    it "defines WiFi network type" do
      Matter::Cluster::NetworkCommissioning::NetworkType::WiFi.value.should eq(0_u8)
    end

    it "defines Thread network type" do
      Matter::Cluster::NetworkCommissioning::NetworkType::Thread.value.should eq(1_u8)
    end

    it "defines Ethernet network type" do
      Matter::Cluster::NetworkCommissioning::NetworkType::Ethernet.value.should eq(2_u8)
    end
  end

  describe "WiFi security types" do
    it "defines security types" do
      Matter::Cluster::NetworkCommissioning::WiFiSecurityType::Unencrypted.value.should eq(0_u8)
      Matter::Cluster::NetworkCommissioning::WiFiSecurityType::WEP.value.should eq(1_u8)
      Matter::Cluster::NetworkCommissioning::WiFiSecurityType::WPA.value.should eq(2_u8)
      Matter::Cluster::NetworkCommissioning::WiFiSecurityType::WPA2.value.should eq(3_u8)
      Matter::Cluster::NetworkCommissioning::WiFiSecurityType::WPA3.value.should eq(4_u8)
    end
  end

  describe "status codes" do
    it "defines status codes" do
      Matter::Cluster::NetworkCommissioning::NetworkCommissioningStatus::Success.value.should eq(0_u8)
      Matter::Cluster::NetworkCommissioning::NetworkCommissioningStatus::NetworkIdNotFound.value.should eq(3_u8)
      Matter::Cluster::NetworkCommissioning::NetworkCommissioningStatus::AuthFailure.value.should eq(7_u8)
    end
  end

  describe "data structure validations" do
    it "validates NetworkInfo network_id length" do
      expect_raises(ArgumentError, "network_id must be 1-32 bytes") do
        Matter::Cluster::NetworkCommissioning::NetworkInfo.new(
          network_id: Bytes.new(0),
          connected: false
        )
      end

      expect_raises(ArgumentError, "network_id must be 1-32 bytes") do
        Matter::Cluster::NetworkCommissioning::NetworkInfo.new(
          network_id: Bytes.new(33),
          connected: false
        )
      end
    end

    it "validates WiFiInterfaceScanResult ssid and bssid lengths" do
      expect_raises(ArgumentError, "ssid must be max 32 bytes") do
        Matter::Cluster::NetworkCommissioning::WiFiInterfaceScanResult.new(
          ssid: Bytes.new(33)
        )
      end

      expect_raises(ArgumentError, "bssid must be exactly 6 bytes") do
        Matter::Cluster::NetworkCommissioning::WiFiInterfaceScanResult.new(
          bssid: Bytes.new(5)
        )
      end
    end

    it "validates ThreadInterfaceScanResult network_name and pan_id" do
      expect_raises(ArgumentError, "network_name must be 1-16 chars") do
        Matter::Cluster::NetworkCommissioning::ThreadInterfaceScanResult.new(
          network_name: ""
        )
      end

      expect_raises(ArgumentError, "network_name must be 1-16 chars") do
        Matter::Cluster::NetworkCommissioning::ThreadInterfaceScanResult.new(
          network_name: "A" * 17
        )
      end

      expect_raises(ArgumentError, "pan_id must be max 65534") do
        Matter::Cluster::NetworkCommissioning::ThreadInterfaceScanResult.new(
          pan_id: 65535_u16
        )
      end
    end

    it "validates response debug_text length" do
      expect_raises(ArgumentError, "debug_text must be max 512 chars") do
        Matter::Cluster::NetworkCommissioning::ScanNetworksResponse.new(
          networking_status: Matter::Cluster::NetworkCommissioning::NetworkCommissioningStatus::Success,
          debug_text: "A" * 513
        )
      end
    end
  end
end
