require "../error"
require "./crypto"
require "./key"

module Matter
  module Crypto
    # The small PKCS#10 profile used for a Joint Fabric ICAC cross-signing CSR.
    # The signature proves that the joining administrator holds the private
    # key of the ICAC whose public key was verified during JCM.
    module Pkcs10
      extend self

      CSR_VERSION            = Bytes[0x02, 0x01, 0x00]
      CSR_SUBJECT            = Bytes[0x30, 0x0e, 0x31, 0x0c, 0x30, 0x0a, 0x06, 0x03, 0x55, 0x04, 0x0a, 0x0c, 0x03, 0x43, 0x53, 0x52]
      CSR_ATTRIBUTES         = Bytes[0xa0, 0x00]
      ECDSA_SHA256_ALGORITHM = Bytes[0x30, 0x0a, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02]
      DER_SEQUENCE           = 0x30_u8
      DER_BIT_STRING         = 0x03_u8
      DER_NO_PADDING         = 0x00_u8
      DER_LONG_FORM          = 0x80_u8
      PUBLIC_KEY_SIZE        =      65

      def create(key : Key, crypto : CryptoBase = Crypto.instance) : Bytes
        info = IO::Memory.new
        info.write CSR_VERSION
        info.write CSR_SUBJECT
        info.write crypto.build_ec_public_key_der(key.public_key)
        info.write CSR_ATTRIBUTES
        signed_info = sequence(info.to_slice)
        signature = crypto.sign_ecdsa(key, signed_info, "der")

        request = IO::Memory.new
        request.write signed_info
        request.write ECDSA_SHA256_ALGORITHM
        request.write_byte DER_BIT_STRING
        write_length(request, signature.size + 1)
        request.write_byte DER_NO_PADDING
        request.write signature
        sequence(request.to_slice)
      end

      # Validates PKCS#10 structure, P-256 SubjectPublicKeyInfo, signature,
      # and exact equality with the previously authenticated ICAC key.
      def verify(request : Bytes, trusted_public_key : Bytes, crypto : CryptoBase = Crypto.instance) : Nil
        outer = der_element(request, 0)
        unless outer[0] == DER_SEQUENCE && outer[2] == request.size
          raise Matter::CertificateError.new("Invalid ICAC CSR envelope")
        end
        info = der_element(request, outer[1])
        algorithm = der_element(request, info[2])
        signature = der_element(request, algorithm[2])
        unless info[0] == DER_SEQUENCE && algorithm[0] == DER_SEQUENCE &&
               request[info[2], algorithm[2] - info[2]] == ECDSA_SHA256_ALGORITHM &&
               signature[0] == DER_BIT_STRING && signature[2] == request.size &&
               request[signature[1]] == DER_NO_PADDING
          raise Matter::CertificateError.new("Invalid ICAC CSR structure or signature algorithm")
        end

        public_key = extract_public_key(request[info[1], info[2] - info[1]], crypto)
        unless public_key == trusted_public_key
          raise Matter::CertificateError.new("ICAC CSR public key differs from authenticated ICAC")
        end
        key = Key.new(KeyType::EC, CurveType::P256)
        key.public_bits = trusted_public_key
        crypto.verify_ecdsa(key, request[outer[1], info[2] - outer[1]],
          request[signature[1] + 1, signature[2] - signature[1] - 1], "der")
      rescue ex : Matter::Error
        raise ex
      rescue ex
        raise Matter::CertificateError.new("Invalid ICAC CSR: #{ex.message}", cause: ex)
      end

      private def extract_public_key(info : Bytes, crypto : CryptoBase) : Bytes
        # The SPKI must match the SDK's DER encoding for a P-256 public key.
        # This also checks the algorithm and curve OIDs and no unused bits.
        offset = CSR_VERSION.size
        subject = der_element(info, offset)
        offset = subject[2]
        spki = der_element(info, offset)
        unless spki[0] == DER_SEQUENCE
          raise Matter::CertificateError.new("ICAC CSR lacks SubjectPublicKeyInfo")
        end
        encoded = info[offset, spki[2] - offset]
        bit_string = der_element(info, der_element(info, spki[1])[2])
        unless bit_string[0] == DER_BIT_STRING &&
               bit_string[2] - bit_string[1] == PUBLIC_KEY_SIZE + 1 &&
               info[bit_string[1]] == DER_NO_PADDING
          raise Matter::CertificateError.new("ICAC CSR lacks P-256 public key")
        end
        public_key = info[bit_string[1] + 1, PUBLIC_KEY_SIZE]
        unless encoded == crypto.build_ec_public_key_der(public_key)
          raise Matter::CertificateError.new("ICAC CSR public key algorithm is not P-256")
        end
        public_key
      end

      # {tag, content_start, element_end}
      private def der_element(data : Bytes, offset : Int32) : Tuple(UInt8, Int32, Int32)
        tag = data[offset]? || raise Matter::CertificateError.new("Truncated ICAC CSR")
        marker = data[offset + 1]? || raise Matter::CertificateError.new("Truncated ICAC CSR length")
        cursor = offset + 2
        length = 0
        if marker < DER_LONG_FORM
          length = marker.to_i
        else
          count = (marker & 0x7f).to_i
          if count == 0 || count > 4 || cursor + count > data.size
            raise Matter::CertificateError.new("Invalid ICAC CSR length")
          end
          count.times do
            length = (length << 8) | data[cursor].to_i
            cursor += 1
          end
        end
        ending = cursor + length
        raise Matter::CertificateError.new("Truncated ICAC CSR element") if ending > data.size
        {tag, cursor, ending}
      end

      private def sequence(content : Bytes) : Bytes
        io = IO::Memory.new
        io.write_byte DER_SEQUENCE
        write_length(io, content.size)
        io.write content
        io.to_slice
      end

      private def write_length(io : IO, length : Int32) : Nil
        if length < DER_LONG_FORM
          io.write_byte length.to_u8
        else
          bytes = [] of UInt8
          remaining = length
          while remaining > 0
            bytes.unshift((remaining & 0xff).to_u8)
            remaining >>= 8
          end
          io.write_byte (DER_LONG_FORM | bytes.size).to_u8
          bytes.each { |byte| io.write_byte byte }
        end
      end
    end
  end
end
