require "openssl"

module Matter
  module Codec
    # Matter Core 1.6 §§3.7 and 4.9 header privacy for group messages.
    # Privacy hides header fields; AES-CCM authentication is still required
    # before a received header or payload can be trusted.
    module MessagePrivacy
      extend self

      KEY_LENGTH        = 16
      NONCE_LENGTH      = 13
      MIC_LENGTH        = 16
      MIC_OFFSET        =  5
      CTR_BLOCK_LENGTH  = 16
      MAX_HEADER_REGION = 20
      KEY_INFO          = "PrivacyKey".to_slice

      def derive_key(encryption_key : Bytes) : Bytes
        raise Matter::CodecError.new("Group encryption key must be 16 bytes") unless encryption_key.size == KEY_LENGTH
        Matter::Crypto.create_hkdf_key(encryption_key, Bytes.empty, KEY_INFO, KEY_LENGTH)
      end

      def nonce(session_id : UInt16, mic : Bytes) : Bytes
        raise Matter::CodecError.new("Privacy MIC must be 16 bytes") unless mic.size == MIC_LENGTH
        result = Bytes.new(NONCE_LENGTH)
        IO::ByteFormat::BigEndian.encode(session_id, result[0, 2])
        result[2, NONCE_LENGTH - 2].copy_from(mic[MIC_OFFSET, MIC_LENGTH - MIC_OFFSET])
        result
      end

      # AES-CTR uses the CCM Appendix A.3 counter block: flags=0x01,
      # 13-byte nonce, 16-bit big-endian counter starting at one.
      def obfuscate(privacy_key : Bytes, header_region : Bytes, privacy_nonce : Bytes) : Bytes
        raise Matter::CodecError.new("Privacy key must be 16 bytes") unless privacy_key.size == KEY_LENGTH
        raise Matter::CodecError.new("Privacy nonce must be 13 bytes") unless privacy_nonce.size == NONCE_LENGTH
        unless header_region.size.in?(1..MAX_HEADER_REGION)
          raise Matter::CodecError.new("Invalid private header region length")
        end

        output = header_region.dup
        block = Bytes.new(CTR_BLOCK_LENGTH)
        block[0] = 0x01_u8
        block[1, NONCE_LENGTH].copy_from(privacy_nonce)
        offset = 0
        counter = 1_u16
        while offset < output.size
          IO::ByteFormat::BigEndian.encode(counter, block[14, 2])
          cipher = OpenSSL::Cipher.new("aes-128-ecb")
          cipher.encrypt
          cipher.padding = false
          cipher.key = privacy_key
          stream = cipher.update(block) + cipher.final
          count = Math.min(CTR_BLOCK_LENGTH, output.size - offset)
          count.times { |i| output[offset + i] ^= stream[i] }
          offset += count
          counter += 1
        end
        output
      end
    end
  end
end
