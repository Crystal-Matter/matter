require "../spec_helper"
require "../../src/matter/controller"

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
