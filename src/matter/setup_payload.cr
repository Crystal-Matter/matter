require "big"

module Matter
  # SetupPayload handles encoding and decoding of Matter onboarding payloads
  #
  # Matter devices use two types of setup codes:
  # 1. Manual Pairing Code: 11-digit decimal code (formatted as xxxx-xxx-xxxx)
  # 2. QR Code: Longer base38-encoded string with additional device information
  #
  # Manual Pairing Code Format (Matter Core Spec § 5.1.4.1):
  # - Bits 0-26: Setup PIN Code (27 bits)
  # - Bits 27-38: Discriminator (12 bits)
  # - Bit 39: Check digit (4 bits, Verhoeff algorithm)
  #
  # The 11-digit code is computed as: (discriminator << 27) | PIN
  # Then the Verhoeff check digit is appended.
  module SetupPayload
    TEST_VENDOR_ID_MINIMUM                     = 0xFFF1_u16
    TEST_VENDOR_ID_EXCLUSIVE_MAXIMUM           = 0xFFF4_u16
    SHORT_DISCRIMINATOR_UNSPECIFIED_BITS_MASK  = 0x00FF_u16
    MANUAL_CODE_DISCRIMINATOR_MIDDLE_BITS_MASK =      0x300
    MANUAL_CODE_DISCRIMINATOR_DIGIT_MASK       =       0x03
    MANUAL_CODE_PASSCODE_LOW_BITS_MASK         =     0x3fff

    # Verhoeff check digit algorithm
    # Used by Matter for manual pairing code validation
    module Verhoeff
      # Multiplication table
      D = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9],
        [1, 2, 3, 4, 0, 6, 7, 8, 9, 5],
        [2, 3, 4, 0, 1, 7, 8, 9, 5, 6],
        [3, 4, 0, 1, 2, 8, 9, 5, 6, 7],
        [4, 0, 1, 2, 3, 9, 5, 6, 7, 8],
        [5, 9, 8, 7, 6, 0, 4, 3, 2, 1],
        [6, 5, 9, 8, 7, 1, 0, 4, 3, 2],
        [7, 6, 5, 9, 8, 2, 1, 0, 4, 3],
        [8, 7, 6, 5, 9, 3, 2, 1, 0, 4],
        [9, 8, 7, 6, 5, 4, 3, 2, 1, 0],
      ]

      # Permutation table
      P = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9],
        [1, 5, 7, 6, 2, 8, 3, 0, 9, 4],
        [5, 8, 0, 3, 7, 9, 6, 1, 4, 2],
        [8, 9, 1, 6, 0, 4, 3, 5, 2, 7],
        [9, 4, 5, 3, 1, 2, 6, 8, 7, 0],
        [4, 2, 8, 6, 5, 7, 3, 9, 0, 1],
        [2, 7, 9, 3, 8, 0, 6, 4, 1, 5],
        [7, 0, 4, 6, 9, 1, 3, 2, 5, 8],
      ]

      # Inverse table
      INV = [0, 4, 3, 2, 1, 5, 6, 7, 8, 9]

      # Compute Verhoeff check digit for a number string
      def self.compute(num : String) : Int32
        c = 0
        num.reverse.chars.each_with_index do |char, i|
          digit = char.to_i
          c = D[c][P[(i + 1) % 8][digit]]
        end
        INV[c]
      end

      # Validate a number string with Verhoeff check digit
      def self.validate(num_with_check : String) : Bool
        c = 0
        num_with_check.reverse.chars.each_with_index do |char, i|
          digit = char.to_i
          c = D[c][P[i % 8][digit]]
        end
        c == 0
      end
    end

    # generate a test vendor id
    def self.test_vendor_id : UInt16
      rand(TEST_VENDOR_ID_MINIMUM...TEST_VENDOR_ID_EXCLUSIVE_MAXIMUM)
    end

    # Generate a serial number
    def self.generate_serial_number : String
      "CM-#{Random::Secure.rand(100000..999999)}"
    end

    # Generate a random discriminator (12-bit value, 0-4095)
    # Each device instance should have a unique discriminator
    def self.generate_random_discriminator : UInt16
      Random::Secure.rand(4096).to_u16
    end

    # Generate a unique ID (UUID-like format)
    def self.generate_unique_id : String
      bytes = Random::Secure.random_bytes(16)
      bytes.hexstring.upcase
    end

    # Generate a random valid PIN that meets Matter requirements
    # - Must be 1-99999998
    # - Cannot be all same digit (11111111, etc.)
    # - Cannot be 12345678 or 87654321
    def self.generate_random_pin : UInt32
      loop do
        pin = Random::Secure.rand(1_u32..99999998_u32)
        pin_str = pin.to_s.rjust(8, '0')

        # Check if all digits are the same
        next if pin_str.chars.uniq!.size == 1

        # Check blacklisted PINs
        next if pin == 12345678 || pin == 87654321

        return pin
      end
    end

    # Generate a manual pairing code from discriminator and PIN
    #
    # @param discriminator Device discriminator (12-bit value, 0-4095)
    # @param pin Setup PIN code (27-bit value, 1-99999998, excluding invalid PINs)
    # @param validate Whether to validate PIN security requirements (default: true)
    # @return 11-digit manual pairing code string (formatted as xxxx-xxx-xxxx)
    #
    # Algorithm from matter.js PairingCodeSchema.ts (Matter Core Spec § 5.1.4.1)
    def self.generate_manual_code(discriminator : UInt16, pin : UInt32, validate : Bool = true) : String
      # Validate discriminator (12 bits = 0-4095)
      raise ArgumentError.new("Discriminator must be 0-4095") if discriminator > 4095

      if validate
        # Validate PIN (27 bits, but Matter has specific restrictions)
        # PIN must be 1-99999998 and cannot be:
        # - 00000000, 11111111, 22222222, ..., 99999999
        # - 12345678, 87654321
        raise ArgumentError.new("PIN must be 1-99999998") if pin < 1 || pin > 99999998

        # Check for invalid repeating digit PINs
        pin_str = pin.to_s.rjust(8, '0')
        if pin_str.chars.uniq!.size == 1
          raise ArgumentError.new("PIN cannot be all the same digit")
        end

        # Check for specific invalid PINs
        if pin == 12345678 || pin == 87654321
          raise ArgumentError.new("PIN cannot be 12345678 or 87654321")
        end
      else
        # Minimal validation even when validate=false
        raise ArgumentError.new("PIN must be 1-99999998") if pin < 1 || pin > 99999998
      end

      # Encode using matter.js algorithm (matches Matter Core Spec § 5.1.4.1)
      # This encodes 10 digits before the check digit:
      # - Digit 1: Top 2 bits of discriminator (bits 10-11)
      # - Digits 2-6: Mixed discriminator (bits 8-9) and passcode (bits 0-13)
      # - Digits 7-10: Top bits of passcode (bits 14-27)

      result = ""

      # Digit 1: Top 2 bits of discriminator
      result += (discriminator >> 10).to_s

      # Digits 2-6: ((discriminator & 0x300) << 6) | (passcode & 0x3fff)
      # - discriminator & 0x300 isolates bits 8-9 of discriminator
      # - << 6 shifts left by 6 positions
      # - passcode & 0x3fff gets bottom 14 bits of passcode
      part2 = ((discriminator & MANUAL_CODE_DISCRIMINATOR_MIDDLE_BITS_MASK) << 6) |
              (pin & MANUAL_CODE_PASSCODE_LOW_BITS_MASK)
      result += part2.to_s.rjust(5, '0')

      # Digits 7-10: Top bits of passcode (passcode >> 14)
      part3 = pin >> 14
      result += part3.to_s.rjust(4, '0')

      # Compute Verhoeff check digit
      check_digit = Verhoeff.compute(result)

      # Append check digit to get 11-digit code
      full_code = result + check_digit.to_s

      # Format as xxxx-xxx-xxxx
      format_manual_code(full_code)
    end

    # Format an 11-digit code as xxxx-xxx-xxxx
    def self.format_manual_code(code : String) : String
      raise ArgumentError.new("Code must be 11 digits") if code.size != 11
      "#{code[0..3]}-#{code[4..6]}-#{code[7..10]}"
    end

    # Parse a formatted manual code back to discriminator and PIN
    #
    # @param formatted_code Manual code in xxxx-xxx-xxxx format (or with spaces/dashes stripped)
    # @return Tuple of {discriminator, pin}
    #
    # Note: Manual pairing codes only encode the SHORT discriminator (top 4 bits of the full 12-bit discriminator).
    # This function reconstructs the full discriminator from those 4 bits by assuming the lower 8 bits are zero.
    # Algorithm from matter.js PairingCodeSchema.ts
    def self.parse_manual_code(formatted_code : String) : {UInt16, UInt32}
      # Remove non-digit characters (dashes, spaces)
      code = formatted_code.gsub(/\D/, "")
      raise ArgumentError.new("Code must be 11 digits") if code.size != 11

      # Validate check digit
      unless Verhoeff.validate(code)
        raise ArgumentError.new("Invalid check digit")
      end

      # Decode using matter.js algorithm (reverse of encoding)
      # Digit 1: Contains top 2 bits of short discriminator + optional vendor/product flag
      digit1 = code[0].to_i

      # Digits 2-6: Contains bottom 2 bits of short discriminator (in high bits) + bottom 14 bits of passcode
      digits_2_6 = code[1..5].to_i

      # Digits 7-10: Contains top 14 bits of passcode (passcode >> 14)
      digits_7_10 = code[6..9].to_i

      # Extract short discriminator (4 bits)
      # Top 2 bits from digit 1 (bits 0-1, since bit 2 is vendor/product flag)
      # Bottom 2 bits from high bits of digits_2_6
      short_discriminator = ((digit1 & MANUAL_CODE_DISCRIMINATOR_DIGIT_MASK) << 2) |
                            ((digits_2_6 >> 14) & MANUAL_CODE_DISCRIMINATOR_DIGIT_MASK)

      # Extract passcode (27 bits)
      # Bottom 14 bits from digits_2_6, top 14 bits from digits_7_10
      passcode = (digits_2_6 & MANUAL_CODE_PASSCODE_LOW_BITS_MASK) | (digits_7_10 << 14)

      # Convert short discriminator (4 bits) back to full discriminator (12 bits)
      # The short discriminator is the top 4 bits (bits 8-11) of the full discriminator
      # So shift left by 8 to position them correctly
      discriminator = (short_discriminator << 8).to_u16

      {discriminator, passcode.to_u32}
    end

    # Generate a default PIN for testing/examples
    # Returns a valid PIN that's easy to remember
    def self.default_pin : UInt32
      20202021_u32 # A valid PIN that's not on the blacklist
    end

    # Compute the short discriminator (4 bits: bits 8-11 of the full 12-bit discriminator)
    # This is what gets encoded in manual pairing codes
    def self.short_discriminator(discriminator : UInt16) : UInt16
      (discriminator >> 8).to_u16
    end

    # QR Code payload generation for Matter onboarding
    #
    # Matter QR codes encode more information than manual codes:
    # - Vendor ID and Product ID
    # - Flow type and discovery capabilities
    # - Discriminator and setup PIN
    #
    # The payload uses TLV encoding and base-38 representation with "MT:" prefix
    #
    # Matter Core Spec § 5.1.4.2 - QR Code Format
    module QRCode
      # Commission flow types
      enum CommissionFlow : UInt8
        Standard         = 0 # Device not on IP network, needs commissioning
        UserActionNeeded = 1 # Device requires user action (e.g., press button)
        Custom           = 2 # Custom commissioning flow
        AlreadyOnNetwork = 3 # Device already on IP network
      end

      # Discovery capability flags
      @[Flags]
      enum DiscoveryCapability : UInt8
        None      = 0x00
        SoftAP    = 0x01 # WiFi soft access point
        BLE       = 0x02 # Bluetooth Low Energy
        OnNetwork = 0x04 # Already on IP network
      end

      # Base-38 alphabet for Matter QR codes
      BASE38_ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ-."

      # Generate Matter QR code payload string
      #
      # @param discriminator Device discriminator (12-bit)
      # @param pin Setup PIN code (27-bit)
      # @param vendor_id Vendor ID (16-bit)
      # @param product_id Product ID (16-bit)
      # @param flow Commission flow type
      # @param capabilities Discovery capabilities
      # @return QR code string with "MT:" prefix
      def self.generate_qr_code(
        discriminator : UInt16,
        pin : UInt32,
        vendor_id : UInt16,
        product_id : UInt16,
        flow : CommissionFlow = CommissionFlow::Standard,
        capabilities : DiscoveryCapability = DiscoveryCapability::BLE,
      ) : String
        # Validate inputs
        raise ArgumentError.new("Discriminator must be 0-4095") if discriminator > 4095
        raise ArgumentError.new("PIN must be 1-99999998") if pin < 1 || pin > 99999998

        # Encode payload as byte array with bit-packed fields
        # Matter spec defines specific bit layout:
        # Bits 0-2: Version (3 bits) = 0
        # Bits 3-18: Vendor ID (16 bits)
        # Bits 19-34: Product ID (16 bits)
        # Bits 35-36: Flow (2 bits)
        # Bits 37-44: Discovery capabilities (8 bits)
        # Bits 45-56: Discriminator (12 bits)
        # Bits 57-83: Setup PIN (27 bits)
        # Total: 84 bits = 11 bytes (rounded up from 10.5)

        # Create byte array (84 bits / 8 = 10.5 bytes, round up to 11)
        bytes = Bytes.new(11, 0_u8)

        # Pack bits into bytes using matter.js's byte-level bit packing
        # Version (bits 0-2, 3 bits)
        pack_bits(bytes, 0, 0_u64, 3)

        # Vendor ID (bits 3-18, 16 bits)
        pack_bits(bytes, 3, vendor_id.to_u64, 16)

        # Product ID (bits 19-34, 16 bits)
        pack_bits(bytes, 19, product_id.to_u64, 16)

        # Flow (bits 35-36, 2 bits)
        pack_bits(bytes, 35, flow.value.to_u64, 2)

        # Capabilities (bits 37-44, 8 bits)
        pack_bits(bytes, 37, capabilities.value.to_u64, 8)

        # Discriminator (bits 45-56, 12 bits)
        pack_bits(bytes, 45, discriminator.to_u64, 12)

        # PIN (bits 57-83, 27 bits)
        pack_bits(bytes, 57, pin.to_u64, 27)

        # Convert byte array to base-38 using matter.js's chunking algorithm
        encoded = encode_base38_from_bytes(bytes)

        # Add "MT:" prefix per Matter spec
        "MT:#{encoded}"
      end

      # Pack bits into a byte array at the specified bit offset
      # Implements matter.js ByteArrayBitmapSchema encoding logic
      private def self.pack_bits(bytes : Bytes, bit_offset : Int32, value : UInt64, bit_length : Int32)
        byte_offset = bit_offset // 8
        bit_offset_in_byte = bit_offset % 8
        mask = (1_u64 << bit_length) - 1
        num_value = value & mask

        while num_value != 0
          bytes[byte_offset] |= ((num_value << bit_offset_in_byte) & 0xFF).to_u8
          bits_written = 8 - bit_offset_in_byte
          bit_offset_in_byte = 0
          num_value >>= bits_written
          byte_offset += 1
        end
      end

      # Encode byte array to base-38 using matter.js's chunking algorithm
      # Processes bytes in 3-byte chunks (little-endian)
      # Each 3-byte chunk (24 bits) encodes to 5 base-38 characters
      # (since 38^5 = 79,235,168 > 2^24 = 16,777,216)
      private def self.encode_base38_from_bytes(bytes : Bytes) : String
        result = [] of String
        offset = 0
        length = bytes.size

        while offset < length
          remaining = length - offset

          if remaining > 2
            # 3 bytes -> 5 base-38 characters
            value = bytes[offset].to_u32 | (bytes[offset + 1].to_u32 << 8) | (bytes[offset + 2].to_u32 << 16)
            result << encode_base38_chunk(value, 5)
            offset += 3
          elsif remaining == 2
            # 2 bytes -> 4 base-38 characters
            value = bytes[offset].to_u32 | (bytes[offset + 1].to_u32 << 8)
            result << encode_base38_chunk(value, 4)
            break
          else
            # 1 byte -> 2 base-38 characters
            value = bytes[offset].to_u32
            result << encode_base38_chunk(value, 2)
            break
          end
        end

        result.join("")
      end

      # Encode a value to a fixed number of base-38 characters
      # Characters are emitted least-significant first (little-endian)
      private def self.encode_base38_chunk(value : UInt32, char_count : Int32) : String
        result = ""
        val = value

        char_count.times do
          remainder = val % 38
          result += BASE38_ALPHABET[remainder.to_i]
          val = (val - remainder) // 38
        end

        result
      end

      # Decode base-38 string to byte array using matter.js's chunking algorithm
      # Reverses the encode_base38_from_bytes process
      private def self.decode_base38_to_bytes(encoded : String) : Bytes
        encoded_length = encoded.size
        remainder_encoded_length = encoded_length % 5

        # Calculate decoded byte length
        decode_length = ((encoded_length - remainder_encoded_length) // 5) * 3
        decode_length += 2 if remainder_encoded_length == 4
        decode_length += 1 if remainder_encoded_length == 2

        raise CodecError.new("Invalid base38 encoded string length: #{encoded_length}") unless [0, 2, 4].includes?(remainder_encoded_length)

        result = Bytes.new(decode_length, 0_u8)
        decoded_offset = 0
        encoded_offset = 0

        while encoded_offset < encoded_length
          remaining = encoded_length - encoded_offset

          if remaining > 5
            # 5 characters -> 3 bytes
            value = decode_base38_chunk(encoded, encoded_offset, 5)
            result[decoded_offset] = (value & 0xFF).to_u8
            result[decoded_offset + 1] = ((value >> 8) & 0xFF).to_u8
            result[decoded_offset + 2] = ((value >> 16) & 0xFF).to_u8
            decoded_offset += 3
            encoded_offset += 5
          elsif remaining == 4
            # 4 characters -> 2 bytes
            value = decode_base38_chunk(encoded, encoded_offset, 4)
            result[decoded_offset] = (value & 0xFF).to_u8
            result[decoded_offset + 1] = ((value >> 8) & 0xFF).to_u8
            break
          else
            # 2 characters -> 1 byte
            value = decode_base38_chunk(encoded, encoded_offset, 2)
            result[decoded_offset] = (value & 0xFF).to_u8
            break
          end
        end

        result
      end

      # Decode a chunk of base-38 characters to a value
      # Characters are read in little-endian order (least-significant first)
      private def self.decode_base38_chunk(encoded : String, offset : Int32, char_count : Int32) : UInt32
        result = 0_u32

        (char_count - 1).downto(0) do |i|
          char = encoded[offset + i]
          code = BASE38_ALPHABET.index(char)
          raise CodecError.new("Unexpected character #{char} at #{offset + i}") unless code
          result = result * 38 + code
        end

        result
      end

      # Parse Matter QR code payload
      #
      # @param qr_code QR code string (with or without "MT:" prefix)
      # @return Hash with decoded values
      def self.parse_qr_code(qr_code : String) : Hash(Symbol, UInt64 | UInt32 | UInt16 | UInt8)
        # Remove "MT:" prefix if present
        code = qr_code.starts_with?("MT:") ? qr_code[3..-1] : qr_code

        # Decode from base-38 to byte array
        bytes = decode_base38_to_bytes(code)

        # Extract fields from byte array using bit unpacking
        version = unpack_bits(bytes, 0, 3).to_u8
        vendor_id = unpack_bits(bytes, 3, 16).to_u16
        product_id = unpack_bits(bytes, 19, 16).to_u16
        flow = unpack_bits(bytes, 35, 2).to_u8
        capabilities = unpack_bits(bytes, 37, 8).to_u8
        discriminator = unpack_bits(bytes, 45, 12).to_u16
        pin = unpack_bits(bytes, 57, 27).to_u32

        {
          :version       => version.to_u64,
          :vendor_id     => vendor_id.as(UInt64 | UInt32 | UInt16 | UInt8),
          :product_id    => product_id.as(UInt64 | UInt32 | UInt16 | UInt8),
          :flow          => flow.as(UInt64 | UInt32 | UInt16 | UInt8),
          :capabilities  => capabilities.as(UInt64 | UInt32 | UInt16 | UInt8),
          :discriminator => discriminator.as(UInt64 | UInt32 | UInt16 | UInt8),
          :pin           => pin.as(UInt64 | UInt32 | UInt16 | UInt8),
        }
      end

      # Unpack bits from a byte array at the specified bit offset
      # Implements matter.js ByteArrayBitmapSchema decoding logic
      private def self.unpack_bits(bytes : Bytes, bit_offset : Int32, bit_length : Int32) : UInt64
        byte_offset = bit_offset // 8
        bit_offset_in_byte = bit_offset % 8
        mask = (1_u64 << bit_length) - 1

        value = 0_u64
        value_bit_offset = 0

        temp_mask = mask
        while temp_mask != 0 && byte_offset < bytes.size
          value |= ((bytes[byte_offset].to_u64 >> bit_offset_in_byte) & temp_mask) << value_bit_offset
          bits_read = 8 - bit_offset_in_byte
          bit_offset_in_byte = 0
          value_bit_offset += bits_read
          temp_mask >>= bits_read
          byte_offset += 1
        end

        value & mask
      end
    end
  end
end
