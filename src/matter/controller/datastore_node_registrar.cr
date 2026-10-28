require "log"
require "../cluster/joint_fabric_datastore"
require "./im_client"
require "./operational_peer_resolver"
require "./pairing/case_pairing"
require "./state_store"
require "./joint_fabric_peer_authentication"

module Matter
  module Controller
    # Opt-in Joint Fabric Datastore lifecycle for a newly commissioned device.
    # Each network operation is retried from a durable controller-state journal.
    class DatastoreNodeRegistrar
      Log                    = ::Log.for("matter.controller.datastore_node_registrar")
      alias Datastore = Cluster::JointFabricDatastore
      DEFAULT_RETRY_INTERVAL = 30.seconds

      abstract class Delivery
        abstract def add_pending_node(fabric : FabricInfo, node_id : UInt64, friendly_name : String) : Nil
        abstract def refresh_node(fabric : FabricInfo, node_id : UInt64) : Nil
        abstract def remove_node(fabric : FabricInfo, node_id : UInt64, friendly_name : String) : Nil
      end

      # Sends the lifecycle commands to the Anchor's Datastore over CASE.
      # NodeList reads make retries safe after a lost invoke response.
      class NetworkDelivery < Delivery
        def initialize(@store : StateStore, @client : Client, @anchor_node_id : UInt64,
                       @datastore_endpoint : UInt16, @timeout : Time::Span = 15.seconds,
                       @crypto : Crypto::CryptoBase = Crypto::StandardCrypto.new)
        end

        def add_pending_node(fabric : FabricInfo, node_id : UInt64, friendly_name : String) : Nil
          with_datastore(fabric) do |interaction, session, peer|
            if entry = find_node(interaction, session, peer, node_id)
              unless entry.friendly_name == friendly_name && pending_node?(entry)
                raise Matter::CommissioningError.new("Datastore Node ID already belongs to a different or completed registration")
              end
              next
            end
            invoke(interaction, session, peer, Datastore::CMD_ADD_PENDING_NODE,
              Datastore::AddPendingNodeRequest.new(node_id, friendly_name).to_slice)
          end
        end

        def refresh_node(fabric : FabricInfo, node_id : UInt64) : Nil
          with_datastore(fabric) do |interaction, session, peer|
            unless find_node(interaction, session, peer, node_id)
              raise Matter::CommissioningError.new("Datastore pending Node ID is missing before RefreshNode")
            end
            invoke(interaction, session, peer, Datastore::CMD_REFRESH_NODE,
              Datastore::RefreshNodeRequest.new(node_id).to_slice)
          end
        end

        def remove_node(fabric : FabricInfo, node_id : UInt64, friendly_name : String) : Nil
          with_datastore(fabric) do |interaction, session, peer|
            entry = find_node(interaction, session, peer, node_id)
            next unless entry
            unless entry.friendly_name == friendly_name && pending_node?(entry)
              raise Matter::CommissioningError.new("Refusing to remove a different or completed Datastore node")
            end
            invoke(interaction, session, peer, Datastore::CMD_REMOVE_NODE,
              Datastore::RemoveNodeRequest.new(node_id).to_slice)
          end
        end

        protected def with_datastore(fabric : FabricInfo, & : ImClient, Session::SecureContext, Socket::IPAddress ->) : Nil
          state = @store.load
          installed = state.fabric_for(fabric.fabric_id, fabric.root_public_key, fabric.controller_node_id)
          node = state.nodes_for(installed.fabric_id, installed.root_public_key, installed.controller_node_id)[@anchor_node_id]? ||
                 raise Matter::ConfigurationError.new("Anchor Administrator is absent from controller state")
          address = node.address || raise Matter::ConfigurationError.new("Anchor Administrator address is missing")
          peer = Socket::IPAddress.new(address, node.port)
          session = Pairing::CasePairing.new(@crypto).pair(@client, peer, installed,
            peer_node_id: @anchor_node_id, timeout: @timeout)
          JointFabricPeerAuthentication.verify_anchor!(session,
            installed.root_cert, installed.fabric_id)
          yield ImClient.new(@client, @timeout), session, peer
        end

        private def pending_node?(entry : Datastore::DatastoreNodeInformationEntryStruct) : Bool
          entry.commissioning_status_entry.state.in?(Datastore::DatastoreStateEnum::Pending,
            Datastore::DatastoreStateEnum::CommitFailed)
        end

        private def find_node(im : ImClient, session : Session::SecureContext,
                              peer : Socket::IPAddress, node_id : UInt64) : Datastore::DatastoreNodeInformationEntryStruct?
          report = im.read_attribute(session: session, peer: peer,
            endpoint_id: @datastore_endpoint, cluster_id: Datastore::CLUSTER_ID,
            attribute_id: Datastore::ATTR_NODE_LIST)
          data = report.attribute_reports.try(&.find(&.attribute_data)).try(&.attribute_data).try(&.data) ||
                 raise Matter::ProtocolError.new("Datastore NodeList read omitted data")
          Array(Datastore::DatastoreNodeInformationEntryStruct).from_tlv(data.to_slice).find(&.node_id.==(node_id))
        end

        private def invoke(im : ImClient, session : Session::SecureContext, peer : Socket::IPAddress,
                           command_id : UInt32, fields : Bytes) : Nil
          response = im.invoke(session: session, peer: peer,
            endpoint_id: @datastore_endpoint, cluster_id: Datastore::CLUSTER_ID,
            command_id: command_id, fields: fields)
          status = response.invoke_responses.compact_map(&.command_status).first?
          unless status && status.status.status == InteractionModel::StatusCode::Success.value
            raise Matter::CommissioningError.new("Datastore command 0x#{command_id.to_s(16)} failed (status=#{status.try(&.status.status)})")
          end
        end
      end

      @retry_running = false
      @retry_owners = 0
      @retry_done : Channel(Nil)?
      @retry_wake : Channel(Nil)?
      @retry_lifecycle_lock = Mutex.new
      @operation_lock = Mutex.new

      def initialize(@store : StateStore, @delivery : Delivery,
                     @retry_interval : Time::Span = DEFAULT_RETRY_INTERVAL)
        raise Matter::ConfigurationError.new("Datastore retry interval must be positive") unless @retry_interval > Time::Span.zero
      end

      # A long-lived commissioner starts this on construction, including after
      # restart. Each pass reads the durable journal, so a failed delivery is
      # retried without keeping an in-memory copy of the pending operation.
      def start_retrying : Nil
        @retry_lifecycle_lock.synchronize { start_retrying_unlocked }
      end

      private def start_retrying_unlocked : Nil
        @retry_owners += 1
        return if @retry_running
        return if (done = @retry_done) && !done.closed?
        @retry_running = true
        done = Channel(Nil).new
        wake = Channel(Nil).new
        @retry_done = done
        @retry_wake = wake
        spawn do
          while @retry_running
            begin
              retry_pending_once
            rescue ex
              Log.warn(exception: ex) { "Datastore registration retry pass failed" }
            end
            if @retry_running
              select
              when wake.receive?
                break
              when timeout(@retry_interval)
              end
            end
          end
        ensure
          done.close
        end
      end

      def stop_retrying : Nil
        @retry_lifecycle_lock.synchronize { stop_retrying_unlocked }
      end

      private def stop_retrying_unlocked : Nil
        return if @retry_owners == 0
        @retry_owners -= 1
        return unless @retry_owners == 0
        @retry_running = false
        @retry_wake.try do |wake|
          wake.close unless wake.closed?
        end
        @retry_done.try(&.receive?)
        @retry_done = nil
        @retry_wake = nil
      end

      # Run each persisted operation independently. One offline fabric must not
      # block delivery for another; an ambiguous Completing stage is reported
      # and retained for authenticated operator reconciliation.
      def retry_pending_once(now_unix : Int64 = Time.utc.to_unix) : Nil
        state = @store.load
        state.pending_datastore_nodes.each do |saved|
          @operation_lock.synchronize do
            latest = @store.load
            fabric = latest.fabric_for(saved.fabric_id, saved.root_public_key, saved.controller_node_id)
            current = entry_for(latest, fabric, saved.node_id)
            resume_entry(fabric, current, now_unix) if current
          end
        rescue ex
          Log.warn(exception: ex) { "Datastore registration retry failed for node 0x#{saved.node_id.to_s(16)}" }
        end
      end

      def add_pending(fabric : FabricInfo, node_id : UInt64, friendly_name : String,
                      expires_at_unix : Int64 = Time.utc.to_unix,
                      peer : Socket::IPAddress? = nil) : Nil
        @operation_lock.synchronize do
          add_pending_unlocked(fabric, node_id, friendly_name, expires_at_unix, peer)
        end
      end

      private def add_pending_unlocked(fabric : FabricInfo, node_id : UInt64, friendly_name : String,
                                       expires_at_unix : Int64, peer : Socket::IPAddress?) : Nil
        if node_id == DataType::NodeId::UNSPECIFIED || friendly_name.empty?
          raise Matter::ConfigurationError.new("Datastore pending node needs a Node ID and friendly name")
        end
        @store.update do |state|
          state.fabric_for(fabric.fabric_id, fabric.root_public_key, fabric.controller_node_id)
          if state.nodes_for(fabric.fabric_id, fabric.root_public_key, fabric.controller_node_id).has_key?(node_id)
            raise Matter::CommissioningError.new("Controller already has a commissioned node with this Node ID")
          end
          if entry = entry_for(state, fabric, node_id)
            unless entry.friendly_name == friendly_name && entry.stage.in?(PendingDatastoreNode::Stage::Pending,
                     PendingDatastoreNode::Stage::Registered) &&
                   (peer.nil? || (entry.peer_address == OperationalPeerResolver.address_hint(peer) && entry.peer_port == peer.port))
              raise Matter::CommissioningError.new("Datastore node registration conflicts with a previous attempt")
            end
          else
            state.pending_datastore_nodes << PendingDatastoreNode.new(fabric.fabric_id,
              fabric.root_public_key.dup, fabric.controller_node_id, node_id, friendly_name, expires_at_unix,
              peer.try { |address| OperationalPeerResolver.address_hint(address) },
              peer.try(&.port) || NodeInfo::DEFAULT_PORT)
          end
        end
        @delivery.add_pending_node(fabric, node_id, friendly_name)
        set_stage(fabric, node_id, PendingDatastoreNode::Stage::Registered)
      end

      def completing(fabric : FabricInfo, node_id : UInt64) : Nil
        @operation_lock.synchronize { set_stage(fabric, node_id, PendingDatastoreNode::Stage::Completing) }
      end

      # A successful ArmFailSafe re-arm extends the pending registration's
      # recovery window without repeating AddPendingNode on the Anchor.
      def extend_deadline(fabric : FabricInfo, node_id : UInt64, expires_at_unix : Int64) : Nil
        @operation_lock.synchronize { extend_deadline_unlocked(fabric, node_id, expires_at_unix) }
      end

      private def extend_deadline_unlocked(fabric : FabricInfo, node_id : UInt64, expires_at_unix : Int64) : Nil
        @store.update do |state|
          index = state.pending_datastore_nodes.index do |entry|
            same_fabric?(entry, fabric) && entry.node_id == node_id
          end
          if index
            entry = state.pending_datastore_nodes[index]
            if expires_at_unix > entry.expires_at_unix
              entry.expires_at_unix = expires_at_unix
              state.pending_datastore_nodes[index] = entry
            end
          end
        end
        nil
      end

      def complete(fabric : FabricInfo, node_id : UInt64) : Nil
        @operation_lock.synchronize { set_stage(fabric, node_id, PendingDatastoreNode::Stage::Completed) }
      end

      def refresh(fabric : FabricInfo, node_id : UInt64) : Nil
        @operation_lock.synchronize { refresh_unlocked(fabric, node_id) }
      end

      private def refresh_unlocked(fabric : FabricInfo, node_id : UInt64) : Nil
        state = @store.load
        entry = entry_for(state, fabric, node_id) || raise Matter::CommissioningError.new("Datastore node registration is missing")
        unless entry.stage == PendingDatastoreNode::Stage::Completed
          raise Matter::CommissioningError.new("Datastore node completion has not been acknowledged")
        end
        record_completed_node(fabric, entry)
        @delivery.refresh_node(fabric, node_id)
        clear(fabric, node_id)
      end

      def abort(fabric : FabricInfo, node_id : UInt64, confirmed_failure : Bool = false) : Nil
        @operation_lock.synchronize { abort_unlocked(fabric, node_id, confirmed_failure) }
      end

      private def abort_unlocked(fabric : FabricInfo, node_id : UInt64, confirmed_failure : Bool) : Nil
        state = @store.load
        entry = entry_for(state, fabric, node_id)
        return unless entry
        unless entry.stage.in?(PendingDatastoreNode::Stage::Pending, PendingDatastoreNode::Stage::Registered) ||
               (confirmed_failure && entry.stage == PendingDatastoreNode::Stage::Completing)
          raise Matter::CommissioningError.new("Datastore node completion is ambiguous; refusing RemoveNode")
        end
        @delivery.remove_node(fabric, node_id, entry.friendly_name)
        clear(fabric, node_id)
      end

      # Reconcile entries after restart. A completing exchange may have
      # succeeded without its response; an operator must establish the peer's
      # final fabric state before calling complete or abort.
      def resume(fabric : FabricInfo, now_unix : Int64 = Time.utc.to_unix) : Nil
        entries = @store.load.pending_datastore_nodes.select { |entry| same_fabric?(entry, fabric) }
        entries.each do |entry|
          @operation_lock.synchronize do
            latest = @store.load
            installed = latest.fabric_for(fabric.fabric_id, fabric.root_public_key, fabric.controller_node_id)
            current = entry_for(latest, installed, entry.node_id)
            resume_entry(installed, current, now_unix) if current
          end
        end
      end

      private def resume_entry(fabric : FabricInfo, entry : PendingDatastoreNode, now_unix : Int64) : Nil
        case entry.stage
        when PendingDatastoreNode::Stage::Pending
          if now_unix >= entry.expires_at_unix
            abort_unlocked(fabric, entry.node_id, false)
          else
            @delivery.add_pending_node(fabric, entry.node_id, entry.friendly_name)
            set_stage(fabric, entry.node_id, PendingDatastoreNode::Stage::Registered)
          end
        when PendingDatastoreNode::Stage::Registered
          abort_unlocked(fabric, entry.node_id, false) if now_unix >= entry.expires_at_unix
        when PendingDatastoreNode::Stage::Completed
          refresh_unlocked(fabric, entry.node_id)
        when PendingDatastoreNode::Stage::Completing
          state = @store.load
          if state.nodes_for(fabric.fabric_id, fabric.root_public_key, fabric.controller_node_id).has_key?(entry.node_id)
            set_stage(fabric, entry.node_id, PendingDatastoreNode::Stage::Completed)
            refresh_unlocked(fabric, entry.node_id)
          else
            raise Matter::CommissioningError.new("Datastore node completion is ambiguous; reconcile before retry")
          end
        end
      end

      private def set_stage(fabric : FabricInfo, node_id : UInt64, stage : PendingDatastoreNode::Stage) : Nil
        @store.update do |state|
          index = state.pending_datastore_nodes.index { |entry| same_fabric?(entry, fabric) && entry.node_id == node_id } ||
                  raise Matter::CommissioningError.new("Datastore node registration is missing")
          entry = state.pending_datastore_nodes[index]
          entry.stage = stage
          state.pending_datastore_nodes[index] = entry
        end
        nil
      end

      private def record_completed_node(fabric : FabricInfo, entry : PendingDatastoreNode) : Nil
        @store.update do |state|
          unless state.nodes_for(fabric.fabric_id, fabric.root_public_key,
                   fabric.controller_node_id).has_key?(entry.node_id)
            address = entry.peer_address ||
                      raise Matter::CommissioningError.new("Completed Datastore registration lacks the peer address for recovery")
            state.record_node(fabric.fabric_id, NodeInfo.new(entry.node_id, address, entry.peer_port),
              fabric.root_public_key, fabric.controller_node_id)
          end
        end
        nil
      end

      private def clear(fabric : FabricInfo, node_id : UInt64) : Nil
        @store.update do |state|
          state.pending_datastore_nodes = state.pending_datastore_nodes.reject do |entry|
            same_fabric?(entry, fabric) && entry.node_id == node_id
          end
        end
        nil
      end

      private def entry_for(state : State, fabric : FabricInfo, node_id : UInt64) : PendingDatastoreNode?
        state.pending_datastore_nodes.find { |entry| same_fabric?(entry, fabric) && entry.node_id == node_id }
      end

      private def same_fabric?(entry : PendingDatastoreNode, fabric : FabricInfo) : Bool
        entry.fabric_id == fabric.fabric_id && entry.controller_node_id == fabric.controller_node_id &&
          entry.root_public_key == fabric.root_public_key
      end
    end
  end
end
