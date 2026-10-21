require "../spec_helper"
require "../../src/matter/controller"

module AttestationCMSFixture
  extend self

  def der(tag : UInt8, content : Bytes) : Bytes
    io = IO::Memory.new
    io.write_byte(tag)
    io.write(Matter::Codec::DERCodec::Base.encode_length_bytes(content.size))
    io.write(content)
    io.to_slice
  end

  def signed_cd(vendor_id : UInt16, product_id : UInt16, digest : Bytes? = nil,
                content_type : Bytes = Matter::Controller::DeviceAttestationVerifier::DATA_OID,
                include_digest : Bool = true, tamper_signature : Bool = false,
                include_signing_time : Bool = false) : Bytes
    declaration = Matter::Certificate::CertificationDeclaration::CDContent.new(
      format_version: 1_u8, vendor_id: vendor_id, product_ids: [product_id],
      device_type_id: 22_u32, certificate_id: "CSA00000SWC00000-00",
      security_level: 0_u8, security_information: 0_u16,
      version_number: 1_u16, certification_type: 0_u8).to_slice
    verifier = Matter::Crypto::StandardCrypto.new
    content_type_oid = Matter::Controller::DeviceAttestationVerifier::CONTENT_TYPE_ATTRIBUTE_OID
    digest_oid = Matter::Controller::DeviceAttestationVerifier::MESSAGE_DIGEST_ATTRIBUTE_OID
    content_attr = der(0x30_u8, der(0x06_u8, content_type_oid) +
                                der(0x31_u8, der(0x06_u8, content_type)))
    attrs = [content_attr]
    if include_digest
      digest_attr = der(0x30_u8, der(0x06_u8, digest_oid) +
                                 der(0x31_u8, der(0x04_u8, digest || verifier.compute_sha256(declaration))))
      attrs << digest_attr
    end
    if include_signing_time
      signing_time_oid = Bytes[0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x09, 0x05]
      attrs << der(0x30_u8, der(0x06_u8, signing_time_oid) +
                            der(0x31_u8, der(0x17_u8, "261021000000Z".to_slice)))
    end
    attr_content = Slice(UInt8).join(attrs)
    signed_attrs = der(0x31_u8, attr_content)
    signer_private = Matter::Certificate::CertificationDeclaration::TEST_CMS_SIGNER_PRIVATE_KEY.hexbytes
    signer_public = OpenSSL::PKey::EC.from_private_bytes(signer_private,
      Matter::Crypto::CRYPTO_EC_CURVE_NIST).public_key_bytes
    key = Matter::Crypto.private_key(Matter::Crypto::BinaryKeyPair.new(signer_public, signer_private))
    signature = Matter::Crypto.sign_ecdsa(key, signed_attrs, "der")
    signature[signature.size - 1] ^= 1_u8 if tamper_signature
    codec = Matter::Codec::DERCodec::Base
    digest_algorithm = codec.encode(Matter::Codec::DERCodec::SHA256_CMS.call)
    signature_algorithm = codec.encode(Matter::Codec::DERCodec::ECDSA_WITH_SHA256_X962.call)
    ski = Matter::Certificate::CertificationDeclaration::TEST_CMS_SIGNER_SKI.hexbytes
    signer = der(0x30_u8, Slice(UInt8).join([
      codec.encode(3_u8), der(0x80_u8, ski), digest_algorithm,
      der(0xa0_u8, attr_content), signature_algorithm, der(0x04_u8, signature),
    ]))
    data_oid = Matter::Controller::DeviceAttestationVerifier::DATA_OID
    encapsulated = der(0x30_u8, der(0x06_u8, data_oid) + der(0xa0_u8, der(0x04_u8, declaration)))
    signed = der(0x30_u8, Slice(UInt8).join([
      codec.encode(3_u8), der(0x31_u8, digest_algorithm), encapsulated, der(0x31_u8, signer),
    ]))
    der(0x30_u8, der(0x06_u8, Matter::Controller::DeviceAttestationVerifier::SIGNED_DATA_OID) +
                 der(0xa0_u8, signed))
  end
end

describe Matter::Controller::DeviceAttestationVerifier do
  vendor_id = 0xFFF1_u16
  product_id = 0x8000_u16
  good_revocation = ->(_dac : Bytes, _pai : Bytes, _paa : Bytes) {
    Matter::Controller::RevocationStatus::Good
  }

  it "accepts an explicitly trusted test chain, CD signer, nonce, and PASE signature" do
    manager = Matter::Certificate::AttestationCertificateManager.new(vendor_id)
    dac, dac_key = manager.get_dac_cert(product_id)
    signer_private = Matter::Certificate::CertificationDeclaration::TEST_CMS_SIGNER_PRIVATE_KEY.hexbytes
    signer_public = OpenSSL::PKey::EC.from_private_bytes(signer_private,
      Matter::Crypto::CRYPTO_EC_CURVE_NIST).public_key_bytes
    ski = Matter::Certificate::CertificationDeclaration::TEST_CMS_SIGNER_SKI
    trust = Matter::Controller::AttestationTrustStore.new([manager.paa_cert],
      {ski => signer_public}, allow_test_attestation: true,
      revocation_check: good_revocation)
    verifier = Matter::Controller::DeviceAttestationVerifier.new(trust)
    nonce = Bytes.new(32, 0x41_u8)
    challenge = Bytes.new(16, 0x42_u8)
    cd = Matter::Certificate::CertificationDeclaration.generate(vendor_id, product_id)
    elements = Matter::Commissioning::CredentialService::AttestationElements.new(cd, nonce, 0_u32).to_slice
    signature = Matter::Crypto.sign_ecdsa(dac_key, elements + challenge)

    verifier.verify_attestation(dac, manager.pai_cert, elements, signature,
      nonce, challenge, vendor_id, product_id).should eq(dac_key.public_key)
    expect_raises(Matter::AuthenticationError) do
      verifier.verify_attestation(dac, manager.pai_cert, elements, signature,
        Bytes.new(32, 0x43_u8), challenge, vendor_id, product_id)
    end
    expect_raises(Matter::AuthenticationError) do
      verifier.verify_attestation(dac, manager.pai_cert, elements, signature,
        nonce, Bytes.new(16, 0x43_u8), vendor_id, product_id)
    end
    no_revocation_source = Matter::Controller::DeviceAttestationVerifier.new(
      Matter::Controller::AttestationTrustStore.new([manager.paa_cert],
        {ski => signer_public}, allow_test_attestation: true))
    expect_raises(Matter::AuthenticationError, /revocation status is Unavailable/) do
      no_revocation_source.verify_attestation(dac, manager.pai_cert, elements, signature,
        nonce, challenge, vendor_id, product_id)
    end
  end

  it "rejects unconfigured PAA and CD signer trust" do
    manager = Matter::Certificate::AttestationCertificateManager.new(vendor_id)
    dac, dac_key = manager.get_dac_cert(product_id)
    nonce = Bytes.new(32, 0x41_u8)
    challenge = Bytes.new(16, 0x42_u8)
    cd = Matter::Certificate::CertificationDeclaration.generate(vendor_id, product_id)
    elements = Matter::Commissioning::CredentialService::AttestationElements.new(cd, nonce, 0_u32).to_slice
    signature = Matter::Crypto.sign_ecdsa(dac_key, elements + challenge)
    verifier = Matter::Controller::DeviceAttestationVerifier.new(
      Matter::Controller::AttestationTrustStore.new([] of Bytes, {} of String => Bytes))
    expect_raises(Matter::AuthenticationError) do
      verifier.verify_attestation(dac, manager.pai_cert, elements, signature,
        nonce, challenge, vendor_id, product_id)
    end
    signer_private = Matter::Certificate::CertificationDeclaration::TEST_CMS_SIGNER_PRIVATE_KEY.hexbytes
    signer_public = OpenSSL::PKey::EC.from_private_bytes(signer_private,
      Matter::Crypto::CRYPTO_EC_CURVE_NIST).public_key_bytes
    ski = Matter::Certificate::CertificationDeclaration::TEST_CMS_SIGNER_SKI
    test_root_without_opt_in = Matter::Controller::DeviceAttestationVerifier.new(
      Matter::Controller::AttestationTrustStore.new([manager.paa_cert], {ski => signer_public}))
    expect_raises(Matter::AuthenticationError, /trusted PAA/) do
      test_root_without_opt_in.verify_attestation(dac, manager.pai_cert, elements, signature,
        nonce, challenge, vendor_id, product_id)
    end
  end

  it "verifies CMS signed attributes and rejects signed but mismatched content metadata" do
    manager = Matter::Certificate::AttestationCertificateManager.new(vendor_id)
    dac, dac_key = manager.get_dac_cert(product_id)
    signer_private = Matter::Certificate::CertificationDeclaration::TEST_CMS_SIGNER_PRIVATE_KEY.hexbytes
    signer_public = OpenSSL::PKey::EC.from_private_bytes(signer_private,
      Matter::Crypto::CRYPTO_EC_CURVE_NIST).public_key_bytes
    ski = Matter::Certificate::CertificationDeclaration::TEST_CMS_SIGNER_SKI
    verifier = Matter::Controller::DeviceAttestationVerifier.new(
      Matter::Controller::AttestationTrustStore.new([manager.paa_cert],
        {ski => signer_public}, allow_test_attestation: true,
        revocation_check: good_revocation))
    nonce = Bytes.new(32, 0x41_u8)
    challenge = Bytes.new(16, 0x42_u8)
    verify_cd = ->(cd : Bytes) {
      elements = Matter::Commissioning::CredentialService::AttestationElements.new(cd, nonce, 0_u32).to_slice
      signature = Matter::Crypto.sign_ecdsa(dac_key, elements + challenge)
      verifier.verify_attestation(dac, manager.pai_cert, elements, signature,
        nonce, challenge, vendor_id, product_id)
    }
    verify_cd.call(AttestationCMSFixture.signed_cd(vendor_id, product_id)).should eq(dac_key.public_key)
    verify_cd.call(AttestationCMSFixture.signed_cd(vendor_id, product_id,
      include_signing_time: true)).should eq(dac_key.public_key)
    expect_raises(Matter::AuthenticationError, /digest/) do
      verify_cd.call(AttestationCMSFixture.signed_cd(vendor_id, product_id, Bytes.new(32, 0x11_u8)))
    end
    expect_raises(Matter::AuthenticationError, /content type/) do
      verify_cd.call(AttestationCMSFixture.signed_cd(vendor_id, product_id,
        content_type: Matter::Controller::DeviceAttestationVerifier::SIGNED_DATA_OID))
    end
    expect_raises(Matter::AuthenticationError, /incomplete/) do
      verify_cd.call(AttestationCMSFixture.signed_cd(vendor_id, product_id, include_digest: false))
    end
    expect_raises(Matter::AuthenticationError) do
      verify_cd.call(AttestationCMSFixture.signed_cd(vendor_id, product_id, tamper_signature: true))
    end
  end

  it "rejects a CD with an unknown signer, a mismatched product, and a tampered signature" do
    manager = Matter::Certificate::AttestationCertificateManager.new(vendor_id)
    dac, dac_key = manager.get_dac_cert(product_id)
    nonce = Bytes.new(32, 0x41_u8)
    challenge = Bytes.new(16, 0x42_u8)
    signer_private = Matter::Certificate::CertificationDeclaration::TEST_CMS_SIGNER_PRIVATE_KEY.hexbytes
    signer_public = OpenSSL::PKey::EC.from_private_bytes(signer_private,
      Matter::Crypto::CRYPTO_EC_CURVE_NIST).public_key_bytes
    ski = Matter::Certificate::CertificationDeclaration::TEST_CMS_SIGNER_SKI
    verifier = Matter::Controller::DeviceAttestationVerifier.new(
      Matter::Controller::AttestationTrustStore.new([manager.paa_cert],
        {ski => signer_public}, allow_test_attestation: true,
        revocation_check: good_revocation))
    wrong_cd = Matter::Certificate::CertificationDeclaration.generate(vendor_id, product_id + 1_u16)
    elements = Matter::Commissioning::CredentialService::AttestationElements.new(wrong_cd, nonce, 0_u32).to_slice
    signature = Matter::Crypto.sign_ecdsa(dac_key, elements + challenge)
    expect_raises(Matter::AuthenticationError, /Declaration/) do
      verifier.verify_attestation(dac, manager.pai_cert, elements, signature,
        nonce, challenge, vendor_id, product_id)
    end
    verifier = Matter::Controller::DeviceAttestationVerifier.new(
      Matter::Controller::AttestationTrustStore.new([manager.paa_cert],
        {} of String => Bytes, allow_test_attestation: true,
        revocation_check: good_revocation))
    expect_raises(Matter::AuthenticationError, /signer/) do
      verifier.verify_attestation(dac, manager.pai_cert, elements, signature,
        nonce, challenge, vendor_id, product_id)
    end
    valid_cd = Matter::Certificate::CertificationDeclaration.generate(vendor_id, product_id)
    valid_elements = Matter::Commissioning::CredentialService::AttestationElements.new(valid_cd, nonce, 0_u32).to_slice
    bad_signature = Matter::Crypto.sign_ecdsa(dac_key, valid_elements + challenge).dup
    bad_signature[0] ^= 1_u8
    trusted = Matter::Controller::DeviceAttestationVerifier.new(
      Matter::Controller::AttestationTrustStore.new([manager.paa_cert],
        {ski => signer_public}, allow_test_attestation: true,
        revocation_check: good_revocation))
    expect_raises(Matter::Error) do
      trusted.verify_attestation(dac, manager.pai_cert, valid_elements, bad_signature,
        nonce, challenge, vendor_id, product_id)
    end
  end

  it "authenticates CSR nonce, DAC signature, and PKCS#10 proof of possession" do
    crypto = Matter::Crypto::StandardCrypto.new
    dac_key = Matter::Crypto::Key.generate_key_pair
    operational_key = Matter::Crypto::Key.generate_key_pair
    nonce = Bytes.new(32, 0x51_u8)
    challenge = Bytes.new(16, 0x52_u8)
    csr = Matter::Crypto::Pkcs10.create(operational_key, crypto)
    elements = Matter::Commissioning::CredentialService::CSRElements.new(csr, nonce).to_slice
    signature = Matter::Crypto.sign_ecdsa(dac_key, elements + challenge)
    response = Matter::Cluster::OperationalCredentials::Tlv::CsrResponse.new(elements, signature)
    verifier = Matter::Controller::DeviceAttestationVerifier.new(
      Matter::Controller::AttestationTrustStore.new([] of Bytes, {} of String => Bytes), crypto)
    verifier.verify_csr(response, nonce, challenge, dac_key.public_key).should eq(operational_key.public_key)
    expect_raises(Matter::AuthenticationError, /nonce/) do
      verifier.verify_csr(response, Bytes.new(32, 0x53_u8), challenge, dac_key.public_key)
    end
    expect_raises(Matter::Error) do
      verifier.verify_csr(response, nonce, Bytes.new(16, 0x53_u8), dac_key.public_key)
    end
  end
end
