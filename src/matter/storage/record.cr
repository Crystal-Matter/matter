require "../error"
require "./document"

module Matter
  module Storage
    # Per-field options for `Storage::Record`:
    #
    # * `key:` the document key to use instead of the ivar name
    # * `ignore:` leave the ivar out of the document (it must be nilable or
    #   have a default value)
    annotation Field
    end

    # Maps a struct or class to a `Document`.
    #
    # ```
    # struct Fabric
    #   include Matter::Storage::Record
    #
    #   @[Matter::Storage::Field(key: "fabric_id")]
    #   getter id : UInt64
    #   getter label : String = ""
    #   getter root_key : Bytes
    #   getter last_seen : Time?
    #
    #   def initialize(@id, @root_key, @label = "", @last_seen = nil)
    #   end
    # end
    #
    # document = fabric.to_document
    # fabric = Fabric.from_document(document)
    # ```
    #
    # Supported field types: `Bool`, `String`, every fixed-width `Int`
    # (range-checked on read), `Float32`/`Float64`, `Bytes`, `Time`, enums
    # (written by member name, read by name or by value), other `Record`s,
    # `Array(T)` and `Hash(K, T)` where `K` is
    # `String` or an `Int` type, and nilable variants of any of these. `nil`
    # values are omitted from the document; missing keys become `nil` for
    # nilable fields, the ivar's default value when it has one, and otherwise
    # raise `Matter::StorageError`. Extra document keys are ignored.
    module Record
      macro included
        def self.from_document(document : ::Matter::Storage::Document) : self
          new_from_storage_document(document)
        end

        # A subclass that declares its own `initialize` hides inherited
        # constructors, so the instance is allocated and initialised explicitly
        # (the same approach `JSON::Serializable` takes).
        private def self.new_from_storage_document(document : ::Matter::Storage::Document) : self
          instance = allocate
          instance.initialize(__storage_document: document)
          ::GC.add_finalizer(instance) if instance.responds_to?(:finalize)
          instance
        end

        macro inherited
          def self.from_document(document : ::Matter::Storage::Document) : self
            new_from_storage_document(document)
          end
        end

        def to_document : ::Matter::Storage::Document
          document = ::Matter::Storage::Document.new
          {% verbatim do %}
            {% for ivar in @type.instance_vars %}
              {% ann = ivar.annotation(::Matter::Storage::Field) %}
              {% unless ann && ann[:ignore] %}
                {% key = (ann && ann[:key]) || ivar.name.stringify %}
                unless (%value = @{{ ivar.name }}).nil?
                  document[{{ key }}] = ::Matter::Storage::Record.encode(%value)
                end
              {% end %}
            {% end %}
          {% end %}
          document
        end

        protected def initialize(*, __storage_document document : ::Matter::Storage::Document)
          {% verbatim do %}
            {% for ivar in @type.instance_vars %}
              {% ann = ivar.annotation(::Matter::Storage::Field) %}
              {% key = (ann && ann[:key]) || ivar.name.stringify %}
              {% if ann && ann[:ignore] %}
                {% if ivar.has_default_value? %}
                  @{{ ivar.name }} = {{ ivar.default_value }}
                {% elsif ivar.type.nilable? %}
                  @{{ ivar.name }} = nil
                {% else %}
                  {% raise "Storage::Record: ignored field #{@type}##{ivar.name} must be nilable or have a default value" %}
                {% end %}
              {% else %}
                if document.has_key?({{ key }})
                  @{{ ivar.name }} = ::Matter::Storage::Record.decode(document[{{ key }}], {{ ivar.type }}, {{ key }})
                else
                  {% if ivar.type.nilable? %}
                    @{{ ivar.name }} = nil
                  {% elsif ivar.has_default_value? %}
                    @{{ ivar.name }} = {{ ivar.default_value }}
                  {% else %}
                    raise ::Matter::StorageError.new("Missing required field #{{{ key }}} for #{{{ @type.stringify }}}")
                  {% end %}
                end
              {% end %}
            {% end %}
          {% end %}
        end
      end

      # Converts a field value to its document representation.
      def self.encode(value : Bool | Int64 | Float64 | String | Bytes | Time?) : Type
        value
      end

      def self.encode(value : UInt64) : Type
        value
      end

      # Narrow integers widen to `Int64`; `UInt64` is handled above.
      def self.encode(value : Int) : Type
        value.to_i64
      end

      def self.encode(value : Float32) : Type
        value.to_f64
      end

      def self.encode(value : Enum) : Type
        value.to_s
      end

      def self.encode(value : Record) : Type
        value.to_document
      end

      def self.encode(value : Array) : Type
        value.map { |element| encode(element).as(Type) }
      end

      def self.encode(value : Hash) : Type
        document = Document.new(initial_capacity: value.size)
        value.each { |key, element| document[key.to_s] = encode(element) }
        document
      end

      def self.encode(value : Tuple | NamedTuple) : Type
        {% raise "Storage::Record: tuples and named tuples are not storable; use a nested Record" %}
      end

      # Converts a document value back to the field type *type*, raising
      # `Matter::StorageError` naming *field* on a mismatch.
      def self.decode(value : Type, type : T.class, field : String) : T forall T
        {% if T.nilable? %}
          {% inner = T.union_types.reject { |member| member == Nil } %}
          {% raise "Storage::Record: unsupported union field type #{T} (only nilable unions are storable)" unless inner.size == 1 %}
          return nil if value.nil?
          decode(value, {{ inner.first }}, field)
        {% elsif T == Bool %}
          value.is_a?(Bool) ? value : type_error(field, T, value)
        {% elsif T == String || T == Time || T == Bytes %}
          value.as?(T) || type_error(field, T, value)
        {% elsif T <= Int %}
          integer = value.as?(Int64) || value.as?(UInt64) || type_error(field, T, value)
          begin
            T.new(integer)
          rescue OverflowError
            raise StorageError.new("Field #{field}: #{integer} is out of range for #{T}")
          end
        {% elsif T <= Float %}
          number = value.as?(Float64) || value.as?(Int64) || value.as?(UInt64) || type_error(field, T, value)
          T.new(number)
        {% elsif T <= Enum %}
          case value
          in String
            parsed = T.parse?(value)
            {% if T.annotation(::Flags) %}
              unless parsed
                mask = 0_u64
                value.split(" | ").each do |member|
                  flag = T.parse?(member) || raise StorageError.new("Field #{field}: #{value.inspect} is not a member of #{T}")
                  mask |= flag.value.to_u64
                end
                parsed = T.from_value?(mask)
              end
            {% end %}
            parsed || raise StorageError.new("Field #{field}: #{value.inspect} is not a member of #{T}")
          in Int64, UInt64
            # Stores imported from the legacy format hold enums by value.
            T.from_value?(value) || raise StorageError.new("Field #{field}: #{value} is not a value of #{T}")
          in Type
            type_error(field, T, value)
          end
        {% elsif T <= Record %}
          T.from_document(value.as?(Document) || type_error(field, T, value))
        {% elsif T <= Array %}
          elements = value.as?(Array(Type)) || type_error(field, T, value)
          elements.map { |element| decode(element, {{ T.type_vars.first }}, field) }
        {% elsif T <= Hash %}
          entries = value.as?(Document) || type_error(field, T, value)
          result = T.new(initial_capacity: entries.size)
          entries.each do |key, element|
            result[decode_key(key, {{ T.type_vars.first }}, field)] = decode(element, {{ T.type_vars.last }}, field)
          end
          result
        {% else %}
          {% raise "Storage::Record: unsupported field type #{T} (tuples and named tuples are not storable; use a nested Record)" %}
        {% end %}
      end

      # Parses a stringified hash key back to *type* (`String` or an `Int`).
      def self.decode_key(key : String, type : K.class, field : String) : K forall K
        {% if K == String %}
          key
        {% elsif K <= Int %}
          integer = key.to_i64? || key.to_u64? || raise StorageError.new("Field #{field}: key #{key.inspect} is not an integer")
          begin
            K.new(integer)
          rescue OverflowError
            raise StorageError.new("Field #{field}: key #{key} is out of range for #{K}")
          end
        {% else %}
          {% raise "Storage::Record: hash keys must be String or an Int type, got #{K}" %}
        {% end %}
      end

      private def self.type_error(field : String, type, value : Type) : NoReturn
        raise StorageError.new("Field #{field}: expected #{type}, got #{value.class}")
      end
    end
  end
end
