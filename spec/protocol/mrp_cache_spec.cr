require "../spec_helper"
require "../../src/matter/protocol/mrp_cache"

describe Matter::Protocol::MrpCache do
  peer = Socket::IPAddress.new("127.0.0.1", 5540)

  it "replays a stored response for a duplicate counter" do
    transport = Matter::Spec::CaptureTransport.new_for_spec
    cache = Matter::Protocol::MrpCache.new(transport)

    cache.store(7_u16, 42_u32, Bytes[1, 2, 3])

    cache.resend?(7_u16, 42_u32, peer).should be_true
    transport.sent_packets.size.should eq(1)
    transport.sent_packets.first[0].should eq(Bytes[1, 2, 3])
    transport.sent_packets.first[1].should eq(peer)
  end

  it "does not replay an unknown counter or another session's response" do
    transport = Matter::Spec::CaptureTransport.new_for_spec
    cache = Matter::Protocol::MrpCache.new(transport)

    cache.store(7_u16, 42_u32, Bytes[1])

    cache.resend?(7_u16, 43_u32, peer).should be_false
    cache.resend?(8_u16, 42_u32, peer).should be_false
    transport.sent_packets.should be_empty
  end

  it "expires entries after the response TTL" do
    transport = Matter::Spec::CaptureTransport.new_for_spec
    cache = Matter::Protocol::MrpCache.new(transport)

    cache.store(7_u16, 42_u32, Bytes[1])

    Timecop.travel(Time.utc + Matter::Protocol::MrpCache::RESPONSE_TTL + 1.second) do
      cache.resend?(7_u16, 42_u32, peer).should be_false
    end
    transport.sent_packets.should be_empty
  end

  it "forgets every response of a removed session" do
    transport = Matter::Spec::CaptureTransport.new_for_spec
    cache = Matter::Protocol::MrpCache.new(transport)

    cache.store(7_u16, 1_u32, Bytes[1])
    cache.store(7_u16, 2_u32, Bytes[2])
    cache.store(9_u16, 1_u32, Bytes[3])

    cache.clear_session(7_u16)

    cache.size.should eq(1)
    cache.resend?(9_u16, 1_u32, peer).should be_true
  end

  it "drops outbound retransmissions when a session is removed" do
    transport = Matter::Spec::CaptureTransport.new_for_spec
    cache = Matter::Protocol::MrpCache.new(transport)
    transport.send_reliable_raw(Bytes[1], peer, 7_u16, 1_u16, 1_u32)
    transport.send_reliable_raw(Bytes[2], peer, 8_u16, 1_u16, 1_u32)

    cache.clear_session(7_u16)

    transport.pending_reliable_count.should eq(1)
    transport.acknowledge_reliable(7_u16, 1_u16, 1_u32).should be_false
    transport.acknowledge_reliable(8_u16, 1_u16, 1_u32).should be_true
  end

  it "keeps at most MAX_ENTRIES responses, dropping the oldest" do
    transport = Matter::Spec::CaptureTransport.new_for_spec
    cache = Matter::Protocol::MrpCache.new(transport)

    overflow = Matter::Protocol::MrpCache::MAX_ENTRIES + 10
    overflow.times { |index| cache.store(1_u16, index.to_u32, Bytes[index.to_u8!]) }

    cache.size.should eq(Matter::Protocol::MrpCache::MAX_ENTRIES)
    cache.resend?(1_u16, 0_u32, peer).should be_false
    cache.resend?(1_u16, (overflow - 1).to_u32, peer).should be_true
  end
end
