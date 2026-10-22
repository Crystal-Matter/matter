require "./e2e_helper"

module TlsClientE2E
  CLIENT_CLUSTER = "tlsclientmanagement"
  CERT_CLUSTER   = "tlscertificatemanagement"
  HOSTNAME       = "hex:6170692e6578616d706c652e636f6d"

  def self.root_certificate : Bytes
    key = Matter::Crypto::Key.generate_key_pair
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = OpenSSL::BN.new(1)
    cert.not_before = OpenSSL::ASN1::Time.days_from_now(-1)
    cert.not_after = OpenSSL::ASN1::Time.days_from_now(365)
    name = OpenSSL::X509::Name.new
    name.add_entry("CN", "Matter TLS Client E2E root")
    cert.subject = name
    cert.issuer = name
    cert.public_key = OpenSSL::PKey::EC.from_public_bytes(key.public_key, Matter::Crypto::CRYPTO_EC_CURVE_NIST)
    cert.add_extension(OpenSSL::X509::Extension.new("basicConstraints", "critical,CA:TRUE"))
    cert.sign(OpenSSL::PKey::EC.from_private_bytes(key.private_key, Matter::Crypto::CRYPTO_EC_CURVE_NIST),
      OpenSSL::Digest.new("SHA256"))
    cert.to_der
  end

  def self.invoke(storage : String, cluster : String, command : String, args : Array(String)) : E2E::Result
    E2E.run([cluster, command] + args + ["1", "0"], storage)
  end

  def self.pair_second(first : String, second : String) : Nil
    window = expect_success(E2E.run(["pairing", "open-commissioning-window", "1", "1", "180", "1000", "3840"], first))
    code = window.output.match(/Manual pairing code:\s*\[?([0-9]{4}-[0-9]{3}-[0-9]{4}|[0-9]{11})\]?/i)
      .try(&.[1]) || fail("chip-tool did not print a pairing code\n#{window.output}")
    Dir.mkdir_p(second)
    expect_success(E2E.run(["pairing", "code", "1", code], second))
  end
end

describe "official SDK TLS Client Management" do
  device = E2E::Device["matter_tls_client_management"]

  it "commissions and advertises revision-1 endpoint commands" do
    device.commission!
    read_int(device, TlsClientE2E::CLIENT_CLUSTER, "cluster-revision", "ClusterRevision", 0).should eq(1_i64)
    read_int(device, TlsClientE2E::CLIENT_CLUSTER, "max-provisioned", "MaxProvisioned", 0).should be >= 5_i64
    expect_success(device.read(TlsClientE2E::CLIENT_CLUSTER, "accepted-command-list", 0))
      .int_list("AcceptedCommandList").should eq([0_i64, 2_i64, 4_i64])
  end

  it "persists and isolates certificate-backed endpoints across fabrics" do
    certificate = "hex:#{TlsClientE2E.root_certificate.hexstring}"
    first = device.storage_dir
    second = File.join(E2E::STORAGE_ROOT, "tls-client-second")

    root = expect_success(TlsClientE2E.invoke(first, TlsClientE2E::CERT_CLUSTER,
      "provision-root-certificate", [certificate, "null"]))
    caid = root.int("caid") || fail("missing CAID\n#{root.output}")
    created = expect_success(TlsClientE2E.invoke(first, TlsClientE2E::CLIENT_CLUSTER,
      "provision-endpoint", [TlsClientE2E::HOSTNAME, "443", caid.to_s, "null", "null"]))
    id = created.int("endpointID") || fail("missing endpointID\n#{created.output}")
    expect_success(device.read(TlsClientE2E::CLIENT_CLUSTER, "provisioned-endpoints", 0))
      .output.should contain("ProvisionedEndpoints: 1 entries")
    expect_failure(TlsClientE2E.invoke(first, TlsClientE2E::CERT_CLUSTER,
      "remove-root-certificate", [caid.to_s]), "INVALID_IN_STATE")
    device.restart!
    expect_success(TlsClientE2E.invoke(first, TlsClientE2E::CLIENT_CLUSTER, "find-endpoint", [id.to_s]))

    TlsClientE2E.pair_second(first, second)
    expect_failure(TlsClientE2E.invoke(second, TlsClientE2E::CLIENT_CLUSTER, "find-endpoint", [id.to_s]), "NOT_FOUND")
    expect_success(E2E.run([TlsClientE2E::CLIENT_CLUSTER, "read", "provisioned-endpoints", "1", "0"], second))
      .output.should contain("ProvisionedEndpoints: 0 entries")
    second_root = expect_success(TlsClientE2E.invoke(second, TlsClientE2E::CERT_CLUSTER,
      "provision-root-certificate", [certificate, "null"]))
    second_caid = second_root.int("caid") || fail("missing second CAID\n#{second_root.output}")
    second_endpoint = expect_success(TlsClientE2E.invoke(second, TlsClientE2E::CLIENT_CLUSTER,
      "provision-endpoint", [TlsClientE2E::HOSTNAME, "443", second_caid.to_s, "null", "null"]))
    second_id = second_endpoint.int("endpointID") || fail("missing second endpointID\n#{second_endpoint.output}")
    expect_success(E2E.run(["operationalcredentials", "remove-fabric", "1", "1", "0"], second))
    device.restart!
    expect_success(TlsClientE2E.invoke(second, TlsClientE2E::CLIENT_CLUSTER, "find-endpoint", [second_id.to_s]))
    expect_success(TlsClientE2E.invoke(second, TlsClientE2E::CLIENT_CLUSTER, "remove-endpoint", [second_id.to_s]))
    expect_success(TlsClientE2E.invoke(second, TlsClientE2E::CERT_CLUSTER, "remove-root-certificate", [second_caid.to_s]))
  end
end
