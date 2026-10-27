require "openssl_ext"
require "./device_attestation_verifier"

lib LibCrypto
  struct MatterAuthorityKeyId
    keyid : ASN1_STRING
    issuer : Void*
    serial : Void*
  end

  struct MatterDistributionPointName
    type : Int32
    names : Void*
    dpname : X509_NAME
  end

  struct MatterIssuingDistributionPoint
    distpoint : MatterDistributionPointName*
    onlyuser : Int32
    only_ca : Int32
    only_some_reasons : Void*
    indirect_crl : Int32
    only_attr : Int32
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
  fun matter_x509_extension_get_critical = X509_EXTENSION_get_critical(extension : X509_EXTENSION) : Int32
  fun matter_issuing_dist_point_free = ISSUING_DIST_POINT_free(point : MatterIssuingDistributionPoint*)
  fun matter_authority_keyid_free = AUTHORITY_KEYID_free(akid : MatterAuthorityKeyId*)
  fun matter_x509_crl_get_ext_count = X509_CRL_get_ext_count(crl : X509_CRL) : Int32
  fun matter_x509_crl_get_ext = X509_CRL_get_ext(crl : X509_CRL, index : Int32) : X509_EXTENSION
  fun matter_x509_crl_get_version = X509_CRL_get_version(crl : X509_CRL) : LibC::Long
  fun matter_x509_crl_get_signature_nid = X509_CRL_get_signature_nid(crl : X509_CRL) : Int32
  fun matter_x509_crl_get_revoked = X509_CRL_get_REVOKED(crl : X509_CRL) : Void*
  fun matter_x509_revoked_get_ext_count = X509_REVOKED_get_ext_count(entry : Void*) : Int32
  fun matter_x509_revoked_get_ext = X509_REVOKED_get_ext(entry : Void*, index : Int32) : X509_EXTENSION
  fun matter_x509_revoked_get_ext_by_nid = X509_REVOKED_get_ext_by_NID(entry : Void*, nid : Int32, last : Int32) : Int32
  fun matter_x509_revoked_get_ext_d2i = X509_REVOKED_get_ext_d2i(entry : Void*, nid : Int32, critical : Int32*, index : Int32*) : Void*
  fun matter_x509_revoked_get0_serial = X509_REVOKED_get0_serialNumber(entry : Void*) : ASN1_STRING
  fun matter_x509_get0_serial = X509_get0_serialNumber(cert : X509) : ASN1_STRING
  fun matter_asn1_integer_cmp = ASN1_INTEGER_cmp(left : ASN1_STRING, right : ASN1_STRING) : Int32
  fun matter_asn1_enumerated_get = ASN1_ENUMERATED_get(value : ASN1_STRING) : LibC::Long
  fun matter_asn1_enumerated_free = ASN1_ENUMERATED_free(value : ASN1_STRING)
  fun matter_general_names_free = GENERAL_NAMES_free(names : Void*)
end

module Matter
  module Controller
    # A local, explicitly provisioned revocation oracle for direct PAA and
    # PAI CRLs. It is intentionally strict: both issuers need a current,
    # correctly signed CRL. DCL retrieval, partitioned CRLs and delegated
    # (indirect) CRL signers require a separate authenticated distribution
    # provider and are not silently treated as good here.
    class OfflineAttestationRevocation
      MAX_CRL_SIZE                = 1_048_576
      KEY_USAGE_DIGITAL_SIGNATURE =  0x80_u32
      KEY_USAGE_CRL_SIGN          =  0x02_u32
      ALLOWED_DELEGATE_KEY_USAGE  = KEY_USAGE_DIGITAL_SIGNATURE | KEY_USAGE_CRL_SIGN

      record CrlValidation,
        certificate_issuer : Bytes,
        signer : Bytes,
        distribution_url : String?

      private class ParsedCrl
        getter handle : LibCrypto::X509_CRL
        getter distribution_url : String?
        getter validation : CrlValidation?

        def initialize(der : Bytes, @distribution_url : String? = nil,
                       @validation : CrlValidation? = nil)
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
      @certificate_issuer_nid : Int32
      @reason_code_nid : Int32

      def initialize(crl_der : Array(Bytes), distribution_urls : Array(String?)? = nil,
                     validations : Array(CrlValidation)? = nil)
        @authority_key_nid = LibCrypto.obj_txt2nid("authorityKeyIdentifier")
        @issuing_distribution_point_nid = LibCrypto.obj_txt2nid("issuingDistributionPoint")
        @delta_crl_nid = LibCrypto.obj_txt2nid("deltaCRLIndicator")
        @crl_number_nid = LibCrypto.obj_txt2nid("crlNumber")
        @certificate_issuer_nid = LibCrypto.obj_txt2nid("certificateIssuer")
        @reason_code_nid = LibCrypto.obj_txt2nid("crlReason")
        urls = distribution_urls || Array(String?).new(crl_der.size, nil)
        raise Matter::ConfigurationError.new("CRL distribution metadata mismatch") unless urls.size == crl_der.size
        if validations && validations.size != crl_der.size
          raise Matter::ConfigurationError.new("CRL signer metadata mismatch")
        end
        @crls = crl_der.each_with_index.map do |der, index|
          ParsedCrl.new(der, urls[index], validations.try(&.[index]))
        end.to_a
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
          validation = entry.validation
          next if validation && validation.certificate_issuer != issuer.to_der
          signer = validation ? OpenSSL::X509::Certificate.from_der(validation.signer) : issuer
          issuer_matches = LibCrypto.matter_x509_name_cmp(LibCrypto.matter_x509_crl_get_issuer(crl),
            LibCrypto.x509_get_subject_name(signer)) == 0
          return RevocationStatus::Unavailable if validation && !issuer_matches
          next unless issuer_matches
          signer_key_id = LibCrypto.x509_get0_subject_key_id(signer)
          return RevocationStatus::Unavailable if signer_key_id.null?
          key_matches = matching_key_id?(crl, signer_key_id)
          return RevocationStatus::Unavailable if validation && !key_matches
          next unless key_matches
          indirect = signer.to_der != issuer.to_der
          return RevocationStatus::Unavailable if indirect && !self.class.valid_delegate_chain?(signer, issuer)
          return RevocationStatus::Unavailable unless valid_crl?(crl, signer, entry.distribution_url, indirect)
          found = true
          return RevocationStatus::Revoked if revoked_for?(crl, cert, issuer_name, indirect)
        end
        found ? RevocationStatus::Good : RevocationStatus::Unavailable
      end

      # Used by the DCL adapter and checked again here before trusting public
      # validation metadata supplied to the offline constructor.
      def self.valid_delegate_chain?(delegate : OpenSSL::X509::Certificate,
                                     issuer : OpenSSL::X509::Certificate) : Bool
        constraint = delegate.extensions.find { |ext| ext.oid == "basicConstraints" }
        usage_extension = delegate.extensions.find { |ext| ext.oid == "keyUsage" }
        usage = LibCrypto.x509_get_key_usage(delegate)
        return false unless delegate.version == 2 && constraint && usage_extension &&
                            LibCrypto.matter_x509_extension_get_critical(constraint) == 1 &&
                            LibCrypto.matter_x509_extension_get_critical(usage_extension) == 1 &&
                            constraint.value.includes?("CA:FALSE") && LibCrypto.x509_check_ca(delegate) == 0 &&
                            (usage & KEY_USAGE_CRL_SIGN) != 0 && (usage & ~ALLOWED_DELEGATE_KEY_USAGE) == 0
        now = Time.utc
        return false unless delegate.not_before <= now && now <= delegate.not_after &&
                            LibCrypto.x509_get_signature_nid(delegate) == LibCrypto.obj_txt2nid("ecdsa-with-SHA256") &&
                            LibCrypto.matter_x509_name_cmp(LibCrypto.x509_get_issuer_name(delegate),
                              LibCrypto.x509_get_subject_name(issuer)) == 0
        issuer_skid = LibCrypto.x509_get0_subject_key_id(issuer)
        delegate_akid = LibCrypto.x509_get0_authority_key_id(delegate)
        delegate_skid = LibCrypto.x509_get0_subject_key_id(delegate)
        return false if issuer_skid.null? || delegate_akid.null? || delegate_skid.null?
        return false unless LibCrypto.asn1_string_length(issuer_skid) == 20 &&
                            LibCrypto.asn1_string_length(delegate_akid) == 20 &&
                            LibCrypto.asn1_string_length(delegate_skid) == 20
        return false unless Slice.new(LibCrypto.asn1_string_get0_data(delegate_akid).as(UInt8*), 20) ==
                              Slice.new(LibCrypto.asn1_string_get0_data(issuer_skid).as(UInt8*), 20)
        delegate_key = delegate.public_key
        ec = LibCrypto.evp_pkey_get0_ec_key(delegate_key)
        return false if ec.null?
        group = LibCrypto.ec_key_get0_group(ec)
        return false if group.null? || LibCrypto.ec_group_get_curve_name(group) != LibCrypto::NID_X9_62_prime256v1
        key = LibCrypto.matter_x509_get_pubkey(issuer)
        return false if key.null?
        begin
          LibCrypto.x509_verify(delegate, key) == 1
        ensure
          LibCrypto.evp_pkey_free(key)
        end
      end

      private def revoked_for?(crl : LibCrypto::X509_CRL,
                               cert : OpenSSL::X509::Certificate,
                               issuer_name : LibCrypto::X509_NAME,
                               indirect : Bool) : Bool
        entries = LibCrypto.matter_x509_crl_get_revoked(crl)
        return false if entries.null?
        issuer_matches = true
        serial = LibCrypto.matter_x509_get0_serial(cert)
        LibCrypto.sk_num(entries).times do |index|
          entry = LibCrypto.sk_value(entries, index)
          validate_entry_extensions!(entry, indirect)
          names = LibCrypto.matter_x509_revoked_get_ext_d2i(entry, @certificate_issuer_nid, nil, nil)
          if names.null? && LibCrypto.matter_x509_revoked_get_ext_by_nid(entry, @certificate_issuer_nid, -1) >= 0
            raise Matter::AuthenticationError.new("Invalid CRL certificate issuer")
          end
          unless names.null?
            begin
              raise Matter::AuthenticationError.new("Invalid CRL certificate issuer") unless LibCrypto.sk_num(names) == 1
              name = LibCrypto.sk_value(names, 0).as(LibCrypto::GENERAL_NAME*)
              raise Matter::AuthenticationError.new("Invalid CRL certificate issuer") if name.null? || name.value.type != 4
              issuer_matches = LibCrypto.matter_x509_name_cmp(name.value.value.as(LibCrypto::X509_NAME),
                issuer_name) == 0
            ensure
              LibCrypto.matter_general_names_free(names)
            end
          end
          next unless issuer_matches
          return true if LibCrypto.matter_asn1_integer_cmp(LibCrypto.matter_x509_revoked_get0_serial(entry), serial) == 0
        end
        false
      end

      private def validate_entry_extensions!(entry : Void*, indirect : Bool) : Nil
        issuer_count = 0
        reason_count = 0
        LibCrypto.matter_x509_revoked_get_ext_count(entry).times do |index|
          extension = LibCrypto.matter_x509_revoked_get_ext(entry, index)
          nid = LibCrypto.obj_obj2nid(LibCrypto.x509_extension_get_object(extension))
          if nid == @certificate_issuer_nid
            issuer_count += 1
            unless indirect && LibCrypto.matter_x509_extension_get_critical(extension) == 1
              raise Matter::AuthenticationError.new("Invalid indirect CRL certificate issuer")
            end
          elsif nid == @reason_code_nid
            reason_count += 1
            raise Matter::AuthenticationError.new("Duplicate CRL reason") if reason_count > 1
            if LibCrypto.matter_x509_extension_get_critical(extension) == 1
              raise Matter::AuthenticationError.new("Critical CRL reason is unsupported")
            end
            reason = LibCrypto.matter_x509_revoked_get_ext_d2i(entry, @reason_code_nid, nil, nil)
            raise Matter::AuthenticationError.new("Invalid CRL reason") if reason.null?
            begin
              # removeFromCRL is meaningful only in a delta CRL, which Matter forbids.
              value = LibCrypto.matter_asn1_enumerated_get(reason.as(LibCrypto::ASN1_STRING))
              unless value.in?(0..6) || value.in?(9..10)
                raise Matter::AuthenticationError.new("Unsupported CRL reason")
              end
            ensure
              LibCrypto.matter_asn1_enumerated_free(reason.as(LibCrypto::ASN1_STRING))
            end
          elsif LibCrypto.matter_x509_extension_get_critical(extension) == 1
            raise Matter::AuthenticationError.new("Unsupported critical CRL entry extension")
          end
        end
        raise Matter::AuthenticationError.new("Duplicate CRL certificate issuer") if issuer_count > 1
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

      private def valid_crl?(crl : LibCrypto::X509_CRL,
                             signer : OpenSSL::X509::Certificate,
                             distribution_url : String?, indirect : Bool) : Bool
        return false unless valid_crl_extensions?(crl)
        return false unless valid_distribution_point?(crl, distribution_url, indirect)
        last_update = LibCrypto.matter_x509_crl_get0_last_update(crl)
        next_update = LibCrypto.matter_x509_crl_get0_next_update(crl)
        return false if last_update.null? || next_update.null?
        return false unless LibCrypto.matter_x509_cmp_current_time(last_update) < 0 &&
                            LibCrypto.matter_x509_cmp_current_time(next_update) > 0
        key = LibCrypto.matter_x509_get_pubkey(signer)
        return false if key.null?
        begin
          LibCrypto.matter_x509_crl_verify(crl, key) == 1
        ensure
          LibCrypto.evp_pkey_free(key)
        end
      end

      private def valid_crl_extensions?(crl : LibCrypto::X509_CRL) : Bool
        return false unless LibCrypto.matter_x509_crl_get_version(crl) == 1
        return false unless LibCrypto.matter_x509_crl_get_signature_nid(crl) ==
                              LibCrypto.obj_txt2nid("ecdsa-with-SHA256")
        akid_count = 0
        number_count = 0
        idp_count = 0
        LibCrypto.matter_x509_crl_get_ext_count(crl).times do |index|
          extension = LibCrypto.matter_x509_crl_get_ext(crl, index)
          nid = LibCrypto.obj_obj2nid(LibCrypto.x509_extension_get_object(extension))
          case nid
          when @authority_key_nid
            akid_count += 1
            return false if LibCrypto.matter_x509_extension_get_critical(extension) == 1
          when @crl_number_nid
            number_count += 1
            return false if LibCrypto.matter_x509_extension_get_critical(extension) == 1
          when @issuing_distribution_point_nid then idp_count += 1
          when @delta_crl_nid                  then return false
          else
            return false if LibCrypto.matter_x509_extension_get_critical(extension) == 1
          end
        end
        akid_count == 1 && number_count == 1 && idp_count <= 1
      end

      private def valid_distribution_point?(crl : LibCrypto::X509_CRL,
                                            expected_url : String?, indirect : Bool) : Bool
        location = LibCrypto.matter_x509_crl_get_ext_by_nid(crl, @issuing_distribution_point_nid, -1)
        return location < 0 unless indirect || expected_url
        return false if location < 0
        critical = 0
        pointer = LibCrypto.matter_x509_crl_get_ext_d2i(crl, @issuing_distribution_point_nid,
          pointerof(critical), nil)
        return false if pointer.null?
        point = pointer.as(LibCrypto::MatterIssuingDistributionPoint*)
        begin
          return false unless critical == 1
          idp = point.value
          return false unless idp.onlyuser == 0 && idp.only_ca == 0 &&
                              idp.only_some_reasons.null? && (idp.indirect_crl != 0) == indirect && idp.only_attr == 0
          return true if expected_url.nil? && indirect && idp.distpoint.null?
          return false if expected_url.nil?
          name = idp.distpoint
          return false if name.null? || name.value.type != 0
          names = name.value.names
          return false if names.null? || LibCrypto.sk_num(names) != 1
          general = LibCrypto.sk_value(names, 0).as(LibCrypto::GENERAL_NAME*)
          return false if general.null? || general.value.type != 6
          uri = general.value.value
          return false if uri.null?
          length = LibCrypto.asn1_string_length(uri)
          return false unless length == expected_url.bytesize
          Slice.new(LibCrypto.asn1_string_get0_data(uri).as(UInt8*), length) == expected_url.to_slice
        ensure
          LibCrypto.matter_issuing_dist_point_free(point)
        end
      end
    end
  end
end
