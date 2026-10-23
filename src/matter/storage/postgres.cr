# Opt-in PostgreSQL storage. Applications must add the `pg` shard and require
# this file explicitly; the default `require "matter"` does not load the driver.
require "pg"
require "./sql_backend"
require "./migrator"

module Matter
  module Storage
    class Postgres < SqlBackend
      # Serializes first-open DDL among independent processes sharing a database.
      # PostgreSQL advisory locks are scoped to the current database.
      SCHEMA_LOCK_KEY = 0x4D41545445525351_i64

      def initialize(@url : String)
        unless @url.starts_with?("postgres://") || @url.starts_with?("postgresql://")
          raise StorageError.new("PostgreSQL storage requires a postgres:// or postgresql:// URL")
        end
        super(@url)
      end

      # Network storage has no local file path; returning the connection URL
      # here would expose a password to callers of Backend#path.
      def path : String?
        nil
      end

      # Removes only Matter's two tables, never the containing database.
      def destroy! : Nil
        close
        DB.open(@url) do |database|
          connection = database.checkout
          begin
            connection.transaction do
              connection.exec("DROP TABLE IF EXISTS #{SqlSchema::DOCUMENT_TABLE}")
              connection.exec("DROP TABLE IF EXISTS #{SqlSchema::VERSION_TABLE}")
            end
          ensure
            connection.release
          end
        end
      rescue ex
        raise StorageError.new("Could not destroy PostgreSQL storage", ex) if ex.is_a?(DB::Error) || driver_error?(ex)
        raise ex
      end

      protected def bind(index : Int32) : String
        "$#{index}"
      end

      protected def driver_error?(error : Exception) : Bool
        error.is_a?(PG::Error | PQ::PQError | PQ::ConnectionError)
      end

      protected def prepare_schema(connection : DB::Connection) : Nil
        connection.exec("SELECT pg_advisory_lock($1)", SCHEMA_LOCK_KEY)
        begin
          SqlSchema.prepare(connection)
        ensure
          connection.exec("SELECT pg_advisory_unlock($1)", SCHEMA_LOCK_KEY)
        end
      end
    end

    Migrator.register_scheme("postgres") do |rest|
      Postgres.new("postgres:#{rest}").tap(&.open)
    end

    Migrator.register_scheme("postgresql") do |rest|
      Postgres.new("postgresql:#{rest}").tap(&.open)
    end
  end
end
