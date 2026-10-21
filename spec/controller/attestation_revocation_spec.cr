require "../spec_helper"
require "../../src/matter/controller"
require "file_utils"

private module AttestationCrlFixture
  extend self

  def generate(issuer_der : Bytes, issuer_key : Matter::Crypto::Key,
               revoked_der : Bytes? = nil, stale : Bool = false) : Bytes
    directory = File.join(Dir.tempdir, "matter-crl-#{Random::Secure.hex(8)}")
    Dir.mkdir(directory)
    Dir.mkdir(File.join(directory, "newcerts"))
    begin
      issuer = OpenSSL::X509::Certificate.from_der(issuer_der)
      File.write(File.join(directory, "issuer.pem"), issuer.to_pem)
      key = OpenSSL::PKey::EC.from_private_bytes(issuer_key.private_key,
        Matter::Crypto::CRYPTO_EC_CURVE_NIST)
      File.write(File.join(directory, "key.pem"), key.to_pem)
      File.write(File.join(directory, "index.txt"), "")
      File.write(File.join(directory, "serial"), "01\n")
      File.write(File.join(directory, "crlnumber"), "01\n")
      File.write(File.join(directory, "ca.cnf"), <<-CONFIG)
        [ ca ]
        default_ca = CA_default
        [ CA_default ]
        database = #{directory}/index.txt
        new_certs_dir = #{directory}/newcerts
        serial = #{directory}/serial
        crlnumber = #{directory}/crlnumber
        default_md = sha256
        default_crl_days = 30
        policy = policy_any
        crl_extensions = crl_ext
        [ policy_any ]
        commonName = supplied
        [ crl_ext ]
        authorityKeyIdentifier = keyid:always
        CONFIG
      if revoked_der
        File.write(File.join(directory, "revoked.pem"),
          OpenSSL::X509::Certificate.from_der(revoked_der).to_pem)
        openssl(directory, ["ca", "-revoke", File.join(directory, "revoked.pem")])
      end
      args = ["ca", "-gencrl", "-out", File.join(directory, "crl.pem")]
      if stale
        args.concat(["-crl_lastupdate", "20200101000000Z", "-crl_nextupdate", "20200102000000Z"])
      end
      openssl(directory, args)
      openssl(directory, ["crl", "-in", File.join(directory, "crl.pem"),
                          "-outform", "DER", "-out", File.join(directory, "crl.der")])
      File.read(File.join(directory, "crl.der")).to_slice
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  private def openssl(directory : String, args : Array(String)) : Nil
    command = args.dup
    if args.first == "ca"
      command.concat(["-config", File.join(directory, "ca.cnf"),
                      "-keyfile", File.join(directory, "key.pem"),
                      "-cert", File.join(directory, "issuer.pem"), "-batch"])
    end
    output = IO::Memory.new
    status = Process.run("openssl", command, output: output, error: output)
    raise Matter::ConfigurationError.new("openssl #{args.first} failed: #{output}") unless status.success?
  end
end

describe Matter::Controller::OfflineAttestationRevocation do
  it "requires current direct CRLs for both issuers and finds revoked PAI and DAC serials" do
    manager = Matter::Certificate::AttestationCertificateManager.new(0xFFF1_u16)
    dac, dac_key = manager.get_dac_cert(0x8000_u16)
    paa = manager.paa_cert
    pai = manager.pai_cert
    good_paa = AttestationCrlFixture.generate(paa, manager.paa_key_pair)
    good_pai = AttestationCrlFixture.generate(pai, manager.pai_key_pair)
    provider = Matter::Controller::OfflineAttestationRevocation.new([good_paa, good_pai])
    provider.callback.call(dac, pai, paa).should eq(Matter::Controller::RevocationStatus::Good)
    cd_private = Matter::Certificate::CertificationDeclaration::TEST_CMS_SIGNER_PRIVATE_KEY.hexbytes
    cd_public = OpenSSL::PKey::EC.from_private_bytes(cd_private,
      Matter::Crypto::CRYPTO_EC_CURVE_NIST).public_key_bytes
    trust = Matter::Controller::AttestationTrustStore.new([paa],
      {Matter::Certificate::CertificationDeclaration::TEST_CMS_SIGNER_SKI => cd_public},
      allow_test_attestation: true, revocation_check: provider.callback)
    verifier = Matter::Controller::DeviceAttestationVerifier.new(trust)
    nonce = Bytes.new(32, 0x41_u8)
    challenge = Bytes.new(16, 0x42_u8)
    cd = Matter::Certificate::CertificationDeclaration.generate(0xFFF1_u16, 0x8000_u16)
    elements = Matter::Commissioning::CredentialService::AttestationElements.new(cd, nonce, 0_u32).to_slice
    second_dac, second_key = manager.get_dac_cert(0x8000_u16)
    second_signature = Matter::Crypto.sign_ecdsa(second_key, elements + challenge)
    verifier.verify_attestation(second_dac, pai, elements, second_signature,
      nonce, challenge, 0xFFF1_u16, 0x8000_u16).should eq(second_key.public_key)
    Matter::Controller::OfflineAttestationRevocation.new([good_paa]).check(dac, pai, paa)
      .should eq(Matter::Controller::RevocationStatus::Unavailable)

    revoked_paa = AttestationCrlFixture.generate(paa, manager.paa_key_pair, pai)
    Matter::Controller::OfflineAttestationRevocation.new([revoked_paa, good_pai]).check(dac, pai, paa)
      .should eq(Matter::Controller::RevocationStatus::Revoked)
    revoked_pai = AttestationCrlFixture.generate(pai, manager.pai_key_pair, dac)
    Matter::Controller::OfflineAttestationRevocation.new([good_paa, revoked_pai]).check(dac, pai, paa)
      .should eq(Matter::Controller::RevocationStatus::Revoked)
    revoked_trust = Matter::Controller::AttestationTrustStore.new([paa],
      {Matter::Certificate::CertificationDeclaration::TEST_CMS_SIGNER_SKI => cd_public},
      allow_test_attestation: true,
      revocation_check: Matter::Controller::OfflineAttestationRevocation.new([good_paa, revoked_pai]).callback)
    revoked_signature = Matter::Crypto.sign_ecdsa(dac_key, elements + challenge)
    expect_raises(Matter::AuthenticationError, /revocation status is Revoked/) do
      Matter::Controller::DeviceAttestationVerifier.new(revoked_trust).verify_attestation(
        dac, pai, elements, revoked_signature, nonce, challenge, 0xFFF1_u16, 0x8000_u16)
    end

    stale = AttestationCrlFixture.generate(pai, manager.pai_key_pair, stale: true)
    Matter::Controller::OfflineAttestationRevocation.new([good_paa, stale]).check(dac, pai, paa)
      .should eq(Matter::Controller::RevocationStatus::Unavailable)
    forged = good_pai.dup
    forged[forged.size - 1] ^= 1_u8
    Matter::Controller::OfflineAttestationRevocation.new([good_paa, forged]).check(dac, pai, paa)
      .should eq(Matter::Controller::RevocationStatus::Unavailable)
  end
end
