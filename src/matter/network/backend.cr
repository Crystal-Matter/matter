require "./credentials"
require "../storage/document"

module Matter
  module Network
    # WiFi Network Info for adding/updating networks
    struct WiFiNetworkInfo
      getter ssid : Bytes
      getter credentials : WiFiCredentials

      def initialize(@ssid : Bytes, credentials : Bytes)
        @credentials = WiFiCredentials.new(credentials)
      end

      # Get SSID as string
      def ssid_string : String
        String.new(@ssid)
      end
    end

    # Abstract base class for platform-specific network operations
    #
    # Implementations of this class provide the actual platform-specific code
    # for scanning, connecting, and managing WiFi and Thread networks.
    #
    # The NetworkCommissioning delegates to this backend for all
    # actual network operations.
    abstract class Backend
      enum InterfaceEnabledResult
        Success
        Unsupported
        Failure
      end

      # Platforms that cannot disable their interface leave this default in
      # place. A supported implementation must apply the change before success
      # and leave its state unchanged when returning Unsupported or Failure.
      def set_interface_enabled(enabled : Bool) : InterfaceEnabledResult
        enabled ? InterfaceEnabledResult::Success : InterfaceEnabledResult::Unsupported
      end

      def interface_enabled? : Bool
        true
      end

      # Return a complete, independent checkpoint of mutable network state.
      # Nil means tentative network changes are unsupported by this backend.
      def checkpoint_configuration : Storage::Document?
        nil
      end

      # Restore the checkpoint after fail-safe expiry. This must also undo a
      # previous successful commit if a later commissioning persistence step
      # failed. Implementations must restore credentials and connection state,
      # including their durable copy, and return false on failure.
      def restore_configuration(snapshot : Storage::Document) : Bool
        false
      end

      # Make all tentative changes durable on CommissioningComplete.
      def commit_configuration : Bool
        false
      end

      # Scan for available WiFi networks
      #
      # @param ssid Optional SSID string for directed scan (nil for broadcast scan)
      # @return Array of discovered WiFi networks
      abstract def scan_wifi(ssid : String?) : Array(Cluster::NetworkCommissioning::WiFiInterfaceScanResult)

      # Scan for available Thread networks
      #
      # @return Array of discovered Thread networks
      abstract def scan_thread : Array(Cluster::NetworkCommissioning::ThreadInterfaceScanResult)

      # Add or update a WiFi network configuration
      #
      # The WiFiNetworkInfo contains the SSID and parsed credentials with
      # inferred security type, making it easy to configure the network.
      #
      # @param network_info Parsed WiFi network information
      # @return True if successful
      abstract def add_wifi_network(network_info : WiFiNetworkInfo) : Bool

      # Add or update a Thread network configuration
      #
      # The ThreadCredentials contain the operational dataset and parsed
      # key parameters like Extended PAN ID, network name, etc.
      #
      # @param credentials Parsed Thread network credentials
      # @return True if successful
      abstract def add_thread_network(credentials : ThreadCredentials) : Bool

      # Remove a network configuration
      #
      # @param network_id Network identifier (SSID for WiFi, XPAN for Thread)
      # @return True if successful
      abstract def remove_network(network_id : Bytes) : Bool

      # Connect to a configured network
      #
      # @param network_id Network identifier (SSID for WiFi, XPAN for Thread)
      # @return Tuple of (success, error_value)
      #         error_value is platform-specific error code (e.g., 802.11 status code for WiFi)
      abstract def connect_network(network_id : Bytes) : {Bool, Int32?}

      # Disconnect from current network
      abstract def disconnect_network : Nil

      # Check if a network is currently connected
      #
      # @param network_id Network identifier (SSID for WiFi, XPAN for Thread)
      # @return True if connected
      abstract def connected?(network_id : Bytes) : Bool
    end
  end
end
