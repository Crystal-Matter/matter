require "uri"
require "http/client"
require "json"
require "base64"
require "openssl_ext"
require "./attestation_revocation"

module Matter
  module Controller
    # A DCL revocation distribution point. The source must return the complete
    # active set for an issuer SKID, including every partition.
    record DclRevocationPoint,
      issuer_skid : Bytes,
      crl_signer_der : Bytes,
      crl_signer_delegator_der : Bytes?,
      url : String,
      is_paa : Bool,
      size : Int64?,
      sha256 : Bytes?,
      vendor_id : UInt16? = nil,
      label : String? = nil,
      product_id : UInt16? = nil

    abstract class DclRevocationSource
      abstract def points_for(issuer_skid : Bytes) : Array(DclRevocationPoint)
    end

    # Reads the DCL's revocation-point index from a caller-selected HTTPS
    # gateway. The gateway's ledger authenticity and freshness are deployment
    # decisions; this parser does not make an untrusted observer authoritative.
    class HttpDclRevocationSource < DclRevocationSource
      MAX_RESPONSE_SIZE = 1_048_576
      alias Fetch = Proc(String, Bytes)

      def initialize(@gateway_url : String,
                     @fetch : Fetch = ->(url : String) { DclAttestationRevocation.fetch_https(url) })
        uri = URI.parse(@gateway_url)
        unless uri.scheme == "https" && uri.host && uri.user.nil? && uri.password.nil? &&
               uri.query.nil? && uri.fragment.nil? && uri.path.in?("", "/")
          raise Matter::ConfigurationError.new("DCL gateway must be an HTTPS origin")
        end
        @gateway_url = @gateway_url.rstrip('/')
      end

      def points_for(issuer_skid : Bytes) : Array(DclRevocationPoint)
        raise Matter::AuthenticationError.new("Invalid issuer SKID") unless issuer_skid.size == 20
        body = @fetch.call("#{@gateway_url}/dcl/pki/revocation-points/#{issuer_skid.hexstring.upcase}")
        raise Matter::AuthenticationError.new("DCL response is too large") if body.size > MAX_RESPONSE_SIZE
        items = JSON.parse(String.new(body)).as_h["pkiRevocationDistributionPointsByIssuerSubjectKeyID"].as_h["points"].as_a
        items.map do |item|
          record = item.as_h
          skid_text = record["issuerSubjectKeyID"].as_s
          raise Matter::AuthenticationError.new("Invalid DCL issuer SKID") unless skid_text.matches?(/\A[0-9A-F]{40}\z/)
          skid = skid_text.hexbytes
          raise Matter::AuthenticationError.new("DCL issuer SKID mismatch") unless skid == issuer_skid
          raise Matter::AuthenticationError.new("Unsupported DCL revocation type") unless record["revocationType"].raw.to_s == "1"
          digest_type = record["dataDigestType"]?.try(&.raw.to_s) || "0"
          digest_text = record["dataDigest"]?.try(&.as_s) || ""
          # The v1.6 DCL commonly omits digest metadata (type 0). Unknown
          # digest algorithms cannot be silently ignored.
          unless digest_type == "0" && digest_text.empty?
            raise Matter::AuthenticationError.new("Unsupported DCL CRL digest metadata")
          end
          size_text = record["dataFileSize"]?.try(&.raw.to_s) || "0"
          # Matter 1.6 §11.23.9.9 forbids DataFileSize for signed CRLs. Proto3
          # represents its absence as zero in the JSON response.
          raise Matter::AuthenticationError.new("Unexpected DCL CRL size metadata") unless size_text == "0"
          delegator_text = record["crlSignerDelegator"]?.try(&.as_s) || ""
          vendor_id = record["vid"].raw.to_s.to_u16
          product_id = record["pid"]?.try(&.raw.to_s.to_u16)
          product_id = nil if product_id == 0
          label = record["label"].as_s
          raise Matter::AuthenticationError.new("Invalid DCL CRL label") if label.empty? || label.bytesize > 64
          DclRevocationPoint.new(skid, pem_der(record["crlSignerCertificate"].as_s),
            delegator_text.empty? ? nil : pem_der(delegator_text), record["dataURL"].as_s,
            record["isPAA"].as_bool, nil, nil, vendor_id, label, product_id)
        end
      rescue ex : Matter::Error
        raise ex
      rescue ex
        raise Matter::AuthenticationError.new("Invalid DCL revocation response: #{ex.message}", cause: ex)
      end

      private def pem_der(pem : String) : Bytes
        lines = pem.lines.map(&.strip)
        unless lines.first? == "-----BEGIN CERTIFICATE-----" &&
               lines.last? == "-----END CERTIFICATE-----"
          raise Matter::AuthenticationError.new("Invalid DCL CRL signer certificate")
        end
        Base64.decode(lines[1...-1].join)
      end
    end

    # Online adapter for bounded direct, partitioned, and delegated CRLs. The
    # application supplies an authenticated DCL source and approved CRL hosts.
    class DclAttestationRevocation
      MAX_CRL_SIZE  = OfflineAttestationRevocation::MAX_CRL_SIZE
      FETCH_TIMEOUT = 5.seconds
      alias Fetch = Proc(String, Bytes)

      def initialize(@source : DclRevocationSource, @allowed_crl_hosts : Set(String),
                     @fetch : Fetch = ->(url : String) { DclAttestationRevocation.fetch_crl(url) },
                     @allowed_http_crl_hosts : Set(String) = Set(String).new)
        if @allowed_crl_hosts.empty? && @allowed_http_crl_hosts.empty?
          raise Matter::ConfigurationError.new("No CRL hosts were approved")
        end
        (@allowed_crl_hosts | @allowed_http_crl_hosts).each do |host|
          if host.empty? || host != host.downcase || host.includes?('/') || host.includes?(':')
            raise Matter::ConfigurationError.new("Invalid approved CRL host")
          end
        end
      end

      # HTTPS only; reads at most MAX_CRL_SIZE bytes before returning. An HTTP
      # redirect is rejected as a non-200 response and never followed.
      def self.fetch_https(url : String) : Bytes
        uri = URI.parse(url)
        raise Matter::AuthenticationError.new("CRL URL must use HTTPS") unless uri.scheme == "https"
        fetch_crl(url)
      end

      # This helper may receive HTTP only after the caller has checked its
      # explicit HTTP host allowlist. CRL signatures and freshness are verified
      # after download; the transport never follows redirects.
      private def self.fetch_crl(url : String) : Bytes
        uri = URI.parse(url)
        unless uri.scheme.in?("https", "http")
          raise Matter::AuthenticationError.new("Unsupported CRL URL scheme")
        end
        HTTP::Client.new(uri) do |client|
          client.connect_timeout = FETCH_TIMEOUT
          client.read_timeout = FETCH_TIMEOUT
          client.exec("GET", uri.request_target) do |response|
            raise Matter::AuthenticationError.new("CRL HTTP response was not 200") unless response.status_code == 200
            output = IO::Memory.new
            buffer = Bytes.new(8192)
            while (read = response.body_io.read(buffer)) > 0
              raise Matter::AuthenticationError.new("CRL is too large") if output.size + read > MAX_CRL_SIZE
              output.write(buffer[0, read])
            end
            output.to_slice
          end
        end
      end

      def callback : Proc(Bytes, Bytes, Bytes, RevocationStatus)
        ->(dac : Bytes, pai : Bytes, paa : Bytes) { check(dac, pai, paa) }
      end

      def check(dac : Bytes, pai : Bytes, paa : Bytes) : RevocationStatus
        pai_cert = OpenSSL::X509::Certificate.from_der(pai)
        paa_cert = OpenSSL::X509::Certificate.from_der(paa)
        crls = [] of Bytes
        distribution_urls = [] of String?
        validations = [] of OfflineAttestationRevocation::CrlValidation
        collect(paa_cert, true, crls, distribution_urls, validations)
        collect(pai_cert, false, crls, distribution_urls, validations)
        OfflineAttestationRevocation.new(crls, distribution_urls, validations).check(dac, pai, paa)
      rescue ex
        ::Log.for("matter.controller.dcl_attestation_revocation").warn(exception: ex) do
          "DCL attestation revocation check unavailable"
        end
        RevocationStatus::Unavailable
      end

      private def collect(issuer : OpenSSL::X509::Certificate, is_paa : Bool,
                          crls : Array(Bytes), distribution_urls : Array(String?),
                          validations : Array(OfflineAttestationRevocation::CrlValidation)) : Nil
        key_id = LibCrypto.x509_get0_subject_key_id(issuer)
        raise Matter::AuthenticationError.new("CRL issuer has no SKID") if key_id.null?
        length = LibCrypto.asn1_string_length(key_id)
        raise Matter::AuthenticationError.new("Invalid CRL issuer SKID") unless length == 20
        skid = Slice.new(LibCrypto.asn1_string_get0_data(key_id).as(UInt8*), length).dup
        points = @source.points_for(skid)
        raise Matter::AuthenticationError.new("No DCL revocation coverage") unless points.size.in?(1..32)
        partitioned = points.size > 1
        if partitioned
          labels = points.map(&.label)
          vendors = points.map(&.vendor_id)
          urls = points.map(&.url)
          unless labels.all? { |label| label && !label.empty? } && labels.uniq.size == points.size &&
                 vendors.all?(&.!=(nil)) && vendors.uniq.size == 1 && urls.uniq.size == points.size
            raise Matter::AuthenticationError.new("Invalid DCL CRL partition metadata")
          end
        end
        points.each do |point|
          unless point.issuer_skid == skid && point.is_paa == is_paa
            raise Matter::AuthenticationError.new("Unsupported or mismatched DCL CRL signer")
          end
          vendor_id = check_issuer_metadata!(point, issuer, is_paa)
          delegated = point.crl_signer_der != issuer.to_der
          if delegated
            if is_paa
              raise Matter::AuthenticationError.new("Unexpected PAA CRL delegator") if point.crl_signer_delegator_der
            else
              unless point.crl_signer_delegator_der == issuer.to_der
                raise Matter::AuthenticationError.new("Invalid PAI CRL delegator")
              end
            end
            validate_delegate!(point.crl_signer_der, issuer, is_paa, vendor_id)
          elsif point.crl_signer_delegator_der
            raise Matter::AuthenticationError.new("Unexpected direct CRL delegator")
          end
          unless point.url.bytesize.in?(1..256) && point.url.each_byte.all?(&.in?(0x21..0x7e))
            raise Matter::AuthenticationError.new("Invalid DCL CRL URL")
          end
          uri = URI.parse(point.url)
          host = uri.host
          approved_https = uri.scheme == "https" && (uri.port.nil? || uri.port == 443) &&
                           host && @allowed_crl_hosts.includes?(host.downcase)
          approved_http = uri.scheme == "http" && (uri.port.nil? || uri.port == 80) &&
                          host && @allowed_http_crl_hosts.includes?(host.downcase)
          unless (approved_https || approved_http) && uri.user.nil? && uri.password.nil? && uri.fragment.nil?
            raise Matter::AuthenticationError.new("CRL URL is not approved")
          end
          data = @fetch.call(point.url)
          raise Matter::AuthenticationError.new("CRL is too large") unless data.size.in?(1..MAX_CRL_SIZE)
          if size = point.size
            raise Matter::AuthenticationError.new("CRL size mismatch") unless data.size.to_i64 == size
          end
          if digest = point.sha256
            raise Matter::AuthenticationError.new("Invalid CRL digest") unless digest.size == 32
            hash = OpenSSL::Digest.new("SHA256").update(data).final
            raise Matter::AuthenticationError.new("CRL digest mismatch") unless hash == digest
          end
          crls << data
          distribution_urls << (partitioned || delegated ? point.url : nil)
          validations << OfflineAttestationRevocation::CrlValidation.new(
            issuer.to_der, point.crl_signer_der, partitioned || delegated ? point.url : nil)
        end
      end

      private def check_issuer_metadata!(point : DclRevocationPoint,
                                         issuer : OpenSSL::X509::Certificate,
                                         is_paa : Bool) : UInt16
        vendor_id = point.vendor_id
        label = point.label
        if vendor_id.nil? || label.nil? || label.empty? || label.bytesize > 64
          raise Matter::AuthenticationError.new("Missing DCL CRL issuer metadata")
        end
        if certificate_vendor = subject_id(issuer, DeviceAttestationVerifier::VENDOR_ID_OID)
          unless vendor_id == certificate_vendor
            raise Matter::AuthenticationError.new("DCL CRL vendor mismatch")
          end
        elsif !is_paa
          raise Matter::AuthenticationError.new("PAI lacks vendor ID")
        end
        certificate_product = subject_id(issuer, DeviceAttestationVerifier::PRODUCT_ID_OID)
        if is_paa
          raise Matter::AuthenticationError.new("Unexpected PAA product ID") if point.product_id || certificate_product
        elsif point.product_id != certificate_product
          raise Matter::AuthenticationError.new("DCL CRL product mismatch")
        end
        vendor_id
      end

      private def subject_id(cert : OpenSSL::X509::Certificate, oid : String) : UInt16?
        text = cert.subject.to_a.find { |entry| entry[0].split('\0').first == oid }.try(&.[1])
        return unless text
        unless text.matches?(/\A[0-9A-Fa-f]{4}\z/)
          raise Matter::AuthenticationError.new("Invalid attestation subject identifier")
        end
        text.to_u16(16)
      end

      private def validate_delegate!(der : Bytes, issuer : OpenSSL::X509::Certificate,
                                     is_paa : Bool, vendor_id : UInt16) : Nil
        raise Matter::AuthenticationError.new("Delegated CRL signer is too large") if der.size > 2048
        delegate = OpenSSL::X509::Certificate.from_der(der)
        if is_paa && subject_id(delegate, DeviceAttestationVerifier::PRODUCT_ID_OID)
          raise Matter::AuthenticationError.new("PAA CRL delegate has product ID")
        end
        if is_paa && (signer_vendor = subject_id(delegate, DeviceAttestationVerifier::VENDOR_ID_OID)) &&
           signer_vendor != vendor_id
          raise Matter::AuthenticationError.new("PAA CRL delegate vendor mismatch")
        end
        unless OfflineAttestationRevocation.valid_delegate_chain?(delegate, issuer)
          raise Matter::AuthenticationError.new("Invalid delegated CRL signer chain or profile")
        end
      end
    end
  end
end
