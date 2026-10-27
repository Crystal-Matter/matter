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

      def durable? : Bool
        true
      end

      def initialize(@path : String)
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
