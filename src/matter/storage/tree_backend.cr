require "./backend"

module Matter
  module Storage
    # The whole store as nested hashes: `{collection => {id => document}}`.
    alias Tree = Hash(String, Hash(String, Document))

    # Shared implementation for backends that keep the complete store in
    # memory as a `Tree`: `Memory` and every `FileBackend`.
    #
    # Every public method holds a reentrant mutex so a store can be shared
    # between fibers. Mutations call `persist`, which subclasses use to write
    # the tree out; inside a `transaction` the tree is marked dirty instead and
    # persisted once when the outermost transaction ends. Each transaction
    # retains a snapshot so a raised block also rolls back only its own writes.
    abstract class TreeBackend < Backend
      @tree = Tree.new
      @mutex = Mutex.new(:reentrant)
      @transaction_depth = 0
      @dirty = false
      @open = false

      def open? : Bool
        @open
      end

      def close : Nil
        @mutex.synchronize { @open = false }
      end

      def read(collection : String, id : String) : Document?
        validate(collection, id)
        @mutex.synchronize do
          ensure_open
          @tree[collection]?.try(&.[id]?).try { |document| Storage.deep_copy(document) }
        end
      end

      def write(collection : String, id : String, document : Document) : Nil
        validate(collection, id)
        @mutex.synchronize do
          ensure_open
          (@tree[collection] ||= Hash(String, Document).new)[id] = Storage.deep_copy(document)
          changed
        end
      end

      def delete(collection : String, id : String) : Nil
        validate(collection, id)
        @mutex.synchronize do
          ensure_open
          documents = @tree[collection]?
          return unless documents && documents.has_key?(id)

          documents.delete(id)
          @tree.delete(collection) if documents.empty?
          changed
        end
      end

      def ids(collection : String) : Array(String)
        validate_collection(collection)
        @mutex.synchronize do
          ensure_open
          @tree[collection]?.try(&.keys.sort!) || [] of String
        end
      end

      def all(collection : String) : Hash(String, Document)
        validate_collection(collection)
        @mutex.synchronize do
          ensure_open
          result = Hash(String, Document).new
          if documents = @tree[collection]?
            documents.keys.sort!.each { |id| result[id] = Storage.deep_copy(documents[id]) }
          end
          result
        end
      end

      def collections : Array(String)
        @mutex.synchronize do
          ensure_open
          @tree.compact_map { |name, documents| name unless documents.empty? }.sort!
        end
      end

      def clear(collection : String) : Nil
        validate_collection(collection)
        @mutex.synchronize do
          ensure_open
          changed if @tree.delete(collection)
        end
      end

      def clear_all : Nil
        @mutex.synchronize do
          ensure_open
          schema = @tree[Collections::META]?.try(&.[Collections::META_SCHEMA_ID]?)
          @tree.clear
          seed_schema(schema)
          changed
        end
      end

      def transaction(& : -> Nil) : Nil
        @mutex.synchronize do
          ensure_open
          previous_tree = snapshot_tree
          previous_dirty = @dirty
          @transaction_depth += 1
          begin
            yield
            if @transaction_depth == 1 && @dirty
              persist
              @dirty = false
            end
          rescue ex
            @tree = previous_tree
            @dirty = previous_dirty
            raise ex
          ensure
            @transaction_depth -= 1
          end
        end
      end

      # Writes the in-memory tree out. Called after every mutation outside a
      # transaction and once at the end of the outermost transaction.
      protected abstract def persist : Nil

      # Ensures `meta/schema` exists, keeping *schema* when one was loaded.
      protected def seed_schema(schema : Document? = nil) : Nil
        meta = (@tree[Collections::META] ||= Hash(String, Document).new)
        meta[Collections::META_SCHEMA_ID] = schema || Backend.schema_document
      end

      protected def replace_tree(tree : Tree) : Nil
        Backend.check_schema(tree[Collections::META]?.try(&.[Collections::META_SCHEMA_ID]?))
        @tree = tree
        seed_schema(tree[Collections::META]?.try(&.[Collections::META_SCHEMA_ID]?))
      end

      private def changed : Nil
        if @transaction_depth.zero?
          persist
        else
          @dirty = true
        end
      end

      private def snapshot_tree : Tree
        snapshot = Tree.new
        @tree.each do |collection, documents|
          copied = Hash(String, Document).new
          documents.each { |id, document| copied[id] = Storage.deep_copy(document) }
          snapshot[collection] = copied
        end
        snapshot
      end
    end
  end
end
