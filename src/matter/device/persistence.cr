require "log"

require "../debouncer"
require "../hex"
require "../fabric_table"
require "../protocol/persistence"
require "../cluster/cluster"
require "../storage/backend"
require "../commissioning/credential_journal"
require "../commissioning/fabric_removal_journal"

module Matter
  abstract class Device
    # Everything a device persists, on one `Storage::Backend`:
    #
    # * `fabrics` via `FabricTable`, `sessions`/`subscriptions` via
    #   `Protocol::Persistence::StorageBackend`
    # * `clusters/<endpoint>-<cluster id>`: each cluster's `save_state` document
    # * `device/identity`: commissioning hostname, serial number and unique id
    # * `app/<id>`: free-form documents for the application
    #
    # Writes that happen on every message (cluster data versions, fabric
    # last-used times, session counters) are coalesced: a change marks the
    # owner dirty and arms one `SAVE_DEBOUNCE` timer; when it fires everything
    # dirty is written in a single backend transaction. `flush` writes
    # synchronously and is called from `Device#shutdown!`.
    class Persistence
      Log = ::Log.for("matter.device.persistence")

      # How long to wait after a change before writing it.
      SAVE_DEBOUNCE = 250.milliseconds

      CLUSTERS = Storage::Collections::CLUSTERS
      DEVICE   = Storage::Collections::DEVICE
      APP      = Storage::Collections::APP

      IDENTITY_ID       = "identity"
      HOSTNAME_KEY      = "commissioning_hostname"
      SERIAL_NUMBER_KEY = "serial_number"
      UNIQUE_ID_KEY     = "unique_id"

      # Generated hostnames are 16 uppercase hex digits followed by this suffix;
      # `update_hostname` may store any other `.local` name.
      HOSTNAME_SUFFIX = ".local"

      # Random bytes behind a generated serial number (16 hex digits) and
      # unique id (32 hex digits).
      SERIAL_NUMBER_BYTES =  8
      UNIQUE_ID_BYTES     = 16

      getter backend : Storage::Backend
      getter fabric_table : FabricTable
      getter protocol_persistence : Protocol::Persistence::StorageBackend
      getter recovered_added_fabric_index : UInt8?

      @debouncer : Debouncer
      @dirty_clusters : Set(Cluster::Base) = Set(Cluster::Base).new

      def initialize(@backend : Storage::Backend, max_fabrics : UInt8 = FabricTable::DEFAULT_MAX_FABRICS)
        @backend.open unless @backend.open?
        @recovered_added_fabric_index = Commissioning::CredentialJournal.recover(@backend)
        Commissioning::FabricRemovalJournal.recover(@backend)
        @debouncer = Debouncer.new(SAVE_DEBOUNCE) { write_dirty }

        @fabric_table = FabricTable.new(@backend, max_fabrics: max_fabrics)
        @fabric_table.write_debouncer = @debouncer

        @protocol_persistence = Protocol::Persistence::StorageBackend.new(@backend)
        @protocol_persistence.write_debouncer = @debouncer
      end

      # ------------------------------------------------------------------------
      # Clusters
      # ------------------------------------------------------------------------

      # Marks *cluster* dirty whenever its data version changes.
      def track(cluster : Cluster::Base) : Nil
        cluster.on_version_changed = -> { mark_dirty(cluster) }
      end

      # Writes the cluster's state now. Returns false when it has none.
      def save_cluster(cluster : Cluster::Base) : Bool
        document = cluster.save_state
        return false unless document

        @dirty_clusters.delete(cluster)
        @backend.write(CLUSTERS, cluster.persistence_key, document)
        Log.debug { "Saved state for cluster #{cluster.name} (#{cluster.persistence_key})" }
        true
      rescue ex
        Log.error(exception: ex) { "Failed to save cluster state (cluster=#{cluster.name} key=#{cluster.persistence_key})" }
        false
      end

      # Writes every cluster's state in one transaction; returns how many had state.
      def save_clusters(clusters : Enumerable(Cluster::Base)) : Int32
        saved = 0
        @backend.transaction do
          clusters.each { |cluster| saved += 1 if save_cluster(cluster) }
        end
        Log.info { "Saved state for #{saved} cluster(s)" } if saved > 0
        saved
      end

      # Restores the state of every cluster that has a document and starts
      # tracking all of them; returns how many were restored.
      def restore_clusters(clusters : Enumerable(Cluster::Base)) : Int32
        restored = 0
        clusters.each do |cluster|
          track(cluster)
          restored += 1 if restore_cluster(cluster)
        end
        Log.info { "Restored state for #{restored} cluster(s)" } if restored > 0
        restored
      end

      # Removes the stored state of the cluster at *endpoint*/*cluster_id*.
      def forget_cluster(endpoint : UInt16, cluster_id : UInt32) : Nil
        key = Cluster::Base.persistence_key(endpoint, cluster_id)
        @dirty_clusters.reject! { |cluster| cluster.persistence_key == key }
        @backend.delete(CLUSTERS, key)
      end

      # Stops tracking *cluster* and removes its stored state.
      def forget_cluster(cluster : Cluster::Base) : Nil
        cluster.on_version_changed = nil
        forget_cluster(cluster.endpoint_id.number, cluster.cluster_id.id)
      end

      private def restore_cluster(cluster : Cluster::Base) : Bool
        document = @backend.read(CLUSTERS, cluster.persistence_key)
        return false unless document

        cluster.restore_state(document)
        Log.debug { "Restored state for cluster #{cluster.name} (#{cluster.persistence_key})" }
        true
      rescue ex
        Log.error(exception: ex) { "Failed to restore cluster state (cluster=#{cluster.name} key=#{cluster.persistence_key})" }
        false
      end

      # Marks *cluster* as holding unsaved state; the debounced writer picks it
      # up on its next run. `track` wires this to the cluster's data version,
      # and `Node#on_version_changed` wires it node-wide.
      def mark_dirty(cluster : Cluster::Base) : Nil
        @dirty_clusters << cluster
        @debouncer.trigger
      end

      # ------------------------------------------------------------------------
      # Identity
      # ------------------------------------------------------------------------

      # The stored commissioning hostname, generating and storing one when
      # missing or malformed.
      def commissioning_hostname : String
        stored = identity[HOSTNAME_KEY]?.as?(String).try(&.strip)
        return stored if stored && stored.ends_with?(HOSTNAME_SUFFIX) && stored.size > HOSTNAME_SUFFIX.size

        hostname = generate_hostname
        write_identity(HOSTNAME_KEY, hostname)
        hostname
      rescue ex
        Log.error(exception: ex) { "Failed to load or persist the commissioning hostname; using a transient value" }
        generate_hostname
      end

      # Stores *hostname* as the commissioning hostname.
      def update_hostname(hostname : String) : Nil
        write_identity(HOSTNAME_KEY, hostname)
      end

      # The stored serial number, generating and storing one when missing.
      def serial_number : String
        load_or_create(SERIAL_NUMBER_KEY, "serial number") { generate_serial_number }
      end

      # The stored unique id, generating and storing one when missing.
      def unique_id : String
        load_or_create(UNIQUE_ID_KEY, "unique id") { generate_unique_id }
      end

      private def load_or_create(key : String, what : String, & : -> String) : String
        stored = identity[key]?.as?(String)
        return stored if stored && !stored.empty?

        value = yield
        write_identity(key, value)
        value
      rescue ex
        Log.error(exception: ex) { "Failed to load or persist the #{what}; using a transient value" }
        yield
      end

      private def identity : Storage::Document
        @backend.read(DEVICE, IDENTITY_ID) || Storage::Document.new
      end

      private def write_identity(key : String, value : String) : Nil
        document = identity
        document[key] = value
        @backend.write(DEVICE, IDENTITY_ID, document)
      end

      private def generate_hostname : String
        "#{Hex.node_id(Random::Secure.rand(UInt64))}#{HOSTNAME_SUFFIX}"
      end

      private def generate_serial_number : String
        Random::Secure.hex(SERIAL_NUMBER_BYTES).upcase
      end

      private def generate_unique_id : String
        Random::Secure.hex(UNIQUE_ID_BYTES)
      end

      # ------------------------------------------------------------------------
      # Application documents
      # ------------------------------------------------------------------------

      def app_document(id : String) : Storage::Document?
        @backend.read(APP, id)
      end

      def write_app_document(id : String, document : Storage::Document) : Nil
        @backend.write(APP, id, document)
      end

      def delete_app_document(id : String) : Nil
        @backend.delete(APP, id)
      end

      # ------------------------------------------------------------------------
      # Lifecycle
      # ------------------------------------------------------------------------

      # Writes everything dirty now.
      def flush : Nil
        @debouncer.cancel
        write_dirty
      end

      # Called after AccessControl state is restored and the provisional
      # fabric's ACL has been durably removed. Until then the add journal stays
      # present, so another restart repeats the cleanup safely.
      def complete_credential_recovery : Nil
        return unless @recovered_added_fabric_index
        Commissioning::CredentialJournal.clear(@backend)
        @recovered_added_fabric_index = nil
      end

      # Flushes and closes the backend.
      def close : Nil
        return unless @backend.open?

        flush
        @backend.close
      end

      # Factory reset: drops every document and removes the persisted data.
      def reset! : Nil
        @debouncer.cancel
        @dirty_clusters.clear
        @backend.open unless @backend.open?
        @backend.clear_all
        @backend.destroy!
      end

      private def write_dirty : Nil
        return unless @backend.open?

        pending = @dirty_clusters.to_a
        @dirty_clusters.clear
        @backend.transaction do
          pending.each { |cluster| save_cluster(cluster) }
          @fabric_table.flush_pending_writes
          @protocol_persistence.flush_pending_writes
        end
      end
    end
  end
end
