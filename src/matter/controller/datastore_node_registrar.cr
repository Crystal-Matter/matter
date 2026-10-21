require "../cluster/joint_fabric_datastore"
require "./im_client"
require "./pairing/case_pairing"
require "./state_store"

module Matter
  module Controller
    # Opt-in Joint Fabric Datastore lifecycle for a newly commissioned device.
    # Each network operation is retried from a durable controller-state journal.
    class DatastoreNodeRegistrar
      alias Datastore = Cluster::JointFabricDatastore

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

      def initialize(@store : StateStore, @delivery : Delivery)
      end

      def add_pending(fabric : FabricInfo, node_id : UInt64, friendly_name : String,
                      expires_at_unix : Int64 = Time.utc.to_unix,
                      peer : Socket::IPAddress? = nil) : Nil
        if node_id == 0_u64 || friendly_name.empty?
          raise Matter::ConfigurationError.new("Datastore pending node needs a Node ID and friendly name")
        end
        state = @store.load
        if state.nodes_for(fabric.fabric_id, fabric.root_public_key, fabric.controller_node_id).has_key?(node_id)
          raise Matter::CommissioningError.new("Controller already has a commissioned node with this Node ID")
        end
        if entry = entry_for(state, fabric, node_id)
          unless entry.friendly_name == friendly_name && entry.stage.in?(PendingDatastoreNode::Stage::Pending,
                   PendingDatastoreNode::Stage::Registered) &&
                 (peer.nil? || (entry.peer_address == peer.address && entry.peer_port == peer.port))
            raise Matter::CommissioningError.new("Datastore node registration conflicts with a previous attempt")
          end
        else
          state.pending_datastore_nodes << PendingDatastoreNode.new(fabric.fabric_id,
            fabric.root_public_key.dup, fabric.controller_node_id, node_id, friendly_name, expires_at_unix,
            peer.try(&.address), peer.try(&.port) || NodeInfo::DEFAULT_PORT)
          @store.save(state)
        end
        @delivery.add_pending_node(fabric, node_id, friendly_name)
        set_stage(fabric, node_id, PendingDatastoreNode::Stage::Registered)
      end

      def completing(fabric : FabricInfo, node_id : UInt64) : Nil
        set_stage(fabric, node_id, PendingDatastoreNode::Stage::Completing)
      end

      # A successful ArmFailSafe re-arm extends the pending registration's
      # recovery window without repeating AddPendingNode on the Anchor.
      def extend_deadline(fabric : FabricInfo, node_id : UInt64, expires_at_unix : Int64) : Nil
        state = @store.load
        index = state.pending_datastore_nodes.index do |entry|
          same_fabric?(entry, fabric) && entry.node_id == node_id
        end
        return unless index
        entry = state.pending_datastore_nodes[index]
        return if expires_at_unix <= entry.expires_at_unix
        entry.expires_at_unix = expires_at_unix
        state.pending_datastore_nodes[index] = entry
        @store.save(state)
      end

      def complete(fabric : FabricInfo, node_id : UInt64) : Nil
        set_stage(fabric, node_id, PendingDatastoreNode::Stage::Completed)
      end

      def refresh(fabric : FabricInfo, node_id : UInt64) : Nil
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
          case entry.stage
          when PendingDatastoreNode::Stage::Pending, PendingDatastoreNode::Stage::Registered
            abort(fabric, entry.node_id) if now_unix >= entry.expires_at_unix
          when PendingDatastoreNode::Stage::Completed
            refresh(fabric, entry.node_id)
          when PendingDatastoreNode::Stage::Completing
            state = @store.load
            if state.nodes_for(fabric.fabric_id, fabric.root_public_key, fabric.controller_node_id).has_key?(entry.node_id)
              complete(fabric, entry.node_id)
              refresh(fabric, entry.node_id)
            else
              raise Matter::CommissioningError.new("Datastore node completion is ambiguous; reconcile before retry")
            end
          end
        end
      end

      private def set_stage(fabric : FabricInfo, node_id : UInt64, stage : PendingDatastoreNode::Stage) : Nil
        state = @store.load
        index = state.pending_datastore_nodes.index { |entry| same_fabric?(entry, fabric) && entry.node_id == node_id } ||
                raise Matter::CommissioningError.new("Datastore node registration is missing")
        entry = state.pending_datastore_nodes[index]
        entry.stage = stage
        state.pending_datastore_nodes[index] = entry
        @store.save(state)
      end

      private def record_completed_node(fabric : FabricInfo, entry : PendingDatastoreNode) : Nil
        state = @store.load
        return if state.nodes_for(fabric.fabric_id, fabric.root_public_key,
                    fabric.controller_node_id).has_key?(entry.node_id)
        address = entry.peer_address ||
                  raise Matter::CommissioningError.new("Completed Datastore registration lacks the peer address for recovery")
        state.record_node(fabric.fabric_id, NodeInfo.new(entry.node_id, address, entry.peer_port),
          fabric.root_public_key, fabric.controller_node_id)
        @store.save(state)
      end

      private def clear(fabric : FabricInfo, node_id : UInt64) : Nil
        state = @store.load
        state.pending_datastore_nodes = state.pending_datastore_nodes.reject do |entry|
          same_fabric?(entry, fabric) && entry.node_id == node_id
        end
        @store.save(state)
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
