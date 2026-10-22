require "./cluster"

module Matter
  module Cluster
    # Matter 1.6 Thread Network Directory (0x0453). One endpoint-wide directory
    # is shared by all authorized fabrics. The host must opt in on a Network
    # Infrastructure Manager or Thread Border Router endpoint and protect its
    # storage, since datasets contain the Thread Network Key and PSKc.
    class ThreadNetworkDirectory < Base
      cluster 0x0453, revision: 1, persist_state: false

      DEFAULT_TABLE_SIZE     = 32_u8
      MAX_DATASET_SIZE       =   254
      EXTENDED_PAN_ID_LENGTH =     8
      MAX_NETWORK_NAME_BYTES =    16

      enum DatasetType : UInt8
        Channel         =  0
        PanId           =  1
        ExtendedPanId   =  2
        NetworkName     =  3
        Pskc            =  4
        NetworkKey      =  5
        MeshLocalPrefix =  7
        SecurityPolicy  = 12
        ActiveTimestamp = 14
        ChannelMask     = 53
      end

      struct ThreadNetworkStruct
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        getter extended_pan_id : Bytes
        @[TLV::Field(tag: 1)]
        getter network_name : String
        @[TLV::Field(tag: 2)]
        getter channel : UInt16
        @[TLV::Field(tag: 3)]
        getter active_timestamp : UInt64

        def initialize(@extended_pan_id : Bytes, @network_name : String,
                       @channel : UInt16, @active_timestamp : UInt64)
        end
      end

      struct AddNetworkRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter operational_dataset : Bytes

        def initialize(@operational_dataset : Bytes)
        end
      end

      struct ExtendedPanIdRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter extended_pan_id : Bytes

        def initialize(@extended_pan_id : Bytes)
        end
      end

      struct OperationalDatasetResponse
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter operational_dataset : Bytes

        def initialize(@operational_dataset : Bytes)
        end
      end

      struct StoredNetwork
        include Storage::Record

        getter network : ThreadNetworkStruct
        getter operational_dataset : Bytes

        def initialize(@network : ThreadNetworkStruct, @operational_dataset : Bytes)
        end
      end

      struct PersistedState
        include Storage::Record

        getter data_version : UInt32
        getter preferred_extended_pan_id : Bytes?
        getter networks : Array(StoredNetwork)

        def initialize(@data_version, @preferred_extended_pan_id, @networks)
        end
      end

      attribute 0x0000, :preferred_extended_pan_id, Bytes, nullable: true,
        computed: true, writable: true, write_access: :manage
      attribute 0x0001, :thread_networks, Array(ThreadNetworkStruct), computed: true
      attribute 0x0002, :thread_network_table_size, UInt8, computed: true, fixed: true

      command 0x00, :add_network, request: AddNetworkRequest, timed: true, access: :manage
      command 0x01, :remove_network, request: ExtendedPanIdRequest, timed: true, access: :manage
      command 0x02, :get_operational_dataset, request: ExtendedPanIdRequest,
        response: OperationalDatasetResponse, response_id: 0x03, access: :manage

      @preferred_extended_pan_id : Bytes? = nil
      @networks = [] of StoredNetwork

      getter thread_network_table_size : UInt8

      def initialize(endpoint_id : DataType::EndpointNumber,
                     table_size : UInt8 = DEFAULT_TABLE_SIZE,
                     supported_fabrics : UInt8 = FabricTable::DEFAULT_MAX_FABRICS)
        raise ConfigurationError.new("SupportedFabrics must meet Matter's minimum") if supported_fabrics < FabricTable::MIN_MAX_FABRICS
        raise ConfigurationError.new("Thread Network Directory capacity must be at least twice SupportedFabrics") if table_size.to_i < supported_fabrics.to_i * 2
        @thread_network_table_size = table_size
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
      end

      def preferred_extended_pan_id : Bytes?
        @preferred_extended_pan_id.try(&.dup)
      end

      def preferred_extended_pan_id=(value : Bytes?) : Nil
        value = nil if value && value.empty?
        if value && (value.size != EXTENDED_PAN_ID_LENGTH || !@networks.any? { |entry| entry.network.extended_pan_id == value })
          raise ClusterError.new("Preferred Extended PAN ID must identify a stored network", InteractionModel::StatusCode::ConstraintError)
        end
        return if @preferred_extended_pan_id == value
        @preferred_extended_pan_id = value.try(&.dup)
        increment_version_and_notify(ATTR_PREFERRED_EXTENDED_PAN_ID)
      end

      def thread_networks : Array(ThreadNetworkStruct)
        @networks.map do |entry|
          network = entry.network
          ThreadNetworkStruct.new(network.extended_pan_id.dup, network.network_name.dup,
            network.channel, network.active_timestamp)
        end
      end

      def add_network(request : AddNetworkRequest) : InteractionModel::Status
        dataset = request.operational_dataset
        network = parse_dataset(dataset)
        return InteractionModel::Status.constraint_error unless network

        index = @networks.index { |entry| entry.network.extended_pan_id == network.extended_pan_id }
        if index
          return InteractionModel::Status.invalid_in_state if network.active_timestamp <= @networks[index].network.active_timestamp
          @networks[index] = StoredNetwork.new(network, dataset.dup)
        else
          return InteractionModel::Status.resource_exhausted if @networks.size >= @thread_network_table_size
          @networks << StoredNetwork.new(network, dataset.dup)
        end
        increment_version_and_notify(ATTR_THREAD_NETWORKS)
        InteractionModel::Status.success
      end

      def remove_network(request : ExtendedPanIdRequest) : InteractionModel::Status
        id = request.extended_pan_id
        return InteractionModel::Status.constraint_error unless id.size == EXTENDED_PAN_ID_LENGTH
        index = @networks.index { |entry| entry.network.extended_pan_id == id }
        return InteractionModel::Status.not_found unless index
        return InteractionModel::Status.constraint_error if @preferred_extended_pan_id == id
        @networks.delete_at(index)
        increment_version_and_notify(ATTR_THREAD_NETWORKS)
        InteractionModel::Status.success
      end

      def get_operational_dataset(request : ExtendedPanIdRequest) : OperationalDatasetResponse | InteractionModel::Status
        return InteractionModel::Status.unsupported_access unless request_is_case_session?
        id = request.extended_pan_id
        return InteractionModel::Status.constraint_error unless id.size == EXTENDED_PAN_ID_LENGTH
        entry = @networks.find { |stored| stored.network.extended_pan_id == id }
        return InteractionModel::Status.not_found unless entry
        OperationalDatasetResponse.new(entry.operational_dataset.dup)
      end

      # Device factory reset also erases its Storage::Backend; this method lets
      # a host reset the cluster explicitly before recycling the endpoint.
      def factory_reset : Nil
        return if @networks.empty? && @preferred_extended_pan_id.nil?
        @networks.clear
        @preferred_extended_pan_id = nil
        increment_version_and_notify(ATTR_THREAD_NETWORKS)
        notify_changed(ATTR_PREFERRED_EXTENDED_PAN_ID)
      end

      def save_state : Storage::Document?
        PersistedState.new(@data_version, @preferred_extended_pan_id, @networks).to_document
      end

      def restore_state(document : Storage::Document) : Nil
        state = PersistedState.from_document(document)
        raise StorageError.new("Thread Network Directory exceeds table capacity") if state.networks.size > @thread_network_table_size
        ids = [] of Bytes
        state.networks.each do |entry|
          parsed = parse_dataset(entry.operational_dataset) || raise StorageError.new("Invalid persisted Thread Operational Dataset")
          if parsed.extended_pan_id != entry.network.extended_pan_id ||
             parsed.network_name != entry.network.network_name ||
             parsed.channel != entry.network.channel ||
             parsed.active_timestamp != entry.network.active_timestamp ||
             ids.includes?(parsed.extended_pan_id)
            raise StorageError.new("Invalid persisted Thread Operational Dataset")
          end
          ids << parsed.extended_pan_id
        end
        preferred = state.preferred_extended_pan_id
        raise StorageError.new("Preferred Thread network missing from persisted directory") if preferred && !ids.includes?(preferred)
        @networks = state.networks
        @preferred_extended_pan_id = preferred
        @data_version = state.data_version
      end

      # Thread Operational Dataset uses its own type/length/value format,
      # independent of Matter TLV. Unknown types are allowed for future Thread
      # extensions; known types must occur once with their required lengths.
      private def parse_dataset(dataset : Bytes) : ThreadNetworkStruct?
        return if dataset.empty? || dataset.size > MAX_DATASET_SIZE
        fields = {} of DatasetType => Bytes
        offset = 0
        while offset < dataset.size
          return if offset + 2 > dataset.size
          type = DatasetType.from_value?(dataset[offset])
          length = dataset[offset + 1].to_i
          offset += 2
          return if length == 255 || offset + length > dataset.size
          if type
            return if fields.has_key?(type)
            fields[type] = dataset[offset, length]
          end
          offset += length
        end

        REQUIRED_LENGTHS.each do |required_type, expected|
          value = fields[required_type]?
          return unless value && value.size == expected
        end
        channel_mask = fields[DatasetType::ChannelMask]?
        return unless channel_mask && channel_mask.size > 0
        name_bytes = fields[DatasetType::NetworkName]?
        return unless name_bytes && name_bytes.size.in?(1..MAX_NETWORK_NAME_BYTES)
        name = String.new(name_bytes)
        return unless name.valid_encoding?
        channel_bytes = fields[DatasetType::Channel]
        return unless channel_bytes[0] == 0_u8
        channel = (channel_bytes[1].to_u16 << 8) | channel_bytes[2].to_u16
        timestamp = 0_u64
        fields[DatasetType::ActiveTimestamp].each { |byte| timestamp = (timestamp << 8) | byte.to_u64 }
        ThreadNetworkStruct.new(fields[DatasetType::ExtendedPanId].dup, name, channel, timestamp)
      end

      REQUIRED_LENGTHS = {
        DatasetType::ActiveTimestamp => 8,
        DatasetType::Channel         => 3,
        DatasetType::ExtendedPanId   => 8,
        DatasetType::NetworkKey      => 16,
        DatasetType::MeshLocalPrefix => 8,
        DatasetType::PanId           => 2,
        DatasetType::Pskc            => 16,
        DatasetType::SecurityPolicy  => 4,
      }
    end
  end
end
