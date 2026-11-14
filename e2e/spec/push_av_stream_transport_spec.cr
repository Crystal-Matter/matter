require "./e2e_helper"

module PushAvCatalogE2E
  alias PushAv = Matter::Cluster::PushAvStreamTransport

  def self.root_certificate : Bytes
    key = Matter::Crypto::Key.generate_key_pair
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = OpenSSL::BN.new(1)
    cert.not_before = OpenSSL::ASN1::Time.days_from_now(-1)
    cert.not_after = OpenSSL::ASN1::Time.days_from_now(365)
    name = OpenSSL::X509::Name.new
    name.add_entry("CN", "Push AV catalog E2E root")
    cert.subject = name
    cert.issuer = name
    cert.public_key = OpenSSL::PKey::EC.from_public_bytes(key.public_key, Matter::Crypto::CRYPTO_EC_CURVE_NIST)
    cert.add_extension(OpenSSL::X509::Extension.new("basicConstraints", "critical,CA:TRUE"))
    cert.sign(OpenSSL::PKey::EC.from_private_bytes(key.private_key, Matter::Crypto::CRYPTO_EC_CURVE_NIST),
      OpenSSL::Digest.new("SHA256"))
    cert.to_der
  end

  def self.allocate_payload(tls_id : Int64, url : String = "https://api.example.com/ingest/",
                            metadata_enabled : Bool? = nil, video_streams : Bool = true,
                            legacy_video_id : UInt16? = nil, video_stream_name : String = "main") : String
    metadata = metadata_enabled.nil? ? "" : %(,"7":#{metadata_enabled})
    legacy_video = legacy_video_id.try { |id| %(,"1":"u:#{id}") } || ""
    video_list = video_streams ? %(,"9":[{"0":"#{video_stream_name}","1":"u:1"}]) : ""
    %({"0":{"0":"u:1"#{legacy_video},"3":"u:#{tls_id}","4":"#{url}","5":{"0":"u:0","4":"u:0"},"6":"u:0","7":{"0":"u:0","1":{"0":"u:0","1":"u:1000","2":"u:500"#{metadata}}}#{video_list}}})
  end

  def self.expiring_payload(tls_id : Int64, seconds : UInt32) : String
    %({"0":{"0":"u:1","3":"u:#{tls_id}","4":"https://api.example.com/ingest/","5":{"0":"u:0","4":"u:0"},"6":"u:0","7":{"0":"u:0","1":{"0":"u:0","1":"u:1000","2":"u:500"}},"8":"u:#{seconds}","9":[{"0":"main","1":"u:1"}]}})
  end

  def self.command(device : E2E::Device, id : UInt32, payload : String) : E2E::Result
    device.chip("any", "command-by-id", PushAv::CLUSTER_ID.to_s, id.to_s,
      payload, device.node, "0")
  end
end

describe "official SDK Push AV Stream Transport" do
  device = E2E::Device["matter_push_av_stream_transport"]

  it "commissions and reads the revision-2 fabric-scoped configuration surface" do
    device.commission!
    read_int(device, "pushavstreamtransport", "cluster-revision", "ClusterRevision", 0).should eq(2_i64)
    formats = expect_success(device.read("pushavstreamtransport", "supported-formats", 0))
    formats.output.should contain("SupportedFormats: 1 entries")
    formats.int("ContainerFormat").should eq(0_i64)
    formats.int("IngestMethod").should eq(0_i64)
    expect_success(device.read("pushavstreamtransport", "current-connections", 0)).output
      .should contain("CurrentConnections: 0 entries")
    expect_success(device.read("pushavstreamtransport", "accepted-command-list", 0))
      .int_list("AcceptedCommandList").should eq([0_i64, 2_i64, 3_i64, 4_i64, 5_i64, 6_i64])
    expect_failure(device.invoke("pushavstreamtransport", "manually-trigger-transport",
      ["0", "0"], endpoint: 0), "NOT_FOUND")
    expect_failure(device.invoke("pushavstreamtransport", "find-transport", ["0"], endpoint: 0), "NOT_FOUND")
    device.restart!
    expect_success(device.read("pushavstreamtransport", "current-connections", 0)).output
      .should contain("CurrentConnections: 0 entries")
  end

  it "allocates, finds, persists, and releases a nonempty CMAF catalog entry" do
    certificate = "hex:#{PushAvCatalogE2E.root_certificate.hexstring}"
    root = expect_success(device.invoke("tlscertificatemanagement", "provision-root-certificate",
      [certificate, "null"], endpoint: 0))
    caid = root.int("caid") || fail("missing CAID\n#{root.output}")
    endpoint = expect_success(device.invoke("tlsclientmanagement", "provision-endpoint",
      ["hex:6170692e6578616d706c652e636f6d", "443", caid.to_s, "null", "null"], endpoint: 0))
    tls_id = endpoint.int("endpointID") || fail("missing TLS endpoint ID\n#{endpoint.output}")

    expect_success(PushAvCatalogE2E.command(device, PushAvCatalogE2E::PushAv::CMD_ALLOCATE_PUSH_TRANSPORT,
      PushAvCatalogE2E.allocate_payload(tls_id)))
    connections = expect_success(device.read("pushavstreamtransport", "current-connections", 0))
    connections.output.should contain("CurrentConnections: 1 entries")
    id = connections.int("ConnectionID") || fail("missing Push AV connection ID\n#{connections.output}")
    in_use = device.invoke("tlsclientmanagement", "remove-endpoint", [tls_id.to_s], endpoint: 0)
    in_use.success?.should be_false
    in_use.output.should contain("Cluster-specific error: 0x05")
    expect_success(PushAvCatalogE2E.command(device, PushAvCatalogE2E::PushAv::CMD_FIND_TRANSPORT,
      %({"0":"u:#{id}"})))

    device.restart!
    expect_success(device.read("pushavstreamtransport", "current-connections", 0)).output
      .should contain("CurrentConnections: 1 entries")
    expect_success(device.invoke("pushavstreamtransport", "deallocate-push-transport", [id.to_s], endpoint: 0))
    expect_success(device.read("pushavstreamtransport", "current-connections", 0)).output
      .should contain("CurrentConnections: 0 entries")
    expect_success(device.invoke("tlsclientmanagement", "remove-endpoint", [tls_id.to_s], endpoint: 0))
    expect_success(device.invoke("tlscertificatemanagement", "remove-root-certificate", [caid.to_s], endpoint: 0))
  end

  it "rejects invalid CMAF ingest base URLs before allocating a connection" do
    certificate = "hex:#{PushAvCatalogE2E.root_certificate.hexstring}"
    root = expect_success(device.invoke("tlscertificatemanagement", "provision-root-certificate",
      [certificate, "null"], endpoint: 0))
    caid = root.int("caid") || fail("missing CAID\n#{root.output}")
    endpoint = expect_success(device.invoke("tlsclientmanagement", "provision-endpoint",
      ["hex:6170692e6578616d706c652e636f6d", "443", caid.to_s, "null", "null"], endpoint: 0))
    tls_id = endpoint.int("endpointID") || fail("missing TLS endpoint ID\n#{endpoint.output}")

    invalid = [
      "http://api.example.com/ingest/",
      "https:///ingest/",
      "https://api.example.com/ingest/?bad=query",
      "https://api.example.com/ingest/#fragment",
      "https://api.example.com/ingest",
    ]
    invalid.each do |url|
      result = PushAvCatalogE2E.command(device, PushAvCatalogE2E::PushAv::CMD_ALLOCATE_PUSH_TRANSPORT,
        PushAvCatalogE2E.allocate_payload(tls_id, url))
      result.success?.should be_false
      result.output.should contain("Cluster-specific error: 0x04")
      expect_success(device.read("pushavstreamtransport", "current-connections", 0)).output
        .should contain("CurrentConnections: 0 entries")
    end

    expect_success(PushAvCatalogE2E.command(device, PushAvCatalogE2E::PushAv::CMD_ALLOCATE_PUSH_TRANSPORT,
      PushAvCatalogE2E.allocate_payload(tls_id, "https://api.example.com/ingest/")))
    connections = expect_success(device.read("pushavstreamtransport", "current-connections", 0))
    connections.output.should contain("CurrentConnections: 1 entries")
    id = connections.int("ConnectionID") || fail("missing Push AV connection ID\n#{connections.output}")
    expect_success(device.invoke("pushavstreamtransport", "deallocate-push-transport", [id.to_s], endpoint: 0))
    expect_success(device.invoke("tlsclientmanagement", "remove-endpoint", [tls_id.to_s], endpoint: 0))
    expect_success(device.invoke("tlscertificatemanagement", "remove-root-certificate", [caid.to_s], endpoint: 0))
  end

  it "rejects MetadataEnabled presence without the Metadata feature" do
    certificate = "hex:#{PushAvCatalogE2E.root_certificate.hexstring}"
    root = expect_success(device.invoke("tlscertificatemanagement", "provision-root-certificate",
      [certificate, "null"], endpoint: 0))
    caid = root.int("caid") || fail("missing CAID\n#{root.output}")
    endpoint = expect_success(device.invoke("tlsclientmanagement", "provision-endpoint",
      ["hex:6170692e6578616d706c652e636f6d", "443", caid.to_s, "null", "null"], endpoint: 0))
    tls_id = endpoint.int("endpointID") || fail("missing TLS endpoint ID\n#{endpoint.output}")

    [false, true].each do |enabled|
      expect_failure(PushAvCatalogE2E.command(device, PushAvCatalogE2E::PushAv::CMD_ALLOCATE_PUSH_TRANSPORT,
        PushAvCatalogE2E.allocate_payload(tls_id, metadata_enabled: enabled)), "INVALID_COMMAND")
    end
    expect_success(device.read("pushavstreamtransport", "current-connections", 0)).output
      .should contain("CurrentConnections: 0 entries")
    expect_success(device.invoke("tlsclientmanagement", "remove-endpoint", [tls_id.to_s], endpoint: 0))
    expect_success(device.invoke("tlscertificatemanagement", "remove-root-certificate", [caid.to_s], endpoint: 0))
  end

  it "requires one stream field representation on AllocatePushTransport" do
    certificate = "hex:#{PushAvCatalogE2E.root_certificate.hexstring}"
    root = expect_success(device.invoke("tlscertificatemanagement", "provision-root-certificate",
      [certificate, "null"], endpoint: 0))
    caid = root.int("caid") || fail("missing CAID\n#{root.output}")
    endpoint = expect_success(device.invoke("tlsclientmanagement", "provision-endpoint",
      ["hex:6170692e6578616d706c652e636f6d", "443", caid.to_s, "null", "null"], endpoint: 0))
    tls_id = endpoint.int("endpointID") || fail("missing TLS endpoint ID\n#{endpoint.output}")

    [
      PushAvCatalogE2E.allocate_payload(tls_id, video_streams: false),
      PushAvCatalogE2E.allocate_payload(tls_id, legacy_video_id: 1_u16),
    ].each do |payload|
      expect_failure(PushAvCatalogE2E.command(device, PushAvCatalogE2E::PushAv::CMD_ALLOCATE_PUSH_TRANSPORT,
        payload), "INVALID_COMMAND")
      expect_success(device.read("pushavstreamtransport", "current-connections", 0)).output
        .should contain("CurrentConnections: 0 entries")
    end

    expect_success(device.invoke("tlsclientmanagement", "remove-endpoint", [tls_id.to_s], endpoint: 0))
    expect_success(device.invoke("tlscertificatemanagement", "remove-root-certificate", [caid.to_s], endpoint: 0))
  end

  it "returns ConstraintError for out-of-range TLS endpoint and URL length" do
    expect_failure(PushAvCatalogE2E.command(device, PushAvCatalogE2E::PushAv::CMD_ALLOCATE_PUSH_TRANSPORT,
      PushAvCatalogE2E.allocate_payload(UInt16::MAX.to_i64)), "CONSTRAINT_ERROR")
    expect_success(device.read("pushavstreamtransport", "current-connections", 0)).output
      .should contain("CurrentConnections: 0 entries")

    certificate = "hex:#{PushAvCatalogE2E.root_certificate.hexstring}"
    root = expect_success(device.invoke("tlscertificatemanagement", "provision-root-certificate",
      [certificate, "null"], endpoint: 0))
    caid = root.int("caid") || fail("missing CAID\n#{root.output}")
    endpoint = expect_success(device.invoke("tlsclientmanagement", "provision-endpoint",
      ["hex:6170692e6578616d706c652e636f6d", "443", caid.to_s, "null", "null"], endpoint: 0))
    tls_id = endpoint.int("endpointID") || fail("missing TLS endpoint ID\n#{endpoint.output}")

    expect_failure(PushAvCatalogE2E.command(device, PushAvCatalogE2E::PushAv::CMD_ALLOCATE_PUSH_TRANSPORT,
      PushAvCatalogE2E.allocate_payload(tls_id, "https://a/")), "CONSTRAINT_ERROR")
    expect_success(device.read("pushavstreamtransport", "current-connections", 0)).output
      .should contain("CurrentConnections: 0 entries")
    expect_success(device.invoke("tlsclientmanagement", "remove-endpoint", [tls_id.to_s], endpoint: 0))
    expect_success(device.invoke("tlscertificatemanagement", "remove-root-certificate", [caid.to_s], endpoint: 0))
  end

  it "returns ConstraintError for video stream names outside 1 to 16 bytes" do
    certificate = "hex:#{PushAvCatalogE2E.root_certificate.hexstring}"
    root = expect_success(device.invoke("tlscertificatemanagement", "provision-root-certificate",
      [certificate, "null"], endpoint: 0))
    caid = root.int("caid") || fail("missing CAID\n#{root.output}")
    endpoint = expect_success(device.invoke("tlsclientmanagement", "provision-endpoint",
      ["hex:6170692e6578616d706c652e636f6d", "443", caid.to_s, "null", "null"], endpoint: 0))
    tls_id = endpoint.int("endpointID") || fail("missing TLS endpoint ID\n#{endpoint.output}")

    ["", "x" * 17].each do |name|
      expect_failure(PushAvCatalogE2E.command(device, PushAvCatalogE2E::PushAv::CMD_ALLOCATE_PUSH_TRANSPORT,
        PushAvCatalogE2E.allocate_payload(tls_id, video_stream_name: name)), "CONSTRAINT_ERROR")
      expect_success(device.read("pushavstreamtransport", "current-connections", 0)).output
        .should contain("CurrentConnections: 0 entries")
    end
    expect_success(device.invoke("tlsclientmanagement", "remove-endpoint", [tls_id.to_s], endpoint: 0))
    expect_success(device.invoke("tlscertificatemanagement", "remove-root-certificate", [caid.to_s], endpoint: 0))
  end

  it "expires a TLS-backed connection after time synchronization and restart" do
    expect_success(device.invoke("timesynchronization", "set-utctime", ["1000000000", "4"], endpoint: 0))
    certificate = "hex:#{PushAvCatalogE2E.root_certificate.hexstring}"
    root = expect_success(device.invoke("tlscertificatemanagement", "provision-root-certificate",
      [certificate, "null"], endpoint: 0))
    caid = root.int("caid") || fail("missing CAID\n#{root.output}")
    endpoint = expect_success(device.invoke("tlsclientmanagement", "provision-endpoint",
      ["hex:6170692e6578616d706c652e636f6d", "443", caid.to_s, "null", "null"], endpoint: 0))
    tls_id = endpoint.int("endpointID") || fail("missing TLS endpoint ID\n#{endpoint.output}")

    expect_success(PushAvCatalogE2E.command(device, PushAvCatalogE2E::PushAv::CMD_ALLOCATE_PUSH_TRANSPORT,
      PushAvCatalogE2E.expiring_payload(tls_id, 5_u32)))
    expect_success(device.read("pushavstreamtransport", "current-connections", 0)).output
      .should contain("CurrentConnections: 1 entries")

    device.restart!
    deadline = Time.instant + 15.seconds
    loop do
      current = expect_success(device.read("pushavstreamtransport", "current-connections", 0)).output
      break if current.includes?("CurrentConnections: 0 entries")
      fail("Push AV connection did not expire\n#{current}") if Time.instant >= deadline
      sleep 1.second
    end
    expect_failure(device.invoke("pushavstreamtransport", "find-transport", ["null"], endpoint: 0), "NOT_FOUND")
    expect_success(device.invoke("tlsclientmanagement", "remove-endpoint", [tls_id.to_s], endpoint: 0))
    expect_success(device.invoke("tlscertificatemanagement", "remove-root-certificate", [caid.to_s], endpoint: 0))
  end
end
