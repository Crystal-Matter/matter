require "../spec_helper"
require "../../src/matter/transport/udp_transport"
require "../../src/matter/controller/client"

describe Matter::Transport::UDPTransport do
  it "uses peer idle timing for a new exchange and active timing thereafter" do
    require_udp_sockets!
    transport = Matter::Spec::CaptureTransport.new_for_spec
    peer = Socket::IPAddress.new("::1", 5540)
    transport.configure_mrp_peer(peer, 7_u16, idle_interval_ms: 4000_u32,
      active_interval_ms: 300_u32)

    transport.send_reliable_raw(Bytes[0x01], peer, 7_u16, 9_u16, 42_u32)
    transport.retransmit_due(Time.instant + 1.second)
    transport.sent_packets.size.should eq(1)
    transport.retransmit_due(Time.instant + 6.seconds)
    transport.sent_packets.size.should eq(2)
    transport.acknowledge_reliable(7_u16, 9_u16, 42_u32, peer).should be_true

    transport.send_reliable_raw(Bytes[0x02], peer, 7_u16, 9_u16, 43_u32)
    transport.retransmit_due(Time.instant + 1.second)
    transport.sent_packets.size.should eq(4)
  ensure
    transport.try(&.close)
  end

  it "uses the Matter idle default when no peer interval is advertised" do
    require_udp_sockets!
    transport = Matter::Spec::CaptureTransport.new_for_spec
    peer = Socket::IPAddress.new("::1", 5540)
    transport.send_reliable_raw(Bytes[0x01], peer, 7_u16, 9_u16, 42_u32)

    transport.retransmit_due(Time.instant + 400.milliseconds)
    transport.sent_packets.size.should eq(1)
    transport.retransmit_due(Time.instant + 700.milliseconds)
    transport.sent_packets.size.should eq(2)
  ensure
    transport.try(&.close)
  end

  it "uses the active interval when answering an exchange opened by the peer" do
    require_udp_sockets!
    transport = Matter::Spec::CaptureTransport.new_for_spec
    peer = Socket::IPAddress.new("::1", 5540)
    transport.configure_mrp_peer(peer, 7_u16, idle_interval_ms: 4000_u32,
      active_interval_ms: 300_u32)
    transport.mark_mrp_peer_active(peer, 7_u16)
    transport.send_reliable_raw(Bytes[0x01], peer, 7_u16, 9_u16, 42_u32)

    transport.retransmit_due(Time.instant + 1.second)
    transport.sent_packets.size.should eq(2)
    transport.clear_reliable_session(7_u16)
    transport.pending_reliable_count.should eq(0)
  ensure
    transport.try(&.close)
  end

  it "uses the active interval on a new exchange while the peer remains active" do
    require_udp_sockets!
    transport = Matter::Spec::CaptureTransport.new_for_spec
    peer = Socket::IPAddress.new("::1", 5540)
    transport.configure_mrp_peer(peer, 7_u16, idle_interval_ms: 4000_u32,
      active_interval_ms: 300_u32, active_threshold_ms: 4000_u16)
    transport.mark_mrp_peer_active(peer, 7_u16)
    transport.send_reliable_raw(Bytes[0x01], peer, 7_u16, 10_u16, 42_u32)

    transport.retransmit_due(Time.instant + 1.second)
    transport.sent_packets.size.should eq(2)
  ensure
    transport.try(&.close)
  end

  it "returns to the idle interval after the peer active threshold" do
    require_udp_sockets!
    transport = Matter::Spec::CaptureTransport.new_for_spec
    peer = Socket::IPAddress.new("::1", 5540)
    transport.configure_mrp_peer(peer, 7_u16, idle_interval_ms: 4000_u32,
      active_interval_ms: 300_u32, active_threshold_ms: 4000_u16)
    transport.mark_mrp_peer_active(peer, 7_u16)
    transport.retransmit_due(Time.instant + 5.seconds)
    transport.send_reliable_raw(Bytes[0x01], peer, 7_u16, 10_u16, 42_u32)

    transport.retransmit_due(Time.instant + 1.second)
    transport.sent_packets.size.should eq(1)
  ensure
    transport.try(&.close)
  end

  it "starts a newly authenticated secure session in peer active mode" do
    require_udp_sockets!
    transport = Matter::Spec::CaptureTransport.new_for_spec
    client = Matter::Controller::Client.new(transport: transport)
    peer = Socket::IPAddress.new("::1", 5540)
    session = Matter::Session::SecureContext.new(7_u16, 8_u16,
      Matter::Session::SessionType::Unicast, Bytes.new(16), Bytes.new(16))
    session.peer_mrp_idle_interval_ms = 4000_u32
    session.peer_mrp_active_interval_ms = 300_u32
    client.register_session(session, peer: peer)
    client.send_encrypted_request(session, peer,
      Matter::Controller::Client::PROTOCOL_SECURE_CHANNEL, 0x40_u8, Bytes.empty)

    transport.retransmit_due(Time.instant + 1.second)
    transport.sent_packets.size.should eq(2)
  ensure
    client.try(&.close)
    transport.try(&.close)
  end

  it "switches a pending retry to the idle interval after peer active mode expires" do
    require_udp_sockets!
    transport = Matter::Spec::CaptureTransport.new_for_spec
    peer = Socket::IPAddress.new("::1", 5540)
    transport.configure_mrp_peer(peer, 7_u16, idle_interval_ms: 4000_u32,
      active_interval_ms: 300_u32, active_threshold_ms: 100_u16)
    transport.mark_mrp_peer_active(peer, 7_u16)
    transport.send_reliable_raw(Bytes[0x01], peer, 7_u16, 9_u16, 42_u32)
    transport.retransmit_due(Time.instant + 1.second)
    transport.sent_packets.size.should eq(2)
    transport.retransmit_due(Time.instant + 2.seconds)
    transport.sent_packets.size.should eq(2)
    transport.retransmit_due(Time.instant + 7.seconds)
    transport.sent_packets.size.should eq(3)
  ensure
    transport.try(&.close)
  end

  it "evicts stale unsecured peer retry parameters" do
    require_udp_sockets!
    transport = Matter::Spec::CaptureTransport.new_for_spec
    peer = Socket::IPAddress.new("::1", 5540)
    transport.configure_mrp_peer(peer, 0_u16, idle_interval_ms: 4000_u32)
    transport.retransmit_due(Time.instant + 11.minutes)
    transport.send_reliable_raw(Bytes[0x01], peer, 0_u16, 9_u16, 42_u32)

    transport.retransmit_due(Time.instant + 700.milliseconds)
    transport.sent_packets.size.should eq(2)
  ensure
    transport.try(&.close)
  end

  it "retains long unsecured retry parameters while a reliable message is pending" do
    require_udp_sockets!
    transport = Matter::Spec::CaptureTransport.new_for_spec
    peer = Socket::IPAddress.new("::1", 5540)
    transport.configure_mrp_peer(peer, 0_u16, idle_interval_ms: 3_600_000_u32)
    transport.send_reliable_raw(Bytes[0x01], peer, 0_u16, 9_u16, 42_u32)

    transport.retransmit_due(Time.instant + 90.minutes)
    transport.sent_packets.size.should eq(2)
    transport.retransmit_due(Time.instant + 91.minutes)
    transport.sent_packets.size.should eq(2)
  ensure
    transport.try(&.close)
  end

  it "accepts a mapped IPv4 acknowledgement for an IPv4 destination" do
    transport = Matter::Spec::CaptureTransport.new_for_spec
    ipv4 = Socket::IPAddress.new("127.0.0.1", 5540)
    mapped = Socket::IPAddress.new("::ffff:127.0.0.1", 5540)
    transport.send_reliable_raw(Bytes[0x01], ipv4, 0_u16, 7_u16, 42_u32)

    transport.acknowledge_reliable(0_u16, 7_u16, 42_u32, mapped).should be_true
    transport.pending_reliable_count.should eq(0)
  ensure
    transport.try(&.close)
  end

  it "retransmits exact reliable bytes and clears them only for the matching acknowledgement" do
    require_udp_sockets!
    transport = Matter::Spec::CaptureTransport.new_for_spec
    peer = Socket::IPAddress.new("::1", 5540)
    packet = Bytes[0x01, 0x02, 0x03]
    transport.send_reliable_raw(packet, peer, 7_u16, 9_u16, 42_u32)
    packet[0] = 0xff

    transport.pending_reliable_count.should eq(1)
    transport.acknowledge_reliable(7_u16, 9_u16, 41_u32).should be_false
    transport.acknowledge_reliable(7_u16, 9_u16, 42_u32,
      Socket::IPAddress.new("::1", 5541)).should be_false
    transport.retransmit_due(Time.instant + 2.seconds)
    transport.sent_packets.map(&.[0]).should eq([Bytes[0x01, 0x02, 0x03], Bytes[0x01, 0x02, 0x03]])
    transport.acknowledge_reliable(7_u16, 9_u16, 42_u32).should be_true
    transport.retransmit_due(Time.instant + 60.seconds)
    transport.sent_packets.size.should eq(2)
    transport.close
  end

  it "bounds retries and clears retained packets on close" do
    require_udp_sockets!
    transport = Matter::Spec::CaptureTransport.new_for_spec
    peer = Socket::IPAddress.new("::1", 5540)
    transport.send_reliable_raw(Bytes[0xaa], peer, 3_u16, 4_u16, 5_u32)
    6.times { |attempt| transport.retransmit_due(Time.instant + (attempt + 1).minutes) }
    transport.sent_packets.size.should eq(1 + Matter::Transport::UDPTransport::MRP_MAX_RETRANSMISSIONS)
    transport.pending_reliable_count.should eq(0)
    transport.send_reliable_raw(Bytes[0xbb], peer, 3_u16, 4_u16, 6_u32)
    transport.close
    transport.pending_reliable_count.should eq(0)
  end
end
