require "openssl"
require "openssl_ext"
require "base64"
require "./wire_identifiers"

module Matter
  module Crypto
    # ECDSA P-256 constants. The two OpenSSL APIs disagree on the spelling:
    # `generate_by_curve_name` wants the short name, while `from_private_bytes`
    # and `from_public_bytes` want the NIST name and raise "unknown NIST curve"
    # for anything else.
    CRYPTO_EC_CURVE        = "prime256v1"
    CRYPTO_EC_CURVE_NIST   = "P-256"
    CRYPTO_EC_KEY_BYTES    = 32
    CRYPTO_AUTH_TAG_LENGTH = 16

    enum KeyType
      EC
      RSA
      Oct
    end

    enum CurveType
      P256 = 1
      P384
      P521
    end

    # Binary key pair structure
    struct BinaryKeyPair
      property public_key : Bytes
      property private_key : Bytes

      def initialize(@public_key, @private_key)
      end
    end

    # Represents a cryptographic key
    # Models keys similar to JSON Web Key (JWK) format for compatibility
    class Key
      property type : KeyType
      property curve : CurveType?
      property algorithm : String?
      property operations : Array(String)?
      property? extractable : Bool

      # Private key material (d in JWK)
      @private_bits : Bytes?
      # Public key x coordinate
      @x_bits : Bytes?
      # Public key y coordinate
      @y_bits : Bytes?

      def initialize(
        @type : KeyType = KeyType::EC,
        @curve : CurveType? = CurveType::P256,
        @extractable : Bool = true,
      )
        @operations = ["sign", "verify"]
      end

      # Get/set private key bytes
      def private_bits : Bytes?
        @private_bits
      end

      def private_bits=(value : Bytes?)
        # For EC keys, ensure private key is exactly 32 bytes (zero-padded if needed)
        # This handles cases where leading zeros are stripped from the big integer
        if value && @type == KeyType::EC && value.size < CRYPTO_EC_KEY_BYTES
          padded = Bytes.new(CRYPTO_EC_KEY_BYTES, 0_u8)
          padded[CRYPTO_EC_KEY_BYTES - value.size, value.size].copy_from(value)
          @private_bits = padded
        else
          @private_bits = value
        end
        # If we have a private key and EC type, compute public key
        derive_public_from_private if value && @type == KeyType::EC && !@x_bits
      end

      # Get/set public key x coordinate
      def x_bits : Bytes?
        @x_bits
      end

      def x_bits=(value : Bytes?)
        @x_bits = value
      end

      # Get/set public key y coordinate
      def y_bits : Bytes?
        @y_bits
      end

      def y_bits=(value : Bytes?)
        @y_bits = value
      end

      # Import/export public key in SEC1/SPKI format (0x04 || x || y)
      def public_bits : Bytes?
        x = @x_bits
        y = @y_bits
        return unless x && y

        io = IO::Memory.new
        io.write_byte(WireIdentifiers::Sec1PointFormat::Uncompressed.value)
        io.write(x)
        io.write(y)
        io.to_slice
      end

      def public_bits=(value : Bytes)
        return if value.size.even?

        case value[0]
        when WireIdentifiers::Sec1PointFormat::CompressedEven.value,
             WireIdentifiers::Sec1PointFormat::CompressedOdd.value
          raise Matter::CryptoError.new("Unsupported public key compression")
        when WireIdentifiers::Sec1PointFormat::Uncompressed.value
          # Uncompressed format
        when WireIdentifiers::Sec1PointFormat::IllegalSpecifier.value
          raise Matter::CryptoError.new("Illegal public key format specifier")
        else
          raise Matter::CryptoError.new("Invalid public key format")
        end

        coordinate_length = (value.size - 1) // 2
        infer_curve(coordinate_length)

        @type = KeyType::EC
        @x_bits = value[1, coordinate_length]
        @y_bits = value[coordinate_length + 1, coordinate_length]
      end

      # Import/export key pair
      def key_pair_bits : BinaryKeyPair?
        pub = public_bits
        priv = @private_bits
        return unless pub && priv

        BinaryKeyPair.new(pub, priv)
      end

      def key_pair_bits=(pair : BinaryKeyPair)
        self.public_bits = pair.public_key
        self.private_bits = pair.private_key
      end

      # Asserted accessors that raise if not present
      def public_key : Bytes
        public_bits || raise Matter::CryptoError.new("Public key not defined")
      end

      def private_key : Bytes
        @private_bits || raise Matter::CryptoError.new("Private key not defined")
      end

      def key_pair : BinaryKeyPair
        key_pair_bits || raise Matter::CryptoError.new("Complete key pair not defined")
      end

      # Import PKCS#8 private key
      def import_pkcs8(data : Bytes)
        # PKCS#8 is a DER-encoded format
        # Try to load it via PEM format
        pem = "-----BEGIN PRIVATE KEY-----\n"
        pem += Base64.strict_encode(data).scan(/.{1,64}/).map(&.[0]).join("\n")
        pem += "\n-----END PRIVATE KEY-----\n"

        pkey = OpenSSL::PKey::EC.new(pem)

        @type = KeyType::EC
        @curve = CurveType::P256 # Assume P-256 for Matter

        # Get the SEC1 format from the loaded key
        io = IO::Memory.new
        pkey.to_der(io)
        sec1_der = io.to_slice

        # Extract private key and public key using our extraction methods
        @private_bits = Key.extract_private_key_from_der(sec1_der)

        # Get public key
        pub_io = IO::Memory.new
        pkey.public_key.to_der(pub_io)
        pub_der = pub_io.to_slice
        self.public_bits = Key.extract_public_key_from_der(pub_der)
      end

      # Import SPKI public key
      def import_spki(data : Bytes)
        # SPKI is a DER-encoded format
        # Convert to PEM and load
        pem = "-----BEGIN PUBLIC KEY-----\n"
        pem += Base64.strict_encode(data).scan(/.{1,64}/).map(&.[0]).join("\n")
        pem += "\n-----END PUBLIC KEY-----\n"

        pkey = OpenSSL::PKey::EC.new(pem)

        @type = KeyType::EC
        @curve = CurveType::P256

        # Get public key DER
        pub_io = IO::Memory.new
        pkey.to_der(pub_io)
        pub_der = pub_io.to_slice

        # Extract uncompressed public key bytes
        self.public_bits = Key.extract_public_key_from_der(pub_der)
      end

      # Import SEC1 private key
      def import_sec1(data : Bytes)
        # SEC1 is a DER-encoded EC private key format
        # Convert to PEM and load
        pem = "-----BEGIN EC PRIVATE KEY-----\n"
        pem += Base64.strict_encode(data).scan(/.{1,64}/).map(&.[0]).join("\n")
        pem += "\n-----END EC PRIVATE KEY-----\n"

        pkey = OpenSSL::PKey::EC.new(pem)

        @type = KeyType::EC
        @curve = CurveType::P256

        # Extract private key bytes using our extraction method
        io = IO::Memory.new
        pkey.to_der(io)
        priv_der = io.to_slice
        @private_bits = Key.extract_private_key_from_der(priv_der)

        # Get public key
        pub_io = IO::Memory.new
        pkey.public_key.to_der(pub_io)
        pub_der = pub_io.to_slice
        self.public_bits = Key.extract_public_key_from_der(pub_der)
      end

      # Generate a random EC key pair
      def self.generate_key_pair : Key
        pkey = OpenSSL::PKey::EC.generate_by_curve_name(CRYPTO_EC_CURVE)

        key = new(KeyType::EC, CurveType::P256)

        # Use new openssl_ext API to get raw key bytes directly
        key.private_bits = pkey.private_key_bytes
        key.public_bits = pkey.public_key_bytes

        key
      end

      # Extract 32-byte private key from DER format
      def self.extract_private_key_from_der(der : Bytes) : Bytes
        # EC private key DER format has the 32-byte key embedded as an OCTET STRING
        # Look for tag 0x04 (OCTET STRING) followed by length 0x20 (32 bytes)
        # Format: ... 04 20 [32 bytes of private key] ...
        (0...der.size - 2).each do |i|
          if der[i] == WireIdentifiers::DerTag::OctetString.value &&
             der[i + 1] == CRYPTO_EC_KEY_BYTES && i + 2 + CRYPTO_EC_KEY_BYTES <= der.size
            return der[i + 2, CRYPTO_EC_KEY_BYTES]
          end
        end

        # Fallback for unexpected format
        raise Matter::CryptoError.new("Could not find private key in DER format")
      end

      # Extract 65-byte uncompressed public key from DER format
      def self.extract_public_key_from_der(der : Bytes) : Bytes
        # Public key DER format has the 65-byte uncompressed key (0x04 || x || y) at the end
        # Scan backwards for 0x04 marker
        (der.size - 65).downto(0) do |i|
          if der[i] == WireIdentifiers::Sec1PointFormat::Uncompressed.value && i + 65 <= der.size
            return der[i, 65]
          end
        end

        # Fallback
        if der.size >= 65
          der[der.size - 65, 65]
        else
          raise Matter::CryptoError.new("Invalid DER public key size")
        end
      end

      # Compute shared secret for Diffie-Hellman using ECDH
      def self.compute_shared_secret(private_key : Key, peer_public_key : Key) : Bytes
        # Get raw key bytes
        priv_bytes = private_key.private_key
        pub_bytes = peer_public_key.public_key

        # Determine curve name from key size
        curve_name = case priv_bytes.size
                     when 32 then CRYPTO_EC_CURVE_NIST
                     when 48 then "P-384"
                     when 66 then "P-521"
                     else
                       raise Matter::CryptoError.new("Unsupported private key size: #{priv_bytes.size}")
                     end

        # Create EC keys from raw bytes using new openssl_ext API
        priv_ec = OpenSSL::PKey::EC.from_private_bytes(priv_bytes, curve_name)
        peer_ec = OpenSSL::PKey::EC.from_public_bytes(pub_bytes, curve_name)

        # Compute shared secret using new openssl_ext API
        OpenSSL::PKey::EC.compute_shared_secret(priv_ec, peer_ec)
      end

      private def infer_curve(bytes : Int32)
        return if @curve

        @curve = case bytes
                 when 66 then CurveType::P521
                 when 48 then CurveType::P384
                 when 32 then CurveType::P256
                 else
                   raise Matter::CryptoError.new("Cannot infer curve from key length #{bytes}")
                 end
      end

      private def derive_public_from_private
        return unless @type == KeyType::EC
        return unless priv = @private_bits
        return if @x_bits && @y_bits

        # Public key derivation is optional - if it fails, public key must be set explicitly
        # This is only an optimization for cases where we have private key but not public key
        begin
          # Determine curve name
          curve_name = case @curve
                       when CurveType::P384 then "P-384"
                       when CurveType::P521 then "P-521"
                       else                      CRYPTO_EC_CURVE_NIST
                       end

          # Use new openssl_ext API to derive public key from private key
          # Note: This requires OpenSSL 3+ and may not work in all environments
          ec_key = OpenSSL::PKey::EC.from_private_bytes(priv, curve_name)
          pub_bytes = ec_key.public_key_bytes

          # Extract x and y coordinates from uncompressed public key (0x04 || x || y)
          if pub_bytes[0] == WireIdentifiers::Sec1PointFormat::Uncompressed.value
            coordinate_length = (pub_bytes.size - 1) // 2
            @x_bits = pub_bytes[1, coordinate_length]
            @y_bits = pub_bytes[coordinate_length + 1, coordinate_length]
          end
        rescue ex
          # Expected in some environments (FIPS mode); the public key can be set explicitly.
          Log.debug(exception: ex) { "Public key derivation from private key failed" }
        end
      end
    end

    # Factory methods for convenience
    def self.private_key(private_key : Bytes | BinaryKeyPair, extractable : Bool = true) : Key
      key = Key.new(KeyType::EC, CurveType::P256, extractable: extractable)

      if private_key.is_a?(BinaryKeyPair)
        key.private_bits = private_key.private_key
        key.public_bits = private_key.public_key
      else
        key.private_bits = private_key
      end

      key
    end

    def self.public_key(public_key : Bytes, extractable : Bool = true) : Key
      key = Key.new(KeyType::EC, CurveType::P256, extractable: extractable)
      key.public_bits = public_key
      key
    end

    def self.symmetric_key(key_bytes : Bytes, extractable : Bool = true) : Key
      key = Key.new(KeyType::Oct, extractable: extractable)
      key.private_bits = key_bytes
      key
    end
  end
end
