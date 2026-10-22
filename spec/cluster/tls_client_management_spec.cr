require "../spec_helper"
require "../../src/matter/device/persistence"
require "../../src/matter/controller/certificate_util"

private alias TlsClient = Matter::Cluster::TlsClientManagement
private alias TlsCert = Matter::Cluster::TlsCertificateManagement

private def tls_client_test_root : Bytes
  key = Matter::Crypto::Key.generate_key_pair
  cert = OpenSSL::X509::Certificate.new
  cert.version = 2
  cert.serial = OpenSSL::BN.new(1)
  cert.not_before = OpenSSL::ASN1::Time.days_from_now(-1)
  cert.not_after = OpenSSL::ASN1::Time.days_from_now(365)
  name = OpenSSL::X509::Name.new
  name.add_entry("CN", "TLS Client Management test root")
  cert.subject = name
  cert.issuer = name
  cert.public_key = OpenSSL::PKey::EC.from_public_bytes(key.public_key, Matter::Crypto::CRYPTO_EC_CURVE_NIST)
  cert.add_extension(OpenSSL::X509::Extension.new("basicConstraints", "critical,CA:TRUE"))
  cert.sign(OpenSSL::PKey::EC.from_private_bytes(key.private_key, Matter::Crypto::CRYPTO_EC_CURVE_NIST), OpenSSL::Digest.new("SHA256"))
  cert.to_der
end

private def tls_client_fixture : Tuple(TlsClient, TlsCert)
  certificates = TlsCert.new
  certificates.request_is_case_session = true
  certificates.request_fabric_index = 1_u8
  certificates.fabric_installed = ->(fabric : UInt8) { fabric.in?(1_u8..2_u8) }
  client = TlsClient.new
  client.certificate_management = certificates
  client.request_is_case_session = true
  client.request_fabric_index = 1_u8
  client.fabric_installed = ->(fabric : UInt8) { fabric.in?(1_u8..2_u8) }
  certificates.managed_root_in_use = ->(fabric : UInt8, caid : UInt16) { client.root_in_use?(fabric, caid) }
  certificates.managed_client_in_use = ->(fabric : UInt8, ccdid : UInt16) { client.client_in_use?(fabric, ccdid) }
  {client, certificates}
end

private def tls_client_request(caid : UInt16, port : UInt16 = 443_u16, id : UInt16? = nil, ccdid : UInt16? = nil) : TlsClient::Tlv::ProvisionEndpointRequest
  TlsClient::Tlv::ProvisionEndpointRequest.new("api.example.com".to_slice, port, caid, ccdid, id)
end

describe TlsClient do
  it "has the mandatory Matter 1.6 revision-1 command and attribute surface" do
    cluster = TlsClient.new
    cluster.cluster_revision.should eq(1_u16)
    cluster.attributes.map(&.id.id).should eq([0_u32, 1_u32])
    cluster.commands.map(&.id.id).should eq([0_u32, 2_u32, 4_u32])
    expect_raises(Matter::ConfigurationError) { TlsClient.new(Matter::DataType::EndpointNumber.new(1_u16)) }
  end

  it "requires an installed fabric and a root certificate before creating an endpoint" do
    client, certificates = tls_client_fixture
    client.provision_endpoint(tls_client_request(0_u16)).as(Matter::InteractionModel::Status).cluster_status
      .should eq(TlsClient::StatusCode::RootCertificateNotFound.value)
    root = certificates.provision_root_certificate(TlsCert::Tlv::ProvisionRootCertificateRequest.new(tls_client_test_root, nil))
      .as(TlsCert::Tlv::ProvisionRootCertificateResponse)
    endpoint = client.provision_endpoint(tls_client_request(root.caid)).as(TlsClient::Tlv::ProvisionEndpointResponse)
    found = client.find_endpoint(TlsClient::Tlv::FindEndpointRequest.new(endpoint.endpoint_id))
      .as(TlsClient::Tlv::FindEndpointResponse).endpoint
    found.caid.should eq(root.caid)
    found.port.should eq(443_u16)
    found.reference_count.should eq(0_u8)
    certificates.root_in_use = ->(_fabric : UInt8, _caid : UInt16) { false }
    certificates.remove_root_certificate(TlsCert::Tlv::RemoveRootCertificateRequest.new(root.caid)).status
      .should eq(Matter::InteractionModel::StatusCode::InvalidInState)
  end

  it "isolates endpoint IDs and reference counts per fabric" do
    client, certificates = tls_client_fixture
    der = tls_client_test_root
    first_root = certificates.provision_root_certificate(TlsCert::Tlv::ProvisionRootCertificateRequest.new(der, nil))
      .as(TlsCert::Tlv::ProvisionRootCertificateResponse)
    first = client.provision_endpoint(tls_client_request(first_root.caid)).as(TlsClient::Tlv::ProvisionEndpointResponse)
    client.change_reference_count(1_u8, first.endpoint_id, 1_i8).should be_true
    client.remove_endpoint(TlsClient::Tlv::RemoveEndpointRequest.new(first.endpoint_id)).status
      .should eq(Matter::InteractionModel::StatusCode::InvalidInState)

    client.request_fabric_index = 2_u8
    certificates.request_fabric_index = 2_u8
    client.find_endpoint(TlsClient::Tlv::FindEndpointRequest.new(first.endpoint_id)).as(Matter::InteractionModel::Status).status
      .should eq(Matter::InteractionModel::StatusCode::NotFound)
    second_root = certificates.provision_root_certificate(TlsCert::Tlv::ProvisionRootCertificateRequest.new(der, nil))
      .as(TlsCert::Tlv::ProvisionRootCertificateResponse)
    second = client.provision_endpoint(tls_client_request(second_root.caid)).as(TlsClient::Tlv::ProvisionEndpointResponse)
    second.endpoint_id.should eq(first.endpoint_id)
    client.provisioned_endpoints(2_u8).as(Array(TlsClient::Tlv::Endpoint)).size.should eq(1)
    client.request_fabric_filtered = false
    client.provisioned_endpoints(2_u8).as(Array(TlsClient::Tlv::Endpoint)).size.should eq(1)
    client.remove_fabric(1_u8)
    client.find_endpoint(TlsClient::Tlv::FindEndpointRequest.new(second.endpoint_id)).as(TlsClient::Tlv::FindEndpointResponse)
      .endpoint.reference_count.should eq(0_u8)
  end

  it "persists endpoints in a file store and rejects duplicate hostname and port" do
    path = File.join(Dir.tempdir, "matter-tls-client-#{Random::Secure.hex(6)}.yml")
    client, certificates = tls_client_fixture
    root = certificates.provision_root_certificate(TlsCert::Tlv::ProvisionRootCertificateRequest.new(tls_client_test_root, nil))
      .as(TlsCert::Tlv::ProvisionRootCertificateResponse)
    persistence = Matter::Device::Persistence.new(Matter::Storage::YamlFile.new(path))
    client.on_persist = -> { persistence.save_cluster(client); nil }
    endpoint = client.provision_endpoint(tls_client_request(root.caid)).as(TlsClient::Tlv::ProvisionEndpointResponse)
    client.change_reference_count(1_u8, endpoint.endpoint_id, 1_i8).should be_true
    client.provision_endpoint(tls_client_request(root.caid)).as(Matter::InteractionModel::Status).cluster_status
      .should eq(TlsClient::StatusCode::EndpointAlreadyInstalled.value)
    persistence.close

    reopened = Matter::Device::Persistence.new(Matter::Storage::YamlFile.new(path))
    restored = TlsClient.new
    restored.certificate_management = certificates
    restored.request_is_case_session = true
    restored.request_fabric_index = 1_u8
    reopened.restore_clusters([restored]).should eq(1)
    restored.find_endpoint(TlsClient::Tlv::FindEndpointRequest.new(endpoint.endpoint_id)).as(TlsClient::Tlv::FindEndpointResponse)
      .endpoint.hostname.should eq("api.example.com".to_slice)
    restored.find_endpoint(TlsClient::Tlv::FindEndpointRequest.new(endpoint.endpoint_id)).as(TlsClient::Tlv::FindEndpointResponse)
      .endpoint.reference_count.should eq(1_u8)
    reopened.close
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "requires a provisioned client certificate and prevents its removal while referenced" do
    client, certificates = tls_client_fixture
    root = certificates.provision_root_certificate(TlsCert::Tlv::ProvisionRootCertificateRequest.new(tls_client_test_root, nil))
      .as(TlsCert::Tlv::ProvisionRootCertificateResponse)
    csr = certificates.client_csr(TlsCert::Tlv::ClientCsrRequest.new(Bytes.new(32, 0x55_u8), nil))
      .as(TlsCert::Tlv::ClientCsrResponse)
    client.provision_endpoint(tls_client_request(root.caid, ccdid: csr.ccdid)).as(Matter::InteractionModel::Status)
      .cluster_status.should eq(TlsClient::StatusCode::ClientCertificateNotFound.value)

    public_key = Matter::Controller::CertificateUtil.extract_uncompressed_public_key_from_csr(csr.csr)
    signer = Matter::Crypto::Key.generate_key_pair
    leaf = OpenSSL::X509::Certificate.new
    leaf.version = 2
    leaf.serial = OpenSSL::BN.new(2)
    leaf.not_before = OpenSSL::ASN1::Time.days_from_now(-1)
    leaf.not_after = OpenSSL::ASN1::Time.days_from_now(365)
    name = OpenSSL::X509::Name.new
    name.add_entry("CN", "TLS Client Management client")
    leaf.subject = name
    leaf.issuer = name
    leaf.public_key = OpenSSL::PKey::EC.from_public_bytes(public_key, Matter::Crypto::CRYPTO_EC_CURVE_NIST)
    leaf.sign(OpenSSL::PKey::EC.from_private_bytes(signer.private_key, Matter::Crypto::CRYPTO_EC_CURVE_NIST),
      OpenSSL::Digest.new("SHA256"))
    certificates.provision_client_certificate(TlsCert::Tlv::ProvisionClientCertificateRequest.new(csr.ccdid, leaf.to_der, [] of Bytes))
      .status.should eq(Matter::InteractionModel::StatusCode::Success)

    endpoint = client.provision_endpoint(tls_client_request(root.caid, ccdid: csr.ccdid)).as(TlsClient::Tlv::ProvisionEndpointResponse)
    certificates.client_in_use = ->(_fabric : UInt8, _ccdid : UInt16) { false }
    certificates.remove_client_certificate(TlsCert::Tlv::RemoveClientCertificateRequest.new(csr.ccdid)).status
      .should eq(Matter::InteractionModel::StatusCode::InvalidInState)
    client.remove_endpoint(TlsClient::Tlv::RemoveEndpointRequest.new(endpoint.endpoint_id)).status
      .should eq(Matter::InteractionModel::StatusCode::Success)
    certificates.remove_client_certificate(TlsCert::Tlv::RemoveClientCertificateRequest.new(csr.ccdid)).status
      .should eq(Matter::InteractionModel::StatusCode::Success)
  end

  it "checks capacity, update IDs, and host reference bounds" do
    client, certificates = tls_client_fixture
    root = certificates.provision_root_certificate(TlsCert::Tlv::ProvisionRootCertificateRequest.new(tls_client_test_root, nil))
      .as(TlsCert::Tlv::ProvisionRootCertificateResponse)
    client.provision_endpoint(tls_client_request(root.caid, id: 7_u16)).as(Matter::InteractionModel::Status).status
      .should eq(Matter::InteractionModel::StatusCode::NotFound)
    5.times do |offset|
      client.provision_endpoint(tls_client_request(root.caid, (443 + offset).to_u16)).as(TlsClient::Tlv::ProvisionEndpointResponse)
    end
    client.provision_endpoint(tls_client_request(root.caid, 999_u16)).as(Matter::InteractionModel::Status).status
      .should eq(Matter::InteractionModel::StatusCode::ResourceExhausted)
    client.change_reference_count(1_u8, 0_u16, -1_i8).should be_false
    client.change_reference_count(1_u8, 0_u16, 1_i8).should be_true
    client.provision_endpoint(tls_client_request(root.caid, 999_u16, 0_u16)).as(Matter::InteractionModel::Status).status
      .should eq(Matter::InteractionModel::StatusCode::InvalidInState)
    client.change_reference_count(1_u8, 0_u16, -1_i8).should be_true
    client.provision_endpoint(tls_client_request(root.caid, 999_u16, 0_u16)).as(TlsClient::Tlv::ProvisionEndpointResponse)
      .endpoint_id.should eq(0_u16)
    client.find_endpoint(TlsClient::Tlv::FindEndpointRequest.new(0_u16)).as(TlsClient::Tlv::FindEndpointResponse)
      .endpoint.port.should eq(999_u16)
  end

  it "validates endpoint bounds and a host-reported unsynchronized clock" do
    client, certificates = tls_client_fixture
    root = certificates.provision_root_certificate(TlsCert::Tlv::ProvisionRootCertificateRequest.new(tls_client_test_root, nil))
      .as(TlsCert::Tlv::ProvisionRootCertificateResponse)
    client.provision_endpoint(TlsClient::Tlv::ProvisionEndpointRequest.new("abc".to_slice, 443_u16, root.caid, nil, nil))
      .as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    client.provision_endpoint(TlsClient::Tlv::ProvisionEndpointRequest.new("api.example.com".to_slice, 0_u16, root.caid, nil, nil))
      .as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    client.provision_endpoint(TlsClient::Tlv::ProvisionEndpointRequest.new("api.example.com".to_slice, 443_u16, root.caid, 65535_u16, nil))
      .as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    client.time_valid = -> { false }
    client.provision_endpoint(tls_client_request(root.caid)).as(Matter::InteractionModel::Status).cluster_status
      .should eq(TlsClient::StatusCode::InvalidTime.value)
  end
end
