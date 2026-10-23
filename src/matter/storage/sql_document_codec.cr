require "json"
require "base64"
require "./document"

module Matter
  module Storage
    # Collision-free JSON representation of every Storage::Type for SQL rows.
    # Each value is tagged, so application maps may contain any key, including
    # keys resembling the wrappers in the file JSON format.
    module SqlDocumentCodec
      NIL_TAG   = "nil"
      BOOL_TAG  = "bool"
      INT_TAG   = "i64"
      UINT_TAG  = "u64"
      FLOAT_TAG = "f64"
      TEXT_TAG  = "text"
      BYTES_TAG = "bytes"
      TIME_TAG  = "time"
      ARRAY_TAG = "array"
      MAP_TAG   = "map"

      TIME_FRACTION_DIGITS = 9

      def self.encode(document : Document) : String
        JSON.build do |json|
          encode_map(json, document)
        end
      end

      def self.decode(payload : String) : Document
        pull = JSON::PullParser.new(payload)
        document = decode_map(pull)
        raise StorageError.new("Unexpected content after SQL document") unless pull.kind.eof?
        document
      rescue ex : JSON::ParseException | ArgumentError | Base64::Error
        raise StorageError.new("Invalid SQL document payload", ex)
      end

      private def self.encode_map(json : JSON::Builder, document : Document) : Nil
        json.object do
          document.each do |key, value|
            json.field(key) { encode_value(json, value) }
          end
        end
      end

      private def self.encode_value(json : JSON::Builder, value : Type) : Nil
        json.array do
          case value
          in Nil
            json.string(NIL_TAG)
          in Bool
            json.string(BOOL_TAG)
            json.bool(value)
          in Int64
            json.string(INT_TAG)
            json.number(value)
          in UInt64
            json.string(UINT_TAG)
            json.number(value)
          in Float64
            json.string(FLOAT_TAG)
            json.string(value.to_s)
          in String
            json.string(TEXT_TAG)
            json.string(value)
          in Bytes
            json.string(BYTES_TAG)
            json.string(Base64.strict_encode(value))
          in Time
            json.string(TIME_TAG)
            json.string(Time::Format::RFC_3339.format(value.to_utc, fraction_digits: TIME_FRACTION_DIGITS))
          in Array(Type)
            json.string(ARRAY_TAG)
            json.array { value.each { |element| encode_value(json, element) } }
          in Hash(String, Type)
            json.string(MAP_TAG)
            encode_map(json, value)
          end
        end
      end

      private def self.decode_map(pull : JSON::PullParser) : Document
        document = Document.new
        pull.read_object { |key| document[key] = decode_value(pull) }
        document
      end

      private def self.decode_value(pull : JSON::PullParser) : Type
        pull.read_begin_array
        tag = pull.read_string
        value = case tag
                when NIL_TAG
                  nil
                when BOOL_TAG
                  pull.read_bool
                when INT_TAG
                  pull.read_raw.to_i64
                when UINT_TAG
                  pull.read_raw.to_u64
                when FLOAT_TAG
                  pull.read_string.to_f64
                when TEXT_TAG
                  pull.read_string
                when BYTES_TAG
                  Base64.decode(pull.read_string)
                when TIME_TAG
                  Time::Format::RFC_3339.parse(pull.read_string)
                when ARRAY_TAG
                  array = [] of Type
                  pull.read_array { array << decode_value(pull) }
                  array
                when MAP_TAG
                  decode_map(pull)
                else
                  raise StorageError.new("Unknown SQL document type #{tag.inspect}")
                end
        pull.read_end_array
        value.as(Type)
      end
    end
  end
end
