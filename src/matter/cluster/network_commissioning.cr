require "./cluster"
require "./general_commissioning"
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

      class InterfaceDisableUnsupported < ClusterError
      end

      class InterfaceChangeFailed < ClusterError
      end

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
      attribute 0x0004, :interface_enabled, Bool, default: true, writable: true,
        persist_default: true, validate: :validate_interface_enabled, write_access: :administer
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

      # General Commissioning owns Breadcrumb. The device wires this callback
      # so a successful network command can update it atomically.
      property on_breadcrumb_success : Proc(UInt64, Nil)?

      # The wire command path consults the live commissioning fail-safe.
      # A standalone cluster without one fails closed.
      property general_commissioning : GeneralCommissioning?

      # The runtime persists committed network metadata; host credentials stay
      # in the platform backend, which owns their durable storage.
      property on_persist_network_state : Proc(Nil)?

      # Additional state for connected network tracking
      @connected_network_index : Int32?

      def initialize(
        endpoint_id : DataType::EndpointNumber = DataType::EndpointNumber::ROOT,
        @network_type : NetworkType = NetworkType::WiFi,
        @max_networks : UInt8 = DEFAULT_MAX_NETWORKS,
        @feature_map : Feature = Feature::None,
        features : Feature? = nil,
        @scan_max_time_seconds : UInt8 = DEFAULT_SCAN_MAX_TIME_SECONDS,
        @connect_max_time_seconds : UInt8 = DEFAULT_CONNECT_MAX_TIME_SECONDS,
        @backend : Network::Backend? = nil,
        @general_commissioning : GeneralCommissioning? = nil,
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

        if backend = @backend
          @interface_enabled = backend.interface_enabled?
        end

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

      private def validate_interface_enabled(enabled : Bool) : Nil
        case apply_interface_enabled(enabled)
        when Network::Backend::InterfaceEnabledResult::Success
          nil
        when Network::Backend::InterfaceEnabledResult::Unsupported
          raise InterfaceDisableUnsupported.new("Network backend does not support disabling its interface")
        when Network::Backend::InterfaceEnabledResult::Failure
          raise InterfaceChangeFailed.new("Network backend could not change interface state")
        end
      end

      private def apply_interface_enabled(enabled : Bool) : Network::Backend::InterfaceEnabledResult
        if backend = @backend
          backend.apply_interface_enabled(enabled)
        else
          enabled ? Network::Backend::InterfaceEnabledResult::Success : Network::Backend::InterfaceEnabledResult::Unsupported
        end
      end

      private def dsl_before_write_interface_enabled(enabled : Bool) : InteractionModel::Status
        self.interface_enabled = enabled
        InteractionModel::Status.success
      rescue InterfaceDisableUnsupported
        InteractionModel::Status.invalid_action
      rescue ex
        Log.warn(exception: ex) { "Network backend could not change interface state" }
        InteractionModel::Status.failure
      end

      private def after_restore_state : Nil
        case apply_interface_enabled(@interface_enabled)
        when Network::Backend::InterfaceEnabledResult::Success
          nil
        else
          Log.warn { "Network backend could not restore interface state; using its current state" }
          if backend = @backend
            @interface_enabled = backend.interface_enabled?
          else
            @interface_enabled = true
          end
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
        set_breadcrumb_on_success(cmd.breadcrumb)

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
        set_breadcrumb_on_success(cmd.breadcrumb)

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
        set_breadcrumb_on_success(cmd.breadcrumb)

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
        set_breadcrumb_on_success(cmd.breadcrumb)

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
        set_breadcrumb_on_success(cmd.breadcrumb)

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
        set_breadcrumb_on_success(cmd.breadcrumb)

        NetworkConfigResponse.new(
          networking_status: NetworkCommissioningStatus::Success,
          network_index: cmd.network_index
        )
      end

      # TLV-level command handlers that parse bytes and encode responses
      # These bridge protocol-level TLV encoding with high-level struct handlers

      # Wire status answered when a request field violates its length constraint.
      OUT_OF_RANGE_STATUS = Tlv::StatusCode.new(NetworkCommissioningStatus::OutOfRange.value)

      private def network_command_failsafe_status : InteractionModel::Status?
        context = @general_commissioning.try(&.failsafe_context)
        return InteractionModel::Status.failsafe_required unless context && context.armed?
        InteractionModel::Status.unsupported_access unless context.matches_fabric?(request_fabric_index)
      end

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

      def scan_networks(tlv_req : Tlv::ScanAvailableNetworksRequest) : Tlv::ScanNetworksResponse | InteractionModel::Status
        if status = network_command_failsafe_status
          return status
        end
        # Parse TLV request

        # Convert to simple struct
        req = begin
          ScanNetworksRequest.new(
            ssid: tlv_req.ssid,
            breadcrumb: tlv_req.breadcrumb
          )
        rescue ex : ArgumentError
          Log.warn(exception: ex) { "ScanNetworks rejected" }
          return scan_networks_response(OUT_OF_RANGE_STATUS, ex.message)
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
        scan_networks_response(
          Tlv::StatusCode.new(response.networking_status.value),
          response.debug_text,
          wifi_results,
          thread_results
        )
      end

      # Feature-present scan result lists are required by Matter 1.6 even when
      # the scan found no networks or returned a networking error.
      private def scan_networks_response(
        status_code : Tlv::StatusCode,
        debug_text : String? = nil,
        wifi_results : Array(Tlv::WiFiInterfaceScanResult)? = nil,
        thread_results : Array(Tlv::ThreadInterfaceScanResult)? = nil,
      ) : Tlv::ScanNetworksResponse
        Tlv::ScanNetworksResponse.new(
          status_code: status_code,
          debug_text: debug_text,
          wifi_scan_results: @feature_map.wi_fi_network_interface? ? (wifi_results || [] of Tlv::WiFiInterfaceScanResult) : nil,
          thread_scan_results: @feature_map.thread_network_interface? ? (thread_results || [] of Tlv::ThreadInterfaceScanResult) : nil
        )
      end

      def add_or_update_wifi_network(tlv_req : Tlv::AddOrUpdateWiFiNetworkRequest) : Tlv::NetworkConfigurationResponse | InteractionModel::Status
        if status = network_command_failsafe_status
          return status
        end
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

        if status = checkpoint_network_state
          return status
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

      def add_or_update_thread_network(tlv_req : Tlv::AddOrUpdateThreadNetworkRequest) : Tlv::NetworkConfigurationResponse | InteractionModel::Status
        if status = network_command_failsafe_status
          return status
        end
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

        if status = checkpoint_network_state
          return status
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

      def remove_network(tlv_req : Tlv::RemoveNetworkRequest) : Tlv::NetworkConfigurationResponse | InteractionModel::Status
        if status = network_command_failsafe_status
          return status
        end
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

        if status = checkpoint_network_state
          return status
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

      def connect_network(tlv_req : Tlv::ConnectNetworkRequest) : Tlv::ConnectNetworkResponse | InteractionModel::Status
        if status = network_command_failsafe_status
          return status
        end
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

        if status = checkpoint_network_state
          return status
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

      def reorder_network(tlv_req : Tlv::ReorderNetworkRequest) : Tlv::NetworkConfigurationResponse | InteractionModel::Status
        if status = network_command_failsafe_status
          return status
        end
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

        if status = checkpoint_network_state
          return status
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

      def restore_network_state(snapshot : Storage::Document) : Nil
        backend = @backend || raise CommissioningError.new("Network backend unavailable for rollback")
        backend_snapshot = snapshot["backend"].as(Storage::Document)
        unless backend.restore_configuration(Storage.deep_copy(backend_snapshot))
          raise CommissioningError.new("Network backend could not restore checkpoint")
        end

        cluster_snapshot = snapshot["cluster"].as(Storage::Document)
        restore_state(cluster_snapshot)
        @wifi_credentials = decode_credentials(snapshot["wifi_credentials"].as(Array(Storage::Type)))
        @thread_credentials = decode_credentials(snapshot["thread_credentials"].as(Array(Storage::Type)))
        @last_networking_status = snapshot["last_networking_status"].as(Int64?).try do |value|
          NetworkCommissioningStatus.from_value(value.to_u8)
        end
        @last_network_id = snapshot["last_network_id"].as(Bytes?).try(&.dup)
        @last_connect_error_value = snapshot["last_connect_error_value"].as(Int64?).try(&.to_i32)
        @connected_network_index = snapshot["connected_network_index"].as(Int64?).try(&.to_i32)
        # Checkpoints from before InterfaceEnabled joined the persisted cluster
        # record kept it only in the outer snapshot.
        unless cluster_snapshot.has_key?("interface_enabled")
          self.interface_enabled = snapshot["interface_enabled"].as(Bool)
        end
        @on_persist_network_state.try(&.call)
        Log.info { "Restored network commissioning state" }
      end

      def commit_network_state : Nil
        backend = @backend || raise CommissioningError.new("Network backend unavailable for commit")
        unless backend.commit_configuration
          raise CommissioningError.new("Network backend could not commit configuration")
        end
        @on_persist_network_state.try(&.call)
      end

      private def checkpoint_network_state : InteractionModel::Status?
        context = @general_commissioning.try(&.failsafe_context)
        return InteractionModel::Status.failsafe_required unless context && context.armed?
        return if context.network_state_snapshot

        backend = @backend || return InteractionModel::Status.failure
        backend_snapshot = backend.checkpoint_configuration || return InteractionModel::Status.failure
        snapshot = Storage::Document{
          "backend"                  => Storage.deep_copy(backend_snapshot),
          "cluster"                  => save_state.as(Storage::Document),
          "wifi_credentials"         => encode_credentials(@wifi_credentials),
          "thread_credentials"       => encode_credentials(@thread_credentials),
          "last_networking_status"   => @last_networking_status.try(&.value.to_i64),
          "last_network_id"          => @last_network_id.try(&.dup),
          "last_connect_error_value" => @last_connect_error_value.try(&.to_i64),
          "connected_network_index"  => @connected_network_index.try(&.to_i64),
          "interface_enabled"        => @interface_enabled,
        }
        context.record_network_state(snapshot)
        nil
      rescue ex
        Log.error(exception: ex) { "Could not checkpoint network configuration" }
        InteractionModel::Status.failure
      end

      private def encode_credentials(credentials : Hash(Bytes, Bytes)) : Array(Storage::Type)
        credentials.map do |id, secret|
          Storage::Document{"id" => id.dup, "secret" => secret.dup}.as(Storage::Type)
        end
      end

      private def decode_credentials(entries : Array(Storage::Type)) : Hash(Bytes, Bytes)
        credentials = {} of Bytes => Bytes
        entries.each do |entry|
          document = entry.as(Storage::Document)
          credentials[document["id"].as(Bytes).dup] = document["secret"].as(Bytes).dup
        end
        credentials
      end

      # Command-managed network metadata is persisted on commit. Credentials
      # remain solely in the platform backend's durable storage.
      def save_state : Storage::Document?
        entries = @networks.map do |network|
          Storage::Document{"id" => network.network_id.dup, "connected" => network.connected?}.as(Storage::Type)
        end
        document = super || Storage::Document.new
        document["networks"] = entries
        document
      end

      def restore_state(document : Storage::Document) : Nil
        super(document)
        if entries = document["networks"]?
          @networks = entries.as(Array(Storage::Type)).map do |entry|
            network = entry.as(Storage::Document)
            NetworkInfo.new(network["id"].as(Bytes).dup, network["connected"].as(Bool))
          end
        end
      end

      # Helper methods

      private def set_breadcrumb_on_success(value : UInt64?) : Nil
        return unless value

        @on_breadcrumb_success.try(&.call(value))
      end

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
