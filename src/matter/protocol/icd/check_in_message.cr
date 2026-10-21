require "../../crypto/crypto"
require "../../error"

module Matter
  module Protocol
    module Icd
      # Matter 1.6 Core §4.22 Check-In payload, carried by unsecured Secure
      # Channel message 0x50. The 16-byte ICDToken is both the AES and HMAC key.
      module CheckInMessage
        extend self

        KEY_LENGTH     = 16
        NONCE_LENGTH   = 13
        MIC_LENGTH     = 16
        COUNTER_LENGTH =  4
        MIN_LENGTH     = NONCE_LENGTH + COUNTER_LENGTH + MIC_LENGTH

        struct Decoded
          getter counter : UInt32
          getter application_data : Bytes

          def initialize(@counter, @application_data)
          end
        end

        def encode(key : Bytes, counter : UInt32, application_data : Bytes) : Bytes
          validate_key(key)
          counter_bytes = Bytes.new(COUNTER_LENGTH)
          IO::ByteFormat::LittleEndian.encode(counter, counter_bytes)
          nonce = Crypto::StandardCrypto.new.sign_hmac(key, counter_bytes)[0, NONCE_LENGTH]
          plaintext = Bytes.new(COUNTER_LENGTH + application_data.size)
          plaintext[0, COUNTER_LENGTH].copy_from(counter_bytes)
          plaintext[COUNTER_LENGTH, application_data.size].copy_from(application_data)
          ciphertext = Crypto::StandardCrypto.new.encrypt(key, plaintext, nonce)
          payload = Bytes.new(NONCE_LENGTH + ciphertext.size)
          payload[0, NONCE_LENGTH].copy_from(nonce)
          payload[NONCE_LENGTH, ciphertext.size].copy_from(ciphertext)
          payload
        end

        def encode_icd(key : Bytes, counter : UInt32, active_mode_threshold : UInt16) : Bytes
          threshold = Bytes.new(2)
          IO::ByteFormat::LittleEndian.encode(active_mode_threshold, threshold)
          encode(key, counter, threshold)
        end

        def decode(key : Bytes, payload : Bytes) : Decoded
          validate_key(key)
          raise CodecError.new("Check-In payload too short") if payload.size < MIN_LENGTH
          nonce = payload[0, NONCE_LENGTH]
          ciphertext = payload[NONCE_LENGTH, payload.size - NONCE_LENGTH]
          plaintext = begin
            Crypto::StandardCrypto.new.decrypt(key, ciphertext, nonce)
          rescue ex : AuthenticationError | ArgumentError
            raise CodecError.new("Check-In authentication failed", cause: ex)
          end
          raise CodecError.new("Check-In counter missing") if plaintext.size < COUNTER_LENGTH
          counter = IO::ByteFormat::LittleEndian.decode(UInt32, plaintext[0, COUNTER_LENGTH])
          expected = Crypto::StandardCrypto.new.sign_hmac(key, plaintext[0, COUNTER_LENGTH])[0, NONCE_LENGTH]
          raise CodecError.new("Check-In nonce mismatch") unless nonce == expected
          Decoded.new(counter, plaintext[COUNTER_LENGTH, plaintext.size - COUNTER_LENGTH].dup)
        end

        private def validate_key(key : Bytes) : Nil
          raise CodecError.new("ICDToken must be 16 bytes") unless key.size == KEY_LENGTH
        end
      end
    end
  end
end
