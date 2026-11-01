require "../support/operational_credentials_helpers"
require "../../src/matter/cluster/operational_credentials"

describe Matter::Cluster::OperationalCredentials do
  it "installs a self-signed RCAC with the Matter.js zero-valued RCAC identifier" do
    authority = TestCertificateAuthority.new
    cluster = Matter::Cluster::OperationalCredentials.new(Matter::FabricTable.new(Matter::Storage::Memory.new))
    outcome = cluster.add_trusted_root_certificate(
      Matter::Cluster::OperationalCredentials::Tlv::AddTrustedRootCertificateRequest.new(
        authority.root_certificate(0_u64)))
    outcome.status.should eq Matter::InteractionModel::StatusCode::Success
    cluster.trusted_root_certificates.size.should eq 1
  end

  it "accepts an ICAC whose identifier is zero when its chain is valid" do
    authority = TestCertificateAuthority.new
    key = Matter::Crypto::Key.generate_key_pair
    certificate = Matter::Crypto::MatterCertificate::Builder.intermediate(
      key.public_key, TestCertificateAuthority::DEFAULT_FABRIC_ID, 0_u64,
      authority.key, TestCertificateAuthority::ROOT_CERTIFICATE_ID, Bytes[1],
      issuer_certificate: authority.root_certificate)
    Matter::Crypto::MatterCertificate::Validation.verify_intermediate_profile(certificate)
  end

  it "returns the specified IM errors for invalid root commands" do
    cluster = Matter::Cluster::OperationalCredentials.new(Matter::FabricTable.new(Matter::Storage::Memory.new))
    valid = Matter::Cluster::OperationalCredentials::Tlv::AddTrustedRootCertificateRequest.new(
      TestCertificateAuthority.new.root_certificate)
    malformed = Matter::Cluster::OperationalCredentials::Tlv::AddTrustedRootCertificateRequest.new(Bytes[0x15])

    cluster.credentials.failsafe_armed = false
    cluster.add_trusted_root_certificate(valid).status.should eq Matter::InteractionModel::StatusCode::FailsafeRequired
    cluster.credentials.failsafe_armed = true
    cluster.add_trusted_root_certificate(malformed).status.should eq Matter::InteractionModel::StatusCode::InvalidCommand
    cluster.add_trusted_root_certificate(valid).status.should eq Matter::InteractionModel::StatusCode::Success
    second = Matter::Cluster::OperationalCredentials::Tlv::AddTrustedRootCertificateRequest.new(
      TestCertificateAuthority.new.root_certificate)
    cluster.add_trusted_root_certificate(second).status.should eq Matter::InteractionModel::StatusCode::ConstraintError
  end

  it "accepts an already installed root without adding a duplicate and selects it for AddNOC" do
    table = Matter::FabricTable.new(Matter::Storage::Memory.new)
    root = TestCertificateAuthority.new.root_certificate
    later_root = TestCertificateAuthority.new.root_certificate
    first = OpCredsTestHelpers.create_test_fabric(0x111_u64, 1_u8)
    second = OpCredsTestHelpers.create_test_fabric(0x222_u64, 2_u8)
    first.root_cert = root
    second.root_cert = later_root
    table.add_fabric(first)
    table.add_fabric(second)
    cluster = Matter::Cluster::OperationalCredentials.new(table)
    request = Matter::Cluster::OperationalCredentials::Tlv::AddTrustedRootCertificateRequest.new(root)

    cluster.add_trusted_root_certificate(request).status.should eq Matter::InteractionModel::StatusCode::Success
    cluster.trusted_root_certificates.size.should eq 2
    cluster.credentials.pending.root_certificate.should eq root
    cluster.add_trusted_root_certificate(request).status.should eq Matter::InteractionModel::StatusCode::Success
    cluster.trusted_root_certificates.size.should eq 2
  end
end
