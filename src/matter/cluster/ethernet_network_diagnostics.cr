require "./cluster"

module Matter
  module Cluster
    # Ethernet Network Diagnostics Cluster (0x0037)
    #
    # Provides Ethernet network diagnostic information.
    # Required by Apple Home for Ethernet-connected accessories.
    #
    # Matter Spec: Core 11.15
    class EthernetNetworkDiagnostics < Base
      cluster 0x0037, revision: 1

      feature :packet_counts, bit: 0 # PKTCNT
      feature :error_counts, bit: 1  # ERRCNT

      # PHY Rate enum
      enum PHYRateEnum : UInt8
        Rate10M  = 0 # 10 Mbps
        Rate100M = 1 # 100 Mbps
        Rate1G   = 2 # 1 Gbps
        Rate25G  = 3 # 2.5 Gbps
        Rate5G   = 4 # 5 Gbps
        Rate10G  = 5 # 10 Gbps
        Rate40G  = 6 # 40 Gbps
        Rate100G = 7 # 100 Gbps
        Rate200G = 8 # 200 Gbps
        Rate400G = 9 # 400 Gbps
      end

      # The packet and error counters are bumped in place by the `record_*`
      # helpers without a data version change (they are omit-changes
      # attributes); TimeSinceReset is computed on read.
      attribute 0x0000, :phy_rate, PHYRateEnum, nullable: true, optional: true
      attribute 0x0001, :full_duplex, Bool, nullable: true, optional: true
      attribute 0x0002, :packet_rx_count, UInt64, default: 0_u64, omit_changes: true, requires: :packet_counts
      attribute 0x0003, :packet_tx_count, UInt64, default: 0_u64, omit_changes: true, requires: :packet_counts
      attribute 0x0004, :tx_err_count, UInt64, default: 0_u64, omit_changes: true, requires: :error_counts
      attribute 0x0005, :collision_count, UInt64, default: 0_u64, omit_changes: true, requires: :error_counts
      attribute 0x0006, :overrun_count, UInt64, default: 0_u64, omit_changes: true, requires: :error_counts
      attribute 0x0007, :carrier_detect, Bool, nullable: true, omit_changes: true, optional: true
      attribute 0x0008, :time_since_reset, UInt64, computed: true, omit_changes: true, optional: true

      command 0x00, :reset_counts, requires: [:packet_counts, :error_counts], access: :manage

      # Track when counters were last reset
      @reset_time : Time

      def initialize(
        endpoint_id : DataType::EndpointNumber,
        @phy_rate : PHYRateEnum? = PHYRateEnum::Rate1G,
        @full_duplex : Bool? = true,
        @feature_map : Feature = Feature::PacketCounts | Feature::ErrorCounts,
      )
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        @carrier_detect = true
        @reset_time = Time.utc
      end

      # TimeSinceReset attribute (0x08): minutes since the counters were reset
      def time_since_reset : UInt64
        (Time.utc - @reset_time).total_minutes.to_u64
      end

      def reset_counts : InteractionModel::Status
        @packet_rx_count = 0_u64
        @packet_tx_count = 0_u64
        @tx_err_count = 0_u64
        @collision_count = 0_u64
        @overrun_count = 0_u64
        @reset_time = Time.utc
        increment_version
        InteractionModel::Status.success
      end

      # Public API: Increment packet counts
      def record_rx_packet
        @packet_rx_count += 1
      end

      def record_tx_packet
        @packet_tx_count += 1
      end

      def record_tx_error
        @tx_err_count += 1
      end

      def record_collision
        @collision_count += 1
      end

      def record_overrun
        @overrun_count += 1
      end
    end
  end
end
