require "../spec_helper"
require "../../src/matter/controller/icd_peer_store"

private alias IcdStore = Matter::Controller::IcdPeerStore

private def icd_peer_record(key : Bytes = Bytes.new(16, 0x41_u8),
                            fabric_id : UInt64 = 0x1111_u64,
                            root : Bytes = Bytes.new(65, 0x42_u8),
                            controller_node : UInt64 = 0x2222_u64,
                            device_node : UInt64 = 0x3333_u64) : IcdStore::Record
  IcdStore::Record.new(fabric_id, root, controller_node, device_node, key,
    100_u32, 100_u32)
end

describe IcdStore do
  it "persists authenticated peer keys and replay counters across restart" do
    backend = Matter::Storage::Memory.new
    store = IcdStore.new(backend)
    record = icd_peer_record
    store.save(record)
    restarted = IcdStore.new(backend)
    loaded = restarted.find_peer(record.fabric_id, record.root_public_key,
      record.controller_node_id, record.device_node_id)
    loaded.should_not be_nil
    loaded.as(IcdStore::Record).key.should eq(record.key)
    loaded.as(IcdStore::Record).last_counter.should eq(100_u32)
  end

  it "scopes identical node IDs to the fabric root and removes only one fabric" do
    backend = Matter::Storage::Memory.new
    store = IcdStore.new(backend)
    first = icd_peer_record
    second = icd_peer_record(Bytes.new(16, 0x43_u8), root: Bytes.new(65, 0x44_u8))
    store.save(first)
    store.save(second)
    store.remove_fabric(first.fabric_id, first.root_public_key, first.controller_node_id)
    store.find_peer(first.fabric_id, first.root_public_key,
      first.controller_node_id, first.device_node_id).should be_nil
    store.find_peer(second.fabric_id, second.root_public_key,
      second.controller_node_id, second.device_node_id).should_not be_nil
  end

  it "rejects a Check-In key assigned to a different peer" do
    store = IcdStore.new(Matter::Storage::Memory.new)
    first = icd_peer_record
    store.save(first)
    expect_raises(Matter::ConfigurationError) do
      store.save(icd_peer_record(device_node: 0x4444_u64))
    end
    store.records.size.should eq(1)
  end

  it "bounds the number of persistent trial-decryption keys" do
    store = IcdStore.new(Matter::Storage::Memory.new)
    IcdStore::MAX_RECORDS.times do |index|
      key = Bytes.new(IcdStore::KEY_LENGTH)
      IO::ByteFormat::LittleEndian.encode(index.to_u32, key[0, 4])
      store.save(icd_peer_record(key, device_node: 0x3333_u64 + index.to_u64))
    end
    expect_raises(Matter::ConfigurationError) do
      store.save(icd_peer_record(Bytes.new(16, 0xFF_u8), device_node: 0x9999_u64))
    end
    store.records.size.should eq(IcdStore::MAX_RECORDS)
  end
end
