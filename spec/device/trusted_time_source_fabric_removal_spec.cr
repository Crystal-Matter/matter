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

  def write(collection : String, id : String, document : Matter::Storage::Document) : Nil
    if collection == Matter::Storage::Collections::CLUSTERS && id == @fail_next_cluster_id
      @fail_next_cluster_id = nil
      raise Matter::StorageError.new("Injected cluster write failure")
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
  it "does not expose a removed fabric's source after ACL failure and index reuse" do
    require_udp_sockets!
    path = File.join(Dir.tempdir, "matter-trusted-time-removal-#{Random::Secure.hex(6)}.yml")
    begin
      storage = TrustedTimeFailStorage.new(path)
      device = TrustedTimeRemovalDevice.new(storage: storage, port: 0)
      device.fabric_table.add_fabric(trusted_time_fabric(1_u8, 0x1001_u64)).should be_true
      time_sync = set_trusted_time_source(device, 1_u8)

      storage.fail_next_cluster_id = device.access_control.persistence_key
      expect_raises(Matter::StorageError, "Injected cluster write failure") do
        device.operational_credentials.credentials.remove_fabric(1_u8)
      end
      device.fabric_table.get_fabric(1_u8).should be_nil
      device.fabric_table.add_fabric(trusted_time_fabric(1_u8, 0x2001_u64)).should be_true
      time_sync.trusted_time_source.should be_nil
    ensure
      device.try(&.shutdown!)
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
      # Model an interrupted removal by a build without durable pre-delete cleanup.
      storage.fail_next_cluster_id = first.access_control.persistence_key
      expect_raises(Matter::StorageError, "Injected cluster write failure") do
        first.operational_credentials.credentials.remove_fabric(1_u8)
      end
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
      expect_raises(Matter::StorageError, "Injected cluster write failure") do
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
