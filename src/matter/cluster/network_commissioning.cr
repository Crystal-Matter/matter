require "./cluster"
require "./network_commissioning/types"
require "../commissioning"
require "../network/backend"
require "log"
require "base64"
require "json"

module Matter
  module Cluster
    # Network Commissioning Cluster (0x0031)
    #
    # This cluster is used to configure network interfaces on Matter devices.
    # It supports WiFi, Thread, and Ethernet network management.
    #
    # Matter Specification: Core 1.4 § 11.8 - Network Commissioning Cluster
    #
    # Commands:
    # - ScanNetworks (0x00): Scan for available networks
    # - AddOrUpdateWiFiNetwork (0x02): Add or update WiFi network configuration
    # - AddOrUpdateThreadNetwork (0x03): Add or update Thread network configuration
    # - RemoveNetwork (0x04): Remove a network from the Networks list
    # - ConnectNetwork (0x06): Connect to a configured network
    # - ReorderNetwork (0x08): Reorder network priority
    #
    # Attributes:
    # - MaxNetworks (0x00): Maximum number of networks
    # - Networks (0x01): List of configured networks
    # - ScanMaxTimeSeconds (0x02): Maximum scan time
    # - ConnectMaxTimeSeconds (0x03): Maximum connect time
    # - InterfaceEnabled (0x04): Network interface enabled status
    # - LastNetworkingStatus (0x05): Status of last operation
    # - LastNetworkID (0x06): Network ID of last operation
    # - LastConnectErrorValue (0x07): Error value from last connect
    class NetworkCommissioning < Base
      include Commissioning::NetworkStateStore

      Log = ::Log.for("matter.cluster.network_commissioning")
      cluster 0x0031, revision: 2

      # Network Types
      enum NetworkType : UInt8
        WiFi     = 0x00
        Thread   = 0x01
        Ethernet = 0x02
      end

      feature :wi_fi_network_interface, bit: 0    # WI - WiFi support
      feature :thread_network_interface, bit: 1   # TH - Thread support
      feature :ethernet_network_interface, bit: 2 # ET - Ethernet support

      DEFAULT_MAX_NETWORKS             =  1_u8
      DEFAULT_SCAN_MAX_TIME_SECONDS    = 30_u8
      DEFAULT_CONNECT_MAX_TIME_SECONDS = 60_u8
      THREAD_VERSION_1_3               = 4_u16

      # NetworkCommissioningStatus Enum
      # Status codes returned by network commissioning commands
      enum NetworkCommissioningStatus : UInt8
        Success                =  0 # Operation successful
        OutOfRange             =  1 # Invalid network ID (empty, too long, invalid format)
        BoundsExceeded         =  2 # Would exceed MaxNetworks limit
        NetworkIdNotFound      =  3 # Network ID not found in Networks
        DuplicateNetworkId     =  4 # Network ID already exists
        NetworkNotFound        =  5 # Network not found during scan/connection
        RegulatoryError        =  6 # Regulatory domain/band mismatch
        AuthFailure            =  7 # Authentication failure (WiFi)
        UnsupportedSecurity    =  8 # Unsupported security mode
        OtherConnectionFailure =  9 # Other WiFi association failure
        Ipv6Failed             = 10 # IPv6 address generation failed
        IpBindFailed           = 11 # WiFi-IP interface binding failed
        UnknownError           = 12 # Unknown internal error
      end

      # WiFiSecurityType
      # WiFi security type enumeration
      enum WiFiSecurityType : UInt8
        Unencrypted = 0 # Open network
        WEP         = 1 # WEP security
        WPA         = 2 # WPA-Personal
        WPA2        = 3 # WPA2-Personal
        WPA3        = 4 # WPA3-Personal
      end

      # WiFiBandEnum
      # Supported WiFi frequency bands
      enum WiFiBandEnum : UInt8
        Band2G4  = 0 # 2.4GHz 802.11b/g/n/ax
        Band3G65 = 1 # 3.65GHz 802.11y
        Band5G   = 2 # 5GHz 802.11a/n/ac/ax
        Band6G   = 3 # 6GHz 802.11ax (WiFi 6E)
        Band60G  = 4 # 60GHz 802.11ad/ay
        Band1G   = 5 # Sub-1GHz 802.11ah
      end

      # ThreadCapabilitiesBitmap
      # Bitmask of Thread device capabilities
      @[Flags]
      enum ThreadCapabilitiesBitmap : UInt16
        IsBorderRouterCapable                = 0x01 # Bit 0
        IsRouterCapable                      = 0x02 # Bit 1
        IsSleepyEndDeviceCapable             = 0x04 # Bit 2
        IsFullThreadDevice                   = 0x08 # Bit 3
        IsSynchronizedSleepyEndDeviceCapable = 0x10 # Bit 4
      end

      # NetworkInfoStruct - Represents a configured network
      struct NetworkInfo
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property network_id : Bytes # 1-32 bytes (SSID or XPAN ID)

        @[TLV::Field(tag: 1)]
        property? connected : Bool # Current connection status

        def initialize(@network_id : Bytes, @connected : Bool)
          raise ArgumentError.new("network_id must be 1-32 bytes") unless network_id.size.in?(1..32)
        end
      end

      # WiFiInterfaceScanResult - Result from WiFi network scan
      struct WiFiInterfaceScanResult
        property security : WiFiSecurityType?
        property ssid : Bytes?  # Max 32 bytes
        property bssid : Bytes? # Exactly 6 bytes (MAC address)
        property channel : UInt16?
        property wifi_band : WiFiBandEnum?
        property rssi : Int8? # dBm

        def initialize(
          @security : WiFiSecurityType? = nil,
          @ssid : Bytes? = nil,
          @bssid : Bytes? = nil,
          @channel : UInt16? = nil,
          @wifi_band : WiFiBandEnum? = nil,
          @rssi : Int8? = nil,
        )
          raise ArgumentError.new("ssid must be max 32 bytes") if ssid && ssid.size > 32
          raise ArgumentError.new("bssid must be exactly 6 bytes") if bssid && bssid.size != 6
        end
      end

      # ThreadInterfaceScanResult - Result from Thread network scan
      struct ThreadInterfaceScanResult
        property pan_id : UInt16?          # Max 65534
        property extended_pan_id : UInt64? # XPAN ID
        property network_name : String?    # 1-16 chars
        property channel : UInt16?
        property version : UInt8?          # Thread version
        property extended_address : Bytes? # IEEE 802.15.4
        property rssi : Int8?              # dBm
        property lqi : UInt8?              # Link Quality Indicator

        def initialize(
          @pan_id : UInt16? = nil,
          @extended_pan_id : UInt64? = nil,
          @network_name : String? = nil,
          @channel : UInt16? = nil,
          @version : UInt8? = nil,
          @extended_address : Bytes? = nil,
          @rssi : Int8? = nil,
          @lqi : UInt8? = nil,
        )
          raise ArgumentError.new("network_name must be 1-16 chars") if network_name && !network_name.size.in?(1..16)
          raise ArgumentError.new("pan_id must be max 65534") if pan_id && pan_id > 65534
        end
      end

      # ScanNetworks command (0x00)
      struct ScanNetworksRequest
        property ssid : Bytes? # 1-32 bytes, optional directed scan
        property breadcrumb : UInt64?

        def initialize(@ssid : Bytes? = nil, @breadcrumb : UInt64? = nil)
          raise ArgumentError.new("ssid must be 1-32 bytes") if ssid && !ssid.size.in?(1..32)
        end
      end

      struct ScanNetworksResponse
        property networking_status : NetworkCommissioningStatus
        property debug_text : String? # 0-512 chars
        property wifi_scan_results : Array(WiFiInterfaceScanResult)?
        property thread_scan_results : Array(ThreadInterfaceScanResult)?

        def initialize(
          @networking_status : NetworkCommissioningStatus,
          @debug_text : String? = nil,
          @wifi_scan_results : Array(WiFiInterfaceScanResult)? = nil,
          @thread_scan_results : Array(ThreadInterfaceScanResult)? = nil,
        )
          raise ArgumentError.new("debug_text must be max 512 chars") if debug_text && debug_text.size > 512
        end
      end

      # AddOrUpdateWiFiNetwork command (0x02)
      struct AddOrUpdateWiFiNetworkRequest
        property ssid : Bytes        # Max 32 bytes
        property credentials : Bytes # Max 64 bytes
        property breadcrumb : UInt64?

        def initialize(@ssid : Bytes, @credentials : Bytes, @breadcrumb : UInt64? = nil)
          raise ArgumentError.new("ssid must be max 32 bytes") if ssid.size > 32
          raise ArgumentError.new("credentials must be max 64 bytes") if credentials.size > 64
        end
      end

      # AddOrUpdateThreadNetwork command (0x03)
      struct AddOrUpdateThreadNetworkRequest
        property operational_dataset : Bytes # Max 254 bytes
        property breadcrumb : UInt64?

        def initialize(@operational_dataset : Bytes, @breadcrumb : UInt64? = nil)
          raise ArgumentError.new("operational_dataset must be max 254 bytes") if operational_dataset.size > 254
        end
      end

      # NetworkConfigResponse - Generic response for Add/Update/Remove/Reorder
      struct NetworkConfigResponse
        property networking_status : NetworkCommissioningStatus
        property debug_text : String? # 0-512 chars
        property network_index : UInt8?

        def initialize(
          @networking_status : NetworkCommissioningStatus,
          @debug_text : String? = nil,
          @network_index : UInt8? = nil,
        )
          raise ArgumentError.new("debug_text must be max 512 chars") if debug_text && debug_text.size > 512
        end
      end

      # RemoveNetwork command (0x04)
      struct RemoveNetworkRequest
        property network_id : Bytes # 1-32 bytes
        property breadcrumb : UInt64?

        def initialize(@network_id : Bytes, @breadcrumb : UInt64? = nil)
          raise ArgumentError.new("network_id must be 1-32 bytes") unless network_id.size.in?(1..32)
        end
      end

      # ConnectNetwork command (0x06)
      struct ConnectNetworkRequest
        property network_id : Bytes # 1-32 bytes
        property breadcrumb : UInt64?

        def initialize(@network_id : Bytes, @breadcrumb : UInt64? = nil)
          raise ArgumentError.new("network_id must be 1-32 bytes") unless network_id.size.in?(1..32)
        end
      end

      struct ConnectNetworkResponse
        property networking_status : NetworkCommissioningStatus
        property debug_text : String? # 0-512 chars
        property error_value : Int32? # WiFi 802.11 Status Code or platform-specific

        def initialize(
          @networking_status : NetworkCommissioningStatus,
          @debug_text : String? = nil,
          @error_value : Int32? = nil,
        )
          raise ArgumentError.new("debug_text must be max 512 chars") if debug_text && debug_text.size > 512
        end
      end

      # ReorderNetwork command (0x08)
      struct ReorderNetworkRequest
        property network_id : Bytes    # 1-32 bytes
        property network_index : UInt8 # Desired position (0-based)
        property breadcrumb : UInt64?

        def initialize(@network_id : Bytes, @network_index : UInt8, @breadcrumb : UInt64? = nil)
          raise ArgumentError.new("network_id must be 1-32 bytes") unless network_id.size.in?(1..32)
        end
      end

      attribute 0x0000, :max_networks, UInt8, default: DEFAULT_MAX_NETWORKS, fixed: true, read_access: :administer
      attribute 0x0001, :networks, Array(NetworkInfo), default: [] of NetworkInfo, read_access: :administer
      # Elements shared by the wireless interface types
      ANY_WIRELESS_INTERFACE = [:wi_fi_network_interface, :thread_network_interface]

      attribute 0x0002, :scan_max_time_seconds, UInt8, default: DEFAULT_SCAN_MAX_TIME_SECONDS, fixed: true, requires: ANY_WIRELESS_INTERFACE
      attribute 0x0003, :connect_max_time_seconds, UInt8, default: DEFAULT_CONNECT_MAX_TIME_SECONDS, fixed: true, requires: ANY_WIRELESS_INTERFACE
      # Persisted by `restore_network_state`, not by the DSL
      attribute 0x0004, :interface_enabled, Bool, default: true, writable: true, persist: false, write_access: :administer
      attribute 0x0005, :last_networking_status, NetworkCommissioningStatus, nullable: true, read_access: :administer
      attribute 0x0006, :last_network_id, Bytes, nullable: true, read_access: :administer
      attribute 0x0007, :last_connect_error_value, Int32, nullable: true, read_access: :administer
      attribute 0x0008, :supported_wifi_bands, Array(WiFiBandEnum), default: [] of WiFiBandEnum, fixed: true, requires: :wi_fi_network_interface
      attribute 0x0009, :supported_thread_features, ThreadCapabilitiesBitmap, default: ThreadCapabilitiesBitmap::None, fixed: true, requires: :thread_network_interface
      attribute 0x000A, :thread_version, UInt16, default: THREAD_VERSION_1_3, fixed: true, requires: :thread_network_interface

      command 0x00, :scan_networks, request: Tlv::ScanAvailableNetworksRequest, response: Tlv::ScanNetworksResponse, response_id: 0x01, access: :administer, requires: ANY_WIRELESS_INTERFACE
      command 0x02, :add_or_update_wifi_network, request: Tlv::AddOrUpdateWiFiNetworkRequest, response: Tlv::NetworkConfigurationResponse, response_id: 0x05, access: :administer, requires: :wi_fi_network_interface
      command 0x03, :add_or_update_thread_network, request: Tlv::AddOrUpdateThreadNetworkRequest, response: Tlv::NetworkConfigurationResponse, response_id: 0x05, access: :administer, requires: :thread_network_interface
      command 0x04, :remove_network, request: Tlv::RemoveNetworkRequest, response: Tlv::NetworkConfigurationResponse, response_id: 0x05, access: :administer, requires: ANY_WIRELESS_INTERFACE
      command 0x06, :connect_network, request: Tlv::ConnectNetworkRequest, response: Tlv::ConnectNetworkResponse, response_id: 0x07, access: :administer, requires: ANY_WIRELESS_INTERFACE
      command 0x08, :reorder_network, request: Tlv::ReorderNetworkRequest, response: Tlv::NetworkConfigurationResponse, response_id: 0x05, access: :administer, requires: ANY_WIRELESS_INTERFACE

      property network_type : NetworkType

      # WiFi-specific
      property wifi_credentials : Hash(Bytes, Bytes) # SSID -> password

      # Thread-specific
      property thread_credentials : Hash(Bytes, Bytes) # Extended PAN ID -> credentials

      # Platform backend for network operations (required)
      property backend : Network::Backend?

      # Additional state for connected network tracking
      @connected_network_index : Int32?

      def initialize(
        endpoint_id : DataType::EndpointNumber = DataType::EndpointNumber.new(0_u16),
        @network_type : NetworkType = NetworkType::WiFi,
        @max_networks : UInt8 = DEFAULT_MAX_NETWORKS,
        @feature_map : Feature = Feature::None,
        features : Feature? = nil,
        @scan_max_time_seconds : UInt8 = DEFAULT_SCAN_MAX_TIME_SECONDS,
        @connect_max_time_seconds : UInt8 = DEFAULT_CONNECT_MAX_TIME_SECONDS,
        @backend : Network::Backend? = nil,
      )
        # Allow 'features' parameter as alias for 'feature_map' for compatibility
        @feature_map = features if features

        # Auto-set feature_map based on network_type if not explicitly set
        if @feature_map == Feature::None
          @feature_map = case @network_type
                         when NetworkType::WiFi
                           Feature::WiFiNetworkInterface
                         when NetworkType::Thread
                           Feature::ThreadNetworkInterface
                         when NetworkType::Ethernet
                           Feature::EthernetNetworkInterface
                         else
                           Feature::None
                         end
        end

        raise ArgumentError.new("max_networks must be >= 1") if @max_networks < 1

        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))

        @connected_network_index = nil

        @wifi_credentials = {} of Bytes => Bytes
        @thread_credentials = {} of Bytes => Bytes

        # Interface capabilities advertised by the feature-gated attributes
        if @feature_map.wi_fi_network_interface?
          @supported_wifi_bands = [WiFiBandEnum::Band2G4, WiFiBandEnum::Band5G]
        end
        if @feature_map.thread_network_interface?
          @supported_thread_features = ThreadCapabilitiesBitmap::IsRouterCapable | ThreadCapabilitiesBitmap::IsFullThreadDevice
        end
      end

      # Command handlers that accept struct parameters (used by tests and high-level API)

      # ScanNetworks command (0x00)
      def handle_scan_networks(
        cmd : ScanNetworksRequest,
        failsafe_armed : Bool,
      ) : ScanNetworksResponse
        # Validate fail-safe is armed
        unless failsafe_armed
          return ScanNetworksResponse.new(
            networking_status: NetworkCommissioningStatus::UnknownError,
            debug_text: "Fail-safe not armed"
          )
        end

        unless @backend
          @last_networking_status = NetworkCommissioningStatus::UnknownError
          return ScanNetworksResponse.new(
            networking_status: NetworkCommissioningStatus::UnknownError,
            debug_text: "Network backend not configured"
          )
        end

        # Perform scan based on enabled features
        wifi_results = nil
        thread_results = nil

        if @feature_map.includes?(Feature::WiFiNetworkInterface)
          wifi_results = perform_wifi_scan(cmd.ssid)
        end

        if @feature_map.includes?(Feature::ThreadNetworkInterface)
          thread_results = perform_thread_scan
        end

        # Update state
        @last_networking_status = NetworkCommissioningStatus::Success
        @last_network_id = cmd.ssid

        ScanNetworksResponse.new(
          networking_status: NetworkCommissioningStatus::Success,
          wifi_scan_results: wifi_results,
          thread_scan_results: thread_results
        )
      end

      # AddOrUpdateWiFiNetwork command (0x02)
      def handle_add_or_update_wifi_network(
        cmd : AddOrUpdateWiFiNetworkRequest,
        failsafe_armed : Bool,
      ) : NetworkConfigResponse
        # Validate fail-safe is armed
        unless failsafe_armed
          return NetworkConfigResponse.new(
            networking_status: NetworkCommissioningStatus::UnknownError,
            debug_text: "Fail-safe not armed"
          )
        end

        # Validate WiFi feature is supported
        unless @feature_map.includes?(Feature::WiFiNetworkInterface)
          return NetworkConfigResponse.new(
            networking_status: NetworkCommissioningStatus::UnknownError,
            debug_text: "WiFi not supported"
          )
        end

        # Validate network ID
        if cmd.ssid.empty?
          return NetworkConfigResponse.new(
            networking_status: NetworkCommissioningStatus::OutOfRange,
            debug_text: "SSID cannot be empty"
          )
        end

        unless @backend
          @last_networking_status = NetworkCommissioningStatus::UnknownError
          @last_network_id = cmd.ssid
          return NetworkConfigResponse.new(
            networking_status: NetworkCommissioningStatus::UnknownError,
            debug_text: "Network backend not configured"
          )
        end

        # Check if network already exists (update) or new (add)
        existing_index = @networks.index { |net| net.network_id == cmd.ssid }

        # Check max networks limit for new additions
        if !existing_index && @networks.size >= @max_networks
          return NetworkConfigResponse.new(
            networking_status: NetworkCommissioningStatus::BoundsExceeded,
            debug_text: "Max networks limit reached"
          )
        end

        # Use backend to add/update network configuration
        if backend = @backend
          # Create WiFiNetworkInfo with parsed credentials
          network_info = Network::WiFiNetworkInfo.new(cmd.ssid, cmd.credentials)
          success = backend.add_wifi_network(network_info)
          unless success
            return NetworkConfigResponse.new(
              networking_status: NetworkCommissioningStatus::UnknownError,
              debug_text: "Backend failed to add WiFi network"
            )
          end
        end

        # Update internal state
        if existing_index
          # Update existing network
          @networks[existing_index] = NetworkInfo.new(cmd.ssid, @networks[existing_index].connected?)
          network_index = existing_index.to_u8
        else
          # Add new network
          @networks << NetworkInfo.new(cmd.ssid, false)
          network_index = (@networks.size - 1).to_u8
        end

        # Store credentials
        @wifi_credentials[cmd.ssid] = cmd.credentials

        # Update state
        @last_networking_status = NetworkCommissioningStatus::Success
        @last_network_id = cmd.ssid

        NetworkConfigResponse.new(
          networking_status: NetworkCommissioningStatus::Success,
          network_index: network_index
        )
      end

      # AddOrUpdateThreadNetwork command (0x03)
      def handle_add_or_update_thread_network(
        cmd : AddOrUpdateThreadNetworkRequest,
        failsafe_armed : Bool,
      ) : NetworkConfigResponse
        # Validate fail-safe is armed
        unless failsafe_armed
          return NetworkConfigResponse.new(
            networking_status: NetworkCommissioningStatus::UnknownError,
            debug_text: "Fail-safe not armed"
          )
        end

        # Validate Thread feature is supported
        unless @feature_map.includes?(Feature::ThreadNetworkInterface)
          return NetworkConfigResponse.new(
            networking_status: NetworkCommissioningStatus::UnknownError,
            debug_text: "Thread not supported"
          )
        end

        # Extract XPAN ID from operational dataset
        network_id = extract_thread_network_id(cmd.operational_dataset)

        unless @backend
          @last_networking_status = NetworkCommissioningStatus::UnknownError
          @last_network_id = network_id
          return NetworkConfigResponse.new(
            networking_status: NetworkCommissioningStatus::UnknownError,
            debug_text: "Network backend not configured"
          )
        end

        # Check if network already exists
        existing_index = @networks.index { |net| net.network_id == network_id }

        # Check max networks limit for new additions
        if !existing_index && @networks.size >= @max_networks
          return NetworkConfigResponse.new(
            networking_status: NetworkCommissioningStatus::BoundsExceeded,
            debug_text: "Max networks limit reached"
          )
        end

        # Use backend to add/update network configuration
        if backend = @backend
          # Create ThreadCredentials with parsed operational dataset
          credentials = Network::ThreadCredentials.new(cmd.operational_dataset)
          success = backend.add_thread_network(credentials)
          unless success
            return NetworkConfigResponse.new(
              networking_status: NetworkCommissioningStatus::UnknownError,
              debug_text: "Backend failed to add Thread network"
            )
          end
        end

        # Update internal state
        if existing_index
          # Update existing network
          @networks[existing_index] = NetworkInfo.new(network_id, @networks[existing_index].connected?)
          network_index = existing_index.to_u8
        else
          # Add new network
          @networks << NetworkInfo.new(network_id, false)
          network_index = (@networks.size - 1).to_u8
        end

        # Store credentials
        @thread_credentials[network_id] = cmd.operational_dataset

        # Update state
        @last_networking_status = NetworkCommissioningStatus::Success
        @last_network_id = network_id

        NetworkConfigResponse.new(
          networking_status: NetworkCommissioningStatus::Success,
          network_index: network_index
        )
      end

      # RemoveNetwork command (0x04)
      def handle_remove_network(
        cmd : RemoveNetworkRequest,
        failsafe_armed : Bool,
      ) : NetworkConfigResponse
        # Validate fail-safe is armed
        unless failsafe_armed
          return NetworkConfigResponse.new(
            networking_status: NetworkCommissioningStatus::UnknownError,
            debug_text: "Fail-safe not armed"
          )
        end

        # Find network by ID
        index = @networks.index { |net| net.network_id == cmd.network_id }

        unless index
          return NetworkConfigResponse.new(
            networking_status: NetworkCommissioningStatus::NetworkIdNotFound,
            debug_text: "Network not found"
          )
        end

        unless @backend
          @last_networking_status = NetworkCommissioningStatus::UnknownError
          @last_network_id = cmd.network_id
          return NetworkConfigResponse.new(
            networking_status: NetworkCommissioningStatus::UnknownError,
            debug_text: "Network backend not configured"
          )
        end

        # Use backend to remove network configuration
        if backend = @backend
          success = backend.remove_network(cmd.network_id)
          unless success
            return NetworkConfigResponse.new(
              networking_status: NetworkCommissioningStatus::UnknownError,
              debug_text: "Backend failed to remove network"
            )
          end
        end

        # Remove network (maintains relative order of remaining entries)
        @networks.delete_at(index)

        # Remove stored credentials
        @wifi_credentials.delete(cmd.network_id)
        @thread_credentials.delete(cmd.network_id)

        # Update state
        @last_networking_status = NetworkCommissioningStatus::Success
        @last_network_id = cmd.network_id

        NetworkConfigResponse.new(
          networking_status: NetworkCommissioningStatus::Success,
          network_index: index.to_u8
        )
      end

      # ConnectNetwork command (0x06)
      def handle_connect_network(
        cmd : ConnectNetworkRequest,
        failsafe_armed : Bool,
      ) : ConnectNetworkResponse
        # Validate fail-safe is armed
        unless failsafe_armed
          return ConnectNetworkResponse.new(
            networking_status: NetworkCommissioningStatus::UnknownError,
            debug_text: "Fail-safe not armed"
          )
        end

        # Find network by ID
        index = @networks.index { |net| net.network_id == cmd.network_id }

        unless index
          return ConnectNetworkResponse.new(
            networking_status: NetworkCommissioningStatus::NetworkIdNotFound,
            debug_text: "Network not found"
          )
        end

        unless @backend
          @last_networking_status = NetworkCommissioningStatus::UnknownError
          @last_network_id = cmd.network_id
          return ConnectNetworkResponse.new(
            networking_status: NetworkCommissioningStatus::UnknownError,
            debug_text: "Network backend not configured"
          )
        end

        # Use backend to connect to network
        if backend = @backend
          success, error_value = backend.connect_network(cmd.network_id)
          unless success
            # Connection failed - update state and return error
            @last_networking_status = NetworkCommissioningStatus::OtherConnectionFailure
            @last_network_id = cmd.network_id
            @last_connect_error_value = error_value

            return ConnectNetworkResponse.new(
              networking_status: NetworkCommissioningStatus::OtherConnectionFailure,
              debug_text: "Connection failed",
              error_value: error_value
            )
          end
        end

        # Connection succeeded - update internal state
        # Set target network as connected, others as disconnected
        @networks = @networks.map_with_index do |network, i|
          NetworkInfo.new(network.network_id, i == index)
        end

        @connected_network_index = index

        # Update state
        @last_networking_status = NetworkCommissioningStatus::Success
        @last_network_id = cmd.network_id
        @last_connect_error_value = nil

        ConnectNetworkResponse.new(
          networking_status: NetworkCommissioningStatus::Success,
          error_value: nil
        )
      end

      # ReorderNetwork command (0x08)
      def handle_reorder_network(
        cmd : ReorderNetworkRequest,
        failsafe_armed : Bool,
      ) : NetworkConfigResponse
        # Validate fail-safe is armed
        unless failsafe_armed
          return NetworkConfigResponse.new(
            networking_status: NetworkCommissioningStatus::UnknownError,
            debug_text: "Fail-safe not armed"
          )
        end

        # Find network by ID
        current_index = @networks.index { |net| net.network_id == cmd.network_id }

        unless current_index
          return NetworkConfigResponse.new(
            networking_status: NetworkCommissioningStatus::NetworkIdNotFound,
            debug_text: "Network not found"
          )
        end

        # Validate new index is in range
        if cmd.network_index >= @networks.size
          return NetworkConfigResponse.new(
            networking_status: NetworkCommissioningStatus::OutOfRange,
            debug_text: "Network index out of range"
          )
        end

        # Reorder network (move from current_index to network_index)
        network = @networks.delete_at(current_index)
        @networks.insert(cmd.network_index, network)

        # Update state
        @last_networking_status = NetworkCommissioningStatus::Success
        @last_network_id = cmd.network_id

        NetworkConfigResponse.new(
          networking_status: NetworkCommissioningStatus::Success,
          network_index: cmd.network_index
        )
      end

      # TLV-level command handlers that parse bytes and encode responses
      # These bridge protocol-level TLV encoding with high-level struct handlers

      # Wire status answered when a request field violates its length constraint.
      OUT_OF_RANGE_STATUS = Tlv::StatusCode.new(NetworkCommissioningStatus::OutOfRange.value)

      # A request DTO rejected a field (oversized ssid / credentials / dataset /
      # network_id): answer `OutOfRange` with the validation message instead of
      # failing the whole command.
      private def out_of_range_config_response(command : String, ex : ArgumentError) : Tlv::NetworkConfigurationResponse
        Log.warn(exception: ex) { "#{command} rejected" }
        Tlv::NetworkConfigurationResponse.new(
          status_code: OUT_OF_RANGE_STATUS,
          debug_text: ex.message
        )
      end

      def scan_networks(tlv_req : Tlv::ScanAvailableNetworksRequest) : Tlv::ScanNetworksResponse
        # Parse TLV request

        # Convert to simple struct
        req = begin
          ScanNetworksRequest.new(
            ssid: tlv_req.ssid,
            breadcrumb: tlv_req.breadcrumb
          )
        rescue ex : ArgumentError
          Log.warn(exception: ex) { "ScanNetworks rejected" }
          return Tlv::ScanNetworksResponse.new(
            status_code: OUT_OF_RANGE_STATUS,
            debug_text: ex.message
          )
        end

        # Call high-level handler (pass true - failsafe checks done at protocol layer)
        response = handle_scan_networks(req, failsafe_armed: true)

        # Convert internal WiFi results to Definitions struct (skip incomplete results)
        wifi_results = if results = response.wifi_scan_results
                         results.compact_map do |result|
                           next unless result.ssid && result.bssid && result.channel
                           band = result.wifi_band.try { |wifi_band| Tlv::Band.new(wifi_band.value) }
                           Tlv::WiFiInterfaceScanResult.new(
                             security: result.security.try(&.value) || 0_u8,
                             ssid: result.ssid.as(Bytes),
                             bssid: result.bssid.as(Bytes),
                             channel: result.channel.as(UInt16),
                             band: band,
                             rssi: result.rssi
                           )
                         end
                       end

        # Convert internal Thread results to Definitions struct
        thread_results = if results = response.thread_scan_results
                           results.map do |result|
                             Tlv::ThreadInterfaceScanResult.new(
                               pan_id: result.pan_id,
                               extended_pan_id: result.extended_pan_id,
                               network_name: result.network_name,
                               channel: result.channel,
                               version: result.version,
                               extended_address: result.extended_address,
                               rssi: result.rssi,
                               lqi: result.lqi
                             )
                           end
                         end

        # Use TLV::Serializable struct for response
        Tlv::ScanNetworksResponse.new(
          status_code: Tlv::StatusCode.new(response.networking_status.value),
          debug_text: response.debug_text,
          wifi_scan_results: wifi_results.try { |wifi_res| wifi_res.empty? ? nil : wifi_res },
          thread_scan_results: thread_results.try { |thread_res| thread_res.empty? ? nil : thread_res }
        )
      end

      def add_or_update_wifi_network(tlv_req : Tlv::AddOrUpdateWiFiNetworkRequest) : Tlv::NetworkConfigurationResponse
        # Parse TLV request

        # Convert to simple struct
        req = begin
          AddOrUpdateWiFiNetworkRequest.new(
            ssid: tlv_req.ssid,
            credentials: tlv_req.credentials,
            breadcrumb: tlv_req.breadcrumb
          )
        rescue ex : ArgumentError
          return out_of_range_config_response("AddOrUpdateWiFiNetwork", ex)
        end

        # Call high-level handler (pass true - failsafe checks done at protocol layer)
        response = handle_add_or_update_wifi_network(req, failsafe_armed: true)

        # Use TLV::Serializable struct for response
        Tlv::NetworkConfigurationResponse.new(
          status_code: Tlv::StatusCode.new(response.networking_status.value),
          debug_text: response.debug_text,
          network_index: response.network_index
        )
      end

      def add_or_update_thread_network(tlv_req : Tlv::AddOrUpdateThreadNetworkRequest) : Tlv::NetworkConfigurationResponse
        # Parse TLV request

        # Convert to simple struct
        req = begin
          AddOrUpdateThreadNetworkRequest.new(
            operational_dataset: tlv_req.operational_dataset,
            breadcrumb: tlv_req.breadcrumb
          )
        rescue ex : ArgumentError
          return out_of_range_config_response("AddOrUpdateThreadNetwork", ex)
        end

        # Call high-level handler (pass true - failsafe checks done at protocol layer)
        response = handle_add_or_update_thread_network(req, failsafe_armed: true)

        # Use TLV::Serializable struct for response
        Tlv::NetworkConfigurationResponse.new(
          status_code: Tlv::StatusCode.new(response.networking_status.value),
          debug_text: response.debug_text,
          network_index: response.network_index
        )
      end

      def remove_network(tlv_req : Tlv::RemoveNetworkRequest) : Tlv::NetworkConfigurationResponse
        # Parse TLV request

        # Convert to simple struct
        req = begin
          RemoveNetworkRequest.new(
            network_id: tlv_req.network_id,
            breadcrumb: tlv_req.breadcrumb
          )
        rescue ex : ArgumentError
          return out_of_range_config_response("RemoveNetwork", ex)
        end

        # Call high-level handler (pass true - failsafe checks done at protocol layer)
        response = handle_remove_network(req, failsafe_armed: true)

        # Use TLV::Serializable struct for response
        Tlv::NetworkConfigurationResponse.new(
          status_code: Tlv::StatusCode.new(response.networking_status.value),
          debug_text: response.debug_text,
          network_index: response.network_index
        )
      end

      def connect_network(tlv_req : Tlv::ConnectNetworkRequest) : Tlv::ConnectNetworkResponse
        # Parse TLV request

        # Convert to simple struct
        req = begin
          ConnectNetworkRequest.new(
            network_id: tlv_req.network_id,
            breadcrumb: tlv_req.breadcrumb
          )
        rescue ex : ArgumentError
          Log.warn(exception: ex) { "ConnectNetwork rejected" }
          return Tlv::ConnectNetworkResponse.new(
            status_code: OUT_OF_RANGE_STATUS,
            debug_text: ex.message
          )
        end

        # Call high-level handler (pass true - failsafe checks done at protocol layer)
        response = handle_connect_network(req, failsafe_armed: true)

        # Use TLV::Serializable struct for response
        Tlv::ConnectNetworkResponse.new(
          status_code: Tlv::StatusCode.new(response.networking_status.value),
          debug_text: response.debug_text,
          error_value: response.error_value
        )
      end

      def reorder_network(tlv_req : Tlv::ReorderNetworkRequest) : Tlv::NetworkConfigurationResponse
        # Parse TLV request

        # Convert to simple struct
        req = begin
          ReorderNetworkRequest.new(
            network_id: tlv_req.network_id,
            network_index: tlv_req.network_index,
            breadcrumb: tlv_req.breadcrumb
          )
        rescue ex : ArgumentError
          return out_of_range_config_response("ReorderNetwork", ex)
        end

        # Call high-level handler (pass true - failsafe checks done at protocol layer)
        response = handle_reorder_network(req, failsafe_armed: true)

        # Use TLV::Serializable struct for response
        Tlv::NetworkConfigurationResponse.new(
          status_code: Tlv::StatusCode.new(response.networking_status.value),
          debug_text: response.debug_text,
          network_index: response.network_index
        )
      end

      # Restore network state from snapshot (used during failsafe rollback)
      #
      # This method restores the network configuration to a previously captured state.
      # It's called during failsafe rollback to undo any network configuration changes
      # made during a failed commissioning session.
      #
      # @param state Snapshot of network state (key-value pairs)
      def restore_network_state(snapshot : Hash(String, String)) : Nil
        state = snapshot
        Log.info { "Restoring network state from snapshot" }

        # Restore networks list
        if networks_json = state["networks"]?
          begin
            network_data = Array(Hash(String, JSON::Any)).from_json(networks_json)
            @networks.clear

            network_data.each do |net|
              network_id = Base64.decode(net["network_id"].as_s)
              connected = net["connected"].as_bool
              @networks << NetworkInfo.new(network_id, connected)
            end

            Log.debug { "Restored #{@networks.size} network(s)" }
          rescue ex
            Log.error(exception: ex) { "Failed to restore networks from snapshot (networks_json=#{networks_json})" }
          end
        end

        # Restore interface enabled state
        if interface_enabled_str = state["interface_enabled"]?
          @interface_enabled = interface_enabled_str == "true"
          Log.debug { "Restored interface_enabled: #{@interface_enabled}" }
        end

        # Restore last networking status
        if last_status_str = state["last_networking_status"]?
          @last_networking_status = NetworkCommissioningStatus.from_value(last_status_str.to_u8)
          Log.debug { "Restored last_networking_status: #{@last_networking_status}" }
        end

        # Restore last network ID
        if last_network_id_str = state["last_network_id"]?
          @last_network_id = Base64.decode(last_network_id_str) unless last_network_id_str.empty?
          Log.debug { "Restored last_network_id" }
        end

        # Restore last connect error value
        if last_error_str = state["last_connect_error_value"]?
          @last_connect_error_value = last_error_str.to_i32? unless last_error_str.empty?
          Log.debug { "Restored last_connect_error_value: #{@last_connect_error_value}" }
        end

        Log.info { "Network state restored successfully" }
      end

      # Helper methods

      private def perform_wifi_scan(ssid : Bytes?) : Array(WiFiInterfaceScanResult)
        backend = @backend
        unless backend
          Log.warn { "No network backend configured for WiFi scan - returning empty results" }
          return [] of WiFiInterfaceScanResult
        end

        # Convert SSID bytes to string for backend
        ssid_string = ssid ? String.new(ssid) : nil
        backend.scan_wifi(ssid_string)
      end

      private def perform_thread_scan : Array(ThreadInterfaceScanResult)
        backend = @backend
        unless backend
          Log.warn { "No network backend configured for Thread scan - returning empty results" }
          return [] of ThreadInterfaceScanResult
        end

        backend.scan_thread
      end

      # Extract Extended PAN ID (network ID) from Thread Operational Dataset
      #
      # The Operational Dataset is TLV-encoded Thread network parameters.
      # Extended PAN ID is a 64-bit value (8 bytes) with TLV type 0x02.
      #
      # Uses ThreadCredentials to parse the TLV-encoded dataset and extract
      # the Extended PAN ID field.
      private def extract_thread_network_id(operational_dataset : Bytes) : Bytes
        credentials = Network::ThreadCredentials.new(operational_dataset)
        credentials.network_id
      end

      # Helper: Get current connected network
      def connected_network : NetworkInfo?
        @networks.find(&.connected?)
      end

      # Helper: Check if network exists
      def has_network?(network_id : Bytes) : Bool
        @networks.any? { |net| net.network_id == network_id }
      end
    end
  end
end
