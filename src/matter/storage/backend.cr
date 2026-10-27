require "../error"
require "./document"

module Matter
  module Storage
    # Persistent document store: named collections of `Document`s keyed by id.
    #
    # Every read hands back a deep copy and every write stores a deep copy, so
    # callers never share mutable state with the store. Collection names and
    # ids are validated against `Storage::NAME_PATTERN`.
    #
    # Every store carries a `meta/schema` document (`{"version" => 1}`) that
    # `clear_all` preserves; opening a store written by a newer schema raises
    # `Matter::StorageError`.
    abstract class Backend
      # Opens the store, loading any persisted state.
      abstract def open : Nil

      # Closes the store. Operations on a closed store raise `Matter::StorageError`.
      abstract def close : Nil

      abstract def open? : Bool

      # Returns a deep copy of the document, or `nil` when it does not exist.
      abstract def read(collection : String, id : String) : Document?

      # Stores a deep copy of *document*, creating the collection if needed.
      abstract def write(collection : String, id : String, document : Document) : Nil

      # Removes the document; a no-op when it does not exist.
      abstract def delete(collection : String, id : String) : Nil

      # Sorted ids of the collection (empty when the collection does not exist).
      abstract def ids(collection : String) : Array(String)

      # Deep copies of every document in the collection, keyed by id.
      abstract def all(collection : String) : Hash(String, Document)

      # Sorted names of every non-empty collection.
      abstract def collections : Array(String)

      # Removes every document in the collection.
      abstract def clear(collection : String) : Nil

      # Removes every collection except `meta/schema`.
      abstract def clear_all : Nil

      # Groups writes so file backends flush once at the end of the outermost
      # transaction. Transactions may be nested.
      abstract def transaction(& : -> Nil) : Nil

      # Whether writes survive a process restart. Custom backends opt in only
      # when they can preserve the completed review journal durably.
      def durable? : Bool
        false
      end

      # Location of the persisted data, `nil` when there is no local file.
      abstract def path : String?

      # Closes the store and removes its persisted data.
      abstract def destroy! : Nil

      # The schema document every store carries at `meta/schema`.
      def self.schema_document : Document
        Document{Collections::SCHEMA_VERSION_KEY => Collections::SCHEMA_VERSION}
      end

      # Raises `Matter::StorageError` when *document* declares a schema version
      # this library does not understand.
      def self.check_schema(document : Document?) : Nil
        return unless document

        version = document[Collections::SCHEMA_VERSION_KEY]?
        return if version.nil?

        unless version.is_a?(Int64 | UInt64) && version <= Collections::SCHEMA_VERSION
          raise StorageError.new("Storage schema version #{version.inspect} is newer than the supported version #{Collections::SCHEMA_VERSION}")
        end
      end

      protected def ensure_open : Nil
        raise StorageError.new("#{self.class.name} is not open") unless open?
      end

      protected def validate(collection : String, id : String) : Nil
        Storage.validate_name(collection, "collection")
        Storage.validate_name(id, "id")
      end

      protected def validate_collection(collection : String) : Nil
        Storage.validate_name(collection, "collection")
      end
    end
  end
end
