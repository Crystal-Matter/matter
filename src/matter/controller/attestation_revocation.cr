require "openssl_ext"
require "./device_attestation_verifier"

lib LibCrypto
  struct MatterAuthorityKeyId
    keyid : ASN1_STRING
    issuer : Void*
    serial : Void*
  end

  fun matter_d2i_x509_crl = d2i_X509_CRL(crl : X509_CRL*, data : UInt8**, length : LibC::Long) : X509_CRL
  fun matter_x509_crl_free = X509_CRL_free(crl : X509_CRL)
  fun matter_x509_crl_get_issuer = X509_CRL_get_issuer(crl : X509_CRL) : X509_NAME
  fun matter_x509_name_cmp = X509_NAME_cmp(left : X509_NAME, right : X509_NAME) : Int32
  fun matter_x509_crl_verify = X509_CRL_verify(crl : X509_CRL, key : EvpPKey*) : Int32
  fun matter_x509_get_pubkey = X509_get_pubkey(cert : X509) : EvpPKey*
  fun matter_x509_crl_get0_last_update = X509_CRL_get0_lastUpdate(crl : X509_CRL) : ASN1_STRING
  fun matter_x509_crl_get0_next_update = X509_CRL_get0_nextUpdate(crl : X509_CRL) : ASN1_STRING
  fun matter_x509_cmp_current_time = X509_cmp_current_time(time : ASN1_STRING) : Int32
  fun matter_x509_crl_get_ext_by_nid = X509_CRL_get_ext_by_NID(crl : X509_CRL, nid : Int32, last : Int32) : Int32
  fun matter_x509_crl_get_ext_d2i = X509_CRL_get_ext_d2i(crl : X509_CRL, nid : Int32, critical : Int32*, index : Int32*) : Void*
  fun matter_authority_keyid_free = AUTHORITY_KEYID_free(akid : MatterAuthorityKeyId*)
  fun matter_x509_crl_get0_by_cert = X509_CRL_get0_by_cert(crl : X509_CRL, revoked : Void**, cert : X509) : Int32
end

module Matter
  module Controller
    # A local, explicitly provisioned revocation oracle for direct PAA and
    # PAI CRLs. It is intentionally strict: both issuers need a current,
    # correctly signed CRL. DCL retrieval, partitioned CRLs and delegated
    # (indirect) CRL signers require a separate authenticated distribution
    # provider and are not silently treated as good here.
    class OfflineAttestationRevocation
      MAX_CRL_SIZE       = 1_048_576
      KEY_USAGE_CRL_SIGN =  0x02_u32

      private class ParsedCrl
        getter handle : LibCrypto::X509_CRL

        def initialize(der : Bytes)
          unless der.size.in?(1..MAX_CRL_SIZE)
            raise Matter::ConfigurationError.new("Attestation CRL has an invalid size")
          end
          input = der.to_unsafe
          @handle = LibCrypto.matter_d2i_x509_crl(nil, pointerof(input), der.size)
          if @handle.null? || input - der.to_unsafe != der.size
            LibCrypto.matter_x509_crl_free(@handle) unless @handle.null?
            raise Matter::ConfigurationError.new("Attestation CRL is not canonical DER")
          end
        end

        def finalize
          LibCrypto.matter_x509_crl_free(@handle)
        end
      end

      @crls : Array(ParsedCrl)
      @authority_key_nid : Int32
      @issuing_distribution_point_nid : Int32
      @delta_crl_nid : Int32
      @crl_number_nid : Int32

      def initialize(crl_der : Array(Bytes))
        @authority_key_nid = LibCrypto.obj_txt2nid("authorityKeyIdentifier")
        @issuing_distribution_point_nid = LibCrypto.obj_txt2nid("issuingDistributionPoint")
        @delta_crl_nid = LibCrypto.obj_txt2nid("deltaCRLIndicator")
        @crl_number_nid = LibCrypto.obj_txt2nid("crlNumber")
        @crls = crl_der.map { |der| ParsedCrl.new(der) }
      end

      # Pass this to AttestationTrustStore#revocation_check. The verifier calls
      # it only after validating DAC -> PAI -> PAA against its configured trust.
      def callback : Proc(Bytes, Bytes, Bytes, RevocationStatus)
        ->(dac_der : Bytes, pai_der : Bytes, paa_der : Bytes) { check(dac_der, pai_der, paa_der) }
      end

      def check(dac_der : Bytes, pai_der : Bytes, paa_der : Bytes) : RevocationStatus
        dac = OpenSSL::X509::Certificate.from_der(dac_der)
        pai = OpenSSL::X509::Certificate.from_der(pai_der)
        paa = OpenSSL::X509::Certificate.from_der(paa_der)
        pai_status = status_for(pai, paa)
        return pai_status unless pai_status.good?
        status_for(dac, pai)
      rescue ex
        ::Log.for("matter.controller.attestation_revocation").warn(exception: ex) { "Attestation CRL check unavailable" }
        RevocationStatus::Unavailable
      end

      private def status_for(cert : OpenSSL::X509::Certificate,
                             issuer : OpenSSL::X509::Certificate) : RevocationStatus
        issuer_name = LibCrypto.x509_get_subject_name(issuer)
        issuer_key_id = LibCrypto.x509_get0_subject_key_id(issuer)
        return RevocationStatus::Unavailable if issuer_name.null? || issuer_key_id.null?
        return RevocationStatus::Unavailable unless issuer.extensions.any?(&.oid.==("keyUsage"))
        return RevocationStatus::Unavailable if (LibCrypto.x509_get_key_usage(issuer) & KEY_USAGE_CRL_SIGN) == 0
        found = false
        @crls.each do |entry|
          crl = entry.handle
          next unless LibCrypto.matter_x509_name_cmp(LibCrypto.matter_x509_crl_get_issuer(crl), issuer_name) == 0
          next unless matching_key_id?(crl, issuer_key_id)
          return RevocationStatus::Unavailable unless valid_direct_crl?(crl, issuer)
          found = true
          revoked = Pointer(Void).null
          return RevocationStatus::Revoked if LibCrypto.matter_x509_crl_get0_by_cert(crl, pointerof(revoked), cert) == 1
        end
        found ? RevocationStatus::Good : RevocationStatus::Unavailable
      end

      private def matching_key_id?(crl : LibCrypto::X509_CRL, issuer_key_id : LibCrypto::ASN1_STRING) : Bool
        extension = LibCrypto.matter_x509_crl_get_ext_d2i(crl, @authority_key_nid, nil, nil)
        return false if extension.null?
        akid = extension.as(LibCrypto::MatterAuthorityKeyId*)
        begin
          key_id = akid.value.keyid
          return false if key_id.null?
          length = LibCrypto.asn1_string_length(key_id)
          return false unless length == LibCrypto.asn1_string_length(issuer_key_id)
          Slice.new(LibCrypto.asn1_string_get0_data(key_id).as(UInt8*), length) ==
            Slice.new(LibCrypto.asn1_string_get0_data(issuer_key_id).as(UInt8*), length)
        ensure
          LibCrypto.matter_authority_keyid_free(akid)
        end
      end

      private def valid_direct_crl?(crl : LibCrypto::X509_CRL,
                                    issuer : OpenSSL::X509::Certificate) : Bool
        # Partitioned and indirect CRLs need their DCL distribution-point
        # metadata and signer chain. Reject them until those are provided.
        return false if LibCrypto.matter_x509_crl_get_ext_by_nid(crl, @issuing_distribution_point_nid, -1) >= 0
        return false if LibCrypto.matter_x509_crl_get_ext_by_nid(crl, @delta_crl_nid, -1) >= 0
        return false if LibCrypto.matter_x509_crl_get_ext_by_nid(crl, @crl_number_nid, -1) < 0
        last_update = LibCrypto.matter_x509_crl_get0_last_update(crl)
        next_update = LibCrypto.matter_x509_crl_get0_next_update(crl)
        return false if last_update.null? || next_update.null?
        return false unless LibCrypto.matter_x509_cmp_current_time(last_update) < 0 &&
                            LibCrypto.matter_x509_cmp_current_time(next_update) > 0
        key = LibCrypto.matter_x509_get_pubkey(issuer)
        return false if key.null?
        begin
          LibCrypto.matter_x509_crl_verify(crl, key) == 1
        ensure
          LibCrypto.evp_pkey_free(key)
        end
      end
    end
  end
end
