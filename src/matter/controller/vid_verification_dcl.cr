require "http/client"
require "json"
require "base64"
require "./vid_verification"
require "./device_attestation_verifier"

lib LibCrypto
  fun x509_extension_get_critical = X509_EXTENSION_get_critical(extension : X509_EXTENSION) : Int32
  fun x509_get_pathlen = X509_get_pathlen(cert : X509) : LibC::Long
  fun matter_i2d_x509_name = i2d_X509_NAME(name : X509_NAME, out : UInt8**) : Int32
end

module Matter
  module Controller
    module VidVerification
      # An approved DCL PKI record. A DCL source is trusted as a ledger query
      # source, but its certificate and VID metadata are still checked locally.
      struct DclCertificate
        enum Type
          OperationalPKI = 1
          VIDSignerPKI   = 2
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
        FETCH_TIMEOUT     = 5.seconds
        ROOT_PATH         = "/dcl/pki/noc-vid-root-certificates"
        ICA_PATH          = "/dcl/pki/noc-vid-ica-certificates"
        SIGNER_PATH       = "/dcl/pki/noc-vid-certificates"

        record Response, status : Int32, age : String?, body : String
        alias Fetch = Proc(String, Response)
        alias LegacyFetch = Proc(String, String)

        def initialize(@base_url : String, @fetch : Fetch = ->(url : String) { HttpDclSource.fetch_fresh_https(url) })
          uri = begin
            URI.parse(@base_url)
          rescue ex : URI::Error
            raise Matter::ConfigurationError.new("Invalid DCL gateway URL", cause: ex)
          end
          host = uri.host || ""
          if uri.scheme != "https" || host.empty? || uri.user || uri.password ||
             uri.query || uri.fragment || !(uri.path.empty? || uri.path == "/") ||
             !(uri.port.nil? || uri.port == 443)
            raise Matter::ConfigurationError.new("DCL gateway must be an HTTPS origin")
          end
          @base_url = uri.to_s.rstrip('/')
        end

        # Existing injected sources return only a body and own their transport
        # freshness policy. The built-in HTTPS transport inspects HTTP Age.
        def initialize(base_url : String, fetch : LegacyFetch)
          initialize(base_url, ->(url : String) { Response.new(200, nil, fetch.call(url)) })
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
          response = @fetch.call("#{@base_url}#{path}")
          raise Matter::AuthenticationError.new("DCL HTTP response was not 200") unless response.status == 200
          if age = response.age
            raise Matter::AuthenticationError.new("DCL HTTP response came from a cache") unless age == "0"
          end
          body = response.body
          raise Matter::AuthenticationError.new("DCL response is too large") if body.bytesize > MAX_RESPONSE_SIZE
          data = JSON.parse(body).as_h[wrapper].as_h["certs"].as_a
          data.map do |item|
            record = item.as_h
            type = case record["certificateType"].raw
                   when "OperationalPKI", DclCertificate::Type::OperationalPKI.value then DclCertificate::Type::OperationalPKI
                   when "VIDSignerPKI", DclCertificate::Type::VIDSignerPKI.value     then DclCertificate::Type::VIDSignerPKI
                   else                                                                   raise Matter::AuthenticationError.new("Unknown DCL certificate type")
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

        def self.fetch_fresh_https(url : String) : Response
          uri = URI.parse(url)
          raise Matter::AuthenticationError.new("DCL URL must use HTTPS") unless uri.scheme == "https"
          HTTP::Client.new(uri) do |client|
            client.connect_timeout = FETCH_TIMEOUT
            client.read_timeout = FETCH_TIMEOUT
            headers = HTTP::Headers{"Cache-Control" => "no-cache, no-store, max-age=0", "Pragma" => "no-cache"}
            client.exec("GET", uri.request_target, headers) do |reply|
              output = IO::Memory.new
              buffer = Bytes.new(8192)
              while (read = reply.body_io.read(buffer)) > 0
                raise Matter::AuthenticationError.new("DCL response is too large") if output.size + read > MAX_RESPONSE_SIZE
                output.write(buffer[0, read])
              end
              Response.new(reply.status_code, reply.headers["Age"]?, String.new(output.to_slice))
            end
          end
        end
      end

      # Verifies an Operational RCAC against a VID-scoped DCL root, or a VVS
      # through a supplied VVSC or DCL VID Signer leaf issued by a DCL
      # OperationalPKI Root/ICA.
      class DclOperationalTrustAnchors < OperationalTrustAnchors
        Log                                = ::Log.for("matter.controller.vid_verification_dcl")
        MAX_SIGNER_CHAIN_DEPTH             =          3
        KEY_USAGE_DIGITAL_SIGNATURE        =   0x80_u32
        MATTER_KEY_USAGE_DIGITAL_SIGNATURE = 0x0001_u16
        MATTER_CERTIFICATE_ALGORITHM       =       1_u8
        MAX_VVSC_SIZE                      =        400
        KEY_USAGE_CERT_SIGN                =   0x04_u32
        KEY_USAGE_CRL_SIGN                 =   0x02_u32
        KEY_ID_SIZE                        =         20
        ROOT_ID_OID                        = "1.3.6.1.4.1.37244.1.4"
        ICA_ID_OID                         = "1.3.6.1.4.1.37244.1.3"
        VID_SIGNER_ID_OID                  = "1.3.6.1.4.1.37244.1.7"
        MATTER_DN_OID_PREFIX               = "1.3.6.1.4.1.37244.1."

        def initialize(@source : DclSource, @crypto : Crypto::CryptoBase = Crypto::StandardCrypto.new)
        end

        def trusted_root?(vendor_id : UInt16, root_certificate : Bytes) : Bool
          Crypto::MatterCertificate::Validation.verify_root(root_certificate)
          matter_root = Crypto::MatterCertificate.from_slice(root_certificate)
          public_key = matter_root.ec_public_key
          root_id = matter_root.subject.rcac_id
          return false unless root_id
          root_skid = matter_key_id(root_certificate)
          return false unless root_skid && root_skid.size == KEY_ID_SIZE
          @source.roots_for(vendor_id).any? do |record|
            next false unless record.vendor_id == vendor_id && record.type.operational_pki? && record.root?
            cert = record.certificate
            valid_root?(cert) && matter_subject?(cert, ROOT_ID_OID, root_id) &&
              valid_certificate_profile?(cert) && key_id(cert) == root_skid &&
              cert.public_key.as(OpenSSL::PKey::EC).public_key_bytes == public_key
          end
        rescue ex
          Log.debug(exception: ex) { "Operational root could not be authenticated against DCL" }
          false
        end

        def verify_statement?(vendor_id : UInt16, signer_skid : Bytes,
                              statement_tbs : Bytes, signature : Bytes,
                              vvsc : Bytes?) : Bool
          return false unless signer_skid.size == KEY_ID_SIZE && signature.size == 64
          roots = @source.roots_for(vendor_id).select { |record| ca_record?(record, vendor_id, root: true) }
          intermediates = @source.intermediates_for(vendor_id).select { |record| ca_record?(record, vendor_id, root: false) }
          if vvsc
            return false unless valid_matter_vvsc?(vvsc, signer_skid, intermediates, roots)
            key = Crypto::Key.new(Crypto::KeyType::EC, Crypto::CurveType::P256)
            key.public_bits = Crypto::MatterCertificate.public_key_from_tlv(vvsc)
            @crypto.verify_ecdsa(key, statement_tbs, signature)
            return true
          end
          signers = @source.signers_for(vendor_id, signer_skid)
          signers.any? do |record|
            next false unless signer_record?(record, vendor_id)
            cert = record.certificate
            next false unless key_id(cert) == signer_skid
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
              valid_root?(parent) && matter_subject?(parent, ROOT_ID_OID) &&
                valid_path_length?(parent, depth - 1)
            else
              signer_chain?(parent, intermediates.reject(&.==(parent_record)), roots, depth + 1)
            end
          end
        end

        private def ca_record?(record : DclCertificate, vendor_id : UInt16, root : Bool) : Bool
          record.vendor_id == vendor_id && record.type.operational_pki? && record.root? == root &&
            matter_subject?(record.certificate, root ? ROOT_ID_OID : ICA_ID_OID) &&
            valid_certificate_profile?(record.certificate) && valid_ca?(record.certificate) &&
            valid_time?(record.certificate)
        end

        private def signer_record?(record : DclCertificate, vendor_id : UInt16) : Bool
          record.vendor_id == vendor_id && record.type.vid_signer_pki? && !record.root? &&
            matter_subject?(record.certificate, VID_SIGNER_ID_OID) &&
            valid_certificate_profile?(record.certificate) && valid_signer?(record.certificate)
        end

        private def matter_subject?(cert : OpenSSL::X509::Certificate, required_oid : String,
                                    required_id : UInt64? = nil) : Bool
          matter_entries = cert.subject.to_a.select do |entry|
            entry[0].split('\0').first.starts_with?(MATTER_DN_OID_PREFIX)
          end
          return false unless matter_entries.size == 1
          oid, value = matter_entries.first
          oid.split('\0').first == required_oid && value.matches?(/\A[0-9A-Fa-f]{16}\z/) &&
            (required_id.nil? || value.to_u64(16) == required_id)
        end

        private def valid_certificate_profile?(cert : OpenSSL::X509::Certificate) : Bool
          return false unless cert.version == 2 &&
                              LibCrypto.x509_get_signature_nid(cert) == LibCrypto.obj_txt2nid("ecdsa-with-SHA256")
          key = cert.public_key
          ec = LibCrypto.evp_pkey_get0_ec_key(key)
          return false if ec.null?
          group = LibCrypto.ec_key_get0_group(ec)
          return false if group.null? || LibCrypto.ec_group_get_curve_name(group) != LibCrypto::NID_X9_62_prime256v1
          cert.extensions.all? do |ext|
            !critical?(ext) || ext.oid.in?("basicConstraints", "keyUsage", "subjectKeyIdentifier", "authorityKeyIdentifier")
          end
        end

        # A root reached through an ICA has one subordinate CA; a signer
        # issued directly by the root has none. An absent pathLen is unbounded.
        private def valid_path_length?(cert : OpenSSL::X509::Certificate, subordinate_cas : Int32) : Bool
          path_length = LibCrypto.x509_get_pathlen(cert)
          path_length == -1 || path_length >= subordinate_cas
        end

        # NOCStruct carries the VVSC as a Matter TLV certificate. The DCL
        # supplies its issuer path; a separate DCL VID Signer leaf is not
        # required when the VVSC is present.
        private def valid_matter_vvsc?(vvsc : Bytes, signer_skid : Bytes,
                                       intermediates : Array(DclCertificate),
                                       roots : Array(DclCertificate)) : Bool
          return false if vvsc.size > MAX_VVSC_SIZE
          matter_cert = Crypto::MatterCertificate.from_slice(vvsc)
          subject = matter_cert.subject
          vvs_id = subject.vvs_id
          return false unless vvs_id && subject.node_id.nil? && subject.fabric_id.nil? &&
                              subject.noc_cat.nil? && subject.icac_id.nil? && subject.rcac_id.nil? &&
                              subject.firmware_signing_id.nil?
          certificate_fields = TLV::Any.from_slice(vvsc).as_structure
          matter_subject = certificate_fields[Crypto::MatterCertificate::Asn1::Field::Subject.value]
          subject_fields = matter_subject.as_list
          return false unless valid_matter_name?(matter_subject) &&
                              subject_fields.count { |item| item.header.ids == Crypto::MatterCertificate::Asn1::Dn::VvsId.value } == 1
          return false unless matter_key_id(vvsc) == signer_skid &&
                              @crypto.compute_sha1(matter_cert.ec_public_key) == signer_skid
          valid_profile = matter_cert.signature_algorithm == MATTER_CERTIFICATE_ALGORITHM &&
                          matter_cert.public_key_algorithm == MATTER_CERTIFICATE_ALGORITHM &&
                          matter_cert.elliptic_curve_id == MATTER_CERTIFICATE_ALGORITHM &&
                          !Crypto::MatterCertificate::Validation.certificate_authority?(vvsc)
          return false unless valid_profile
          extensions = TLV::Any.from_slice(vvsc).as_structure[Crypto::MatterCertificate::Asn1::Field::Extensions.value].as_list
          tags = extensions.map(&.header.ids)
          return false unless tags.uniq.size == tags.size &&
                              tags.all?(&.in?(1_u8, 2_u8, 3_u8, 4_u8, 5_u8)) &&
                              tags.includes?(Crypto::MatterCertificate::Asn1::Extension::BasicConstraints.value) &&
                              tags.includes?(Crypto::MatterCertificate::Asn1::Extension::KeyUsage.value) &&
                              tags.includes?(Crypto::MatterCertificate::Asn1::Extension::SubjectKeyIdentifier.value) &&
                              tags.includes?(Crypto::MatterCertificate::Asn1::Extension::AuthorityKeyIdentifier.value)
          usage = extensions.find! { |item| item.header.ids == Crypto::MatterCertificate::Asn1::Extension::KeyUsage.value }
          return false unless usage.as_u16 == MATTER_KEY_USAGE_DIGITAL_SIGNATURE
          constraints = extensions.find! { |item| item.header.ids == Crypto::MatterCertificate::Asn1::Extension::BasicConstraints.value }
          return false unless constraints.as_structure[Crypto::MatterCertificate::Asn1::BASIC_CONSTRAINT_IS_CA].as_bool == false
          Crypto::MatterCertificate::Validation.verify_validity(vvsc)
          issuer = matter_cert.issuer
          return false unless issuer.vvs_id.nil? && issuer.node_id.nil? && issuer.noc_cat.nil? &&
                              issuer.firmware_signing_id.nil?
          matter_issuer = certificate_fields[Crypto::MatterCertificate::Asn1::Field::Issuer.value]
          return false unless valid_matter_name?(matter_issuer)

          (intermediates + roots).any? do |parent_record|
            parent = parent_record.certificate
            next false unless Crypto::MatterCertificate::Asn1.distinguished_name_der(matter_issuer) == name_der(parent.subject) &&
                              matter_key_id(vvsc, authority: true) == key_id(parent)
            next false unless parent_record.root? ? (!issuer.rcac_id.nil? && issuer.icac_id.nil? &&
                              matter_subject?(parent, ROOT_ID_OID, issuer.rcac_id)) : (!issuer.icac_id.nil? && issuer.rcac_id.nil? &&
                              matter_subject?(parent, ICA_ID_OID, issuer.icac_id))
            next false unless parent_record.root? ? valid_root?(parent) && valid_path_length?(parent, 0) : signer_chain?(parent, intermediates.reject(&.==(parent_record)), roots, 2)
            begin
              Crypto::MatterCertificate::Validation.verify_signature(vvsc,
                parent.public_key.as(OpenSSL::PKey::EC).public_key_bytes)
              true
            rescue Matter::AuthenticationError
              false
            end
          end
        end

        private def matter_key_id(certificate : Bytes, authority : Bool = false) : Bytes?
          extensions = TLV::Any.from_slice(certificate).as_structure[Crypto::MatterCertificate::Asn1::Field::Extensions.value].as_list
          tag = authority ? Crypto::MatterCertificate::Asn1::Extension::AuthorityKeyIdentifier.value : Crypto::MatterCertificate::Asn1::Extension::SubjectKeyIdentifier.value
          extensions.find { |item| item.header.ids == tag }.try(&.as_bytes)
        end

        private def name_der(name : OpenSSL::X509::Name) : Bytes
          size = LibCrypto.matter_i2d_x509_name(name.to_unsafe, Pointer(Pointer(UInt8)).null)
          raise Matter::CertificateError.new("Invalid X.509 name") unless size > 0
          encoded = Bytes.new(size)
          cursor = encoded.to_unsafe
          written = LibCrypto.matter_i2d_x509_name(name.to_unsafe, pointerof(cursor))
          raise Matter::CertificateError.new("X.509 name could not be encoded") unless written == size
          encoded
        end

        private def valid_matter_name?(name : TLV::Any) : Bool
          elements = name.as_list
          elements.size <= 5 && elements.all? do |element|
            tag = element.header.ids
            tag.is_a?(UInt8) && !Crypto::MatterCertificate::Asn1::Dn.from_value?(tag).nil?
          end
        end

        private def valid_root?(cert : OpenSSL::X509::Certificate) : Bool
          valid_time?(cert) && cert.subject.to_a == cert.issuer.to_a && cert.verify(cert.public_key) &&
            key_id(cert) == key_id(cert, authority: true) && key_id(cert).size == KEY_ID_SIZE &&
            valid_ca?(cert)
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
