require "../spec_helper"
require "../../src/matter/transport/udp_transport"

describe Matter::Transport::UDPTransport do
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
