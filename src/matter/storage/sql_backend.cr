require "db"
require "./backend"
require "./sql_document_codec"

module Matter
  module Storage
    # Versioned, driver-neutral relational layout. The first version needs one
    # table for documents; later versions can migrate it in this transaction.
    module SqlSchema
      VERSION = 1_i64

      VERSION_TABLE  = "matter_storage_schema"
      DOCUMENT_TABLE = "matter_storage_documents"

      CREATE_VERSION_TABLE  = "CREATE TABLE IF NOT EXISTS #{VERSION_TABLE} (version BIGINT NOT NULL)"
      CREATE_DOCUMENT_TABLE = "CREATE TABLE IF NOT EXISTS #{DOCUMENT_TABLE} (collection TEXT NOT NULL, id TEXT NOT NULL, payload TEXT NOT NULL, PRIMARY KEY (collection, id))"

      def self.prepare(connection : DB::Connection) : Nil
        connection.transaction do
          connection.exec(CREATE_VERSION_TABLE)
          stored_version = connection.query_one?("SELECT version FROM #{VERSION_TABLE}", as: Int64)
          version = stored_version || 0_i64
          if version > VERSION
            raise StorageError.new("SQL storage schema version #{version} is newer than the supported version #{VERSION}")
          end

          ((version + 1)..VERSION).each do |next_version|
            case next_version
            when 1
              connection.exec(CREATE_DOCUMENT_TABLE)
            else
              raise StorageError.new("No SQL storage migration for version #{next_version}")
            end
          end

          if stored_version
            connection.exec("UPDATE #{VERSION_TABLE} SET version = #{VERSION}") if version < VERSION
          else
            connection.exec("INSERT INTO #{VERSION_TABLE} (version) VALUES (#{VERSION})")
          end
        end
      end
    end

    # Common storage implementation for relational DB drivers. Only the
    # connection URL, bind placeholder syntax, and destruction are adapter
    # specific; SQLite and PostgreSQL share this layout and typed JSON codec.
    abstract class SqlBackend < Backend
      @database : DB::Database? = nil
      @connection : DB::Connection? = nil
      @current_transaction : DB::Transaction? = nil
      @mutex = Mutex.new(:reentrant)

      def initialize(@database_url : String)
      end

      def durable? : Bool
        true
      end

      protected abstract def bind(index : Int32) : String

      # Driver exceptions need not inherit DB::Error. Keep their recognition in
      # each optional adapter so this common layer has no driver dependency.
      protected def driver_error?(error : Exception) : Bool
        false
      end

      protected def prepare_schema(connection : DB::Connection) : Nil
        SqlSchema.prepare(connection)
      end

      def open? : Bool
        @mutex.synchronize { !@connection.nil? }
      end

      def open : Nil
        @mutex.synchronize do
          return if @connection

          database = DB.open(@database_url)
          begin
            connection = database.checkout
            begin
              prepare_schema(connection)
              connection.exec(insert_if_absent_sql, Collections::META, Collections::META_SCHEMA_ID,
                SqlDocumentCodec.encode(Backend.schema_document))
              schema_payload = connection.query_one(read_sql, Collections::META, Collections::META_SCHEMA_ID, as: String)
              schema = SqlDocumentCodec.decode(schema_payload)
              Backend.check_schema(schema)
              @database = database
              @connection = connection
            rescue ex
              connection.release
              raise ex
            end
          rescue ex
            database.close
            raise StorageError.new("Could not open SQL storage", ex) if ex.is_a?(DB::Error) || driver_error?(ex)
            raise ex
          end
        end
      rescue ex
        raise StorageError.new("Could not open SQL storage", ex) if ex.is_a?(DB::Error) || driver_error?(ex)
        raise ex
      end

      def close : Nil
        @mutex.synchronize do
          raise StorageError.new("Cannot close SQL storage during a transaction") if @current_transaction
          @connection.try(&.release)
          @connection = nil
          @database.try(&.close)
          @database = nil
        end
      end

      def read(collection : String, id : String) : Document?
        validate(collection, id)
        with_connection do |connection|
          connection.query_one?(read_sql, collection, id, as: String).try { |payload| SqlDocumentCodec.decode(payload) }
        end
      end

      def write(collection : String, id : String, document : Document) : Nil
        validate(collection, id)
        payload = SqlDocumentCodec.encode(Storage.deep_copy(document))
        with_connection do |connection|
          mutate(connection) do
            connection.exec(upsert_sql, collection, id, payload)
          end
        end
      end

      def delete(collection : String, id : String) : Nil
        validate(collection, id)
        with_connection do |connection|
          mutate(connection) { connection.exec(delete_sql, collection, id) }
        end
      end

      def ids(collection : String) : Array(String)
        validate_collection(collection)
        with_connection do |connection|
          connection.query_all("SELECT id FROM #{SqlSchema::DOCUMENT_TABLE} WHERE collection = #{bind(1)} ORDER BY id", collection, as: String)
        end
      end

      def all(collection : String) : Hash(String, Document)
        validate_collection(collection)
        with_connection do |connection|
          documents = Hash(String, Document).new
          connection.query("SELECT id, payload FROM #{SqlSchema::DOCUMENT_TABLE} WHERE collection = #{bind(1)} ORDER BY id", collection) do |result|
            result.each do
              id, payload = result.read(String, String)
              documents[id] = SqlDocumentCodec.decode(payload)
            end
          end
          documents
        end
      end

      def collections : Array(String)
        with_connection do |connection|
          connection.query_all("SELECT DISTINCT collection FROM #{SqlSchema::DOCUMENT_TABLE} ORDER BY collection", as: String)
        end
      end

      def clear(collection : String) : Nil
        validate_collection(collection)
        with_connection do |connection|
          mutate(connection) do
            connection.exec("DELETE FROM #{SqlSchema::DOCUMENT_TABLE} WHERE collection = #{bind(1)}", collection)
          end
        end
      end

      def clear_all : Nil
        with_connection do |connection|
          mutate(connection) do
            connection.exec("DELETE FROM #{SqlSchema::DOCUMENT_TABLE} WHERE NOT (collection = #{bind(1)} AND id = #{bind(2)})",
              Collections::META, Collections::META_SCHEMA_ID)
            connection.exec(insert_if_absent_sql, Collections::META, Collections::META_SCHEMA_ID,
              SqlDocumentCodec.encode(Backend.schema_document))
          end
        end
      end

      def transaction(& : -> Nil) : Nil
        with_connection do |connection|
          if parent = @current_transaction
            parent.transaction do |nested|
              @current_transaction = nested
              begin
                yield
              ensure
                @current_transaction = parent
              end
            end
          else
            connection.transaction do |current|
              @current_transaction = current
              begin
                yield
              ensure
                @current_transaction = nil
              end
            end
          end
        end
      end

      private def read_sql : String
        "SELECT payload FROM #{SqlSchema::DOCUMENT_TABLE} WHERE collection = #{bind(1)} AND id = #{bind(2)}"
      end

      private def delete_sql : String
        "DELETE FROM #{SqlSchema::DOCUMENT_TABLE} WHERE collection = #{bind(1)} AND id = #{bind(2)}"
      end

      private def insert_sql : String
        "INSERT INTO #{SqlSchema::DOCUMENT_TABLE} (collection, id, payload) VALUES (#{bind(1)}, #{bind(2)}, #{bind(3)})"
      end

      private def insert_if_absent_sql : String
        "#{insert_sql} ON CONFLICT (collection, id) DO NOTHING"
      end

      private def upsert_sql : String
        "#{insert_sql} ON CONFLICT (collection, id) DO UPDATE SET payload = EXCLUDED.payload"
      end

      private def mutate(connection : DB::Connection, & : -> Nil) : Nil
        if current = @current_transaction
          # PostgreSQL aborts a transaction after a statement error. Roll a
          # caught mutation back to a savepoint so the outer transaction can
          # still commit its other writes.
          current.transaction { yield }
        else
          connection.transaction { yield }
        end
      end

      private def with_connection(& : DB::Connection -> T) : T forall T
        @mutex.synchronize do
          ensure_open
          connection = @connection || raise StorageError.new("SQL storage is not open")
          yield connection
        end
      rescue ex : JSON::ParseException
        raise StorageError.new("Stored SQL document is invalid JSON", ex)
      rescue ex
        raise StorageError.new("SQL storage operation failed", ex) if ex.is_a?(DB::Error) || driver_error?(ex)
        raise ex
      end
    end
  end
end
