require "../../src/matter/network/backend"

module Matter
  module Network
    # Test implementation of NetworkBackend for testing
    #
    # This provides simulated network operations that return
    # predictable test data without requiring actual network interfaces.
    class TestBackend < Backend
      # Storage for configured networks
      property configured_networks : Hash(Bytes, Bytes) = {} of Bytes => Bytes
      property connected_network_id : Bytes? = nil

      def checkpoint_configuration : Storage::Document?
        entries = [] of Storage::Type
        @configured_networks.each do |id, credentials|
          entries << Storage::Document{"id" => id.dup, "credentials" => credentials.dup}
        end
        Storage::Document{"entries" => entries, "connected" => @connected_network_id.try(&.dup)}
      end

      def restore_configuration(snapshot : Storage::Document) : Bool
        entries = snapshot["entries"].as(Array(Storage::Type))
        restored = {} of Bytes => Bytes
        entries.each do |entry|
          document = entry.as(Storage::Document)
          restored[document["id"].as(Bytes).dup] = document["credentials"].as(Bytes).dup
        end
        @configured_networks = restored
        @connected_network_id = snapshot["connected"].as(Bytes?).try(&.dup)
        true
      end

      def commit_configuration : Bool
        true
      end

      def scan_wifi(ssid : String?) : Array(Cluster::NetworkCommissioning::WiFiInterfaceScanResult)
        results = [] of Cluster::NetworkCommissioning::WiFiInterfaceScanResult

        if ssid
          # Directed scan - return single result if found
          results << Cluster::NetworkCommissioning::WiFiInterfaceScanResult.new(
            security: Cluster::NetworkCommissioning::WiFiSecurityType::WPA2,
            ssid: ssid.to_slice,
            bssid: Bytes[0x00, 0x11, 0x22, 0x33, 0x44, 0x55],
            channel: 6_u16,
            wifi_band: Cluster::NetworkCommissioning::WiFiBandEnum::Band2G4,
            rssi: -50_i8
          )
        else
          # Full scan - return multiple results
          results << Cluster::NetworkCommissioning::WiFiInterfaceScanResult.new(
            security: Cluster::NetworkCommissioning::WiFiSecurityType::WPA3,
            ssid: "TestNetwork1".to_slice,
            bssid: Bytes[0x00, 0x11, 0x22, 0x33, 0x44, 0x55],
            channel: 6_u16,
            wifi_band: Cluster::NetworkCommissioning::WiFiBandEnum::Band2G4,
            rssi: -45_i8
          )

          results << Cluster::NetworkCommissioning::WiFiInterfaceScanResult.new(
            security: Cluster::NetworkCommissioning::WiFiSecurityType::WPA2,
            ssid: "TestNetwork2".to_slice,
            bssid: Bytes[0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF],
            channel: 11_u16,
            wifi_band: Cluster::NetworkCommissioning::WiFiBandEnum::Band2G4,
            rssi: -60_i8
          )
        end

        # Sort by RSSI (strongest first)
        results.sort_by! { |result| -(result.rssi || -100) }
        results
      end

      def scan_thread : Array(Cluster::NetworkCommissioning::ThreadInterfaceScanResult)
        results = [] of Cluster::NetworkCommissioning::ThreadInterfaceScanResult

        results << Cluster::NetworkCommissioning::ThreadInterfaceScanResult.new(
          pan_id: 0x1234_u16,
          extended_pan_id: 0x1122334455667788_u64,
          network_name: "TestThread1",
          channel: 15_u16,
          version: 4_u8,
          rssi: -50_i8,
          lqi: 200_u8
        )

        results << Cluster::NetworkCommissioning::ThreadInterfaceScanResult.new(
          pan_id: 0x5678_u16,
          extended_pan_id: 0x8877665544332211_u64,
          network_name: "TestThread2",
          channel: 20_u16,
          version: 4_u8,
          rssi: -65_i8,
          lqi: 150_u8
        )

        # Sort by LQI (highest first)
        results.sort_by! { |result| -(result.lqi || 0_u8).to_i32 }
        results
      end

      def add_wifi_network(network_info : WiFiNetworkInfo) : Bool
        # Store using parsed credentials
        configured_networks[network_info.ssid] = network_info.credentials.raw
        true
      end

      def add_thread_network(credentials : ThreadCredentials) : Bool
        # Store using network ID (XPAN) as key
        configured_networks[credentials.network_id] = credentials.raw
        true
      end

      def remove_network(network_id : Bytes) : Bool
        return false unless configured_networks.has_key?(network_id)
        configured_networks.delete(network_id)
        @connected_network_id = nil if @connected_network_id == network_id
        true
      end

      def connect_network(network_id : Bytes) : {Bool, Int32?}
        return {false, nil} unless configured_networks.has_key?(network_id)

        # Disconnect any existing connection
        @connected_network_id = network_id

        # Return success with no error
        {true, nil}
      end

      def disconnect_network : Nil
        @connected_network_id = nil
      end

      def connected?(network_id : Bytes) : Bool
        @connected_network_id == network_id
      end
    end
  end
end
