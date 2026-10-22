require "../spec_helper"
require "../../src/matter/controller/certificate_util"

private alias TlsCert = Matter::Cluster::TlsCertificateManagement

private def tls_test_certificate(subject_key : Matter::Crypto::Key, signer_key : Matter::Crypto::Key,
                                 serial : Int32, ca : Bool) : Bytes
  cert = OpenSSL::X509::Certificate.new
  cert.version = 2
  cert.serial = OpenSSL::BN.new(serial)
  cert.not_before = OpenSSL::ASN1::Time.days_from_now(-1)
  cert.not_after = OpenSSL::ASN1::Time.days_from_now(365)
  name = OpenSSL::X509::Name.new
  name.add_entry("CN", "Matter TLS test #{serial}")
  cert.subject = name
  cert.issuer = name
  cert.public_key = OpenSSL::PKey::EC.from_public_bytes(subject_key.public_key, Matter::Crypto::CRYPTO_EC_CURVE_NIST)
  cert.add_extension(OpenSSL::X509::Extension.new("basicConstraints", "critical,CA:#{ca ? "TRUE" : "FALSE"}"))
  private_key = OpenSSL::PKey::EC.from_private_bytes(signer_key.private_key, Matter::Crypto::CRYPTO_EC_CURVE_NIST)
  cert.sign(private_key, OpenSSL::Digest.new("SHA256"))
  cert.to_der
end

private def tls_cluster(fabric : UInt8 = 1_u8) : TlsCert
  TlsCert.new.tap do |cluster|
    cluster.fabric_installed = ->(index : UInt8) { index == 1_u8 || index == 2_u8 }
    cluster.request_is_case_session = true
    cluster.request_fabric_index = fabric
  end
end

describe TlsCert do
  it "advertises revision 1 mandatory commands with Matter privileges" do
    cluster = tls_cluster
    cluster.cluster_revision.should eq(1_u16)
    cluster.attributes.map(&.id.id).should eq([0_u32, 1_u32, 2_u32, 3_u32])
    cluster.commands.map(&.id.id).should eq([0_u32, 2_u32, 4_u32, 6_u32, 7_u32, 9_u32, 10_u32, 12_u32, 14_u32])
    cluster.commands.select { |command| command.access == Matter::InteractionModel::EntryPrivilege::Administer }
      .map(&.id.id).should eq([0_u32, 6_u32, 7_u32, 9_u32, 14_u32])
  end

  it "isolates roots and client keys across fabrics and erases only the removed fabric" do
    cluster = tls_cluster
    root_key = Matter::Crypto::Key.generate_key_pair
    root_der = tls_test_certificate(root_key, root_key, 1, true)
    root_id = cluster.provision_root_certificate(TlsCert::Tlv::ProvisionRootCertificateRequest.new(root_der, nil))
      .as(TlsCert::Tlv::ProvisionRootCertificateResponse).caid
    root_id.should eq(0_u16)
    cluster.lookup_root_certificate(TlsCert::Tlv::LookupRootCertificateRequest.new(Matter::Crypto::StandardCrypto.new.compute_sha256(root_der)))
      .as(TlsCert::Tlv::LookupRootCertificateResponse).caid.should eq(root_id)

    nonce = Bytes.new(32, 0x5a_u8)
    csr = cluster.client_csr(TlsCert::Tlv::ClientCsrRequest.new(nonce, nil)).as(TlsCert::Tlv::ClientCsrResponse)
    public_key = Matter::Controller::CertificateUtil.extract_uncompressed_public_key_from_csr(csr.csr)
    Matter::Crypto::StandardCrypto.new.verify_ecdsa(Matter::Crypto::Key.new(Matter::Crypto::KeyType::EC,
      Matter::Crypto::CurveType::P256).tap(&.public_bits=(public_key)), nonce, csr.nonce_signature)
    client_key = Matter::Crypto::Key.new(Matter::Crypto::KeyType::EC, Matter::Crypto::CurveType::P256)
    client_key.public_bits = public_key
    client_der = tls_test_certificate(client_key, root_key, 2, false)
    cluster.provision_client_certificate(TlsCert::Tlv::ProvisionClientCertificateRequest.new(csr.ccdid, client_der, [] of Bytes))
      .status.should eq(Matter::InteractionModel::StatusCode::Success)

    cluster.request_fabric_index = 2_u8
    cluster.find_root_certificate(TlsCert::Tlv::FindRootCertificateRequest.new(nil)).as(Matter::InteractionModel::Status)
      .status.should eq(Matter::InteractionModel::StatusCode::NotFound)
    cluster.find_client_certificate(TlsCert::Tlv::FindClientCertificateRequest.new(nil)).as(Matter::InteractionModel::Status)
      .status.should eq(Matter::InteractionModel::StatusCode::NotFound)
    second_root = cluster.provision_root_certificate(TlsCert::Tlv::ProvisionRootCertificateRequest.new(root_der, nil))
      .as(TlsCert::Tlv::ProvisionRootCertificateResponse)
    second_root.caid.should eq(0_u16)
    cluster.remove_fabric(1_u8)
    cluster.has_root?(1_u8, root_id).should be_false
    cluster.has_client?(1_u8, csr.ccdid).should be_false
    cluster.has_root?(2_u8, second_root.caid).should be_true
  end

  it "persists pending CSR keys and rejects certificates with another public key" do
    original = tls_cluster
    nonce = Bytes.new(32, 0x33_u8)
    csr = original.client_csr(TlsCert::Tlv::ClientCsrRequest.new(nonce, nil)).as(TlsCert::Tlv::ClientCsrResponse)
    restored = tls_cluster
    restored.restore_state(original.save_state.as(Matter::Storage::Document))
    repeated = restored.client_csr(TlsCert::Tlv::ClientCsrRequest.new(nonce, csr.ccdid)).as(TlsCert::Tlv::ClientCsrResponse)
    Matter::Controller::CertificateUtil.extract_uncompressed_public_key_from_csr(repeated.csr)
      .should eq(Matter::Controller::CertificateUtil.extract_uncompressed_public_key_from_csr(csr.csr))
    other = Matter::Crypto::Key.generate_key_pair
    wrong_cert = tls_test_certificate(other, other, 3, false)
    restored.provision_client_certificate(TlsCert::Tlv::ProvisionClientCertificateRequest.new(csr.ccdid, wrong_cert, [] of Bytes))
      .status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    restored.find_client_certificate(TlsCert::Tlv::FindClientCertificateRequest.new(csr.ccdid))
      .as(TlsCert::Tlv::FindClientCertificateResponse).certificate_details.first.client_certificate.should be_nil
  end

  it "keeps two fabrics in a file store across restart and drops the removed fabric before index reuse" do
    path = File.join(Dir.tempdir, "matter-tls-cert-#{Random::Secure.hex(6)}.yml")
    installed = [1_u8, 2_u8]
    persistence = Matter::Device::Persistence.new(Matter::Storage::YamlFile.new(path))
    cluster = tls_cluster
    cluster.fabric_installed = ->(index : UInt8) { installed.includes?(index) }
    cluster.on_persist = -> { persistence.save_cluster(cluster); nil }
    first = cluster.client_csr(TlsCert::Tlv::ClientCsrRequest.new(Bytes.new(32, 1_u8), nil))
      .as(TlsCert::Tlv::ClientCsrResponse)
    cluster.request_fabric_index = 2_u8
    second = cluster.client_csr(TlsCert::Tlv::ClientCsrRequest.new(Bytes.new(32, 2_u8), nil))
      .as(TlsCert::Tlv::ClientCsrResponse)
    persistence.close

    reopened = Matter::Device::Persistence.new(Matter::Storage::YamlFile.new(path))
    restored = tls_cluster
    restored.fabric_installed = ->(index : UInt8) { installed.includes?(index) }
    reopened.restore_clusters([restored]).should eq(1)
    restored.has_client?(1_u8, first.ccdid).should be_true
    restored.has_client?(2_u8, second.ccdid).should be_true
    restored.on_persist = -> { reopened.save_cluster(restored); nil }
    installed.delete(1_u8)
    restored.remove_fabric(1_u8)
    reopened.close

    replacement = Matter::Device::Persistence.new(Matter::Storage::YamlFile.new(path))
    again = tls_cluster
    again.fabric_installed = ->(index : UInt8) { installed.includes?(index) }
    replacement.restore_clusters([again]).should eq(1)
    again.has_client?(1_u8, first.ccdid).should be_false
    again.has_client?(2_u8, second.ccdid).should be_true
    replacement.close
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "rejects expired X.509 certificates using DynamicConstraintError" do
    cluster = tls_cluster
    key = Matter::Crypto::Key.generate_key_pair
    certificate = tls_test_certificate(key, key, 8, true)
    Timecop.travel(Time.utc + 2.years) do
      cluster.provision_root_certificate(TlsCert::Tlv::ProvisionRootCertificateRequest.new(certificate, nil))
        .as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::DynamicConstraintError)
    end
  end

  it "enforces a CASE fabric context and command constraints" do
    cluster = tls_cluster
    cluster.request_is_case_session = false
    cluster.client_csr(TlsCert::Tlv::ClientCsrRequest.new(Bytes.new(32), nil)).as(Matter::InteractionModel::Status)
      .status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAccess)
    cluster.request_is_case_session = true
    cluster.client_csr(TlsCert::Tlv::ClientCsrRequest.new(Bytes.new(31), nil)).as(Matter::InteractionModel::Status)
      .status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
  end
end
