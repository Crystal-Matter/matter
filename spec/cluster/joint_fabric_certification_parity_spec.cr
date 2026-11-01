require "../spec_helper"
require "../../src/matter/commissioning/joint_fabric_administrator_service"

# Local, executable mirrors of the command sequences in connectedhomeip v1.6:
# TC_JFADMIN_1_1/1_2/1_4 and TC_JFDS_2_1/2_2/2_3/2_4. These exercise
# Crystal's wire command dispatch, while the upstream Python tests remain the
# authority for live discovery, CASE, commissioning and mDNS timing.
private alias JFD = Matter::Cluster::JointFabricDatastore
private alias JFA = Matter::Cluster::JointFabricAdministrator
private alias IMStatus = Matter::InteractionModel::Status
private alias IMCode = Matter::InteractionModel::StatusCode

private def certification_datastore : JFD
  cluster = JFD.new(Matter::DataType::EndpointNumber.new(1_u16))
  cluster.configure_anchor(Bytes[1, 2, 3], 1_u64, 0xFFF1_u16, "Anchor").success?.should be_true
  cluster.add_admin(JFD::AddAdminRequest.new(1_u64, "Anchor", 0xFFF1_u16, Bytes[4, 5])).success?.should be_true
  cluster.seed_reserved_cat_group(1_u16, "Administrator", JFD::ADMINISTRATOR_CAT, 1_u16).success?.should be_true
  cluster.seed_reserved_cat_group(2_u16, "Anchor", JFD::ANCHOR_CAT, 1_u16).success?.should be_true
  cluster.joint_fabric_index = 1_u8
  cluster.access_mode = JFD::AccessMode::Active
  cluster.request_is_case_session = true
  cluster
end

private def certification_invoke(cluster : JFD, command : UInt32, request : T) : IMStatus forall T
  cluster.invoke_command(command, request.to_tlv(nil), is_case_session: true, fabric_index: 1_u8).as(IMStatus)
end

private def certification_key_set(id : UInt16, last_byte : UInt8 = 0x22_u8, start : UInt64 = 2_220_000_u64) : JFD::DatastoreGroupKeySetStruct
  JFD::DatastoreGroupKeySetStruct.new(id, JFD::DatastoreGroupKeySecurityPolicyEnum::TrustFirst,
    Bytes.new(16, 0_u8), start,
    Bytes.new(16, 0x11_u8), start + 1_u64,
    Bytes.new(16, last_byte), start + 2_u64)
end

describe "Matter 1.6 Joint Fabric certification parity" do
  it "mirrors TC_JFDS_2_1 Anchor attributes and TC_JFADMIN_1_1 fabric index" do
    cluster = certification_datastore
    cluster.group_key_set_list.map(&.group_key_set_id).should contain(0_u16)
    cluster.anchor_root_ca.should eq(Bytes[1, 2, 3])
    cluster.anchor_node_id.should eq(1_u64)
    cluster.anchor_vendor_id.should eq(0xFFF1_u16)
    cluster.friendly_name.bytesize.should be <= JFD::MAX_FRIENDLY_NAME_BYTES
    cluster.read_attribute(JFD::ATTR_ANCHOR_ROOT_CA, 1_u8).should be_a(TLV::Any)
    cluster.read_attribute(JFD::ATTR_ANCHOR_NODE_ID, 1_u8).should be_a(TLV::Any)
    cluster.read_attribute(JFD::ATTR_ANCHOR_VENDOR_ID, 1_u8).should be_a(TLV::Any)
    cluster.read_attribute(JFD::ATTR_FRIENDLY_NAME, 1_u8).should be_a(TLV::Any)
    cluster.read_attribute(JFD::ATTR_STATUS, 1_u8).should be_a(TLV::Any)

    administrator = JFA.new(Matter::DataType::EndpointNumber.new(1_u16))
    administrator.administrator_fabric_index.should be_nil
    administrator.administrator_fabric_index = 1_u8
    administrator.administrator_fabric_index.should eq(cluster.joint_fabric_index)
    expect_raises(Matter::ConfigurationError) { administrator.administrator_fabric_index = 0_u8 }
    expect_raises(Matter::ConfigurationError) { administrator.administrator_fabric_index = UInt8::MAX }
  end

  it "mirrors TC_JFDS_2_2 AddKeySet, UpdateKeySet and RemoveKeySet status sequence" do
    cluster = certification_datastore
    original = certification_key_set(10_u16)
    changed = certification_key_set(10_u16, 0x99_u8, 2_220_001_u64)
    certification_invoke(cluster, JFD::CMD_ADD_KEY_SET, JFD::AddKeySetRequest.new(original)).success?.should be_true
    cluster.group_key_set_list.map(&.group_key_set_id).should eq([0_u16, 10_u16])
    cluster.group_key_set_list.last.epoch_key2.should eq(Bytes.new(16, 0x22_u8))
    certification_invoke(cluster, JFD::CMD_ADD_KEY_SET, JFD::AddKeySetRequest.new(changed)).status.should eq(IMCode::ConstraintError)
    certification_invoke(cluster, JFD::CMD_UPDATE_KEY_SET, JFD::UpdateKeySetRequest.new(changed)).success?.should be_true
    cluster.group_key_set_list.last.epoch_key2.should eq(Bytes.new(16, 0x99_u8))
    certification_invoke(cluster, JFD::CMD_UPDATE_KEY_SET, JFD::UpdateKeySetRequest.new(certification_key_set(0x0FFF_u16)))
      .status.should eq(IMCode::NotFound)
    certification_invoke(cluster, JFD::CMD_REMOVE_KEY_SET, JFD::RemoveKeySetRequest.new(0x0FFF_u16)).status.should eq(IMCode::NotFound)
    certification_invoke(cluster, JFD::CMD_REMOVE_KEY_SET, JFD::RemoveKeySetRequest.new(0_u16)).status.should eq(IMCode::ConstraintError)
    certification_invoke(cluster, JFD::CMD_REMOVE_KEY_SET, JFD::RemoveKeySetRequest.new(10_u16)).success?.should be_true
    cluster.group_key_set_list.map(&.group_key_set_id).should eq([0_u16])
    certification_invoke(cluster, JFD::CMD_ADD_KEY_SET, JFD::AddKeySetRequest.new(certification_key_set(0_u16)))
      .status.should eq(IMCode::ConstraintError)
  end

  it "returns ConstraintError for TC_JFDS_2_2 step 6 invalid security policy on the wire" do
    cluster = certification_datastore
    key_set = certification_key_set(10_u16)
    certification_invoke(cluster, JFD::CMD_ADD_KEY_SET, JFD::AddKeySetRequest.new(key_set)).success?.should be_true
    fields = JFD::UpdateKeySetRequest.new(key_set).to_tlv(nil).as_structure
    key_fields = fields[0_u8].as_structure
    key_fields[1_u8] = TLV::Any.new(2_u8, 1_u8)
    fields[0_u8] = TLV::Any.new(key_fields, 0_u8)
    cluster.invoke_command(JFD::CMD_UPDATE_KEY_SET, TLV::Any.new(fields, nil),
      is_case_session: true, fabric_index: 1_u8).as(IMStatus).status.should eq(IMCode::ConstraintError)
    cluster.group_key_set_list.last.group_key_security_policy.should eq(JFD::DatastoreGroupKeySecurityPolicyEnum::TrustFirst)
    cluster.group_key_set_list.last.epoch_key2.should eq(Bytes.new(16, 0x22_u8))
  end

  it "mirrors TC_JFDS_2_3 GroupList mutation and reserved CAT protection" do
    cluster = certification_datastore
    cluster.group_list.map(&.group_cat).should contain(JFD::ADMINISTRATOR_CAT)
    cluster.group_list.map(&.group_cat).should contain(JFD::ANCHOR_CAT)
    view = JFD::DatastoreAccessControlEntryPrivilegeEnum::View
    operate = JFD::DatastoreAccessControlEntryPrivilegeEnum::Operate
    admin = JFD::DatastoreAccessControlEntryPrivilegeEnum::Administer
    certification_invoke(cluster, JFD::CMD_ADD_GROUP,
      JFD::AddGroupRequest.new(10_u16, "tc-jf-2.3", 11_u16, 1_u16, 1_u16, view)).success?.should be_true
    group = cluster.group_list.find(&.group_id.==(10_u64)).as(JFD::DatastoreGroupInformationEntryStruct)
    {group.friendly_name, group.group_key_set_id, group.group_cat, group.group_cat_version, group.group_permission}
      .should eq({"tc-jf-2.3", 11_u16, 1_u16, 1_u16, view})
    certification_invoke(cluster, JFD::CMD_UPDATE_GROUP,
      JFD::UpdateGroupRequest.new(10_u16, "tc-jf-2.3-update", 12_u16, 1_u16, 2_u16, operate)).success?.should be_true
    group = cluster.group_list.find(&.group_id.==(10_u64)).as(JFD::DatastoreGroupInformationEntryStruct)
    {group.friendly_name, group.group_key_set_id, group.group_cat_version, group.group_permission}
      .should eq({"tc-jf-2.3-update", 12_u16, 2_u16, operate})
    certification_invoke(cluster, JFD::CMD_REMOVE_GROUP, JFD::RemoveGroupRequest.new(10_u16)).success?.should be_true
    cluster.group_list.any?(&.group_id.==(10_u64)).should be_false
    {JFD::ADMINISTRATOR_CAT, JFD::ANCHOR_CAT}.each do |cat|
      certification_invoke(cluster, JFD::CMD_ADD_GROUP,
        JFD::AddGroupRequest.new(10_u16, "Reserved", 11_u16, cat, 1_u16, view)).status.should eq(IMCode::ConstraintError)
    end
    {1_u16, 2_u16}.each do |group_id|
      certification_invoke(cluster, JFD::CMD_UPDATE_GROUP,
        JFD::UpdateGroupRequest.new(group_id, "Changed", 12_u16, 3_u16, 2_u16, admin)).status.should eq(IMCode::ConstraintError)
      certification_invoke(cluster, JFD::CMD_REMOVE_GROUP, JFD::RemoveGroupRequest.new(group_id)).status.should eq(IMCode::ConstraintError)
    end
  end

  it "mirrors TC_JFDS_2_4 AdminList add, update, duplicate and remove" do
    cluster = certification_datastore
    cluster.admin_list.map(&.node_id).should contain(1_u64)
    certification_invoke(cluster, JFD::CMD_ADD_ADMIN,
      JFD::AddAdminRequest.new(10_u64, "tc-jf-2.4", 12_u16, Bytes[1, 2, 3])).success?.should be_true
    entry = cluster.admin_list.find(&.node_id.==(10_u64)).as(JFD::DatastoreAdministratorInformationEntryStruct)
    {entry.friendly_name, entry.vendor_id, entry.icac}.should eq({"tc-jf-2.4", 12_u16, Bytes[1, 2, 3]})
    certification_invoke(cluster, JFD::CMD_UPDATE_ADMIN,
      JFD::UpdateAdminRequest.new(10_u64, "tc-jf-2.4-update", Bytes[3, 2, 1])).success?.should be_true
    entry = cluster.admin_list.find(&.node_id.==(10_u64)).as(JFD::DatastoreAdministratorInformationEntryStruct)
    {entry.friendly_name, entry.icac}.should eq({"tc-jf-2.4-update", Bytes[3, 2, 1]})
    certification_invoke(cluster, JFD::CMD_ADD_ADMIN,
      JFD::AddAdminRequest.new(10_u64, "Duplicate", 12_u16, Bytes[1])).status.should eq(IMCode::ConstraintError)
    certification_invoke(cluster, JFD::CMD_REMOVE_ADMIN, JFD::RemoveAdminRequest.new(10_u64)).success?.should be_true
    cluster.admin_list.map(&.node_id).should eq([1_u64])
  end

  it "mirrors TC_JFADMIN_1_2 fail-safe and unverified VID statuses" do
    crypto = Matter::Crypto::StandardCrypto.new
    root_key = crypto.create_key_pair
    icac_key = crypto.create_key_pair
    root = Matter::Crypto::MatterCertificate::Builder.root(root_key, 1_u64, Bytes[1], crypto)
    fabric_id = 0x1234_u64
    armed = false
    service = Matter::Commissioning::JointFabricAdministratorService.new(
      icac_key, root, fabric_id,
      -> { armed }, ->(_index : UInt8) { false },
      ->(_request : JFA::OpenJointCommissioningWindowRequest) { IMStatus.success },
      ->(_node : UInt64) { true }, -> { false }, -> { nil }, -> { nil }, crypto)
    administrator = JFA.new(Matter::DataType::EndpointNumber.new(1_u16))
    administrator.request_is_case_session = true
    administrator.request_fabric_index = 1_u8
    administrator.request_peer_subject_ids = [7_u64]
    service.icaccsr_request(administrator).should eq(IMStatus.failsafe_required)
    armed = true
    service.icaccsr_request(administrator).should eq(IMStatus.cluster_failure(JFA::ICACCSRResponseStatusCodeEnum::VIDNotVerified))
    certificate = Matter::Crypto::MatterCertificate::Builder.intermediate(
      icac_key.public_key, fabric_id, 2_u64, root_key, 1_u64, Bytes[2], crypto)
    service.add_icac(administrator, JFA::AddICACRequest.new(certificate)).as(JFA::ICACResponse).status_code
      .should eq(JFA::ICACResponseStatusEnum::InvalidPublicKey)
    service.icaccsr_request(administrator).should eq(IMStatus.constraint_error)
    armed = false
    service.on_failsafe_expired
    service.add_icac(administrator, JFA::AddICACRequest.new(certificate)).should eq(IMStatus.failsafe_required)
  end

  it "mirrors TC_JFADMIN_1_4 commissioning window parameter boundaries and Busy" do
    crypto = Matter::Crypto::StandardCrypto.new
    root_key = crypto.create_key_pair
    icac_key = crypto.create_key_pair
    root = Matter::Crypto::MatterCertificate::Builder.root(root_key, 1_u64, Bytes[1], crypto)
    opened = 0
    busy = false
    service = Matter::Commissioning::JointFabricAdministratorService.new(
      icac_key, root, 0x1234_u64,
      -> { false }, ->(_index : UInt8) { true },
      ->(_request : JFA::OpenJointCommissioningWindowRequest) {
        opened += 1 unless busy
        busy ? IMStatus.busy : IMStatus.success
      },
      ->(_node : UInt64) { true }, -> { false }, -> { nil }, -> { nil }, crypto)
    administrator = JFA.new(Matter::DataType::EndpointNumber.new(1_u16))
    administrator.request_is_case_session = true
    administrator.request_peer_subject_ids = [0xFFFF_FFFD_FFFF_0001_u64]
    valid = JFA::OpenJointCommissioningWindowRequest.new(
      400_u16, Bytes.new(97, 0_u8), 3839_u16, 1000_u32, Bytes.new(16, 0_u8))
    administrator.request_peer_subject_ids = [0x1234_u64]
    service.open_joint_commissioning_window(administrator, valid).should eq(
      IMStatus.cluster_failure(JFA::ICACCSRResponseStatusCodeEnum::InvalidAdministratorFabricIndex))
    administrator.request_peer_subject_ids = [0xFFFF_FFFD_FFFF_0001_u64]
    service.open_joint_commissioning_window(administrator, valid).should eq(
      IMStatus.cluster_failure(JFA::ICACCSRResponseStatusCodeEnum::InvalidAdministratorFabricIndex))
    administrator.administrator_fabric_index = 1_u8
    administrator.request_fabric_index = 1_u8
    administrator.request_peer_subject_ids = [0x1234_u64]
    service.open_joint_commissioning_window(administrator, valid).should eq(IMStatus.unsupported_access)
    administrator.request_peer_subject_ids = [0xFFFF_FFFD_FFFF_0001_u64]
    invalid = [
      JFA::OpenJointCommissioningWindowRequest.new(0_u16, valid.pake_passcode_verifier, valid.discriminator, valid.iterations, valid.salt),
      JFA::OpenJointCommissioningWindowRequest.new(UInt16::MAX, valid.pake_passcode_verifier, valid.discriminator, valid.iterations, valid.salt),
      JFA::OpenJointCommissioningWindowRequest.new(400_u16, Bytes.new(96, 0_u8), valid.discriminator, valid.iterations, valid.salt),
      JFA::OpenJointCommissioningWindowRequest.new(400_u16, Bytes.new(98, 0_u8), valid.discriminator, valid.iterations, valid.salt),
      JFA::OpenJointCommissioningWindowRequest.new(400_u16, valid.pake_passcode_verifier, 4096_u16, valid.iterations, valid.salt),
      JFA::OpenJointCommissioningWindowRequest.new(400_u16, valid.pake_passcode_verifier, valid.discriminator, 999_u32, valid.salt),
      JFA::OpenJointCommissioningWindowRequest.new(400_u16, valid.pake_passcode_verifier, valid.discriminator, 100_001_u32, valid.salt),
      JFA::OpenJointCommissioningWindowRequest.new(400_u16, valid.pake_passcode_verifier, valid.discriminator, valid.iterations, Bytes.new(15, 0_u8)),
      JFA::OpenJointCommissioningWindowRequest.new(400_u16, valid.pake_passcode_verifier, valid.discriminator, valid.iterations, Bytes.new(33, 0_u8)),
    ]
    invalid.each { |request| service.open_joint_commissioning_window(administrator, request).should eq(IMStatus.invalid_command) }
    opened.should eq(0)
    service.open_joint_commissioning_window(administrator, valid).should eq(IMStatus.unsupported_access)
    administrator.jcm_add_noc_guard_ready = -> { true }
    {16, 24, 32}.each do |size|
      request = JFA::OpenJointCommissioningWindowRequest.new(400_u16, valid.pake_passcode_verifier,
        valid.discriminator, 50_000_u32, Bytes.new(size, 0_u8))
      service.open_joint_commissioning_window(administrator, request).should eq(IMStatus.success)
    end
    opened.should eq(3)
    busy = true
    service.open_joint_commissioning_window(administrator, valid).should eq(
      IMStatus.cluster_failure(JFA::ICACCSRResponseStatusCodeEnum::Busy))
  end
end
