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

        def remove_committed_node(fabric : FabricInfo, node_id : UInt64, friendly_name : String) : Nil
          remove_node(fabric, node_id, friendly_name)
        end

        def node_absent?(fabric : FabricInfo, node_id : UInt64) : Bool
          false
        end
      end

      # Sends the lifecycle commands to the Anchor's Datastore over CASE.
      # NodeList reads make retries safe after a lost invoke response.
      class NetworkDelivery < Delivery
        def initialize(@store : StateStore, @client : Client, @anchor_node_id : UInt64,
                       @datastore_endpoint : UInt16, @timeout : Time::Span = 15.seconds,
                       @crypto : Crypto::CryptoBase = Crypto::StandardCrypto.new,
                       @anchor_peer : Socket::IPAddress? = nil)
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
          remove_matching_node(fabric, node_id, friendly_name, allow_committed: false)
        end

        def remove_committed_node(fabric : FabricInfo, node_id : UInt64, friendly_name : String) : Nil
          remove_matching_node(fabric, node_id, friendly_name, allow_committed: true)
        end

        private def remove_matching_node(fabric : FabricInfo, node_id : UInt64, friendly_name : String,
                                         allow_committed : Bool) : Nil
          with_datastore(fabric) do |interaction, session, peer|
            entry = find_node(interaction, session, peer, node_id)
            next unless entry
            unless entry.friendly_name == friendly_name &&
                   (pending_node?(entry) || (allow_committed && entry.commissioning_status_entry.state.committed?))
              raise Matter::CommissioningError.new("Refusing to remove a different or completed Datastore node")
            end
            invoke(interaction, session, peer, Datastore::CMD_REMOVE_NODE,
              Datastore::RemoveNodeRequest.new(node_id).to_slice)
          end
        end

        def node_absent?(fabric : FabricInfo, node_id : UInt64) : Bool
          absent = false
          with_datastore(fabric) do |interaction, session, peer|
            absent = find_node(interaction, session, peer, node_id).nil?
          end
          absent
        end

        protected def with_datastore(fabric : FabricInfo, & : ImClient, Session::SecureContext, Socket::IPAddress ->) : Nil
          state = @store.load
          installed = state.fabric_for(fabric.fabric_id, fabric.root_public_key, fabric.controller_node_id)
          peer = @anchor_peer || begin
            node = state.nodes_for(installed.fabric_id, installed.root_public_key, installed.controller_node_id)[@anchor_node_id]? ||
                   raise Matter::ConfigurationError.new("Anchor Administrator is absent from controller state")
            address = node.address || raise Matter::ConfigurationError.new("Anchor Administrator address is missing")
            Socket::IPAddress.new(address, node.port)
          end
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

      getter attempt_id : String

      @retry_running = false
      @retry_owners = 0
      @retry_done : Channel(Nil)?
      @retry_wake : Channel(Nil)?
      @retry_lifecycle_lock = Mutex.new
      @operation_lock = Mutex.new

      def initialize(@store : StateStore, @delivery : Delivery, attempt_id : String? = nil,
                     @target_node_id : UInt64? = nil,
                     @retry_interval : Time::Span = DEFAULT_RETRY_INTERVAL)
        raise Matter::ConfigurationError.new("Datastore retry interval must be positive") unless @retry_interval > Time::Span.zero
        @fixed_attempt_id = !attempt_id.nil?
        @attempt_id = attempt_id || Random::Secure.random_bytes(16).hexstring
      end

      # A long-lived commissioner retries the durable registration journal.
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

      # Reload under the process lock so foreground commissioning and retry
      # never write the same registration stage concurrently.
      def retry_pending_once(now_unix : Int64 = Time.utc.to_unix) : Nil
        @store.load.pending_datastore_nodes.each do |saved|
          next if @target_node_id && saved.node_id != @target_node_id
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
                      peer : Socket::IPAddress? = nil, allow_commissioned : Bool = false) : Nil
        @operation_lock.synchronize do
          add_pending_unlocked(fabric, node_id, friendly_name, expires_at_unix, peer, allow_commissioned)
        end
      end

      private def add_pending_unlocked(fabric : FabricInfo, node_id : UInt64, friendly_name : String,
                                       expires_at_unix : Int64, peer : Socket::IPAddress?,
                                       allow_commissioned : Bool) : Nil
        if node_id == DataType::NodeId::UNSPECIFIED || friendly_name.empty?
          raise Matter::ConfigurationError.new("Datastore pending node needs a Node ID and friendly name")
        end
        @store.update do |state|
          state.fabric_for(fabric.fabric_id, fabric.root_public_key, fabric.controller_node_id)
          if commissioned = state.nodes_for(fabric.fabric_id, fabric.root_public_key,
               fabric.controller_node_id)[node_id]?
            unless allow_commissioned && peer &&
                   commissioned.address == OperationalPeerResolver.address_hint(peer) &&
                   commissioned.port == peer.port
              raise Matter::CommissioningError.new("Controller already has a commissioned node with this Node ID")
            end
          end
          if entry = entry_for(state, fabric, node_id)
            unless entry.attempt_id == @attempt_id && entry.friendly_name == friendly_name &&
                   entry.stage.in?(PendingDatastoreNode::Stage::Pending, PendingDatastoreNode::Stage::Registered) &&
                   (peer.nil? || (entry.peer_address == OperationalPeerResolver.address_hint(peer) && entry.peer_port == peer.port))
              raise Matter::CommissioningError.new("Datastore node registration conflicts with a previous attempt")
            end
          else
            state.pending_datastore_nodes << PendingDatastoreNode.new(fabric.fabric_id,
              fabric.root_public_key.dup, fabric.controller_node_id, node_id, friendly_name, expires_at_unix,
              peer.try { |address| OperationalPeerResolver.address_hint(address) },
              peer.try(&.port) || NodeInfo::DEFAULT_PORT, attempt_id: @attempt_id)
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
          index = entry_index(state, fabric, node_id)
          next unless index
          entry = state.pending_datastore_nodes[index]
          require_attempt!(entry)
          if expires_at_unix > entry.expires_at_unix
            entry.expires_at_unix = expires_at_unix
            state.pending_datastore_nodes[index] = entry
          end
        end
      end

      def complete(fabric : FabricInfo, node_id : UInt64) : Nil
        @operation_lock.synchronize { set_stage(fabric, node_id, PendingDatastoreNode::Stage::Completed) }
      end

      # Call only after an authenticated Datastore NodeList read shows the
      # matching legacy registration is Committed. No RefreshNode is replayed.
      def confirm_remote_committed(fabric : FabricInfo, node_id : UInt64) : Nil
        @operation_lock.synchronize { confirm_remote_committed_unlocked(fabric, node_id) }
      end

      private def confirm_remote_committed_unlocked(fabric : FabricInfo, node_id : UInt64) : Nil
        @store.update do |state|
          entry = entry_for(state, fabric, node_id) ||
                  raise Matter::CommissioningError.new("Datastore node registration is missing")
          require_attempt!(entry)
          if entry.stage.removing?
            raise Matter::CommissioningError.new("Datastore removal already started")
          end
          state.pending_datastore_nodes.reject! { |item| same_fabric?(item, fabric) && item.node_id == node_id }
        end
      end

      def refresh(fabric : FabricInfo, node_id : UInt64) : Nil
        @operation_lock.synchronize { refresh_unlocked(fabric, node_id) }
      end

      private def refresh_unlocked(fabric : FabricInfo, node_id : UInt64) : Nil
        state = @store.load
        entry = entry_for(state, fabric, node_id) || raise Matter::CommissioningError.new("Datastore node registration is missing")
        require_attempt!(entry)
        unless entry.stage == PendingDatastoreNode::Stage::Completed
          raise Matter::CommissioningError.new("Datastore node completion has not been acknowledged")
        end
        record_completed_node(fabric, entry)
        @delivery.refresh_node(fabric, node_id)
        clear(fabric, node_id, PendingDatastoreNode::Stage::Completed)
      end

      def abort(fabric : FabricInfo, node_id : UInt64, confirmed_failure : Bool = false,
                allow_committed : Bool = false) : Nil
        @operation_lock.synchronize { abort_unlocked(fabric, node_id, confirmed_failure, allow_committed) }
      end

      private def abort_unlocked(fabric : FabricInfo, node_id : UInt64, confirmed_failure : Bool,
                                 allow_committed : Bool) : Nil
        entry = @store.update do |state|
          index = entry_index(state, fabric, node_id)
          next unless index
          current = state.pending_datastore_nodes[index]
          require_attempt!(current)
          unless current.stage.in?(PendingDatastoreNode::Stage::Pending, PendingDatastoreNode::Stage::Registered) ||
                 (confirmed_failure && current.stage == PendingDatastoreNode::Stage::Completing)
            raise Matter::CommissioningError.new("Datastore node completion is ambiguous; refusing RemoveNode")
          end
          current.stage = PendingDatastoreNode::Stage::Removing
          state.pending_datastore_nodes[index] = current
          current
        end
        return unless entry
        if allow_committed
          @delivery.remove_committed_node(fabric, node_id, entry.friendly_name)
        else
          @delivery.remove_node(fabric, node_id, entry.friendly_name)
        end
        clear(fabric, node_id, PendingDatastoreNode::Stage::Removing)
      end

      # A lost RemoveNode result is never replayed. An authenticated absent
      # NodeList entry proves that releasing the durable removal guard is safe.
      def reconcile_removal(fabric : FabricInfo, node_id : UInt64) : Nil
        @operation_lock.synchronize { reconcile_removal_unlocked(fabric, node_id) }
      end

      private def reconcile_removal_unlocked(fabric : FabricInfo, node_id : UInt64) : Nil
        entry = entry_for(@store.load, fabric, node_id) || return
        require_attempt!(entry)
        unless entry.stage.removing? && @delivery.node_absent?(fabric, node_id)
          raise Matter::CommissioningError.new("Datastore removal needs authenticated absence reconciliation")
        end
        clear(fabric, node_id, PendingDatastoreNode::Stage::Removing)
      end

      # Reconcile entries after restart. A completing exchange may have
      # succeeded without its response; an operator must establish the peer's
      # final fabric state before calling complete or abort.
      def resume(fabric : FabricInfo, now_unix : Int64 = Time.utc.to_unix) : Nil
        entries = @store.load.pending_datastore_nodes.select { |entry| same_fabric?(entry, fabric) }
        entries.each do |entry|
          next if @target_node_id && entry.node_id != @target_node_id
          @operation_lock.synchronize do
            latest = @store.load
            installed = latest.fabric_for(fabric.fabric_id, fabric.root_public_key, fabric.controller_node_id)
            current = entry_for(latest, installed, entry.node_id)
            resume_entry(installed, current, now_unix) if current
          end
        end
      end

      private def resume_entry(fabric : FabricInfo, entry : PendingDatastoreNode, now_unix : Int64) : Nil
        unless @fixed_attempt_id
          # Recovery owns one saved attempt at a time. Its identity must never
          # replace the active commissioner's foreground attempt ID.
          if entry.attempt_id.empty?
            claimant = DatastoreNodeRegistrar.new(@store, @delivery, target_node_id: entry.node_id)
            claimant.claim_legacy(fabric, entry.node_id, entry.friendly_name, entry.peer_address, entry.peer_port)
            attempt_id = claimant.attempt_id
          else
            attempt_id = entry.attempt_id
          end
          DatastoreNodeRegistrar.new(@store, @delivery, attempt_id, entry.node_id).resume(fabric, now_unix)
          return
        end
        if entry.attempt_id.empty?
          raise Matter::CommissioningError.new("Legacy Datastore registration needs identity claim")
        end
        if entry.attempt_id != @attempt_id
          raise Matter::CommissioningError.new("Datastore registration belongs to another attempt")
        end
        case entry.stage
        when PendingDatastoreNode::Stage::Pending
          if now_unix >= entry.expires_at_unix
            abort_unlocked(fabric, entry.node_id, false, false)
          else
            @delivery.add_pending_node(fabric, entry.node_id, entry.friendly_name)
            set_stage(fabric, entry.node_id, PendingDatastoreNode::Stage::Registered)
          end
        when PendingDatastoreNode::Stage::Registered
          abort_unlocked(fabric, entry.node_id, false, false) if now_unix >= entry.expires_at_unix
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
        when PendingDatastoreNode::Stage::Removing
          reconcile_removal_unlocked(fabric, entry.node_id)
        end
      end

      # Claim a pre-attempt-ID record once, under the backend transaction.
      # The caller supplies its full saved identity before using the claim.
      def claim_legacy(fabric : FabricInfo, node_id : UInt64, friendly_name : String,
                       peer_address : String?, peer_port : Int32) : Nil
        @store.update do |state|
          index = entry_index(state, fabric, node_id) ||
                  raise Matter::CommissioningError.new("Legacy Datastore registration is missing")
          entry = state.pending_datastore_nodes[index]
          unless entry.friendly_name == friendly_name && entry.peer_address == peer_address &&
                 entry.peer_port == peer_port
            raise Matter::CommissioningError.new("Legacy Datastore registration identity changed")
          end
          if entry.attempt_id.empty?
            if entry.stage.removing?
              raise Matter::CommissioningError.new("Legacy Datastore removal needs manual reconciliation")
            end
            state.pending_datastore_nodes[index] = PendingDatastoreNode.new(entry.fabric_id,
              entry.root_public_key.dup, entry.controller_node_id, entry.node_id,
              entry.friendly_name, entry.expires_at_unix, entry.peer_address,
              entry.peer_port, entry.stage, @attempt_id)
          else
            require_attempt!(entry)
          end
        end
      end

      private def set_stage(fabric : FabricInfo, node_id : UInt64, stage : PendingDatastoreNode::Stage) : Nil
        @store.update do |state|
          index = entry_index(state, fabric, node_id) ||
                  raise Matter::CommissioningError.new("Datastore node registration is missing")
          entry = state.pending_datastore_nodes[index]
          require_attempt!(entry)
          raise Matter::CommissioningError.new("Datastore removal already started") if entry.stage.removing?
          entry.stage = stage
          state.pending_datastore_nodes[index] = entry
        end
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

      private def clear(fabric : FabricInfo, node_id : UInt64, expected_stage : PendingDatastoreNode::Stage) : Nil
        @store.update do |state|
          entry = entry_for(state, fabric, node_id) ||
                  raise Matter::CommissioningError.new("Datastore node registration is missing")
          require_attempt!(entry)
          unless entry.stage == expected_stage
            raise Matter::CommissioningError.new("Datastore node registration changed during cleanup")
          end
          state.pending_datastore_nodes.reject! { |item| same_fabric?(item, fabric) && item.node_id == node_id }
        end
      end

      private def require_attempt!(entry : PendingDatastoreNode) : Nil
        if @attempt_id.empty? || entry.attempt_id != @attempt_id
          raise Matter::CommissioningError.new("Datastore registration belongs to another attempt")
        end
      end

      private def entry_for(state : State, fabric : FabricInfo, node_id : UInt64) : PendingDatastoreNode?
        state.pending_datastore_nodes.find { |entry| same_fabric?(entry, fabric) && entry.node_id == node_id }
      end

      private def entry_index(state : State, fabric : FabricInfo, node_id : UInt64) : Int32?
        state.pending_datastore_nodes.index { |entry| same_fabric?(entry, fabric) && entry.node_id == node_id }
      end

      private def same_fabric?(entry : PendingDatastoreNode, fabric : FabricInfo) : Bool
        entry.fabric_id == fabric.fabric_id && entry.controller_node_id == fabric.controller_node_id &&
          entry.root_public_key == fabric.root_public_key
      end
    end
  end
end
