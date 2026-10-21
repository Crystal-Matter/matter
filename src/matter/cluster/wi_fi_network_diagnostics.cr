require "./cluster"
require "tlv"

module Matter
  module Cluster
    # Observed Wi-Fi link state and optional packet/error counters.
    class WiFiNetworkDiagnostics < Base
      cluster 0x0036, revision: 1

      feature :packet_counts, bit: 0
      feature :error_counts, bit: 1

      enum SecurityType : UInt8
        Unspecified = 0
        None        = 1
        Wep         = 2
        Wpa         = 3
        Wpa2        = 4
        Wpa3        = 5
      end

      enum WiFiVersion : UInt8
        A  = 0
        B  = 1
        G  = 2
        N  = 3
        Ac = 4
        Ax = 5
        Ah = 6
      end

      enum AssociationFailureCause : UInt8
        Unknown              = 0
        AssociationFailed    = 1
        AuthenticationFailed = 2
        SsidNotFound         = 3
      end

      enum ConnectionStatus : UInt8
        Connected    = 0
        NotConnected = 1
      end

      struct DisconnectionEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property reason_code : UInt16

        def initialize(@reason_code : UInt16)
        end
      end

      struct AssociationFailureEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property association_failure_cause : AssociationFailureCause

        @[TLV::Field(tag: 1)]
        property status : UInt16

        def initialize(@association_failure_cause : AssociationFailureCause,
                       @status : UInt16)
        end
      end

      struct ConnectionStatusEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property connection_status : ConnectionStatus

        def initialize(@connection_status : ConnectionStatus)
        end
      end

      attribute 0x0000, :bssid, Bytes, nullable: true
      attribute 0x0001, :security_type, SecurityType, nullable: true
      attribute 0x0002, :wi_fi_version, WiFiVersion, nullable: true
      attribute 0x0003, :channel_number, UInt16, nullable: true
      attribute 0x0004, :rssi, Int8, nullable: true, min: -120_i8, max: 0_i8,
        omit_changes: true
      attribute 0x0005, :beacon_lost_count, UInt32, nullable: true,
        default: 0_u32, requires: :error_counts, omit_changes: true
      attribute 0x0006, :beacon_rx_count, UInt32, nullable: true,
        default: 0_u32, requires: :packet_counts, omit_changes: true
      attribute 0x0007, :packet_multicast_rx_count, UInt32, nullable: true,
        default: 0_u32, requires: :packet_counts, omit_changes: true
      attribute 0x0008, :packet_multicast_tx_count, UInt32, nullable: true,
        default: 0_u32, requires: :packet_counts, omit_changes: true
      attribute 0x0009, :packet_unicast_rx_count, UInt32, nullable: true,
        default: 0_u32, requires: :packet_counts, omit_changes: true
      attribute 0x000A, :packet_unicast_tx_count, UInt32, nullable: true,
        default: 0_u32, requires: :packet_counts, omit_changes: true
      attribute 0x000B, :current_max_rate, UInt64, nullable: true,
        optional: true, present_if: :current_max_rate, omit_changes: true
      attribute 0x000C, :overrun_count, UInt64, nullable: true,
        default: 0_u64, requires: :error_counts, omit_changes: true

      event 0x0000, :disconnection, priority: :info
      event 0x0001, :association_failure, priority: :info
      event 0x0002, :connection_status, priority: :info
      command 0x0000, :reset_counts, requires: :error_counts, access: :operate

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @feature_map : Feature = Feature::None,
                     @bssid : Bytes? = nil,
                     @security_type : SecurityType? = nil,
                     @wi_fi_version : WiFiVersion? = nil,
                     @channel_number : UInt16? = nil,
                     @rssi : Int8? = nil,
                     @current_max_rate : UInt64? = nil)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        validate_link!(@bssid, @rssi)
        @bssid = @bssid.try(&.dup)
      end

      def update_link(bssid : Bytes?, security_type : SecurityType?,
                      version : WiFiVersion?, channel : UInt16?,
                      rssi : Int8?) : Nil
        validate_link!(bssid, rssi)
        self.bssid = bssid.try(&.dup)
        self.security_type = security_type
        self.wi_fi_version = version
        self.channel_number = channel
        self.rssi = rssi
      end

      def record_beacon_loss : Nil
        @beacon_lost_count = (@beacon_lost_count || 0_u32) &+ 1_u32
      end

      def record_beacon_rx : Nil
        @beacon_rx_count = (@beacon_rx_count || 0_u32) &+ 1_u32
      end

      def reset_counts : InteractionModel::Status
        @beacon_lost_count = 0_u32
        @beacon_rx_count = 0_u32
        @packet_multicast_rx_count = 0_u32
        @packet_multicast_tx_count = 0_u32
        @packet_unicast_rx_count = 0_u32
        @packet_unicast_tx_count = 0_u32
        @overrun_count = 0_u64
        InteractionModel::Status.success
      end

      def emit_disconnection(reason_code : UInt16) : Bytes
        payload = DisconnectionEvent.new(reason_code)
        emit_event(EVENT_DISCONNECTION, payload)
        payload.to_slice
      end

      def emit_association_failure(cause : AssociationFailureCause,
                                   status : UInt16) : Bytes
        payload = AssociationFailureEvent.new(cause, status)
        emit_event(EVENT_ASSOCIATION_FAILURE, payload)
        payload.to_slice
      end

      def emit_connection_status(status : ConnectionStatus) : Bytes
        payload = ConnectionStatusEvent.new(status)
        emit_event(EVENT_CONNECTION_STATUS, payload)
        payload.to_slice
      end

      private def validate_link!(bssid : Bytes?, rssi : Int8?) : Nil
        raise ArgumentError.new("BSSID must contain six bytes") if bssid && bssid.size != 6
        raise ArgumentError.new("RSSI must be between -120 and 0 dBm") if rssi && (rssi < -120 || rssi > 0)
      end
    end
  end
end
