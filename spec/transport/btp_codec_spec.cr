require "../spec_helper"

private alias Btp = Matter::Transport::BtpCodec

describe Matter::Transport::BtpCodec do
  it "encodes the Matter.js BTP v4 handshake request vector" do
    request = Btp::HandshakeRequest.new([4_u8], 185_u16, 6_u8)
    Btp.encode_handshake_request(request).hexstring.should eq("656c04000000b90006")
    Btp.decode_handshake_request("656c04000000b90006".hexbytes).should eq(request)
  end

  it "preserves the low-nibble-first order of supported versions" do
    request = Btp::HandshakeRequest.new([4_u8, 5_u8, 6_u8], 185_u16, 6_u8)
    Btp.encode_handshake_request(request).hexstring.should eq("656c54060000b90006")
    Btp.decode_handshake_request("656c54060000b90006".hexbytes).should eq(request)
  end

  it "encodes and decodes the BTP v4 handshake response" do
    response = Btp::HandshakeResponse.new(4_u8, 256_u16, 6_u8)
    Btp.encode_handshake_response(response).hexstring.should eq("656c04000106")
    Btp.decode_handshake_response("656c04000106".hexbytes).should eq(response)
  end

  it "encodes a single segment with a piggyback ACK" do
    packet = Btp::Packet.new(Btp::Flags::Begin | Btp::Flags::End | Btp::Flags::Ack,
      0_u8, 0_u8, 4_u16, "01020304".hexbytes)
    Btp.encode_packet(packet).hexstring.should eq("0d0000040001020304")
    Btp.decode_packet("0d0000040001020304".hexbytes).should eq(packet)
  end

  it "decodes and re-encodes the Matter.js complete-message vector" do
    wire = "0d000044000400000049b6a902a9a5773dbb8cafd90120a7c7000015300120cb0c120a3499327ddaec4ebe60889df0f1bf80d8a4dea1dd6ffef16ef58ecafe25028e17240300280418".hexbytes
    packet = Btp.decode_packet(wire)
    packet.flags.should eq(Btp::Flags::Begin | Btp::Flags::End | Btp::Flags::Ack)
    packet.message_length.should eq(68_u16)
    packet.payload.size.should eq(68)
    Btp.encode_packet(packet).should eq(wire)
  end

  it "encodes continuation and ACK-only packets" do
    continuation = Btp::Packet.new(Btp::Flags::Continue | Btp::Flags::End,
      2_u8, nil, nil, Bytes[0xaa, 0xbb])
    Btp.encode_packet(continuation).hexstring.should eq("0602aabb")
    Btp.decode_packet("0602aabb".hexbytes).should eq(continuation)

    ack = Btp::Packet.new(Btp::Flags::Ack, 3_u8, 2_u8, nil, Bytes.empty)
    Btp.encode_packet(ack).hexstring.should eq("080203")
    Btp.decode_packet("080203".hexbytes).should eq(ack)
  end

  it "rejects malformed handshakes and unsupported negotiation values" do
    expect_raises(Matter::CodecError) { Btp.decode_handshake_request("656c00000000b90006".hexbytes) }
    expect_raises(Matter::CodecError) { Btp.decode_handshake_response("656c04f400".hexbytes) }
    expect_raises(Matter::CodecError) { Btp.decode_handshake_response("656c04000000".hexbytes) }
    expect_raises(Matter::CodecError) { Btp.encode_handshake_request(Btp::HandshakeRequest.new([4_u8], 19_u16, 6_u8)) }
    expect_raises(Matter::CodecError) { Btp.encode_handshake_response(Btp::HandshakeResponse.new(4_u8, 23_u16, 0_u8)) }
  end

  it "rejects truncated, reserved, and inconsistent packet frames" do
    expect_raises(Matter::CodecError) { Btp.decode_packet(Bytes[0x0d, 0x00]) }
    expect_raises(Matter::CodecError) { Btp.decode_packet(Bytes[0x20, 0x00]) }
    expect_raises(Matter::CodecError) { Btp.decode_packet(Bytes[0x03, 0x00, 0x01, 0x00, 0xaa]) }
    expect_raises(Matter::CodecError) { Btp.decode_packet(Bytes[0x04, 0x00, 0xaa]) }
    expect_raises(Matter::CodecError) { Btp.decode_packet(Bytes[0x05, 0x00, 0x02, 0x00, 0xaa]) }
    expect_raises(Matter::CodecError) { Btp.encode_packet(Btp::Packet.new(Btp::Flags::Ack, 0_u8, nil, nil, Bytes.empty)) }
  end
end
