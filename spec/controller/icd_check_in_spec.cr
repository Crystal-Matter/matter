require "../spec_helper"
require "../../src/matter/controller/icd_client"

private alias ControllerIcd = Matter::Controller::IcdClient
private alias IcdStore = Matter::Controller::IcdPeerStore

private def controller_icd_peer(key : Bytes, root : Bytes = Bytes.new(65, 0x42_u8),
                                counter : UInt32 = 100_u32) : IcdStore::Record
  IcdStore::Record.new(0x1111_u64, root, 0x2222_u64, 0x3333_u64,
    key, counter, counter)
end

describe ControllerIcd do
  it "authenticates a Check-In, persists its counter, and never delivers a replay" do
    backend = Matter::Storage::Memory.new
    store = IcdStore.new(backend)
    key = Bytes.new(16, 0x51_u8)
    store.save(controller_icd_peer(key))
    client = Matter::Controller::Client.new(port: 0)
    icd = ControllerIcd.new(client, store)
    received = [] of ControllerIcd::CheckIn
    icd.on_check_in = ->(check_in : ControllerIcd::CheckIn) { received << check_in; nil }
    peer = Socket::IPAddress.new("::1", 5540)
    payload = Matter::Protocol::Icd::CheckInMessage.encode_icd(key, 101_u32, 5_000_u16)

    icd.accept_check_in(payload, peer).should be_true
    received.size.should eq(1)
    received.first.device_node_id.should eq(0x3333_u64)
    received.first.active_mode_threshold.should eq(5_000_u16)
    IcdStore.new(backend).find_peer(0x1111_u64, Bytes.new(65, 0x42_u8),
      0x2222_u64, 0x3333_u64).as(IcdStore::Record).last_counter.should eq(101_u32)
    icd.accept_check_in(payload, peer).should be_true
    received.size.should eq(1)
    icd.accept_check_in(Matter::Protocol::Icd::CheckInMessage.encode_icd(
      Bytes.new(16, 0x52_u8), 102_u32, 5_000_u16), peer).should be_false
  ensure
    icd.try(&.close)
    client.try(&.close)
  end

  it "promotes a pending registration key only after an authenticated Check-In" do
    backend = Matter::Storage::Memory.new
    store = IcdStore.new(backend)
    old_key = Bytes.new(16, 0x61_u8)
    new_key = Bytes.new(16, 0x62_u8)
    store.save(IcdStore::Record.new(0x1111_u64, Bytes.new(65, 0x42_u8),
      0x2222_u64, 0x3333_u64, old_key, 100_u32, 101_u32, new_key))
    client = Matter::Controller::Client.new(port: 0)
    icd = ControllerIcd.new(client, store)
    peer = Socket::IPAddress.new("::1", 5540)
    icd.accept_check_in(Matter::Protocol::Icd::CheckInMessage.encode_icd(
      new_key, 102_u32, 1_000_u16), peer).should be_true
    saved = IcdStore.new(backend).find_peer(0x1111_u64,
      Bytes.new(65, 0x42_u8), 0x2222_u64, 0x3333_u64).as(IcdStore::Record)
    saved.key.should eq(new_key)
    saved.pending_key.should be_nil
    saved.last_counter.should eq(102_u32)
    icd.accept_check_in(Matter::Protocol::Icd::CheckInMessage.encode_icd(
      old_key, 103_u32, 1_000_u16), peer).should be_false
  ensure
    icd.try(&.close)
    client.try(&.close)
  end

  it "accepts a fresh counter past the key-refresh boundary and signals rotation" do
    backend = Matter::Storage::Memory.new
    store = IcdStore.new(backend)
    key = Bytes.new(16, 0x73_u8)
    store.save(controller_icd_peer(key))
    client = Matter::Controller::Client.new(port: 0)
    icd = ControllerIcd.new(client, store)
    received = [] of ControllerIcd::CheckIn
    icd.on_check_in = ->(check_in : ControllerIcd::CheckIn) { received << check_in; nil }
    counter = 0x8000_0080_u32
    icd.accept_check_in(Matter::Protocol::Icd::CheckInMessage.encode_icd(
      key, counter, 500_u16), Socket::IPAddress.new("::1", 5540)).should be_true
    received.size.should eq(1)
    received.first.needs_key_refresh.should be_true
    received.first.counter.should eq(counter)
  ensure
    icd.try(&.close)
    client.try(&.close)
  end

  it "authenticates an official CHIP SDK Check-In vector with trailing application data" do
    # CHIP SDK CheckIn_Message_test_vectors.h vector 2, also exercised by
    # matter.js CheckInMessageTest.ts. The first two application bytes carry
    # ActiveModeThreshold; trailing bytes are permitted by the codec.
    key = "18fdbceaef01955b0ec875eda3ae6ee8".hexbytes
    payload = "9b02ed21ee0c7b491985502e372dbd7b3f8b4f8e3c5ad99419389f41a8d609938c67a86d65".hexbytes
    store = IcdStore.new(Matter::Storage::Memory.new)
    store.save(controller_icd_peer(key, counter: 14_u32))
    client = Matter::Controller::Client.new(port: 0)
    icd = ControllerIcd.new(client, store)
    received = [] of ControllerIcd::CheckIn
    icd.on_check_in = ->(check_in : ControllerIcd::CheckIn) { received << check_in; nil }
    icd.accept_check_in(payload, Socket::IPAddress.new("::1", 5540)).should be_true
    received.size.should eq(1)
    received.first.counter.should eq(15_u32)
    received.first.active_mode_threshold.should eq(0x6854_u16)
  ensure
    icd.try(&.close)
    client.try(&.close)
  end

  it "consumes a counter before a failing application callback" do
    backend = Matter::Storage::Memory.new
    store = IcdStore.new(backend)
    key = Bytes.new(16, 0x83_u8)
    store.save(controller_icd_peer(key))
    client = Matter::Controller::Client.new(port: 0)
    icd = ControllerIcd.new(client, store)
    calls = 0
    icd.on_check_in = ->(_check_in : ControllerIcd::CheckIn) do
      calls += 1
      raise "application error"
    end
    peer = Socket::IPAddress.new("::1", 5540)
    payload = Matter::Protocol::Icd::CheckInMessage.encode_icd(key, 101_u32, 500_u16)
    icd.accept_check_in(payload, peer).should be_true
    icd.accept_check_in(payload, peer).should be_true
    calls.should eq(1)
    IcdStore.new(backend).find_peer(0x1111_u64, Bytes.new(65, 0x42_u8),
      0x2222_u64, 0x3333_u64).as(IcdStore::Record).last_counter.should eq(101_u32)
  ensure
    icd.try(&.close)
    client.try(&.close)
  end

  it "does not promote a pending key using a replayed counter" do
    store = IcdStore.new(Matter::Storage::Memory.new)
    old_key = Bytes.new(16, 0x94_u8)
    new_key = Bytes.new(16, 0x95_u8)
    store.save(IcdStore::Record.new(0x1111_u64, Bytes.new(65, 0x42_u8),
      0x2222_u64, 0x3333_u64, old_key, 10_u32, 15_u32, new_key))
    client = Matter::Controller::Client.new(port: 0)
    icd = ControllerIcd.new(client, store)
    peer = Socket::IPAddress.new("::1", 5540)
    icd.accept_check_in(Matter::Protocol::Icd::CheckInMessage.encode_icd(
      new_key, 12_u32, 500_u16), peer).should be_true
    saved = store.find_peer(0x1111_u64, Bytes.new(65, 0x42_u8),
      0x2222_u64, 0x3333_u64).as(IcdStore::Record)
    saved.key.should eq(old_key)
    saved.pending_key.should eq(new_key)
    saved.last_counter.should eq(15_u32)
  ensure
    icd.try(&.close)
    client.try(&.close)
  end

  it "does not promote a pending key before the acknowledged registration counter" do
    store = IcdStore.new(Matter::Storage::Memory.new)
    old_key = Bytes.new(16, 0x96_u8)
    new_key = Bytes.new(16, 0x97_u8)
    store.save(IcdStore::Record.new(0x1111_u64, Bytes.new(65, 0x42_u8),
      0x2222_u64, 0x3333_u64, old_key, 10_u32, 30_u32,
      new_key, 52_u32))
    client = Matter::Controller::Client.new(port: 0)
    icd = ControllerIcd.new(client, store)
    peer = Socket::IPAddress.new("::1", 5540)
    icd.accept_check_in(Matter::Protocol::Icd::CheckInMessage.encode_icd(
      new_key, 51_u32, 500_u16), peer).should be_true
    saved = store.find_peer(0x1111_u64, Bytes.new(65, 0x42_u8),
      0x2222_u64, 0x3333_u64).as(IcdStore::Record)
    saved.key.should eq(old_key)
    saved.pending_key.should eq(new_key)
    saved.last_counter.should eq(30_u32)
  ensure
    icd.try(&.close)
    client.try(&.close)
  end
end
