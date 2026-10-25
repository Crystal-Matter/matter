require "../fabric"
require "../storage/backend"

module Matter
  module Commissioning
    # An undo record for state erased before FabricTable releases an index.
    # Recovery runs before the device loads fabrics or cluster documents.
    module FabricRemovalJournal
      COLLECTION   = Storage::Collections::DEVICE
      ID           = "pending_fabric_removal"
      INDEX        = "fabric_index"
      CLUSTERS     = "clusters"
      APP          = "app"
      CLUSTER_IDS  = "cluster_ids"
      APP_IDS      = "app_ids"
      ID_SEPARATOR = ","

      def self.start(backend : Storage::Backend, index : UInt8,
                     cluster_documents : Storage::Document? = nil,
                     app_ids : Array(String) = [] of String) : Nil
        raise StorageError.new("A fabric removal is already pending") if backend.read(COLLECTION, ID)
        cluster_documents ||= snapshot(backend, Storage::Collections::CLUSTERS,
          backend.ids(Storage::Collections::CLUSTERS))
        cluster_ids = cluster_documents.keys
        backend.write(COLLECTION, ID, Storage::Document{
          INDEX       => index.to_i64,
          CLUSTER_IDS => cluster_ids.join(ID_SEPARATOR),
          APP_IDS     => app_ids.join(ID_SEPARATOR),
          CLUSTERS    => cluster_documents,
          APP         => snapshot(backend, Storage::Collections::APP, app_ids),
        })
      end

      def self.snapshot(backend : Storage::Backend, collection : String,
                        ids : Array(String)) : Storage::Document
        result = Storage::Document.new
        ids.each do |id|
          if document = backend.read(collection, id)
            result[id] = document
          end
        end
        result
      end

      def self.previous(backend : Storage::Backend, collection : String, id : String) : Storage::Document?
        record = backend.read(COLLECTION, ID) || return
        key = collection == Storage::Collections::CLUSTERS ? CLUSTERS : APP
        documents = record[key]?.as?(Storage::Document) || return
        documents[id]?.as?(Storage::Document)
      end

      # Roll back only when the caller knows the fabric delete was never tried.
      # A file backend can mutate its in-memory tree before a failed flush, so
      # delete errors must be resolved after reopening durable storage.
      def self.rollback(backend : Storage::Backend) : Nil
        restore_documents(backend)
        clear(backend)
      end

      def self.restore_documents(backend : Storage::Backend) : Nil
        record = backend.read(COLLECTION, ID) || return
        restore_collection(backend, Storage::Collections::CLUSTERS,
          ids(record, CLUSTER_IDS), record[CLUSTERS].as(Storage::Document))
        restore_collection(backend, Storage::Collections::APP,
          ids(record, APP_IDS), record[APP].as(Storage::Document))
      end

      def self.recover(backend : Storage::Backend) : Nil
        record = backend.read(COLLECTION, ID) || return
        index = record[INDEX]?.as?(Int64) || raise StorageError.new("Invalid pending fabric removal index")
        unless (Fabric::MIN_FABRIC_INDEX..Fabric::MAX_FABRIC_INDEX).includes?(index)
          raise StorageError.new("Invalid pending fabric removal index")
        end
        if backend.read(Storage::Collections::FABRICS, index.to_s)
          rollback(backend)
        else
          clear(backend)
        end
      end

      def self.clear(backend : Storage::Backend) : Nil
        backend.delete(COLLECTION, ID)
      end

      private def self.ids(record : Storage::Document, key : String) : Array(String)
        value = record[key]?.as?(String) || raise StorageError.new("Invalid pending fabric removal key list")
        value.empty? ? [] of String : value.split(ID_SEPARATOR)
      end

      private def self.restore_collection(backend : Storage::Backend, collection : String,
                                          ids : Array(String), previous : Storage::Document) : Nil
        ids.each do |id|
          if value = previous[id]?
            document = value.as?(Storage::Document) || raise StorageError.new("Invalid pending fabric removal snapshot")
            backend.write(collection, id, document) unless backend.read(collection, id) == document
          else
            backend.delete(collection, id) if backend.read(collection, id)
          end
        end
      end
    end
  end
end
