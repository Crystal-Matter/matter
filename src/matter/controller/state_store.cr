require "log"
require "../storage/backend"
require "../fabric"
require "../session/case/resumption_store"
require "../transport/message_counter"
require "./icd_peer_store"
require "./state"

module Matter
  module Controller
    # Persists the controller `State` as the `controller/state` document of a
    # `Storage::Backend`.
    class StateStore
      Log = ::Log.for("matter.controller.state_store")

      private class LoadConflict < Matter::StorageError
      end

      class ConflictError < Matter::StorageError
      end

      COLLECTION                           = "controller"
      DOCUMENT_ID                          = "state"
      LOAD_CONFLICT_RETRIES                =      8
      COUNTER_RESERVATION_CONFLICT_RETRIES =      8
      DEFAULT_UNSECURED_COUNTER_LEASE_SIZE = 64_u32

      # A fixed unsecured source Node ID must spend counters from one durable
      # StateStore. Each reservation is committed before Client sends a packet;
      # a crash deliberately leaves the rest of that range unused.
      class CounterLease
        getter store : StateStore
        getter source_node_id : UInt64
        getter block_size : UInt32
        getter? renewable : Bool

        def initialize(@store : StateStore, @source_node_id : UInt64,
                       @block_size : UInt32 = DEFAULT_UNSECURED_COUNTER_LEASE_SIZE,
                       @renewable : Bool = true)
          unless @store.backend.durable?
            raise Matter::ConfigurationError.new("A fixed source counter lease requires durable storage")
          end
          unless (DataType::NodeId::OPERATIONAL_MINIMUM..DataType::NodeId::OPERATIONAL_MAXIMUM).includes?(@source_node_id)
            raise Matter::ConfigurationError.new("Counter lease requires an operational source Node ID")
          end
          if @block_size == 0_u32 || @block_size >= State::UNSECURED_COUNTER_HALF_RANGE
            raise Matter::ConfigurationError.new("Counter lease block size is outside the serial half-range")
          end
        end

        def reserve : Tuple(UInt32, UInt32)
          {@store.reserve_unsecured_message_counters_for(@source_node_id, @block_size), @block_size}
        end

        def owns?(counter : Transport::MessageCounter) : Bool
          counter.leased_by?(@store.backend)
        end

        def ownership_key : Tuple(String, UInt64)
          {@store.backend.counter_lease_namespace, @source_node_id}
        end
      end

      def counter_lease(source_node_id : UInt64,
                        block_size : UInt32 = DEFAULT_UNSECURED_COUNTER_LEASE_SIZE,
                        renewable : Bool = true) : CounterLease
        CounterLease.new(self, source_node_id, block_size, renewable)
      end

      # A device listener and its shared controller Clients use one outgoing
      # counter. Call before the listener starts sending; all source Node IDs on
      # that transport then draw from the same durable reservation sequence.
      def bind_transport_counter(counter : Transport::MessageCounter,
                                 block_size : UInt32 = DEFAULT_UNSECURED_COUNTER_LEASE_SIZE) : Nil
        raise Matter::ConfigurationError.new("A shared transport counter lease requires durable storage") unless @backend.durable?
        @backend.claim_counter_lease_owner!
        return if counter.leased_by?(@backend)
        start = reserve_unsecured_message_counters(block_size, claim_owner: true)
        counter.bind_lease(@backend, start, block_size,
          -> { {reserve_unsecured_message_counters(block_size, claim_owner: true), block_size} },
          @backend.counter_lease_validity)
      end

      getter backend : Storage::Backend

      def initialize(@backend : Storage::Backend)
      end

      def load : State
        @backend.open unless @backend.open?
        attempts = 0
        loop do
          return load_once
        rescue ex : LoadConflict
          attempts += 1
          raise ex if attempts >= LOAD_CONFLICT_RETRIES
        end
      rescue ex : Matter::StorageError
        raise ex
      rescue ex
        raise Matter::StorageError.new("Failed to load controller state (path=#{@backend.path.inspect}): #{ex.message}", cause: ex)
      end

      private def load_once : State
        state = State.new
        @backend.transaction do
          document = @backend.read(COLLECTION, DOCUMENT_ID)
          state = document ? State.from_document(document) : State.new
          state, dirty = normalize(state)
          if original = document
            # An old document has no marker for a counter that already
            # wrapped to zero. Treat it as initialized to reject stale peers.
            unless original.has_key?("unsecured_counter_initialized")
              state.unsecured_counter_initialized = true
              dirty = true
            end
            # Guard cleanup even when normalization made no changes. The SQL
            # conditional update locks this row until commit.
            guarded = dirty ? state.to_document : original
            unless @backend.compare_and_swap(COLLECTION, DOCUMENT_ID, original, guarded)
              raise LoadConflict.new("Controller state changed during load")
            end
            purge_orphaned_credentials(state)
            state.storage_snapshot = Storage.deep_copy(guarded)
          else
            # An empty store owns no controller credentials yet. Do not
            # clean them from an unguarded snapshot or write on first read.
            state.storage_snapshot = nil
          end
          state.storage_loaded = true
        end
        state
      end

      def save(state : State) : Nil
        @backend.open unless @backend.open?
        @backend.transaction do
          previous = @backend.read(COLLECTION, DOCUMENT_ID)
          if state.storage_loaded? && previous != state.storage_snapshot
            raise ConflictError.new("Controller state changed since load; reload before saving")
          end
          prior_state = previous ? State.from_document(previous) : State.new
          purge_orphaned_credentials(prior_state)
          document = state.to_document
          expected = state.storage_loaded? ? state.storage_snapshot : previous
          unless @backend.compare_and_swap(COLLECTION, DOCUMENT_ID, expected, document)
            raise ConflictError.new("Controller state changed since load; reload before saving")
          end
          remaining = state.fabrics
          resume_store = Session::Case::ResumptionStore.new(@backend)
          icd_peers = IcdPeerStore.new(@backend)
          prior_state.fabrics.each do |fabric|
            next if remaining.any? do |installed|
                      same_fabric?(installed, fabric.fabric_id, fabric.root_public_key,
                        fabric.controller_node_id)
                    end
            # Controller state owns initiator records only. A legacy roleless
            # record could belong to a device role sharing this backend.
            resume_store.remove_fabric(fabric.fabric_id, fabric.root_public_key,
              fabric.controller_node_id, role: Session::Case::Role::Initiator,
              include_legacy: false)
            icd_peers.remove_fabric(fabric.fabric_id, fabric.root_public_key,
              fabric.controller_node_id)
          end
        end
      rescue ex : Matter::StorageError
        raise ex
      rescue ex
        raise Matter::StorageError.new("Failed to save controller state (path=#{@backend.path.inspect}): #{ex.message}", cause: ex)
      end

      # Keep the read, mutation and write inside one backend transaction. The
      # block must contain only local state changes; perform network work first.
      def update(& : State -> T) : T forall T
        result = uninitialized T
        @backend.open unless @backend.open?
        @backend.transaction do
          state = load
          result = yield state
          save(state)
        end
        result
      end

      # A SQL adapter may lose a cross-instance compare-and-swap race. Retry
      # only that conflict after reloading the new high watermark.
      def reserve_unsecured_message_counters(count : UInt32, claim_owner : Bool = false) : UInt32
        @backend.claim_counter_lease_owner! if claim_owner
        reject_nested_counter_reservation!
        attempts = 0
        loop do
          return update(&.reserve_unsecured_message_counters(count))
        rescue ex : ConflictError
          attempts += 1
          raise ex if attempts >= COUNTER_RESERVATION_CONFLICT_RETRIES
        end
      end

      # When the store is still empty, keep the first leased source identity
      # aligned with the commissioner identity that commissioning will persist.
      def reserve_unsecured_message_counters_for(source_node_id : UInt64, count : UInt32) : UInt32
        @backend.claim_counter_lease_owner!
        reject_nested_counter_reservation!
        attempts = 0
        loop do
          return update do |state|
            state.commissioner_node_id = source_node_id if state.storage_snapshot.nil?
            state.reserve_unsecured_message_counters(count)
          end
        rescue ex : ConflictError
          attempts += 1
          raise ex if attempts >= COUNTER_RESERVATION_CONFLICT_RETRIES
        end
      end

      private def reject_nested_counter_reservation! : Nil
        if @backend.transaction_open?
          raise Matter::StorageError.new("Counter reservation cannot commit inside an open storage transaction")
        end
      end

      # Older saves could durably remove a fabric before deleting its separate
      # CASE and ICD records. The controller state is authoritative only for
      # initiator CASE records. Responder and roleless records may belong to a
      # device writer that does not share this state row's transaction lock.
      private def purge_orphaned_credentials(state : State) : Nil
        fabrics = state.fabrics
        @backend.all(Session::Case::ResumptionStore::COLLECTION).each do |id, document|
          record = decode_case_record(document, id)
          next unless record
          next unless record.role == Session::Case::Role::Initiator
          controller_owned = fabrics.any? do |fabric|
            same_fabric?(fabric, record.fabric_id, record.root_public_key, record.local_node_id)
          end
          next if controller_owned
          @backend.delete(Session::Case::ResumptionStore::COLLECTION, id)
        end
        @backend.all(IcdPeerStore::COLLECTION).each do |id, document|
          record = decode_icd_record(document, id)
          next unless record
          controller_owned = fabrics.any? do |fabric|
            same_fabric?(fabric, record.fabric_id, record.root_public_key, record.controller_node_id)
          end
          next if controller_owned
          @backend.delete(IcdPeerStore::COLLECTION, id)
        end
      end

      private def decode_case_record(document : Storage::Document, id : String) : Session::Case::ResumptionStore::Record?
        Session::Case::ResumptionStore::Record.from_document(document)
      rescue ex
        Log.warn(exception: ex) { "Keeping undecodable CASE resumption #{id} during controller cleanup" }
        nil
      end

      private def decode_icd_record(document : Storage::Document, id : String) : IcdPeerStore::Record?
        IcdPeerStore::Record.from_document(document)
      rescue ex
        Log.warn(exception: ex) { "Keeping undecodable ICD peer #{id} during controller cleanup" }
        nil
      end

      private def same_fabric?(fabric : FabricInfo, fabric_id : UInt64,
                               root_public_key : Bytes, controller_node_id : UInt64) : Bool
        fabric.fabric_id == fabric_id && fabric.root_public_key == root_public_key &&
          fabric.controller_node_id == controller_node_id
      end

      private def normalize(state : State) : {State, Bool}
        dirty = false

        if fabric = state.fabric
          if state.commissioner_node_id != fabric.controller_node_id
            state.commissioner_node_id = fabric.controller_node_id
            dirty = true
          end
        elsif state.commissioner_node_id == DataType::NodeId::UNSPECIFIED
          state.commissioner_node_id = random_nonzero_u64
          dirty = true
        end

        {state, dirty}
      end

      private def random_nonzero_u64 : UInt64
        DataType::NodeId.random_operational.id
      end
    end
  end
end
