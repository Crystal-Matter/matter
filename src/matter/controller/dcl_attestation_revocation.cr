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
      sha256 : Bytes?

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
          DclRevocationPoint.new(skid, pem_der(record["crlSignerCertificate"].as_s),
            delegator_text.empty? ? nil : pem_der(delegator_text), record["dataURL"].as_s,
            record["isPAA"].as_bool, nil, nil)
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

    # Conservative online adapter for complete, directly signed CRLs. The
    # application supplies an authenticated DCL source and a bounded fetcher;
    # it explicitly allowlists CRL hosts. Partitioned and delegated CRLs are
    # unsupported and return Unavailable rather than an incomplete Good.
    class DclAttestationRevocation
      MAX_CRL_SIZE  = OfflineAttestationRevocation::MAX_CRL_SIZE
      FETCH_TIMEOUT = 5.seconds
      alias Fetch = Proc(String, Bytes)

      def initialize(@source : DclRevocationSource, @allowed_crl_hosts : Set(String),
                     @fetch : Fetch = ->(url : String) { DclAttestationRevocation.fetch_https(url) })
        raise Matter::ConfigurationError.new("No CRL hosts were approved") if @allowed_crl_hosts.empty?
        @allowed_crl_hosts.each do |host|
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
        collect(paa_cert, true, crls)
        collect(pai_cert, false, crls)
        OfflineAttestationRevocation.new(crls).check(dac, pai, paa)
      rescue ex
        ::Log.for("matter.controller.dcl_attestation_revocation").warn(exception: ex) do
          "DCL attestation revocation check unavailable"
        end
        RevocationStatus::Unavailable
      end

      private def collect(issuer : OpenSSL::X509::Certificate, is_paa : Bool,
                          crls : Array(Bytes)) : Nil
        key_id = LibCrypto.x509_get0_subject_key_id(issuer)
        raise Matter::AuthenticationError.new("CRL issuer has no SKID") if key_id.null?
        length = LibCrypto.asn1_string_length(key_id)
        raise Matter::AuthenticationError.new("Invalid CRL issuer SKID") unless length == 20
        skid = Slice.new(LibCrypto.asn1_string_get0_data(key_id).as(UInt8*), length).dup
        points = @source.points_for(skid)
        raise Matter::AuthenticationError.new("No DCL revocation coverage") unless points.size == 1
        point = points.first
        unless point.issuer_skid == skid && point.is_paa == is_paa &&
               point.crl_signer_delegator_der.nil? && point.crl_signer_der == issuer.to_der
          raise Matter::AuthenticationError.new("Unsupported or mismatched DCL CRL signer")
        end
        uri = URI.parse(point.url)
        host = uri.host
        unless uri.scheme == "https" && host && @allowed_crl_hosts.includes?(host.downcase) &&
               uri.user.nil? && uri.password.nil? && uri.fragment.nil?
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
      end
    end
  end
end
