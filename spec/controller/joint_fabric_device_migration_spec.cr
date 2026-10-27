require "../spec_helper"
require "../../src/matter/controller/joint_fabric_device_migration"
require "../../src/matter/controller/shared_fabric"

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
  property? no_effect : Bool = true
  property? postcondition : Bool = true

  def commission_anchor! : Nil
    call("commission")
  end

  def verify_anchor! : Nil
    call("verify")
  end

  def add_anchor_node! : Nil
    call("add-anchor")
  end

  def refresh_anchor_registration! : Nil
    call("refresh-anchor")
  end

  def remove_old_fabric! : Nil
    call("remove-fabric")
  end

  def remove_old_node! : Nil
    call("remove-old")
  end

  def verify_postcondition!(stage : Migration::Stage) : Nil
    call("reconcile-#{stage}")
    raise Matter::CommissioningError.new("postcondition not proven") unless postcondition?
  end

  def verify_no_effect!(stage : Migration::Stage) : Nil
    call("no-effect-#{stage}")
    raise Matter::CommissioningError.new("operation took effect") unless @no_effect
  end

  def rollback_anchor!(anchor_registered : Bool) : Nil
    call("rollback-#{anchor_registered}")
  end

  def resume_rollback! : Nil
    call("resume-rollback")
  end

  def finalize_rollback! : Nil
    call("finalize-rollback")
  end

  def validate_journal!(journal : Migration::Journal) : Nil
  end

  private def call(name : String) : Nil
    @calls << name
    raise Matter::TransportError.new("interrupted") if @fail_at == name
  end
end

private class MigrationRecoveryNetworkPort < Migration::NetworkPort
  property? anchor_verified : Bool = false
  property? old_verified : Bool = false

  def verify_anchor! : Nil
    raise Matter::AuthenticationError.new("A CASE verification failed") unless anchor_verified?
  end

  private def require_old_fabric_present! : Nil
    raise Matter::AuthenticationError.new("B CASE verification failed") unless old_verified?
  end

  private def verify_handoff_baseline! : Nil
    raise Matter::AuthenticationError.new("B ownership verification failed") unless old_verified?
  end
end

private class MigrationRollbackNetworkPort < Migration::NetworkPort
  property? remote_rolled_back : Bool = false

  def verify_postcondition!(stage : Migration::Stage) : Nil
    raise Matter::CommissioningError.new("Remote rollback is incomplete") unless stage.rolled_back? && remote_rolled_back?
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

  it "recovers a restarted journal only after proof that each command had no effect" do
    boundaries = {
      {"commission", Migration::Stage::CommissioningAnchor, Migration::Stage::Ready},
      {"verify", Migration::Stage::VerifyingAnchor, Migration::Stage::AnchorCommissioned},
      {"add-anchor", Migration::Stage::AddingAnchorNode, Migration::Stage::AnchorVerified},
      {"remove-fabric", Migration::Stage::RemovingOldFabric, Migration::Stage::AnchorNodeAdded},
      {"remove-old", Migration::Stage::RemovingOldNode, Migration::Stage::OldFabricRemoved},
    }
    boundaries.each do |command, uncertain, previous|
      backend = Matter::Storage::Memory.new
      store = Migration::JournalStore.new(backend)
      port = MigrationPort.new
      port.fail_at = command
      journal = Migration::Journal.new(0xB001_u64, 0xA001_u64,
        0xB002_u64, 0xA002_u64, Bytes[1], Bytes[2], previous)
      runner = Migration::Workflow.new(journal, port, -> { true },
        ->(item : Migration::Journal) { store.save(item) })
      expect_raises(Matter::TransportError) { runner.run }
      store.load(0xB001_u64, Bytes[1], 0xB002_u64,
        0xA001_u64, Bytes[2], 0xA002_u64).as(Migration::Journal).stage.should eq(uncertain)

      restarted = Migration::Workflow.new(store.load(0xB001_u64, Bytes[1], 0xB002_u64,
        0xA001_u64, Bytes[2], 0xA002_u64).as(Migration::Journal), port,
        -> { true }, ->(item : Migration::Journal) { store.save(item) })
      port.postcondition = false if command == "commission"
      expect_raises(Matter::CommissioningError) { restarted.run }
      port.no_effect = false
      expect_raises(Matter::CommissioningError) { restarted.reconcile_no_effect! }
      restarted.journal.stage.should eq(uncertain)
      port.no_effect = true
      restarted.reconcile_no_effect!
      restarted.journal.stage.should eq(previous)
      port.fail_at = nil
      restarted.run
      restarted.journal.stage.should eq(Migration::Stage::Complete)
      port.calls.count(command).should eq(2)
    end
  end

  it "recovers completed commands with lost replies without issuing them twice" do
    boundaries = {
      {"commission", Migration::Stage::CommissioningAnchor, Migration::Stage::AnchorCommissioned},
      {"verify", Migration::Stage::VerifyingAnchor, Migration::Stage::AnchorVerified},
      {"add-anchor", Migration::Stage::AddingAnchorNode, Migration::Stage::AnchorNodeAdded},
      {"remove-fabric", Migration::Stage::RemovingOldFabric, Migration::Stage::OldFabricRemoved},
      {"remove-old", Migration::Stage::RemovingOldNode, Migration::Stage::Complete},
    }
    boundaries.each do |command, uncertain, observed|
      backend = Matter::Storage::Memory.new
      store = Migration::JournalStore.new(backend)
      port = MigrationPort.new
      port.fail_at = command
      journal = Migration::Journal.new(0xB001_u64, 0xA001_u64,
        0xB002_u64, 0xA002_u64, Bytes[1], Bytes[2])
      runner = Migration::Workflow.new(journal, port, -> { true },
        ->(item : Migration::Journal) { store.save(item) })
      expect_raises(Matter::TransportError) { runner.run }
      restarted = Migration::Workflow.new(store.load(0xB001_u64, Bytes[1], 0xB002_u64,
        0xA001_u64, Bytes[2], 0xA002_u64).as(Migration::Journal), port,
        -> { true }, ->(item : Migration::Journal) { store.save(item) })
      restarted.journal.stage.should eq(uncertain)
      if command == "commission"
        port.fail_at = nil
        restarted.run
        restarted.journal.stage.should eq(Migration::Stage::Complete)
        port.calls.count(command).should eq(1)
        next
      end
      expect_raises(Matter::CommissioningError) { restarted.run }
      port.no_effect = false
      expect_raises(Matter::CommissioningError) { restarted.reconcile_no_effect! }
      restarted.reconcile!(observed)
      port.fail_at = nil
      restarted.run
      restarted.journal.stage.should eq(Migration::Stage::Complete)
      port.calls.count(command).should eq(1)
    end
  end

  it "automatically resumes commissioning after restart only after a verified postcondition" do
    backend = Matter::Storage::Memory.new
    store = Migration::JournalStore.new(backend)
    journal = Migration::Journal.new(0xB001_u64, 0xA001_u64,
      0xB002_u64, 0xA002_u64, Bytes[1], Bytes[2], Migration::Stage::CommissioningAnchor)
    store.save(journal)
    port = MigrationPort.new
    port.fail_at = "reconcile-AnchorCommissioned"
    restarted = Migration::Workflow.new(store.load(0xB001_u64, Bytes[1], 0xB002_u64,
      0xA001_u64, Bytes[2], 0xA002_u64).as(Migration::Journal), port,
      -> { true }, ->(item : Migration::Journal) { store.save(item) })
    expect_raises(Matter::TransportError) { restarted.run }
    restarted.journal.stage.should eq(Migration::Stage::CommissioningAnchor)
    port.calls.should eq(["reconcile-AnchorCommissioned"])
    port.fail_at = nil
    restarted.run
    restarted.journal.stage.should eq(Migration::Stage::Complete)
    port.calls.count("commission").should eq(0)
    port.calls.should eq(["reconcile-AnchorCommissioned", "reconcile-AnchorCommissioned",
                          "verify", "add-anchor", "remove-fabric", "remove-old"])
  end

  it "persists an interrupted migration across a fresh file backend" do
    path = File.join(Dir.tempdir, "matter-migration-#{Random::Secure.hex(8)}.json")
    begin
      first_backend = Matter::Storage::JsonFile.new(path)
      first_store = Migration::JournalStore.new(first_backend)
      port = MigrationPort.new
      port.fail_at = "remove-old"
      journal = Migration::Journal.new(0xB001_u64, 0xA001_u64,
        0xB002_u64, 0xA002_u64, Bytes[1], Bytes[2])
      runner = Migration::Workflow.new(journal, port, -> { true },
        ->(item : Migration::Journal) { first_store.save(item) })
      expect_raises(Matter::TransportError) { runner.run }
      first_backend.close

      reopened_backend = Matter::Storage::JsonFile.new(path)
      reopened_store = Migration::JournalStore.new(reopened_backend)
      persisted = reopened_store.load(0xB001_u64, Bytes[1], 0xB002_u64,
        0xA001_u64, Bytes[2], 0xA002_u64).as(Migration::Journal)
      persisted.stage.should eq(Migration::Stage::RemovingOldNode)
      restarted = Migration::Workflow.new(persisted, port, -> { true },
        ->(item : Migration::Journal) { reopened_store.save(item) })
      restarted.reconcile_no_effect!
      restarted.journal.stage.should eq(Migration::Stage::OldFabricRemoved)
      port.fail_at = nil
      restarted.run
      reopened_store.load(0xB001_u64, Bytes[1], 0xB002_u64,
        0xA001_u64, Bytes[2], 0xA002_u64).as(Migration::Journal).stage.should eq(Migration::Stage::Complete)
      reopened_backend.close
    ensure
      File.delete?(path)
    end
  end

  it "persists the CommissioningComplete acknowledgement before local node recovery" do
    backend = Matter::Storage::Memory.new
    store = Migration::JournalStore.new(backend)
    journal = Migration::Journal.new(0xB001_u64, 0xA001_u64,
      0xB002_u64, 0xA002_u64, Bytes[1], Bytes[2], Migration::Stage::CommissioningAnchor)
    store.save(journal)
    callback = -> {
      current = store.load(0xB001_u64, Bytes[1], 0xB002_u64,
        0xA001_u64, Bytes[2], 0xA002_u64).as(Migration::Journal)
      current.commissioning_acknowledged = true
      store.save(current)
    }
    deadline_callback = ->(deadline : Int64, max_seconds : UInt16) {
      current = store.load(0xB001_u64, Bytes[1], 0xB002_u64,
        0xA001_u64, Bytes[2], 0xA002_u64).as(Migration::Journal)
      current.fail_safe_deadline_unix = deadline
      current.fail_safe_max_seconds = max_seconds
      store.save(current)
    }
    issuer = Migration::CrossSignedIssuer.new(Bytes.empty, Bytes.empty,
      0xA001_u64, Bytes[2], Bytes[1])
    hooks = Migration::Credentials.new(issuer, 0xFFFF_0001_u32, 0xFFF2_u16,
      Matter::Crypto::StandardCrypto.new, callback, deadline_callback)
    fabric = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      0xA001_u64, 0xA101_u64, 0xFFF1_u16).fabric
    hooks.record_fail_safe_deadline?.should be_true
    hooks.fail_safe_deadline_observed(1_000_i64, 60_u16)
    hooks.complete_acknowledged(fabric, 0xA002_u64,
      Socket::IPAddress.new("127.0.0.1", 5540))
    loaded = store.load(0xB001_u64, Bytes[1], 0xB002_u64,
      0xA001_u64, Bytes[2], 0xA002_u64).as(Migration::Journal)
    loaded.stage.should eq(Migration::Stage::CommissioningAnchor)
    loaded.commissioning_acknowledged?.should be_true
    loaded.fail_safe_deadline_unix.should eq(1_000_i64)
    loaded.fail_safe_max_seconds.should eq(60_u16)
    legacy_document = journal.to_document
    legacy_document.delete("commissioning_acknowledged")
    Migration::Journal.from_document(legacy_document).commissioning_acknowledged?.should be_false
    legacy_document.delete("fail_safe_deadline_unix")
    Migration::Journal.from_document(legacy_document).fail_safe_deadline_unix.should be_nil
    legacy_document.delete("fail_safe_max_seconds")
    Migration::Journal.from_document(legacy_document).fail_safe_max_seconds.should be_nil
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

  it "delegates a B-signed group-CAT controller on A's shared fabric" do
    crypto = Matter::Crypto::StandardCrypto.new
    old_fabric = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      0xB001_u64, 0xB101_u64, 0xFFF2_u16, crypto: crypto).fabric
    bootstrap = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      0xA001_u64, 0xA101_u64, 0xFFF1_u16, crypto: crypto)
    joined = joined_identity(bootstrap, 0xA103_u64, Matter::Crypto::Key.generate_key_pair)
    b_public = Matter::Crypto::MatterCertificate.public_key_from_tlv(old_fabric.intermediate_cert.as(Bytes))
    icac = Matter::Crypto::MatterCertificate::Builder.intermediate(
      b_public, joined.fabric_id, 0xB101_u64,
      bootstrap.fabric.certificate_authority_key, 1_u64, Bytes[1], crypto)
    issuer = Migration.cross_signed_issuer(old_fabric, joined, icac,
      old_fabric.intermediate_private_key.as(Bytes))

    delegated = issuer.delegate_controller(joined, 0xA105_u64, 0x1234_u16, 2_u16, crypto)
    delegated.fabric_id.should eq(joined.fabric_id)
    delegated.root_cert.should eq(joined.root_cert)
    delegated.ipk_value.should eq(joined.ipk_value)
    delegated.admin_vendor_id.should eq(old_fabric.admin_vendor_id)
    delegated.intermediate_cert.should eq(icac)
    delegated.intermediate_private_key.should be_nil
    Matter::Crypto::MatterCertificate::Validation.verify_chain(delegated.controller_noc,
      icac, joined.root_public_key, joined.root_cert)
    cert = Matter::Crypto::MatterCertificate.from_slice(delegated.controller_noc)
    cert.node_id.should eq(0xA105_u64)
    subjects = Matter::Crypto::MatterCertificate.subject_ids_from_tlv(delegated.controller_noc)
    subjects.should contain(0xA105_u64)
    subjects.should contain(0xFFFF_FFFD_1234_0002_u64)
    Matter::Controller::SharedFabric.install(
      Matter::Controller::StateStore.new(Matter::Storage::Memory.new), delegated)

    expect_raises(Matter::ConfigurationError) do
      issuer.delegate_controller(joined, joined.controller_node_id, 0x1234_u16, 2_u16, crypto)
    end
    expect_raises(Matter::ConfigurationError) do
      issuer.delegate_controller(joined, 0xA106_u64, 0xFFFF_u16, 2_u16, crypto)
    end
    expect_raises(Matter::ConfigurationError) do
      issuer.delegate_controller(joined, 0xA106_u64, 0x1234_u16, 0_u16, crypto)
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
    port.calls.should eq(["rollback-true", "reconcile-RolledBack", "finalize-rollback"])
    saved.map(&.stage).should eq([Migration::Stage::RollingBack, Migration::Stage::RolledBack])
  end

  it "resumes a partially completed rollback after restart only on explicit request" do
    backend = Matter::Storage::Memory.new
    store = Migration::JournalStore.new(backend)
    port = MigrationPort.new
    port.fail_at = "rollback-true"
    journal = Migration::Journal.new(0xB001_u64, 0xA001_u64,
      0xB002_u64, 0xA002_u64, Bytes[1], Bytes[2], Migration::Stage::AnchorNodeAdded)
    runner = Migration::Workflow.new(journal, port, -> { true },
      ->(item : Migration::Journal) { store.save(item) })
    expect_raises(Matter::TransportError) { runner.rollback! }
    persisted = store.load(0xB001_u64, Bytes[1], 0xB002_u64,
      0xA001_u64, Bytes[2], 0xA002_u64).as(Migration::Journal)
    persisted.stage.should eq(Migration::Stage::RollingBack)
    restarted = Migration::Workflow.new(persisted, port, -> { true },
      ->(item : Migration::Journal) { store.save(item) })
    expect_raises(Matter::CommissioningError) { restarted.run }
    port.fail_at = "resume-rollback"
    expect_raises(Matter::TransportError) { restarted.resume_rollback! }
    restarted.journal.stage.should eq(Migration::Stage::RollingBack)
    port.fail_at = nil
    restarted.resume_rollback!
    restarted.journal.stage.should eq(Migration::Stage::RolledBack)
    port.calls.should eq(["rollback-true", "resume-rollback", "resume-rollback", "finalize-rollback"])
  end

  it "keeps rollback uncertain when controller cleanup fails after remote removal" do
    backend = Matter::Storage::Memory.new
    store = Migration::JournalStore.new(backend)
    port = MigrationPort.new
    port.fail_at = "finalize-rollback"
    journal = Migration::Journal.new(0xB001_u64, 0xA001_u64,
      0xB002_u64, 0xA002_u64, Bytes[1], Bytes[2], Migration::Stage::AnchorNodeAdded)
    runner = Migration::Workflow.new(journal, port, -> { true },
      ->(item : Migration::Journal) { store.save(item) })
    expect_raises(Matter::TransportError) { runner.rollback! }
    stored = store.load(0xB001_u64, Bytes[1], 0xB002_u64,
      0xA001_u64, Bytes[2], 0xA002_u64).as(Migration::Journal)
    stored.stage.should eq(Migration::Stage::RollingBack)
    restarted = Migration::Workflow.new(stored, port, -> { true },
      ->(item : Migration::Journal) { store.save(item) })
    port.fail_at = nil
    restarted.reconcile!(Migration::Stage::RolledBack)
    restarted.journal.stage.should eq(Migration::Stage::RolledBack)
    port.calls.should eq(["rollback-true", "finalize-rollback", "reconcile-RolledBack", "finalize-rollback"])
  end

  it "refreshes an uncertain pending Anchor registration without repeating AddPendingNode" do
    backend = Matter::Storage::Memory.new
    store = Migration::JournalStore.new(backend)
    port = MigrationPort.new
    port.fail_at = "add-anchor"
    journal = Migration::Journal.new(0xB001_u64, 0xA001_u64,
      0xB002_u64, 0xA002_u64, Bytes[1], Bytes[2], Migration::Stage::AnchorVerified)
    runner = Migration::Workflow.new(journal, port, -> { true },
      ->(item : Migration::Journal) { store.save(item) })
    expect_raises(Matter::TransportError) { runner.run }
    restarted = Migration::Workflow.new(store.load(0xB001_u64, Bytes[1], 0xB002_u64,
      0xA001_u64, Bytes[2], 0xA002_u64).as(Migration::Journal), port,
      -> { true }, ->(item : Migration::Journal) { store.save(item) })
    expect_raises(Matter::CommissioningError) { restarted.run }
    port.fail_at = "refresh-anchor"
    expect_raises(Matter::TransportError) { restarted.resume_anchor_registration! }
    restarted.journal.stage.should eq(Migration::Stage::AddingAnchorNode)
    port.fail_at = nil
    restarted.resume_anchor_registration!
    restarted.journal.stage.should eq(Migration::Stage::AnchorNodeAdded)
    restarted.run
    restarted.journal.stage.should eq(Migration::Stage::Complete)
    port.calls.count("add-anchor").should eq(1)
    port.calls.count("refresh-anchor").should eq(2)
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

  it "removes a stale Anchor controller node only after authenticated rollback proof" do
    crypto = Matter::Crypto::StandardCrypto.new
    old_fabric = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      0xB001_u64, 0xB101_u64, 0xFFF2_u16, crypto: crypto).fabric
    bootstrap = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      0xA001_u64, 0xA101_u64, 0xFFF1_u16, crypto: crypto)
    joined = joined_identity(bootstrap, 0xA103_u64, Matter::Crypto::Key.generate_key_pair)
    b_icac = old_fabric.intermediate_cert.as(Bytes)
    signed = Matter::Crypto::MatterCertificate::Builder.intermediate(
      Matter::Crypto::MatterCertificate.public_key_from_tlv(b_icac),
      joined.fabric_id, 0xB101_u64, bootstrap.fabric.certificate_authority_key,
      1_u64, Bytes[2], crypto)
    issuer = Migration.cross_signed_issuer(old_fabric, joined, signed,
      old_fabric.intermediate_private_key.as(Bytes))
    store = Matter::Controller::StateStore.new(Matter::Storage::Memory.new)
    state = store.load
    state.install_fabric(joined)
    state.record_node(joined.fabric_id, Matter::Controller::NodeInfo.new(
      node_id: 0xA201_u64, address: "127.0.0.1", port: 5540),
      joined.root_public_key, joined.controller_node_id)
    store.save(state)
    peer = Socket::IPAddress.new("127.0.0.1", 5540)
    verifier = Matter::Controller::DeviceAttestationVerifier.new(
      Matter::Controller::AttestationTrustStore.matter_test_fixture)
    port = MigrationRollbackNetworkPort.new(store, old_fabric, joined, issuer,
      0xB201_u64, 0xA201_u64, peer, 0xB101_u64, peer, 1_u16,
      0xA101_u64, peer, 1_u16, "Existing device", 0xFFFF_0001_u32,
      verifier, timeout: 1.millisecond)
    begin
      expect_raises(Matter::CommissioningError, /Remote rollback is incomplete/) do
        port.finalize_rollback!
      end
      store.load.nodes_for(joined.fabric_id, joined.root_public_key,
        joined.controller_node_id).has_key?(0xA201_u64).should be_true
      port.remote_rolled_back = true
      port.finalize_rollback!
      store.load.nodes_for(joined.fabric_id, joined.root_public_key,
        joined.controller_node_id).has_key?(0xA201_u64).should be_false
      port.finalize_rollback!
    ensure
      port.close
    end
  end

  it "restores a missing controller node only after durable acknowledgement and A CASE proof" do
    crypto = Matter::Crypto::StandardCrypto.new
    old_fabric = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      0xB001_u64, 0xB101_u64, 0xFFF2_u16, crypto: crypto).fabric
    bootstrap = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      0xA001_u64, 0xA101_u64, 0xFFF1_u16, crypto: crypto)
    joined = joined_identity(bootstrap, 0xA103_u64, Matter::Crypto::Key.generate_key_pair)
    b_icac = old_fabric.intermediate_cert.as(Bytes)
    signed = Matter::Crypto::MatterCertificate::Builder.intermediate(
      Matter::Crypto::MatterCertificate.public_key_from_tlv(b_icac),
      joined.fabric_id, 0xB101_u64, bootstrap.fabric.certificate_authority_key,
      1_u64, Bytes[2], crypto)
    issuer = Migration.cross_signed_issuer(old_fabric, joined, signed,
      old_fabric.intermediate_private_key.as(Bytes))
    store = Matter::Controller::StateStore.new(Matter::Storage::Memory.new)
    state = store.load
    state.install_fabric(joined)
    store.save(state)
    peer = Socket::IPAddress.new("127.0.0.1", 5540)
    verifier = Matter::Controller::DeviceAttestationVerifier.new(
      Matter::Controller::AttestationTrustStore.matter_test_fixture)
    monotonic = Time.instant
    recovery_waits = [] of Time::Span
    port = MigrationRecoveryNetworkPort.new(store, old_fabric, joined, issuer,
      0xB201_u64, 0xA201_u64, peer, 0xB101_u64, peer, 1_u16,
      0xA101_u64, peer, 1_u16, "Existing device", 0xFFFF_0001_u32,
      verifier, timeout: 1.millisecond,
      monotonic_now: -> { monotonic },
      recovery_sleep: ->(duration : Time::Span) { recovery_waits << duration; monotonic += duration })
    journal = Migration::Journal.new(0xB001_u64, 0xA001_u64,
      0xB201_u64, 0xA201_u64, old_fabric.root_public_key,
      joined.root_public_key, Migration::Stage::CommissioningAnchor)
    port.validate_journal!(journal)
    expect_raises(Matter::CommissioningError, /durable CommissioningComplete/) do
      port.verify_postcondition!(Migration::Stage::AnchorCommissioned)
    end
    journal.commissioning_acknowledged = true
    port.validate_journal!(journal)
    expect_raises(Matter::CommissioningError, /Durable CommissioningComplete/) do
      port.verify_no_effect!(Migration::Stage::CommissioningAnchor)
    end
    expect_raises(Matter::AuthenticationError, /B ownership/) do
      port.verify_postcondition!(Migration::Stage::AnchorCommissioned)
    end
    port.old_verified = true
    expect_raises(Matter::AuthenticationError, /A CASE/) do
      port.verify_postcondition!(Migration::Stage::AnchorCommissioned)
    end
    store.load.nodes_for(joined.fabric_id, joined.root_public_key,
      joined.controller_node_id).has_key?(0xA201_u64).should be_false
    port.anchor_verified = true
    port.verify_postcondition!(Migration::Stage::AnchorCommissioned)
    stored = store.load.nodes_for(joined.fabric_id, joined.root_public_key,
      joined.controller_node_id)[0xA201_u64]
    stored.address.should eq("127.0.0.1")
    stored.port.should eq(5540)
    journal.commissioning_acknowledged = false
    journal.fail_safe_max_seconds = 1_u16
    journal.fail_safe_deadline_unix = Time.utc.to_unix - 86_400
    port.validate_journal!(journal)
    port.verify_postcondition!(Migration::Stage::AnchorCommissioned)
    recovery_waits.should eq([3.seconds])
    recovery_waits.clear
    state = store.load
    state.nodes_for(joined.fabric_id, joined.root_public_key,
      joined.controller_node_id).delete(0xA201_u64)
    store.save(state)
    port.close
    journal.commissioning_acknowledged = false
    journal.fail_safe_max_seconds = nil
    # Simulate a process restart with a stale UTC deadline. A jump in the
    # wall clock must not let the restarted controller adopt provisional A.
    journal.fail_safe_deadline_unix = Time.utc.to_unix - 86_400
    migration_store = Migration::JournalStore.new(Matter::Storage::Memory.new)
    migration_store.save(journal)
    restarted_journal = migration_store.load(0xB001_u64, old_fabric.root_public_key,
      0xB201_u64, 0xA001_u64, joined.root_public_key, 0xA201_u64).as(Migration::Journal)
    restarted_port = MigrationRecoveryNetworkPort.new(store, old_fabric, joined, issuer,
      0xB201_u64, 0xA201_u64, peer, 0xB101_u64, peer, 1_u16,
      0xA101_u64, peer, 1_u16, "Existing device", 0xFFFF_0001_u32,
      verifier, timeout: 1.millisecond,
      monotonic_now: -> { monotonic },
      recovery_sleep: ->(duration : Time::Span) { recovery_waits << duration; monotonic += duration })
    restarted_port.validate_journal!(restarted_journal)
    expect_raises(Matter::CommissioningError, /fail-safe recovery bound/) do
      restarted_port.verify_postcondition!(Migration::Stage::AnchorCommissioned)
    end
    expect_raises(Matter::CommissioningError, /fail-safe recovery bound/) do
      restarted_port.verify_no_effect!(Migration::Stage::CommissioningAnchor)
    end
    recovery_waits.should be_empty
    restarted_journal.fail_safe_max_seconds = 1_u16
    migration_store.save(restarted_journal)
    restarted_port.validate_journal!(migration_store.load(0xB001_u64,
      old_fabric.root_public_key, 0xB201_u64, 0xA001_u64,
      joined.root_public_key, 0xA201_u64).as(Migration::Journal))
    restarted_port.old_verified = false
    restarted = Migration::Workflow.new(restarted_journal, restarted_port,
      -> { true }, ->(item : Migration::Journal) { migration_store.save(item) })
    expect_raises(Matter::AuthenticationError, /B ownership/) do
      restarted.run
    end
    restarted.journal.stage.should eq(Migration::Stage::CommissioningAnchor)
    recovery_waits.should eq([3.seconds])
    restarted_journal.fail_safe_deadline_unix = Time.utc.to_unix + 86_400
    restarted_port.validate_journal!(restarted_journal)
    restarted_port.old_verified = true
    restarted_port.anchor_verified = true
    restarted_port.verify_postcondition!(Migration::Stage::AnchorCommissioned)
    recovery_waits.should eq([3.seconds, 3.seconds])
    store.load.nodes_for(joined.fabric_id, joined.root_public_key,
      joined.controller_node_id).has_key?(0xA201_u64).should be_true
    restarted_port.close
  end
end
