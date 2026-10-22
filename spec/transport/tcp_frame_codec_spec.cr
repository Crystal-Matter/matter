require "../spec_helper"

private alias FrameCodec = Matter::Transport::TcpFrameCodec

describe Matter::Transport::TcpFrameCodec do
  it "writes the Matter TCP four-byte little-endian length before a 3000-byte message" do
    message = Bytes.new(3000, 0xab_u8)
    frame = FrameCodec.encode(message, 4096)

    frame.size.should eq(3004)
    frame[0, 4].should eq(Bytes[0xb8, 0x0b, 0x00, 0x00])
    frame[4, message.size].should eq(message)
  end

  it "waits for a fragmented length prefix and body" do
    codec = FrameCodec.new(4096)
    message = Bytes.new(3000, 0xcd_u8)
    frame = FrameCodec.encode(message, 4096)

    codec.feed(frame[0, 2]).should be_empty
    codec.feed(frame[2, 3]).should be_empty
    codec.feed(frame[5, 1000]).should be_empty
    codec.feed(frame[1005, frame.size - 1005]).should eq([message])
  end

  it "yields every complete message from coalesced frames" do
    codec = FrameCodec.new(4096)
    first = Bytes[1, 2, 3]
    second = Bytes.new(3000, 0xef_u8)
    first_frame = FrameCodec.encode(first, 4096)
    second_frame = FrameCodec.encode(second, 4096)
    wire = Bytes.new(first_frame.size + second_frame.size)
    wire[0, first_frame.size].copy_from(first_frame)
    wire[first_frame.size, second_frame.size].copy_from(second_frame)

    codec.feed(wire).should eq([first, second])
  end

  it "accepts a message exactly at the negotiated limit" do
    message = Bytes.new(4096, 0x01_u8)
    codec = FrameCodec.new(4096)

    codec.feed(FrameCodec.encode(message, 4096)).should eq([message])
  end

  it "rejects zero-length and oversized receive frames as soon as the prefix arrives" do
    [Bytes[0, 0, 0, 0], Bytes[0x01, 0x10, 0, 0]].each do |prefix|
      codec = FrameCodec.new(4096)
      expect_raises(Matter::ProtocolError) { codec.feed(prefix) }
      codec.failed?.should be_true
      expect_raises(Matter::ProtocolError) { codec.feed(Bytes[1]) }
    end
  end

  it "rejects invalid send lengths and a nonpositive receive limit" do
    expect_raises(Matter::ConfigurationError) { FrameCodec.new(0) }
    expect_raises(Matter::ProtocolError) { FrameCodec.encode(Bytes.empty, 4096) }
    expect_raises(Matter::ProtocolError) { FrameCodec.encode(Bytes.new(4097, 0_u8), 4096) }
  end
end
