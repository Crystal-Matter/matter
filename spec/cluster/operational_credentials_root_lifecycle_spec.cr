require "../support/operational_credentials_helpers"

private def root_list(cluster : Matter::Cluster::OperationalCredentials, fabric_index : UInt8? = nil) : Array(Bytes)
  cluster.read_attribute(Matter::Cluster::OperationalCredentials::ATTR_TRUSTED_ROOT_CERTIFICATES, fabric_index)
    .as(TLV::Any).as_list.map { |entry| entry.value.as(Bytes) }
end

describe "OperationalCredentials TrustedRootCertificates lifecycle" do
  it "drops a pending root when the fail-safe expires without AddNOC" do
    cluster = build_op_creds_cluster
    root = TestCertificateAuthority.new.root_certificate
    request = Matter::Cluster::OperationalCredentials::Tlv::AddTrustedRootCertificateRequest.new(root)

    cluster.add_trusted_root_certificate(request).status.should eq Matter::InteractionModel::StatusCode::Success
    root_list(cluster).should eq([root])
    cluster.on_failsafe_expired
    root_list(cluster).should be_empty

    # A rolled-back root is no longer treated as an installed root.
    cluster.add_trusted_root_certificate(request).status.should eq Matter::InteractionModel::StatusCode::Success
    root_list(cluster).should eq([root])
  end

  it "removes only the removed fabric's root on authenticated RemoveFabric" do
    table = OpCredsTestHelpers.create_fabric_table
    first = OpCredsTestHelpers.create_test_fabric(0x111_u64, 1_u8)
    second = OpCredsTestHelpers.create_test_fabric(0x222_u64, 2_u8)
    first.root_cert = TestCertificateAuthority.new.root_certificate
    second.root_cert = TestCertificateAuthority.new.root_certificate
    table.add_fabric(first)
    table.add_fabric(second)
    cluster = Matter::Cluster::OperationalCredentials.new(table)

    root_list(cluster, first.fabric_index).should eq([first.root_cert, second.root_cert].map(&.as(Bytes)))
    response = cluster.invoke_command(
      Matter::Cluster::OperationalCredentials::CMD_REMOVE_FABRIC,
      Matter::Cluster::OperationalCredentials::Tlv::RemoveFabricRequest.new(first.fabric_index).to_tlv(nil),
      is_case_session: true, fabric_index: first.fabric_index)
    Matter::Cluster::OperationalCredentials::Tlv::TlvNocResponse.from_slice(
      response.as(Matter::Cluster::CommandResponse).response.as(TLV::Any).to_slice).status_code.should eq Matter::Cluster::OperationalCredentials::Tlv::NodeOperationalCertificateStatus::Ok
    root_list(cluster, second.fabric_index).should eq([second.root_cert.as(Bytes)])
    root_list(Matter::Cluster::OperationalCredentials.new(Matter::FabricTable.new(table.backend))).should eq([second.root_cert.as(Bytes)])
  end

  it "keeps one root per installed fabric when they share an RCAC, including after restart" do
    table = OpCredsTestHelpers.create_fabric_table
    root = TestCertificateAuthority.new.root_certificate
    first = OpCredsTestHelpers.create_test_fabric(0x333_u64, 1_u8)
    second = OpCredsTestHelpers.create_test_fabric(0x444_u64, 2_u8)
    first.root_cert = root
    second.root_cert = root
    table.add_fabric(first)
    table.add_fabric(second)

    cluster = Matter::Cluster::OperationalCredentials.new(table)
    root_list(cluster, first.fabric_index).should eq([root, root])
    root_list(Matter::Cluster::OperationalCredentials.new(Matter::FabricTable.new(table.backend))).should eq([root, root])
  end
end
