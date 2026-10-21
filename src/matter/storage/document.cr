require "../error"

module Matter
  module Storage
    # A value that can be persisted by a `Storage::Backend`.
    #
    # Documents carry only wide scalars: every integer is an `Int64` (or a
    # `UInt64` when it does not fit in an `Int64`) and every float a `Float64`.
    # Narrow widths (`UInt16`, `Float32`, enums, ...) belong to `Storage::Record`
    # types, which convert on the way in and out.
    # ameba:disable Style/VerboseNilType -- the leading `Nil` keeps the alias readable as a list of members.
    alias Type = Nil | Bool | Int64 | UInt64 | Float64 | String | Bytes | Time | Array(Type) | Hash(String, Type)

    # A single stored entity: a string-keyed map of `Type` values.
    alias Document = Hash(String, Type)

    # Well-known collection and document names.
    module Collections
      FABRICS          = "fabrics"
      SESSIONS         = "sessions"
      CASE_RESUMPTIONS = "case_resumptions"
      SUBSCRIPTIONS    = "subscriptions"
      DEVICE           = "device"
      CLUSTERS         = "clusters"
      APP              = "app"
      META             = "meta"

      # `meta/schema` records the on-disk layout version of a store.
      META_SCHEMA_ID     = "schema"
      SCHEMA_VERSION_KEY = "version"
      SCHEMA_VERSION     = 1_i64
    end

    # Collection names and document ids must be non-empty, contain no `/` and
    # be safe to use as file or key names.
    NAME_PATTERN = /\A[A-Za-z0-9_.:-]+\z/

    # Raises `Matter::StorageError` unless *name* is a valid collection name or
    # document id. *kind* names the offending argument in the message.
    def self.validate_name(name : String, kind : String) : String
      unless name.matches?(NAME_PATTERN)
        raise StorageError.new("Invalid storage #{kind} #{name.inspect}: must be non-empty and match #{NAME_PATTERN.source}")
      end
      name
    end

    # Returns an independent copy of *value*: nested arrays, hashes and byte
    # slices are duplicated so the result shares no mutable state with the
    # original. `UInt64` values that fit in an `Int64` are normalised to
    # `Int64` so every backend hands back the same representation.
    def self.deep_copy(value : Type) : Type
      case value
      in Nil, Bool, Int64, Float64, String, Time
        value
      in UInt64
        value <= Int64::MAX ? value.to_i64 : value
      in Bytes
        value.dup
      in Array(Type)
        value.map { |element| deep_copy(element).as(Type) }
      in Hash(String, Type)
        deep_copy(value)
      end
    end

    # :ditto:
    def self.deep_copy(document : Document) : Document
      copy = Document.new(initial_capacity: document.size)
      document.each { |key, element| copy[key] = deep_copy(element) }
      copy
    end
  end
end
