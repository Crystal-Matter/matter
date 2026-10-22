require "./e2e_helper"

# An official chip-tool CASE peer exercises the opt-in revision-1 cluster.
# The certificate is generated in the test runner so no private key fixture is
# copied into the device image.
module TlsCertificateE2E
  CLUSTER = "tlscertificatemanagement"

  def self.root_certificate : Bytes
    key = Matter::Crypto::Key.generate_key_pair
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = OpenSSL::BN.new(1)
    cert.not_before = OpenSSL::ASN1::Time.days_from_now(-1)
    cert.not_after = OpenSSL::ASN1::Time.days_from_now(365)
    name = OpenSSL::X509::Name.new
    name.add_entry("CN", "Matter TLS E2E root")
    cert.subject = name
    cert.issuer = name
    cert.public_key = OpenSSL::PKey::EC.from_public_bytes(key.public_key, Matter::Crypto::CRYPTO_EC_CURVE_NIST)
    cert.add_extension(OpenSSL::X509::Extension.new("basicConstraints", "critical,CA:TRUE"))
    signer = OpenSSL::PKey::EC.from_private_bytes(key.private_key, Matter::Crypto::CRYPTO_EC_CURVE_NIST)
    cert.sign(signer, OpenSSL::Digest.new("SHA256"))
    cert.to_der
  end
end

describe "official SDK TLS Certificate Management" do
  device = E2E::Device["matter_tls_certificate_management"]

  it "commissions and advertises the mandatory revision 1 surface" do
    device.commission!
    read_int(device, TlsCertificateE2E::CLUSTER, "cluster-revision", "ClusterRevision", 0).should eq(1_i64)
    read_int(device, TlsCertificateE2E::CLUSTER, "max-root-certificates", "MaxRootCertificates", 0).should be >= 5_i64
    read_int(device, TlsCertificateE2E::CLUSTER, "max-client-certificates", "MaxClientCertificates", 0).should be >= 2_i64
    commands = expect_success(device.read(TlsCertificateE2E::CLUSTER, "accepted-command-list", 0)).int_list("AcceptedCommandList")
    commands.should eq([0_i64, 2_i64, 4_i64, 6_i64, 7_i64, 9_i64, 10_i64, 12_i64, 14_i64])
  end

  it "provisions, finds, persists and removes a root certificate over CASE" do
    certificate = TlsCertificateE2E.root_certificate
    der = "hex:#{certificate.hexstring}"
    provision = expect_success(device.invoke(TlsCertificateE2E::CLUSTER, "provision-root-certificate", [der, "null"], endpoint: 0))
    caid = provision.int("caid") || fail("chip-tool did not report CAID\n#{provision.output}")
    expect_success(device.invoke(TlsCertificateE2E::CLUSTER, "find-root-certificate", [caid.to_s], endpoint: 0))
      .output.should contain("certificateDetails")
    device.restart!
    expect_success(device.invoke(TlsCertificateE2E::CLUSTER, "find-root-certificate", [caid.to_s], endpoint: 0))
    expect_success(device.invoke(TlsCertificateE2E::CLUSTER, "remove-root-certificate", [caid.to_s], endpoint: 0))
    expect_failure(device.invoke(TlsCertificateE2E::CLUSTER, "find-root-certificate", [caid.to_s], endpoint: 0), "NOT_FOUND")
  end

  it "persists a device-held CSR key across restart and rejects bad nonce length" do
    nonce = "hex:#{Bytes.new(32, 0xa5_u8).hexstring}"
    csr = expect_success(device.invoke(TlsCertificateE2E::CLUSTER, "client-csr", [nonce, "null"], endpoint: 0))
    ccdid = csr.int("ccdid") || fail("chip-tool did not report CCDID\n#{csr.output}")
    csr.output.should contain("csr:")
    csr.output.should contain("nonceSignature:")
    device.restart!
    expect_success(device.invoke(TlsCertificateE2E::CLUSTER, "client-csr", [nonce, ccdid.to_s], endpoint: 0))
    expect_failure(device.invoke(TlsCertificateE2E::CLUSTER, "client-csr", ["hex:00", "null"], endpoint: 0), "CONSTRAINT_ERROR")
    expect_success(device.invoke(TlsCertificateE2E::CLUSTER, "remove-client-certificate", [ccdid.to_s], endpoint: 0))
  end
end
