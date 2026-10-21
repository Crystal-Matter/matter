require "log"
require "tlv"

require "../error"
require "../datatype/node_id"

module Matter
  module Crypto
    # Matter Certificate TLV encoding as per Matter spec section 6.5.2
    # This represents the Matter Operational Certificate (NOC) format

    # Distinguished Name (DN) attributes for certificate subject/issuer
    # These appear as context-tagged elements within a LIST (not Structure)
    # Matter uses TLV List format for DN attributes
    @[TLV::ListFormat]
    struct DNAttributes
      include TLV::Serializable

      # Matter-specific DN attribute OIDs mapped to context tags:
      # Tag 17 (0x11): matter-node-id
      # Tag 18 (0x12): matter-firmware-signing-id
      # Tag 19 (0x13): matter-icac-id
      # Tag 20 (0x14): matter-rcac-id
      # Tag 21 (0x15): matter-fabric-id
      # Tag 22 (0x16): matter-noc-cat

      @[TLV::Field(tag: 17, optional: true)]
      property node_id : UInt64?

      @[TLV::Field(tag: 18, optional: true)]
      property firmware_signing_id : UInt64?

      @[TLV::Field(tag: 19, optional: true)]
      property icac_id : UInt64?

      @[TLV::Field(tag: 20, optional: true)]
      property rcac_id : UInt64?

      @[TLV::Field(tag: 21, optional: true)]
      property fabric_id : UInt64?

      @[TLV::Field(tag: 22, optional: true)]
      property noc_cat : UInt32?

      def initialize(
        @node_id : UInt64? = nil,
        @fabric_id : UInt64? = nil,
        @icac_id : UInt64? = nil,
        @rcac_id : UInt64? = nil,
        @firmware_signing_id : UInt64? = nil,
        @noc_cat : UInt32? = nil,
      )
      end
    end

    # Matter Certificate TLV structure
    # See Matter spec section 6.5.2 "Matter Certificate Encoding"
    struct MatterCertificate
      include TLV::Serializable

      Log                             = ::Log.for("matter.crypto.certificate")
      ANCHOR_ICAC_ORGANIZATIONAL_UNIT = "jf-anchor-icac"

      # Context tags the raw-TLV helpers below reach for. A certificate that
      # `TLV::Serializable` cannot decode (a truncated or vendor-extended NOC)
      # can still be scanned field by field.
      enum Tag : UInt8
        Subject              =  6
        PublicKey            =  9
        NodeId               = 17
        CaseAuthenticatedTag = 22
      end

      # Tag 1: Serial number (octet string, 1-20 bytes)
      @[TLV::Field(tag: 1)]
      property serial_number : Bytes

      # Tag 2: Signature algorithm (unsigned int)
      # 1 = ECDSA with SHA256
      @[TLV::Field(tag: 2)]
      property signature_algorithm : UInt8

      # Tag 3: Issuer DN (list of DN attributes)
      @[TLV::Field(tag: 3)]
      property issuer : DNAttributes

      # Tag 4: Not Before (unsigned int, Matter epoch seconds)
      @[TLV::Field(tag: 4)]
      property not_before : UInt32

      # Tag 5: Not After (unsigned int, Matter epoch seconds)
      @[TLV::Field(tag: 5)]
      property not_after : UInt32

      # Tag 6: Subject DN (list of DN attributes)
      @[TLV::Field(tag: 6)]
      property subject : DNAttributes

      # Tag 7: Public key algorithm (unsigned int)
      # 1 = EC public key
      @[TLV::Field(tag: 7)]
      property public_key_algorithm : UInt8

      # Tag 8: Elliptic curve ID (unsigned int)
      # 1 = prime256v1 (P-256)
      @[TLV::Field(tag: 8)]
      property elliptic_curve_id : UInt8

      # Tag 9: EC public key (octet string, 65 bytes for uncompressed P-256)
      @[TLV::Field(tag: 9)]
      property ec_public_key : Bytes

      # Tag 10: Extensions (list)
      @[TLV::Field(tag: 10, optional: true)]
      property extensions : TLV::Any?

      # Tag 11: Signature (octet string, 64 bytes for P-256 ECDSA)
      @[TLV::Field(tag: 11)]
      property signature : Bytes

      def initialize(
        @serial_number : Bytes,
        @signature_algorithm : UInt8,
        @issuer : DNAttributes,
        @not_before : UInt32,
        @not_after : UInt32,
        @subject : DNAttributes,
        @public_key_algorithm : UInt8,
        @elliptic_curve_id : UInt8,
        @ec_public_key : Bytes,
        @signature : Bytes,
        @extensions : TLV::Any? = nil,
      )
      end

      # Extract the EC public key (tag 9) from a Matter TLV certificate.
      #
      # Raises `Matter::CertificateError` when the certificate carries no
      # public key field.
      def self.public_key_from_tlv(cert_tlv : Bytes) : Bytes
        public_key = find_tlv_field(TLV::Any.from_slice(cert_tlv), Tag::PublicKey)
        if public_key.nil?
          raise Matter::CertificateError.new("Could not find public key field (tag #{Tag::PublicKey.value}) in TLV certificate")
        end

        public_key.as_bytes
      end

      # Node ID of a Matter TLV certificate (Subject DN tag 17), or `nil` when
      # the certificate has no Subject DN or no Node ID in it.
      def self.node_id_from_tlv(cert_tlv : Bytes) : UInt64?
        begin
          if node_id = from_slice(cert_tlv).node_id
            return node_id
          end
        rescue ex
          Log.trace(exception: ex) { "Failed to parse NodeId via MatterCertificate, falling back to a raw TLV scan" }
        end

        subject = find_tlv_field(TLV::Any.from_slice(cert_tlv), Tag::Subject)
        return unless subject

        node_id = find_tlv_field(subject, Tag::NodeId)
        return unless node_id

        case value = node_id.value
        when UInt64 then value
        when UInt32 then value.to_u64
        when UInt16 then value.to_u64
        when UInt8  then value.to_u64
        when Int    then value.to_u64
        end
      rescue ex
        Log.trace(exception: ex) { "Failed to parse NodeId from certificate TLV" }
        nil
      end

      # All authenticated Subject IDs of a Matter TLV NOC:
      #
      # - the Node ID (Subject DN tag 17)
      # - zero or more CASE Authenticated Tags (Subject DN tag 22)
      #
      # Returned in priority order (Node ID first), de-duplicated. Used for ACL
      # evaluation, where a subject may be a Node ID or a CAT.
      def self.subject_ids_from_tlv(cert_tlv : Bytes) : Array(UInt64)
        subject_ids = [] of UInt64

        if node_id = node_id_from_tlv(cert_tlv)
          subject_ids << node_id
        end

        # CATs may be encoded as multiple tag-22 entries in the Subject DN list.
        # TLV::Serializable currently only exposes a single `noc_cat`, so scan the TLV directly.
        begin
          parsed = TLV::Any.from_slice(cert_tlv)
          if tlv_struct = parsed.value.as?(TLV::Structure)
            if subject_any = tlv_struct[Tag::Subject.value]?
              subject_list = [] of TLV::Any
              case value = subject_any.value
              when Array(TLV::Any)
                subject_list = value
              when TLV::List
                value.each { |elem| subject_list << elem }
              else
                # A Subject DN that is neither a list nor an array carries no CATs
              end

              subject_list.each do |elem|
                next unless elem.header.ids == Tag::CaseAuthenticatedTag.value

                raw = elem.as_u32?
                next unless raw

                begin
                  cat = DataType::CaseAuthenticatedTag.new(raw)
                  subject_ids << DataType::NodeId.from_case_authenticated_tag(cat).id
                rescue ex
                  Log.trace(exception: ex) { "Skipping invalid CAT value in NOC (raw=0x#{raw.to_s(16)})" }
                end
              end
            end
          end
        rescue ex
          Log.trace(exception: ex) { "Failed scanning NOC for CATs" }
        end

        subject_ids.uniq!
        subject_ids
      end

      # Joint Fabric Anchor authority marker in the ICAC Subject DN. CASE
      # certificate-chain verification is a separate prerequisite; callers
      # use this after the peer's chain has already been authenticated.
      def self.anchor_icac?(cert_tlv : Bytes) : Bool
        parsed = TLV::Any.from_slice(cert_tlv)
        subject = parsed.as_structure?.try(&.[Asn1::Field::Subject.value]?).try(&.as_list?)
        return false unless subject
        subject.any? do |attribute|
          attribute.header.ids == Asn1::Dn::OrgUnitName.value &&
            attribute.as_s? == ANCHOR_ICAC_ORGANIZATIONAL_UNIT
        end
      rescue
        false
      end

      # Recursively search a decoded TLV certificate for a field by context tag
      private def self.find_tlv_field(data : TLV::Any, tag : Tag) : TLV::Any?
        tag_id = tag.value

        case value = data.value
        when TLV::Structure
          return value[tag_id]? if value.has_key?(tag_id)

          # Recursively search nested structures
          value.each_value do |nested|
            if found = find_tlv_field(nested, tag)
              return found
            end
          end
        when TLV::List
          value.each do |elem|
            # Check if this list element has the tag we're looking for
            return elem if elem.header.ids == tag_id

            # Also recurse in case it's a nested container
            if found = find_tlv_field(elem, tag)
              return found
            end
          end
        end

        nil
      end

      # Extract fabric ID from subject DN
      def fabric_id : UInt64?
        subject.fabric_id
      end

      # Extract node ID from subject DN
      def node_id : UInt64?
        subject.node_id
      end

      # Check if this is a NOC (has both fabric_id and node_id)
      def noc? : Bool
        !subject.fabric_id.nil? && !subject.node_id.nil?
      end

      # Check if this is an ICAC (has icac_id)
      def icac? : Bool
        !subject.icac_id.nil?
      end

      # Check if this is a root CA (has rcac_id)
      def root_ca? : Bool
        !subject.rcac_id.nil?
      end
    end
  end
end
