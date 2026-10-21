require "./certificate"
require "../codec/der_codec"

module Matter
  module Crypto
    # ASN.1 DER rendering of a Matter operational certificate.
    #
    # A Matter certificate travels as TLV, but the issuer signs the ASN.1 DER
    # form of it with the signature field left out. Verifying one therefore
    # means rebuilding that DER byte for byte; anything else is rejected by the
    # signature check, so the conversion is exercised against the certificate
    # vectors of other implementations in `spec/crypto/certificate_asn1_spec.cr`.
    #
    # See the Matter specification 6.5 "Operational Certificate Encoding" and
    # appendix E for the Matter object identifiers.
    struct MatterCertificate
      module Asn1
        extend self

        alias Der = Codec::DERCodec::Base

        # X.509 version 3, zero-indexed on the wire
        X509_VERSION_3 = 2_u8

        OID_ECDSA_WITH_SHA256 = "1.2.840.10045.4.3.2"
        OID_EC_PUBLIC_KEY     = "1.2.840.10045.2.1"
        OID_PRIME256V1        = "1.2.840.10045.3.1.7"

        # Seconds between the Unix epoch and the Matter epoch (2000-01-01)
        MATTER_EPOCH_OFFSET = 10957_i64 * 24 * 60 * 60
        # `notAfter` of zero means "no well defined expiry"
        NO_WELL_DEFINED_EXPIRY = Time.utc(9999, 12, 31, 23, 59, 59)

        # Top-level certificate fields, Matter specification table 6.5.2
        enum Field : UInt8
          SerialNumber       =  1
          SignatureAlgorithm =  2
          Issuer             =  3
          NotBefore          =  4
          NotAfter           =  5
          Subject            =  6
          PublicKeyAlgorithm =  7
          EllipticCurveId    =  8
          PublicKey          =  9
          Extensions         = 10
          Signature          = 11
        end

        # Distinguished name attributes. 1 to 16 are the X.520 attributes, 17 to
        # 23 the Matter ones, and 129 upwards repeat the X.520 set for values
        # that must be written as a PrintableString rather than a UTF8String.
        enum Dn : UInt8
          CommonName           =   1
          SurName              =   2
          SerialNum            =   3
          CountryName          =   4
          LocalityName         =   5
          StateOrProvinceName  =   6
          OrgName              =   7
          OrgUnitName          =   8
          Title                =   9
          Name                 =  10
          GivenName            =  11
          Initials             =  12
          GenQualifier         =  13
          DnQualifier          =  14
          Pseudonym            =  15
          DomainComponent      =  16
          NodeId               =  17
          FirmwareSigningId    =  18
          IcacId               =  19
          RcacId               =  20
          FabricId             =  21
          CaseAuthenticatedTag =  22
          VvsId                =  23
          CommonNamePs         = 129
          SurNamePs            = 130
          SerialNumPs          = 131
          CountryNamePs        = 132
          LocalityNamePs       = 133
          StateOrProvincePs    = 134
          OrgNamePs            = 135
          OrgUnitNamePs        = 136
          TitlePs              = 137
          NamePs               = 138
          GivenNamePs          = 139
          InitialsPs           = 140
          GenQualifierPs       = 141
          DnQualifierPs        = 142
          PseudonymPs          = 143
        end

        # The X.520 arc (2.5.4.n) each string attribute encodes as
        X520_ARCS = {
          Dn::CommonName => 3, Dn::SurName => 4, Dn::SerialNum => 5,
          Dn::CountryName => 6, Dn::LocalityName => 7, Dn::StateOrProvinceName => 8,
          Dn::OrgName => 10, Dn::OrgUnitName => 11, Dn::Title => 12,
          Dn::Name => 41, Dn::GivenName => 42, Dn::Initials => 43,
          Dn::GenQualifier => 44, Dn::DnQualifier => 46, Dn::Pseudonym => 65,
        }

        # The Matter arc (1.3.6.1.4.1.37244.1.n) each Matter attribute encodes as
        MATTER_ARCS = {
          Dn::NodeId => 1, Dn::FirmwareSigningId => 2, Dn::IcacId => 3,
          Dn::RcacId => 4, Dn::FabricId => 5, Dn::CaseAuthenticatedTag => 6,
          Dn::VvsId => 7,
        }

        OID_X520_PREFIX   = "2.5.4."
        OID_MATTER_PREFIX = "1.3.6.1.4.1.37244.1."
        # 0.9.2342.19200300.100.1.25
        OID_DOMAIN_COMPONENT = "0.9.2342.19200300.100.1.25"

        # A Matter identifier prints as a fixed-width upper-case hex string: 16
        # characters for the 64-bit ones, 8 for a CASE authenticated tag.
        ID_HEX_DIGITS  = 16
        CAT_HEX_DIGITS =  8

        enum Extension : UInt8
          BasicConstraints       = 1
          KeyUsage               = 2
          ExtendedKeyUsage       = 3
          SubjectKeyIdentifier   = 4
          AuthorityKeyIdentifier = 5
          FutureExtension        = 6
        end

        OID_BASIC_CONSTRAINTS        = "2.5.29.19"
        OID_KEY_USAGE                = "2.5.29.15"
        OID_EXTENDED_KEY_USAGE       = "2.5.29.37"
        OID_SUBJECT_KEY_IDENTIFIER   = "2.5.29.14"
        OID_AUTHORITY_KEY_IDENTIFIER = "2.5.29.35"

        # Basic constraints fields
        BASIC_CONSTRAINT_IS_CA    = 1_u8
        BASIC_CONSTRAINT_PATH_LEN = 2_u8

        # Extended key usage purposes, Matter specification table 6.5.11.3
        EXTENDED_KEY_USAGE_OIDS = {
          1 => "1.3.6.1.5.5.7.3.1", # server authentication
          2 => "1.3.6.1.5.5.7.3.2", # client authentication
          3 => "1.3.6.1.5.5.7.3.3", # code signing
          4 => "1.3.6.1.5.5.7.3.4", # email protection
          5 => "1.3.6.1.5.5.7.3.8", # time stamping
          6 => "1.3.6.1.5.5.7.3.9", # OCSP signing
        }

        # The authority key identifier is carried under an implicit `[0]`
        AUTHORITY_KEY_ID_TAG = 0
        # Extensions sit under an explicit `[3]` in a TBSCertificate
        EXTENSIONS_TAG = 3
        # The version sits under an explicit `[0]`
        VERSION_TAG = 0

        # The DER a certificate's issuer signed: the certificate without its
        # signature field.
        def to_unsigned_asn1(certificate : TLV::Any) : Bytes
          fields = structure(certificate, "certificate")

          Der.encode_sequence([
            Der.encode_explicit(VERSION_TAG, Der.encode_integer(Bytes[X509_VERSION_3])),
            Der.encode_integer(bytes_field(fields, Field::SerialNumber)),
            Der.encode_sequence([Der.encode_oid(OID_ECDSA_WITH_SHA256)]),
            distinguished_name(field(fields, Field::Issuer)),
            Der.encode_sequence([
              Der.encode_time(matter_time(uint_field(fields, Field::NotBefore))),
              Der.encode_time(matter_time(uint_field(fields, Field::NotAfter))),
            ]),
            distinguished_name(field(fields, Field::Subject)),
            Der.encode_sequence([
              Der.encode_sequence([Der.encode_oid(OID_EC_PUBLIC_KEY), Der.encode_oid(OID_PRIME256V1)]),
              Der.encode_bit_string(bytes_field(fields, Field::PublicKey)),
            ]),
            Der.encode_explicit(EXTENSIONS_TAG, extensions(field(fields, Field::Extensions))),
          ])
        end

        # Preserve the signed RDN order when binding Matter TLV names to the
        # corresponding X.509 certificate names.
        def distinguished_name_der(name : TLV::Any) : Bytes
          distinguished_name(name)
        end

        # A distinguished name is a SEQUENCE of single-attribute SETs, in the
        # order the issuer wrote them: the DN is a TLV list, and re-ordering it
        # changes the bytes that were signed.
        private def distinguished_name(name : TLV::Any) : Bytes
          attributes = [] of Bytes
          case_tags_written = false

          list(name, "distinguished name").each do |element|
            attribute = Dn.from_value?(tag_of(element, "distinguished name"))
            next if attribute.nil?

            if attribute.case_authenticated_tag?
              # Every CAT in the list is written where the first one appeared
              next if case_tags_written
              case_tags_written = true
              list(name, "distinguished name").each do |cat|
                next unless tag_of(cat, "distinguished name") == Dn::CaseAuthenticatedTag.value
                attributes << dn_attribute(OID_MATTER_PREFIX + MATTER_ARCS[attribute].to_s,
                  Der.encode_utf8_string(hex_id(cat, CAT_HEX_DIGITS)))
              end
              next
            end

            attributes << dn_attribute_for(attribute, element)
          end

          Der.encode_sequence(attributes)
        end

        private def dn_attribute_for(attribute : Dn, element : TLV::Any) : Bytes
          if arc = MATTER_ARCS[attribute]?
            return dn_attribute(OID_MATTER_PREFIX + arc.to_s,
              Der.encode_utf8_string(hex_id(element, ID_HEX_DIGITS)))
          end

          if attribute.domain_component?
            return dn_attribute(OID_DOMAIN_COMPONENT, Der.encode_ia5_string(element.as_s))
          end

          printable = attribute.value >= Dn::CommonNamePs.value
          plain = printable ? Dn.new(attribute.value - Dn::CommonNamePs.value + Dn::CommonName.value) : attribute
          arc = X520_ARCS[plain]?
          raise Matter::CertificateError.new("Unsupported DN attribute #{attribute}") if arc.nil?

          value = printable ? Der.encode_printable_string(element.as_s) : Der.encode_utf8_string(element.as_s)
          dn_attribute(OID_X520_PREFIX + arc.to_s, value)
        end

        private def dn_attribute(oid : String, value : Bytes) : Bytes
          Der.encode_set([Der.encode_sequence([Der.encode_oid(oid), value])])
        end

        private def extensions(extensions : TLV::Any) : Bytes
          encoded = [] of Bytes

          list(extensions, "extensions").each do |element|
            extension = Extension.from_value?(tag_of(element, "extensions"))
            next if extension.nil?

            case extension
            in .basic_constraints?
              encoded << extension_der(OID_BASIC_CONSTRAINTS, basic_constraints(element), critical: true)
            in .key_usage?
              encoded << extension_der(OID_KEY_USAGE, Der.encode_bit_flags(to_u64(element)), critical: true)
            in .extended_key_usage?
              encoded << extension_der(OID_EXTENDED_KEY_USAGE, extended_key_usage(element), critical: true)
            in .subject_key_identifier?
              encoded << extension_der(OID_SUBJECT_KEY_IDENTIFIER, Der.encode_octet_string(element.as_bytes))
            in .authority_key_identifier?
              encoded << extension_der(OID_AUTHORITY_KEY_IDENTIFIER,
                Der.encode_sequence([Der.encode_implicit(AUTHORITY_KEY_ID_TAG, element.as_bytes)]))
            in .future_extension?
              # Already DER, carried through untouched
              encoded << element.as_bytes
            end
          end

          Der.encode_sequence(encoded)
        end

        private def extension_der(oid : String, value : Bytes, critical : Bool = false) : Bytes
          members = [Der.encode_oid(oid)]
          members << Der.encode_boolean(true) if critical
          members << Der.encode_octet_string(value)
          Der.encode_sequence(members)
        end

        private def basic_constraints(element : TLV::Any) : Bytes
          fields = structure(element, "basic constraints")
          members = [] of Bytes

          # `false` is the default and RFC 5280 appendix B says to leave a
          # default out of the encoding
          if (is_ca = fields[BASIC_CONSTRAINT_IS_CA]?) && is_ca.as_bool
            members << Der.encode_boolean(true)
          end
          if path_len = fields[BASIC_CONSTRAINT_PATH_LEN]?
            members << Der.encode_integer(Bytes[to_u64(path_len).to_u8])
          end

          Der.encode_sequence(members)
        end

        private def extended_key_usage(element : TLV::Any) : Bytes
          purposes = list(element, "extended key usage").map do |purpose|
            oid = EXTENDED_KEY_USAGE_OIDS[to_u64(purpose).to_i]?
            raise Matter::CertificateError.new("Unsupported extended key usage #{to_u64(purpose)}") if oid.nil?
            Der.encode_oid(oid)
          end

          Der.encode_sequence(purposes)
        end

        # Matter stores time as seconds since 2000-01-01; zero means no expiry
        private def matter_time(seconds : UInt64) : Time
          return NO_WELL_DEFINED_EXPIRY if seconds.zero?
          Time.unix(seconds.to_i64 + MATTER_EPOCH_OFFSET)
        end

        private def hex_id(element : TLV::Any, digits : Int) : String
          to_u64(element).to_s(16).upcase.rjust(digits, '0')
        end

        private def tag_of(element : TLV::Any, context : String) : UInt8
          tag = element.header.ids
          raise Matter::CertificateError.new("Untagged element in #{context}") unless tag.is_a?(UInt8)
          tag
        end

        private def structure(any : TLV::Any, context : String) : TLV::Structure
          any.as_structure? || raise Matter::CertificateError.new("#{context} is not a TLV structure")
        end

        private def list(any : TLV::Any, context : String) : TLV::List
          any.as_list? || raise Matter::CertificateError.new("#{context} is not a TLV list")
        end

        private def field(fields : TLV::Structure, name : Field) : TLV::Any
          fields[name.value]? || raise Matter::CertificateError.new("Certificate has no #{name} (tag #{name.value})")
        end

        private def bytes_field(fields : TLV::Structure, name : Field) : Bytes
          field(fields, name).as_bytes
        end

        private def uint_field(fields : TLV::Structure, name : Field) : UInt64
          to_u64(field(fields, name))
        end

        private def to_u64(any : TLV::Any) : UInt64
          case value = any.value
          when UInt64 then value
          when UInt32 then value.to_u64
          when UInt16 then value.to_u64
          when UInt8  then value.to_u64
          when Int    then value.to_u64
          else
            raise Matter::CertificateError.new("Expected an unsigned integer, got #{value.class}")
          end
        end
      end
    end
  end
end
