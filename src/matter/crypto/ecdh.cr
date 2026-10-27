require "openssl_ext"
require "./wire_identifiers"

module Matter
  module Crypto
    # ECDH (Elliptic Curve Diffie-Hellman) implementation for Matter
    # Uses OpenSSL for EC operations on P-256 curve
    module ECDH
      extend self

      # Compute shared secret using ECDH on P-256
      # @param private_key Local EC private key (32 bytes)
      # @param peer_public_key Peer's EC public key (65 bytes uncompressed: 0x04 || x || y)
      # @return Shared secret (32 bytes - the x-coordinate of the computed point)
      def compute_shared_secret(private_key : Bytes, peer_public_key : Bytes) : Bytes
        # Validate input sizes
        raise ArgumentError.new("Private key must be 32 bytes") unless private_key.size == 32
        raise ArgumentError.new("Public key must be 65 bytes (uncompressed)") unless peer_public_key.size == 65
        raise ArgumentError.new("Public key must start with an uncompressed SEC1 point marker") unless peer_public_key[0] == WireIdentifiers::Sec1PointFormat::Uncompressed.value

        # Try new openssl_ext API first (OpenSSL 3+ compatible, cleaner code)
        # Fall back to low-level API if new API not available in this environment
        begin
          priv_ec = OpenSSL::PKey::EC.from_private_bytes(private_key, CRYPTO_EC_CURVE_NIST)
          peer_ec = OpenSSL::PKey::EC.from_public_bytes(peer_public_key, CRYPTO_EC_CURVE_NIST)
          shared_secret = OpenSSL::PKey::EC.compute_shared_secret(priv_ec, peer_ec)
          raise Matter::CryptoError.new("Unexpected shared secret length: #{shared_secret.size}") unless shared_secret.size == 32
          return shared_secret
        rescue OpenSSL::PKey::EcError
          # Fall back to low-level implementation for environments where new API isn't available
        end

        # Low-level ECDH implementation using direct OpenSSL bindings
        # Create a temporary EC key for P-256 to get the group
        temp_key = OpenSSL::PKey::EC.generate(CRYPTO_EC_CURVE_NIST)
        ec_key = LibCrypto.evp_pkey_get1_ec_key(temp_key)
        group = LibCrypto.ec_key_get0_group(ec_key)

        # Convert peer's public key bytes to an EC_POINT
        peer_point = LibCrypto.ec_point_new(group)
        raise Matter::CryptoError.new("Failed to create EC_POINT") if peer_point.null?

        begin
          result = LibCrypto.ec_point_oct2point(group, peer_point, peer_public_key, peer_public_key.size, nil)
          raise Matter::CryptoError.new("Failed to convert public key bytes to EC_POINT") if result != 1

          # Convert private key bytes to BIGNUM
          priv_bn = LibCrypto.bn_new
          raise Matter::CryptoError.new("Failed to create BIGNUM") if priv_bn.null?

          begin
            LibCrypto.bn_from_bin(private_key, private_key.size, priv_bn)

            # Compute shared_point = private_key * peer_public_key
            shared_point = LibCrypto.ec_point_new(group)
            raise Matter::CryptoError.new("Failed to create shared point") if shared_point.null?

            begin
              result = LibCrypto.ec_point_mul(group, shared_point, nil, peer_point, priv_bn, nil)
              raise Matter::CryptoError.new("Failed to compute ECDH shared point") if result != 1

              # Convert shared point to uncompressed format (0x04 || x || y)
              shared_bytes = Bytes.new(65)
              len = LibCrypto.ec_point_point2oct(
                group,
                shared_point,
                LibCrypto::PointConversionForm::UNCOMPRESSED,
                shared_bytes,
                65,
                nil
              )
              raise Matter::CryptoError.new("Failed to convert shared point to bytes") if len != 65

              # Extract x-coordinate as the shared secret (bytes 1-32)
              shared_bytes[1, 32]
            ensure
              LibCrypto.ec_point_free(shared_point)
            end
          ensure
            LibCrypto.bn_clear_free(priv_bn)
          end
        ensure
          LibCrypto.ec_point_free(peer_point)
        end
      end

      # Generate a P-256 EC key pair
      # @return Key with both private and public components
      def generate_key_pair : Key
        Key.generate_key_pair
      end
    end
  end
end
