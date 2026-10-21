require "../storage/backend"
require "../session/case/resumption_store"
require "./icd_peer_store"
require "./state"

module Matter
  module Controller
    # Persists the controller `State` as the `controller/state` document of a
    # `Storage::Backend`.
    class StateStore
      COLLECTION  = "controller"
      DOCUMENT_ID = "state"

      getter backend : Storage::Backend

      def initialize(@backend : Storage::Backend)
      end

      def load : State
        @backend.open unless @backend.open?

        document = @backend.read(COLLECTION, DOCUMENT_ID)
        state = document ? State.from_document(document) : State.new

        state, dirty = normalize(state)
        save(state) if dirty && document
        state
      rescue ex : Matter::StorageError
        raise ex
      rescue ex
        raise Matter::StorageError.new("Failed to load controller state (path=#{@backend.path.inspect}): #{ex.message}", cause: ex)
      end

      def save(state : State) : Nil
        @backend.open unless @backend.open?
        previous = @backend.read(COLLECTION, DOCUMENT_ID)
        previous_fabrics = previous ? State.from_document(previous).fabrics : [] of FabricInfo
        @backend.write(COLLECTION, DOCUMENT_ID, state.to_document)
        remaining = state.fabrics
        resume_store = Session::Case::ResumptionStore.new(@backend)
        icd_peers = IcdPeerStore.new(@backend)
        previous_fabrics.each do |fabric|
          next if remaining.any? do |installed|
                    installed.fabric_id == fabric.fabric_id &&
                    installed.root_public_key == fabric.root_public_key &&
                    installed.controller_node_id == fabric.controller_node_id
                  end
          resume_store.remove_fabric(fabric.fabric_id, fabric.root_public_key,
            fabric.controller_node_id)
          icd_peers.remove_fabric(fabric.fabric_id, fabric.root_public_key,
            fabric.controller_node_id)
        end
      rescue ex : Matter::StorageError
        raise ex
      rescue ex
        raise Matter::StorageError.new("Failed to save controller state (path=#{@backend.path.inspect}): #{ex.message}", cause: ex)
      end

      private def normalize(state : State) : {State, Bool}
        dirty = false

        if fabric = state.fabric
          if state.commissioner_node_id != fabric.controller_node_id
            state.commissioner_node_id = fabric.controller_node_id
            dirty = true
          end
        elsif state.commissioner_node_id == 0_u64
          state.commissioner_node_id = random_nonzero_u64
          dirty = true
        end

        {state, dirty}
      end

      private def random_nonzero_u64 : UInt64
        loop do
          id = Random::Secure.rand(UInt64)
          return id unless id == 0_u64
        end
      end
    end
  end
end
