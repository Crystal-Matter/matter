# Opt-in SQLite storage. Applications must add the `sqlite3` shard and require
# this file explicitly; the default `require "matter"` does not load the driver.
require "sqlite3"
require "file_utils"
require "./sql_backend"
require "./migrator"

module Matter
  module Storage
    class Sqlite < SqlBackend
      BUSY_TIMEOUT_MS = 5_000

      getter path : String

      def initialize(@path : String)
        raise StorageError.new("SQLite storage path must not be empty") if @path.empty?

        absolute_path = File.expand_path(@path)
        database_url = "sqlite3://#{URI.encode_path(absolute_path)}?busy_timeout=#{BUSY_TIMEOUT_MS}&journal_mode=wal&synchronous=full"
        super(database_url)
      end

      def open : Nil
        FileUtils.mkdir_p(File.dirname(@path))
        super
      end

      def destroy! : Nil
        close
        File.delete?(@path)
        File.delete?("#{@path}-wal")
        File.delete?("#{@path}-shm")
      end

      protected def bind(index : Int32) : String
        "?"
      end
    end

    Migrator.register_scheme("sqlite") do |path|
      raise StorageError.new("Storage URI sqlite: needs a file path") if path.empty?
      Sqlite.new(path).tap(&.open)
    end
  end
end
