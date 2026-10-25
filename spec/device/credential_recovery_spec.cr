require "../support/operational_credentials_helpers"
require "../../src/matter/device"
require "../../src/matter/cluster/on_off"
require "../../src/matter/cluster/identify"
require "../../src/matter/cluster/groups"
require "../../src/matter/cluster/scenes_management"

private class CredentialRecoveryDevice < Matter::Device
  def initialize(path : String, tc_min_required_version : UInt16? = nil,
                 tc_required_acknowledgements : UInt16 = 0_u16)
    super(Matter::Storage::YamlFile.new(path), port: 0,
      tc_min_required_version: tc_min_required_version,
      tc_required_acknowledgements: tc_required_acknowledgements)
  end

  def initialize(storage : Matter::Storage::Backend, tc_min_required_version : UInt16? = nil,
                 tc_required_acknowledgements : UInt16 = 0_u16)
    super(storage, port: 0,
      tc_min_required_version: tc_min_required_version,
      tc_required_acknowledgements: tc_required_acknowledgements)
  end

  def device_name : String
    "Credential recovery"
  end

  def vendor_id : UInt16
    0xFFF1_u16
  end

  def product_id : UInt16
    0x8000_u16
  end

  def discriminator : UInt16
    3840_u16
  end

  def setup_pin : UInt32
    20202021_u32
  end

  def primary_device_type_id : UInt32
    Matter::DeviceType::ON_OFF_LIGHT
  end

  protected def device_clusters : Array(Matter::Cluster::Base)
    light = endpoint(1_u16)
    [Matter::Cluster::OnOff.new(light, feature_map: Matter::Cluster::OnOff::Feature::Lighting),
     Matter::Cluster::Identify.new(light), Matter::Cluster::Groups.new(light),
     Matter::Cluster::ScenesManagement.new(light)] of Matter::Cluster::Base
  end

  protected def endpoint_device_types : Hash(UInt16, UInt32)
    {1_u16 => Matter::DeviceType::ON_OFF_LIGHT}
  end
end

private class FailCredentialYamlFile < Matter::Storage::YamlFile
  property? fail_next_cluster_write : Bool = false
  property fail_next_cluster_id : String?
  property? fail_next_journal_delete : Bool = false
  property? fail_next_fabric_write : Bool = false
  property? fail_next_flush : Bool = false

  protected def flush : Nil
    if @fail_next_flush
      @fail_next_flush = false
      raise Matter::StorageError.new("Injected file flush failure")
    end
    super
  end

  def write(collection : String, id : String, document : Matter::Storage::Document) : Nil
    if collection == Matter::Storage::Collections::CLUSTERS && id == @fail_next_cluster_id
      @fail_next_cluster_id = nil
      raise Matter::StorageError.new("Injected targeted cluster write failure")
    end
    if @fail_next_fabric_write && collection == Matter::Storage::Collections::FABRICS
      @fail_next_fabric_write = false
      raise Matter::StorageError.new("Injected fabric write failure")
    end
    if @fail_next_cluster_write && collection == Matter::Storage::Collections::CLUSTERS
      @fail_next_cluster_write = false
      raise Matter::StorageError.new("Injected ACL write failure")
    end
    super
  end

  def delete(collection : String, id : String) : Nil
    if @fail_next_journal_delete && collection == Matter::Storage::Collections::DEVICE &&
       id == Matter::Commissioning::CredentialJournal::ID
      @fail_next_journal_delete = false
      raise Matter::StorageError.new("Injected credential journal delete failure")
    end
    super
  end
end

private def add_recovery_fabric(device : CredentialRecoveryDevice,
                                fabric_id : UInt64 = 0x1111_u64,
                                node_id : UInt64 = 0x2222_u64,
                                admin : UInt64 = 0x3333_u64) : UInt8
  device.general_commissioning.arm_failsafe(
    Matter::Cluster::GeneralCommissioning::ArmFailSafeRequest.new(60_u16, 1_u64), nil, true
  ).error_code.ok?.should be_true
  service = device.operational_credentials.credentials
  service.failsafe_armed = true
  csr = service.create_csr(Bytes.new(32, 0x42_u8), 42_u64, false, true).as(Tuple(Bytes, Bytes))[0]
  elements = Matter::Commissioning::CredentialService::CSRElements.from_slice(csr)
  key = Matter::Controller::CertificateUtil.extract_uncompressed_public_key_from_csr(elements.csr)
  service.add_trusted_root_certificate(TestCertificateAuthority.default.root_certificate).ok?.should be_true
  noc = TestCertificateAuthority.default.issue(fabric_id, node_id, key)
  outcome = service.add_noc(noc, nil, Bytes.new(16), admin, 0xFFF1_u16, 42_u64)
  outcome.ok?.should be_true
  outcome.fabric_index.as(UInt8)
end

private def update_recovery_fabric(device : CredentialRecoveryDevice, index : UInt8) : Nil
  device.general_commissioning.arm_failsafe(
    Matter::Cluster::GeneralCommissioning::ArmFailSafeRequest.new(60_u16, 2_u64), index, false
  ).error_code.ok?.should be_true
  service = device.operational_credentials.credentials
  service.failsafe_armed = true
  csr = service.create_csr(Bytes.new(32, 0x43_u8), 43_u64, true, false).as(Tuple(Bytes, Bytes))[0]
  elements = Matter::Commissioning::CredentialService::CSRElements.from_slice(csr)
  key = Matter::Controller::CertificateUtil.extract_uncompressed_public_key_from_csr(elements.csr)
  noc = TestCertificateAuthority.default.issue(0x1111_u64, 0x7777_u64, key)
  service.update_noc(noc, nil, index, 43_u64).ok?.should be_true
end

describe "durable fail-safe credential recovery" do
  it "restores direct Terms and Conditions state after a failed file flush" do
    path = File.join(Dir.tempdir, "matter-credential-recovery-#{Random::Secure.hex(6)}.yml")
    begin
      backend = FailCredentialYamlFile.new(path)
      first = CredentialRecoveryDevice.new(backend,
        tc_min_required_version: 2_u16, tc_required_acknowledgements: 0b0110_u16)
      committed_before = first.general_commissioning.save_state
      backend.fail_next_flush = true

      expect_raises(Matter::StorageError, "Injected file flush failure") do
        first.general_commissioning.set_tc_acknowledgements(
          Matter::Cluster::GeneralCommissioning::SetTCAcknowledgementsRequest.new(2_u16, 0b0110_u16))
      end
      first.general_commissioning.save_state.should eq(committed_before)
      backend.read(Matter::Storage::Collections::CLUSTERS,
        first.general_commissioning.persistence_key).should be_nil
      backend.close

      restarted = CredentialRecoveryDevice.new(path,
        tc_min_required_version: 2_u16, tc_required_acknowledgements: 0b0110_u16)
      restarted.general_commissioning.tc_accepted_version.should eq(0_u16)
      restarted.shutdown!
    ensure
      File.delete?(path)
    end
  end

  it "keeps provisional credentials and Terms and Conditions when the combined file flush fails" do
    path = File.join(Dir.tempdir, "matter-credential-recovery-#{Random::Secure.hex(6)}.yml")
    begin
      backend = FailCredentialYamlFile.new(path)
      first = CredentialRecoveryDevice.new(backend,
        tc_min_required_version: 2_u16, tc_required_acknowledgements: 0b0110_u16)
      index = add_recovery_fabric(first)
      first.general_commissioning.set_tc_acknowledgements(
        Matter::Cluster::GeneralCommissioning::SetTCAcknowledgementsRequest.new(2_u16, 0b0110_u16)
      ).error_code.ok?.should be_true
      committed_before = first.general_commissioning.save_state
      journal_before = backend.read(Matter::Storage::Collections::DEVICE,
        Matter::Commissioning::CredentialJournal::ID)
      journal_before.should_not be_nil
      backend.fail_next_flush = true

      expect_raises(Matter::StorageError, "Injected file flush failure") do
        first.general_commissioning.commissioning_complete(index, true)
      end
      first.general_commissioning.failsafe_armed?.should be_true
      first.general_commissioning.save_state.should eq(committed_before)
      backend.read(Matter::Storage::Collections::DEVICE,
        Matter::Commissioning::CredentialJournal::ID).should eq(journal_before)
      backend.close

      restarted = CredentialRecoveryDevice.new(path,
        tc_min_required_version: 2_u16, tc_required_acknowledgements: 0b0110_u16)
      restarted.fabric_table.get_fabric(index).should be_nil
      restarted.general_commissioning.tc_accepted_version.should eq(0_u16)
      restarted.shutdown!
    ensure
      File.delete?(path)
    end
  end

  it "does not acknowledge direct Terms and Conditions acceptance if its save fails" do
    path = File.join(Dir.tempdir, "matter-credential-recovery-#{Random::Secure.hex(6)}.yml")
    begin
      backend = FailCredentialYamlFile.new(path)
      first = CredentialRecoveryDevice.new(backend,
        tc_min_required_version: 2_u16, tc_required_acknowledgements: 0b0110_u16)
      backend.fail_next_cluster_write = true
      expect_raises(Matter::StorageError) do
        first.general_commissioning.set_tc_acknowledgements(
          Matter::Cluster::GeneralCommissioning::SetTCAcknowledgementsRequest.new(2_u16, 0b0110_u16))
      end
      first.general_commissioning.tc_accepted_version.should eq(0_u16)
      backend.close

      restarted = CredentialRecoveryDevice.new(path,
        tc_min_required_version: 2_u16, tc_required_acknowledgements: 0b0110_u16)
      restarted.general_commissioning.tc_accepted_version.should eq(0_u16)
      restarted.shutdown!
    ensure
      File.delete?(path)
    end
  end

  it "retains Terms and Conditions acknowledged outside a fail-safe after a crash" do
    path = File.join(Dir.tempdir, "matter-credential-recovery-#{Random::Secure.hex(6)}.yml")
    begin
      first = CredentialRecoveryDevice.new(path,
        tc_min_required_version: 2_u16, tc_required_acknowledgements: 0b0110_u16)
      first.general_commissioning.set_tc_acknowledgements(
        Matter::Cluster::GeneralCommissioning::SetTCAcknowledgementsRequest.new(2_u16, 0b0110_u16)
      ).error_code.ok?.should be_true
      first.persistence.backend.close

      restarted = CredentialRecoveryDevice.new(path,
        tc_min_required_version: 2_u16, tc_required_acknowledgements: 0b0110_u16)
      restarted.general_commissioning.tc_accepted_version.should eq(2_u16)
      restarted.general_commissioning.tc_acknowledgements.should eq(0b0110_u16)
      restarted.shutdown!
    ensure
      File.delete?(path)
    end
  end

  it "retains accepted Terms and Conditions after an acknowledged commissioning crash" do
    path = File.join(Dir.tempdir, "matter-credential-recovery-#{Random::Secure.hex(6)}.yml")
    begin
      first = CredentialRecoveryDevice.new(path,
        tc_min_required_version: 2_u16, tc_required_acknowledgements: 0b0110_u16)
      index = add_recovery_fabric(first)
      first.general_commissioning.set_tc_acknowledgements(
        Matter::Cluster::GeneralCommissioning::SetTCAcknowledgementsRequest.new(2_u16, 0b0110_u16)
      ).error_code.ok?.should be_true
      first.general_commissioning.commissioning_complete(index, true).error_code.ok?.should be_true

      # Closing only the backend models process loss: Device#shutdown! would
      # flush the debounced cluster writer and conceal the durability gap.
      first.persistence.backend.close

      restarted = CredentialRecoveryDevice.new(path,
        tc_min_required_version: 2_u16, tc_required_acknowledgements: 0b0110_u16)
      restarted.fabric_table.get_fabric(index).should_not be_nil
      restarted.general_commissioning.tc_accepted_version.should eq(2_u16)
      restarted.general_commissioning.tc_acknowledgements.should eq(0b0110_u16)
      restarted.general_commissioning.tc_acknowledgements_required?.should be_false
      restarted.shutdown!
    ensure
      File.delete?(path)
    end
  end

  it "retains an undo record when AddNOC's fabric write fails after journal flush" do
    path = File.join(Dir.tempdir, "matter-credential-recovery-#{Random::Secure.hex(6)}.yml")
    begin
      backend = FailCredentialYamlFile.new(path)
      first = CredentialRecoveryDevice.new(backend)
      backend.fail_next_fabric_write = true
      expect_raises(Matter::StorageError) { add_recovery_fabric(first) }
      backend.read(Matter::Storage::Collections::DEVICE,
        Matter::Commissioning::CredentialJournal::ID).should_not be_nil
      backend.read(Matter::Storage::Collections::FABRICS, "1").should be_nil
      first.fabric_table.should be_empty
      first.operational_credentials.on_failsafe_expired
      backend.read(Matter::Storage::Collections::DEVICE,
        Matter::Commissioning::CredentialJournal::ID).should be_nil
      first.fabric_table.should be_empty
      backend.close

      restarted = CredentialRecoveryDevice.new(path)
      restarted.fabric_table.should be_empty
      restarted.access_control.acl.should be_empty
      restarted.shutdown!
    ensure
      File.delete?(path)
    end
  end

  it "recovers a journal written before AddNOC changes the fabric table" do
    path = File.join(Dir.tempdir, "matter-credential-recovery-#{Random::Secure.hex(6)}.yml")
    begin
      first = CredentialRecoveryDevice.new(path)
      Matter::Commissioning::CredentialJournal.begin_add(first.persistence.backend, 1_u8)
      first.shutdown!

      restarted = CredentialRecoveryDevice.new(path)
      restarted.fabric_table.should be_empty
      restarted.access_control.acl.should be_empty
      restarted.persistence.backend.read(Matter::Storage::Collections::DEVICE,
        Matter::Commissioning::CredentialJournal::ID).should be_nil
      restarted.shutdown!
    ensure
      File.delete?(path)
    end
  end

  it "removes a provisional AddNOC fabric and its ACL after a file-backed restart" do
    path = File.join(Dir.tempdir, "matter-credential-recovery-#{Random::Secure.hex(6)}.yml")
    begin
      first = CredentialRecoveryDevice.new(path)
      index = add_recovery_fabric(first)
      first.access_control.acl(index).size.should eq(1)
      first.persistence.save_cluster(first.access_control).should be_true
      first.shutdown!

      restarted = CredentialRecoveryDevice.new(path)
      restarted.fabric_table.get_fabric(index).should be_nil
      restarted.access_control.acl(index).should be_empty
      restarted.shutdown!
    ensure
      File.delete?(path)
    end
  end

  it "keeps an unrelated commissioned fabric and its ACL while removing a provisional one" do
    path = File.join(Dir.tempdir, "matter-credential-recovery-#{Random::Secure.hex(6)}.yml")
    begin
      first = CredentialRecoveryDevice.new(path)
      committed = add_recovery_fabric(first)
      first.general_commissioning.commissioning_complete(committed, true).error_code.ok?.should be_true
      provisional = add_recovery_fabric(first, 0x1112_u64, 0x2223_u64, 0x3334_u64)
      first.persistence.save_cluster(first.access_control).should be_true
      first.shutdown!

      restarted = CredentialRecoveryDevice.new(path)
      restarted.fabric_table.get_fabric(committed).should_not be_nil
      restarted.access_control.acl(committed).size.should eq(1)
      restarted.fabric_table.get_fabric(provisional).should be_nil
      restarted.access_control.acl(provisional).should be_empty
      restarted.shutdown!
    ensure
      File.delete?(path)
    end
  end

  it "keeps the undo journal if fail-safe rollback cannot durably remove the ACL" do
    path = File.join(Dir.tempdir, "matter-credential-recovery-#{Random::Secure.hex(6)}.yml")
    begin
      backend = FailCredentialYamlFile.new(path)
      first = CredentialRecoveryDevice.new(backend)
      index = add_recovery_fabric(first)
      backend.fail_next_cluster_write = true
      expect_raises(Matter::StorageError) { first.operational_credentials.on_failsafe_expired }
      backend.read(Matter::Storage::Collections::DEVICE,
        Matter::Commissioning::CredentialJournal::ID).should_not be_nil
      # Close the storage handle without flushing the device's dirty ACL.
      # This models a process loss at the failed write boundary.
      backend.close

      restarted = CredentialRecoveryDevice.new(path)
      restarted.fabric_table.get_fabric(index).should be_nil
      restarted.access_control.acl(index).should be_empty
      restarted.shutdown!
    ensure
      File.delete?(path)
    end
  end

  it "prunes an orphan ACL after a normal RemoveFabric ACL write failure" do
    path = File.join(Dir.tempdir, "matter-credential-recovery-#{Random::Secure.hex(6)}.yml")
    begin
      backend = FailCredentialYamlFile.new(path)
      first = CredentialRecoveryDevice.new(backend)
      index = add_recovery_fabric(first)
      first.general_commissioning.commissioning_complete(index, true).error_code.ok?.should be_true
      backend.fail_next_cluster_id = first.access_control.persistence_key
      expect_raises(Matter::StorageError) do
        first.operational_credentials.credentials.remove_fabric(index)
      end
      backend.close

      restarted = CredentialRecoveryDevice.new(path)
      restarted.fabric_table.get_fabric(index).should be_nil
      restarted.access_control.acl(index).should be_empty
      restarted.shutdown!
    ensure
      File.delete?(path)
    end
  end

  it "does not restore removed group credentials or names after an ACL write failure and restart" do
    path = File.join(Dir.tempdir, "matter-credential-recovery-#{Random::Secure.hex(6)}.yml")
    begin
      backend = FailCredentialYamlFile.new(path)
      first = CredentialRecoveryDevice.new(backend)
      index = add_recovery_fabric(first)
      first.general_commissioning.commissioning_complete(index, true).error_code.ok?.should be_true
      key_management = first.message_handler.node.get_cluster!(Matter::Cluster::GroupKeyManagement)
      groups = first.message_handler.node.get_cluster!(1_u16, Matter::Cluster::Groups)
      key_set_id = 5_u16
      group_id = 0x1234_u16
      key_management.handle_key_set_write(Matter::Cluster::GroupKeyManagement::KeySetWriteRequest.new(
        Matter::Cluster::GroupKeyManagement::GroupKeySetStruct.new(key_set_id,
          epoch_key0: Bytes.new(16, 0xAA_u8), epoch_start_time0: 1_u64)), index)
      key_management.add_group_key_map(group_id, key_set_id, index)
      groups.with_request_context do
        groups.request_fabric_index = index
        groups.add_group(Matter::Cluster::Groups::AddGroupRequest.new(
          Matter::DataType::GroupId.new(group_id), "Old fabric"))
      end
      first.persistence.save_cluster(key_management).should be_true
      first.persistence.save_cluster(groups).should be_true

      # Model a removal started by an older build before the durable gate
      # existed; restart must repair its orphaned group documents.
      first.operational_credentials.on_before_fabric_removed = nil
      backend.fail_next_cluster_id = first.access_control.persistence_key
      expect_raises(Matter::StorageError, "Injected targeted cluster write failure") do
        first.operational_credentials.credentials.remove_fabric(index)
      end
      backend.close

      restarted = CredentialRecoveryDevice.new(path)
      restarted.fabric_table.get_fabric(index).should be_nil
      restored_keys = restarted.message_handler.node.get_cluster!(Matter::Cluster::GroupKeyManagement)
      restored_groups = restarted.message_handler.node.get_cluster!(1_u16, Matter::Cluster::Groups)
      restored_keys.get_key_set(key_set_id, index).should be_nil
      restored_keys.group_key_map(index).should be_empty
      restored_groups.with_request_context do
        restored_groups.request_fabric_index = index
        restored_groups.member_of?(group_id).should be_false
      end
      replacement_index = add_recovery_fabric(restarted, fabric_id: 0x4444_u64)
      replacement_index.should eq(index)
      restored_keys.get_key_set(key_set_id, replacement_index).should be_nil
      restarted.shutdown!
    ensure
      File.delete?(path)
    end
  end

  it "keeps the fabric reserved until removed group credentials and names are durable" do
    path = File.join(Dir.tempdir, "matter-credential-recovery-#{Random::Secure.hex(6)}.yml")
    begin
      backend = FailCredentialYamlFile.new(path)
      device = CredentialRecoveryDevice.new(backend)
      index = add_recovery_fabric(device)
      device.general_commissioning.commissioning_complete(index, true).error_code.ok?.should be_true
      key_management = device.message_handler.node.get_cluster!(Matter::Cluster::GroupKeyManagement)
      groups = device.message_handler.node.get_cluster!(1_u16, Matter::Cluster::Groups)
      key_set_id = 5_u16
      group_id = 0x1234_u16
      key_management.handle_key_set_write(Matter::Cluster::GroupKeyManagement::KeySetWriteRequest.new(
        Matter::Cluster::GroupKeyManagement::GroupKeySetStruct.new(key_set_id,
          epoch_key0: Bytes.new(16, 0xBB_u8), epoch_start_time0: 1_u64)), index)
      key_management.add_group_key_map(group_id, key_set_id, index)
      groups.with_request_context do
        groups.request_fabric_index = index
        groups.add_group(Matter::Cluster::Groups::AddGroupRequest.new(
          Matter::DataType::GroupId.new(group_id), "Old fabric"))
      end
      device.persistence.save_cluster(key_management).should be_true
      device.persistence.save_cluster(groups).should be_true

      backend.fail_next_cluster_id = key_management.persistence_key
      expect_raises(Matter::StorageError) do
        device.operational_credentials.credentials.remove_fabric(index)
      end
      device.fabric_table.get_fabric(index).should_not be_nil
      device.operational_credentials.credentials.remove_fabric(index).ok?.should be_true
      device.fabric_table.get_fabric(index).should be_nil
      backend.close

      restarted = CredentialRecoveryDevice.new(path)
      restored_keys = restarted.message_handler.node.get_cluster!(Matter::Cluster::GroupKeyManagement)
      restored_groups = restarted.message_handler.node.get_cluster!(1_u16, Matter::Cluster::Groups)
      restored_keys.get_key_set(key_set_id, index).should be_nil
      restored_keys.group_key_map(index).should be_empty
      restored_groups.with_request_context do
        restored_groups.request_fabric_index = index
        restored_groups.member_of?(group_id).should be_false
      end
      restarted.shutdown!
    ensure
      File.delete?(path)
    end
  end

  it "repairs persisted scenes left by an interrupted fabric removal before index reuse" do
    path = File.join(Dir.tempdir, "matter-scene-recovery-#{Random::Secure.hex(6)}.yml")
    begin
      backend = FailCredentialYamlFile.new(path)
      first = CredentialRecoveryDevice.new(backend)
      index = add_recovery_fabric(first)
      first.general_commissioning.commissioning_complete(index, true).error_code.ok?.should be_true
      scenes = first.message_handler.node.get_cluster!(1_u16, Matter::Cluster::ScenesManagement)
      scenes.scenes[{index, 0x1234_u16, 1_u8}] = Matter::Cluster::ScenesManagement::SceneData.new(
        scene_name: "Old fabric scene")
      scenes.scene_info_by_fabric[index] = Matter::Cluster::ScenesManagement::SceneInfo.new(
        scene_count: 1_u8, fabric_index: index)
      first.persistence.save_cluster(scenes).should be_true

      # Simulate an older build that lost power after deleting the fabric
      # document, before its post-removal scene callback could run.
      first.operational_credentials.on_before_fabric_removed = nil
      backend.fail_next_cluster_id = first.access_control.persistence_key
      expect_raises(Matter::StorageError, "Injected targeted cluster write failure") do
        first.operational_credentials.credentials.remove_fabric(index)
      end
      backend.close

      restarted = CredentialRecoveryDevice.new(path)
      restarted.fabric_table.get_fabric(index).should be_nil
      restored = restarted.message_handler.node.get_cluster!(1_u16, Matter::Cluster::ScenesManagement)
      restored.has_scene?(0x1234_u16, 1_u8, index).should be_false
      restored.scene_info_by_fabric.has_key?(index).should be_false
      replacement = add_recovery_fabric(restarted, fabric_id: 0x4444_u64)
      replacement.should eq(index)
      restored.has_scene?(0x1234_u16, 1_u8, replacement).should be_false
      restarted.shutdown!
    ensure
      File.delete?(path)
    end
  end

  it "keeps the fabric reserved until erased scenes are durable" do
    path = File.join(Dir.tempdir, "matter-scene-removal-#{Random::Secure.hex(6)}.yml")
    begin
      backend = FailCredentialYamlFile.new(path)
      device = CredentialRecoveryDevice.new(backend)
      index = add_recovery_fabric(device)
      device.general_commissioning.commissioning_complete(index, true).error_code.ok?.should be_true
      scenes = device.message_handler.node.get_cluster!(1_u16, Matter::Cluster::ScenesManagement)
      scenes.scenes[{index, 0x1234_u16, 1_u8}] = Matter::Cluster::ScenesManagement::SceneData.new(
        scene_name: "Old fabric scene")
      scenes.scene_info_by_fabric[index] = Matter::Cluster::ScenesManagement::SceneInfo.new(
        scene_count: 1_u8, fabric_index: index)
      device.persistence.save_cluster(scenes).should be_true

      backend.fail_next_cluster_id = scenes.persistence_key
      expect_raises(Matter::StorageError, "Could not persist erased Scenes") do
        device.operational_credentials.credentials.remove_fabric(index)
      end
      device.fabric_table.get_fabric(index).should_not be_nil
      device.operational_credentials.credentials.remove_fabric(index).ok?.should be_true
      backend.close

      restarted = CredentialRecoveryDevice.new(path)
      restored = restarted.message_handler.node.get_cluster!(1_u16, Matter::Cluster::ScenesManagement)
      restored.has_scene?(0x1234_u16, 1_u8, index).should be_false
      restored.scene_info_by_fabric.has_key?(index).should be_false
      restarted.shutdown!
    ensure
      File.delete?(path)
    end
  end

  it "restores the old CASE identity after an uncommitted UpdateNOC and keeps its ACL" do
    path = File.join(Dir.tempdir, "matter-credential-recovery-#{Random::Secure.hex(6)}.yml")
    begin
      first = CredentialRecoveryDevice.new(path)
      index = add_recovery_fabric(first)
      first.general_commissioning.commissioning_complete(index, true).error_code.ok?.should be_true
      first.persistence.save_cluster(first.access_control).should be_true
      original = first.fabric_table.get_fabric(index).as(Matter::Fabric)
      old_noc = original.operational_cert.dup
      old_public_key = original.operational_key.public_key.dup
      old_destination_id = original.compute_destination_id(Bytes.new(32, 0x55_u8))
      update_recovery_fabric(first, index)
      first.shutdown!

      restarted = CredentialRecoveryDevice.new(path)
      restored = restarted.fabric_table.get_fabric(index).as(Matter::Fabric)
      restored.node_id.should eq(0x2222_u64)
      restored.operational_cert.should eq(old_noc)
      restored.operational_key.public_key.should eq(old_public_key)
      restored.compute_destination_id(Bytes.new(32, 0x55_u8)).should eq(old_destination_id)
      restarted.access_control.acl(index).size.should eq(1)
      restarted.shutdown!
    ensure
      File.delete?(path)
    end
  end

  it "keeps the live CASE identity old if an UpdateNOC fabric write fails" do
    path = File.join(Dir.tempdir, "matter-credential-recovery-#{Random::Secure.hex(6)}.yml")
    begin
      backend = FailCredentialYamlFile.new(path)
      first = CredentialRecoveryDevice.new(backend)
      index = add_recovery_fabric(first)
      first.general_commissioning.commissioning_complete(index, true).error_code.ok?.should be_true
      previous = first.fabric_table.get_fabric(index).as(Matter::Fabric)
      old_key = previous.operational_key.public_key.dup
      backend.fail_next_fabric_write = true

      expect_raises(Matter::StorageError) { update_recovery_fabric(first, index) }
      live = first.fabric_table.get_fabric(index).as(Matter::Fabric)
      live.node_id.should eq(0x2222_u64)
      live.operational_key.public_key.should eq(old_key)
      backend.read(Matter::Storage::Collections::DEVICE,
        Matter::Commissioning::CredentialJournal::ID).should_not be_nil
      backend.close

      restarted = CredentialRecoveryDevice.new(path)
      restored = restarted.fabric_table.get_fabric(index).as(Matter::Fabric)
      restored.node_id.should eq(0x2222_u64)
      restored.operational_key.public_key.should eq(old_key)
      restarted.access_control.acl(index).size.should eq(1)
      restarted.shutdown!
    ensure
      File.delete?(path)
    end
  end

  it "retains a new fabric after CommissioningComplete was acknowledged" do
    path = File.join(Dir.tempdir, "matter-credential-recovery-#{Random::Secure.hex(6)}.yml")
    begin
      first = CredentialRecoveryDevice.new(path)
      index = add_recovery_fabric(first)
      first.general_commissioning.commissioning_complete(index, true).error_code.ok?.should be_true
      first.shutdown!

      restarted = CredentialRecoveryDevice.new(path)
      restarted.fabric_table.get_fabric(index).should_not be_nil
      restarted.access_control.acl(index).size.should eq(1)
      restarted.shutdown!
    ensure
      File.delete?(path)
    end
  end

  it "leaves fail-safe armed and delays other completion callbacks if journal commit fails" do
    path = File.join(Dir.tempdir, "matter-credential-recovery-#{Random::Secure.hex(6)}.yml")
    begin
      backend = FailCredentialYamlFile.new(path)
      first = CredentialRecoveryDevice.new(backend,
        tc_min_required_version: 2_u16, tc_required_acknowledgements: 0b0110_u16)
      index = add_recovery_fabric(first)
      first.general_commissioning.set_tc_acknowledgements(
        Matter::Cluster::GeneralCommissioning::SetTCAcknowledgementsRequest.new(2_u16, 0b0110_u16)
      ).error_code.ok?.should be_true
      terms_commits = 0
      window_closes = 0
      first.general_commissioning.failsafe.on_terms_conditions_commit = -> { terms_commits += 1; nil }
      first.general_commissioning.on_close_commissioning_window = -> { window_closes += 1; nil }
      backend.fail_next_journal_delete = true

      expect_raises(Matter::StorageError) do
        first.general_commissioning.commissioning_complete(index, true)
      end
      first.general_commissioning.failsafe_armed?.should be_true
      terms_commits.should eq(0)
      window_closes.should eq(0)
      backend.read(Matter::Storage::Collections::DEVICE,
        Matter::Commissioning::CredentialJournal::ID).should_not be_nil
      backend.close

      restarted = CredentialRecoveryDevice.new(path,
        tc_min_required_version: 2_u16, tc_required_acknowledgements: 0b0110_u16)
      restarted.fabric_table.get_fabric(index).should be_nil
      restarted.access_control.acl(index).should be_empty
      restarted.general_commissioning.tc_accepted_version.should eq(0_u16)
      restarted.general_commissioning.tc_acknowledgements_required?.should be_true
      restarted.shutdown!
    ensure
      File.delete?(path)
    end
  end

  it "keeps durable credentials if a later completion callback fails before the response" do
    path = File.join(Dir.tempdir, "matter-credential-recovery-#{Random::Secure.hex(6)}.yml")
    begin
      first = CredentialRecoveryDevice.new(path)
      index = add_recovery_fabric(first)
      first.general_commissioning.failsafe.on_terms_conditions_commit = -> do
        raise Matter::StorageError.new("Injected post-commit callback failure")
      end
      expect_raises(Matter::StorageError) do
        first.general_commissioning.commissioning_complete(index, true)
      end
      first.persistence.backend.read(Matter::Storage::Collections::DEVICE,
        Matter::Commissioning::CredentialJournal::ID).should be_nil
      first.persistence.backend.close

      restarted = CredentialRecoveryDevice.new(path)
      restarted.fabric_table.get_fabric(index).should_not be_nil
      restarted.access_control.acl(index).size.should eq(1)
      restarted.shutdown!
    ensure
      File.delete?(path)
    end
  end

  it "retains an acknowledged UpdateNOC replacement after restart" do
    path = File.join(Dir.tempdir, "matter-credential-recovery-#{Random::Secure.hex(6)}.yml")
    begin
      first = CredentialRecoveryDevice.new(path)
      index = add_recovery_fabric(first)
      first.general_commissioning.commissioning_complete(index, true).error_code.ok?.should be_true
      update_recovery_fabric(first, index)
      first.general_commissioning.commissioning_complete(index, true).error_code.ok?.should be_true
      first.shutdown!

      restarted = CredentialRecoveryDevice.new(path)
      restarted.fabric_table.get_fabric(index).as(Matter::Fabric).node_id.should eq(0x7777_u64)
      restarted.access_control.acl(index).size.should eq(1)
      restarted.shutdown!
    ensure
      File.delete?(path)
    end
  end

  it "rejects a malformed journal before loading operational state" do
    path = File.join(Dir.tempdir, "matter-credential-recovery-#{Random::Secure.hex(6)}.yml")
    begin
      backend = Matter::Storage::YamlFile.new(path).tap(&.open)
      backend.write(Matter::Storage::Collections::DEVICE,
        Matter::Commissioning::CredentialJournal::ID,
        Matter::Storage::Document{Matter::Commissioning::CredentialJournal::OPERATION => "unknown",
                                  Matter::Commissioning::CredentialJournal::INDEX     => 1_i64})
      backend.close

      expect_raises(Matter::StorageError) { CredentialRecoveryDevice.new(path) }
    ensure
      File.delete?(path)
    end
  end
end
