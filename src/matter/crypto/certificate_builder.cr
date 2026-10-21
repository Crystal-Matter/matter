require "./certificate"
require "./certificate_asn1"
require "./crypto"
require "./key"

module Matter
  module Crypto
    struct MatterCertificate
      # Issues operational certificates: a self-signed root and the node
      # certificates under it. This is what a commissioner needs to act as the
      # certificate authority of a fabric.
      module Builder
        extend self

        ANCHOR_ICAC_ORGANIZATIONAL_UNIT = MatterCertificate::ANCHOR_ICAC_ORGANIZATIONAL_UNIT

        # Matter certificates are ECDSA with SHA-256 over a P-256 key, and the
        # TLV records that as three enumerations of one
        SIGNATURE_ALGORITHM  = 1_u8
        PUBLIC_KEY_ALGORITHM = 1_u8
        ELLIPTIC_CURVE_ID    = 1_u8

        # A key identifier is the leading bytes of the SHA-256 of the public key
        KEY_IDENTIFIER_LENGTH       = 20
        MAX_CASE_AUTHENTICATED_TAGS =  3

        # Key usage bits, Matter specification table 6.5.11.2
        KEY_USAGE_DIGITAL_SIGNATURE = 1 << 0
        KEY_USAGE_KEY_CERT_SIGN     = 1 << 5
        KEY_USAGE_CRL_SIGN          = 1 << 6

        # Extended key usage purposes a node certificate carries, in the order
        # every other implementation writes them
        NODE_EXTENDED_KEY_USAGE = [2_u8, 1_u8]

        # A certificate is valid from an hour before it was issued, to allow for
        # clock skew between the commissioner and the node, and for ten years.
        VALIDITY_BACKDATE = 1.hour
        VALIDITY_PERIOD   = (10 * 365).days

        # Issue a self-signed root certificate for `key`.
        def root(key : Key, rcac_id : UInt64, serial : Bytes, crypto : CryptoBase = Crypto.instance) : Bytes
          identifier = key_identifier(key.public_key, crypto)
          name = TLV::List{TLV::Any.new(rcac_id, Asn1::Dn::RcacId.value)}

          sign(
            certificate(
              serial: serial,
              issuer: name,
              subject: name,
              public_key: key.public_key,
              extensions: TLV::List{
                basic_constraints(certificate_authority: true),
                key_usage(KEY_USAGE_KEY_CERT_SIGN | KEY_USAGE_CRL_SIGN),
                key_identifier_extension(Asn1::Extension::SubjectKeyIdentifier, identifier),
                key_identifier_extension(Asn1::Extension::AuthorityKeyIdentifier, identifier),
              }
            ),
            key,
            crypto
          )
        end

        # Issue a node operational certificate under the root held by `issuer_key`.
        def node(
          public_key : Bytes,
          fabric_id : UInt64,
          node_id : UInt64,
          issuer_key : Key,
          issuer_rcac_id : UInt64,
          serial : Bytes,
          crypto : CryptoBase = Crypto.instance,
          case_authenticated_tag : UInt32? = nil,
          issuer_icac_id : UInt64? = nil,
          case_authenticated_tags : Array(UInt32) = [] of UInt32,
          issuer_certificate : Bytes? = nil,
        ) : Bytes
          tags = case_authenticated_tags.dup
          tags.unshift(case_authenticated_tag) if case_authenticated_tag
          if tags.size > MAX_CASE_AUTHENTICATED_TAGS || tags.uniq.size != tags.size ||
             tags.any? { |tag| (tag & 0xffff_u32) == 0_u32 }
            raise Matter::CertificateError.new("Invalid CASE authenticated tags for NOC")
          end
          issuer = if certificate = issuer_certificate
                     identity = MatterCertificate.from_slice(certificate)
                     expected_id = issuer_icac_id || issuer_rcac_id
                     actual_id = issuer_icac_id ? identity.subject.icac_id : identity.subject.rcac_id
                     unless actual_id == expected_id && identity.ec_public_key == issuer_key.public_key
                       raise Matter::CertificateError.new("Node issuer certificate does not match signing key or ID")
                     end
                     TLV::Any.from_slice(certificate).as_structure[Asn1::Field::Subject.value].as_list.dup
                   elsif icac_id = issuer_icac_id
                     TLV::List{TLV::Any.new(icac_id, Asn1::Dn::IcacId.value),
                               TLV::Any.new(fabric_id, Asn1::Dn::FabricId.value)}
                   else
                     TLV::List{TLV::Any.new(issuer_rcac_id, Asn1::Dn::RcacId.value)}
                   end
          subject = TLV::List{
            TLV::Any.new(fabric_id, Asn1::Dn::FabricId.value),
            TLV::Any.new(node_id, Asn1::Dn::NodeId.value),
          }
          tags.each do |tag|
            subject << TLV::Any.new(tag, Asn1::Dn::CaseAuthenticatedTag.value)
          end
          sign(
            certificate(
              serial: serial,
              issuer: issuer,
              subject: subject,
              public_key: public_key,
              extensions: TLV::List{
                basic_constraints(certificate_authority: false),
                key_usage(KEY_USAGE_DIGITAL_SIGNATURE),
                extended_key_usage(NODE_EXTENDED_KEY_USAGE),
                key_identifier_extension(Asn1::Extension::SubjectKeyIdentifier, key_identifier(public_key, crypto)),
                key_identifier_extension(Asn1::Extension::AuthorityKeyIdentifier, key_identifier(issuer_key.public_key, crypto)),
              }
            ),
            issuer_key,
            crypto
          )
        end

        # Issue an intermediate CA under the Anchor root. A joining ecosystem
        # uses the same public key as its existing ICAC, retaining its private
        # key while receiving an ICAC trusted by the Anchor fabric.
        def intermediate(
          public_key : Bytes,
          fabric_id : UInt64,
          icac_id : UInt64,
          issuer_key : Key,
          issuer_rcac_id : UInt64,
          serial : Bytes,
          crypto : CryptoBase = Crypto.instance,
          anchor : Bool = false,
        ) : Bytes
          subject = TLV::List{
            TLV::Any.new(icac_id, Asn1::Dn::IcacId.value),
            TLV::Any.new(fabric_id, Asn1::Dn::FabricId.value),
          }
          if anchor
            subject << TLV::Any.new(ANCHOR_ICAC_ORGANIZATIONAL_UNIT, Asn1::Dn::OrgUnitName.value)
          end
          sign(
            certificate(
              serial: serial,
              issuer: TLV::List{TLV::Any.new(issuer_rcac_id, Asn1::Dn::RcacId.value)},
              subject: subject,
              public_key: public_key,
              extensions: TLV::List{
                basic_constraints(certificate_authority: true),
                key_usage(KEY_USAGE_KEY_CERT_SIGN | KEY_USAGE_CRL_SIGN),
                key_identifier_extension(Asn1::Extension::SubjectKeyIdentifier, key_identifier(public_key, crypto)),
                key_identifier_extension(Asn1::Extension::AuthorityKeyIdentifier, key_identifier(issuer_key.public_key, crypto)),
              }
            ),
            issuer_key,
            crypto
          )
        end

        # The identifier other certificates refer to this key by
        def key_identifier(public_key : Bytes, crypto : CryptoBase = Crypto.instance) : Bytes
          crypto.compute_sha256(public_key)[0, KEY_IDENTIFIER_LENGTH]
        end

        private def certificate(
          serial : Bytes,
          issuer : TLV::List,
          subject : TLV::List,
          public_key : Bytes,
          extensions : TLV::List,
        ) : TLV::Structure
          now = Time.utc
          fields = TLV::Structure.new
          fields[Asn1::Field::SerialNumber.value] = TLV::Any.new(serial, Asn1::Field::SerialNumber.value)
          fields[Asn1::Field::SignatureAlgorithm.value] = TLV::Any.new(SIGNATURE_ALGORITHM, Asn1::Field::SignatureAlgorithm.value)
          fields[Asn1::Field::Issuer.value] = TLV::Any.new(issuer, Asn1::Field::Issuer.value)
          fields[Asn1::Field::NotBefore.value] = TLV::Any.new(matter_seconds(now - VALIDITY_BACKDATE), Asn1::Field::NotBefore.value)
          fields[Asn1::Field::NotAfter.value] = TLV::Any.new(matter_seconds(now + VALIDITY_PERIOD), Asn1::Field::NotAfter.value)
          fields[Asn1::Field::Subject.value] = TLV::Any.new(subject, Asn1::Field::Subject.value)
          fields[Asn1::Field::PublicKeyAlgorithm.value] = TLV::Any.new(PUBLIC_KEY_ALGORITHM, Asn1::Field::PublicKeyAlgorithm.value)
          fields[Asn1::Field::EllipticCurveId.value] = TLV::Any.new(ELLIPTIC_CURVE_ID, Asn1::Field::EllipticCurveId.value)
          fields[Asn1::Field::PublicKey.value] = TLV::Any.new(public_key, Asn1::Field::PublicKey.value)
          fields[Asn1::Field::Extensions.value] = TLV::Any.new(extensions, Asn1::Field::Extensions.value)
          fields
        end

        # Sign the DER of the certificate so far and write the signature in
        private def sign(fields : TLV::Structure, key : Key, crypto : CryptoBase) : Bytes
          signature = crypto.sign_ecdsa(key, Asn1.to_unsigned_asn1(TLV::Any.new(fields, nil)))
          fields[Asn1::Field::Signature.value] = TLV::Any.new(signature, Asn1::Field::Signature.value)
          TLV::Any.new(fields, nil).to_slice
        end

        private def basic_constraints(certificate_authority : Bool) : TLV::Any
          constraints = TLV::Structure.new
          constraints[Asn1::BASIC_CONSTRAINT_IS_CA] = TLV::Any.new(certificate_authority, Asn1::BASIC_CONSTRAINT_IS_CA)
          TLV::Any.new(constraints, Asn1::Extension::BasicConstraints.value)
        end

        private def key_usage(flags : Int) : TLV::Any
          TLV::Any.new(flags.to_u16, Asn1::Extension::KeyUsage.value)
        end

        private def extended_key_usage(purposes : Array(UInt8)) : TLV::Any
          TLV::Any.new(
            TLV::List.new(purposes.size) { |index| TLV::Any.new(purposes[index], nil) },
            Asn1::Extension::ExtendedKeyUsage.value,
            as_array: true
          )
        end

        private def key_identifier_extension(extension : Asn1::Extension, identifier : Bytes) : TLV::Any
          TLV::Any.new(identifier, extension.value)
        end

        private def matter_seconds(time : Time) : UInt32
          (time.to_unix - Asn1::MATTER_EPOCH_OFFSET).to_u32
        end
      end
    end
  end
end
