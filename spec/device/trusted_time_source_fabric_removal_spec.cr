require "../spec_helper"
require "../../src/matter/device"

private alias TrustedTimeSync = Matter::Cluster::TimeSynchronization

private class TrustedTimeRemovalDevice < Matter::Device
  identity vendor: "Crystal Matter", product: "Trusted Time Removal",
    vendor_id: 0xFFF1_u16, product_id: 0x8131_u16,
    discriminator: 3845_u16, pin: 20202098_u32,
    device_type: Matter::DeviceType::ROOT_NODE
  storage :memory

  endpoint 0, device_type: Matter::DeviceType::AGGREGATOR do
    cluster TrustedTimeSync, feature_map: TrustedTimeSync::Feature::TrustedTimeClient
  end
end

private class TrustedTimeFailStorage < Matter::Storage::YamlFile
  property fail_next_cluster_id : String?
  property? fail_next_fabric_delete : Bool = false

  def write(collection : String, id : String, document : Matter::Storage::Document) : Nil
    if collection == Matter::Storage::Collections::CLUSTERS && id == @fail_next_cluster_id
      @fail_next_cluster_id = nil
      raise Matter::StorageError.new("Injected cluster write failure")
    end
    super
  end

  def delete(collection : String, id : String) : Nil
    if @fail_next_fabric_delete && collection == Matter::Storage::Collections::FABRICS
      @fail_next_fabric_delete = false
      raise Matter::StorageError.new("Injected fabric delete failure")
    end
    super
  end
end

private def trusted_time_fabric(index : UInt8, fabric_id : UInt64) : Matter::Fabric
  Matter::Fabric.new(
    fabric_id: fabric_id, fabric_index: index, node_id: 0x5678_u64,
    root_public_key: Random::Secure.random_bytes(65),
    operational_cert: Random::Secure.random_bytes(200),
    operational_key: Matter::Crypto::Key.generate_key_pair,
    ipk: Random::Secure.random_bytes(16))
end

private def set_trusted_time_source(device : TrustedTimeRemovalDevice, index : UInt8) : TrustedTimeSync
  time_sync = device.node.get_cluster!(0_u16, TrustedTimeSync)
  source = TrustedTimeSync::FabricScopedTrustedTimeSourceStruct.new(0x1234_u64, 2_u16)
  status = time_sync.invoke_command(TrustedTimeSync::CMD_SET_TRUSTED_TIME_SOURCE,
    TrustedTimeSync::SetTrustedTimeSourceRequest.new(source).to_tlv(nil),
    is_case_session: true, fabric_index: index).as(Matter::InteractionModel::Status)
  status.status.should eq(Matter::InteractionModel::StatusCode::Success)
  device.persistence.save_cluster(time_sync).should be_true
  time_sync
end

describe "TrustedTimeSource fabric removal durability" do
  it "retains the old source after fabric document deletion fails" do
    require_udp_sockets!
    path = File.join(Dir.tempdir, "matter-trusted-time-delete-#{Random::Secure.hex(6)}.yml")
    begin
      storage = TrustedTimeFailStorage.new(path)
      first = TrustedTimeRemovalDevice.new(storage: storage, port: 0)
      first.fabric_table.add_fabric(trusted_time_fabric(1_u8, 0x1001_u64)).should be_true
      time_sync = set_trusted_time_source(first, 1_u8)
      expected = time_sync.trusted_time_source
      storage.fail_next_fabric_delete = true
      expect_raises(Matter::StorageError, "Injected fabric delete failure") do
        first.operational_credentials.credentials.remove_fabric(1_u8)
      end
      time_sync.trusted_time_source.should eq(expected)
      first.fabric_table.used_indices.should contain(1_u8)
      storage.close

      restarted = TrustedTimeRemovalDevice.new(storage: TrustedTimeFailStorage.new(path), port: 0)
      restarted.fabric_table.get_fabric(1_u8).should_not be_nil
      restarted.node.get_cluster!(0_u16, TrustedTimeSync).trusted_time_source.should eq(expected)
    ensure
      restarted.try(&.shutdown!)
      File.delete?(path)
    end
  end

  it "retains the old source after an ACL failure and permits safe reuse after restart" do
    require_udp_sockets!
    path = File.join(Dir.tempdir, "matter-trusted-time-removal-#{Random::Secure.hex(6)}.yml")
    begin
      storage = TrustedTimeFailStorage.new(path)
      device = TrustedTimeRemovalDevice.new(storage: storage, port: 0)
      device.fabric_table.add_fabric(trusted_time_fabric(1_u8, 0x1001_u64)).should be_true
      time_sync = set_trusted_time_source(device, 1_u8)
      expected = time_sync.trusted_time_source

      storage.fail_next_cluster_id = device.access_control.persistence_key
      expect_raises(Matter::StorageError, "Could not persist erased Access Control") do
        device.operational_credentials.credentials.remove_fabric(1_u8)
      end
      device.fabric_table.get_fabric(1_u8).should_not be_nil
      device.fabric_table.quarantined?(1_u8).should be_true
      device.fabric_table.add_fabric(trusted_time_fabric(1_u8, 0x2001_u64)).should be_false
      time_sync.trusted_time_source.should eq(expected)
      device.shutdown!
      device = nil

      restarted = TrustedTimeRemovalDevice.new(storage: TrustedTimeFailStorage.new(path), port: 0)
      restarted.fabric_table.get_fabric(1_u8).should_not be_nil
      recovered_time_sync = restarted.node.get_cluster!(0_u16, TrustedTimeSync)
      recovered_time_sync.trusted_time_source.should eq(expected)
      restarted.operational_credentials.credentials.remove_fabric(1_u8).ok?.should be_true
      restarted.fabric_table.add_fabric(trusted_time_fabric(1_u8, 0x2001_u64)).should be_true
      recovered_time_sync.trusted_time_source.should be_nil
    ensure
      device.try(&.shutdown!)
      restarted.try(&.shutdown!)
      File.delete?(path)
    end
  end

  it "repairs an orphan source on restart before the index can be reused" do
    require_udp_sockets!
    path = File.join(Dir.tempdir, "matter-trusted-time-removal-#{Random::Secure.hex(6)}.yml")
    begin
      storage = TrustedTimeFailStorage.new(path)
      first = TrustedTimeRemovalDevice.new(storage: storage, port: 0)
      first.fabric_table.add_fabric(trusted_time_fabric(1_u8, 0x1001_u64)).should be_true
      set_trusted_time_source(first, 1_u8)
      # Model an older build that deleted the fabric document before clearing
      # its persisted source. Restart must repair the orphan.
      storage.delete(Matter::FabricTable::COLLECTION, "1")
      first.shutdown!

      restarted = TrustedTimeRemovalDevice.new(storage: TrustedTimeFailStorage.new(path), port: 0)
      restarted.node.get_cluster!(0_u16, TrustedTimeSync).trusted_time_source.should be_nil
      restarted.fabric_table.add_fabric(trusted_time_fabric(1_u8, 0x2001_u64)).should be_true
      restarted.node.get_cluster!(0_u16, TrustedTimeSync).trusted_time_source.should be_nil
    ensure
      restarted.try(&.shutdown!)
      File.delete?(path)
    end
  end

  it "keeps the old fabric index reserved when erasing the source cannot be saved" do
    require_udp_sockets!
    path = File.join(Dir.tempdir, "matter-trusted-time-removal-#{Random::Secure.hex(6)}.yml")
    begin
      storage = TrustedTimeFailStorage.new(path)
      device = TrustedTimeRemovalDevice.new(storage: storage, port: 0)
      device.fabric_table.add_fabric(trusted_time_fabric(1_u8, 0x1001_u64)).should be_true
      time_sync = set_trusted_time_source(device, 1_u8)

      storage.fail_next_cluster_id = time_sync.persistence_key
      expect_raises(Matter::StorageError, "Could not persist erased TrustedTimeSource") do
        device.operational_credentials.credentials.remove_fabric(1_u8)
      end
      device.fabric_table.get_fabric(1_u8).should_not be_nil
      device.operational_credentials.credentials.remove_fabric(1_u8).ok?.should be_true
    ensure
      device.try(&.shutdown!)
      File.delete?(path)
    end
  end
end
