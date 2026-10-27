require "openssl"
require "tlv"
require "../error"

module Matter
  module Protocol
    # Matter OTA Software Image v1 (Core 1.6 §11.21.2). Validation streams the
    # payload through a digest and never retains it in memory. The caller owns
    # the IO and should pass a completed BDX download or another finite source.
    module OtaImage
      MAGIC                  = 0x1BEEF11E_u32
      PREFIX_SIZE            =         16_u64
      MAX_HEADER_BYTES       =       4096_u32
      DEFAULT_MAX_TOTAL      = 64_u64 * 1024 * 1024
      DIGEST_BUFFER_BYTES    =  8192
      UNSPECIFIED_VENDOR_ID  = 0_u16
      UNSPECIFIED_PRODUCT_ID = 0_u16

      class InvalidImage < Matter::Error
      end

      struct Header
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property vendor_id : UInt16

        @[TLV::Field(tag: 1)]
        property product_id : UInt16

        @[TLV::Field(tag: 2)]
        property software_version : UInt32

        @[TLV::Field(tag: 3)]
        property software_version_string : String

        @[TLV::Field(tag: 4)]
        property payload_size : UInt64

        @[TLV::Field(tag: 5, optional: true)]
        property min_applicable_software_version : UInt32?

        @[TLV::Field(tag: 6, optional: true)]
        property max_applicable_software_version : UInt32?

        @[TLV::Field(tag: 7, optional: true)]
        property release_notes_url : String?

        @[TLV::Field(tag: 8)]
        property image_digest_type : UInt8

        @[TLV::Field(tag: 9)]
        property image_digest : Bytes

        def initialize(@vendor_id : UInt16 = UNSPECIFIED_VENDOR_ID,
                       @product_id : UInt16 = UNSPECIFIED_PRODUCT_ID,
                       @software_version : UInt32 = 0_u32,
                       @software_version_string : String = "",
                       @payload_size : UInt64 = 0_u64,
                       @min_applicable_software_version : UInt32? = nil,
                       @max_applicable_software_version : UInt32? = nil,
                       @release_notes_url : String? = nil,
                       @image_digest_type : UInt8 = 1_u8,
                       @image_digest : Bytes = Bytes.empty)
        end
      end

      # Validate the complete image against the QueryImage offer and the
      # requestor's current identity/version. Zero VID/PID are wildcard values
      # in the image format. The caller may lower or raise the image size cap.
      def self.validate(io : IO, vendor_id : UInt16, product_id : UInt16,
                        current_version : UInt32, offered_version : UInt32,
                        max_total_bytes : UInt64 = DEFAULT_MAX_TOTAL) : Header
        magic = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
        raise InvalidImage.new("Invalid OTA image identifier") unless magic == MAGIC

        total_size = io.read_bytes(UInt64, IO::ByteFormat::LittleEndian)
        header_size = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
        unless total_size >= PREFIX_SIZE && total_size <= max_total_bytes &&
               header_size > 0 && header_size <= MAX_HEADER_BYTES &&
               header_size.to_u64 <= total_size - PREFIX_SIZE
          raise InvalidImage.new("Invalid OTA image size")
        end

        header_bytes = Bytes.new(header_size.to_i)
        io.read_fully(header_bytes)
        header = Header.from_slice(header_bytes)
        validate_header!(header, vendor_id, product_id, current_version,
          offered_version, total_size - PREFIX_SIZE - header_size)

        algorithm, digest_bytes = digest_algorithm(header.image_digest_type)
        unless header.image_digest.size == digest_bytes
          raise InvalidImage.new("Invalid OTA image digest length")
        end
        digest = OpenSSL::Digest.new(algorithm)
        buffer = Bytes.new(DIGEST_BUFFER_BYTES)
        remaining = header.payload_size
        while remaining > 0
          count = {remaining, DIGEST_BUFFER_BYTES.to_u64}.min.to_i
          read = io.read(buffer[0, count])
          raise InvalidImage.new("Truncated OTA payload") if read == 0
          digest.update(buffer[0, read])
          remaining -= read.to_u64
        end
        raise InvalidImage.new("OTA image digest mismatch") unless digest.final == header.image_digest
        raise InvalidImage.new("Trailing OTA image bytes") unless io.read_byte.nil?
        header
      rescue ex : IO::EOFError | TLV::DeserializationError
        raise InvalidImage.new("Truncated or malformed OTA image: #{ex.message}")
      end

      private def self.validate_header!(header : Header, vendor_id : UInt16,
                                        product_id : UInt16, current_version : UInt32,
                                        offered_version : UInt32,
                                        declared_payload_size : UInt64) : Nil
        unless (header.vendor_id == UNSPECIFIED_VENDOR_ID || header.vendor_id == vendor_id) &&
               (header.product_id == UNSPECIFIED_PRODUCT_ID || header.product_id == product_id)
          raise InvalidImage.new("OTA image vendor or product mismatch")
        end
        unless offered_version > current_version && header.software_version == offered_version
          raise InvalidImage.new("OTA image software version mismatch")
        end
        unless header.payload_size == declared_payload_size &&
               header.software_version_string.bytesize.in?(1..64)
          raise InvalidImage.new("Invalid OTA image header fields")
        end
        if minimum = header.min_applicable_software_version
          raise InvalidImage.new("OTA image is too new for the current version") if current_version < minimum
        end
        if maximum = header.max_applicable_software_version
          raise InvalidImage.new("OTA image is too old for the current version") if current_version > maximum
        end
        if notes = header.release_notes_url
          unless notes.bytesize.in?(1..256) && notes.starts_with?("https://")
            raise InvalidImage.new("Invalid OTA release notes URL")
          end
        end
      end

      private def self.digest_algorithm(type : UInt8) : {String, Int32}
        case type
        when  1_u8 then {"SHA256", 32}
        when  7_u8 then {"SHA384", 48}
        when  8_u8 then {"SHA512", 64}
        when 10_u8 then {"SHA3-256", 32}
        else
          raise InvalidImage.new("Unsupported OTA image digest algorithm #{type}")
        end
      end
    end
  end
end
