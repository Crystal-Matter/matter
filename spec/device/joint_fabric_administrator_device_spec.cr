require "../spec_helper"
require "../../examples/support/joint_fabric_administrator_device"
require "../../src/matter/storage/sqlite"

class InspectableJointFabricAdministratorDevice < MatterJointFabricAdministrator::Device
  def prepare_for_start : Nil
    before_start
  end

  def advertised_joint_role : Matter::MDNS::JointFabricRole?
    commissioning_info_for(Matter::MDNS::CommissioningMode::Basic).joint_fabric_role
  end

  def install_test_fabric(fabric : Matter::Fabric) : Nil
    fabric_table.add_fabric(fabric) unless fabric_table.get_fabric(fabric.fabric_index)
    fabric_added(fabric)
  end

  def remove_test_fabric(index : UInt8) : Nil
    fabric_removed(index)
  end

  def stage_fabric_removal_for_spec(index : UInt8) : Nil
    before_fabric_removed(index)
  end

  def select_anchor_administrator_fabric_for_spec(index : UInt8) : Nil
    select_anchor_administrator_fabric(index)
  end

  def persist_anchor_role_for_spec(anchor : Bool) : Nil
    persist_anchor_role(anchor)
  end

  def migration_verifier_for_spec : Matter::Controller::DeviceAttestationVerifier
    migration_attestation_verifier
  end

  def anchor_profile_for_spec(fabric : Matter::Fabric) : Bool
    compliant_anchor_fabric?(fabric)
  end

  def anchor_verification_peer_for_spec(source : Socket::IPAddress) : Socket::IPAddress
    scanner = Matter::Controller::Scanner.new
    resolve_anchor_verification_peer(scanner, 0_u64, 1_u64, source, 0.seconds)
  ensure
    scanner.try(&.close)
  end

  def anchor_verification_client_for_spec(node_id : UInt64) : Matter::Controller::Client
    anchor_verification_client(node_id)
  end

  def anchor_trust_for_spec(vendor_id : UInt16, root_path : String?, test_dcl_url : String?,
                            dcl_url : String? = nil) : Matter::Controller::VidVerification::OperationalTrustAnchors
    anchor_trust(vendor_id, root_path, test_dcl_url, dcl_url)
  end

  def persist_icac_commit_for_spec(certificate : Bytes) : Nil
    persist_icac(certificate, APP_ICAC_DOCUMENT, joint_fabric_administrator)
  end

  def persist_bootstrap_icac_commit_for_spec(certificate : Bytes) : Nil
    persist_bootstrap_icac(certificate, bootstrap_joint_fabric_administrator,
      bootstrap_joint_fabric_datastore)
  end

  def restore_bootstrap_administrator_binding_for_spec : Nil
    restore_bootstrap_administrator_binding
  end

  def propagation_fabric_for_spec : Matter::Fabric?
    @propagation_fabric
  end

  def controller_store_for_spec : Matter::Controller::StateStore?
    @controller_store
  end

  def durable_anchor_old_credential_for_spec(fabric : Matter::Fabric) : Matter::Fabric
    verify_durable_anchor_old_credential!(fabric)
  end

  def finalize_anchor_rotation_no_effect_for_spec(journal : Matter::Controller::AdministratorRemoval::Journal,
                                                  datastore : Matter::Cluster::JointFabricDatastore,
                                                  fabric : Matter::Fabric, document_name : String) : Nil
    finalize_anchor_rotation_no_effect!(journal, datastore, fabric, fabric.operational_cert, document_name)
  end

  def inbound_arm_failsafe_for_spec(fabric_index : UInt8) : Matter::Commissioning::ErrorCode
    @message_handler.registry.synchronize do
      general_commissioning.arm_failsafe(
        Matter::Cluster::GeneralCommissioning::ArmFailSafeRequest.new(60_u16, 0_u64),
        fabric_index, false).error_code
    end
  end
end

private class PausingJfaRecoveryYaml < Matter::Storage::YamlFile
  property on_removal_journal_write : Proc(Nil)?

  def write(collection : String, id : String, document : Matter::Storage::Document) : Nil
    if collection == Matter::Storage::Collections::APP &&
       id.starts_with?(MatterJointFabricAdministrator::Device::APP_REMOVAL_PREFIX)
      @on_removal_journal_write.try(&.call)
    end
    super
  end
end

class InterruptedJfaCommitYaml < Matter::Storage::YamlFile
  property? fail_next_cluster_write = false
  property? fail_next_flush = false
  property fail_cluster_id : String?

  protected def flush : Nil
    if @fail_next_flush
      @fail_next_flush = false
      raise Matter::StorageError.new("Interrupted joined completion flush")
    end
    super
  end

  def write(collection : String, id : String, document : Matter::Storage::Document) : Nil
    if @fail_next_cluster_write && collection == Matter::Storage::Collections::CLUSTERS &&
       (@fail_cluster_id.nil? || @fail_cluster_id == id)
      @fail_next_cluster_write = false
      raise Matter::StorageError.new("Interrupted cluster write")
    end
    super
  end
end

private class PendingJfaCompletionService < Matter::Commissioning::JointFabricAdministratorService
  def stage_for_spec(cluster : Matter::Cluster::JointFabricAdministrator, certificate : Bytes) : Nil
    @administrator_cluster = cluster
    @cross_signed_icac = certificate
    @icac_pending_commit = true
  end
end

private def stage_joined_jfa_completion(backend : Matter::Storage::Backend,
                                        *, terms_required : Bool = false,
                                        on_restriction_review_requested : Proc(Matter::Cluster::AccessControl::RestrictionReviewRequest, Nil)? = nil,
                                        on_restriction_review_updated : Proc(UInt8, Matter::Cluster::AccessControl::FabricRestrictionReviewUpdate, Nil)? = nil) : Tuple(InspectableJointFabricAdministratorDevice, PendingJfaCompletionService)
  device = InspectableJointFabricAdministratorDevice.new(storage: backend,
    ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0,
    tc_min_required_version: terms_required ? 2_u16 : nil,
    tc_required_acknowledgements: 0b0110_u16,
    on_restriction_review_requested: on_restriction_review_requested,
    on_restriction_review_updated: on_restriction_review_updated)
  device.prepare_for_start
  device.general_commissioning.arm_failsafe(
    Matter::Cluster::GeneralCommissioning::ArmFailSafeRequest.new(60_u16, 0_u64), 1_u8, true
  ).error_code.ok?.should be_true
  Matter::Commissioning::CredentialJournal.begin_add(backend, 1_u8)
  crypto = Matter::Crypto::StandardCrypto.new
  root_key = crypto.create_key_pair
  icac_key = crypto.create_key_pair
  fabric = jfa_reuse_test_fabric(0xA100_u64, 0xA102_u64,
    root_key: root_key, icac_key: icac_key)
  device.fabric_table.add_fabric(fabric).should be_true
  device.persistence.write_app_document(MatterJointFabricAdministrator::Device::APP_KEY_DOCUMENT,
    MatterJointFabricAdministrator::Device::IcacKeyState.new(icac_key.private_key, icac_key.public_key).to_document)

  administrator = device.joint_fabric_administrator
  administrator.begin_provisional_administrator_fabric_index(1_u8)
  device.persistence.save_cluster(administrator).should be_true
  root = fabric.root_cert || raise Matter::ConfigurationError.new("Test root missing")
  cross_signed = Matter::Crypto::MatterCertificate::Builder.intermediate(
    icac_key.public_key, fabric.fabric_id, 2_u64, root_key, 1_u64, Bytes[4_u8], crypto)
  service = PendingJfaCompletionService.new(
    icac_key, root, fabric.fabric_id,
    -> { true }, ->(_index : UInt8) { true },
    ->(_request : Matter::Cluster::JointFabricAdministrator::OpenJointCommissioningWindowRequest) { Matter::InteractionModel::Status.success },
    ->(_node : UInt64) { true }, -> { false }, -> { nil }, -> { nil },
    persist_icac: ->(certificate : Bytes?) {
      device.persist_icac_commit_for_spec(certificate.as(Bytes))
    })
  service.stage_for_spec(administrator, cross_signed)
  administrator.service = service
  {device, service}
end

class InterruptedJfaCommitSqlite < Matter::Storage::Sqlite
  property? fail_next_cluster_write = false

  def write(collection : String, id : String, document : Matter::Storage::Document) : Nil
    if @fail_next_cluster_write && collection == Matter::Storage::Collections::CLUSTERS
      @fail_next_cluster_write = false
      raise Matter::StorageError.new("Interrupted cluster write")
    end
    super
  end
end

private def jfa_reuse_test_fabric(fabric_id : UInt64, node_id : UInt64,
                                  root_key : Matter::Crypto::Key = Matter::Crypto::StandardCrypto.new.create_key_pair,
                                  icac_key : Matter::Crypto::Key = Matter::Crypto::StandardCrypto.new.create_key_pair,
                                  root_cert : Bytes? = nil) : Matter::Fabric
  crypto = Matter::Crypto::StandardCrypto.new
  noc_key = crypto.create_key_pair
  root = root_cert || Matter::Crypto::MatterCertificate::Builder.root(root_key, 1_u64, Bytes[1], crypto)
  icac = Matter::Crypto::MatterCertificate::Builder.intermediate(
    icac_key.public_key, fabric_id, 2_u64, root_key, 1_u64, Bytes[2], crypto, anchor: true)
  noc = Matter::Crypto::MatterCertificate::Builder.node(
    noc_key.public_key, fabric_id, node_id, icac_key, 1_u64, Bytes[3], crypto,
    issuer_icac_id: 2_u64, issuer_certificate: icac,
    case_authenticated_tag: 0xFFFE_0001_u32)
  Matter::Fabric.new(fabric_id, 1_u8, node_id, root_key.public_key, noc, noc_key,
    Bytes.new(16, 0xA5_u8), intermediate_cert: icac, root_cert: root,
    cats: [Matter::DataType::CaseAuthenticatedTag.new(0xFFFE_0001_u32)])
end

private class FailingJfaMemory < Matter::Storage::Memory
  property? fail_next_administrator_write : Bool = false
  property? fail_next_fabric_delete : Bool = false

  def delete(collection : String, id : String) : Nil
    if @fail_next_fabric_delete && collection == Matter::FabricTable::COLLECTION
      @fail_next_fabric_delete = false
      raise Matter::StorageError.new("Injected fabric document deletion failure")
    end
    super
  end

  def write(collection : String, id : String, document : Matter::Storage::Document) : Nil
    if @fail_next_administrator_write && collection == Matter::Storage::Collections::CLUSTERS &&
       id == Matter::Cluster::Base.persistence_key(1_u16, Matter::Cluster::JointFabricAdministrator::CLUSTER_ID)
      @fail_next_administrator_write = false
      raise Matter::StorageError.new("Injected JFA write failure")
    end
    super
  end
end

describe MatterJointFabricAdministrator::Device do
  it "serializes the final old-NOC journal write against inbound ArmFailSafe" do
    path = File.join(Dir.tempdir, "matter-jfa-anchor-race-#{Random::Secure.hex(6)}.yml")
    backend = PausingJfaRecoveryYaml.new(path)
    device = InspectableJointFabricAdministratorDevice.new(storage: backend,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    fabric = jfa_reuse_test_fabric(0xA100_u64, 0xA102_u64)
    device.fabric_table.add_fabric(fabric).should be_true
    datastore = Matter::Cluster::JointFabricDatastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    datastore.anchor_root_ca = fabric.root_cert.as(Bytes)
    datastore.anchor_node_id = fabric.node_id
    datastore.joint_fabric_index = fabric.fabric_index
    datastore.admin_list = [
      Matter::Cluster::JointFabricDatastore::DatastoreAdministratorInformationEntryStruct.new(
        fabric.node_id, "Anchor", 0xFFF2_u16, Bytes[1]),
    ]
    datastore.group_list = [Matter::Cluster::JointFabricDatastore::DatastoreGroupInformationEntryStruct.new(
      1_u64, "Administrators", nil, Matter::Cluster::JointFabricDatastore::ADMINISTRATOR_CAT,
      2_u16, Matter::Cluster::JointFabricDatastore::DatastoreAccessControlEntryPrivilegeEnum::Administer)]
    datastore.status = Matter::Cluster::JointFabricDatastore::DatastoreStatusEntryStruct.new(
      Matter::Cluster::JointFabricDatastore::DatastoreStateEnum::Committed, 0_u32, 0_u8)
    backend.write(Matter::Storage::Collections::CLUSTERS, datastore.persistence_key, datastore.save_state.as(Matter::Storage::Document))
    outgoing_node_id = 0xA103_u64
    journal = Matter::Controller::AdministratorRemoval::Journal.new(outgoing_node_id,
      Matter::Controller::AdministratorRemoval::Stage::RotatingAnchor,
      administrator_cat_version: 2_u16, prior_administrator_cat_version: 1_u16,
      fabric_id: fabric.fabric_id, root_public_key: fabric.root_public_key,
      anchor_node_id: fabric.node_id, outgoing_admin_entry: Bytes[2],
      remaining_admin_entries: datastore.admin_list.map(&.to_slice),
      anchor_pre_rotation_noc: fabric.operational_cert)
    document_name = "#{MatterJointFabricAdministrator::Device::APP_REMOVAL_PREFIX}#{outgoing_node_id.to_s(16)}"
    attempted = Channel(Nil).new(1)
    finished = Channel(Matter::Commissioning::ErrorCode).new(1)
    backend.on_removal_journal_write = -> do
      spawn do
        attempted.send(nil)
        result = device.inbound_arm_failsafe_for_spec(fabric.fabric_index)
        finished.send(result)
      end
      attempted.receive
      select
      when finished.receive
        fail "Inbound ArmFailSafe interleaved with the removal journal write"
      when timeout(200.milliseconds)
      end
    end

    device.finalize_anchor_rotation_no_effect_for_spec(journal, datastore, fabric, document_name)
    saved = backend.read(Matter::Storage::Collections::APP, document_name).as(Matter::Storage::Document)
    Matter::Controller::AdministratorRemoval::Journal.from_document(saved).stage.should eq(
      Matter::Controller::AdministratorRemoval::Stage::DatastoreRemoved)
    select
    when result = finished.receive
      result.ok?.should be_true
    when timeout(1.second)
      fail "Inbound ArmFailSafe deadlocked behind recovery"
    end
  ensure
    device.try(&.shutdown!)
    File.delete?(path) if path
  end

  it "requires durable storage for old-NOC recovery" do
    device = InspectableJointFabricAdministratorDevice.new(storage: Matter::Storage::Memory.new,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    fabric = jfa_reuse_test_fabric(0xA100_u64, 0xA102_u64)
    device.fabric_table.add_fabric(fabric).should be_true
    expect_raises(Matter::StorageError, /durable storage/) do
      device.durable_anchor_old_credential_for_spec(fabric)
    end
  ensure
    device.try(&.shutdown!)
  end

  it "rejects an old-NOC recovery while fail-safe, credential journal, or fabric state is uncertain" do
    path = File.join(Dir.tempdir, "matter-jfa-anchor-old-noc-#{Random::Secure.hex(6)}.yml")
    backend = Matter::Storage::YamlFile.new(path)
    device = InspectableJointFabricAdministratorDevice.new(storage: backend,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    fabric = jfa_reuse_test_fabric(0xA100_u64, 0xA102_u64)
    device.fabric_table.add_fabric(fabric).should be_true
    device.durable_anchor_old_credential_for_spec(fabric).operational_cert.should eq(fabric.operational_cert)

    device.general_commissioning.arm_failsafe(
      Matter::Cluster::GeneralCommissioning::ArmFailSafeRequest.new(60_u16, 0_u64), 1_u8, false
    ).error_code.ok?.should be_true
    expect_raises(Matter::CommissioningError, /provisional/) do
      device.durable_anchor_old_credential_for_spec(fabric)
    end
    device.general_commissioning.arm_failsafe(
      Matter::Cluster::GeneralCommissioning::ArmFailSafeRequest.new(0_u16, 0_u64), 1_u8, false
    ).error_code.ok?.should be_true

    Matter::Commissioning::CredentialJournal.begin_update(backend, fabric)
    expect_raises(Matter::CommissioningError, /provisional/) do
      device.durable_anchor_old_credential_for_spec(fabric)
    end
    Matter::Commissioning::CredentialJournal.clear(backend)

    fabric.operational_cert = Bytes[1_u8]
    expect_raises(Matter::AuthenticationError, /live and durable/) do
      device.durable_anchor_old_credential_for_spec(fabric)
    end
  ensure
    device.try(&.shutdown!)
    File.delete?(path) if path
  end

  it "restores a managed restriction review alongside a committed joined JFA" do
    path = File.join(Dir.tempdir, "matter-jfa-managed-completion-#{Random::Secure.hex(6)}.yml")
    backend = InterruptedJfaCommitYaml.new(path)
    first_requests = [] of UInt64
    first_requested = ->(request : Matter::Cluster::AccessControl::RestrictionReviewRequest) do
      first_requests << request.token
      nil
    end
    first_updated = ->(_fabric : UInt8, _update : Matter::Cluster::AccessControl::FabricRestrictionReviewUpdate) { nil }
    device, service = stage_joined_jfa_completion(backend,
      on_restriction_review_requested: first_requested,
      on_restriction_review_updated: first_updated)
    icac = service.cross_signed_icac.as(Bytes)
    acl = device.access_control
    acl.feature_map.managed_device?.should be_true
    token = acl.request_restriction_review(1_u8, [] of Matter::Cluster::AccessControl::AccessRestrictionEntry)
    first_requests.should eq([token])

    device.general_commissioning.commissioning_complete(1_u8, true).error_code.ok?.should be_true
    backend.read(Matter::Commissioning::CredentialJournal::COLLECTION,
      Matter::Commissioning::CredentialJournal::ID).should be_nil
    backend.close

    replayed = [] of UInt64
    completed = [] of UInt64
    restarted = InspectableJointFabricAdministratorDevice.new(storage: Matter::Storage::YamlFile.new(path),
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0,
      on_restriction_review_requested: ->(request : Matter::Cluster::AccessControl::RestrictionReviewRequest) do
        replayed << request.token
        nil
      end,
      on_restriction_review_updated: ->(_fabric : UInt8, update : Matter::Cluster::AccessControl::FabricRestrictionReviewUpdate) do
        completed << update.token
        nil
      end)
    restarted.fabric_table.get_fabric(1_u8).should_not be_nil
    restarted.joint_fabric_administrator.administrator_fabric_index.should eq(1_u8)
    icac_document = restarted.persistence.app_document(MatterJointFabricAdministrator::Device::APP_ICAC_DOCUMENT) ||
                    raise Matter::StorageError.new("Committed ICAC missing")
    MatterJointFabricAdministrator::Device::IcacCertificateState.from_document(icac_document).certificate.should eq(icac)
    restarted.access_control.feature_map.managed_device?.should be_true
    replayed.should eq([token])
    restarted.access_control.deny_restriction_review(1_u8, token).should be_true
    completed.should eq([token])
  ensure
    restarted.try(&.shutdown!)
    device.try(&.shutdown!) if backend.try(&.open?)
    File.delete?(path) if path
  end

  it "rolls back both joined fabric and JFA identity when their shared completion flush fails" do
    path = File.join(Dir.tempdir, "matter-jfa-completion-#{Random::Secure.hex(6)}.yml")
    backend = InterruptedJfaCommitYaml.new(path)
    device = stage_joined_jfa_completion(backend)[0]
    backend.fail_next_cluster_write = true

    expect_raises(Matter::StorageError, "Interrupted cluster write") do
      device.general_commissioning.commissioning_complete(1_u8, true)
    end
    device.general_commissioning.failsafe_armed?.should be_true
    backend.close

    restarted = InspectableJointFabricAdministratorDevice.new(storage: Matter::Storage::YamlFile.new(path),
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    restarted.fabric_table.get_fabric(1_u8).should be_nil
    restarted.joint_fabric_administrator.administrator_fabric_index.should be_nil
    restarted.persistence.app_document(MatterJointFabricAdministrator::Device::APP_ICAC_DOCUMENT).should be_nil
  ensure
    restarted.try(&.shutdown!)
    device.try(&.shutdown!) if backend.try(&.open?)
    File.delete?(path) if path
  end

  it "retries a failed joined completion and commits terms, fabric, and JFA identity together" do
    path = File.join(Dir.tempdir, "matter-jfa-completion-retry-#{Random::Secure.hex(6)}.yml")
    backend = InterruptedJfaCommitYaml.new(path)
    device, service = stage_joined_jfa_completion(backend, terms_required: true)
    pending_icac = service.cross_signed_icac.as(Bytes)
    device.general_commissioning.set_tc_acknowledgements(
      Matter::Cluster::GeneralCommissioning::SetTCAcknowledgementsRequest.new(2_u16, 0b0110_u16)
    ).error_code.ok?.should be_true
    committed_terms_before = device.general_commissioning.save_state
    backend.fail_cluster_id = device.joint_fabric_administrator.persistence_key
    backend.fail_next_cluster_write = true

    expect_raises(Matter::StorageError, "Interrupted cluster write") do
      device.general_commissioning.commissioning_complete(1_u8, true)
    end
    device.general_commissioning.failsafe_armed?.should be_true
    device.general_commissioning.save_state.should eq(committed_terms_before)
    device.joint_fabric_administrator.administrator_fabric_index.should eq(1_u8)
    backend.read(Matter::Commissioning::CredentialJournal::COLLECTION,
      Matter::Commissioning::CredentialJournal::ID).should_not be_nil
    service.cross_signed_icac.should eq(pending_icac)

    device.general_commissioning.commissioning_complete(1_u8, true).error_code.ok?.should be_true
    backend.read(Matter::Commissioning::CredentialJournal::COLLECTION,
      Matter::Commissioning::CredentialJournal::ID).should be_nil
    device.general_commissioning.tc_accepted_version.should eq(2_u16)
    backend.close

    restarted = InspectableJointFabricAdministratorDevice.new(storage: Matter::Storage::YamlFile.new(path),
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0,
      tc_min_required_version: 2_u16, tc_required_acknowledgements: 0b0110_u16)
    restarted.fabric_table.get_fabric(1_u8).should_not be_nil
    restarted.general_commissioning.tc_accepted_version.should eq(2_u16)
    restarted.joint_fabric_administrator.administrator_fabric_index.should eq(1_u8)
    icac_document = restarted.persistence.app_document(MatterJointFabricAdministrator::Device::APP_ICAC_DOCUMENT) ||
                    raise Matter::StorageError.new("Committed ICAC missing")
    MatterJointFabricAdministrator::Device::IcacCertificateState.from_document(icac_document)
      .certificate.should eq(pending_icac)
  ensure
    restarted.try(&.shutdown!)
    device.try(&.shutdown!) if backend.try(&.open?)
    File.delete?(path) if path
  end

  it "keeps joined credentials provisional after the shared file flush fails" do
    path = File.join(Dir.tempdir, "matter-jfa-completion-flush-#{Random::Secure.hex(6)}.yml")
    backend = InterruptedJfaCommitYaml.new(path)
    device, service = stage_joined_jfa_completion(backend)
    pending_icac = service.cross_signed_icac.as(Bytes)
    backend.fail_next_flush = true

    expect_raises(Matter::StorageError, "Interrupted joined completion flush") do
      device.general_commissioning.commissioning_complete(1_u8, true)
    end
    device.general_commissioning.failsafe_armed?.should be_true
    backend.read(Matter::Commissioning::CredentialJournal::COLLECTION,
      Matter::Commissioning::CredentialJournal::ID).should_not be_nil
    backend.read(Matter::Storage::Collections::APP,
      MatterJointFabricAdministrator::Device::APP_ICAC_DOCUMENT).should be_nil
    service.cross_signed_icac.should eq(pending_icac)
    device.general_commissioning.commissioning_complete(1_u8, true).error_code.ok?.should be_true
    backend.close

    restarted = InspectableJointFabricAdministratorDevice.new(storage: Matter::Storage::YamlFile.new(path),
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    restarted.fabric_table.get_fabric(1_u8).should_not be_nil
    restarted.joint_fabric_administrator.administrator_fabric_index.should eq(1_u8)
    icac_document = restarted.persistence.app_document(MatterJointFabricAdministrator::Device::APP_ICAC_DOCUMENT) ||
                    raise Matter::StorageError.new("Committed ICAC missing")
    MatterJointFabricAdministrator::Device::IcacCertificateState.from_document(icac_document)
      .certificate.should eq(pending_icac)
  ensure
    restarted.try(&.shutdown!)
    device.try(&.shutdown!) if backend.try(&.open?)
    File.delete?(path) if path
  end

  it "rolls back a joined completion on SQLite and can commit it on retry" do
    {false, true}.each do |retry_completion|
      path = File.join(Dir.tempdir, "matter-jfa-completion-#{Random::Secure.hex(6)}.sqlite3")
      backend = InterruptedJfaCommitSqlite.new(path)
      device, service = stage_joined_jfa_completion(backend)
      pending_icac = service.cross_signed_icac.as(Bytes)
      backend.fail_next_cluster_write = true

      expect_raises(Matter::StorageError, "Interrupted cluster write") do
        device.general_commissioning.commissioning_complete(1_u8, true)
      end
      device.general_commissioning.failsafe_armed?.should be_true
      backend.read(Matter::Commissioning::CredentialJournal::COLLECTION,
        Matter::Commissioning::CredentialJournal::ID).should_not be_nil
      if retry_completion
        device.general_commissioning.commissioning_complete(1_u8, true).error_code.ok?.should be_true
      end
      backend.close

      restarted = InspectableJointFabricAdministratorDevice.new(storage: Matter::Storage::Sqlite.new(path),
        ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
      if retry_completion
        restarted.fabric_table.get_fabric(1_u8).should_not be_nil
        restarted.joint_fabric_administrator.administrator_fabric_index.should eq(1_u8)
        icac_document = restarted.persistence.app_document(MatterJointFabricAdministrator::Device::APP_ICAC_DOCUMENT) ||
                        raise Matter::StorageError.new("Committed ICAC missing")
        MatterJointFabricAdministrator::Device::IcacCertificateState.from_document(icac_document)
          .certificate.should eq(pending_icac)
      else
        restarted.fabric_table.get_fabric(1_u8).should be_nil
        restarted.joint_fabric_administrator.administrator_fabric_index.should be_nil
        restarted.persistence.app_document(MatterJointFabricAdministrator::Device::APP_ICAC_DOCUMENT).should be_nil
      end
      restarted.shutdown!
      backend.destroy!
    end
  end

  it "rolls a partial ICAC commit back on SQLite and restores a durable pair after a crash" do
    path = File.join(Dir.tempdir, "matter-jfa-atomic-commit-#{Random::Secure.hex(6)}.sqlite3")
    backend = InterruptedJfaCommitSqlite.new(path)
    device = InspectableJointFabricAdministratorDevice.new(storage: backend,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    administrator = device.joint_fabric_administrator
    administrator.administrator_fabric_index = 1_u8
    old_icac = Bytes[1_u8]
    new_icac = Bytes[2_u8]
    device.persistence.write_app_document(MatterJointFabricAdministrator::Device::APP_ICAC_DOCUMENT,
      MatterJointFabricAdministrator::Device::IcacCertificateState.new(old_icac).to_document)
    device.persistence.save_cluster(administrator).should be_true
    administrator.begin_provisional_administrator_fabric_index(2_u8)
    device.persistence.save_cluster(administrator).should be_true

    backend.fail_next_cluster_write = true
    administrator.with_pending_provisional_commit do
      expect_raises(Matter::StorageError, "Interrupted cluster write") do
        device.persist_icac_commit_for_spec(new_icac)
      end
    end
    before_commit = Matter::Storage::Sqlite.new(path)
    before_commit.open
    stored_old_icac = before_commit.read(Matter::Storage::Collections::APP,
      MatterJointFabricAdministrator::Device::APP_ICAC_DOCUMENT).as(Matter::Storage::Document)
    MatterJointFabricAdministrator::Device::IcacCertificateState.from_document(stored_old_icac)
      .certificate.should eq(old_icac)
    restored_old = Matter::Cluster::JointFabricAdministrator.new(Matter::DataType::EndpointNumber.new(1_u16))
    restored_old.restore_state(before_commit.read(Matter::Storage::Collections::CLUSTERS,
      administrator.persistence_key).as(Matter::Storage::Document))
    restored_old.administrator_fabric_index.should eq(1_u8)
    before_commit.close

    expect_raises(Matter::StorageError, "Interrupted after commit") do
      administrator.with_pending_provisional_commit do
        device.persist_icac_commit_for_spec(new_icac)
        raise Matter::StorageError.new("Interrupted after commit")
      end
    end
    after_commit = Matter::Storage::Sqlite.new(path)
    after_commit.open
    stored_new_icac = after_commit.read(Matter::Storage::Collections::APP,
      MatterJointFabricAdministrator::Device::APP_ICAC_DOCUMENT).as(Matter::Storage::Document)
    MatterJointFabricAdministrator::Device::IcacCertificateState.from_document(stored_new_icac)
      .certificate.should eq(new_icac)
    restored_new = Matter::Cluster::JointFabricAdministrator.new(Matter::DataType::EndpointNumber.new(1_u16))
    restored_new.restore_state(after_commit.read(Matter::Storage::Collections::CLUSTERS,
      administrator.persistence_key).as(Matter::Storage::Document))
    restored_new.administrator_fabric_index.should eq(2_u8)
  ensure
    after_commit.try(&.close) if after_commit.try(&.open?)
    before_commit.try(&.close) if before_commit.try(&.open?)
    device.try(&.shutdown!)
    backend.try(&.destroy!) if backend
  end

  it "commits the ICAC and AdministratorFabricIndex together across interrupted file writes" do
    path = File.join(Dir.tempdir, "matter-jfa-atomic-commit-#{Random::Secure.hex(6)}.yml")
    backend = InterruptedJfaCommitYaml.new(path)
    device = InspectableJointFabricAdministratorDevice.new(storage: backend,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    administrator = device.joint_fabric_administrator
    administrator.administrator_fabric_index = 1_u8
    old_icac = Bytes[1_u8]
    new_icac = Bytes[2_u8]
    device.persistence.write_app_document(MatterJointFabricAdministrator::Device::APP_ICAC_DOCUMENT,
      MatterJointFabricAdministrator::Device::IcacCertificateState.new(old_icac).to_document)
    device.persistence.save_cluster(administrator).should be_true
    administrator.begin_provisional_administrator_fabric_index(2_u8)
    device.persistence.save_cluster(administrator).should be_true

    backend.fail_next_cluster_write = true
    administrator.with_pending_provisional_commit do
      expect_raises(Matter::StorageError, "Interrupted cluster write") do
        device.persist_icac_commit_for_spec(new_icac)
      end
    end
    before_commit = Matter::Storage::YamlFile.new(path)
    before_commit.open
    stored_old_icac = before_commit.read(Matter::Storage::Collections::APP,
      MatterJointFabricAdministrator::Device::APP_ICAC_DOCUMENT).as(Matter::Storage::Document)
    MatterJointFabricAdministrator::Device::IcacCertificateState.from_document(stored_old_icac)
      .certificate.should eq(old_icac)
    restored_old = Matter::Cluster::JointFabricAdministrator.new(Matter::DataType::EndpointNumber.new(1_u16))
    restored_old.restore_state(before_commit.read(Matter::Storage::Collections::CLUSTERS,
      administrator.persistence_key).as(Matter::Storage::Document))
    restored_old.administrator_fabric_index.should eq(1_u8)
    before_commit.close

    expect_raises(Matter::StorageError, "Interrupted after commit") do
      administrator.with_pending_provisional_commit do
        device.persist_icac_commit_for_spec(new_icac)
        raise Matter::StorageError.new("Interrupted after commit")
      end
    end
    after_commit = Matter::Storage::YamlFile.new(path)
    after_commit.open
    stored_new_icac = after_commit.read(Matter::Storage::Collections::APP,
      MatterJointFabricAdministrator::Device::APP_ICAC_DOCUMENT).as(Matter::Storage::Document)
    MatterJointFabricAdministrator::Device::IcacCertificateState.from_document(stored_new_icac)
      .certificate.should eq(new_icac)
    restored_new = Matter::Cluster::JointFabricAdministrator.new(Matter::DataType::EndpointNumber.new(1_u16))
    restored_new.restore_state(after_commit.read(Matter::Storage::Collections::CLUSTERS,
      administrator.persistence_key).as(Matter::Storage::Document))
    restored_new.administrator_fabric_index.should eq(2_u8)
  ensure
    after_commit.try(&.close) if after_commit.try(&.open?)
    before_commit.try(&.close) if before_commit.try(&.open?)
    device.try(&.shutdown!)
    File.delete?(path) if path
  end

  it "cleans retained Anchor credentials on restart after deletion without the post-delete callback" do
    crypto = Matter::Crypto::StandardCrypto.new
    root_key = crypto.create_key_pair
    icac_key = crypto.create_key_pair
    fabric = jfa_reuse_test_fabric(0xA100_u64, 0xA102_u64, root_key: root_key, icac_key: icac_key)
    replacement = jfa_reuse_test_fabric(0xB200_u64, 0xB203_u64,
      root_key: root_key, root_cert: fabric.root_cert)
    previous_anchor = ENV["MATTER_JFA_PROVISIONED_ANCHOR"]?
    previous_csr = ENV["MATTER_JFA_ICAC_CSR_MAILBOX_PATH"]?
    ENV["MATTER_JFA_PROVISIONED_ANCHOR"] = "1"
    ENV.delete("MATTER_JFA_ICAC_CSR_MAILBOX_PATH")
    backend = Matter::Storage::Memory.new
    first = InspectableJointFabricAdministratorDevice.new(storage: backend,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    first.persistence.write_app_document(MatterJointFabricAdministrator::Device::APP_KEY_DOCUMENT,
      MatterJointFabricAdministrator::Device::IcacKeyState.new(icac_key.private_key, icac_key.public_key).to_document)
    first.install_test_fabric(fabric)
    old_admin_id = 0xA103_u64
    first.joint_fabric_datastore.admin_list = first.joint_fabric_datastore.admin_list + [
      Matter::Cluster::JointFabricDatastore::DatastoreAdministratorInformationEntryStruct.new(
        old_admin_id, "Old Administrator", 0xFFF1_u16,
        fabric.intermediate_cert || raise Matter::ConfigurationError.new("Anchor ICAC missing")),
    ]
    first.persistence.save_cluster(first.joint_fabric_datastore).should be_true

    first.stage_fabric_removal_for_spec(1_u8)
    first.joint_fabric_administrator.administrator_fabric_index.should be_nil
    first.persistence.app_document(MatterJointFabricAdministrator::Device::APP_KEY_DOCUMENT).should_not be_nil
    first.persistence.app_document(MatterJointFabricAdministrator::Device::APP_FABRIC_BINDING_DOCUMENT).should_not be_nil
    first.fabric_table.remove_fabric(1_u8).should be_true
    first.fabric_table.add_fabric(replacement).should be_true
    ENV["MATTER_JFA_ICAC_CSR_MAILBOX_PATH"] = "#{Dir.tempdir}/jfa-index-#{Random::Secure.hex(6)}"

    restored = InspectableJointFabricAdministratorDevice.new(storage: backend,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    restored.prepare_for_start
    restored.joint_fabric_administrator.administrator_fabric_index.should eq(1_u8)
    restored.joint_fabric_datastore.joint_fabric_index.should eq(1_u8)
    restored.joint_fabric_datastore.admin_list.map(&.node_id).should_not contain(old_admin_id)
    restored.joint_fabric_datastore.admin_list.map(&.node_id).should contain(replacement.node_id)
    restored.persistence.app_document(MatterJointFabricAdministrator::Device::APP_KEY_DOCUMENT).should be_nil
    replacement_binding = restored.persistence.app_document(MatterJointFabricAdministrator::Device::APP_FABRIC_BINDING_DOCUMENT) ||
                          raise Matter::StorageError.new("Replacement binding missing")
    MatterJointFabricAdministrator::Device::FabricBindingState.from_document(replacement_binding)
      .fabric_id.should eq(replacement.fabric_id)
  ensure
    first.try(&.shutdown!)
    restored.try(&.shutdown!)
    if previous_anchor
      ENV["MATTER_JFA_PROVISIONED_ANCHOR"] = previous_anchor
    else
      ENV.delete("MATTER_JFA_PROVISIONED_ANCHOR")
    end
    if previous_csr
      ENV["MATTER_JFA_ICAC_CSR_MAILBOX_PATH"] = previous_csr
    else
      ENV.delete("MATTER_JFA_ICAC_CSR_MAILBOX_PATH")
    end
  end

  it "retains Anchor credentials when fabric document deletion fails, then reattaches on restart" do
    crypto = Matter::Crypto::StandardCrypto.new
    icac_key = crypto.create_key_pair
    fabric = jfa_reuse_test_fabric(0xA100_u64, 0xA102_u64, icac_key: icac_key)
    previous_anchor = ENV["MATTER_JFA_PROVISIONED_ANCHOR"]?
    previous_csr = ENV["MATTER_JFA_ICAC_CSR_MAILBOX_PATH"]?
    ENV["MATTER_JFA_PROVISIONED_ANCHOR"] = "1"
    ENV.delete("MATTER_JFA_ICAC_CSR_MAILBOX_PATH")
    backend = FailingJfaMemory.new
    first = InspectableJointFabricAdministratorDevice.new(storage: backend,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    first.persistence.write_app_document(MatterJointFabricAdministrator::Device::APP_KEY_DOCUMENT,
      MatterJointFabricAdministrator::Device::IcacKeyState.new(icac_key.private_key, icac_key.public_key).to_document)
    first.install_test_fabric(fabric)
    first.joint_fabric_administrator.administrator_fabric_index.should eq(1_u8)
    retained_admin_id = 0xA103_u64
    retained_node_id = 0xA104_u64
    datastore = first.joint_fabric_datastore
    datastore.joint_fabric_index = 1_u8
    datastore.admin_list = datastore.admin_list + [Matter::Cluster::JointFabricDatastore::DatastoreAdministratorInformationEntryStruct.new(
      retained_admin_id, "Second Administrator", 0xFFF1_u16,
      fabric.intermediate_cert || raise Matter::ConfigurationError.new("Anchor ICAC missing"))]
    datastore.node_list = datastore.node_list + [Matter::Cluster::JointFabricDatastore::DatastoreNodeInformationEntryStruct.new(
      retained_node_id, "Second Node", Matter::Cluster::JointFabricDatastore::DatastoreStatusEntryStruct.new(
      Matter::Cluster::JointFabricDatastore::DatastoreStateEnum::Committed, 0_u32, 0_u8))]
    first.persistence.save_cluster(datastore).should be_true

    backend.fail_next_fabric_delete = true
    expect_raises(Matter::StorageError, "Injected fabric document deletion failure") do
      first.operational_credentials.credentials.remove_fabric(1_u8)
    end
    first.fabric_table.get_fabric(1_u8).should eq(fabric)
    saved_before = Matter::Commissioning::FabricRemovalJournal.previous(backend,
      Matter::Storage::Collections::CLUSTERS, first.joint_fabric_administrator.persistence_key)
    saved_before.should_not be_nil
    prior_admin = Matter::Cluster::JointFabricAdministrator.new(Matter::DataType::EndpointNumber.new(1_u16))
    prior_admin.restore_state(saved_before.as(Matter::Storage::Document))
    prior_admin.administrator_fabric_index.should eq(1_u8)
    first.joint_fabric_administrator.administrator_fabric_index.should eq(1_u8)
    first.joint_fabric_datastore.joint_fabric_index.should be_nil
    first.persistence.app_document(MatterJointFabricAdministrator::Device::APP_KEY_DOCUMENT).should_not be_nil
    first.joint_fabric_datastore.admin_list.map(&.node_id).should contain(retained_admin_id)
    first.joint_fabric_datastore.node_list.map(&.node_id).should contain(retained_node_id)
    restored = InspectableJointFabricAdministratorDevice.new(storage: backend,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    restored.prepare_for_start
    stored_admin = Matter::Cluster::JointFabricAdministrator.new(Matter::DataType::EndpointNumber.new(1_u16))
    stored_admin.restore_state(backend.read(Matter::Storage::Collections::CLUSTERS,
      first.joint_fabric_administrator.persistence_key).as(Matter::Storage::Document))
    stored_admin.administrator_fabric_index.should eq(1_u8)
    stored_datastore = Matter::Cluster::JointFabricDatastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    stored_datastore.restore_state(backend.read(Matter::Storage::Collections::CLUSTERS,
      first.joint_fabric_datastore.persistence_key).as(Matter::Storage::Document))
    stored_datastore.admin_list.map(&.node_id).should contain(retained_admin_id)
    stored_datastore.node_list.map(&.node_id).should contain(retained_node_id)
    restored.joint_fabric_administrator.administrator_fabric_index.should eq(1_u8)
    restored.joint_fabric_datastore.joint_fabric_index.should eq(1_u8)
    restored.joint_fabric_datastore.admin_list.map(&.node_id).should contain(retained_admin_id)
    restored.joint_fabric_datastore.node_list.map(&.node_id).should contain(retained_node_id)
    restored.operational_credentials.credentials.remove_fabric(1_u8).ok?.should be_true
    restored.persistence.app_document(MatterJointFabricAdministrator::Device::APP_KEY_DOCUMENT).should be_nil
    restored.joint_fabric_datastore.admin_list.should be_empty
    restored.joint_fabric_datastore.node_list.should be_empty
  ensure
    first.try(&.shutdown!)
    restored.try(&.shutdown!)
    if previous_anchor
      ENV["MATTER_JFA_PROVISIONED_ANCHOR"] = previous_anchor
    else
      ENV.delete("MATTER_JFA_PROVISIONED_ANCHOR")
    end
    if previous_csr
      ENV["MATTER_JFA_ICAC_CSR_MAILBOX_PATH"] = previous_csr
    else
      ENV.delete("MATTER_JFA_ICAC_CSR_MAILBOX_PATH")
    end
  end

  it "fails closed for a legacy Anchor with no binding when the same root reuses its index" do
    root_key = Matter::Crypto::StandardCrypto.new.create_key_pair
    old_fabric = jfa_reuse_test_fabric(0xA100_u64, 0xA102_u64, root_key: root_key)
    new_fabric = jfa_reuse_test_fabric(0xB200_u64, 0xB203_u64,
      root_key: root_key, root_cert: old_fabric.root_cert)
    old_fabric.root_cert.should eq(new_fabric.root_cert)
    previous_anchor = ENV["MATTER_JFA_PROVISIONED_ANCHOR"]?
    previous_csr = ENV["MATTER_JFA_ICAC_CSR_MAILBOX_PATH"]?
    ENV["MATTER_JFA_PROVISIONED_ANCHOR"] = "1"
    ENV["MATTER_JFA_ICAC_CSR_MAILBOX_PATH"] = "#{Dir.tempdir}/jfa-index-#{Random::Secure.hex(6)}"
    backend = Matter::Storage::Memory.new
    first = InspectableJointFabricAdministratorDevice.new(storage: backend,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    first.install_test_fabric(old_fabric)
    first.joint_fabric_datastore.admin_list.map(&.node_id).should contain(old_fabric.node_id)
    first.persistence.save_cluster(first.joint_fabric_datastore).should be_true
    first.persistence.save_cluster(first.joint_fabric_administrator).should be_true
    first.persistence.delete_app_document(MatterJointFabricAdministrator::Device::APP_FABRIC_BINDING_DOCUMENT)

    first.fabric_table.remove_fabric(1_u8).should be_true
    first.fabric_table.add_fabric(new_fabric).should be_true
    restored = InspectableJointFabricAdministratorDevice.new(storage: backend,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    restored.prepare_for_start
    restored.joint_fabric_datastore.admin_list.map(&.node_id).should_not contain(old_fabric.node_id)
    restored.joint_fabric_administrator.administrator_fabric_index.should eq(1_u8)
  ensure
    first.try(&.shutdown!)
    restored.try(&.shutdown!)
    if previous_anchor
      ENV["MATTER_JFA_PROVISIONED_ANCHOR"] = previous_anchor
    else
      ENV.delete("MATTER_JFA_PROVISIONED_ANCHOR")
    end
    if previous_csr
      ENV["MATTER_JFA_ICAC_CSR_MAILBOX_PATH"] = previous_csr
    else
      ENV.delete("MATTER_JFA_ICAC_CSR_MAILBOX_PATH")
    end
  end

  it "discards a legacy Datastore with no binding or saved AdministratorFabricIndex" do
    root_key = Matter::Crypto::StandardCrypto.new.create_key_pair
    old_fabric = jfa_reuse_test_fabric(0xA100_u64, 0xA102_u64, root_key: root_key)
    new_fabric = jfa_reuse_test_fabric(0xB200_u64, 0xB203_u64,
      root_key: root_key, root_cert: old_fabric.root_cert)
    previous_anchor = ENV["MATTER_JFA_PROVISIONED_ANCHOR"]?
    previous_csr = ENV["MATTER_JFA_ICAC_CSR_MAILBOX_PATH"]?
    ENV["MATTER_JFA_PROVISIONED_ANCHOR"] = "1"
    ENV["MATTER_JFA_ICAC_CSR_MAILBOX_PATH"] = "#{Dir.tempdir}/jfa-index-#{Random::Secure.hex(6)}"
    backend = Matter::Storage::Memory.new
    first = InspectableJointFabricAdministratorDevice.new(storage: backend,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    first.install_test_fabric(old_fabric)
    first.joint_fabric_datastore.admin_list.map(&.node_id).should contain(old_fabric.node_id)
    first.persistence.save_cluster(first.joint_fabric_datastore).should be_true
    first.joint_fabric_administrator.administrator_fabric_index = nil
    first.persistence.save_cluster(first.joint_fabric_administrator).should be_true
    first.persistence.delete_app_document(MatterJointFabricAdministrator::Device::APP_FABRIC_BINDING_DOCUMENT)

    first.fabric_table.remove_fabric(1_u8).should be_true
    first.fabric_table.add_fabric(new_fabric).should be_true
    restored = InspectableJointFabricAdministratorDevice.new(storage: backend,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    restored.prepare_for_start
    restored.joint_fabric_datastore.admin_list.map(&.node_id).should_not contain(old_fabric.node_id)
    restored.joint_fabric_administrator.administrator_fabric_index.should eq(1_u8)
  ensure
    first.try(&.shutdown!)
    restored.try(&.shutdown!)
    if previous_anchor
      ENV["MATTER_JFA_PROVISIONED_ANCHOR"] = previous_anchor
    else
      ENV.delete("MATTER_JFA_PROVISIONED_ANCHOR")
    end
    if previous_csr
      ENV["MATTER_JFA_ICAC_CSR_MAILBOX_PATH"] = previous_csr
    else
      ENV.delete("MATTER_JFA_ICAC_CSR_MAILBOX_PATH")
    end
  end

  it "reserves a fabric index when durable JFA cleanup fails before RemoveFabric" do
    fabric = jfa_reuse_test_fabric(0xA100_u64, 0xA102_u64)
    previous_anchor = ENV["MATTER_JFA_PROVISIONED_ANCHOR"]?
    previous_csr = ENV["MATTER_JFA_ICAC_CSR_MAILBOX_PATH"]?
    ENV["MATTER_JFA_PROVISIONED_ANCHOR"] = "1"
    ENV["MATTER_JFA_ICAC_CSR_MAILBOX_PATH"] = "#{Dir.tempdir}/jfa-index-#{Random::Secure.hex(6)}"
    backend = FailingJfaMemory.new
    device = InspectableJointFabricAdministratorDevice.new(storage: backend,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    device.install_test_fabric(fabric)
    backend.fail_next_administrator_write = true
    expect_raises(Matter::StorageError, "Could not persist erased Joint Fabric Administrator index") do
      device.operational_credentials.credentials.remove_fabric(1_u8)
    end
    device.fabric_table.get_fabric(1_u8).should eq(fabric)
    device.operational_credentials.credentials.remove_fabric(1_u8).ok?.should be_true
    device.fabric_table.get_fabric(1_u8).should be_nil
  ensure
    device.try(&.shutdown!)
    if previous_anchor
      ENV["MATTER_JFA_PROVISIONED_ANCHOR"] = previous_anchor
    else
      ENV.delete("MATTER_JFA_PROVISIONED_ANCHOR")
    end
    if previous_csr
      ENV["MATTER_JFA_ICAC_CSR_MAILBOX_PATH"] = previous_csr
    else
      ENV.delete("MATTER_JFA_ICAC_CSR_MAILBOX_PATH")
    end
  end

  it "does not restore a removed AdministratorFabricIndex after a crash before debounced writes" do
    fabric = jfa_reuse_test_fabric(0xA100_u64, 0xA102_u64)
    previous_anchor = ENV["MATTER_JFA_PROVISIONED_ANCHOR"]?
    previous_csr = ENV["MATTER_JFA_ICAC_CSR_MAILBOX_PATH"]?
    ENV["MATTER_JFA_PROVISIONED_ANCHOR"] = "1"
    ENV["MATTER_JFA_ICAC_CSR_MAILBOX_PATH"] = "#{Dir.tempdir}/jfa-index-#{Random::Secure.hex(6)}"
    backend = Matter::Storage::Memory.new
    first = InspectableJointFabricAdministratorDevice.new(storage: backend,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    first.fabric_table.add_fabric(fabric).should be_true
    first.install_test_fabric(fabric)
    first.joint_fabric_administrator.administrator_fabric_index.should eq(1_u8)
    first.persistence.save_cluster(first.joint_fabric_administrator).should be_true

    first.operational_credentials.credentials.remove_fabric(1_u8).ok?.should be_true
    restored = InspectableJointFabricAdministratorDevice.new(storage: backend,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    restored.prepare_for_start
    restored.joint_fabric_administrator.administrator_fabric_index.should be_nil
    restored.joint_fabric_datastore.joint_fabric_index.should be_nil
  ensure
    first.try(&.shutdown!)
    restored.try(&.shutdown!)
    if previous_anchor
      ENV["MATTER_JFA_PROVISIONED_ANCHOR"] = previous_anchor
    else
      ENV.delete("MATTER_JFA_PROVISIONED_ANCHOR")
    end
    if previous_csr
      ENV["MATTER_JFA_ICAC_CSR_MAILBOX_PATH"] = previous_csr
    else
      ENV.delete("MATTER_JFA_ICAC_CSR_MAILBOX_PATH")
    end
  end

  it "does not bind an abandoned Anchor Datastore to a different fabric reusing its index" do
    old_fabric = jfa_reuse_test_fabric(0xA100_u64, 0xA102_u64)
    new_fabric = jfa_reuse_test_fabric(0xB200_u64, 0xB203_u64)
    previous_anchor = ENV["MATTER_JFA_PROVISIONED_ANCHOR"]?
    previous_csr = ENV["MATTER_JFA_ICAC_CSR_MAILBOX_PATH"]?
    ENV["MATTER_JFA_PROVISIONED_ANCHOR"] = "1"
    ENV["MATTER_JFA_ICAC_CSR_MAILBOX_PATH"] = "#{Dir.tempdir}/jfa-index-#{Random::Secure.hex(6)}"
    backend = Matter::Storage::Memory.new
    first = InspectableJointFabricAdministratorDevice.new(storage: backend,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    first.fabric_table.add_fabric(old_fabric).should be_true
    first.install_test_fabric(old_fabric)
    first.joint_fabric_datastore.admin_list.map(&.node_id).should contain(old_fabric.node_id)
    first.persistence.save_cluster(first.joint_fabric_datastore).should be_true
    first.persistence.save_cluster(first.joint_fabric_administrator).should be_true

    # Model an interrupted legacy removal that deleted the fabric document but
    # never ran the JFA's post-delete callback.
    first.fabric_table.remove_fabric(1_u8).should be_true
    first.fabric_table.add_fabric(new_fabric).should be_true
    restored = InspectableJointFabricAdministratorDevice.new(storage: backend,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    restored.prepare_for_start
    restored.joint_fabric_datastore.admin_list.map(&.node_id).should_not contain(old_fabric.node_id)
    restored.joint_fabric_administrator.administrator_fabric_index.should eq(1_u8)
  ensure
    first.try(&.shutdown!)
    restored.try(&.shutdown!)
    if previous_anchor
      ENV["MATTER_JFA_PROVISIONED_ANCHOR"] = previous_anchor
    else
      ENV.delete("MATTER_JFA_PROVISIONED_ANCHOR")
    end
    if previous_csr
      ENV["MATTER_JFA_ICAC_CSR_MAILBOX_PATH"] = previous_csr
    else
      ENV.delete("MATTER_JFA_ICAC_CSR_MAILBOX_PATH")
    end
  end

  it "selects an explicit test DCL trust source without falling back to a static root" do
    device = InspectableJointFabricAdministratorDevice.new
    trust = device.anchor_trust_for_spec(0xFFF1_u16, nil, "https://127.0.0.1")
    trust.should be_a(Matter::Controller::VidVerification::DclOperationalTrustAnchors)
    expect_raises(Matter::ConfigurationError) do
      device.anchor_trust_for_spec(0xFFF1_u16, nil, "http://127.0.0.1")
    end
    expect_raises(Matter::ConfigurationError) do
      device.anchor_trust_for_spec(0xFFF1_u16, nil, "https://dcl.example")
    end
    expect_raises(Matter::ConfigurationError) do
      device.anchor_trust_for_spec(0xFFF1_u16, nil, nil)
    end
  end

  it "selects a configured HTTPS DCL gateway for production JFA VID trust" do
    device = InspectableJointFabricAdministratorDevice.new
    trust = device.anchor_trust_for_spec(0x1234_u16, nil, nil, "https://dcl.example")
    trust.should be_a(Matter::Controller::VidVerification::DclOperationalTrustAnchors)
    expect_raises(Matter::ConfigurationError) do
      device.anchor_trust_for_spec(0x1234_u16, nil, nil, "http://dcl.example")
    end
    expect_raises(Matter::ConfigurationError) do
      device.anchor_trust_for_spec(0x1234_u16, nil, "https://127.0.0.1", "https://dcl.example")
    end
  end

  it "decodes a legacy command YAML without the new removal interruption flag" do
    path = File.join(Dir.tempdir, "matter-jfa-legacy-command-#{Random::Secure.hex(6)}.yml")
    request = MatterJointFabricAdministrator::Device::CommandRequest.new("inspect-fabric", 0xA102_u64,
      fabric_id: 0xA100_u64, root_public_key: Bytes[1_u8], nonce: "legacy-command")
    document = request.to_document
    document.delete("interrupt_after_remove_admin")
    document.delete("interrupt_before_remove_admin")
    document.delete("interrupt_before_anchor_noc")
    backend = Matter::Storage::YamlFile.new(path)
    backend.open
    backend.write(MatterJointFabricAdministrator::Device::COMMAND_RPC_COLLECTION, "request", document)
    backend.close

    reopened = Matter::Storage::YamlFile.new(path)
    reopened.open
    stored = reopened.read(MatterJointFabricAdministrator::Device::COMMAND_RPC_COLLECTION, "request") ||
             raise Matter::StorageError.new("Legacy JFA command was not saved")
    restored = MatterJointFabricAdministrator::Device::CommandRequest.from_document(stored)
    restored.operation.should eq("inspect-fabric")
    restored.node_id.should eq(0xA102_u64)
    restored.interrupt_after_remove_admin?.should be_false
    restored.interrupt_before_remove_admin?.should be_false
    restored.interrupt_before_anchor_noc?.should be_false
  ensure
    backend.try(&.close) if backend.try(&.open?)
    reopened.try(&.close) if reopened.try(&.open?)
    File.delete?(path) if path
  end

  it "round-trips the fault hook for interruption after Anchor Datastore persistence" do
    request = MatterJointFabricAdministrator::Device::CommandRequest.new("remove-administrator", 0xA102_u64,
      interrupt_before_anchor_noc: true)
    restored = MatterJointFabricAdministrator::Device::CommandRequest.from_document(request.to_document)
    restored.interrupt_before_anchor_noc?.should be_true
  end

  it "round-trips the transfer follow-up interruption flag and defaults old commands to false" do
    request = MatterJointFabricAdministrator::Device::CommandRequest.new("transfer-anchor", 0xA102_u64,
      interrupt_before_transfer_follow_up: true)
    MatterJointFabricAdministrator::Device::CommandRequest.from_document(request.to_document)
      .interrupt_before_transfer_follow_up?.should be_true

    old_document = request.to_document
    old_document.delete("interrupt_before_transfer_follow_up")
    MatterJointFabricAdministrator::Device::CommandRequest.from_document(old_document)
      .interrupt_before_transfer_follow_up?.should be_false
  end

  it "round-trips the first participant follow-up interruption flag and defaults old commands to false" do
    request = MatterJointFabricAdministrator::Device::CommandRequest.new("transfer-anchor", 0xA102_u64,
      interrupt_after_first_transfer_follow_up: true)
    MatterJointFabricAdministrator::Device::CommandRequest.from_document(request.to_document)
      .interrupt_after_first_transfer_follow_up?.should be_true

    old_document = request.to_document
    old_document.delete("interrupt_after_first_transfer_follow_up")
    MatterJointFabricAdministrator::Device::CommandRequest.from_document(old_document)
      .interrupt_after_first_transfer_follow_up?.should be_false
  end

  it "round-trips the transfer request interruption flag and defaults old commands to false" do
    request = MatterJointFabricAdministrator::Device::CommandRequest.new("transfer-anchor", 0xA102_u64,
      interrupt_after_transfer_request: true)
    MatterJointFabricAdministrator::Device::CommandRequest.from_document(request.to_document)
      .interrupt_after_transfer_request?.should be_true

    old_document = request.to_document
    old_document.delete("interrupt_after_transfer_request")
    MatterJointFabricAdministrator::Device::CommandRequest.from_document(old_document)
      .interrupt_after_transfer_request?.should be_false
  end

  it "retains the link-local interface scope in an Anchor ICAC exchange handoff" do
    peer = Socket::IPAddress.new("fe80::1234%1", 5540)
    request = MatterJointFabricAdministrator::Device::AnchorExchangeRequest.new(
      0xA100_u64, Bytes[1], 0xB200_u64, peer, 1_u16, Bytes.new(65, 1_u8), 3_u64)

    restored = MatterJointFabricAdministrator::Device::AnchorExchangeRequest.from_document(request.to_document)
    restored.peer_address.should eq("fe80::1234%1")
    reconstructed = Socket::IPAddress.new(restored.peer_address, restored.peer_port)
    reconstructed.zone_id.should eq(peer.zone_id)
  end

  it "durably repairs a legacy Anchor Datastore IPK before serving it after restart" do
    crypto = Matter::Crypto::StandardCrypto.new
    root_key = crypto.create_key_pair
    icac_key = crypto.create_key_pair
    noc_key = crypto.create_key_pair
    fabric_id = 0xA100_u64
    node_id = 0xA102_u64
    root = Matter::Crypto::MatterCertificate::Builder.root(root_key, 1_u64, Bytes[1], crypto)
    icac = Matter::Crypto::MatterCertificate::Builder.intermediate(
      icac_key.public_key, fabric_id, 2_u64, root_key, 1_u64, Bytes[2], crypto, anchor: true)
    noc = Matter::Crypto::MatterCertificate::Builder.node(
      noc_key.public_key, fabric_id, node_id, icac_key, 1_u64, Bytes[3], crypto,
      issuer_icac_id: 2_u64, issuer_certificate: icac,
      case_authenticated_tag: 0xFFFE_0001_u32)
    fabric = Matter::Fabric.new(fabric_id, 1_u8, node_id, root_key.public_key, noc, noc_key,
      Bytes.new(16, 0xA5_u8), intermediate_cert: icac, root_cert: root,
      cats: [Matter::DataType::CaseAuthenticatedTag.new(0xFFFE_0001_u32)])
    path = File.join(Dir.tempdir, "matter-jfa-legacy-ipk-#{Random::Secure.hex(6)}.yml")
    previous_anchor = ENV["MATTER_JFA_PROVISIONED_ANCHOR"]?
    previous_csr = ENV["MATTER_JFA_ICAC_CSR_MAILBOX_PATH"]?
    ENV["MATTER_JFA_PROVISIONED_ANCHOR"] = "1"
    ENV["MATTER_JFA_ICAC_CSR_MAILBOX_PATH"] = "#{path}.csr"

    first = InspectableJointFabricAdministratorDevice.new(storage: Matter::Storage::YamlFile.new(path),
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    first.fabric_table.add_fabric(fabric).should be_true
    legacy = first.joint_fabric_datastore
    legacy.configure_anchor(root, node_id, fabric.vendor_id, "Legacy Anchor").success?.should be_true
    legacy.group_key_set_list.first.epoch_key0.should be_nil
    first.persistence.save_cluster(legacy).should be_true
    first.shutdown!

    repaired = InspectableJointFabricAdministratorDevice.new(storage: Matter::Storage::YamlFile.new(path),
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    repaired.prepare_for_start
    served = repaired.joint_fabric_datastore
    served.request_is_case_session = true
    key_sets = Array(Matter::Cluster::JointFabricDatastore::DatastoreGroupKeySetStruct).from_tlv(
      served.read_attribute(Matter::Cluster::JointFabricDatastore::ATTR_GROUP_KEY_SET_LIST, 1_u8).as(TLV::Any).to_slice)
    key_sets.find!(&.group_key_set_id.==(0_u16)).epoch_key0.should eq(fabric.ipk)

    # Opening a second backend immediately models a process loss before the
    # normal debounced cluster-state save or graceful shutdown.
    after_crash = InspectableJointFabricAdministratorDevice.new(storage: Matter::Storage::YamlFile.new(path),
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    after_crash.joint_fabric_datastore.group_key_set_list
      .find!(&.group_key_set_id.==(0_u16)).epoch_key0.should eq(fabric.ipk)
  ensure
    first.try(&.shutdown!)
    repaired.try(&.shutdown!)
    after_crash.try(&.shutdown!)
    File.delete?(path) if path
    if previous_anchor
      ENV["MATTER_JFA_PROVISIONED_ANCHOR"] = previous_anchor
    else
      ENV.delete("MATTER_JFA_PROVISIONED_ANCHOR")
    end
    if previous_csr
      ENV["MATTER_JFA_ICAC_CSR_MAILBOX_PATH"] = previous_csr
    else
      ENV.delete("MATTER_JFA_ICAC_CSR_MAILBOX_PATH")
    end
  end

  it "starts Anchor verification from the operational listener without taking ownership of it" do
    device = InspectableJointFabricAdministratorDevice.new(storage: Matter::Storage::Memory.new,
      ip_addresses: [Socket::IPAddress.new("::1", 0)], port: 0)
    client = device.anchor_verification_client_for_spec(9_u64)
    client.transport.should be(device.transport)
    client.transport.port.should eq(device.port)
    client.close
    device.transport.socket.closed?.should be_false
  ensure
    client.try(&.close)
    device.try(&.shutdown!)
  end

  it "uses the authenticated Anchor CASE source when operational discovery misses" do
    previous = ENV["MATTER_JFA_ANCHOR_OPERATIONAL_PORT"]?
    ENV.delete("MATTER_JFA_ANCHOR_OPERATIONAL_PORT")
    device = InspectableJointFabricAdministratorDevice.new(storage: Matter::Storage::Memory.new,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    source = Socket::IPAddress.new("127.0.0.2", 44551)
    device.anchor_verification_peer_for_spec(source).should eq(source)
    expect_raises(Matter::TransportError, /operational port is unavailable/) do
      device.anchor_verification_peer_for_spec(Socket::IPAddress.new("127.0.0.2", 0))
    end
  ensure
    if previous
      ENV["MATTER_JFA_ANCHOR_OPERATIONAL_PORT"] = previous
    else
      ENV.delete("MATTER_JFA_ANCHOR_OPERATIONAL_PORT")
    end
  end

  it "keeps a fixture DUT out of SDK discovery until its gate opens" do
    gate = File.join(Dir.tempdir, "matter-jfa-discovery-#{Random::Secure.hex(6)}")
    previous = ENV["MATTER_JFA_DISCOVERY_GATE_PATH"]?
    ENV["MATTER_JFA_DISCOVERY_GATE_PATH"] = gate
    device = InspectableJointFabricAdministratorDevice.new(storage: Matter::Storage::Memory.new,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    device.start
    device.responder.advertised_commissioning_info.should be_nil
    File.write(gate, "ready")
    deadline = Time.instant + 5.seconds
    until device.responder.advertised_commissioning_info || Time.instant >= deadline
      sleep 50.milliseconds
    end
    device.responder.advertised_commissioning_info.should_not be_nil
  ensure
    device.try(&.shutdown!)
    File.delete(gate) if gate && File.exists?(gate)
    if previous
      ENV["MATTER_JFA_DISCOVERY_GATE_PATH"] = previous
    else
      ENV.delete("MATTER_JFA_DISCOVERY_GATE_PATH")
    end
  end

  it "does not expose an unprovisioned second JFA to wildcard commissioning reads" do
    previous = ENV["MATTER_JFA_KEEP_BOOTSTRAP_DATASTORE"]?
    ENV.delete("MATTER_JFA_KEEP_BOOTSTRAP_DATASTORE")
    device = InspectableJointFabricAdministratorDevice.new(storage: Matter::Storage::Memory.new,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    device.prepare_for_start
    device.endpoint_ids.should eq([1_u16])
    device.node.clusters.keys.should_not contain({2_u16, Matter::Cluster::JointFabricAdministrator::CLUSTER_ID})

    ENV["MATTER_JFA_KEEP_BOOTSTRAP_DATASTORE"] = "1"
    retained = InspectableJointFabricAdministratorDevice.new(storage: Matter::Storage::Memory.new,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    retained.prepare_for_start
    retained.endpoint_ids.should eq([1_u16, 2_u16])
  ensure
    if previous
      ENV["MATTER_JFA_KEEP_BOOTSTRAP_DATASTORE"] = previous
    else
      ENV.delete("MATTER_JFA_KEEP_BOOTSTRAP_DATASTORE")
    end
  end

  it "serves JFA status commands on a newly commissioned non-Anchor fabric" do
    crypto = Matter::Crypto::StandardCrypto.new
    root_key = crypto.create_key_pair
    icac_key = crypto.create_key_pair
    noc_key = crypto.create_key_pair
    fabric_id = 0xCAFE_u64
    root = Matter::Crypto::MatterCertificate::Builder.root(root_key, 1_u64, Bytes[1], crypto)
    icac = Matter::Crypto::MatterCertificate::Builder.intermediate(
      icac_key.public_key, fabric_id, 2_u64, root_key, 1_u64, Bytes[2], crypto)
    noc = Matter::Crypto::MatterCertificate::Builder.node(
      noc_key.public_key, fabric_id, 3_u64, icac_key, 1_u64, Bytes[3], crypto,
      issuer_icac_id: 2_u64, issuer_certificate: icac)
    fabric = Matter::Fabric.new(fabric_id, 1_u8, 3_u64, root_key.public_key, noc, noc_key,
      Bytes.new(16, 1_u8), intermediate_cert: icac, root_cert: root)
    device = InspectableJointFabricAdministratorDevice.new(storage: Matter::Storage::Memory.new,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)

    device.install_test_fabric(fabric)
    administrator = device.joint_fabric_administrator
    administrator.administrator_fabric_index.should be_nil
    administrator.request_is_case_session = true
    administrator.request_fabric_index = 1_u8
    administrator.icaccsr_request.should eq(Matter::InteractionModel::Status.failsafe_required)
    device.advertised_joint_role.should eq(Matter::MDNS::JointFabricRole::Available)
  end

  it "accepts an SDK-issued Anchor ICAC without a private organizational unit" do
    crypto = Matter::Crypto::StandardCrypto.new
    root_key = crypto.create_key_pair
    icac_key = crypto.create_key_pair
    noc_key = crypto.create_key_pair
    root = Matter::Crypto::MatterCertificate::Builder.root(root_key, 1_u64, Bytes[1], crypto)
    icac = Matter::Crypto::MatterCertificate::Builder.intermediate(
      icac_key.public_key, 0xA100_u64, 2_u64, root_key, 1_u64, Bytes[2], crypto)
    noc = Matter::Crypto::MatterCertificate::Builder.node(
      noc_key.public_key, 0xA100_u64, 3_u64, icac_key, 1_u64, Bytes[3], crypto,
      issuer_icac_id: 2_u64, issuer_certificate: icac,
      case_authenticated_tag: 0xFFFE_0001_u32)
    fabric = Matter::Fabric.new(0xA100_u64, 1_u8, 3_u64, root_key.public_key,
      noc, noc_key, Bytes.new(16, 1_u8), intermediate_cert: icac, root_cert: root,
      cats: [Matter::DataType::CaseAuthenticatedTag.new(0xFFFE_0001_u32)])
    previous = ENV["MATTER_JFA_PROVISIONED_ANCHOR"]?
    ENV["MATTER_JFA_PROVISIONED_ANCHOR"] = "1"
    device = InspectableJointFabricAdministratorDevice.new(storage: Matter::Storage::Memory.new,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    device.anchor_profile_for_spec(fabric).should be_true
    rotated_noc = Matter::Crypto::MatterCertificate::Builder.node(
      noc_key.public_key, 0xA100_u64, 3_u64, icac_key, 2_u64, Bytes[4], crypto,
      issuer_icac_id: 2_u64, issuer_certificate: icac,
      case_authenticated_tag: 0xFFFE_0002_u32)
    rotated = Matter::Fabric.new(0xA100_u64, 1_u8, 3_u64, root_key.public_key,
      rotated_noc, noc_key, Bytes.new(16, 1_u8), intermediate_cert: icac, root_cert: root,
      cats: [Matter::DataType::CaseAuthenticatedTag.new(0xFFFE_0002_u32)])
    device.anchor_profile_for_spec(rotated).should be_true
    expect_raises(ArgumentError, /version number must not be 0/) do
      Matter::DataType::CaseAuthenticatedTag.new(0xFFFE_0000_u32)
    end
  ensure
    if previous
      ENV["MATTER_JFA_PROVISIONED_ANCHOR"] = previous
    else
      ENV.delete("MATTER_JFA_PROVISIONED_ANCHOR")
    end
  end

  it "keeps the bootstrap and joined Administrator services bound to distinct fabrics" do
    crypto = Matter::Crypto::StandardCrypto.new
    b_root_key = crypto.create_key_pair
    b_icac_key = crypto.create_key_pair
    b_noc_key = crypto.create_key_pair
    b_root = Matter::Crypto::MatterCertificate::Builder.root(b_root_key, 1_u64, Bytes[1], crypto)
    b_icac = Matter::Crypto::MatterCertificate::Builder.intermediate(
      b_icac_key.public_key, 0xB100_u64, 2_u64, b_root_key, 1_u64, Bytes[2], crypto, anchor: true)
    b_noc = Matter::Crypto::MatterCertificate::Builder.node(
      b_noc_key.public_key, 0xB100_u64, 0xB102_u64, b_icac_key, 1_u64, Bytes[3], crypto,
      issuer_icac_id: 2_u64, issuer_certificate: b_icac,
      case_authenticated_tag: 0xFFFE_0001_u32)
    b_fabric = Matter::Fabric.new(0xB100_u64, 1_u8, 0xB102_u64, b_root_key.public_key,
      b_noc, b_noc_key, Bytes.new(16, 1_u8), intermediate_cert: b_icac, root_cert: b_root,
      cats: [Matter::DataType::CaseAuthenticatedTag.new(0xFFFE_0001_u32)])
    bootstrap_path = File.join(Dir.tempdir, "matter-jfa-concurrent-#{Random::Secure.hex(6)}.yml")
    bootstrap_store = Matter::Controller::StateStore.new(Matter::Storage::YamlFile.new(bootstrap_path))
    bootstrap_store.save(Matter::Controller::State.new(fabric: Matter::Controller::FabricInfo.new(
      0xB100_u64, 0xB102_u64, b_fabric.ipk, b_root, b_root_key.public_key,
      b_noc, b_noc_key.private_key, root_private_key: b_root_key.private_key,
      intermediate_cert: b_icac, intermediate_private_key: b_icac_key.private_key)))
    bootstrap_store.backend.close

    a_root_key = crypto.create_key_pair
    a_operational_icac_key = crypto.create_key_pair
    a_noc_key = crypto.create_key_pair
    a_root = Matter::Crypto::MatterCertificate::Builder.root(a_root_key, 3_u64, Bytes[4], crypto)
    a_icac = Matter::Crypto::MatterCertificate::Builder.intermediate(
      a_operational_icac_key.public_key, 0xA100_u64, 4_u64, a_root_key, 3_u64, Bytes[5], crypto)
    committed_a_icac = Matter::Crypto::MatterCertificate::Builder.intermediate(
      b_icac_key.public_key, 0xA100_u64, 4_u64, a_root_key, 3_u64, Bytes[7], crypto)
    a_noc = Matter::Crypto::MatterCertificate::Builder.node(
      a_noc_key.public_key, 0xA100_u64, 0xA103_u64, a_operational_icac_key, 2_u64, Bytes[6], crypto,
      issuer_icac_id: 4_u64, issuer_certificate: a_icac,
      case_authenticated_tag: 0xFFFF_0001_u32)
    a_fabric = Matter::Fabric.new(0xA100_u64, 2_u8, 0xA103_u64, a_root_key.public_key,
      a_noc, a_noc_key, Bytes.new(16, 2_u8), intermediate_cert: a_icac, root_cert: a_root,
      cats: [Matter::DataType::CaseAuthenticatedTag.new(0xFFFF_0001_u32)])

    previous_provisioned = ENV["MATTER_JFA_PROVISIONED_ANCHOR"]?
    previous_bootstrap = ENV["MATTER_JFA_BOOTSTRAP_STATE_PATH"]?
    previous_keep = ENV["MATTER_JFA_KEEP_BOOTSTRAP_DATASTORE"]?
    previous_jcm = ENV["MATTER_JFA_ALLOW_JCM"]?
    ENV["MATTER_JFA_PROVISIONED_ANCHOR"] = "1"
    ENV["MATTER_JFA_BOOTSTRAP_STATE_PATH"] = bootstrap_path
    ENV["MATTER_JFA_KEEP_BOOTSTRAP_DATASTORE"] = "1"
    backend = Matter::Storage::Memory.new
    device = InspectableJointFabricAdministratorDevice.new(storage: backend,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    device.install_test_fabric(b_fabric)
    device.bootstrap_joint_fabric_administrator.administrator_fabric_index.should eq(1_u8)
    device.bootstrap_joint_fabric_administrator.service.should be_a(Matter::Commissioning::JointFabricAdministratorService)
    device.bootstrap_joint_fabric_administrator.begin_provisional_administrator_fabric_index(2_u8)
    device.persist_bootstrap_icac_commit_for_spec(committed_a_icac)
    saved_icac = device.persistence.app_document(MatterJointFabricAdministrator::Device::APP_ICAC_DOCUMENT)
      .as(Matter::Storage::Document)
    MatterJointFabricAdministrator::Device::IcacCertificateState.from_document(saved_icac)
      .certificate.should eq(committed_a_icac)
    device.persistence.app_document(MatterJointFabricAdministrator::Device::APP_BOOTSTRAP_ICAC_DOCUMENT).should be_nil
    device.install_test_fabric(a_fabric)
    device.restore_bootstrap_administrator_binding_for_spec
    device.joint_fabric_administrator.administrator_fabric_index.should eq(2_u8)
    device.joint_fabric_administrator.service.as(Matter::Commissioning::JointFabricAdministratorService)
      .cross_signed_icac.should eq(committed_a_icac)
    device.access_control.acl(2_u8).flat_map(&.subjects).should contain(0xFFFF_FFFD_FFFF_0001_u64)
    device.bootstrap_joint_fabric_administrator.administrator_fabric_index.should eq(1_u8)
    device.bootstrap_joint_fabric_administrator.service.should be_a(Matter::Commissioning::JointFabricAdministratorService)
    device.bootstrap_joint_fabric_datastore.joint_fabric_index.should eq(1_u8)
    device.joint_fabric_datastore.joint_fabric_index.should eq(2_u8)
    device.joint_fabric_datastore.access_mode.should eq(Matter::Cluster::JointFabricDatastore::AccessMode::Inactive)

    wrong_joined = InspectableJointFabricAdministratorDevice.new(storage: Matter::Storage::Memory.new,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    wrong_joined.install_test_fabric(b_fabric)
    unrelated_key = crypto.create_key_pair
    wrong_joined.persistence.write_app_document(MatterJointFabricAdministrator::Device::APP_KEY_DOCUMENT,
      MatterJointFabricAdministrator::Device::IcacKeyState.new(
        unrelated_key.private_key, unrelated_key.public_key).to_document)
    wrong_joined.persistence.write_app_document(MatterJointFabricAdministrator::Device::APP_ICAC_DOCUMENT,
      MatterJointFabricAdministrator::Device::IcacCertificateState.new(committed_a_icac).to_document)
    expect_raises(Matter::ConfigurationError, "Joined JFA ICAC private key is unavailable") do
      wrong_joined.install_test_fabric(a_fabric)
    end
    wrong_joined.access_control.acl(2_u8).flat_map(&.subjects)
      .should_not contain(0xFFFF_FFFD_FFFF_0001_u64)

    # The official SDK JFC owns the ICAC signer remotely. Its cross-signed
    # ICAC reuses the commissioned ICAC key but can have a different ICAC ID.
    remote_icac = Matter::Crypto::MatterCertificate::Builder.intermediate(
      a_operational_icac_key.public_key, 0xA100_u64, 5_u64, a_root_key, 3_u64, Bytes[8], crypto)
    previous_remote = ENV["MATTER_JFA_ICAC_CSR_MAILBOX_PATH"]?
    ENV["MATTER_JFA_ICAC_CSR_MAILBOX_PATH"] = File.join(Dir.tempdir, "remote-jfa-csr-#{Random::Secure.hex(6)}")
    remote_joined = InspectableJointFabricAdministratorDevice.new(storage: Matter::Storage::Memory.new,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    remote_joined.install_test_fabric(b_fabric)
    remote_joined.persistence.write_app_document(MatterJointFabricAdministrator::Device::APP_ICAC_DOCUMENT,
      MatterJointFabricAdministrator::Device::IcacCertificateState.new(remote_icac).to_document)
    remote_joined.install_test_fabric(a_fabric)
    remote_joined.joint_fabric_administrator.administrator_fabric_index.should eq(2_u8)
    remote_joined.joint_fabric_administrator.service.as(Matter::Commissioning::JointFabricAdministratorService)
      .cross_signed_icac.should eq(remote_icac)

    wrong_remote = InspectableJointFabricAdministratorDevice.new(storage: Matter::Storage::Memory.new,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    wrong_remote.install_test_fabric(b_fabric)
    wrong_remote.persistence.write_app_document(MatterJointFabricAdministrator::Device::APP_ICAC_DOCUMENT,
      MatterJointFabricAdministrator::Device::IcacCertificateState.new(committed_a_icac).to_document)
    wrong_remote.install_test_fabric(a_fabric)
    wrong_remote.joint_fabric_administrator.administrator_fabric_index.should eq(1_u8)
    if previous_remote
      ENV["MATTER_JFA_ICAC_CSR_MAILBOX_PATH"] = previous_remote
    else
      ENV.delete("MATTER_JFA_ICAC_CSR_MAILBOX_PATH")
    end

    restored = InspectableJointFabricAdministratorDevice.new(storage: backend,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    restored.install_test_fabric(b_fabric)
    restored.install_test_fabric(a_fabric)
    restored.joint_fabric_administrator.administrator_fabric_index.should eq(2_u8)
    restored.bootstrap_joint_fabric_administrator.administrator_fabric_index.should eq(1_u8)
    restored.propagation_fabric_for_spec.try(&.fabric_id).should eq(0xB100_u64)
    restored.controller_store_for_spec.should_not be_nil
    restored.bootstrap_joint_fabric_administrator.service.should be_a(Matter::Commissioning::JointFabricAdministratorService)
    restored.remove_test_fabric(2_u8)
    restored.bootstrap_joint_fabric_administrator.service.should be_a(Matter::Commissioning::JointFabricAdministratorService)
    restored.advertised_joint_role.should eq(
      Matter::MDNS::JointFabricRole::Administrator |
      Matter::MDNS::JointFabricRole::Anchor |
      Matter::MDNS::JointFabricRole::Datastore)
    restored.persistence.app_document(MatterJointFabricAdministrator::Device::APP_KEY_DOCUMENT).should_not be_nil
    device.remove_test_fabric(1_u8)
    device.joint_fabric_administrator.administrator_fabric_index.should eq(2_u8)
    device.joint_fabric_administrator.service.should be_a(Matter::Commissioning::JointFabricAdministratorService)
    device.persistence.app_document(MatterJointFabricAdministrator::Device::APP_KEY_DOCUMENT).should_not be_nil

    promoted_backend = Matter::Storage::Memory.new
    promoted = InspectableJointFabricAdministratorDevice.new(storage: promoted_backend,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    promoted.install_test_fabric(b_fabric)
    promoted.persistence.write_app_document(MatterJointFabricAdministrator::Device::APP_ICAC_DOCUMENT,
      MatterJointFabricAdministrator::Device::IcacCertificateState.new(committed_a_icac).to_document)
    promoted.install_test_fabric(a_fabric)
    promoted.select_anchor_administrator_fabric_for_spec(1_u8)
    promoted.persist_anchor_role_for_spec(true)

    # The promoted JFA must serve B immediately. A restart should not be
    # required to replace the joined A service's window callback.
    ENV["MATTER_JFA_ALLOW_JCM"] = "1"
    promoted_admin = promoted.joint_fabric_administrator
    promoted_admin.request_is_case_session = true
    promoted_admin.request_fabric_index = 1_u8
    promoted_admin.request_peer_subject_ids = [0xFFFF_FFFD_FFFF_0001_u64]
    window_request = Matter::Cluster::JointFabricAdministrator::OpenJointCommissioningWindowRequest.new(
      400_u16, Bytes.new(97, 0_u8), 3839_u16, 1000_u32, Bytes.new(16, 0_u8))
    begin
      promoted_admin.service.as(Matter::Commissioning::JointFabricAdministratorService)
        .open_joint_commissioning_window(promoted_admin, window_request).success?.should be_true
      promoted.administrator_commissioning.window.admin_fabric_index.should eq(1_u8)
    ensure
      promoted.administrator_commissioning.window.revoke if promoted.administrator_commissioning.window.open?
    end

    binding = MatterJointFabricAdministrator::Device::FabricBindingState.from_document(
      promoted.persistence.app_document(MatterJointFabricAdministrator::Device::APP_FABRIC_BINDING_DOCUMENT)
        .as(Matter::Storage::Document))
    binding.matches?(b_fabric).should be_true
    promoted.persistence.app_document(MatterJointFabricAdministrator::Device::APP_ICAC_DOCUMENT).should be_nil

    promoted_restored = InspectableJointFabricAdministratorDevice.new(storage: promoted_backend,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    promoted_restored.install_test_fabric(b_fabric)
    promoted_restored.install_test_fabric(a_fabric)
    promoted_restored.joint_fabric_administrator.administrator_fabric_index.should eq(1_u8)
    promoted_restored.joint_fabric_datastore.joint_fabric_index.should eq(1_u8)
    promoted_restored.joint_fabric_datastore.access_mode.should eq(Matter::Cluster::JointFabricDatastore::AccessMode::Active)
    promoted_restored.bootstrap_joint_fabric_administrator.administrator_fabric_index.should be_nil
    promoted_restored.bootstrap_joint_fabric_datastore.joint_fabric_index.should eq(1_u8)
    promoted_restored.bootstrap_joint_fabric_datastore.access_mode.should eq(Matter::Cluster::JointFabricDatastore::AccessMode::Inactive)
  ensure
    if previous_provisioned
      ENV["MATTER_JFA_PROVISIONED_ANCHOR"] = previous_provisioned
    else
      ENV.delete("MATTER_JFA_PROVISIONED_ANCHOR")
    end
    if previous_bootstrap
      ENV["MATTER_JFA_BOOTSTRAP_STATE_PATH"] = previous_bootstrap
    else
      ENV.delete("MATTER_JFA_BOOTSTRAP_STATE_PATH")
    end
    if previous_keep
      ENV["MATTER_JFA_KEEP_BOOTSTRAP_DATASTORE"] = previous_keep
    else
      ENV.delete("MATTER_JFA_KEEP_BOOTSTRAP_DATASTORE")
    end
    if previous_jcm
      ENV["MATTER_JFA_ALLOW_JCM"] = previous_jcm
    else
      ENV.delete("MATTER_JFA_ALLOW_JCM")
    end
    File.delete?(bootstrap_path) if bootstrap_path
  end

  it "fails closed without migration attestation trust and accepts explicit production trust" do
    previous = ENV["MATTER_JFA_MIGRATION_TEST_TRUST"]?
    ENV.delete("MATTER_JFA_MIGRATION_TEST_TRUST")
    device = InspectableJointFabricAdministratorDevice.new(storage: Matter::Storage::Memory.new,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    expect_raises(Matter::ConfigurationError, /not configured/) do
      device.migration_verifier_for_spec
    end
    expect_raises(Matter::ConfigurationError, /revocation source/) do
      device.migration_attestation_trust = Matter::Controller::AttestationTrustStore.new(
        [Bytes[1]], {"signer" => Bytes[2]})
    end
    fixture = Matter::Controller::AttestationTrustStore.matter_test_fixture
    production_trust = Matter::Controller::AttestationTrustStore.new(
      fixture.paa_certificates, fixture.cd_signers,
      revocation_check: fixture.revocation_check)
    device.migration_attestation_trust = production_trust
    device.migration_verifier_for_spec.should be_a(Matter::Controller::DeviceAttestationVerifier)
    production_trust.allow_test_attestation?.should be_false
  ensure
    if previous
      ENV["MATTER_JFA_MIGRATION_TEST_TRUST"] = previous
    else
      ENV.delete("MATTER_JFA_MIGRATION_TEST_TRUST")
    end
  end

  it "treats a legacy non-Anchor role record as transfer-complete" do
    document = Matter::Storage::Document.new
    document["anchor"] = false
    role = MatterJointFabricAdministrator::Device::JointFabricRoleState.from_document(document)
    role.anchor?.should be_false
    role.transfer_complete?.should be_true
  end

  it "exposes both mandatory JFA clusters on device type 0x0130" do
    device = MatterJointFabricAdministrator::Device.new(storage: Matter::Storage::Memory.new,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    endpoint = device.node.endpoint(1_u16).as(Matter::Endpoint)
    endpoint.primary_device_type.as(Matter::DeviceType).device_type_id.id.should eq(0x0130_u32)
    endpoint.has_cluster?(Matter::Cluster::JointFabricDatastore::CLUSTER_ID).should be_true
    endpoint.has_cluster?(Matter::Cluster::JointFabricAdministrator::CLUSTER_ID).should be_true
    endpoint.validate.should be_empty
    device.node.endpoint(2_u16).as(Matter::Endpoint)
      .has_cluster?(Matter::Cluster::JointFabricDatastore::CLUSTER_ID).should be_true
  end

  it "advertises only availability until provisioned as an Anchor" do
    device = InspectableJointFabricAdministratorDevice.new(storage: Matter::Storage::Memory.new,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    device.advertised_joint_role.should eq(Matter::MDNS::JointFabricRole::Available)
  end

  it "persists its propagation identity and removes it with the Anchor fabric" do
    crypto = Matter::Crypto::StandardCrypto.new
    root_key = crypto.create_key_pair
    icac_key = crypto.create_key_pair
    noc_key = crypto.create_key_pair
    fabric_id = 0x1234_u64
    node_id = 0x10_u64
    root = Matter::Crypto::MatterCertificate::Builder.root(root_key, 1_u64, Bytes[1], crypto)
    icac = Matter::Crypto::MatterCertificate::Builder.intermediate(
      icac_key.public_key, fabric_id, 2_u64, root_key, 1_u64, Bytes[2], crypto, anchor: true)
    noc = Matter::Crypto::MatterCertificate::Builder.node(
      noc_key.public_key, fabric_id, node_id, icac_key, 1_u64, Bytes[3], crypto,
      issuer_icac_id: 2_u64, issuer_certificate: icac,
      case_authenticated_tag: 0xFFFE_0001_u32)
    backend = Matter::Storage::Memory.new
    device = InspectableJointFabricAdministratorDevice.new(storage: backend,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    fabric = Matter::Fabric.new(fabric_id, 1_u8, node_id, root_key.public_key, noc, noc_key,
      Bytes.new(16, 1_u8), intermediate_cert: icac, root_cert: root,
      cats: [Matter::DataType::CaseAuthenticatedTag.new(0xFFFE_0001_u32)])

    bootstrap_path = File.join(Dir.tempdir, "matter-jfa-bootstrap-#{Random::Secure.hex(6)}.yml")
    bootstrap_store = Matter::Controller::StateStore.new(Matter::Storage::YamlFile.new(bootstrap_path))
    bootstrap_identity = Matter::Controller::FabricInfo.new(fabric_id, node_id, fabric.ipk,
      root, root_key.public_key, noc, noc_key.private_key,
      root_private_key: root_key.private_key,
      intermediate_cert: icac, intermediate_private_key: icac_key.private_key)
    bootstrap_store.save(Matter::Controller::State.new(fabric: bootstrap_identity))
    bootstrap_store.backend.close

    previous = ENV["MATTER_JFA_PROVISIONED_ANCHOR"]?
    previous_bootstrap = ENV["MATTER_JFA_BOOTSTRAP_STATE_PATH"]?
    previous_bootstrap_datastore = ENV["MATTER_JFA_KEEP_BOOTSTRAP_DATASTORE"]?
    ENV["MATTER_JFA_PROVISIONED_ANCHOR"] = "1"
    ENV["MATTER_JFA_BOOTSTRAP_STATE_PATH"] = bootstrap_path
    ENV["MATTER_JFA_KEEP_BOOTSTRAP_DATASTORE"] = "1"
    wrong_key = crypto.create_key_pair
    wrong_backend = Matter::Storage::Memory.new
    wrong_device = InspectableJointFabricAdministratorDevice.new(storage: wrong_backend,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    wrong_state = MatterJointFabricAdministrator::Device::IcacKeyState.new(wrong_key.private_key, wrong_key.public_key)
    wrong_device.persistence.write_app_document(MatterJointFabricAdministrator::Device::APP_KEY_DOCUMENT, wrong_state.to_document)
    wrong_device.install_test_fabric(fabric)
    wrong_device.advertised_joint_role.should eq(Matter::MDNS::JointFabricRole::Available)
    Matter::Controller::StateStore.new(wrong_backend).load.fabrics.should be_empty

    device.install_test_fabric(fabric)
    expected_role = Matter::MDNS::JointFabricRole::Administrator |
                    Matter::MDNS::JointFabricRole::Anchor |
                    Matter::MDNS::JointFabricRole::Datastore
    device.advertised_joint_role.should eq(expected_role)
    admin_subject = 0xFFFF_FFFD_FFFF_0001_u64
    device.access_control.acl(1_u8).flat_map(&.subjects).should contain(admin_subject)
    admins = device.joint_fabric_datastore.admin_list
    admins.size.should eq(1)
    admins.first.node_id.should eq(node_id)
    admins.first.icac.should eq(icac)
    bootstrap_datastore = device.bootstrap_joint_fabric_datastore
    bootstrap_datastore.joint_fabric_index.should eq(1_u8)
    bootstrap_datastore.admin_list.first.node_id.should eq(node_id)
    bootstrap_datastore.allow_jcm_pase_group_list.should_not be_nil
    bootstrap_datastore.allow_jcm_pase_group_list.as(Proc(Bool)).call.should be_false
    bootstrap_administrator = device.bootstrap_joint_fabric_administrator
    bootstrap_administrator.administrator_fabric_index.should eq(1_u8)
    bootstrap_administrator.service.should be_a(Matter::Commissioning::JointFabricAdministratorService)
    bootstrap_datastore.request_is_case_session = true
    bootstrap_datastore.read_attribute(Matter::Cluster::JointFabricDatastore::ATTR_NODE_LIST, 1_u8)
      .should be_a(TLV::Any)
    bootstrap_datastore.read_attribute(Matter::Cluster::JointFabricDatastore::ATTR_NODE_LIST, 2_u8)
      .as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAccess)
    state_store = Matter::Controller::StateStore.new(backend)
    anchor_identity = state_store.load.fabric_for(fabric_id, root_key.public_key, node_id)
    anchor_identity.controller_noc.should eq(noc)
    anchor_identity.controller_node_id.should eq(node_id)
    anchor_identity.root_private_key.should eq(root_key.private_key)
    anchor_identity.intermediate_private_key.should eq(icac_key.private_key)
    ENV["MATTER_JFA_BOOTSTRAP_STATE_PATH"] = "#{bootstrap_path}.removed"
    device.install_test_fabric(fabric)
    device.access_control.acl(1_u8).count { |entry| entry.subjects.try(&.includes?(admin_subject)) || false }.should eq(1)
    state_store.load.fabric_for(fabric_id, root_key.public_key, node_id).root_private_key
      .should eq(root_key.private_key)
    installed_key = device.persistence.app_document(MatterJointFabricAdministrator::Device::APP_KEY_DOCUMENT)
    MatterJointFabricAdministrator::Device::IcacKeyState.from_document(installed_key.as(Matter::Storage::Document)).private_key.should eq(icac_key.private_key)

    device.joint_fabric_datastore.begin_anchor_transfer.should be_true
    device.advertised_joint_role.should be_nil

    watch = MatterJointFabricAdministrator::Device::TransferWatchState.new(
      0x44_u64, fabric_id, root_key.public_key, nil)
    device.persistence.write_app_document(MatterJointFabricAdministrator::Device::APP_TRANSFER_WATCH_DOCUMENT,
      watch.to_document)
    device.persistence.save_cluster(device.joint_fabric_datastore).should be_true
    device.persistence.flush
    restarted = InspectableJointFabricAdministratorDevice.new(storage: backend,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    restarted.install_test_fabric(fabric)
    administrator = restarted.joint_fabric_administrator
    administrator.request_is_case_session = true
    administrator.request_peer_subject_ids = [0x44_u64, 0xFFFF_FFFD_FFFF_0001_u64]
    administrator.request_peer_node_id = 0x44_u64
    administrator.request_fabric_index = 1_u8
    service = administrator.service.as(Matter::Commissioning::JointFabricAdministratorService)
    frozen_datastore = restarted.joint_fabric_datastore
    frozen_datastore.request_is_case_session = true
    frozen_datastore.read_attribute(Matter::Cluster::JointFabricDatastore::ATTR_ANCHOR_NODE_ID, 1_u8).should be_a(TLV::Any)
    service.transfer_anchor_complete(administrator).should eq(Matter::InteractionModel::Status.success)
    frozen_datastore.read_attribute(Matter::Cluster::JointFabricDatastore::ATTR_ANCHOR_NODE_ID, 1_u8)
      .as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAccess)

    after_transfer = InspectableJointFabricAdministratorDevice.new(storage: backend,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    after_transfer.install_test_fabric(fabric)
    inactive_datastore = after_transfer.joint_fabric_datastore
    inactive_datastore.request_is_case_session = true
    inactive_datastore.read_attribute(Matter::Cluster::JointFabricDatastore::ATTR_ANCHOR_NODE_ID, 1_u8)
      .as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAccess)
    request = Matter::Cluster::JointFabricDatastore::AddPendingNodeRequest.new(0x99_u64, "Rejected")
    inactive_datastore.invoke_command(Matter::Cluster::JointFabricDatastore::CMD_ADD_PENDING_NODE,
      request.to_tlv(nil), is_case_session: true, fabric_index: 1_u8)
      .as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAccess)

    device.stage_fabric_removal_for_spec(1_u8)
    device.bootstrap_joint_fabric_datastore.allow_jcm_pase_group_list.should be_nil
    device.remove_test_fabric(1_u8)
    device.bootstrap_joint_fabric_datastore.joint_fabric_index.should be_nil
    device.bootstrap_joint_fabric_datastore.allow_jcm_pase_group_list.should be_nil
    state_store.load.fabrics.should be_empty
    device.advertised_joint_role.should eq(Matter::MDNS::JointFabricRole::Available)
    device.joint_fabric_datastore.anchor_root_ca.should be_empty
    device.joint_fabric_datastore.status.state.should eq(Matter::Cluster::JointFabricDatastore::DatastoreStateEnum::Pending)
    device.persistence.app_document(MatterJointFabricAdministrator::Device::APP_KEY_DOCUMENT).should be_nil
  ensure
    if previous
      ENV["MATTER_JFA_PROVISIONED_ANCHOR"] = previous
    else
      ENV.delete("MATTER_JFA_PROVISIONED_ANCHOR")
    end
    if previous_bootstrap
      ENV["MATTER_JFA_BOOTSTRAP_STATE_PATH"] = previous_bootstrap
    else
      ENV.delete("MATTER_JFA_BOOTSTRAP_STATE_PATH")
    end
    if previous_bootstrap_datastore
      ENV["MATTER_JFA_KEEP_BOOTSTRAP_DATASTORE"] = previous_bootstrap_datastore
    else
      ENV.delete("MATTER_JFA_KEEP_BOOTSTRAP_DATASTORE")
    end
    File.delete?(bootstrap_path) if bootstrap_path
  end
end
