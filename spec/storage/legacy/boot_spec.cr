require "../../spec_helper"
require "../../../src/matter/storage/legacy"
require "../../../src/matter/device"
require "../../../src/matter/cluster/on_off"
require "../../../src/matter/cluster/level_control"
require "../../../src/matter/cluster/groups"
require "../../../src/matter/cluster/scenes_management"
require "../../../src/matter/cluster/user_label"
require "../../../src/matter/cluster/identify"

# A dimmable light on endpoint 1 with every cluster the legacy fixture has a
# document for, so booting it on an imported store exercises each restore.
class LegacyBootDevice < Matter::Device
  LIGHT_ENDPOINT = 1_u16

  # Bind an ephemeral UDP port so the device never collides with a running one.
  EPHEMERAL_PORT = 0

  @switch : Matter::Cluster::OnOff?
  @level : Matter::Cluster::LevelControl?
  @groups : Matter::Cluster::Groups?
  @scenes : Matter::Cluster::ScenesManagement?

  def initialize(storage : Matter::Storage::Backend)
    super(storage, port: EPHEMERAL_PORT)
  end

  def device_name : String
    "Legacy Light"
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
    Matter::DeviceType::DIMMABLE_LIGHT
  end

  def switch : Matter::Cluster::OnOff
    @switch.as(Matter::Cluster::OnOff)
  end

  def level : Matter::Cluster::LevelControl
    @level.as(Matter::Cluster::LevelControl)
  end

  def groups : Matter::Cluster::Groups
    @groups.as(Matter::Cluster::Groups)
  end

  def scenes : Matter::Cluster::ScenesManagement
    @scenes.as(Matter::Cluster::ScenesManagement)
  end

  def group_key_management : Matter::Cluster::GroupKeyManagement
    message_handler.clusters[{0_u16, Matter::Cluster::GroupKeyManagement::CLUSTER_ID}].as(Matter::Cluster::GroupKeyManagement)
  end

  protected def device_clusters : Array(Matter::Cluster::Base)
    endpoint = endpoint(LIGHT_ENDPOINT)
    @switch = Matter::Cluster::OnOff.new(endpoint, feature_map: Matter::Cluster::OnOff::Feature::Lighting)
    @level = Matter::Cluster::LevelControl.new(endpoint)
    @groups = Matter::Cluster::Groups.new(endpoint)
    @scenes = Matter::Cluster::ScenesManagement.new(endpoint)

    # Identify is mandatory on a Dimmable Light.
    [switch, level, groups, scenes, Matter::Cluster::Identify.new(endpoint)] of Matter::Cluster::Base
  end

  protected def endpoint_device_types : Hash(UInt16, UInt32)
    {LIGHT_ENDPOINT => Matter::DeviceType::DIMMABLE_LIGHT}
  end

  def release : Nil
    persistence.close
    transport.close
  end
end

module LegacyBootSpec
  FIXTURE = File.join(__DIR__, "..", "..", "fixtures", "legacy_storage.json")

  # Values written into `spec/fixtures/legacy_storage.json`.
  FABRIC_INDEX  =                     1_u8
  FABRIC_ID     = 14250677199893128768_u64
  NODE_ID       =           5000000001_u64
  VENDOR_ID     =                65521_u16
  FABRIC_LABEL  = "Home"
  FABRIC_COUNT  = 2
  NODE_LABEL    = "Crystal Light"
  LOCATION      = "AU"
  CURRENT_LEVEL =  128_u8
  GROUP_ID      = 257_u16
  GROUP_NAME    = "Kitchen"
  UNNAMED_GROUP = 258_u16
  SCENE_ID      =    1_u8

  ADMIN_SUBJECT    = 112233_u64
  OPERATE_SUBJECTS = [445566_u64, UInt64::MAX]
  OPERATE_FABRIC   = 2_u8
  ON_OFF_CLUSTER   = Matter::Cluster::OnOff::CLUSTER_ID

  HOSTNAME      = "0123456789ABCDEF.local"
  SERIAL_NUMBER = "ABCDEF0123456789"
  UNIQUE_ID     = "00112233445566778899aabbccddeeff"
  USER_LABELS   = [{"room", "kitchen"}, {"floor", "1"}]

  def self.with_temp_file(& : String ->) : Nil
    path = File.join(Dir.tempdir, "matter-legacy-boot-#{Random::Secure.hex(6)}.yml")
    yield path
  ensure
    File.delete?(path) if path
  end

  # Imports the fixture into a YAML store at *path*, as `matter-storage migrate` would.
  def self.import(path : String) : Nil
    source = Matter::Storage::Legacy::JsonImport.new(FIXTURE)
    source.open
    yaml = Matter::Storage::YamlFile.new(path)
    yaml.open
    Matter::Storage::Migrator.copy(source, yaml)
    yaml.close
    source.close
  end

  def self.with_imported_device(& : LegacyBootDevice ->) : Nil
    with_temp_file do |path|
      import(path)
      device = LegacyBootDevice.new(Matter::Storage::YamlFile.new(path))
      begin
        yield device
      ensure
        device.release
      end
    end
  end
end

describe "Booting a device from a legacy import" do
  it "restores the fabric table" do
    LegacyBootSpec.with_imported_device do |device|
      device.persistence.fabric_table.size.should eq(LegacyBootSpec::FABRIC_COUNT)
      fabric = device.fabric_table.get_fabric(LegacyBootSpec::FABRIC_INDEX).as(Matter::Fabric)
      fabric.fabric_id.should eq(LegacyBootSpec::FABRIC_ID)
      fabric.node_id.should eq(LegacyBootSpec::NODE_ID)
      fabric.vendor_id.should eq(LegacyBootSpec::VENDOR_ID)
      fabric.label.should eq(LegacyBootSpec::FABRIC_LABEL)
    end
  end

  it "restores the user labels from the imported document" do
    LegacyBootSpec.with_temp_file do |path|
      LegacyBootSpec.import(path)
      store = Matter::Storage::YamlFile.new(path)
      store.open
      key = Matter::Cluster::Base.persistence_key(0_u16, Matter::Cluster::UserLabel::CLUSTER_ID)
      document = store.read(Matter::Storage::Collections::CLUSTERS, key).as(Matter::Storage::Document)
      store.close

      labels = Matter::Cluster::UserLabel.new(endpoint(0))
      labels.restore_state(document)
      labels.label_list.map { |entry| {entry.label, entry.value} }.should eq(LegacyBootSpec::USER_LABELS)
    end
  end

  it "restores the root node clusters" do
    LegacyBootSpec.with_imported_device do |device|
      device.basic_info.node_label.should eq(LegacyBootSpec::NODE_LABEL)
      device.basic_info.location.should eq(LegacyBootSpec::LOCATION)

      acl = device.access_control.acl
      acl.size.should eq(2)
      acl[0].privilege.should eq(Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer)
      acl[0].auth_mode.should eq(Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE)
      acl[0].subjects.should eq([LegacyBootSpec::ADMIN_SUBJECT])
      acl[0].targets.should be_nil
      acl[0].fabric_index.should eq(LegacyBootSpec::FABRIC_INDEX)
      acl[1].privilege.should eq(Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Operate)
      acl[1].subjects.should eq(LegacyBootSpec::OPERATE_SUBJECTS)
      acl[1].fabric_index.should eq(LegacyBootSpec::OPERATE_FABRIC)
      targets = acl[1].targets.as(Array(Matter::Cluster::AccessControl::Target))
      targets.size.should eq(1)
      targets[0].cluster.should eq(LegacyBootSpec::ON_OFF_CLUSTER)
      targets[0].endpoint.should eq(LegacyBootDevice::LIGHT_ENDPOINT)
      targets[0].device_type.should be_nil

      group_table = device.group_key_management.group_table(LegacyBootSpec::FABRIC_INDEX)
      group_table.size.should eq(1)
      group_table[0].group_id.should eq(LegacyBootSpec::GROUP_ID)
      group_table[0].group_name.should eq(LegacyBootSpec::GROUP_NAME)
      group_table[0].endpoints.should eq([LegacyBootDevice::LIGHT_ENDPOINT])
    end
  end

  it "restores the light's clusters" do
    LegacyBootSpec.with_imported_device do |device|
      device.switch.on?.should be_true
      device.level.current_level.should eq(LegacyBootSpec::CURRENT_LEVEL)

      device.groups.groups.should eq({LegacyBootSpec::GROUP_ID => LegacyBootSpec::GROUP_NAME, LegacyBootSpec::UNNAMED_GROUP => ""})
      device.groups.member_of?(LegacyBootSpec::GROUP_ID).should be_true

      device.scenes.scene_count(LegacyBootSpec::FABRIC_INDEX).should eq(1)
      device.scenes.has_scene?(LegacyBootSpec::GROUP_ID, LegacyBootSpec::SCENE_ID, LegacyBootSpec::FABRIC_INDEX).should be_true
    end
  end

  it "migrates legacy unscoped Groups membership to its authenticated fabric and keeps it after restart" do
    LegacyBootSpec.with_temp_file do |path|
      LegacyBootSpec.import(path)
      device = LegacyBootDevice.new(Matter::Storage::YamlFile.new(path))
      begin
        device.groups.group_names_for_fabric(LegacyBootSpec::FABRIC_INDEX).should eq({LegacyBootSpec::GROUP_ID => LegacyBootSpec::GROUP_NAME})
        device.groups.group_names_for_fabric(LegacyBootSpec::OPERATE_FABRIC).should be_empty
        device.groups.with_request_context do
          device.groups.request_is_case_session = true
          device.groups.request_fabric_index = LegacyBootSpec::FABRIC_INDEX
          device.groups.view_group(Matter::Cluster::Groups::ViewGroupRequest.new(
            Matter::DataType::GroupId.new(LegacyBootSpec::GROUP_ID))).status_code.should eq(Matter::InteractionModel::StatusCode::Success)
          device.groups.request_fabric_index = LegacyBootSpec::OPERATE_FABRIC
          device.groups.view_group(Matter::Cluster::Groups::ViewGroupRequest.new(
            Matter::DataType::GroupId.new(LegacyBootSpec::GROUP_ID))).status_code.should eq(Matter::InteractionModel::StatusCode::NotFound)
        end
      ensure
        device.release
      end

      restarted = LegacyBootDevice.new(Matter::Storage::YamlFile.new(path))
      begin
        restarted.groups.group_names_for_fabric(LegacyBootSpec::FABRIC_INDEX).should eq({LegacyBootSpec::GROUP_ID => LegacyBootSpec::GROUP_NAME})
        restarted.groups.group_names_for_fabric(LegacyBootSpec::OPERATE_FABRIC).should be_empty
        restarted.group_key_management.group_table(LegacyBootSpec::FABRIC_INDEX).first.endpoints.should eq([LegacyBootDevice::LIGHT_ENDPOINT])
        restarted.groups.with_request_context do
          restarted.groups.request_is_case_session = true
          restarted.groups.request_fabric_index = LegacyBootSpec::FABRIC_INDEX
          restarted.groups.remove_group(Matter::Cluster::Groups::RemoveGroupRequest.new(
            Matter::DataType::GroupId.new(LegacyBootSpec::GROUP_ID))).status_code.should eq(Matter::InteractionModel::StatusCode::Success)
        end
        restarted.persistence.save_cluster(restarted.groups).should be_true
      ensure
        restarted.release
      end

      removed = LegacyBootDevice.new(Matter::Storage::YamlFile.new(path))
      begin
        removed.groups.group_names_for_fabric(LegacyBootSpec::FABRIC_INDEX).should be_empty
        removed.group_key_management.group_table(LegacyBootSpec::FABRIC_INDEX).should be_empty
      ensure
        removed.release
      end
    end
  end

  it "keeps the device identity" do
    LegacyBootSpec.with_imported_device do |device|
      device.hostname.should eq(LegacyBootSpec::HOSTNAME)
      device.persistence.commissioning_hostname.should eq(LegacyBootSpec::HOSTNAME)
      device.basic_info.serial_number.should eq(LegacyBootSpec::SERIAL_NUMBER)
      device.basic_info.unique_id.should eq(LegacyBootSpec::UNIQUE_ID)
    end
  end
end
