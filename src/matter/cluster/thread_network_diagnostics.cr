require "./cluster"
require "tlv"

module Matter
  module Cluster
    # Thread link state and counters supplied by a platform Thread stack.
    class ThreadNetworkDiagnostics < Base
      cluster 0x0035, revision: 3

      MAX_NETWORK_NAME_BYTES = 16
      MAX_MESH_PREFIX_BYTES  = 17
      CHANNEL_MASK_BYTES     =  4
      MAX_ACTIVE_FAULTS      =  4

      feature :packet_counts, bit: 0
      feature :error_counts, bit: 1
      feature :mle_counts, bit: 2
      feature :mac_counts, bit: 3

      enum RoutingRole : UInt8
        Unspecified     = 0
        Unassigned      = 1
        SleepyEndDevice = 2
        EndDevice       = 3
        Reed            = 4
        Router          = 5
        Leader          = 6
      end

      enum NetworkFault : UInt8
        Unspecified     = 0
        LinkDown        = 1
        HardwareFailure = 2
        NetworkJammed   = 3
      end

      enum ConnectionStatus : UInt8
        Connected    = 0
        NotConnected = 1
      end

      struct NeighborTableStruct
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property ext_address : UInt64
        @[TLV::Field(tag: 1)]
        property age : UInt32
        @[TLV::Field(tag: 2)]
        property rloc16 : UInt16
        @[TLV::Field(tag: 3)]
        property link_frame_counter : UInt32
        @[TLV::Field(tag: 4)]
        property mle_frame_counter : UInt32
        @[TLV::Field(tag: 5)]
        property lqi : UInt8
        @[TLV::Field(tag: 6)]
        property average_rssi : Int8?
        @[TLV::Field(tag: 7)]
        property last_rssi : Int8?
        @[TLV::Field(tag: 8)]
        property frame_error_rate : UInt8
        @[TLV::Field(tag: 9)]
        property message_error_rate : UInt8
        @[TLV::Field(tag: 10)]
        property? rx_on_when_idle : Bool
        @[TLV::Field(tag: 11)]
        property? full_thread_device : Bool
        @[TLV::Field(tag: 12)]
        property? full_network_data : Bool
        @[TLV::Field(tag: 13)]
        property? is_child : Bool

        def initialize(@ext_address : UInt64, @age : UInt32, @rloc16 : UInt16,
                       @link_frame_counter : UInt32, @mle_frame_counter : UInt32,
                       @lqi : UInt8, @average_rssi : Int8?, @last_rssi : Int8?,
                       @frame_error_rate : UInt8, @message_error_rate : UInt8,
                       @rx_on_when_idle : Bool, @full_thread_device : Bool,
                       @full_network_data : Bool, @is_child : Bool)
          raise ArgumentError.new("Thread frame error rate exceeds 100") if @frame_error_rate > 100
          raise ArgumentError.new("Thread message error rate exceeds 100") if @message_error_rate > 100
          [@average_rssi, @last_rssi].each do |rssi|
            raise ArgumentError.new("Thread neighbor RSSI must be between -127 and 0") if rssi && (rssi < -127 || rssi > 0)
          end
        end
      end

      struct RouteTableStruct
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property ext_address : UInt64
        @[TLV::Field(tag: 1)]
        property rloc16 : UInt16
        @[TLV::Field(tag: 2)]
        property router_id : UInt8
        @[TLV::Field(tag: 3)]
        property next_hop : UInt8
        @[TLV::Field(tag: 4)]
        property path_cost : UInt8
        @[TLV::Field(tag: 5)]
        property lqi_in : UInt8
        @[TLV::Field(tag: 6)]
        property lqi_out : UInt8
        @[TLV::Field(tag: 7)]
        property age : UInt8
        @[TLV::Field(tag: 8)]
        property? allocated : Bool
        @[TLV::Field(tag: 9)]
        property? link_established : Bool

        def initialize(@ext_address : UInt64, @rloc16 : UInt16, @router_id : UInt8,
                       @next_hop : UInt8, @path_cost : UInt8, @lqi_in : UInt8,
                       @lqi_out : UInt8, @age : UInt8, @allocated : Bool,
                       @link_established : Bool)
        end
      end

      struct SecurityPolicyStruct
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property rotation_time : UInt16
        @[TLV::Field(tag: 1)]
        property flags : UInt16

        def initialize(@rotation_time : UInt16, @flags : UInt16)
        end
      end

      struct OperationalDatasetComponentsStruct
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property? active_timestamp_present : Bool
        @[TLV::Field(tag: 1)]
        property? pending_timestamp_present : Bool
        @[TLV::Field(tag: 2)]
        property? master_key_present : Bool
        @[TLV::Field(tag: 3)]
        property? network_name_present : Bool
        @[TLV::Field(tag: 4)]
        property? extended_pan_id_present : Bool
        @[TLV::Field(tag: 5)]
        property? mesh_local_prefix_present : Bool
        @[TLV::Field(tag: 6)]
        property? delay_present : Bool
        @[TLV::Field(tag: 7)]
        property? pan_id_present : Bool
        @[TLV::Field(tag: 8)]
        property? channel_present : Bool
        @[TLV::Field(tag: 9)]
        property? pskc_present : Bool
        @[TLV::Field(tag: 10)]
        property? security_policy_present : Bool
        @[TLV::Field(tag: 11)]
        property? channel_mask_present : Bool

        def initialize(@active_timestamp_present : Bool = false,
                       @pending_timestamp_present : Bool = false,
                       @master_key_present : Bool = false,
                       @network_name_present : Bool = false,
                       @extended_pan_id_present : Bool = false,
                       @mesh_local_prefix_present : Bool = false,
                       @delay_present : Bool = false,
                       @pan_id_present : Bool = false,
                       @channel_present : Bool = false,
                       @pskc_present : Bool = false,
                       @security_policy_present : Bool = false,
                       @channel_mask_present : Bool = false)
        end
      end

      struct ConnectionStatusEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property connection_status : ConnectionStatus

        def initialize(@connection_status : ConnectionStatus)
        end
      end

      struct NetworkFaultChangeEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property current : Array(NetworkFault)
        @[TLV::Field(tag: 1)]
        property previous : Array(NetworkFault)

        def initialize(@current : Array(NetworkFault), @previous : Array(NetworkFault))
          raise ArgumentError.new("Thread active faults exceed four entries") if @current.size > MAX_ACTIVE_FAULTS || @previous.size > MAX_ACTIVE_FAULTS
        end
      end

      attribute 0x0000, :channel, UInt16, nullable: true
      attribute 0x0001, :routing_role, RoutingRole, nullable: true
      attribute 0x0002, :network_name, String, nullable: true
      attribute 0x0003, :pan_id, UInt16, nullable: true
      attribute 0x0004, :extended_pan_id, UInt64, nullable: true
      attribute 0x0005, :mesh_local_prefix, Bytes, nullable: true
      attribute 0x0006, :overrun_count, UInt64, default: 0_u64,
        requires: :error_counts, omit_changes: true
      attribute 0x0007, :neighbor_table, Array(NeighborTableStruct),
        default: [] of NeighborTableStruct
      attribute 0x0008, :route_table, Array(RouteTableStruct),
        default: [] of RouteTableStruct
      attribute 0x0009, :partition_id, UInt32, nullable: true
      attribute 0x000A, :weighting, UInt16, nullable: true, max: 255_u16
      # Base#data_version is the cluster's IM version counter. Keep the Thread
      # dataset version in a separate backing field while retaining its wire ID.
      attribute 0x000B, :thread_data_version, UInt16, nullable: true, max: 255_u16
      ATTR_DATA_VERSION = ATTR_THREAD_DATA_VERSION
      attribute 0x000C, :stable_data_version, UInt16, nullable: true, max: 255_u16
      attribute 0x000D, :leader_router_id, UInt8, nullable: true, max: 62_u8

      attribute 0x000E, :detached_role_count, UInt16, default: 0_u16,
        requires: :mle_counts, omit_changes: true
      attribute 0x000F, :child_role_count, UInt16, default: 0_u16,
        requires: :mle_counts, omit_changes: true
      attribute 0x0010, :router_role_count, UInt16, default: 0_u16,
        requires: :mle_counts, omit_changes: true
      attribute 0x0011, :leader_role_count, UInt16, default: 0_u16,
        requires: :mle_counts, omit_changes: true
      attribute 0x0012, :attach_attempt_count, UInt16, default: 0_u16,
        requires: :mle_counts, omit_changes: true
      attribute 0x0013, :partition_id_change_count, UInt16, default: 0_u16,
        requires: :mle_counts, omit_changes: true
      attribute 0x0014, :better_partition_attach_attempt_count, UInt16, default: 0_u16,
        requires: :mle_counts, omit_changes: true
      attribute 0x0015, :parent_change_count, UInt16, default: 0_u16,
        requires: :mle_counts, omit_changes: true
      attribute 0x0016, :tx_total_count, UInt32, default: 0_u32,
        requires: :mac_counts, omit_changes: true
      attribute 0x0017, :tx_unicast_count, UInt32, default: 0_u32,
        requires: :mac_counts, omit_changes: true
      attribute 0x0018, :tx_broadcast_count, UInt32, default: 0_u32,
        requires: :mac_counts, omit_changes: true
      attribute 0x0019, :tx_ack_requested_count, UInt32, default: 0_u32,
        requires: :mac_counts, omit_changes: true
      attribute 0x001A, :tx_acked_count, UInt32, default: 0_u32,
        requires: :mac_counts, omit_changes: true
      attribute 0x001B, :tx_no_ack_requested_count, UInt32, default: 0_u32,
        requires: :mac_counts, omit_changes: true
      attribute 0x001C, :tx_data_count, UInt32, default: 0_u32,
        requires: :mac_counts, omit_changes: true
      attribute 0x001D, :tx_data_poll_count, UInt32, default: 0_u32,
        requires: :mac_counts, omit_changes: true
      attribute 0x001E, :tx_beacon_count, UInt32, default: 0_u32,
        requires: :mac_counts, omit_changes: true
      attribute 0x001F, :tx_beacon_request_count, UInt32, default: 0_u32,
        requires: :mac_counts, omit_changes: true
      attribute 0x0020, :tx_other_count, UInt32, default: 0_u32,
        requires: :mac_counts, omit_changes: true
      attribute 0x0021, :tx_retry_count, UInt32, default: 0_u32,
        requires: :mac_counts, omit_changes: true
      attribute 0x0022, :tx_direct_max_retry_expiry_count, UInt32, default: 0_u32,
        requires: :mac_counts, omit_changes: true
      attribute 0x0023, :tx_indirect_max_retry_expiry_count, UInt32, default: 0_u32,
        requires: :mac_counts, omit_changes: true
      attribute 0x0024, :tx_err_cca_count, UInt32, default: 0_u32,
        requires: :mac_counts, omit_changes: true
      attribute 0x0025, :tx_err_abort_count, UInt32, default: 0_u32,
        requires: :mac_counts, omit_changes: true
      attribute 0x0026, :tx_err_busy_channel_count, UInt32, default: 0_u32,
        requires: :mac_counts, omit_changes: true
      attribute 0x0027, :rx_total_count, UInt32, default: 0_u32,
        requires: :mac_counts, omit_changes: true
      attribute 0x0028, :rx_unicast_count, UInt32, default: 0_u32,
        requires: :mac_counts, omit_changes: true
      attribute 0x0029, :rx_broadcast_count, UInt32, default: 0_u32,
        requires: :mac_counts, omit_changes: true
      attribute 0x002A, :rx_data_count, UInt32, default: 0_u32,
        requires: :mac_counts, omit_changes: true
      attribute 0x002B, :rx_data_poll_count, UInt32, default: 0_u32,
        requires: :mac_counts, omit_changes: true
      attribute 0x002C, :rx_beacon_count, UInt32, default: 0_u32,
        requires: :mac_counts, omit_changes: true
      attribute 0x002D, :rx_beacon_request_count, UInt32, default: 0_u32,
        requires: :mac_counts, omit_changes: true
      attribute 0x002E, :rx_other_count, UInt32, default: 0_u32,
        requires: :mac_counts, omit_changes: true
      attribute 0x002F, :rx_address_filtered_count, UInt32, default: 0_u32,
        requires: :mac_counts, omit_changes: true
      attribute 0x0030, :rx_dest_addr_filtered_count, UInt32, default: 0_u32,
        requires: :mac_counts, omit_changes: true
      attribute 0x0031, :rx_duplicated_count, UInt32, default: 0_u32,
        requires: :mac_counts, omit_changes: true
      attribute 0x0032, :rx_err_no_frame_count, UInt32, default: 0_u32,
        requires: :mac_counts, omit_changes: true
      attribute 0x0033, :rx_err_unknown_neighbor_count, UInt32, default: 0_u32,
        requires: :mac_counts, omit_changes: true
      attribute 0x0034, :rx_err_invalid_src_addr_count, UInt32, default: 0_u32,
        requires: :mac_counts, omit_changes: true
      attribute 0x0035, :rx_err_sec_count, UInt32, default: 0_u32,
        requires: :mac_counts, omit_changes: true
      attribute 0x0036, :rx_err_fcs_count, UInt32, default: 0_u32,
        requires: :mac_counts, omit_changes: true
      attribute 0x0037, :rx_err_other_count, UInt32, default: 0_u32,
        requires: :mac_counts, omit_changes: true

      attribute 0x0038, :active_timestamp, UInt64, nullable: true,
        optional: true, present_if: :active_timestamp
      attribute 0x0039, :pending_timestamp, UInt64, nullable: true,
        optional: true, present_if: :pending_timestamp
      attribute 0x003A, :delay, UInt32, nullable: true,
        optional: true, present_if: :delay
      attribute 0x003B, :security_policy, SecurityPolicyStruct, nullable: true
      attribute 0x003C, :channel_page0_mask, Bytes, nullable: true
      attribute 0x003D, :operational_dataset_components,
        OperationalDatasetComponentsStruct, nullable: true
      attribute 0x003E, :active_network_faults_list, Array(NetworkFault),
        default: [] of NetworkFault
      attribute 0x003F, :ext_address, UInt64, nullable: true,
        optional: true, present_if: :ext_address
      attribute 0x0040, :rloc16, UInt16, nullable: true,
        optional: true, present_if: :rloc16

      event 0x0000, :connection_status, priority: :info
      event 0x0001, :network_fault_change, priority: :info
      command 0x0000, :reset_counts, requires: :error_counts, access: :manage

      def update_network_name(value : String?) : Nil
        if value && value.bytesize > MAX_NETWORK_NAME_BYTES
          raise ArgumentError.new("Thread network name exceeds #{MAX_NETWORK_NAME_BYTES} bytes")
        end
        self.network_name = value
      end

      def update_mesh_local_prefix(value : Bytes?) : Nil
        if value && value.size > MAX_MESH_PREFIX_BYTES
          raise ArgumentError.new("Thread mesh-local prefix exceeds #{MAX_MESH_PREFIX_BYTES} bytes")
        end
        self.mesh_local_prefix = value.try(&.dup)
      end

      def update_channel_page0_mask(value : Bytes?) : Nil
        if value && value.size != CHANNEL_MASK_BYTES
          raise ArgumentError.new("Thread channel mask must contain #{CHANNEL_MASK_BYTES} bytes")
        end
        self.channel_page0_mask = value.try(&.dup)
      end

      def update_neighbor_table(value : Array(NeighborTableStruct)) : Nil
        self.neighbor_table = value.dup
      end

      def update_route_table(value : Array(RouteTableStruct)) : Nil
        self.route_table = value.dup
      end

      def update_active_network_faults(value : Array(NetworkFault)) : Nil
        raise ArgumentError.new("Thread active faults exceed four entries") if value.size > MAX_ACTIVE_FAULTS
        self.active_network_faults_list = value.dup
      end

      def record_overrun : Nil
        @overrun_count = @overrun_count &+ 1_u64
      end

      def record_detached_role : Nil
        @detached_role_count = @detached_role_count &+ 1_u16
      end

      def record_tx_total : Nil
        @tx_total_count = @tx_total_count &+ 1_u32
      end

      def reset_counts : InteractionModel::Status
        @overrun_count = 0_u64
        @detached_role_count = 0_u16
        @child_role_count = 0_u16
        @router_role_count = 0_u16
        @leader_role_count = 0_u16
        @attach_attempt_count = 0_u16
        @partition_id_change_count = 0_u16
        @better_partition_attach_attempt_count = 0_u16
        @parent_change_count = 0_u16
        @tx_total_count = 0_u32
        @tx_unicast_count = 0_u32
        @tx_broadcast_count = 0_u32
        @tx_ack_requested_count = 0_u32
        @tx_acked_count = 0_u32
        @tx_no_ack_requested_count = 0_u32
        @tx_data_count = 0_u32
        @tx_data_poll_count = 0_u32
        @tx_beacon_count = 0_u32
        @tx_beacon_request_count = 0_u32
        @tx_other_count = 0_u32
        @tx_retry_count = 0_u32
        @tx_direct_max_retry_expiry_count = 0_u32
        @tx_indirect_max_retry_expiry_count = 0_u32
        @tx_err_cca_count = 0_u32
        @tx_err_abort_count = 0_u32
        @tx_err_busy_channel_count = 0_u32
        @rx_total_count = 0_u32
        @rx_unicast_count = 0_u32
        @rx_broadcast_count = 0_u32
        @rx_data_count = 0_u32
        @rx_data_poll_count = 0_u32
        @rx_beacon_count = 0_u32
        @rx_beacon_request_count = 0_u32
        @rx_other_count = 0_u32
        @rx_address_filtered_count = 0_u32
        @rx_dest_addr_filtered_count = 0_u32
        @rx_duplicated_count = 0_u32
        @rx_err_no_frame_count = 0_u32
        @rx_err_unknown_neighbor_count = 0_u32
        @rx_err_invalid_src_addr_count = 0_u32
        @rx_err_sec_count = 0_u32
        @rx_err_fcs_count = 0_u32
        @rx_err_other_count = 0_u32
        InteractionModel::Status.success
      end

      def emit_connection_status(status : ConnectionStatus) : Bytes
        payload = ConnectionStatusEvent.new(status)
        emit_event(EVENT_CONNECTION_STATUS, payload)
        payload.to_slice
      end

      def emit_network_fault_change(current : Array(NetworkFault),
                                    previous : Array(NetworkFault)) : Bytes
        payload = NetworkFaultChangeEvent.new(current.dup, previous.dup)
        emit_event(EVENT_NETWORK_FAULT_CHANGE, payload)
        payload.to_slice
      end
    end
  end
end
