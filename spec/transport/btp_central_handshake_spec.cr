require "../spec_helper"
require "../../src/matter/transport/btp_central_handshake"

private class HandshakeGattChannel < Matter::Transport::GattHandshakeChannel
  getter events = [] of String
  getter writes = [] of Bytes
  getter read_timeout : Time::Span?
  property response : Bytes?
  property att_mtu : Int32?
  @closed = false

  def initialize(@response : Bytes? = nil, @att_mtu : Int32? = 23)
  end

  def write(frame : Bytes) : Nil
    @events << "write"
    @writes << frame.dup
  end

  def subscribe : Nil
    @events << "subscribe"
  end

  def read(timeout_span : Time::Span) : Bytes?
    @events << "read"
    @read_timeout = timeout_span
    frame = @response
    @response = nil
    sleep(timeout_span) unless frame
    frame
  end

  def close : Nil
    @closed = true
  end

  def closed? : Bool
    @closed
  end
end

describe Matter::Transport::BtpCentralHandshake do
  it "writes the v4 request before subscribing and starts the negotiated transport" do
    response = Matter::Transport::BtpCodec.encode_handshake_response(
      Matter::Transport::BtpCodec::HandshakeResponse.new(4_u8, 40_u16, 4_u8))
    channel = HandshakeGattChannel.new(response, 103)
    transport = Matter::Transport::BtpCentralHandshake.open(channel)
    channel.events.should eq(["write", "subscribe", "read"])
    request = Matter::Transport::BtpCodec.decode_handshake_request(channel.writes.first)
    request.versions.should eq([4_u8])
    request.segment_size.should eq(100_u16)
    transport.fragment_size.should eq(40)
    transport.window_size.should eq(4)
    channel.closed?.should be_false
    transport.close
  end

  it "uses the minimum BTP segment size when ATT MTU is unknown" do
    response = Matter::Transport::BtpCodec.encode_handshake_response(
      Matter::Transport::BtpCodec::HandshakeResponse.new(4_u8, 244_u16, 5_u8))
    channel = HandshakeGattChannel.new(response, nil)
    transport = Matter::Transport::BtpCentralHandshake.open(channel)
    Matter::Transport::BtpCodec.decode_handshake_request(channel.writes.first)
      .segment_size.should eq(20_u16)
    transport.fragment_size.should eq(20)
    transport.window_size.should eq(4)
    transport.close
  end

  it "rejects a peer that selects an unsupported BTP version and closes the link" do
    response = Matter::Transport::BtpCodec.encode_handshake_response(
      Matter::Transport::BtpCodec::HandshakeResponse.new(3_u8, 20_u16, 4_u8))
    channel = HandshakeGattChannel.new(response)
    expect_raises(Matter::ProtocolError) do
      Matter::Transport::BtpCentralHandshake.open(channel)
    end
    channel.closed?.should be_true
  end

  it "times out a missing handshake response and closes the link" do
    channel = HandshakeGattChannel.new
    expect_raises(Matter::TimeoutError) do
      Matter::Transport::BtpCentralHandshake.open(channel, timeout_span: 1.millisecond)
    end
    channel.events.first(2).should eq(["write", "subscribe"])
    channel.read_timeout.should_not be_nil
    channel.closed?.should be_true
  end
end
