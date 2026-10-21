require "../spec_helper"
require "../../src/matter/controller"
require "file_utils"

private module AttestationCrlFixture
  extend self

  def generate(issuer_der : Bytes, issuer_key : Matter::Crypto::Key,
               revoked_der : Bytes? = nil, stale : Bool = false,
               numbered : Bool = true, distribution_url : String? = nil,
               distribution_critical : Bool = true) : Bytes
    directory = File.join(Dir.tempdir, "matter-crl-#{Random::Secure.hex(8)}")
    Dir.mkdir(directory)
    Dir.mkdir(File.join(directory, "newcerts"))
    begin
      config_directory = directory.gsub('\\', '/')
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
        database = #{config_directory}/index.txt
        new_certs_dir = #{config_directory}/newcerts
        serial = #{config_directory}/serial
        #{numbered ? "crlnumber = #{config_directory}/crlnumber" : ""}
        default_md = sha256
        default_crl_days = 30
        policy = policy_any
        crl_extensions = crl_ext
        [ policy_any ]
        commonName = supplied
        [ crl_ext ]
        authorityKeyIdentifier = keyid:always
        #{distribution_url ? "issuingDistributionPoint = #{distribution_critical ? "critical," : ""}@idp" : ""}
        [ idp ]
        #{distribution_url ? "fullname = URI:#{distribution_url}" : ""}
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

private class TestDclRevocationSource < Matter::Controller::DclRevocationSource
  property points = {} of String => Array(Matter::Controller::DclRevocationPoint)

  def points_for(issuer_skid : Bytes) : Array(Matter::Controller::DclRevocationPoint)
    @points[issuer_skid.hexstring]? || [] of Matter::Controller::DclRevocationPoint
  end
end

private def dcl_point(cert_der : Bytes, crl : Bytes, is_paa : Bool,
                      url : String = "https://crl.example/issuer.crl") : Matter::Controller::DclRevocationPoint
  cert = OpenSSL::X509::Certificate.from_der(cert_der)
  key_id = LibCrypto.x509_get0_subject_key_id(cert)
  length = LibCrypto.asn1_string_length(key_id)
  skid = Slice.new(LibCrypto.asn1_string_get0_data(key_id).as(UInt8*), length).dup
  digest = OpenSSL::Digest.new("SHA256").update(crl).final
  Matter::Controller::DclRevocationPoint.new(skid, cert_der, nil, url, is_paa,
    crl.size.to_i64, digest, 0xFFF1_u16, "primary")
end

describe Matter::Controller::DclAttestationRevocation do
  it "parses the DCL issuer index from an explicit HTTPS gateway" do
    manager = Matter::Certificate::AttestationCertificateManager.new(0xFFF1_u16)
    paa = manager.paa_cert
    crl = AttestationCrlFixture.generate(paa, manager.paa_key_pair)
    point = dcl_point(paa, crl, true)
    calls = [] of String
    record = {
      "issuerSubjectKeyID"   => point.issuer_skid.hexstring.upcase,
      "crlSignerCertificate" => OpenSSL::X509::Certificate.from_der(paa).to_pem,
      "crlSignerDelegator"   => "",
      "dataURL"              => point.url,
      "dataFileSize"         => "0",
      "dataDigest"           => "",
      "dataDigestType"       => 0,
      "revocationType"       => 1,
      "isPAA"                => true,
      "vid"                  => 0xFFF1,
      "pid"                  => 0,
      "label"                => "primary",
    }
    response = {"pkiRevocationDistributionPointsByIssuerSubjectKeyID" => {"points" => [record]}}.to_json
    source = Matter::Controller::HttpDclRevocationSource.new("https://dcl.example/",
      ->(url : String) { calls << url; response.to_slice })
    source.points_for(point.issuer_skid).first.should eq(point.copy_with(size: nil, sha256: nil,
      vendor_id: 0xFFF1_u16, label: "primary"))
    calls.should eq(["https://dcl.example/dcl/pki/revocation-points/#{point.issuer_skid.hexstring.upcase}"])
    expect_raises(Matter::ConfigurationError) do
      Matter::Controller::HttpDclRevocationSource.new("http://dcl.example")
    end
    record["dataDigestType"] = 7
    response = {"pkiRevocationDistributionPointsByIssuerSubjectKeyID" => {"points" => [record]}}.to_json
    expect_raises(Matter::AuthenticationError, /digest/) { source.points_for(point.issuer_skid) }
    record["dataDigestType"] = 0
    record["dataFileSize"] = "100"
    response = {"pkiRevocationDistributionPointsByIssuerSubjectKeyID" => {"points" => [record]}}.to_json
    expect_raises(Matter::AuthenticationError, /size metadata/) { source.points_for(point.issuer_skid) }
  end

  it "accepts complete direct signed CRLs and rejects revoked devices" do
    manager = Matter::Certificate::AttestationCertificateManager.new(0xFFF1_u16)
    dac, _ = manager.get_dac_cert(0x8000_u16)
    paa = manager.paa_cert
    pai = manager.pai_cert
    paa_crl = AttestationCrlFixture.generate(paa, manager.paa_key_pair)
    pai_crl = AttestationCrlFixture.generate(pai, manager.pai_key_pair)
    source = TestDclRevocationSource.new
    paa_point = dcl_point(paa, paa_crl, true)
    pai_point = dcl_point(pai, pai_crl, false, "https://crl.example/pai.crl")
    source.points[paa_point.issuer_skid.hexstring] = [paa_point]
    source.points[pai_point.issuer_skid.hexstring] = [pai_point]
    crls = {paa_point.url => paa_crl, pai_point.url => pai_crl}
    provider = Matter::Controller::DclAttestationRevocation.new(source, Set{"crl.example"},
      ->(url : String) { crls[url] })
    provider.callback.call(dac, pai, paa).should eq(Matter::Controller::RevocationStatus::Good)
    revoked = AttestationCrlFixture.generate(pai, manager.pai_key_pair, dac)
    revoked_point = dcl_point(pai, revoked, false, pai_point.url)
    source.points[pai_point.issuer_skid.hexstring] = [revoked_point]
    crls[pai_point.url] = revoked
    provider.check(dac, pai, paa).should eq(Matter::Controller::RevocationStatus::Revoked)
  end

  it "requires and combines every partition of a PAI revocation set" do
    manager = Matter::Certificate::AttestationCertificateManager.new(0xFFF1_u16)
    dac, _ = manager.get_dac_cert(0x8000_u16)
    paa = manager.paa_cert
    pai = manager.pai_cert
    paa_crl = AttestationCrlFixture.generate(paa, manager.paa_key_pair)
    first_url = "https://crl.example/part-a.crl"
    second_url = "https://crl.example/part-b.crl"
    first_crl = AttestationCrlFixture.generate(pai, manager.pai_key_pair,
      distribution_url: first_url)
    second_crl = AttestationCrlFixture.generate(pai, manager.pai_key_pair, dac,
      distribution_url: second_url)
    source = TestDclRevocationSource.new
    paa_point = dcl_point(paa, paa_crl, true)
    first_point = dcl_point(pai, first_crl, false, first_url)
      .copy_with(vendor_id: 0xFFF1_u16, label: "first")
    second_point = dcl_point(pai, second_crl, false, second_url)
      .copy_with(vendor_id: 0xFFF1_u16, label: "second")
    source.points[paa_point.issuer_skid.hexstring] = [paa_point]
    source.points[first_point.issuer_skid.hexstring] = [first_point, second_point]
    crls = {paa_point.url => paa_crl, first_url => first_crl, second_url => second_crl}
    provider = Matter::Controller::DclAttestationRevocation.new(source, Set{"crl.example"},
      ->(url : String) { crls[url] })

    provider.check(dac, pai, paa).should eq(Matter::Controller::RevocationStatus::Revoked)
    mismatched_url = "https://crl.example/other.crl"
    source.points[first_point.issuer_skid.hexstring] = [first_point,
                                                        second_point.copy_with(url: mismatched_url)]
    crls[mismatched_url] = second_crl
    provider.check(dac, pai, paa).should eq(Matter::Controller::RevocationStatus::Unavailable)
    noncritical_crl = AttestationCrlFixture.generate(pai, manager.pai_key_pair, dac,
      distribution_url: second_url, distribution_critical: false)
    source.points[first_point.issuer_skid.hexstring] = [first_point,
                                                        dcl_point(pai, noncritical_crl, false, second_url)
                                                          .copy_with(vendor_id: 0xFFF1_u16, label: "second")]
    crls[second_url] = noncritical_crl
    provider.check(dac, pai, paa).should eq(Matter::Controller::RevocationStatus::Unavailable)
    crls[second_url] = second_crl
    wrong_issuer_point = dcl_point(pai, paa_crl, false, second_url)
      .copy_with(vendor_id: 0xFFF1_u16, label: "second")
    source.points[first_point.issuer_skid.hexstring] = [first_point, wrong_issuer_point]
    crls[second_url] = paa_crl
    provider.check(dac, pai, paa).should eq(Matter::Controller::RevocationStatus::Unavailable)
    crls[second_url] = second_crl
    source.points[first_point.issuer_skid.hexstring] = [first_point]
    provider.check(dac, pai, paa).should eq(Matter::Controller::RevocationStatus::Unavailable)
    source.points[first_point.issuer_skid.hexstring] = [first_point,
                                                        second_point.copy_with(url: first_url)]
    provider.check(dac, pai, paa).should eq(Matter::Controller::RevocationStatus::Unavailable)
    source.points[first_point.issuer_skid.hexstring] = [first_point,
                                                        second_point.copy_with(label: "first")]
    provider.check(dac, pai, paa).should eq(Matter::Controller::RevocationStatus::Unavailable)
  end

  it "validates PAA and PAI delegated signers against their issuing authorities" do
    fixture = ->(name : String) { File.read(File.join(__DIR__, "../fixtures/attestation_crl", name)).to_slice }
    paa = fixture.call("Chip-Test-PAA-FFF1-Cert.der")
    pai = fixture.call("Chip-Test-PAI-FFF1-01-Cert.der")
    dac = fixture.call("Chip-Test-DAC-FFF1-8001-Signed-By-Test-PAI-01-Cert.der")
    paa_delegate = fixture.call("Chip-Test-PAA-Delegate-FFF1-Cert.der")
    pai_delegate = fixture.call("Chip-Test-PAI-Delegate-FFF1-01-Cert.der")
    paa_crl = fixture.call("Chip-Test-PAA-FFF1-Delegated-CRL.der")
    pai_crl = fixture.call("Chip-Test-PAI-FFF1-Delegated-CRL.der")
    paa_point = dcl_point(paa, paa_crl, true, "https://example.com/paa-delegated-crl.der")
      .copy_with(crl_signer_der: paa_delegate)
    pai_point = dcl_point(pai, pai_crl, false, "https://example.com/pai-delegated-crl.der")
      .copy_with(crl_signer_der: pai_delegate, crl_signer_delegator_der: pai)
    source = TestDclRevocationSource.new
    source.points[paa_point.issuer_skid.hexstring] = [paa_point]
    source.points[pai_point.issuer_skid.hexstring] = [pai_point]
    crls = {paa_point.url => paa_crl, pai_point.url => pai_crl}
    provider = Matter::Controller::DclAttestationRevocation.new(source, Set{"example.com"},
      ->(url : String) { crls[url] })

    provider.check(dac, pai, paa).should eq(Matter::Controller::RevocationStatus::Revoked)
    inherited = fixture.call("Chip-Test-PAI-FFF1-Delegated-CRL-Only-First-Entry-With-Issuer-Ext.der")
    inherited_point = dcl_point(pai, inherited, false, pai_point.url)
      .copy_with(crl_signer_der: pai_delegate, crl_signer_delegator_der: pai)
    source.points[pai_point.issuer_skid.hexstring] = [inherited_point]
    crls[pai_point.url] = inherited
    # Exercise the CRL issuer filter in isolation; the production callback
    # receives a chain already authenticated by DeviceAttestationVerifier.
    changed_serial = OpenSSL::X509::Certificate.from_der(dac)
    changed_serial.serial = OpenSSL::BN.new(0x0EFCBECBABCD3CD9_u64)
    provider.check(changed_serial.to_der, pai, paa).should eq(Matter::Controller::RevocationStatus::Good)
    source.points[pai_point.issuer_skid.hexstring] = [pai_point]
    crls[pai_point.url] = pai_crl
    pai_three = fixture.call("Chip-Test-PAI-FFF1-03-Cert.der")
    dac_three = fixture.call("Chip-Test-DAC-01-FFF1-8001-Signed-By-Test-PAI-03-Cert.der")
    pai_three_crl = fixture.call("Chip-Test-PAI-FFF1-03-Direct-CRL.der")
    pai_three_point = dcl_point(pai_three, pai_three_crl, false,
      "https://example.com/pai-three-direct-crl.der")
    source.points[pai_point.issuer_skid.hexstring] = [] of Matter::Controller::DclRevocationPoint
    source.points[pai_three_point.issuer_skid.hexstring] = [pai_three_point]
    crls[pai_three_point.url] = pai_three_crl
    provider.check(dac_three, pai_three, paa).should eq(Matter::Controller::RevocationStatus::Revoked)
    source.points[pai_three_point.issuer_skid.hexstring] = [] of Matter::Controller::DclRevocationPoint
    source.points[pai_point.issuer_skid.hexstring] = [pai_point]
    source.points[pai_point.issuer_skid.hexstring] = [pai_point.copy_with(crl_signer_delegator_der: paa)]
    provider.check(dac, pai, paa).should eq(Matter::Controller::RevocationStatus::Unavailable)
    source.points[pai_point.issuer_skid.hexstring] = [pai_point.copy_with(vendor_id: 0x0001_u16)]
    provider.check(dac, pai, paa).should eq(Matter::Controller::RevocationStatus::Unavailable)
  end

  it "fails closed on missing, duplicate, mismatched, unapproved, or altered CRLs" do
    manager = Matter::Certificate::AttestationCertificateManager.new(0xFFF1_u16)
    dac, _ = manager.get_dac_cert(0x8000_u16)
    paa = manager.paa_cert
    pai = manager.pai_cert
    paa_crl = AttestationCrlFixture.generate(paa, manager.paa_key_pair)
    pai_crl = AttestationCrlFixture.generate(pai, manager.pai_key_pair)
    source = TestDclRevocationSource.new
    paa_point = dcl_point(paa, paa_crl, true)
    pai_point = dcl_point(pai, pai_crl, false, "https://crl.example/pai.crl")
    source.points[paa_point.issuer_skid.hexstring] = [paa_point]
    source.points[pai_point.issuer_skid.hexstring] = [pai_point]
    crls = {paa_point.url => paa_crl, pai_point.url => pai_crl}
    provider = Matter::Controller::DclAttestationRevocation.new(source, Set{"crl.example"},
      ->(url : String) { crls[url] })
    source.points[pai_point.issuer_skid.hexstring] = [] of Matter::Controller::DclRevocationPoint
    provider.check(dac, pai, paa).should eq(Matter::Controller::RevocationStatus::Unavailable)
    source.points[pai_point.issuer_skid.hexstring] = [pai_point, pai_point]
    provider.check(dac, pai, paa).should eq(Matter::Controller::RevocationStatus::Unavailable)
    source.points[pai_point.issuer_skid.hexstring] = [pai_point.copy_with(crl_signer_delegator_der: paa)]
    provider.check(dac, pai, paa).should eq(Matter::Controller::RevocationStatus::Unavailable)
    source.points[pai_point.issuer_skid.hexstring] = [pai_point.copy_with(url: "http://127.0.0.1/private")]
    provider.check(dac, pai, paa).should eq(Matter::Controller::RevocationStatus::Unavailable)
    http_paa = paa_point.copy_with(url: "http://crl.example/issuer.crl")
    http_pai = pai_point.copy_with(url: "http://crl.example/pai.crl")
    source.points[paa_point.issuer_skid.hexstring] = [http_paa]
    source.points[pai_point.issuer_skid.hexstring] = [http_pai]
    crls[http_paa.url] = paa_crl
    crls[http_pai.url] = pai_crl
    provider.check(dac, pai, paa).should eq(Matter::Controller::RevocationStatus::Unavailable)
    http_provider = Matter::Controller::DclAttestationRevocation.new(source, Set(String).new,
      ->(url : String) { crls[url] }, allowed_http_crl_hosts: Set{"crl.example"})
    http_provider.check(dac, pai, paa).should eq(Matter::Controller::RevocationStatus::Good)
    source.points[pai_point.issuer_skid.hexstring] = [http_pai.copy_with(url: "http://crl.example:8080/private")]
    http_provider.check(dac, pai, paa).should eq(Matter::Controller::RevocationStatus::Unavailable)
    source.points[paa_point.issuer_skid.hexstring] = [paa_point]
    source.points[pai_point.issuer_skid.hexstring] = [pai_point]
    source.points[pai_point.issuer_skid.hexstring] = [pai_point.copy_with(url: "https://crl.example:8443/private")]
    provider.check(dac, pai, paa).should eq(Matter::Controller::RevocationStatus::Unavailable)
    source.points[pai_point.issuer_skid.hexstring] = [pai_point]
    crls[pai_point.url] = Bytes[0x30]
    provider.check(dac, pai, paa).should eq(Matter::Controller::RevocationStatus::Unavailable)
    crls[pai_point.url] = pai_crl
    source.points[pai_point.issuer_skid.hexstring] = [pai_point.copy_with(sha256: Bytes.new(32, 0_u8))]
    provider.check(dac, pai, paa).should eq(Matter::Controller::RevocationStatus::Unavailable)
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
    unnumbered = AttestationCrlFixture.generate(pai, manager.pai_key_pair, numbered: false)
    Matter::Controller::OfflineAttestationRevocation.new([good_paa, unnumbered]).check(dac, pai, paa)
      .should eq(Matter::Controller::RevocationStatus::Unavailable)
    forged = good_pai.dup
    forged[forged.size - 1] ^= 1_u8
    Matter::Controller::OfflineAttestationRevocation.new([good_paa, forged]).check(dac, pai, paa)
      .should eq(Matter::Controller::RevocationStatus::Unavailable)
  end
end
