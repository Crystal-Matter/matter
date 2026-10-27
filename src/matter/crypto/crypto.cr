require "openssl"
require "openssl/digest"
require "openssl/hmac"
require "bindata/asn1"
require "base64"
require "./aes/ccm"
require "./wire_identifiers"

module Matter
  module Crypto
    Log = ::Log.for("matter.crypto")

    # Cryptographic constants for Matter protocol
    CRYPTO_ENCRYPT_ALGORITHM    = "aes-128-ccm"
    CRYPTO_HASH_ALGORITHM       = "sha256"
    CRYPTO_SYMMETRIC_KEY_LENGTH = 16

    # Abstract interface for cryptographic operations required by Matter protocol
    # Implementations can be platform-specific or use standard OpenSSL bindings
    abstract class CryptoBase
      # The implementation name for logging
      abstract def implementation_name : String

      # Encrypt using AES-128-CCM with Matter-specific parameters
      # @param key 16-byte AES key
      # @param data Plaintext to encrypt
      # @param nonce 13-byte nonce
      # @param aad Additional authenticated data (optional)
      # @return Ciphertext with 16-byte authentication tag appended
      abstract def encrypt(key : Bytes, data : Bytes, nonce : Bytes, aad : Bytes? = nil) : Bytes

      # Decrypt using AES-128-CCM with Matter-specific parameters
      # @param key 16-byte AES key
      # @param data Ciphertext with authentication tag
      # @param nonce 13-byte nonce
      # @param aad Additional authenticated data (optional)
      # @return Plaintext
      # @raise Matter::AuthenticationError if authentication fails
      abstract def decrypt(key : Bytes, data : Bytes, nonce : Bytes, aad : Bytes? = nil) : Bytes

      # Generate cryptographically secure random bytes
      # @param length Number of bytes to generate
      # @return Random bytes
      abstract def random_bytes(length : Int32) : Bytes

      # Compute SHA-256 hash
      # @param data Data to hash (can be single buffer or array of buffers)
      # @return 32-byte hash
      abstract def compute_sha256(data : Bytes | Array(Bytes)) : Bytes

      # Matter certificate key identifiers are SHA-1 of the full public key.
      # This is only for SKID/AKID derivation; certificate signatures use SHA-256.
      def compute_sha1(data : Bytes) : Bytes
        digest = OpenSSL::Digest.new("SHA1")
        digest.update(data)
        digest.final
      end

      # Derive key using PBKDF2 with SHA-256
      # @param secret Secret/password
      # @param salt Salt value
      # @param iterations Iteration count
      # @param key_length Desired key length
      # @return Derived key
      abstract def create_pbkdf2_key(secret : Bytes, salt : Bytes, iterations : Int32, key_length : Int32) : Bytes

      # Derive key using HKDF with SHA-256
      # @param secret Input key material
      # @param salt Salt value
      # @param info Context/application specific info
      # @param length Desired output length (default 32 bytes)
      # @return Derived key
      abstract def create_hkdf_key(secret : Bytes, salt : Bytes, info : Bytes, length : Int32 = 32) : Bytes

      # Create HMAC-SHA256 signature
      # @param key HMAC key
      # @param data Data to sign
      # @return HMAC signature
      abstract def sign_hmac(key : Bytes, data : Bytes) : Bytes

      # Create ECDSA signature using P-256
      # @param private_key EC private key
      # @param data Data to sign (can be array for multiple buffers)
      # @param dsa_encoding Signature encoding format (ieee-p1363 or der)
      # @return Signature bytes
      abstract def sign_ecdsa(private_key : Key, data : Bytes | Array(Bytes), dsa_encoding : String = "ieee-p1363") : Bytes

      # Verify ECDSA signature using P-256
      # @param public_key EC public key
      # @param data Data that was signed
      # @param signature Signature to verify
      # @param dsa_encoding Signature encoding format
      # @raise Matter::AuthenticationError if verification fails
      abstract def verify_ecdsa(public_key : Key, data : Bytes, signature : Bytes, dsa_encoding : String = "ieee-p1363") : Nil

      # Generate an EC P-256 key pair
      # @return New private key (includes public key)
      abstract def create_key_pair : Key

      # Compute shared secret using ECDH
      # @param private_key Local private key
      # @param peer_public_key Peer's public key
      # @return Shared secret (32 bytes for P-256)
      abstract def generate_dh_secret(private_key : Key, peer_public_key : Key) : Bytes

      # Convenience methods for random number generation
      def random_uint8 : UInt8
        random_bytes(1)[0]
      end

      def random_uint16 : UInt16
        bytes = random_bytes(2)
        IO::ByteFormat::BigEndian.decode(UInt16, bytes)
      end

      def random_uint32 : UInt32
        bytes = random_bytes(4)
        IO::ByteFormat::BigEndian.decode(UInt32, bytes)
      end

      def random_uint64 : UInt64
        bytes = random_bytes(8)
        IO::ByteFormat::BigEndian.decode(UInt64, bytes)
      end

      def random_big_int(size : Int32, max_value : BigInt? = nil) : BigInt
        loop do
          bytes = random_bytes(size)
          value = BigInt.new(bytes.hexstring, 16)
          return value if max_value.nil? || value < max_value
        end
      end

      def report_usage(component : String? = nil)
        msg = "Using #{implementation_name} crypto implementation"
        msg += " for #{component}" if component
        Log.debug { msg }
      end
    end

    # Standard OpenSSL-based implementation
    class StandardCrypto < CryptoBase
      def implementation_name : String
        "OpenSSL (standard)"
      end

      def encrypt(key : Bytes, data : Bytes, nonce : Bytes, aad : Bytes? = nil) : Bytes
        # AES-CCM encryption using pure-Crystal implementation
        ccm = AES::Ccm.new(key)
        ccm.encrypt(data, nonce, aad)
      end

      def decrypt(key : Bytes, data : Bytes, nonce : Bytes, aad : Bytes? = nil) : Bytes
        # AES-CCM decryption using pure-Crystal implementation
        ccm = AES::Ccm.new(key)
        ccm.decrypt(data, nonce, aad)
      end

      def random_bytes(length : Int32) : Bytes
        Random::Secure.random_bytes(length)
      end

      def compute_sha256(data : Bytes | Array(Bytes)) : Bytes
        digest = OpenSSL::Digest.new("SHA256")

        case data
        when Bytes
          digest.update(data)
        when Array(Bytes)
          data.each { |chunk| digest.update(chunk) }
        end

        digest.final
      end

      def create_pbkdf2_key(secret : Bytes, salt : Bytes, iterations : Int32, key_length : Int32) : Bytes
        OpenSSL::PKCS5.pbkdf2_hmac(
          secret,
          salt,
          iterations,
          OpenSSL::Algorithm::SHA256,
          key_length
        )
      end

      def create_hkdf_key(secret : Bytes, salt : Bytes, info : Bytes, length : Int32 = 32) : Bytes
        # HKDF-SHA256
        # Extract phase
        prk = OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, salt, secret)

        # Expand phase
        output = Bytes.new(length)
        t = Bytes.empty
        iterations = (length.to_f / 32.0).ceil.to_i

        iterations.times do |i|
          hmac_input = IO::Memory.new
          hmac_input.write(t)
          hmac_input.write(info)
          hmac_input.write_byte((i + 1).to_u8)

          t = OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, prk, hmac_input.to_slice)

          copy_len = Math.min(32, length - (i * 32))
          output[i * 32, copy_len].copy_from(t[0, copy_len])
        end

        output
      end

      def sign_hmac(key : Bytes, data : Bytes) : Bytes
        OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, key, data)
      end

      def sign_ecdsa(private_key : Key, data : Bytes | Array(Bytes), dsa_encoding : String = "ieee-p1363") : Bytes
        # Create EC key from private key bytes
        pkey = create_ec_private_key(private_key)

        # Hash the data
        digest = case data
                 when Bytes
                   compute_sha256(data)
                 when Array(Bytes)
                   compute_sha256(data)
                 else
                   raise ArgumentError.new("Invalid data type")
                 end

        # Sign using EC signature (returns DER format)
        der_signature = pkey.ec_sign(digest)

        # Convert DER signature to IEEE P1363 format if needed
        if dsa_encoding == "ieee-p1363"
          asn1_to_raw(der_signature, pkey)
        else
          der_signature
        end
      end

      def verify_ecdsa(public_key : Key, data : Bytes, signature : Bytes, dsa_encoding : String = "ieee-p1363") : Nil
        # Create EC key from public key bytes
        pkey = create_ec_public_key(public_key)

        # Convert IEEE P1363 to DER if needed
        der_signature = if dsa_encoding == "ieee-p1363"
                          raw_to_asn1(signature, pkey)
                        else
                          signature
                        end

        # Hash the data
        digest = compute_sha256(data)

        # Verify using EC signature verification
        unless pkey.ec_verify(digest, der_signature)
          raise Matter::AuthenticationError.new("ECDSA signature verification failed")
        end
      end

      def create_key_pair : Key
        Key.generate_key_pair
      end

      def generate_dh_secret(private_key : Key, peer_public_key : Key) : Bytes
        # Use ECDH module to compute shared secret
        ECDH.compute_shared_secret(private_key.private_key, peer_public_key.public_key)
      end

      private def create_ec_private_key(key : Key) : OpenSSL::PKey::EC
        # Build EC private key in SEC1 DER format from raw private key bytes
        # SEC1 format: SEQUENCE { version, privateKey, [0] curve, [1] publicKey }
        priv_bytes = key.private_key
        pub_bytes = key.public_bits || raise Matter::CryptoError.new("Public key required for ECDSA")

        # Build SEC1 DER-encoded private key
        der = build_ec_private_key_der(priv_bytes, pub_bytes)

        # Convert to PEM format
        pem = der_to_pem(der, "EC PRIVATE KEY")

        # Load the PEM-encoded key
        OpenSSL::PKey::EC.new(pem)
      end

      private def create_ec_public_key(key : Key) : OpenSSL::PKey::EC
        # Build EC public key from uncompressed point
        pub_bytes = key.public_key

        # Build SPKI DER-encoded public key
        der = build_ec_public_key_der(pub_bytes)

        # Convert to PEM format
        pem = der_to_pem(der, "PUBLIC KEY")

        # Load the PEM-encoded key
        OpenSSL::PKey::EC.new(pem)
      end

      # Convert DER to PEM format
      def der_to_pem(der : Bytes, label : String) : String
        encoded = Base64.strict_encode(der)
        lines = [] of String
        lines << "-----BEGIN #{label}-----"
        # Split into 64-character lines
        encoded.scan(/.{1,64}/) { |match| lines << match[0] }
        lines << "-----END #{label}-----"
        lines.join("\n") + "\n"
      end

      # Build SEC1 DER format for EC private key
      def build_ec_private_key_der(priv : Bytes, pub : Bytes) : Bytes
        # P-256 curve OID: 1.2.840.10045.3.1.7 (complete with tag and length)
        curve_oid = Bytes[0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07]

        # Build: SEQUENCE { INTEGER 1, OCTET STRING priv, [0] OID, [1] BIT STRING pub }
        io = IO::Memory.new

        # Version (INTEGER 1)
        io.write Bytes[0x02, 0x01, 0x01]

        # Private key (OCTET STRING)
        io.write_byte WireIdentifiers::DerTag::OctetString.value
        io.write_byte priv.size.to_u8
        io.write priv

        # Curve parameters ([0] EXPLICIT containing OID)
        io.write_byte WireIdentifiers::DerTag::Context0Constructed.value
        io.write_byte curve_oid.size.to_u8 # Length of the OID (including its tag/length)
        io.write curve_oid                 # The complete OID with its tag and length

        # Public key ([1] EXPLICIT containing BIT STRING)
        # Build the BIT STRING first
        bit_string_content = IO::Memory.new
        bit_string_content.write_byte WireIdentifiers::DerTag::BitString.value
        bit_string_content.write_byte (pub.size + 1).to_u8 # Length (data + unused bits byte)
        bit_string_content.write_byte WireIdentifiers::DER_NO_UNUSED_BITS
        bit_string_content.write pub
        bit_string_bytes = bit_string_content.to_slice

        io.write_byte WireIdentifiers::DerTag::Context1Constructed.value
        io.write_byte bit_string_bytes.size.to_u8
        io.write bit_string_bytes

        # Wrap in SEQUENCE
        content = io.to_slice
        result = IO::Memory.new
        result.write_byte WireIdentifiers::DerTag::Sequence.value
        write_der_length(result, content.size)
        result.write content

        result.to_slice
      end

      # Build SPKI DER format for EC public key
      def build_ec_public_key_der(pub : Bytes) : Bytes
        # Algorithm identifier for EC public key with P-256
        # SEQUENCE { OID ecPublicKey, OID prime256v1 }
        algo_id = Bytes[
          0x30, 0x13,                                                # SEQUENCE
          0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,      # OID ecPublicKey
          0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07 # OID prime256v1
        ]

        # Build SPKI: SEQUENCE { algorithm, BIT STRING publicKey }
        io = IO::Memory.new
        io.write algo_id

        # Public key (BIT STRING)
        io.write_byte WireIdentifiers::DerTag::BitString.value
        write_der_length(io, pub.size + 1)
        io.write_byte WireIdentifiers::DER_NO_UNUSED_BITS
        io.write pub

        # Wrap in SEQUENCE
        content = io.to_slice
        result = IO::Memory.new
        result.write_byte WireIdentifiers::DerTag::Sequence.value
        write_der_length(result, content.size)
        result.write content

        result.to_slice
      end

      private def write_der_length(io : IO, length : Int)
        if length < 128
          io.write_byte length.to_u8
        else
          # Long form
          bytes = [] of UInt8
          temp = length
          while temp > 0
            bytes.unshift(temp.to_u8 & 0xFF)
            temp >>= 8
          end
          io.write_byte (WireIdentifiers::DER_LONG_FORM_FLAG | bytes.size).to_u8
          bytes.each { |byte| io.write_byte byte }
        end
      end

      # Convert DER-encoded ECDSA signature to IEEE P1363 (raw r||s) format
      # Based on JWT library implementation
      private def asn1_to_raw(signature : Bytes, pkey : OpenSSL::PKey::EC) : Bytes
        byte_size = (pkey.group_degree + 7) // 8
        io = IO::Memory.new(signature)
        sequence = io.read_bytes(ASN1::BER)
        parts = sequence.children
        r_bytes = parts[0].get_integer_bytes
        s_bytes = parts[1].get_integer_bytes

        Log.debug { "asn1_to_raw: DER sig #{signature.size} bytes, R=#{r_bytes.size} bytes, S=#{s_bytes.size} bytes, target=#{byte_size}" }

        # Pad or trim R and S values to exactly byte_size (32 for P-256)
        # DER integers can have leading zeros if high bit is set
        r_normalized = pad_or_trim(r_bytes, byte_size)
        s_normalized = pad_or_trim(s_bytes, byte_size)

        Log.debug { "asn1_to_raw: Normalized R=#{r_normalized.size}, S=#{s_normalized.size}, total=#{r_normalized.size + s_normalized.size}" }

        raw = IO::Memory.new
        raw.write r_normalized
        raw.write s_normalized
        raw.to_slice
      end

      # Convert IEEE P1363 (raw r||s) to DER format
      # Based on JWT library implementation
      private def raw_to_asn1(signature : Bytes, pkey : OpenSSL::PKey::EC) : Bytes
        byte_size = (pkey.group_degree + 7) // 8
        sig_bytes = signature[0..(byte_size - 1)]
        sig_char = signature[byte_size..-1]

        bytes_asn1 = ASN1::BER.new
        bytes_asn1.tag_number = ASN1::BER::UniversalTags::Integer
        bytes_asn1.set_integer sig_bytes

        char_asn1 = ASN1::BER.new
        char_asn1.tag_number = ASN1::BER::UniversalTags::Integer
        char_asn1.set_integer sig_char

        sequence = ASN1::BER.new
        sequence.tag_number = ASN1::BER::UniversalTags::Sequence
        sequence.children = {bytes_asn1, char_asn1}
        sequence.to_slice
      end

      private def pad_or_trim(bytes : Bytes, target_size : Int32) : Bytes
        if bytes.size == target_size
          bytes
        elsif bytes.size < target_size
          # Pad with leading zeros
          result = Bytes.new(target_size, 0_u8)
          result[target_size - bytes.size, bytes.size].copy_from(bytes)
          result
        else
          # Trim leading zeros/padding
          start = 0
          while start < bytes.size - target_size && bytes[start] == 0
            start += 1
          end
          bytes[start, target_size]
        end
      end
    end

    # Global crypto instance
    @@instance : CryptoBase = StandardCrypto.new

    def self.instance : CryptoBase
      @@instance
    end

    def self.instance=(crypto : CryptoBase)
      @@instance = crypto
    end

    # Convenience methods that delegate to the global instance
    def self.encrypt(key : Bytes, data : Bytes, nonce : Bytes, aad : Bytes? = nil) : Bytes
      instance.encrypt(key, data, nonce, aad)
    end

    def self.decrypt(key : Bytes, data : Bytes, nonce : Bytes, aad : Bytes? = nil) : Bytes
      instance.decrypt(key, data, nonce, aad)
    end

    def self.random_bytes(length : Int32) : Bytes
      instance.random_bytes(length)
    end

    def self.compute_sha256(data : Bytes | Array(Bytes)) : Bytes
      instance.compute_sha256(data)
    end

    def self.create_pbkdf2_key(secret : Bytes, salt : Bytes, iterations : Int32, key_length : Int32) : Bytes
      instance.create_pbkdf2_key(secret, salt, iterations, key_length)
    end

    def self.create_hkdf_key(secret : Bytes, salt : Bytes, info : Bytes, length : Int32 = 32) : Bytes
      instance.create_hkdf_key(secret, salt, info, length)
    end

    def self.sign_hmac(key : Bytes, data : Bytes) : Bytes
      instance.sign_hmac(key, data)
    end

    def self.sign_ecdsa(private_key : Key, data : Bytes | Array(Bytes), dsa_encoding : String = "ieee-p1363") : Bytes
      instance.sign_ecdsa(private_key, data, dsa_encoding)
    end

    def self.verify_ecdsa(public_key : Key, data : Bytes, signature : Bytes, dsa_encoding : String = "ieee-p1363") : Nil
      instance.verify_ecdsa(public_key, data, signature, dsa_encoding)
    end

    def self.create_key_pair : Key
      instance.create_key_pair
    end

    def self.generate_dh_secret(private_key : Key, peer_public_key : Key) : Bytes
      instance.generate_dh_secret(private_key, peer_public_key)
    end

    # Random number convenience methods
    def self.random_uint8 : UInt8
      instance.random_uint8
    end

    def self.random_uint16 : UInt16
      instance.random_uint16
    end

    def self.random_uint32 : UInt32
      instance.random_uint32
    end

    def self.random_uint64 : UInt64
      instance.random_uint64
    end

    def self.random_big_int(size : Int32, max_value : BigInt? = nil) : BigInt
      instance.random_big_int(size, max_value)
    end
  end
end
