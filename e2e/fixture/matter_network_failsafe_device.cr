require "../../examples/support/console"
require "../../examples/support/main"

# Synthetic Wi-Fi backend for exercising fail-safe rollback through chip-tool.
# Its sidecar contains only test SSIDs (as hex) and a restore counter, never
# credentials. The device still communicates over Docker's wired IP network.
module MatterNetworkFailsafeFixture
  class MemoryBackend < Matter::Network::Backend
    STATE_PATH = "/e2e/logs/matter_network_failsafe.state"

    @configured_networks = {} of Bytes => Bytes
    @connected_network_id : Bytes? = nil
    @restores = 0

    def initialize
      publish_state
    end

    def checkpoint_configuration : Matter::Storage::Document?
      entries = [] of Matter::Storage::Type
      @configured_networks.each do |id, credentials|
        entries << Matter::Storage::Document{"id" => id.dup, "credentials" => credentials.dup}
      end
      Matter::Storage::Document{"entries" => entries, "connected" => @connected_network_id.try(&.dup)}
    end

    def restore_configuration(snapshot : Matter::Storage::Document) : Bool
      restored = {} of Bytes => Bytes
      snapshot["entries"].as(Array(Matter::Storage::Type)).each do |entry|
        document = entry.as(Matter::Storage::Document)
        restored[document["id"].as(Bytes).dup] = document["credentials"].as(Bytes).dup
      end
      @configured_networks = restored
      @connected_network_id = snapshot["connected"].as(Bytes?).try(&.dup)
      @restores += 1
      publish_state
      true
    end

    def commit_configuration : Bool
      publish_state
      true
    end

    def scan_wifi(ssid : String?) : Array(Matter::Cluster::NetworkCommissioning::WiFiInterfaceScanResult)
      [] of Matter::Cluster::NetworkCommissioning::WiFiInterfaceScanResult
    end

    def scan_thread : Array(Matter::Cluster::NetworkCommissioning::ThreadInterfaceScanResult)
      [] of Matter::Cluster::NetworkCommissioning::ThreadInterfaceScanResult
    end

    def add_wifi_network(network_info : Matter::Network::WiFiNetworkInfo) : Bool
      @configured_networks[network_info.ssid.dup] = network_info.credentials.raw.dup
      publish_state
      true
    end

    def add_thread_network(credentials : Matter::Network::ThreadCredentials) : Bool
      false
    end

    def remove_network(network_id : Bytes) : Bool
      return false unless @configured_networks.has_key?(network_id)
      @configured_networks.delete(network_id)
      @connected_network_id = nil if @connected_network_id == network_id
      publish_state
      true
    end

    def connect_network(network_id : Bytes) : {Bool, Int32?}
      return {false, nil} unless @configured_networks.has_key?(network_id)
      @connected_network_id = network_id.dup
      {true, nil}
    end

    def disconnect_network : Nil
      @connected_network_id = nil
    end

    def connected?(network_id : Bytes) : Bool
      @connected_network_id == network_id
    end

    private def publish_state : Nil
      ids = @configured_networks.keys.map(&.hexstring).sort!.join(",")
      File.write(STATE_PATH, "restores=#{@restores}\nnetwork_ids=#{ids}\n")
    end
  end

  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Synthetic Network Rollback",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: rand(0x0001_u16..0xFFFF_u16),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_network_failsafe_storage.yml"
    network :wifi

    endpoint 1, device_type: Matter::DeviceType::AGGREGATOR
  end
end

Examples.main("Synthetic Network Rollback") do
  MatterNetworkFailsafeFixture::Device.new(network_backend: MatterNetworkFailsafeFixture::MemoryBackend.new)
end
