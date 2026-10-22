require "../support/operational_credentials_helpers"

private def rollback_test_cluster : {Matter::Cluster::OperationalCredentials, UInt8}
  cluster = build_op_creds_cluster
  cluster.failsafe_armed = true
  service = cluster.credentials
  csr = service.create_csr(Bytes.new(32, 0x42_u8), 42_u64, false, true).as(Tuple(Bytes, Bytes))[0]
  elements = Matter::Commissioning::CredentialService::CSRElements.from_slice(csr)
  public_key = Matter::Controller::CertificateUtil.extract_uncompressed_public_key_from_csr(elements.csr)
  service.add_trusted_root_certificate(TestCertificateAuthority.default.root_certificate).ok?.should be_true
  noc = TestCertificateAuthority.default.issue(0x1111_u64, 0x2222_u64, public_key)
  outcome = service.add_noc(noc, nil, Bytes.new(16), 0x3333_u64, 0xFFF1_u16, 42_u64)
  outcome.ok?.should be_true
  {cluster, outcome.fabric_index.as(UInt8)}
end

describe "OperationalCredentials fail-safe NOC rollback" do
  it "rolls back an uncommitted fabric through the ArmFailSafe zero-expiry command" do
    cluster, index = rollback_test_cluster
    commissioning = Matter::Cluster::GeneralCommissioning.new
    commissioning.on_failsafe_expired = -> { cluster.on_failsafe_expired }
    arm = Matter::Cluster::GeneralCommissioning::ArmFailSafeRequest.new(60_u16, 1_u64)
    commissioning.invoke_command(
      Matter::Cluster::GeneralCommissioning::CMD_ARM_FAIL_SAFE,
      arm.to_tlv(nil), is_case_session: true, fabric_index: index)
    commissioning.failsafe_armed?.should be_true

    disarm = Matter::Cluster::GeneralCommissioning::ArmFailSafeRequest.new(0_u16, 2_u64)
    commissioning.invoke_command(
      Matter::Cluster::GeneralCommissioning::CMD_ARM_FAIL_SAFE,
      disarm.to_tlv(nil), is_case_session: true, fabric_index: index)

    commissioning.failsafe_armed?.should be_false
    cluster.fabric_table.get_fabric(index).should be_nil
  end

  it "keeps the new fabric when CommissioningComplete succeeds" do
    cluster, index = rollback_test_cluster
    commissioning = Matter::Cluster::GeneralCommissioning.new
    commissioning.on_failsafe_expired = -> { cluster.on_failsafe_expired }
    commissioning.on_failsafe_success = -> { cluster.on_failsafe_success }
    commissioning.arm_failsafe(
      Matter::Cluster::GeneralCommissioning::ArmFailSafeRequest.new(60_u16, 1_u64),
      index, false).error_code.ok?.should be_true

    commissioning.commissioning_complete(index, true).error_code.ok?.should be_true
    cluster.fabric_table.get_fabric(index).should_not be_nil
    Matter::FabricTable.new(cluster.fabric_table.backend).get_fabric(index).should_not be_nil
  end

  it "removes a newly added fabric when the fail-safe expires" do
    cluster, index = rollback_test_cluster
    removed = [] of UInt8
    changed = [] of UInt32
    cluster.on_fabric_removed = ->(fabric_index : UInt8) { removed << fabric_index; nil }
    cluster.on_attribute_changed = ->(_endpoint : UInt16, _cluster : UInt32, attribute : UInt32) {
      changed << attribute
      nil
    }
    cluster.fabric_table.get_fabric(index).should_not be_nil

    cluster.on_failsafe_expired

    cluster.fabric_table.get_fabric(index).should be_nil
    cluster.fabrics.should be_empty
    cluster.nocs.should be_empty
    Matter::FabricTable.new(cluster.fabric_table.backend).get_fabric(index).should be_nil
    removed.should eq([index])
    changed.should contain(Matter::Cluster::OperationalCredentials::ATTR_FABRICS)
    changed.should contain(Matter::Cluster::OperationalCredentials::ATTR_NOCS)
  end

  it "restores the previous CASE identity after an uncommitted UpdateNOC" do
    cluster, index = rollback_test_cluster
    original = cluster.fabric_table.get_fabric(index).as(Matter::Fabric)
    original_noc = original.operational_cert.dup
    original_key = original.operational_key.public_key.dup
    original_node_id = original.node_id
    original_destination_id = original.compute_destination_id(Bytes.new(32, 0x55_u8))
    advertised_nodes = [] of UInt64
    changed = [] of UInt32
    cluster.on_fabric_updated = ->(fabric : Matter::Fabric) { advertised_nodes << fabric.node_id; nil }
    cluster.on_attribute_changed = ->(_endpoint : UInt16, _cluster : UInt32, attribute : UInt32) {
      changed << attribute
      nil
    }
    cluster.on_failsafe_success
    cluster.failsafe_armed = true

    service = cluster.credentials
    csr = service.create_csr(Bytes.new(32, 0x43_u8), 43_u64, true, false).as(Tuple(Bytes, Bytes))[0]
    elements = Matter::Commissioning::CredentialService::CSRElements.from_slice(csr)
    public_key = Matter::Controller::CertificateUtil.extract_uncompressed_public_key_from_csr(elements.csr)
    replacement = TestCertificateAuthority.default.issue(0x1111_u64, 0x7777_u64, public_key)
    service.update_noc(replacement, nil, index, 43_u64).ok?.should be_true
    cluster.fabric_table.get_fabric(index).as(Matter::Fabric).node_id.should eq(0x7777_u64)

    changed.clear
    cluster.on_failsafe_expired

    restored = cluster.fabric_table.get_fabric(index).as(Matter::Fabric)
    restored.operational_cert.should eq(original_noc)
    restored.operational_key.public_key.should eq(original_key)
    restored.node_id.should eq(original_node_id)
    restored.compute_destination_id(Bytes.new(32, 0x55_u8)).should eq(original_destination_id)
    persisted = Matter::FabricTable.new(cluster.fabric_table.backend).get_fabric(index).as(Matter::Fabric)
    persisted.operational_cert.should eq(original_noc)
    persisted.operational_key.public_key.should eq(original_key)
    persisted.node_id.should eq(original_node_id)
    advertised_nodes.should eq([0x7777_u64, original_node_id])
    changed.should contain(Matter::Cluster::OperationalCredentials::ATTR_FABRICS)
    changed.should contain(Matter::Cluster::OperationalCredentials::ATTR_NOCS)
  end
end
