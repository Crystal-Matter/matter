require "log"

require "./datastore_synchronizer"
require "./pairing/case_pairing"
require "./scanner"
require "./state_store"

module Matter
  module Controller
    # Retries delivery of pending Joint Fabric Datastore work. The network
    # delivery object is replaceable so the scheduling policy can be tested
    # without sockets or mDNS.
    class DatastorePropagator
      Log = ::Log.for("matter.controller.datastore_propagator")

      alias Store = Cluster::JointFabricDatastore
      MAX_ATTEMPTS          = 3
      DEFAULT_RETRY_DELAY   = 2.seconds
      DEFAULT_POLL_INTERVAL = 30.seconds
      FAILURE_CODE          = InteractionModel::StatusCode::Failure.value

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
        )
        end

        def deliver(store : Store, node_id : UInt64) : Nil
          state = @state_store.load
          fabric = if id = @fabric_id
                     state.fabric_for(id, @root_public_key, @controller_node_id)
                   else
                     state.fabric || raise Matter::ConfigurationError.new("No controller fabric is installed")
                   end
          peer = resolve_peer(state, fabric, node_id)
          client = Client.new(
            unsecured_source_node_id: fabric.controller_node_id,
            initial_unsecured_message_counter: state.unsecured_message_counter
          )
          begin
            session = Pairing::CasePairing.new.pair(client, peer, fabric, peer_node_id: node_id, timeout: @timeout)
            DatastoreSynchronizer.new(ImClient.new(client, @timeout)).sync_node(store, node_id, session, peer)
            state.record_node(fabric.fabric_id, NodeInfo.new(node_id, peer.address, peer.port), fabric.root_public_key, fabric.controller_node_id)
          ensure
            state.unsecured_message_counter = client.transport.message_counter.counter
            @state_store.save(state)
            client.close
          end
        end

        private def resolve_peer(state : State, fabric : FabricInfo, node_id : UInt64) : Socket::IPAddress
          compressed_fabric_id = fabric.compressed_fabric_id
          scanner = Scanner.new
          begin
            scanner.start
            scanner.query_operational
            deadline = Time.instant + @timeout
            loop do
              device = scanner.operational_devices.find do |candidate|
                candidate.fabric_id == compressed_fabric_id && candidate.node_id == node_id
              end
              if device
                address = device.addresses.find(&.family.inet?) || device.addresses.first?
                return Socket::IPAddress.new(address.address, device.port) if address
              end
              break if Time.instant >= deadline
              sleep 100.milliseconds
            end
          ensure
            scanner.close
          end
          if info = state.nodes_for(fabric.fabric_id, fabric.root_public_key, fabric.controller_node_id)[node_id]?
            if address = info.address
              return Socket::IPAddress.new(address, info.port)
            end
          end
          # A configured address is only a reachability hint. CASE still
          # authenticates the expected Node ID against the selected fabric.
          if peer = @peer_hints[node_id]?
            return peer
          end
          raise Matter::TransportError.new("Could not discover Joint Fabric node 0x#{node_id.to_s(16)}")
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
        pending_node_ids.each do |node_id|
          break if respect_stop && !@running
          @max_attempts.times do |attempt|
            break if respect_stop && !@running
            begin
              @delivery.deliver(@store, node_id)
              break unless pending_for?(node_id)
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

      private def pending_node_ids : Array(UInt64)
        ids = [] of UInt64
        @store.node_list.each { |entry| ids << entry.node_id if pending?(entry.commissioning_status_entry) }
        @store.node_key_set_list.each { |entry| ids << entry.node_id if pending?(entry.status_entry) }
        @store.endpoint_group_id_list.each { |entry| ids << entry.node_id if pending?(entry.status_entry) }
        @store.node_acl_list.each { |entry| ids << entry.node_id if pending?(entry.status_entry) }
        @store.endpoint_binding_list.each { |entry| ids << entry.node_id if pending?(entry.status_entry) }
        ids.uniq
      end

      private def pending_for?(node_id : UInt64) : Bool
        pending_node_ids.includes?(node_id)
      end

      private def pending?(status : Store::DatastoreStatusEntryStruct) : Bool
        status.state == Store::DatastoreStateEnum::Pending ||
          (status.state == Store::DatastoreStateEnum::DeletePending && status.failure_code == 0_u8)
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
