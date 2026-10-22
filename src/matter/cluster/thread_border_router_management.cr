require "./cluster"
require "./general_commissioning"
require "log"
require "set"

module Matter
  module Cluster
    # Opt-in Matter 1.6 Thread Border Router Management server (0x0452).
    # The host owns the Thread stack and all dataset secrets. This cluster
    # validates requests and publishes host state, but never persists a dataset.
    class ThreadBorderRouterManagement < Base
      Log = ::Log.for("matter.cluster.thread_border_router_management")
      cluster 0x0452, revision: 1, persist_state: false
      feature :pan_change, bit: 0

      MAX_DATASET_SIZE       =  254
      MAX_ROUTER_NAME_BYTES  =   63
      BORDER_AGENT_ID_LENGTH =   16
      MAX_NETWORK_NAME_BYTES =   16
      THREAD_TLV_HEADER_SIZE =    2
      EXTENDED_TLV_LENGTH    =  255
      CHANNEL_PAGE_ZERO      = 0_u8

      enum DatasetType : UInt8
        Channel          =  0
        PanId            =  1
        ExtendedPanId    =  2
        NetworkName      =  3
        Pskc             =  4
        NetworkKey       =  5
        MeshLocalPrefix  =  7
        SecurityPolicy   = 12
        ActiveTimestamp  = 14
        PendingTimestamp = 51
        DelayTimer       = 52
        ChannelMask      = 53
      end

      # A concrete backend must wait for real Thread activation before
      # returning true and implement rollback of its durable Thread state.
      # Calls may overlap with fail-safe expiry; backend operations must be
      # synchronized by the host when its Thread stack is multithreaded.
      abstract class Backend
        abstract def border_router_name : String
        abstract def border_agent_id : Bytes
        abstract def thread_version : UInt16
        abstract def interface_enabled? : Bool
        abstract def active_dataset : Bytes?
        abstract def pending_dataset : Bytes?
        # Validate radio/channel/security-policy details against the host's
        # Thread stack (for OpenThread, otDatasetIsValid).
        abstract def valid_dataset?(dataset : Bytes, pending : Bool) : Bool
        abstract def activate_active_dataset(dataset : Bytes, deadline : Time::Span) : Bool
        abstract def apply_pending_dataset(dataset : Bytes) : Bool
        abstract def restore(active : Bytes?, pending : Bytes?, interface_enabled : Bool) : Nil
      end

      struct DatasetResponse
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter dataset : Bytes

        def initialize(@dataset : Bytes)
        end
      end

      struct SetActiveDatasetRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter active_dataset : Bytes

        @[TLV::Field(tag: 1, optional: true)]
        getter breadcrumb : UInt64?

        def initialize(@active_dataset : Bytes, @breadcrumb : UInt64? = nil)
        end
      end

      struct SetPendingDatasetRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter pending_dataset : Bytes

        def initialize(@pending_dataset : Bytes)
        end
      end

      private record Snapshot, active : Bytes?, pending : Bytes?, interface_enabled : Bool

      attribute 0x0000, :border_router_name, String, computed: true
      attribute 0x0001, :border_agent_id, Bytes, computed: true
      attribute 0x0002, :thread_version, UInt16, computed: true, fixed: true
      attribute 0x0003, :interface_enabled, Bool, default: false
      attribute 0x0004, :active_dataset_timestamp, UInt64, nullable: true
      attribute 0x0005, :pending_dataset_timestamp, UInt64, nullable: true

      command 0x00, :get_active_dataset_request, response: DatasetResponse,
        response_id: 0x02, access: :manage, handler: :handle_get_active_dataset_request
      command 0x01, :get_pending_dataset_request, response: DatasetResponse,
        response_id: 0x02, access: :manage, handler: :handle_get_pending_dataset_request
      command 0x03, :set_active_dataset_request, request: SetActiveDatasetRequest,
        timed: true, access: :manage, handler: :handle_set_active_dataset_request
      command 0x04, :set_pending_dataset_request, request: SetPendingDatasetRequest,
        timed: true, access: :manage, requires: :pan_change, handler: :handle_set_pending_dataset_request

      @activation_in_progress = false
      @snapshot : Snapshot? = nil
      @state_mutex = Mutex.new
      @reported_name : String? = nil
      @reported_agent_id : Bytes? = nil

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @backend : Backend,
                     @general_commissioning : GeneralCommissioning,
                     @feature_map : Feature = Feature::None)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        validate_identity!
        refresh_host_state
        register_failsafe_hooks
      end

      def border_router_name : String
        @backend.border_router_name
      end

      def border_agent_id : Bytes
        @backend.border_agent_id.dup
      end

      def thread_version : UInt16
        @backend.thread_version
      end

      # Hosts call this after external Thread state changes so subscriptions
      # receive the changed InterfaceEnabled and timestamp attributes.
      def refresh_host_state : Nil
        validate_identity!
        name = @backend.border_router_name
        agent_id = @backend.border_agent_id
        active = @backend.active_dataset
        pending = @backend.pending_dataset
        active_timestamp = active ? parse_dataset_timestamp(active, pending: false) : nil
        pending_timestamp = pending ? parse_dataset_timestamp(pending, pending: true) : nil
        raise ConfigurationError.new("Host supplied invalid active Thread dataset") if active && !valid_dataset?(active, pending: false)
        raise ConfigurationError.new("Host supplied invalid pending Thread dataset") if pending && !valid_dataset?(pending, pending: true)
        if @reported_name != name
          @reported_name = name.dup
          increment_version_and_notify(ATTR_BORDER_ROUTER_NAME)
        end
        if @reported_agent_id != agent_id
          @reported_agent_id = agent_id.dup
          increment_version_and_notify(ATTR_BORDER_AGENT_ID)
        end
        self.interface_enabled = @backend.interface_enabled?
        self.active_dataset_timestamp = active_timestamp
        self.pending_dataset_timestamp = pending_timestamp
      end

      def handle_get_active_dataset_request : DatasetResponse | InteractionModel::Status
        return InteractionModel::Status.unsupported_access unless request_is_case_session?
        dataset = @backend.active_dataset
        return InteractionModel::Status.failure if dataset && !valid_dataset?(dataset, pending: false)
        DatasetResponse.new(dataset ? dataset.dup : Bytes.empty)
      rescue ex
        Log.error(exception: ex) { "Thread active dataset read failed" }
        InteractionModel::Status.failure
      end

      def handle_get_pending_dataset_request : DatasetResponse | InteractionModel::Status
        return InteractionModel::Status.unsupported_access unless request_is_case_session?
        dataset = @backend.pending_dataset
        return InteractionModel::Status.failure if dataset && !valid_dataset?(dataset, pending: true)
        DatasetResponse.new(dataset ? dataset.dup : Bytes.empty)
      rescue ex
        Log.error(exception: ex) { "Thread pending dataset read failed" }
        InteractionModel::Status.failure
      end

      def handle_set_active_dataset_request(request : SetActiveDatasetRequest) : InteractionModel::Status
        return InteractionModel::Status.unsupported_access unless request_is_case_session?
        return InteractionModel::Status.busy if @state_mutex.synchronize { @activation_in_progress }
        context = @general_commissioning.failsafe_context
        return InteractionModel::Status.failsafe_required unless context && context.armed?
        # The active administrator alone may use the armed context.
        return InteractionModel::Status.unsupported_access unless context.matches_fabric?(request_fabric_index)
        return InteractionModel::Status.invalid_command unless valid_dataset?(request.active_dataset, pending: false)

        acquired = @state_mutex.synchronize do
          if @activation_in_progress
            false
          else
            @activation_in_progress = true
            true
          end
        end
        return InteractionModel::Status.busy unless acquired

        begin
          return InteractionModel::Status.invalid_in_state if @backend.active_dataset
          remaining = context.primary_time_remaining
          return InteractionModel::Status.timeout unless remaining && remaining > Time::Span.zero
          cumulative = context.cumulative_time_remaining
          remaining = cumulative if cumulative && cumulative < remaining
          started = Time.instant
          snapshot = Snapshot.new(@backend.active_dataset.try(&.dup),
            @backend.pending_dataset.try(&.dup), @backend.interface_enabled?)
          @snapshot = snapshot
          activated = @backend.activate_active_dataset(request.active_dataset.dup, remaining)
          unless context.armed? && Time.instant - started < remaining
            rollback(snapshot)
            return InteractionModel::Status.timeout
          end
          unless activated && @backend.active_dataset == request.active_dataset && @backend.interface_enabled?
            rollback(snapshot)
            return InteractionModel::Status.failure
          end
          refresh_host_state
          if breadcrumb = request.breadcrumb
            @general_commissioning.breadcrumb = breadcrumb
          end
          InteractionModel::Status.success
        rescue ex
          Log.error(exception: ex) { "Thread active dataset activation failed" }
          rollback(snapshot) if snapshot
          InteractionModel::Status.failure
        ensure
          @state_mutex.synchronize { @activation_in_progress = false }
        end
      rescue ex
        Log.error(exception: ex) { "Thread active dataset validation failed" }
        InteractionModel::Status.failure
      end

      def handle_set_pending_dataset_request(request : SetPendingDatasetRequest) : InteractionModel::Status
        return InteractionModel::Status.unsupported_access unless request_is_case_session?
        return InteractionModel::Status.invalid_command unless valid_dataset?(request.pending_dataset, pending: true)
        snapshot = Snapshot.new(@backend.active_dataset.try(&.dup),
          @backend.pending_dataset.try(&.dup), @backend.interface_enabled?)
        unless @backend.apply_pending_dataset(request.pending_dataset.dup) &&
               @backend.pending_dataset == request.pending_dataset
          rollback(snapshot, clear_snapshot: false)
          return InteractionModel::Status.failure
        end
        refresh_host_state
        InteractionModel::Status.success
      rescue ex
        Log.error(exception: ex) { "Thread pending dataset update failed" }
        rollback(snapshot, clear_snapshot: false) if snapshot
        InteractionModel::Status.failure
      end

      private def validate_identity! : Nil
        name = @backend.border_router_name
        unless name.bytesize.in?(1..MAX_ROUTER_NAME_BYTES) && name.valid_encoding?
          raise ConfigurationError.new("Thread Border Router name must contain 1–63 UTF-8 bytes")
        end
        unless @backend.border_agent_id.size == BORDER_AGENT_ID_LENGTH
          raise ConfigurationError.new("Thread Border Agent ID must be 16 bytes")
        end
      end

      private def register_failsafe_hooks : Nil
        previous_armed = @general_commissioning.on_failsafe_armed
        previous_expiry = @general_commissioning.on_failsafe_expired
        previous_success = @general_commissioning.on_failsafe_success
        @general_commissioning.on_failsafe_armed = -> {
          @snapshot = nil
          previous_armed.try(&.call)
        }
        @general_commissioning.on_failsafe_expired = -> {
          if snapshot = @snapshot
            rollback(snapshot)
          end
          previous_expiry.try(&.call)
        }
        @general_commissioning.on_failsafe_success = -> {
          @snapshot = nil
          previous_success.try(&.call)
        }
      end

      private def rollback(snapshot : Snapshot, clear_snapshot : Bool = true) : Nil
        @backend.restore(snapshot.active.try(&.dup), snapshot.pending.try(&.dup), snapshot.interface_enabled)
        @snapshot = nil if clear_snapshot
        refresh_host_state
      rescue ex
        Log.error(exception: ex) { "Thread dataset rollback failed" }
        @snapshot = nil if clear_snapshot
      end

      private def valid_dataset?(dataset : Bytes, pending : Bool) : Bool
        !!parse_dataset_timestamp(dataset, pending) && @backend.valid_dataset?(dataset, pending)
      end

      # Thread datasets use their own type/length/value encoding, not Matter
      # TLV. OpenThread's otDatasetIsValid contract requires all Active Dataset
      # TLVs in a Pending Dataset, plus Pending Timestamp and Delay Timer.
      # Unknown TLV types remain valid.
      private def parse_dataset_timestamp(dataset : Bytes, pending : Bool) : UInt64?
        return if dataset.empty? || dataset.size > MAX_DATASET_SIZE
        fields = {} of DatasetType => Bytes
        seen_types = Set(UInt8).new
        offset = 0
        while offset < dataset.size
          return if offset + THREAD_TLV_HEADER_SIZE > dataset.size
          raw_type = dataset[offset]
          return if seen_types.includes?(raw_type)
          seen_types << raw_type
          type = DatasetType.from_value?(raw_type)
          length = dataset[offset + 1].to_i
          offset += THREAD_TLV_HEADER_SIZE
          return if length == EXTENDED_TLV_LENGTH || offset + length > dataset.size
          if type
            fields[type] = dataset[offset, length]
          end
          offset += length
        end
        REQUIRED_LENGTHS.each do |required_type, expected|
          value = fields[required_type]?
          return unless value && value.size == expected
        end
        name = fields[DatasetType::NetworkName]?
        return unless name && name.size.in?(1..MAX_NETWORK_NAME_BYTES) && String.new(name).valid_encoding?
        channel = fields[DatasetType::Channel]?
        return unless channel && channel[0] == CHANNEL_PAGE_ZERO
        channel_mask = fields[DatasetType::ChannelMask]?
        return unless channel_mask
        return if channel_mask.empty?
        if pending
          timestamp = fields[DatasetType::PendingTimestamp]?
          delay = fields[DatasetType::DelayTimer]?
          return unless timestamp && timestamp.size == 8 && delay && delay.size == 4
        end
        timestamp = fields[pending ? DatasetType::PendingTimestamp : DatasetType::ActiveTimestamp]
        timestamp.reduce(0_u64) { |value, byte| (value << 8) | byte.to_u64 }
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
