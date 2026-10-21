require "../spec_helper"
require "../../src/matter/controller/joint_fabric_device_migration"

private alias Migration = Matter::Controller::JointFabricDeviceMigration
private alias MigrationDatastore = Matter::Cluster::JointFabricDatastore

private def joined_identity(bootstrap : Matter::Controller::JointCommissioning::AnchorBootstrap,
                            node_id : UInt64, key : Matter::Crypto::Key) : Matter::Controller::FabricInfo
  anchor = bootstrap.fabric
  noc = bootstrap.issue_noc(node_id, key.public_key, [0xFFFF_0001_u32])
  Matter::Controller::FabricInfo.new(anchor.fabric_id, node_id,
    anchor.ipk_value, anchor.root_cert, anchor.root_public_key,
    noc, key.private_key, nil, 0xFFF2_u16,
    anchor.intermediate_cert, nil)
end

private class MigrationPort < Migration::Port
  getter calls = [] of String
  property fail_at : String? = nil

  def commission_anchor! : Nil
    call("commission")
  end

  def verify_anchor! : Nil
    call("verify")
  end

  def add_anchor_node! : Nil
    call("add-anchor")
  end

  def remove_old_fabric! : Nil
    call("remove-fabric")
  end

  def remove_old_node! : Nil
    call("remove-old")
  end

  def verify_postcondition!(stage : Migration::Stage) : Nil
    call("reconcile-#{stage}")
  end

  def rollback_anchor!(anchor_registered : Bool) : Nil
    call("rollback-#{anchor_registered}")
  end

  def validate_journal!(journal : Migration::Journal) : Nil
  end

  private def call(name : String) : Nil
    @calls << name
    raise Matter::TransportError.new("interrupted") if @fail_at == name
  end
end

describe Migration do
  it "requires both fabric identities and explicit consent" do
    port = MigrationPort.new
    journal = Migration::Journal.new(0xB001_u64, 0xA001_u64,
      0xB002_u64, 0xA002_u64, Bytes[1], Bytes[2])
    saved = [] of Migration::Journal
    runner = Migration::Workflow.new(journal, port, -> { false }, ->(item : Migration::Journal) { saved << item })
    expect_raises(Matter::CommissioningError) { runner.run }
    port.calls.should be_empty
    saved.should be_empty
  end

  it "never removes B before A commissioning, CASE verification, and registration" do
    port = MigrationPort.new
    journal = Migration::Journal.new(0xB001_u64, 0xA001_u64,
      0xB002_u64, 0xA002_u64, Bytes[1], Bytes[2])
    saved = [] of Migration::Journal
    runner = Migration::Workflow.new(journal, port, -> { true }, ->(item : Migration::Journal) { saved << item })
    runner.run
    port.calls.should eq(["commission", "verify", "add-anchor", "remove-fabric", "remove-old"])
    runner.journal.stage.should eq(Migration::Stage::Complete)
    saved.last.stage.should eq(Migration::Stage::Complete)
  end

  it "journals uncertainty before B removal and refuses automatic replay" do
    port = MigrationPort.new
    port.fail_at = "remove-fabric"
    journal = Migration::Journal.new(0xB001_u64, 0xA001_u64,
      0xB002_u64, 0xA002_u64, Bytes[1], Bytes[2])
    saved = [] of Migration::Journal
    runner = Migration::Workflow.new(journal, port, -> { true }, ->(item : Migration::Journal) { saved << item })
    expect_raises(Matter::TransportError) { runner.run }
    runner.journal.stage.should eq(Migration::Stage::RemovingOldFabric)
    expect_raises(Matter::CommissioningError) { runner.run }
    port.calls.count("remove-fabric").should eq(1)
  end

  it "issues a device NOC under B's cross-signed ICAC for Fabric A" do
    crypto = Matter::Crypto::StandardCrypto.new
    old_fabric = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      0xB001_u64, 0xB101_u64, 0xFFF2_u16, crypto: crypto).fabric
    bootstrap = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      0xA001_u64, 0xA101_u64, 0xFFF1_u16, crypto: crypto)
    anchor = bootstrap.fabric
    joined_key = Matter::Crypto::Key.generate_key_pair
    joined = joined_identity(bootstrap, 0xA103_u64, joined_key)
    b_public = Matter::Crypto::MatterCertificate.public_key_from_tlv(old_fabric.intermediate_cert.as(Bytes))
    icac = Matter::Crypto::MatterCertificate::Builder.intermediate(
      b_public, anchor.fabric_id, 0xB101_u64,
      anchor.certificate_authority_key, 1_u64, Bytes[1], crypto)
    issuer = Migration.cross_signed_issuer(old_fabric, joined, icac,
      old_fabric.intermediate_private_key.as(Bytes))
    expect_raises(Matter::CertificateError, /joining Administrator identity/) do
      Migration.cross_signed_issuer(old_fabric, anchor, icac,
        old_fabric.intermediate_private_key.as(Bytes))
    end
    device_key = Matter::Crypto::Key.generate_key_pair
    hooks = Migration::Credentials.new(issuer, 0xFFFF_0001_u32, 0xFFF2_u16)
    credentials = hooks.issue(joined, 0xA201_u64, device_key.public_key)
    Matter::Crypto::MatterCertificate::Validation.verify_chain(credentials.noc,
      icac, anchor.root_public_key, anchor.root_cert)
    cert = Matter::Crypto::MatterCertificate.from_slice(credentials.noc)
    cert.fabric_id.should eq(anchor.fabric_id)
    cert.node_id.should eq(0xA201_u64)
    cert.ec_public_key.should eq(device_key.public_key)
    credentials.icac.should eq(icac)
    credentials.ipk.should eq(anchor.ipk_value)
    credentials.case_admin_subject.should eq(0xFFFF_FFFD_FFFF_0001_u64)
    credentials.admin_vendor_id.should eq(0xFFF2_u16)
    joined.intermediate_cert.should eq(anchor.intermediate_cert)
    joined.intermediate_cert.should_not eq(icac)
    Matter::Crypto::MatterCertificate::Validation.verify_chain(joined.controller_noc,
      joined.intermediate_cert, anchor.root_public_key, anchor.root_cert)
    expect_raises(Matter::AuthenticationError) do
      Matter::Crypto::MatterCertificate::Validation.verify_chain(credentials.noc,
        joined.intermediate_cert, anchor.root_public_key, anchor.root_cert)
    end
  end

  it "rejects a private key that cannot sign for the cross-signed ICAC" do
    crypto = Matter::Crypto::StandardCrypto.new
    old_fabric = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      0xB001_u64, 0xB101_u64, 0xFFF2_u16, crypto: crypto).fabric
    bootstrap = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      0xA001_u64, 0xA101_u64, 0xFFF1_u16, crypto: crypto)
    anchor = bootstrap.fabric
    joined_key = Matter::Crypto::Key.generate_key_pair
    joined = joined_identity(bootstrap, 0xA103_u64, joined_key)
    b_public = Matter::Crypto::MatterCertificate.public_key_from_tlv(old_fabric.intermediate_cert.as(Bytes))
    icac = Matter::Crypto::MatterCertificate::Builder.intermediate(
      b_public, anchor.fabric_id, 0xB101_u64,
      anchor.certificate_authority_key, 1_u64, Bytes[1], crypto)
    wrong = Matter::Crypto::Key.generate_key_pair
    expect_raises(Matter::CertificateError) do
      Migration.cross_signed_issuer(old_fabric, joined, icac, wrong.private_key)
    end
  end

  it "requires the authenticated Anchor GroupKeySetList IPK rather than trusting a local guess" do
    ipk = Bytes.new(16, 0xA5_u8)
    empty = MigrationDatastore::DatastoreGroupKeySetStruct.new(0_u16,
      MigrationDatastore::DatastoreGroupKeySecurityPolicyEnum::TrustFirst,
      nil, nil, nil, nil, nil, nil)
    expect_raises(Matter::AuthenticationError) do
      Migration.validate_anchor_ipk!([empty], ipk)
    end
    valid = MigrationDatastore::DatastoreGroupKeySetStruct.new(0_u16,
      MigrationDatastore::DatastoreGroupKeySecurityPolicyEnum::TrustFirst,
      ipk, 0_u64, nil, nil, nil, nil)
    Migration.validate_anchor_ipk!([valid], ipk)
    expect_raises(Matter::AuthenticationError) do
      Migration.validate_anchor_ipk!([valid, valid], ipk)
    end
  end

  it "can resume only after explicit authenticated reconciliation of a removed B fabric" do
    port = MigrationPort.new
    journal = Migration::Journal.new(0xB001_u64, 0xA001_u64,
      0xB002_u64, 0xA002_u64, Bytes[1], Bytes[2], Migration::Stage::RemovingOldFabric)
    saved = [] of Migration::Journal
    runner = Migration::Workflow.new(journal, port, -> { true }, ->(item : Migration::Journal) { saved << item })
    expect_raises(Matter::ConfigurationError) { runner.reconcile!(Migration::Stage::AnchorVerified) }
    runner.reconcile!(Migration::Stage::OldFabricRemoved)
    runner.run
    port.calls.should eq(["reconcile-OldFabricRemoved", "remove-old"])
    runner.journal.stage.should eq(Migration::Stage::Complete)
  end

  it "persists an uncertain removal boundary under both full fabric identities" do
    backend = Matter::Storage::Memory.new
    store = Migration::JournalStore.new(backend)
    journal = Migration::Journal.new(0xB001_u64, 0xA001_u64,
      0xB002_u64, 0xA002_u64, Bytes[1, 2], Bytes[3, 4],
      Migration::Stage::RemovingOldFabric)
    store.save(journal)
    loaded = store.load(0xB001_u64, Bytes[1, 2], 0xB002_u64,
      0xA001_u64, Bytes[3, 4], 0xA002_u64)
    loaded.should_not be_nil
    loaded.as(Migration::Journal).stage.should eq(Migration::Stage::RemovingOldFabric)
    store.load(0xB001_u64, Bytes[9], 0xB002_u64,
      0xA001_u64, Bytes[3, 4], 0xA002_u64).should be_nil
  end

  it "rolls back A only while B is still installed, with a durable uncertainty boundary" do
    port = MigrationPort.new
    journal = Migration::Journal.new(0xB001_u64, 0xA001_u64,
      0xB002_u64, 0xA002_u64, Bytes[1], Bytes[2], Migration::Stage::AnchorNodeAdded)
    saved = [] of Migration::Journal
    runner = Migration::Workflow.new(journal, port, -> { true }, ->(item : Migration::Journal) { saved << item })
    port.fail_at = "rollback-true"
    expect_raises(Matter::TransportError) { runner.rollback! }
    runner.journal.stage.should eq(Migration::Stage::RollingBack)
    expect_raises(Matter::CommissioningError) { runner.run }
    port.fail_at = nil
    runner.reconcile!(Migration::Stage::RolledBack)
    runner.journal.stage.should eq(Migration::Stage::RolledBack)
    port.calls.should eq(["rollback-true", "reconcile-RolledBack"])
    saved.map(&.stage).should eq([Migration::Stage::RollingBack, Migration::Stage::RolledBack])
  end

  it "refuses rollback after B removal begins" do
    port = MigrationPort.new
    journal = Migration::Journal.new(0xB001_u64, 0xA001_u64,
      0xB002_u64, 0xA002_u64, Bytes[1], Bytes[2], Migration::Stage::RemovingOldFabric)
    runner = Migration::Workflow.new(journal, port, -> { true }, ->(_item : Migration::Journal) { })
    expect_raises(Matter::CommissioningError) { runner.rollback! }
    port.calls.should be_empty
  end

  it "requires an installed cross-signed Anchor identity before network migration" do
    crypto = Matter::Crypto::StandardCrypto.new
    old_fabric = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      0xB001_u64, 0xB101_u64, 0xFFF2_u16, crypto: crypto).fabric
    anchor = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      0xA001_u64, 0xA101_u64, 0xFFF1_u16, crypto: crypto).fabric
    store = Matter::Controller::StateStore.new(Matter::Storage::Memory.new)
    peer = Socket::IPAddress.new("127.0.0.1", 5540)
    verifier = Matter::Controller::DeviceAttestationVerifier.new(
      Matter::Controller::AttestationTrustStore.matter_test_fixture)
    expect_raises(Matter::ConfigurationError) do
      issuer = Migration::CrossSignedIssuer.new(Bytes.empty, Bytes.empty, 0_u64, Bytes.empty, Bytes.empty)
      Migration::NetworkPort.new(store, old_fabric, anchor, issuer, 0xB201_u64, 0xA201_u64,
        peer, 0xB101_u64, peer, 1_u16, 0xA101_u64, peer, 1_u16,
        "Existing device", 0xFFFF_0001_u32, verifier, timeout: 1.millisecond)
    end
  end

  it "accepts a locally held cross-signed B key for the network adapter" do
    crypto = Matter::Crypto::StandardCrypto.new
    old_fabric = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      0xB001_u64, 0xB101_u64, 0xFFF2_u16, crypto: crypto).fabric
    bootstrap = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      0xA001_u64, 0xA101_u64, 0xFFF1_u16, crypto: crypto)
    anchor = bootstrap.fabric
    joined_key = Matter::Crypto::Key.generate_key_pair
    joined = joined_identity(bootstrap, 0xA103_u64, joined_key)
    b_icac = old_fabric.intermediate_cert || raise "Fixture ICAC missing"
    b_public = Matter::Crypto::MatterCertificate.public_key_from_tlv(b_icac)
    signed = Matter::Crypto::MatterCertificate::Builder.intermediate(
      b_public, anchor.fabric_id, 0xB101_u64,
      anchor.certificate_authority_key, 1_u64, Bytes[2], crypto)
    b_private = old_fabric.intermediate_private_key || raise "Fixture ICAC key missing"
    issuer = Migration.cross_signed_issuer(old_fabric, joined, signed, b_private)
    store = Matter::Controller::StateStore.new(Matter::Storage::Memory.new)
    state = store.load
    state.install_fabric(joined)
    store.save(state)
    peer = Socket::IPAddress.new("127.0.0.1", 5540)
    verifier = Matter::Controller::DeviceAttestationVerifier.new(
      Matter::Controller::AttestationTrustStore.matter_test_fixture)
    port = Migration::NetworkPort.new(store, old_fabric, joined, issuer,
      0xB201_u64, 0xA201_u64, peer, 0xB101_u64, peer, 1_u16,
      0xA101_u64, peer, 1_u16, "Existing device", 0xFFFF_0001_u32,
      verifier, timeout: 1.millisecond)
    joined.root_private_key.should be_nil
    expect_raises(Matter::CommissioningError, /durable CommissioningComplete/) do
      port.verify_postcondition!(Migration::Stage::AnchorCommissioned)
    end
    expect_raises(Matter::AuthenticationError) do
      port.validate_journal!(Migration::Journal.new(old_fabric.fabric_id,
        anchor.fabric_id, 0xB201_u64, 0xA201_u64,
        Bytes[9], anchor.root_public_key))
    end
    # Keep each wire method typechecked without requiring a live device in
    # the unit test process. The live migration path still needs Docker e2e.
    if ENV["MATTER_MIGRATION_LIVE_SPEC"]? == "1"
      port.commission_anchor!
      port.verify_anchor!
      port.add_anchor_node!
      port.remove_old_fabric!
      port.remove_old_node!
      port.anchor_present?
      port.old_fabric_absent?
      port.verify_postcondition!(Migration::Stage::Complete)
    end
    port.close
  end
end
