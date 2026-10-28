require "file_utils"
require "./tree_backend"

module Matter
  module Storage
    # A store persisted as a single file.
    #
    # The whole tree lives in memory; `open` loads it (a missing file is an
    # empty store) and every mutation outside a `transaction` rewrites the
    # file atomically: encode, write `<path>.tmp`, fsync, rename over *path*,
    # then fsync the directory (best effort).
    #
    # A file that cannot be decoded is logged, renamed to
    # `<path>.corrupt-<timestamp>` and the store starts empty.
    #
    # Subclasses implement only `encode` and `decode`.
    abstract class FileBackend < TreeBackend
      TEMP_SUFFIX              = ".tmp"
      CORRUPT_SUFFIX           = ".corrupt-"
      CORRUPT_TIMESTAMP_FORMAT = "%Y%m%dT%H%M%S"

      getter path : String
      @counter_lease_lock : File? = nil
      @counter_lease_epoch = Atomic(UInt64).new(0_u64)

      def durable? : Bool
        true
      end

      def counter_lease_namespace : String
        "file:#{File.expand_path(@path)}"
      end

      def counter_lease_validity : Proc(Nil)?
        epoch = @counter_lease_epoch.get
        -> do
          unless @counter_lease_epoch.get == epoch
            raise Matter::StorageError.new("Counter lease owner was closed: #{@path}")
          end
        end
      end

      def initialize(@path : String)
      end

      # Hold an advisory lock for the lifetime of the open backend. Another
      # lease owner for this path, even in the same process, must fail closed.
      # Other state writers, including writers not acquiring counter leases,
      # must reuse this backend instance. Advisory locks are cooperative.
      def claim_counter_lease_owner! : Nil
        @mutex.synchronize do
          return if @counter_lease_lock
          raise Matter::StorageError.new("Cannot claim a counter lease inside a storage transaction") if @transaction_depth > 0
          lock_path = "#{File.expand_path(@path)}.counter.lock"
          FileUtils.mkdir_p(File.dirname(lock_path))
          lock_file = File.open(lock_path, "a")
          begin
            lock_file.flock_exclusive(blocking: false)
          rescue ex : IO::Error
            lock_file.close
            raise Matter::StorageError.new("Counter lease storage path is owned by another writer: #{@path}", cause: ex)
          end
          begin
            replace_tree(load) if @open
            @counter_lease_lock = lock_file
            @counter_lease_epoch.add(1_u64)
          rescue ex
            lock_file.close
            raise ex
          end
        end
      end

      # Serialises the tree. Every document must survive a `decode` round trip.
      protected abstract def encode(tree : Tree) : String

      # Parses *content* produced by `encode`. Raise on malformed input.
      protected abstract def decode(content : String) : Tree

      def open : Nil
        @mutex.synchronize do
          return if @open
          replace_tree(load)
          @open = true
        end
      end

      def close : Nil
        @mutex.synchronize do
          @open = false
          if lock_file = @counter_lease_lock
            @counter_lease_lock = nil
            @counter_lease_epoch.add(1_u64)
            lock_file.flock_unlock
            lock_file.close
          end
        end
      end

      def destroy! : Nil
        @mutex.synchronize do
          close
          @tree.clear
          File.delete?(@path)
          File.delete?(temp_path)
        end
      end

      protected def persist : Nil
        flush
      end

      # Writes the tree to disk atomically.
      protected def flush : Nil
        seed_schema(@tree[Collections::META]?.try(&.[Collections::META_SCHEMA_ID]?))
        content = encode(@tree)
        directory = File.dirname(@path)
        FileUtils.mkdir_p(directory)

        File.open(temp_path, "w") do |file|
          file << content
          file.flush
          file.fsync
        end
        File.rename(temp_path, @path)
        sync_directory(directory)
      end

      private def temp_path : String
        "#{@path}#{TEMP_SUFFIX}"
      end

      private def sync_directory(directory : String) : Nil
        File.open(directory, "r", &.fsync)
      rescue IO::Error
        # Some filesystems (and platforms) do not support fsync on a directory
        # handle; the rename itself is still atomic.
      end

      private def load : Tree
        return Tree.new unless File.exists?(@path)

        content = File.read(@path)
        return Tree.new if content.strip.empty?

        decode(content)
      rescue ex
        quarantine(ex)
      end

      private def quarantine(ex : Exception) : Tree
        corrupt_path = "#{@path}#{CORRUPT_SUFFIX}#{Time.utc.to_s(CORRUPT_TIMESTAMP_FORMAT)}"
        Log.error(exception: ex) { "Storage file #{@path} is corrupt; moving it to #{corrupt_path} and starting empty" }
        File.rename(@path, corrupt_path)
        Tree.new
      end
    end
  end
end
