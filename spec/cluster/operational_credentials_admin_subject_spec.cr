require "../support/operational_credentials_helpers"

private def prepared_add_noc_subject_test
  table = Matter::FabricTable.new(Matter::Storage::Memory.new)
  acl = Matter::Cluster::AccessControl.new(endpoint(0))
  cluster = Matter::Cluster::OperationalCredentials.new(table, acl)
  cluster.set_attestation_credentials(Bytes.new(100, 1_u8), Bytes.new(100, 2_u8),
    Matter::Crypto::Key.generate_key_pair)
  csr = cluster.handle_csr_request(
    Matter::Cluster::OperationalCredentials::CSRRequestCommand.new(csr_nonce: Bytes.new(32)),
    session_id: 1_u64, is_pase_session: true, failsafe_armed: true
  ).as(Matter::Cluster::OperationalCredentials::CSRResponse)
  cluster.handle_add_trusted_root_certificate(
    Matter::Cluster::OperationalCredentials::AddTrustedRootCertificateCommand.new(
      root_ca_certificate: TestCertificateAuthority.default.root_certificate),
    failsafe_armed: true)
  noc = TestCertificateAuthority.default.issue(
    TestCertificateAuthority::DEFAULT_FABRIC_ID,
    TestCertificateAuthority::DEFAULT_NODE_ID,
    csr_public_key(csr))
  {cluster, table, acl, noc}
end

describe "OperationalCredentials AddNOC CaseAdminSubject" do
  it "rejects reserved subjects without consuming the pending CSR or changing fabric and ACL state" do
    cluster, table, acl, noc = prepared_add_noc_subject_test
    invalid_subjects = [
      0_u64,
      Matter::DataType::NodeId::OPERATIONAL_MAXIMUM + 1_u64,
      Matter::DataType::NodeId::CAT_PREFIX | 0x0001_0000_u64,
      Matter::DataType::NodeId.group(1_u16).id,
      UInt64::MAX,
    ]

    invalid_subjects.each do |subject|
      request = Matter::Cluster::OperationalCredentials::AddNOCCommand.new(
        noc_value: noc, icac_value: nil, ipk_value: Bytes.new(16),
        case_admin_subject: subject, admin_vendor_id: 0xFFF1_u16)
      response = cluster.handle_add_noc(request, session_id: 1_u64, failsafe_armed: true)
      response.status_code.should eq(Matter::Cluster::OperationalCredentials::NodeOperationalCertStatus::InvalidAdminSubject)
      table.size.should eq(0)
      acl.acl.should be_empty
    end

    valid = Matter::Cluster::OperationalCredentials::AddNOCCommand.new(
      noc_value: noc, icac_value: nil, ipk_value: Bytes.new(16),
      case_admin_subject: 1_u64, admin_vendor_id: 0xFFF1_u16)
    cluster.handle_add_noc(valid, session_id: 1_u64, failsafe_armed: true).status_code.should eq(
      Matter::Cluster::OperationalCredentials::NodeOperationalCertStatus::Ok)
    table.size.should eq(1)
    acl.acl.first.subjects.should eq([1_u64])
  end

  it "accepts a CASE Authenticated Tag with a nonzero version" do
    cluster, table, acl, noc = prepared_add_noc_subject_test
    cat_subject = Matter::DataType::NodeId::CAT_PREFIX | 0x0001_0001_u64
    request = Matter::Cluster::OperationalCredentials::AddNOCCommand.new(
      noc_value: noc, icac_value: nil, ipk_value: Bytes.new(16),
      case_admin_subject: cat_subject, admin_vendor_id: 0xFFF1_u16)

    cluster.handle_add_noc(request, session_id: 1_u64, failsafe_armed: true).status_code.should eq(
      Matter::Cluster::OperationalCredentials::NodeOperationalCertStatus::Ok)
    table.size.should eq(1)
    acl.acl.first.subjects.should eq([cat_subject])
  end
end
