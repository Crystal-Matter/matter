require "log"
require "../storage/backend"
require "../fabric"
require "../session/case/resumption_store"
require "./icd_peer_store"
require "./state"

module Matter
  module Controller
    # Persists the controller `State` as the `controller/state` document of a
    # `Storage::Backend`.
    class StateStore
      Log = ::Log.for("matter.controller.state_store")

      COLLECTION  = "controller"
      DOCUMENT_ID = "state"

      getter backend : Storage::Backend

      def initialize(@backend : Storage::Backend)
      end

      def load : State
        @backend.open unless @backend.open?
        state = State.new
        @backend.transaction do
          document = @backend.read(COLLECTION, DOCUMENT_ID)
          state = document ? State.from_document(document) : State.new
          state, dirty = normalize(state)
          devices, uncertain_device_identity = device_fabrics
          purge_orphaned_credentials(state, devices, uncertain_device_identity)
          @backend.write(COLLECTION, DOCUMENT_ID, state.to_document) if dirty && document
          state.storage_snapshot = document ? Storage.deep_copy(dirty ? state.to_document : document) : nil
          state.storage_loaded = true
        end
        state
      rescue ex : Matter::StorageError
        raise ex
      rescue ex
        raise Matter::StorageError.new("Failed to load controller state (path=#{@backend.path.inspect}): #{ex.message}", cause: ex)
      end

      def save(state : State) : Nil
        @backend.open unless @backend.open?
        @backend.transaction do
          previous = @backend.read(COLLECTION, DOCUMENT_ID)
          if state.storage_loaded? && previous != state.storage_snapshot
            raise Matter::StorageError.new("Controller state changed since load; reload before saving")
          end
          prior_state = previous ? State.from_document(previous) : State.new
          devices, uncertain_device_identity = device_fabrics
          purge_orphaned_credentials(prior_state, devices, uncertain_device_identity)
          document = state.to_document
          @backend.write(COLLECTION, DOCUMENT_ID, document)
          remaining = state.fabrics
          resume_store = Session::Case::ResumptionStore.new(@backend)
          icd_peers = IcdPeerStore.new(@backend)
          prior_state.fabrics.each do |fabric|
            next if remaining.any? do |installed|
                      same_fabric?(installed, fabric.fabric_id, fabric.root_public_key,
                        fabric.controller_node_id)
                    end
            # A JFA can use one backend for both roles. A roleless legacy
            # record is ambiguous while a matching or unreadable device
            # fabric exists; new controller records can always be removed.
            include_legacy = !uncertain_device_identity && !device_fabric?(devices,
              fabric.fabric_id, fabric.root_public_key, fabric.controller_node_id)
            resume_store.remove_fabric(fabric.fabric_id, fabric.root_public_key,
              fabric.controller_node_id, role: Session::Case::Role::Initiator,
              include_legacy: include_legacy)
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

      # Older saves could durably remove a fabric before deleting its separate
      # CASE and ICD records. The controller state is the authority for which
      # operational identities still own these secrets. Device-role CASE
      # records may share this backend. Old roleless records are ambiguous when
      # a device fabric still owns the identity or a device document is corrupt.
      private def purge_orphaned_credentials(state : State, devices : Array(Fabric),
                                             uncertain_device_identity : Bool) : Nil
        fabrics = state.fabrics
        @backend.all(Session::Case::ResumptionStore::COLLECTION).each do |id, document|
          record = decode_case_record(document, id)
          next unless record
          controller_owned = fabrics.any? do |fabric|
            same_fabric?(fabric, record.fabric_id, record.root_public_key, record.local_node_id)
          end
          device_owned = device_fabric?(devices, record.fabric_id,
            record.root_public_key, record.local_node_id)
          owned = case record.role
                  when Session::Case::Role::Initiator then controller_owned
                  when Session::Case::Role::Responder then device_owned || uncertain_device_identity
                  else                                     controller_owned || device_owned || uncertain_device_identity
                  end
          next if owned
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

      private def device_fabrics : {Array(Fabric), Bool}
        devices = [] of Fabric
        uncertain = false
        @backend.all(Storage::Collections::FABRICS).each do |id, document|
          if fabric = decode_device_fabric(document, id)
            devices << fabric
          else
            uncertain = true
          end
        end
        {devices, uncertain}
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

      private def decode_device_fabric(document : Storage::Document, id : String) : Fabric?
        Fabric.from_document(document)
      rescue ex
        Log.warn(exception: ex) { "Ignoring undecodable device fabric #{Storage::Collections::FABRICS}/#{id} during controller cleanup" }
        nil
      end

      private def device_fabric?(devices : Array(Fabric), fabric_id : UInt64,
                                 root_public_key : Bytes, node_id : UInt64) : Bool
        devices.any? do |fabric|
          fabric.fabric_id == fabric_id && fabric.root_public_key == root_public_key &&
            fabric.node_id == node_id
        end
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
        loop do
          id = Random::Secure.rand(UInt64)
          return id unless id == DataType::NodeId::UNSPECIFIED
        end
      end
    end
  end
end
