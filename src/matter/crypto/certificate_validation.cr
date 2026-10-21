require "./certificate"
require "./certificate_asn1"
require "./crypto"
require "./key"

module Matter
  module Crypto
    struct MatterCertificate
      # Operational certificate chain validation.
      #
      # A CASE peer proving it holds the private key of the certificate it
      # presents says nothing about who issued that certificate. Without this,
      # any member of a fabric can mint a certificate naming any node id or
      # CASE authenticated tag and inherit the access control entries written
      # for it.
      module Validation
        extend self

        MATTER_EPOCH_UNIX_SECONDS = Asn1::MATTER_EPOCH_OFFSET

        # Extensions of a Matter certificate, tag 10
        private ISSUER_KEY_IDENTIFIER  = Asn1::Extension::AuthorityKeyIdentifier.value
        private SUBJECT_KEY_IDENTIFIER = Asn1::Extension::SubjectKeyIdentifier.value
        private BASIC_CONSTRAINTS      = Asn1::Extension::BasicConstraints.value
        private KEY_USAGE              = Asn1::Extension::KeyUsage.value
        private EXTENDED_KEY_USAGE     = Asn1::Extension::ExtendedKeyUsage.value

        KEY_USAGE_DIGITAL_SIGNATURE = 1_u16
        KEY_USAGE_KEY_CERT_SIGN     = 1_u16 << 5
        KEY_PURPOSE_SERVER_AUTH     = 1_u8

        # Verify `certificate` against the public key of whoever issued it.
        # Raises `Matter::AuthenticationError` when it does not hold.
        def verify_signature(certificate : Bytes, issuer_public_key : Bytes) : Nil
          parsed = parse(certificate)
          signature = signature_of(parsed)
          transcript = Asn1.to_unsigned_asn1(parsed)

          key = Key.new(KeyType::EC, CurveType::P256)
          key.public_bits = issuer_public_key

          Crypto.verify_ecdsa(key, transcript, signature)
        rescue ex : Matter::AuthenticationError
          raise ex
        rescue ex
          raise Matter::AuthenticationError.new("Certificate signature could not be checked: #{ex.message}", cause: ex)
        end

        # Verify that `noc` was issued by the holder of `root_public_key`,
        # through `icac` when the peer presented one. Raises
        # `Matter::AuthenticationError` on the first link that does not hold.
        def verify_chain(noc : Bytes, icac : Bytes?, root_public_key : Bytes,
                         root_certificate : Bytes? = nil) : Nil
          node = MatterCertificate.from_slice(noc)
          valid_noc_profile = node.subject.node_id && node.subject.fabric_id && !certificate_authority?(noc) &&
                              key_usage?(noc, KEY_USAGE_DIGITAL_SIGNATURE) &&
                              extended_key_usage?(noc, KEY_PURPOSE_SERVER_AUTH)
          unless valid_noc_profile
            raise Matter::AuthenticationError.new("Node certificate has an invalid NOC profile")
          end
          verify_validity(noc)
          if root = root_certificate
            unless MatterCertificate.public_key_from_tlv(root) == root_public_key
              raise Matter::AuthenticationError.new("Root certificate differs from trusted root key")
            end
          end
          if icac
            unless certificate_authority?(icac) && key_cert_sign?(icac)
              raise Matter::AuthenticationError.new("Intermediate certificate cannot sign certificates")
            end

            intermediate = MatterCertificate.from_slice(icac)
            unless intermediate.subject.icac_id && intermediate.subject.icac_id != 0_u64 &&
                   intermediate.subject.node_id.nil? && intermediate.subject.rcac_id.nil? &&
                   intermediate.subject.noc_cat.nil?
              raise Matter::AuthenticationError.new("Intermediate certificate has an invalid ICAC subject")
            end
            if intermediate.subject.fabric_id && node.subject.fabric_id != intermediate.subject.fabric_id
              raise Matter::AuthenticationError.new("Intermediate and node certificates name different fabrics")
            end
            verify_validity(icac)

            verify_issued_by(icac, root) if root
            verify_signature(icac, root_public_key)
            verify_issued_by(noc, icac)
            verify_signature(noc, MatterCertificate.public_key_from_tlv(icac))
          else
            verify_issued_by(noc, root) if root
            verify_signature(noc, root_public_key)
          end
        end

        # An RCAC installed as a trust anchor must have the root profile and
        # prove possession of its own public key before it enters the table.
        # The official SDK deliberately skips RCAC time validity at install;
        # NOC and ICAC dates are checked during chain use.
        def verify_root(certificate : Bytes) : Nil
          root = MatterCertificate.from_slice(certificate)
          unless root.subject.rcac_id && root.subject.rcac_id != 0_u64 &&
                 issuer_matches_subject?(certificate, certificate) && certificate_authority?(certificate) &&
                 key_cert_sign?(certificate) && valid_root_path_length?(certificate)
            raise Matter::AuthenticationError.new("Root certificate has an invalid RCAC profile")
          end
          verify_issued_by(certificate, certificate)
          verify_signature(certificate, root.ec_public_key)
        rescue ex : Matter::AuthenticationError
          raise ex
        rescue ex
          raise Matter::AuthenticationError.new("Root certificate could not be validated: #{ex.message}", cause: ex)
        end

        # Matter certificate times are seconds since 2000-01-01 UTC. Keep the
        # check on the common chain path so AddNOC, UpdateNOC and both CASE
        # roles reject credentials outside their signed validity interval.
        def verify_validity(certificate : Bytes, now : Time = Time.utc) : Nil
          parsed = MatterCertificate.from_slice(certificate)
          seconds = now.to_unix - MATTER_EPOCH_UNIX_SECONDS
          # Matter encodes an unbounded NotAfter as zero (X.509's special
          # 9999-12-31 value). The ordinary ordering rule does not apply to it.
          expires = parsed.not_after
          unless seconds >= parsed.not_before &&
                 (expires == 0_u32 || (seconds <= expires && parsed.not_before <= expires))
            raise Matter::AuthenticationError.new("Certificate is outside its validity interval")
          end
        end

        # The issuer a certificate names must be the subject of the certificate
        # that signed it, so a peer cannot present an unrelated pair.
        def verify_issued_by(certificate : Bytes, issuer : Bytes) : Nil
          authority = extension(certificate, ISSUER_KEY_IDENTIFIER)
          subject = extension(issuer, SUBJECT_KEY_IDENTIFIER)

          if authority.nil? || subject.nil?
            raise Matter::AuthenticationError.new("Certificate is missing a key identifier extension")
          end

          unless authority.as_bytes == subject.as_bytes
            raise Matter::AuthenticationError.new("Certificate was not issued by the certificate above it")
          end
          unless issuer_matches_subject?(certificate, issuer)
            raise Matter::AuthenticationError.new("Certificate issuer name differs from signing authority")
          end
        end

        # True when the certificate's basic constraints mark it as a CA
        def certificate_authority?(certificate : Bytes) : Bool
          constraints = extension(certificate, BASIC_CONSTRAINTS)
          return false if constraints.nil?

          is_ca = constraints.as_structure?.try(&.[Asn1::BASIC_CONSTRAINT_IS_CA]?)
          return false if is_ca.nil?

          is_ca.as_bool
        rescue ex
          Log.debug(exception: ex) { "Certificate has unreadable basic constraints" }
          false
        end

        private def key_cert_sign?(certificate : Bytes) : Bool
          key_usage?(certificate, KEY_USAGE_KEY_CERT_SIGN)
        end

        private def key_usage?(certificate : Bytes, usage : UInt16) : Bool
          flags = extension(certificate, KEY_USAGE).try(&.as_u16?)
          !!flags && (flags & usage) != 0_u16
        end

        private def extended_key_usage?(certificate : Bytes, purpose : UInt8) : Bool
          purposes = extension(certificate, EXTENDED_KEY_USAGE).try(&.as_list?)
          !!purposes && purposes.any? { |item| item.as_u8? == purpose }
        end

        private def valid_root_path_length?(certificate : Bytes) : Bool
          constraints = extension(certificate, BASIC_CONSTRAINTS)
          return false unless constraints
          path_length = constraints.as_structure?.try(&.[Asn1::BASIC_CONSTRAINT_PATH_LEN]?)
          path_length.nil? || path_length.as_u8 <= 1_u8
        end

        private def issuer_matches_subject?(certificate : Bytes, issuer : Bytes) : Bool
          issued_by = parse(certificate).as_structure[Asn1::Field::Issuer.value].as_list
          authority = parse(issuer).as_structure[Asn1::Field::Subject.value].as_list
          issued_by.map(&.to_slice) == authority.map(&.to_slice)
        end

        private def extension(certificate : Bytes, tag : UInt8) : TLV::Any?
          extensions = parse(certificate).as_structure?.try(&.[Asn1::Field::Extensions.value]?)
          return if extensions.nil?

          extensions.as_list?.try(&.find { |element| element.header.ids == tag })
        end

        private def signature_of(parsed : TLV::Any) : Bytes
          signature = parsed.as_structure?.try(&.[Asn1::Field::Signature.value]?)
          raise Matter::CertificateError.new("Certificate carries no signature") if signature.nil?

          signature.as_bytes
        end

        private def parse(certificate : Bytes) : TLV::Any
          TLV::Any.from_slice(certificate)
        end
      end
    end
  end
end
