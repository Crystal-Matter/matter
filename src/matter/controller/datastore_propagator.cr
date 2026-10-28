require "log"

require "./datastore_synchronizer"
require "./pairing/case_pairing"
require "./operational_peer_resolver"
require "./state_store"

module Matter
  module Controller
    # Retries delivery of pending Joint Fabric Datastore work. The network
    # delivery object is replaceable so the scheduling policy can be tested
    # without sockets or mDNS.
    class DatastorePropagator
      Log = ::Log.for("matter.controller.datastore_propagator")

      alias Store = Cluster::JointFabricDatastore
      MAX_ATTEMPTS                          = 3
      DEFAULT_RETRY_DELAY                   = 2.seconds
      DEFAULT_POLL_INTERVAL                 = 30.seconds
      FAILURE_CODE                          = InteractionModel::StatusCode::Failure.value
      CASE_INITIATOR_MESSAGES_PER_CANDIDATE = 2_u32
      CASE_ACKABLE_RESPONSES_PER_CANDIDATE  = 2_u32
      CASE_UNSECURED_MESSAGES_PER_CANDIDATE = CASE_INITIATOR_MESSAGES_PER_CANDIDATE +
                                              CASE_ACKABLE_RESPONSES_PER_CANDIDATE *
                                              (1_u32 + Transport::UDPTransport::MRP_MAX_RETRANSMISSIONS.to_u32)

      abstract class Delivery
        abstract def deliver(store : Store, node_id : UInt64) : Nil
      end

      class NetworkDelivery < Delivery
        def initialize(
          @state_store : StateStore,
          @timeout : Time::Span = 10.seconds,
          @fabric_id : UInt64? = nil,
          @root_public_key : Bytes? = nil,
          @controller_node_id : UInt64? = nil,
          @peer_hints : Hash(UInt64, Socket::IPAddress) = {} of UInt64 => Socket::IPAddress,
          @shared_message_counter : Transport::MessageCounter? = nil,
        )
        end

        def deliver(store : Store, node_id : UInt64) : Nil
          state = @state_store.load
          fabric = if id = @fabric_id
                     state.fabric_for(id, @root_public_key, @controller_node_id)
                   else
                     state.fabric || raise Matter::ConfigurationError.new("No controller fabric is installed")
                   end
          peer = OperationalPeerResolver.new.resolve(state, fabric, node_id,
            @timeout, @peer_hints[node_id]?)
          client = Client.new(counter_lease: counter_lease_for(fabric),
            shared_message_counter: @shared_message_counter)
          delivered = false
          begin
            session = Pairing::CasePairing.new.pair(client, peer, fabric, peer_node_id: node_id, timeout: @timeout)
            DatastoreSynchronizer.new(ImClient.new(client, @timeout)).sync_node(store, node_id, session, peer)
            delivered = true
          ensure
            @state_store.update do |current|
              if delivered
                current.record_node(fabric.fabric_id,
                  NodeInfo.new(node_id, OperationalPeerResolver.address_hint(peer), peer.port),
                  fabric.root_public_key, fabric.controller_node_id)
              end
            end
            client.close
          end
        end

        protected def counter_lease_for(fabric : FabricInfo) : StateStore::CounterLease
          # Full CASE sends Sigma1 and Sigma3, plus ACKs for Sigma2 and
          # StatusReport. Each inbound response may be retried up to the
          # transport's MRP bound; duplicate reception emits another ACK.
          # This bounds standalone delivery. A supplied listener counter uses
          # its renewable range instead. Unused counters stay spent after crash.
          preferred = fabric.case_ipk_value
          candidate_count = 1_u32 + fabric.ipk_epoch_keys.count { |key| key != preferred }.to_u32
          counter_count = candidate_count * CASE_UNSECURED_MESSAGES_PER_CANDIDATE
          @state_store.counter_lease(fabric.controller_node_id, counter_count, renewable: false)
        end
      end

      @running = false
      @done : Channel(Nil)?
      @wake : Channel(Nil)?

      def initialize(
        @store : Store,
        @delivery : Delivery,
        @max_attempts : Int32 = MAX_ATTEMPTS,
        @retry_delay : Time::Span = DEFAULT_RETRY_DELAY,
        @poll_interval : Time::Span = DEFAULT_POLL_INTERVAL,
      )
        raise Matter::ConfigurationError.new("Datastore propagation needs at least one attempt") if @max_attempts < 1
      end

      def start : Nil
        return if @running
        return if (done = @done) && !done.closed?
        @running = true
        done = Channel(Nil).new
        wake = Channel(Nil).new
        @done = done
        @wake = wake
        spawn do
          while @running
            begin
              run_pending(respect_stop: true)
            rescue ex
              Log.error(exception: ex) { "Datastore propagation pass failed" }
            end
            if @running
              select
              when wake.receive?
                break
              when timeout(@poll_interval)
              end
            end
          end
        ensure
          done.close
        end
      end

      # Wait for an in-flight delivery to finish before its storage closes.
      # Returns false when the delivery is still running after the deadline.
      def stop(wait_timeout : Time::Span = 30.seconds) : Bool
        @running = false
        wake_worker
        if done = @done
          select
          when done.receive?
            @done = nil
            @wake = nil
            true
          when timeout(wait_timeout)
            false
          end
        else
          true
        end
      end

      # Stop before closing storage shared with a delivery. An active network
      # request must finish, but idle and retry waits are cancelled at once.
      def stop! : Nil
        @running = false
        wake_worker
        @done.try(&.receive?)
        @done = nil
        @wake = nil
      end

      def run_pending(respect_stop : Bool = false) : Nil
        work_node_ids.each do |node_id|
          break if respect_stop && !@running
          @max_attempts.times do |attempt|
            break if respect_stop && !@running
            begin
              rearm_recoverable_failure(node_id)
              @delivery.deliver(@store, node_id)
              break unless work_for?(node_id)
            rescue ex
              Log.warn { "Datastore propagation attempt #{attempt + 1}/#{@max_attempts} failed for node 0x#{node_id.to_s(16)}: #{ex.message}" }
            end
            if attempt + 1 == @max_attempts
              fail_pending(node_id)
            else
              if respect_stop
                break unless @running
                if wake = @wake
                  select
                  when wake.receive?
                    return
                  when timeout(@retry_delay * (attempt + 1))
                  end
                end
              else
                sleep @retry_delay * (attempt + 1)
              end
            end
          end
        end
      end

      private def wake_worker : Nil
        @wake.try do |wake|
          wake.close unless wake.closed?
        end
      end

      private def work_node_ids : Array(UInt64)
        ids = [] of UInt64
        @store.node_list.each { |entry| ids << entry.node_id if work?(entry.commissioning_status_entry) }
        @store.node_key_set_list.each { |entry| ids << entry.node_id if work?(entry.status_entry) }
        @store.endpoint_group_id_list.each { |entry| ids << entry.node_id if work?(entry.status_entry) }
        @store.node_acl_list.each { |entry| ids << entry.node_id if work?(entry.status_entry) }
        @store.endpoint_binding_list.each { |entry| ids << entry.node_id if work?(entry.status_entry) }
        ids.uniq
      end

      private def work_for?(node_id : UInt64) : Bool
        work_node_ids.includes?(node_id)
      end

      private def work?(status : Store::DatastoreStatusEntryStruct) : Bool
        pending?(status) || recoverable_failure?(status)
      end

      private def pending?(status : Store::DatastoreStatusEntryStruct) : Bool
        status.state == Store::DatastoreStateEnum::Pending ||
          (status.state == Store::DatastoreStateEnum::DeletePending && status.failure_code == Store::NO_FAILURE_CODE)
      end

      private def recoverable_failure?(status : Store::DatastoreStatusEntryStruct) : Bool
        failed = status.state == Store::DatastoreStateEnum::CommitFailed ||
                 (status.state == Store::DatastoreStateEnum::DeletePending && status.failure_code != Store::NO_FAILURE_CODE)
        failed && status.failure_code != InteractionModel::StatusCode::ResourceExhausted.value &&
          status.failure_code != InteractionModel::StatusCode::ConstraintError.value
      end

      private def rearm_recoverable_failure(node_id : UInt64) : Nil
        return unless @store.node_list.any? { |entry| entry.node_id == node_id }
        return unless @store.node_list.any? { |entry| entry.node_id == node_id && recoverable_failure?(entry.commissioning_status_entry) } ||
                      @store.node_key_set_list.any? { |entry| entry.node_id == node_id && recoverable_failure?(entry.status_entry) } ||
                      @store.endpoint_group_id_list.any? { |entry| entry.node_id == node_id && recoverable_failure?(entry.status_entry) } ||
                      @store.node_acl_list.any? { |entry| entry.node_id == node_id && recoverable_failure?(entry.status_entry) } ||
                      @store.endpoint_binding_list.any? { |entry| entry.node_id == node_id && recoverable_failure?(entry.status_entry) }
        status = @store.refresh_node(Store::RefreshNodeRequest.new(node_id))
        raise Matter::ClusterError.new("Datastore retry RefreshNode failed", status.status, status.cluster_status) unless status.success?
      end

      private def fail_pending(node_id : UInt64) : Nil
        @store.node_key_set_list.select { |entry| entry.node_id == node_id && pending?(entry.status_entry) }.each do |entry|
          @store.complete_node_key_set(node_id, entry.group_key_set_id, FAILURE_CODE)
        end
        @store.endpoint_group_id_list.select { |entry| entry.node_id == node_id && pending?(entry.status_entry) }.each do |entry|
          @store.complete_group_membership(node_id, entry.endpoint_id, entry.group_id, FAILURE_CODE)
        end
        @store.node_acl_list.select { |entry| entry.node_id == node_id && pending?(entry.status_entry) }.each do |entry|
          @store.complete_acl(node_id, entry.list_id, FAILURE_CODE)
        end
        @store.endpoint_binding_list.select { |entry| entry.node_id == node_id && pending?(entry.status_entry) }.each do |entry|
          @store.complete_binding(node_id, entry.endpoint_id, entry.list_id, FAILURE_CODE)
        end
        @store.node_list.select { |entry| entry.node_id == node_id && pending?(entry.commissioning_status_entry) }.each do
          @store.complete_node(node_id, FAILURE_CODE)
        end
      end
    end
  end
end
