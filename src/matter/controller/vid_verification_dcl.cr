require "http/client"
require "json"
require "base64"
require "./vid_verification"
require "./device_attestation_verifier"

lib LibCrypto
  fun x509_extension_get_critical = X509_EXTENSION_get_critical(extension : X509_EXTENSION) : Int32
end

module Matter
  module Controller
    module VidVerification
      # An approved DCL PKI record. A DCL source is trusted as a ledger query
      # source, but its certificate and VID metadata are still checked locally.
      struct DclCertificate
        enum Type
          OperationalPKI
          VIDSignerPKI
        end

        getter certificate : OpenSSL::X509::Certificate
        getter vendor_id : UInt16
        getter type : Type
        getter? root : Bool

        def initialize(der : Bytes, @vendor_id : UInt16, @type : Type, @root : Bool)
          @certificate = OpenSSL::X509::Certificate.from_der(der)
        end
      end

      abstract class DclSource
        abstract def roots_for(vendor_id : UInt16) : Array(DclCertificate)
        abstract def intermediates_for(vendor_id : UInt16) : Array(DclCertificate)
        abstract def signers_for(vendor_id : UInt16, skid : Bytes) : Array(DclCertificate)
      end

      # Reads only the DCL's active (non-revoked) NOC PKI indexes. The caller
      # chooses a trusted HTTPS DCL gateway; no test-net endpoint is implicit.
      class HttpDclSource < DclSource
        MAX_RESPONSE_SIZE = 1_048_576
        ROOT_PATH         = "/dcl/pki/noc-vid-root-certificates"
        ICA_PATH          = "/dcl/pki/noc-vid-ica-certificates"
        SIGNER_PATH       = "/dcl/pki/noc-vid-certificates"

        alias Fetch = Proc(String, String)

        def initialize(@base_url : String, @fetch : Fetch = ->(url : String) { HTTP::Client.get(url).body })
          unless @base_url.starts_with?("https://")
            raise Matter::ConfigurationError.new("DCL gateway must use HTTPS")
          end
          @base_url = @base_url.rstrip('/')
        end

        def roots_for(vendor_id : UInt16) : Array(DclCertificate)
          read("#{ROOT_PATH}/#{vendor_id}", "nocRootCertificates")
        end

        def intermediates_for(vendor_id : UInt16) : Array(DclCertificate)
          read("#{ICA_PATH}/#{vendor_id}", "nocIcaCertificates")
        end

        def signers_for(vendor_id : UInt16, skid : Bytes) : Array(DclCertificate)
          key = skid.hexstring.upcase.scan(/../).join(":")
          read("#{SIGNER_PATH}/#{vendor_id}/#{key}", "nocCertificatesByVidAndSkid")
        end

        private def read(path : String, wrapper : String) : Array(DclCertificate)
          body = @fetch.call("#{@base_url}#{path}")
          raise Matter::AuthenticationError.new("DCL response is too large") if body.bytesize > MAX_RESPONSE_SIZE
          data = JSON.parse(body).as_h[wrapper].as_h["certs"].as_a
          data.map do |item|
            record = item.as_h
            type = case record["certificateType"].raw
                   when "OperationalPKI", 1 then DclCertificate::Type::OperationalPKI
                   when "VIDSignerPKI", 2   then DclCertificate::Type::VIDSignerPKI
                   else                          raise Matter::AuthenticationError.new("Unknown DCL certificate type")
                   end
            vendor_id = record["vid"].raw.to_s.to_u16
            pem = record["pemCert"].as_s
            base64 = pem.lines.reject(&.starts_with?("-----")).join
            # Proto3 JSON omits a false `isRoot` for ICA and signer records.
            DclCertificate.new(Base64.decode(base64), vendor_id, type, record["isRoot"]?.try(&.as_bool) || false)
          end
        rescue ex : Matter::Error
          raise ex
        rescue ex
          raise Matter::AuthenticationError.new("Invalid DCL certificate response: #{ex.message}", cause: ex)
        end
      end

      # Verifies an Operational RCAC against a VID-scoped DCL root, or a VVS
      # against a VID Signer certificate chain rooted in a DCL VVSC root.
      class DclOperationalTrustAnchors < OperationalTrustAnchors
        Log                         = ::Log.for("matter.controller.vid_verification_dcl")
        MAX_SIGNER_CHAIN_DEPTH      =        3
        KEY_USAGE_DIGITAL_SIGNATURE = 0x80_u32
        KEY_USAGE_CERT_SIGN         = 0x04_u32
        KEY_USAGE_CRL_SIGN          = 0x02_u32
        KEY_ID_SIZE                 =       20

        def initialize(@source : DclSource, @crypto : Crypto::CryptoBase = Crypto::StandardCrypto.new)
        end

        def trusted_root?(vendor_id : UInt16, root_certificate : Bytes) : Bool
          Crypto::MatterCertificate::Validation.verify_root(root_certificate)
          public_key = Crypto::MatterCertificate.public_key_from_tlv(root_certificate)
          @source.roots_for(vendor_id).any? do |record|
            next false unless record.vendor_id == vendor_id && record.type.operational_pki? && record.root?
            cert = record.certificate
            valid_root?(cert, ca: true) && cert.public_key.as(OpenSSL::PKey::EC).public_key_bytes == public_key
          end
        rescue ex
          Log.debug(exception: ex) { "Operational root could not be authenticated against DCL" }
          false
        end

        def verify_statement?(vendor_id : UInt16, signer_skid : Bytes,
                              statement_tbs : Bytes, signature : Bytes,
                              vvsc : Bytes?) : Bool
          return false unless signer_skid.size == KEY_ID_SIZE && signature.size == 64
          roots = @source.roots_for(vendor_id).select { |record| signer_record?(record, vendor_id, root: true) }
          intermediates = @source.intermediates_for(vendor_id).select { |record| signer_record?(record, vendor_id, root: false) }
          signers = @source.signers_for(vendor_id, signer_skid)
          signers.any? do |record|
            next false unless signer_record?(record, vendor_id, root: false)
            cert = record.certificate
            next false unless key_id(cert) == signer_skid
            next false if vvsc && !matches_matter_vvsc?(vvsc, cert, signer_skid)
            next false unless signer_chain?(cert, intermediates, roots, 1)
            key = Crypto::Key.new(Crypto::KeyType::EC, Crypto::CurveType::P256)
            key.public_bits = cert.public_key.as(OpenSSL::PKey::EC).public_key_bytes
            @crypto.verify_ecdsa(key, statement_tbs, signature)
            true
          end
        rescue ex
          Log.debug(exception: ex) { "VID Verification Statement has no trusted DCL signer" }
          false
        end

        private def signer_chain?(child : OpenSSL::X509::Certificate,
                                  intermediates : Array(DclCertificate), roots : Array(DclCertificate),
                                  depth : Int32) : Bool
          return false if depth >= MAX_SIGNER_CHAIN_DEPTH
          (intermediates + roots).any? do |parent_record|
            parent = parent_record.certificate
            next false unless child.issuer.to_a == parent.subject.to_a &&
                              key_id(child, authority: true) == key_id(parent) &&
                              child.verify(parent.public_key)
            if parent_record.root?
              valid_root?(parent, ca: false)
            else
              signer_chain?(parent, intermediates.reject(&.==(parent_record)), roots, depth + 1)
            end
          end
        end

        private def signer_record?(record : DclCertificate, vendor_id : UInt16, root : Bool) : Bool
          record.vendor_id == vendor_id && record.type.vid_signer_pki? && record.root? == root &&
            valid_signer?(record.certificate)
        end

        # NOCStruct carries the VVSC as a Matter TLV certificate, while the
        # DCL publishes its X.509 form. The approved signing key and SKID must
        # describe the same signer in both encodings.
        private def matches_matter_vvsc?(vvsc : Bytes, cert : OpenSSL::X509::Certificate,
                                         signer_skid : Bytes) : Bool
          matter_cert = Crypto::MatterCertificate.from_slice(vvsc)
          extensions = TLV::Any.from_slice(vvsc).as_structure[Crypto::MatterCertificate::Asn1::Field::Extensions.value].as_list
          skid = extensions.find { |item| item.header.ids == Crypto::MatterCertificate::Asn1::Extension::SubjectKeyIdentifier.value }
          matter_cert.ec_public_key == cert.public_key.as(OpenSSL::PKey::EC).public_key_bytes &&
            skid.try(&.as_bytes) == signer_skid
        end

        private def valid_root?(cert : OpenSSL::X509::Certificate, ca : Bool) : Bool
          valid_time?(cert) && cert.subject.to_a == cert.issuer.to_a && cert.verify(cert.public_key) &&
            key_id(cert) == key_id(cert, authority: true) && key_id(cert).size == KEY_ID_SIZE &&
            (ca ? valid_ca?(cert) : valid_signer?(cert))
        end

        private def valid_ca?(cert : OpenSSL::X509::Certificate) : Bool
          constraint = cert.extensions.find { |ext| ext.oid == "basicConstraints" }
          usage_extension = cert.extensions.find { |ext| ext.oid == "keyUsage" }
          usage = LibCrypto.x509_get_key_usage(cert)
          !!constraint && critical?(constraint) && constraint.value.includes?("CA:TRUE") &&
            !!usage_extension && critical?(usage_extension) && LibCrypto.x509_check_ca(cert) > 0 &&
            (usage & (KEY_USAGE_CERT_SIGN | KEY_USAGE_CRL_SIGN)) == (KEY_USAGE_CERT_SIGN | KEY_USAGE_CRL_SIGN) &&
            (usage & ~(KEY_USAGE_DIGITAL_SIGNATURE | KEY_USAGE_CERT_SIGN | KEY_USAGE_CRL_SIGN)) == 0
        end

        private def valid_signer?(cert : OpenSSL::X509::Certificate) : Bool
          constraint = cert.extensions.find { |ext| ext.oid == "basicConstraints" }
          usage_extension = cert.extensions.find { |ext| ext.oid == "keyUsage" }
          usage = LibCrypto.x509_get_key_usage(cert)
          !!constraint && critical?(constraint) && constraint.value.includes?("CA:FALSE") &&
            !!usage_extension && critical?(usage_extension) &&
            LibCrypto.x509_check_ca(cert) == 0 && usage == KEY_USAGE_DIGITAL_SIGNATURE &&
            valid_time?(cert) && key_id(cert).size == KEY_ID_SIZE &&
            key_id(cert, authority: true).size == KEY_ID_SIZE
        end

        private def critical?(extension : OpenSSL::X509::Extension) : Bool
          LibCrypto.x509_extension_get_critical(extension) == 1
        end

        private def valid_time?(cert : OpenSSL::X509::Certificate) : Bool
          now = Time.utc
          cert.not_before <= now && now <= cert.not_after
        end

        private def key_id(cert : OpenSSL::X509::Certificate, authority : Bool = false) : Bytes
          pointer = authority ? LibCrypto.x509_get0_authority_key_id(cert) : LibCrypto.x509_get0_subject_key_id(cert)
          return Bytes.empty if pointer.null?
          length = LibCrypto.asn1_string_length(pointer)
          return Bytes.empty if length != KEY_ID_SIZE
          Slice.new(LibCrypto.asn1_string_get0_data(pointer).as(UInt8*), length).dup
        end
      end
    end
  end
end
