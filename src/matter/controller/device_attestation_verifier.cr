require "openssl_ext"
require "../certificate/certification_declaration"
require "../commissioning/credential_service"
require "../crypto/pkcs10"

lib LibCrypto
  fun x509_check_ca = X509_check_ca(cert : X509) : Int32
  fun x509_get_key_usage = X509_get_key_usage(cert : X509) : UInt32
  fun x509_get0_subject_key_id = X509_get0_subject_key_id(cert : X509) : ASN1_STRING
  fun x509_get0_authority_key_id = X509_get0_authority_key_id(cert : X509) : ASN1_STRING
end

module Matter
  module Controller
    enum RevocationStatus
      Good
      Revoked
      Unavailable
    end

    # The caller supplies every trusted root and CD signer. The library never
    # installs the well-known Matter test credentials as production trust.
    class AttestationTrustStore
      getter paa_certificates : Array(Bytes)
      getter cd_signers : Hash(String, Bytes)
      getter? allow_test_attestation : Bool
      getter revocation_check : Proc(Bytes, Bytes, Bytes, RevocationStatus)?

      def initialize(@paa_certificates : Array(Bytes), @cd_signers : Hash(String, Bytes),
                     @allow_test_attestation : Bool = false,
                     @revocation_check : Proc(Bytes, Bytes, Bytes, RevocationStatus)? = nil)
      end

      # Explicit development-only trust for this repository's example DACs.
      def self.matter_test_fixture : AttestationTrustStore
        signer = Certificate::CertificationDeclaration::TEST_CMS_SIGNER_PRIVATE_KEY.hexbytes
        public_key = OpenSSL::PKey::EC.from_private_bytes(signer,
          Crypto::CRYPTO_EC_CURVE_NIST).public_key_bytes
        new([Certificate::ChipPAAuthorities::TEST_CERT_PAA_NO_VID_CERT],
          {Certificate::CertificationDeclaration::TEST_CMS_SIGNER_SKI => public_key},
          allow_test_attestation: true,
          revocation_check: ->(_dac : Bytes, _pai : Bytes, _paa : Bytes) { RevocationStatus::Good })
      end
    end

    class DeviceAttestationVerifier
      MAX_CERTIFICATE_SIZE         = 2048
      MAX_DECLARATION_SIZE         = 4096
      NONCE_SIZE                   =   32
      P256_PUBLIC_KEY_SIZE         =   65
      VENDOR_ID_OID                = "1.3.6.1.4.1.37244.2.1"
      PRODUCT_ID_OID               = "1.3.6.1.4.1.37244.2.2"
      SIGNED_DATA_OID              = Bytes[0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x02]
      DATA_OID                     = Bytes[0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x01]
      CONTENT_TYPE_ATTRIBUTE_OID   = Bytes[0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x09, 0x03]
      MESSAGE_DIGEST_ATTRIBUTE_OID = Bytes[0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x09, 0x04]
      KEY_USAGE_DIGITAL_SIGNATURE  = 0x80_u32
      KEY_USAGE_CERT_SIGN          = 0x04_u32

      def initialize(@trust : AttestationTrustStore, @crypto : Crypto::CryptoBase = Crypto::StandardCrypto.new)
      end

      # Returns the authenticated DAC key for later CSRResponse verification.
      def verify_attestation(dac_der : Bytes, pai_der : Bytes, elements_bytes : Bytes,
                             signature : Bytes, nonce : Bytes, challenge : Bytes,
                             vendor_id : UInt16, product_id : UInt16) : Bytes
        unless nonce.size == NONCE_SIZE && challenge.size == 16 &&
               dac_der.size.in?(1..MAX_CERTIFICATE_SIZE) && pai_der.size.in?(1..MAX_CERTIFICATE_SIZE)
          raise Matter::AuthenticationError.new("Invalid attestation certificate or challenge length")
        end
        dac = OpenSSL::X509::Certificate.from_der(dac_der)
        pai = OpenSSL::X509::Certificate.from_der(pai_der)
        paa = @trust.paa_certificates.find do |candidate|
          next false unless candidate.size.in?(1..MAX_CERTIFICATE_SIZE)
          if candidate == Certificate::ChipPAAuthorities::TEST_CERT_PAA_NO_VID_CERT &&
             !@trust.allow_test_attestation?
            next false
          end
          root = OpenSSL::X509::Certificate.from_der(candidate)
          pai.issuer.to_a == root.subject.to_a && pai.verify(root.public_key)
        end
        raise Matter::AuthenticationError.new("No trusted PAA signs the PAI") unless paa
        root = OpenSSL::X509::Certificate.from_der(paa)
        now = Time.utc
        {dac, pai, root}.each do |cert|
          unless cert.not_before <= now && now <= cert.not_after
            raise Matter::AuthenticationError.new("Attestation certificate is outside its validity period")
          end
        end
        unless root.issuer.to_a == root.subject.to_a && root.verify(root.public_key) &&
               dac.issuer.to_a == pai.subject.to_a && dac.verify(pai.public_key)
          raise Matter::AuthenticationError.new("Invalid attestation certificate chain")
        end
        unless key_id(pai, authority: true) == key_id(root) &&
               key_id(dac, authority: true) == key_id(pai)
          raise Matter::AuthenticationError.new("Attestation AKID/SKID mismatch")
        end
        require_ca(root)
        require_ca(pai)
        require_end_entity(dac)
        status = @trust.revocation_check.try(&.call(dac_der, pai_der, paa)) || RevocationStatus::Unavailable
        unless status.good?
          raise Matter::AuthenticationError.new("Attestation revocation status is #{status}")
        end
        dac_vendor = subject_id(dac, VENDOR_ID_OID)
        pai_vendor = subject_id(pai, VENDOR_ID_OID)
        paa_vendor = subject_id(root, VENDOR_ID_OID)
        if dac_vendor.nil? || dac_vendor != pai_vendor ||
           (paa_vendor && paa_vendor != pai_vendor)
          raise Matter::AuthenticationError.new("Attestation certificate VID mismatch")
        end

        elements = ::Matter::Commissioning::CredentialService::AttestationElements.from_slice(elements_bytes)
        unless elements.attestation_nonce == nonce
          raise Matter::AuthenticationError.new("Attestation nonce mismatch")
        end
        verify_declaration(elements.certification_declaration, vendor_id, product_id, dac, pai, root)
        key_bytes = dac.public_key.as(OpenSSL::PKey::EC).public_key_bytes
        unless key_bytes.size == P256_PUBLIC_KEY_SIZE
          raise Matter::AuthenticationError.new("DAC key is not P-256")
        end
        verify_signature(key_bytes, elements_bytes, challenge, signature)
        key_bytes
      rescue ex : Matter::Error
        raise ex
      rescue ex
        raise Matter::AuthenticationError.new("Invalid device attestation: #{ex.message}", cause: ex)
      end

      def verify_csr(response : Cluster::OperationalCredentials::Tlv::CsrResponse,
                     nonce : Bytes, challenge : Bytes, dac_public_key : Bytes) : Bytes
        elements = ::Matter::Commissioning::CredentialService::CSRElements.from_slice(response.nocsr_elements)
        unless nonce.size == NONCE_SIZE && elements.csr_nonce == nonce
          raise Matter::AuthenticationError.new("CSR nonce mismatch")
        end
        verify_signature(dac_public_key, response.nocsr_elements, challenge, response.attestation_signature)
        key = CertificateUtil.extract_uncompressed_public_key_from_csr(elements.csr)
        Crypto::Pkcs10.verify(elements.csr, key, @crypto)
        key
      rescue ex : Matter::Error
        raise ex
      rescue ex
        raise Matter::AuthenticationError.new("Invalid CSR response: #{ex.message}", cause: ex)
      end

      private def verify_signature(key_bytes : Bytes, data : Bytes, challenge : Bytes, signature : Bytes) : Nil
        key = Crypto::Key.new(Crypto::KeyType::EC, Crypto::CurveType::P256)
        key.public_bits = key_bytes
        @crypto.verify_ecdsa(key, data + challenge, signature)
      end

      private def subject_id(cert : OpenSSL::X509::Certificate, oid : String) : UInt16?
        value = cert.subject.to_a.find(&.[0].starts_with?(oid)).try(&.[1])
        return unless value && value.matches?(/\A[0-9A-Fa-f]{4}\z/)
        value.to_u16(16)
      end

      private def key_id(cert : OpenSSL::X509::Certificate, authority : Bool = false) : Bytes
        pointer = authority ? LibCrypto.x509_get0_authority_key_id(cert) : LibCrypto.x509_get0_subject_key_id(cert)
        raise Matter::AuthenticationError.new("Attestation certificate lacks key identifier") if pointer.null?
        length = LibCrypto.asn1_string_length(pointer)
        raise Matter::AuthenticationError.new("Invalid attestation key identifier") unless length == 20
        Slice.new(LibCrypto.asn1_string_get0_data(pointer).as(UInt8*), length).dup
      end

      private def require_ca(cert : OpenSSL::X509::Certificate) : Nil
        constraint = cert.extensions.find { |ext| ext.oid == "basicConstraints" }
        usage = LibCrypto.x509_get_key_usage(cert)
        unless constraint && constraint.value.includes?("CA:TRUE") &&
               LibCrypto.x509_check_ca(cert) > 0 && (usage & KEY_USAGE_CERT_SIGN) != 0
          raise Matter::AuthenticationError.new("Attestation issuer lacks CA/key usage constraints")
        end
      end

      private def require_end_entity(cert : OpenSSL::X509::Certificate) : Nil
        constraint = cert.extensions.find { |ext| ext.oid == "basicConstraints" }
        usage = LibCrypto.x509_get_key_usage(cert)
        unless constraint && constraint.value.includes?("CA:FALSE") &&
               LibCrypto.x509_check_ca(cert) == 0 && (usage & KEY_USAGE_DIGITAL_SIGNATURE) != 0
          raise Matter::AuthenticationError.new("DAC lacks end-entity/key usage constraints")
        end
      end

      # The signature covers the payload directly when signedAttrs is absent;
      # otherwise RFC 5652 requires a DER SET OF signedAttrs and a digest of
      # the encapsulated payload inside those attributes.
      private def verify_declaration(cms : Bytes, vendor_id : UInt16, product_id : UInt16,
                                     dac : OpenSSL::X509::Certificate, pai : OpenSSL::X509::Certificate,
                                     paa : OpenSSL::X509::Certificate) : Nil
        raise Matter::AuthenticationError.new("Certification Declaration is too large") if cms.size > MAX_DECLARATION_SIZE
        outer = DerReader.new(cms)
        content_info = outer.read(Codec::DERCodec::Tag::SEQUENCE)
        outer.finished!
        info = DerReader.new(content_info)
        unless info.read(Codec::DERCodec::Tag::OBJECT_IDENTIFIER) == SIGNED_DATA_OID
          raise Matter::AuthenticationError.new("Certification Declaration is not CMS SignedData")
        end
        signed_wrapper = DerReader.new(info.read(Codec::DERCodec::Tag::CONTEXT_0_CONSTRUCTED))
        signed = DerReader.new(signed_wrapper.read(Codec::DERCodec::Tag::SEQUENCE))
        signed_wrapper.finished!
        info.finished!
        signed.read(Codec::DERCodec::Tag::INTEGER)
        digest_algorithm = Codec::DERCodec::Base.encode(Codec::DERCodec::SHA256_CMS.call)
        unless signed.read(Codec::DERCodec::Tag::SET) == digest_algorithm
          raise Matter::AuthenticationError.new("Unsupported Certification Declaration digest")
        end
        encapsulated = DerReader.new(signed.read(Codec::DERCodec::Tag::SEQUENCE))
        unless encapsulated.read(Codec::DERCodec::Tag::OBJECT_IDENTIFIER) == DATA_OID
          raise Matter::AuthenticationError.new("Unsupported CD encapsulated content")
        end
        payload_wrapper = DerReader.new(encapsulated.read(Codec::DERCodec::Tag::CONTEXT_0_CONSTRUCTED))
        payload = payload_wrapper.read(Codec::DERCodec::Tag::OCTET_STRING)
        payload_wrapper.finished!
        encapsulated.finished!
        signers = DerReader.new(signed.read(Codec::DERCodec::Tag::SET))
        signer = DerReader.new(signers.read(Codec::DERCodec::Tag::SEQUENCE))
        signers.finished!
        signed.finished!
        signer.read(Codec::DERCodec::Tag::INTEGER)
        ski = signer.read(Codec::DERCodec::Tag::CONTEXT_0_PRIMITIVE)
        unless signer.read(Codec::DERCodec::Tag::SEQUENCE) == DerReader.new(digest_algorithm).read(Codec::DERCodec::Tag::SEQUENCE)
          raise Matter::AuthenticationError.new("Unsupported Certification Declaration digest algorithm")
        end
        signed_content = payload
        if signer.next_tag == Codec::DERCodec::Tag::CONTEXT_0_CONSTRUCTED
          attributes = signer.read(Codec::DERCodec::Tag::CONTEXT_0_CONSTRUCTED)
          verify_signed_attributes(attributes, payload)
          io = IO::Memory.new
          io.write_byte(Codec::DERCodec::Tag::SET)
          io.write(Codec::DERCodec::Base.encode_length_bytes(attributes.size))
          io.write(attributes)
          signed_content = io.to_slice
        end
        unless signer.read(Codec::DERCodec::Tag::SEQUENCE) == DerReader.new(
                 Codec::DERCodec::Base.encode(Codec::DERCodec::ECDSA_WITH_SHA256_X962.call)).read(Codec::DERCodec::Tag::SEQUENCE)
          raise Matter::AuthenticationError.new("Unsupported Certification Declaration signature algorithm")
        end
        signature = signer.read(Codec::DERCodec::Tag::OCTET_STRING)
        signer.finished!
        public_key = @trust.cd_signers[ski.hexstring.upcase]? ||
                     raise Matter::AuthenticationError.new("Untrusted Certification Declaration signer")
        key = Crypto::Key.new(Crypto::KeyType::EC, Crypto::CurveType::P256)
        key.public_bits = public_key
        @crypto.verify_ecdsa(key, signed_content, signature, "der")
        declaration = Certificate::CertificationDeclaration::CDContent.from_slice(payload)
        unless declaration.format_version == 1_u8 && declaration.vendor_id == vendor_id &&
               declaration.product_ids.includes?(product_id) && declaration.certification_type <= 2_u8
          raise Matter::AuthenticationError.new("Certification Declaration VID/PID or type mismatch")
        end
        origin_vendor = declaration.dac_origin_vendor_id
        origin_product = declaration.dac_origin_product_id
        if origin_vendor.nil? != origin_product.nil?
          raise Matter::AuthenticationError.new("Certification Declaration origin VID and PID must appear together")
        end
        expected_vendor = origin_vendor || declaration.vendor_id
        expected_products = origin_product ? [origin_product] : declaration.product_ids
        dac_product = subject_id(dac, PRODUCT_ID_OID)
        pai_product = subject_id(pai, PRODUCT_ID_OID)
        unless subject_id(dac, VENDOR_ID_OID) == expected_vendor &&
               subject_id(pai, VENDOR_ID_OID) == expected_vendor &&
               dac_product && expected_products.includes?(dac_product) &&
               (pai_product.nil? || expected_products.includes?(pai_product))
          raise Matter::AuthenticationError.new("Certification Declaration DAC origin mismatch")
        end
        if authorized_paas = declaration.authorized_paa_list
          unless authorized_paas.size.in?(1..10) && authorized_paas.all?(&.size.==(20)) &&
                 authorized_paas.includes?(key_id(paa))
            raise Matter::AuthenticationError.new("Certification Declaration has no authorized PAA")
          end
        end
      end

      private def verify_signed_attributes(bytes : Bytes, payload : Bytes) : Nil
        attributes = DerReader.new(bytes)
        content_type_count = 0
        digest_count = 0
        until attributes.finished?
          attribute = DerReader.new(attributes.read(Codec::DERCodec::Tag::SEQUENCE))
          oid = attribute.read(Codec::DERCodec::Tag::OBJECT_IDENTIFIER)
          values = DerReader.new(attribute.read(Codec::DERCodec::Tag::SET))
          attribute.finished!
          if oid == CONTENT_TYPE_ATTRIBUTE_OID
            content_type_count += 1
            unless values.read(Codec::DERCodec::Tag::OBJECT_IDENTIFIER) == DATA_OID
              raise Matter::AuthenticationError.new("Certification Declaration signed content type mismatch")
            end
          elsif oid == MESSAGE_DIGEST_ATTRIBUTE_OID
            digest_count += 1
            unless values.read(Codec::DERCodec::Tag::OCTET_STRING) == @crypto.compute_sha256(payload)
              raise Matter::AuthenticationError.new("Certification Declaration signed digest mismatch")
            end
          else
            # Other CMS attributes, such as signingTime, are covered by the
            # signature but do not change the two required content bindings.
            while tag = values.next_tag
              values.read(tag)
            end
          end
          values.finished!
        end
        unless content_type_count == 1 && digest_count == 1
          raise Matter::AuthenticationError.new("Certification Declaration signed attributes are incomplete")
        end
      end

      private class DerReader
        def initialize(@bytes : Bytes)
          @offset = 0
        end

        def read(expected : UInt8) : Bytes
          tag = @bytes[@offset]? || raise Matter::AuthenticationError.new("Truncated DER")
          raise Matter::AuthenticationError.new("Unexpected DER tag") unless tag == expected
          marker = @bytes[@offset + 1]? || raise Matter::AuthenticationError.new("Truncated DER length")
          @offset += 2
          length = marker.to_i
          if marker >= Codec::DERCodec::LONG_FORM_LENGTH.to_u8
            count = (marker & 0x7f_u8).to_i
            raise Matter::AuthenticationError.new("Invalid DER length") unless count.in?(1..2)
            length = 0
            count.times do
              byte = @bytes[@offset]? || raise Matter::AuthenticationError.new("Truncated DER length")
              length = (length << 8) | byte.to_i
              @offset += 1
            end
          end
          raise Matter::AuthenticationError.new("Truncated DER content") if @offset + length > @bytes.size
          content = @bytes[@offset, length]
          @offset += length
          content
        end

        def next_tag : UInt8?
          @bytes[@offset]?
        end

        def finished? : Bool
          @offset == @bytes.size
        end

        def finished! : Nil
          raise Matter::AuthenticationError.new("Trailing DER data") unless @offset == @bytes.size
        end
      end
    end
  end
end
