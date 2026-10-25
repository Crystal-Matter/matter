require "../spec_helper"
require "../../src/matter/device"

private class FabricEventSpecDevice < Matter::Device
  identity vendor: "Crystal Matter", product: "Fabric Event Test",
    vendor_id: 0xFFF1_u16, product_id: 0x8130_u16,
    discriminator: 3844_u16, pin: 20202097_u32,
    device_type: Matter::DeviceType::ROOT_NODE
  storage :memory
end

private def event_spec_fabric(index : UInt8, fabric_id : UInt64) : Matter::Fabric
  Matter::Fabric.new(
    fabric_id: fabric_id, fabric_index: index, node_id: 0x5678_u64,
    root_public_key: Random::Secure.random_bytes(65),
    operational_cert: Random::Secure.random_bytes(200),
    operational_key: Matter::Crypto::Key.generate_key_pair,
    ipk: Random::Secure.random_bytes(16))
end

describe Matter::Device do
  it "does not disclose retained fabric events after RemoveFabric reuses an index" do
    require_udp_sockets!
    device = FabricEventSpecDevice.new(storage: Matter::Storage::Memory.new, port: 0)
    device.fabric_table.add_fabric(event_spec_fabric(1_u8, 0x1001_u64)).should be_true
    device.fabric_table.add_fabric(event_spec_fabric(2_u8, 0x1002_u64)).should be_true

    journal = device.node.event_journal
    before = journal.latest_event_number
    old = journal.record(0_u16, Matter::Cluster::AccessControl::CLUSTER_ID,
      Matter::Cluster::AccessControl::EVENT_ACCESS_CONTROL_ENTRY_CHANGED,
      :info, TLV::Any.new(11_u32, nil), fabric_index: 1_u8)
    other = journal.record(0_u16, Matter::Cluster::AccessControl::CLUSTER_ID,
      Matter::Cluster::AccessControl::EVENT_ACCESS_CONTROL_ENTRY_CHANGED,
      :info, TLV::Any.new(22_u32, nil), fabric_index: 2_u8)
    global = journal.record(0_u16, Matter::Cluster::GeneralDiagnostics::CLUSTER_ID,
      Matter::Cluster::GeneralDiagnostics::EVENT_BOOT_REASON,
      :critical, TLV::Any.new(33_u32, nil))
    path = [Matter::InteractionModel::EventPath.new]
    journal.query(path, after: before, fabric_index: 1_u8).map(&.event_number).should eq([old.event_number, global.event_number])

    response = device.operational_credentials.handle_remove_fabric(
      Matter::Cluster::OperationalCredentials::RemoveFabricCommand.new(1_u8))
    response.status_code.should eq(Matter::Cluster::OperationalCredentials::NodeOperationalCertStatus::Ok)
    device.fabric_table.add_fabric(event_spec_fabric(1_u8, 0x2001_u64)).should be_true
    fresh = journal.record(0_u16, Matter::Cluster::AccessControl::CLUSTER_ID,
      Matter::Cluster::AccessControl::EVENT_ACCESS_CONTROL_ENTRY_CHANGED,
      :info, TLV::Any.new(44_u32, nil), fabric_index: 1_u8)

    fresh.event_number.should be > global.event_number
    journal.query(path, after: before, fabric_index: 1_u8).map(&.event_number).should eq([global.event_number, fresh.event_number])
    journal.query(path, after: before, fabric_index: 2_u8).map(&.event_number).should eq([other.event_number, global.event_number])
  ensure
    if device
      device.message_handler.close
      device.persistence.close
      device.transport.close
    end
  end
end
