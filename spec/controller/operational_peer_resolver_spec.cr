require "../spec_helper"
require "../../src/matter/controller"

private alias Resolver = Matter::Controller::OperationalPeerResolver

private class StubOperationalResolver < Resolver
  property advertised = nil.as(Socket::IPAddress?)
  getter requested_identity = nil.as(Tuple(UInt64, UInt64)?)

  protected def discover(compressed_fabric_id : UInt64, node_id : UInt64,
                         timeout : Time::Span) : Socket::IPAddress?
    @requested_identity = {compressed_fabric_id, node_id}
    @advertised
  end
end

private class StubDiscoveredCasePairing < Matter::Controller::Pairing::CasePairing
  getter paired_peer = nil.as(Socket::IPAddress?)
  property? fail_pairing = false

  def pair(client : Matter::Controller::Client, peer : Socket::IPAddress,
           fabric : Matter::Controller::FabricInfo, peer_node_id : UInt64,
           timeout : Time::Span = 10.seconds) : Matter::Session::SecureContext
    @paired_peer = peer
    client.transport.message_counter.next
    raise Matter::AuthenticationError.new("CASE peer did not authenticate") if fail_pairing?
    Matter::Session::SecureContext.new(session_id: 1_u16, peer_session_id: 1_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16), decryption_key: Bytes.new(16))
  end
end

private def operational_test_fabric : Matter::Controller::FabricInfo
  Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
    0x1234_u64, 0x100_u64, 0xFFF1_u16).fabric
end

private def operational_test_device(compressed_fabric_id : UInt64, node_id : UInt64,
                                    address : String) : Matter::Controller::DiscoveredDevice
  instance = "#{compressed_fabric_id.to_s(16).rjust(16, '0')}-#{node_id.to_s(16).rjust(16, '0')}._matter._tcp.local"
  Matter::Controller::DiscoveredDevice.new(instance, "peer.local",
    [Socket::IPAddress.new(address, 5540)], 5540,
    ({} of String => String), Matter::MDNS::ServiceType::Operational,
    Time.utc + 1.minute)
end

describe Matter::Controller::OperationalPeerResolver do
  it "reads bounded operational SII, SAI and SAT values" do
    fabric = operational_test_fabric
    device = operational_test_device(fabric.compressed_fabric_id, 0x200_u64, "192.0.2.2")
    device.txt_records["SII"] = "4000"
    device.txt_records["SAI"] = "300"
    device.txt_records["SAT"] = "5000"
    Resolver.mrp_parameters(device).should eq({4000_u32, 300_u32, 5000_u16})
    device.txt_records["SII"] = "0"
    device.txt_records["SAI"] = "invalid"
    device.txt_records["SAT"] = "65536"
    Resolver.mrp_parameters(device).should eq({nil, nil, nil})
    device.txt_records["SII"] = "3600001"
    device.txt_records["SAI"] = "4294967295"
    Resolver.mrp_parameters(device).should eq({nil, nil, nil})
  end

  it "matches both compressed fabric identity and node ID" do
    fabric = operational_test_fabric
    target = operational_test_device(fabric.compressed_fabric_id, 0x200_u64, "192.0.2.2")
    wrong_fabric = operational_test_device(fabric.compressed_fabric_id ^ 1_u64, 0x200_u64, "192.0.2.3")
    wrong_node = operational_test_device(fabric.compressed_fabric_id, 0x201_u64, "192.0.2.4")

    Resolver.select_peer([wrong_fabric, wrong_node, target],
      fabric.compressed_fabric_id, 0x200_u64).should eq(Socket::IPAddress.new("192.0.2.2", 5540))
    Resolver.select_peer([wrong_fabric, wrong_node],
      fabric.compressed_fabric_id, 0x200_u64).should be_nil

    empty_target = Matter::Controller::DiscoveredDevice.new(target.instance_name,
      target.hostname, [] of Socket::IPAddress, target.port,
      ({} of String => String), Matter::MDNS::ServiceType::Operational,
      Time.utc + 1.minute)
    Resolver.select_peer([empty_target, target], fabric.compressed_fabric_id,
      0x200_u64).should eq(Socket::IPAddress.new("192.0.2.2", 5540))

    dual_stack = Matter::Controller::DiscoveredDevice.new(target.instance_name,
      target.hostname,
      [Socket::IPAddress.new("192.0.2.2", 5540), Socket::IPAddress.new("2001:db8::2", 5540)],
      target.port, ({} of String => String), Matter::MDNS::ServiceType::Operational,
      Time.utc + 1.minute)
    Resolver.select_peer([dual_stack], fabric.compressed_fabric_id,
      0x200_u64).should eq(Socket::IPAddress.new("2001:db8::2", 5540))

    scoped = Matter::Controller::DiscoveredDevice.new(target.instance_name,
      target.hostname, [Socket::IPAddress.new("fe80::2%1", 0)], target.port,
      ({} of String => String), Matter::MDNS::ServiceType::Operational,
      Time.utc + 1.minute)
    selected = Resolver.select_peer([scoped], fabric.compressed_fabric_id, 0x200_u64)
    selected.should eq(Socket::IPAddress.new("fe80::2%1", 5540))
    selected.try(&.zone_id).should eq(1)
  end

  it "prefers a fresh operational advertisement over a saved IP" do
    fabric = operational_test_fabric
    state = Matter::Controller::State.new(fabric: fabric)
    state.record_node(fabric.fabric_id,
      Matter::Controller::NodeInfo.new(0x200_u64, "192.0.2.1"),
      fabric.root_public_key, fabric.controller_node_id)
    resolver = StubOperationalResolver.new
    resolver.advertised = Socket::IPAddress.new("192.0.2.2", 5540)

    resolver.resolve(state, fabric, 0x200_u64, 50.milliseconds)
      .should eq(Socket::IPAddress.new("192.0.2.2", 5540))
    resolver.requested_identity.should eq({fabric.compressed_fabric_id, 0x200_u64})
  end

  it "uses a saved address only after operational discovery yields none" do
    fabric = operational_test_fabric
    state = Matter::Controller::State.new(fabric: fabric)
    state.record_node(fabric.fabric_id,
      Matter::Controller::NodeInfo.new(0x200_u64, "192.0.2.1"),
      fabric.root_public_key, fabric.controller_node_id)
    resolver = StubOperationalResolver.new

    resolver.resolve(state, fabric, 0x200_u64, 50.milliseconds)
      .should eq(Socket::IPAddress.new("192.0.2.1", 5540))
  end

  it "saves the new address only after CASE authenticates the operational peer" do
    fabric = operational_test_fabric
    store = Matter::Controller::StateStore.new(Matter::Storage::Memory.new)
    state = Matter::Controller::State.new(fabric: fabric)
    state.record_node(fabric.fabric_id,
      Matter::Controller::NodeInfo.new(0x200_u64, "192.0.2.1"),
      fabric.root_public_key, fabric.controller_node_id)
    store.save(state)
    resolver = StubOperationalResolver.new
    resolver.advertised = Socket::IPAddress.new("192.0.2.2", 5540)
    pairing = StubDiscoveredCasePairing.new
    client = Matter::Controller::Client.new

    session, peer = pairing.pair_discovered(client, store, 0x200_u64,
      resolver: resolver, timeout: 50.milliseconds)
    session.should be_a(Matter::Session::SecureContext)
    peer.should eq(Socket::IPAddress.new("192.0.2.2", 5540))
    pairing.paired_peer.should eq(peer)
    store.load.nodes_for(fabric.fabric_id, fabric.root_public_key,
      fabric.controller_node_id)[0x200_u64].address.should eq("192.0.2.2")
    # The random, ephemeral Client source must not advance the durable
    # watermark reserved for a fixed operational source.
    store.load.unsecured_message_counter.should eq(0_u32)
  ensure
    client.try(&.close)
  end

  it "persists the scoped address of an authenticated link-local peer" do
    fabric = operational_test_fabric
    store = Matter::Controller::StateStore.new(Matter::Storage::Memory.new)
    store.save(Matter::Controller::State.new(fabric: fabric))
    resolver = StubOperationalResolver.new
    resolver.advertised = Socket::IPAddress.new("fe80::2%1", 5540)
    pairing = StubDiscoveredCasePairing.new
    client = Matter::Controller::Client.new

    _session, peer = pairing.pair_discovered(client, store, 0x200_u64,
      resolver: resolver, timeout: 50.milliseconds)
    peer.zone_id.should eq(1)
    saved = store.load.nodes_for(fabric.fabric_id, fabric.root_public_key,
      fabric.controller_node_id)[0x200_u64]
    saved.address.should eq("fe80::2%1")
    StubOperationalResolver.new.resolve(store.load, fabric, 0x200_u64,
      timeout: 0.milliseconds).zone_id.should eq(1)
  ensure
    client.try(&.close)
  end

  it "keeps the saved address when CASE rejects a discovered peer" do
    fabric = operational_test_fabric
    store = Matter::Controller::StateStore.new(Matter::Storage::Memory.new)
    state = Matter::Controller::State.new(fabric: fabric)
    state.record_node(fabric.fabric_id,
      Matter::Controller::NodeInfo.new(0x200_u64, "192.0.2.1"),
      fabric.root_public_key, fabric.controller_node_id)
    store.save(state)
    resolver = StubOperationalResolver.new
    resolver.advertised = Socket::IPAddress.new("192.0.2.2", 5540)
    pairing = StubDiscoveredCasePairing.new
    pairing.fail_pairing = true
    client = Matter::Controller::Client.new

    expect_raises(Matter::AuthenticationError, /did not authenticate/) do
      pairing.pair_discovered(client, store, 0x200_u64,
        resolver: resolver, timeout: 50.milliseconds)
    end
    store.load.nodes_for(fabric.fabric_id, fabric.root_public_key,
      fabric.controller_node_id)[0x200_u64].address.should eq("192.0.2.1")
    store.load.unsecured_message_counter.should eq(0_u32)
  ensure
    client.try(&.close)
  end
end
