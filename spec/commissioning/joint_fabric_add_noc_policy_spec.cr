require "../spec_helper"
require "../../src/matter/commissioning/joint_fabric_add_noc_policy"
require "../../src/matter/commissioning/joint_fabric_add_noc_guard"
require "../../src/matter/controller/certificate_util"

private def jcm_subject(identity : UInt16, version : UInt16) : UInt64
  Matter::DataType::NodeId.from_case_authenticated_tag(
    Matter::DataType::CaseAuthenticatedTag.create(identity, version)).id
end

private def jcm_datastore(admin_version : UInt16 = 2_u16,
                          anchor_version : UInt16 = 3_u16,
                          endpoint_id : UInt16 = 1_u16) : Matter::Cluster::JointFabricDatastore
  store = Matter::Cluster::JointFabricDatastore.new(Matter::DataType::EndpointNumber.new(endpoint_id))
  store.seed_reserved_cat_group(1_u16, "Administrators",
    Matter::Cluster::JointFabricDatastore::ADMINISTRATOR_CAT, admin_version).success?.should be_true
  store.seed_reserved_cat_group(2_u16, "Anchors",
    Matter::Cluster::JointFabricDatastore::ANCHOR_CAT, anchor_version).success?.should be_true
  store
end

private def jcm_add_noc_service(datastore : Matter::Cluster::JointFabricDatastore,
                                joint_session : UInt64?) : {Matter::Commissioning::CredentialService, Bytes}
  target = RecordingCredentialTarget.new
  table = Matter::FabricTable.new(Matter::Storage::Memory.new)
  service = Matter::Commissioning::CredentialService.new(target, table)
  service.on_validate_add_noc = ->(noc : Bytes, subject : UInt64, session_id : UInt64) {
    session_id == joint_session ? Matter::Commissioning::JointFabricAddNocPolicy.validate(noc, subject, datastore) : nil
  }
  elements, _signature = service.create_csr(Bytes.new(32, 0x42_u8), 42_u64, false, true).as(Tuple(Bytes, Bytes))
  service.add_trusted_root_certificate(CommissioningCertificates.root_certificate)
  csr = Matter::Commissioning::CredentialService::CSRElements.from_slice(elements).csr
  key = Matter::Controller::CertificateUtil.extract_uncompressed_public_key_from_csr(csr)
  {service, key}
end

private def jcm_noc(public_key : Bytes, administrator_cat : UInt32?) : Bytes
  authority = TestCertificateAuthority.default
  cats = administrator_cat ? [administrator_cat] : [] of UInt32
  Matter::Crypto::MatterCertificate::Builder.node(
    public_key: public_key,
    fabric_id: TestCertificateAuthority::DEFAULT_FABRIC_ID,
    node_id: TestCertificateAuthority::DEFAULT_NODE_ID,
    issuer_key: authority.key,
    issuer_rcac_id: TestCertificateAuthority::ROOT_CERTIFICATE_ID,
    serial: Bytes[1, 2, 3, 4, 5, 6, 7, 8],
    crypto: Matter::Crypto::StandardCrypto.new,
    case_authenticated_tags: cats)
end

describe Matter::Commissioning::JointFabricAddNocPolicy do
  admin_id = Matter::Cluster::JointFabricDatastore::ADMINISTRATOR_CAT
  anchor_id = Matter::Cluster::JointFabricDatastore::ANCHOR_CAT
  admin_cat = Matter::DataType::CaseAuthenticatedTag.create(admin_id, 2_u16).value
  anchor_subject = jcm_subject(anchor_id, 3_u16)

  it "rejects an AddNOC without the Datastore's Administrator CAT before fabric mutation" do
    service, key = jcm_add_noc_service(jcm_datastore, 42_u64)
    outcome = service.add_noc(jcm_noc(key, nil), nil, Bytes.new(16, 0_u8),
      anchor_subject, 0xFFF1_u16, 42_u64)
    outcome.status.should eq(Matter::Commissioning::NocStatus::InvalidNoc)
    service.fabric_table.size.should eq(0)
    service.pending.noc_added_or_updated?.should be_false
    service.fabric_table.backend.read(Matter::Commissioning::CredentialJournal::COLLECTION,
      Matter::Commissioning::CredentialJournal::ID).should be_nil
  end

  it "rejects an AddNOC without the Datastore's Anchor CAT CaseAdminSubject" do
    service, key = jcm_add_noc_service(jcm_datastore, 42_u64)
    outcome = service.add_noc(jcm_noc(key, admin_cat), nil, Bytes.new(16, 0_u8),
      TestCertificateAuthority::DEFAULT_NODE_ID, 0xFFF1_u16, 42_u64)
    outcome.status.should eq(Matter::Commissioning::NocStatus::InvalidAdminSubject)
    service.fabric_table.size.should eq(0)
    service.pending.noc_added_or_updated?.should be_false
    service.fabric_table.backend.read(Matter::Commissioning::CredentialJournal::COLLECTION,
      Matter::Commissioning::CredentialJournal::ID).should be_nil
  end

  it "rejects stale CAT versions even when the reserved CAT identities match" do
    stale_admin = Matter::DataType::CaseAuthenticatedTag.create(admin_id, 1_u16).value
    service, key = jcm_add_noc_service(jcm_datastore, 42_u64)
    service.add_noc(jcm_noc(key, stale_admin), nil, Bytes.new(16, 0_u8),
      anchor_subject, 0xFFF1_u16, 42_u64).status
      .should eq(Matter::Commissioning::NocStatus::InvalidNoc)
    service.fabric_table.size.should eq(0)

    stale_anchor_subject = jcm_subject(anchor_id, 2_u16)
    another, another_key = jcm_add_noc_service(jcm_datastore, 42_u64)
    another.add_noc(jcm_noc(another_key, admin_cat), nil, Bytes.new(16, 0_u8),
      stale_anchor_subject, 0xFFF1_u16, 42_u64).status
      .should eq(Matter::Commissioning::NocStatus::InvalidAdminSubject)
    another.fabric_table.size.should eq(0)
  end

  it "accepts the current JCM CAT pair and preserves ordinary AddNOC on a non-JCM session" do
    service, key = jcm_add_noc_service(jcm_datastore, 42_u64)
    service.add_noc(jcm_noc(key, admin_cat), nil, Bytes.new(16, 0_u8),
      anchor_subject, 0xFFF1_u16, 42_u64).status.should eq(Matter::Commissioning::NocStatus::Ok)

    ordinary, ordinary_key = jcm_add_noc_service(jcm_datastore, nil)
    ordinary.add_noc(jcm_noc(ordinary_key, nil), nil, Bytes.new(16, 0_u8),
      TestCertificateAuthority::DEFAULT_NODE_ID, 0xFFF1_u16, 42_u64).status
      .should eq(Matter::Commissioning::NocStatus::Ok)
  end
end

describe Matter::Commissioning::JointFabricAddNocGuard do
  it "binds multiple JFA endpoints to their own Datastore and tracks the selected JCM session" do
    admin_a = Matter::Cluster::JointFabricAdministrator.new(Matter::DataType::EndpointNumber.new(1_u16))
    admin_b = Matter::Cluster::JointFabricAdministrator.new(Matter::DataType::EndpointNumber.new(2_u16))
    admin_a.administrator_fabric_index = 1_u8
    admin_b.administrator_fabric_index = 2_u8
    store_a = jcm_datastore(4_u16, 5_u16)
    store_b = jcm_datastore(2_u16, 3_u16, 2_u16)
    store_a.joint_fabric_index = 1_u8
    store_b.joint_fabric_index = 2_u8
    store_a.access_mode = Matter::Cluster::JointFabricDatastore::AccessMode::Active
    store_b.access_mode = Matter::Cluster::JointFabricDatastore::AccessMode::Active
    service, key = jcm_add_noc_service(store_b, nil)
    guard = Matter::Commissioning::JointFabricAddNocGuard.new(service,
      -> { [admin_a, admin_b] },
      ->(endpoint : UInt16) { endpoint == 1_u16 ? store_a : endpoint == 2_u16 ? store_b : nil })
    guard.install!
    admin_a.jcm_add_noc_guard_ready?.should be_true
    admin_b.jcm_add_noc_guard_ready?.should be_true
    guard.observe_failsafe_arm(42_u64, 2_u8, joint_window: true, case_session: false)

    service.add_noc(jcm_noc(key, nil), nil, Bytes.new(16, 0_u8),
      jcm_subject(Matter::Cluster::JointFabricDatastore::ANCHOR_CAT, 3_u16),
      0xFFF1_u16, 42_u64).status.should eq(Matter::Commissioning::NocStatus::InvalidNoc)
    service.fabric_table.size.should eq(0)

    stale_admin = Matter::DataType::CaseAuthenticatedTag.create(
      Matter::Cluster::JointFabricDatastore::ADMINISTRATOR_CAT, 1_u16).value
    service.add_noc(jcm_noc(key, stale_admin), nil, Bytes.new(16, 0_u8),
      jcm_subject(Matter::Cluster::JointFabricDatastore::ANCHOR_CAT, 3_u16),
      0xFFF1_u16, 42_u64).status.should eq(Matter::Commissioning::NocStatus::InvalidNoc)
    service.fabric_table.size.should eq(0)

    guard.reset
    service.add_noc(jcm_noc(key, nil), nil, Bytes.new(16, 0_u8),
      TestCertificateAuthority::DEFAULT_NODE_ID, 0xFFF1_u16, 42_u64).status
      .should eq(Matter::Commissioning::NocStatus::Ok)
  end

  it "fails closed for an unpaired or ambiguous JFA endpoint" do
    admin = Matter::Cluster::JointFabricAdministrator.new(Matter::DataType::EndpointNumber.new(1_u16))
    admin.administrator_fabric_index = 1_u8
    service, key = jcm_add_noc_service(jcm_datastore, nil)
    guard = Matter::Commissioning::JointFabricAddNocGuard.new(service,
      -> { [admin] }, ->(_endpoint : UInt16) { nil.as(Matter::Cluster::JointFabricDatastore?) })
    guard.install!
    admin.jcm_add_noc_guard_ready?.should be_false
    guard.observe_failsafe_arm(42_u64, 1_u8, joint_window: true, case_session: false)
    service.add_noc(jcm_noc(key, nil), nil, Bytes.new(16, 0_u8),
      TestCertificateAuthority::DEFAULT_NODE_ID, 0xFFF1_u16, 42_u64).status
      .should eq(Matter::Commissioning::NocStatus::InvalidNoc)
    service.fabric_table.size.should eq(0)
  end
end
