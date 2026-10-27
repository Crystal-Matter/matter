require "openssl_ext"
require "../codec/der_codec"
require "../crypto/crypto"
require "../crypto/key"
require "tlv"

module Matter
  module Certificate
    # Generates Certification Declaration (CD) for Matter devices
    # The CD is a PKCS#7 SignedData structure containing device certification info
    # Used during commissioning to prove device compliance
    class CertificationDeclaration
      # Test CMS Signer Private Key from Matter 1.1 Core Spec Appendix F
      # This is the well-known test key that chip-tool trusts
      TEST_CMS_SIGNER_PRIVATE_KEY = "AEF3484116E9481EC57BE0472DF41BF499064E5024AD869ECA5E889802D48075"

      # Subject Key Identifier for the test CMS signer certificate
      TEST_CMS_SIGNER_SKI = "62FA823359ACFAA9963E1CFA140ADDF504F37160"

      # The test CD uses Root Node (0x0016). Certificate loading precedes the
      # device type catalog, so its fixture ID is declared here.
      TEST_CD_DEVICE_TYPE_ID = 0x0016_u32

      # CD TLV content structure
      # Based on Matter Core Spec section 6.3.1
      struct CDContent
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property format_version : UInt8

        @[TLV::Field(tag: 1, fixed_size: true)]
        property vendor_id : UInt16

        @[TLV::Field(tag: 2)]
        property product_ids : Array(UInt16)

        @[TLV::Field(tag: 3, fixed_size: true)]
        property device_type_id : UInt32

        @[TLV::Field(tag: 4)]
        property certificate_id : String

        @[TLV::Field(tag: 5)]
        property security_level : UInt8

        @[TLV::Field(tag: 6, fixed_size: true)]
        property security_information : UInt16

        @[TLV::Field(tag: 7, fixed_size: true)]
        property version_number : UInt16

        @[TLV::Field(tag: 8)]
        property certification_type : UInt8

        @[TLV::Field(tag: 9, optional: true)]
        property dac_origin_vendor_id : UInt16?

        @[TLV::Field(tag: 10, optional: true)]
        property dac_origin_product_id : UInt16?

        @[TLV::Field(tag: 11, optional: true)]
        property authorized_paa_list : Array(Bytes)?

        def initialize(
          @format_version : UInt8,
          @vendor_id : UInt16,
          @product_ids : Array(UInt16),
          @device_type_id : UInt32,
          @certificate_id : String,
          @security_level : UInt8,
          @security_information : UInt16,
          @version_number : UInt16,
          @certification_type : UInt8,
          @dac_origin_vendor_id : UInt16? = nil,
          @dac_origin_product_id : UInt16? = nil,
          @authorized_paa_list : Array(Bytes)? = nil,
        )
        end
      end

      # Generate a Certification Declaration for a device
      def self.generate(vendor_id : UInt16, product_id : UInt16) : Bytes
        # Build CD content as TLV
        cd_content = build_cd_tlv(vendor_id, product_id)

        # Sign with test CMS key using PKCS#7 SignedData format
        build_pkcs7_signed_data(cd_content)
      end

      # Build the CD TLV structure
      # Based on Matter Core Spec section 6.3.1
      private def self.build_cd_tlv(vendor_id : UInt16, product_id : UInt16) : Bytes
        content = CDContent.new(
          format_version: 1_u8,
          vendor_id: vendor_id,
          product_ids: [product_id],
          device_type_id: TEST_CD_DEVICE_TYPE_ID,
          certificate_id: "CSA00000SWC00000-00",
          security_level: 0_u8,
          security_information: 0_u16,
          version_number: 1_u16,
          certification_type: 0_u8
        )
        content.to_slice
      end

      # Build PKCS#7 SignedData ASN.1 structure
      # Manually builds DER bytes in correct RFC 5652 field order
      private def self.build_pkcs7_signed_data(content : Bytes) : Bytes
        # Load the test private key
        key_bytes = Bytes.new(TEST_CMS_SIGNER_PRIVATE_KEY.hexbytes.size)
        TEST_CMS_SIGNER_PRIVATE_KEY.hexbytes.to_a.each_with_index do |byte, i|
          key_bytes[i] = byte
        end

        # Derive public key from private key using OpenSSL
        ec_key = OpenSSL::PKey::EC.from_private_bytes(key_bytes, Crypto::CRYPTO_EC_CURVE_NIST)
        public_key_bytes = ec_key.public_key_bytes

        # Create Key with both private and public keys
        key_pair = Crypto::BinaryKeyPair.new(public_key_bytes, key_bytes)
        key = Crypto.private_key(key_pair)

        # Sign the content with ECDSA (DER format for PKCS#7)
        signature = Crypto.sign_ecdsa(key, content, "der")

        # Subject Key Identifier as bytes
        ski_bytes = Bytes.new(TEST_CMS_SIGNER_SKI.hexbytes.size)
        TEST_CMS_SIGNER_SKI.hexbytes.to_a.each_with_index do |byte, i|
          ski_bytes[i] = byte
        end

        # Build SignerInfo SEQUENCE manually in RFC 5652 order:
        # version, sid, digestAlgorithm, signatureAlgorithm, signature
        signer_info_fields = [] of Bytes
        signer_info_fields << Codec::DERCodec::Base.encode(3_u8) # version

        # Build SubjectKeyIdentifier as context-specific [0] primitive (just raw bytes)
        ski_io = IO::Memory.new
        ski_io.write_byte(0x80_u8) # Context-specific [0] (primitive)
        ski_length_bytes = Codec::DERCodec::Base.encode_length_bytes(ski_bytes.size)
        ski_io.write(ski_length_bytes)
        ski_io.write(ski_bytes)
        signer_info_fields << ski_io.to_slice # sid

        signer_info_fields << Codec::DERCodec::Base.encode(Codec::DERCodec::SHA256_CMS.call)             # digestAlgorithm
        signer_info_fields << Codec::DERCodec::Base.encode(Codec::DERCodec::ECDSA_WITH_SHA256_X962.call) # signatureAlgorithm
        signer_info_fields << Codec::DERCodec::Base.encode(signature)                                    # signature
        signer_info_seq = Codec::DERCodec::Base.encode_sequence(Slice(UInt8).join(signer_info_fields))

        # Build SET OF SignerInfo (tag 0x31 = SET | CONSTRUCTED)
        io = IO::Memory.new
        io.write_byte(0x31_u8) # SET | CONSTRUCTED
        length_bytes = Codec::DERCodec::Base.encode_length_bytes(signer_info_seq.size)
        io.write(length_bytes)
        io.write(signer_info_seq)
        signer_infos_set = io.to_slice

        # Build digestAlgorithms SET (tag 0x31)
        digest_alg_encoded = Codec::DERCodec::Base.encode(Codec::DERCodec::SHA256_CMS.call)
        io2 = IO::Memory.new
        io2.write_byte(0x31_u8) # SET | CONSTRUCTED
        length_bytes2 = Codec::DERCodec::Base.encode_length_bytes(digest_alg_encoded.size)
        io2.write(length_bytes2)
        io2.write(digest_alg_encoded)
        digest_algs_set = io2.to_slice

        # Build SignedData SEQUENCE in RFC 5652 order:
        # version, digestAlgorithms, encapContentInfo, signerInfos
        signed_data_fields = [] of Bytes
        signed_data_fields << Codec::DERCodec::Base.encode(3_u8)                                     # version
        signed_data_fields << digest_algs_set                                                        # digestAlgorithms SET
        signed_data_fields << Codec::DERCodec::Base.encode(Codec::DERCodec::Pkcs7Data.call(content)) # encapContentInfo
        signed_data_fields << signer_infos_set                                                       # signerInfos SET
        signed_data_seq = Codec::DERCodec::Base.encode_sequence(Slice(UInt8).join(signed_data_fields))

        # Wrap in PKCS#7 SignedData OID manually to avoid double-encoding
        # Structure: SEQUENCE { OID(pkcs7-signedData), [0] EXPLICIT <raw SignedData bytes> }

        # Build context tag [0] EXPLICIT (CONSTRUCTED) with raw SignedData bytes
        ctx_io = IO::Memory.new
        ctx_io.write_byte(0xA0_u8) # Context [0] | CONSTRUCTED
        ctx_length = Codec::DERCodec::Base.encode_length_bytes(signed_data_seq.size)
        ctx_io.write(ctx_length)
        ctx_io.write(signed_data_seq)
        context_tagged = ctx_io.to_slice

        # Build PKCS#7 OID
        pkcs7_oid = Codec::DERCodec::Base.encode(Codec::DERCodec::ObjectId.new("2a864886f70d010702").value)

        # Combine OID + context-tagged SignedData in a SEQUENCE
        Codec::DERCodec::Base.encode_sequence(Slice(UInt8).join([pkcs7_oid, context_tagged]))
      end
    end
  end
end
