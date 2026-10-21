require "../spec_helper"

private alias Codec = Matter::Codec::MessageCodec

describe Matter::Codec::MessageCodec do
  it "encodes/decodes packet and payload header into a message" do
    source_node_id = Matter::DataType::NodeId.new(1_u64)
    # Compute flags with HasSourceNodeId flag set

    packet_header = Matter::Codec::MessageCodec::PacketHeader.new(session_id: 1_u16, session_type: Matter::Codec::MessageCodec::SessionType::Group, message_id: 1_u32, privacy_enhancements: false, control_message: false, message_extensions: false, source_node_id: source_node_id)
    payload_header = Matter::Codec::MessageCodec::PayloadHeader.new(exchange_id: 1234_u16, protocol_id: 1_u16, message_type: 2_u8, initiator_message: false, requires_acknowledge: false, acknowledged_message_id: 3123_u32)

    message = Matter::Codec::MessageCodec::Message.new(packet_header: packet_header, payload_header: payload_header, payload: Slice[1_u8, 2_u8, 3_u8, 4_u8, 5_u8])

    payload_encoded_packet = Matter::Codec::MessageCodec::Base.encode_payload(message)
    second_message = Matter::Codec::MessageCodec::Base.decode_payload(payload_encoded_packet)

    payload_header.exchange_id.should eq second_message.payload_header.exchange_id
    payload_header.protocol_id.should eq second_message.payload_header.protocol_id
    payload_header.message_type.should eq second_message.payload_header.message_type
    payload_header.initiator_message?.should eq second_message.payload_header.initiator_message?
    payload_header.requires_acknowledge?.should eq second_message.payload_header.requires_acknowledge?
    payload_header.acknowledged_message_id.should eq second_message.payload_header.acknowledged_message_id
  end

  it "decodes and re-encodes opaque packet and secured extensions" do
    packet_bytes = Bytes[
      0x00, 0x01, 0x00, 0x20, 0x04, 0x03, 0x02, 0x01,
      0x03, 0x00, 0xAA, 0xBB, 0xCC,
      0x0B, 0x05, 0x34, 0x12, 0x01, 0x00, 0x78, 0x56, 0x34, 0x12,
      0x02, 0x00, 0xDE, 0xAD, 0xEF,
    ]
    packet = Codec::Base.decode_packet(packet_bytes)
    packet.header.message_extensions?.should be_true
    packet.header.message_extension_data.should eq(Bytes[0xAA, 0xBB, 0xCC])
    packet.header_bytes.should eq(packet_bytes[0, 13])
    message = Codec::Base.decode_payload(packet)
    message.payload_header.secured_extensions.should eq(Bytes[0xDE, 0xAD])
    message.payload.should eq(Bytes[0xEF])
    Codec::Base.encode_packet(Codec::Base.encode_payload(message)).should eq(packet_bytes)
  end

  it "rejects extension lengths that exceed the received bytes" do
    packet = Bytes[0x00, 0x01, 0x00, 0x20, 0x04, 0x03, 0x02, 0x01,
      0x03, 0x00, 0xAA]
    expect_raises(Matter::CodecError, /Message extension/) { Codec::Base.decode_packet(packet) }

    header = Codec::PacketHeader.new(1_u16, Codec::SessionType::Unicast, 1_u32)
    payload = Bytes[0x08, 0x05, 0x34, 0x12, 0x01, 0x00, 0x02, 0x00, 0xAA]
    expect_raises(Matter::CodecError, /Secured extension/) do
      Codec::Base.decode_payload(Codec::Packet.new(header, payload))
    end
  end

  it "refuses extension payloads too large for a 16-bit wire length" do
    oversized = Bytes.new(UInt16::MAX.to_i + 1)
    packet_header = Codec::PacketHeader.new(1_u16, Codec::SessionType::Unicast, 1_u32,
      message_extension_data: oversized)
    expect_raises(Matter::CodecError, /Message extension/) do
      Codec::Base.encode_packet_header(packet_header)
    end

    payload_header = Codec::PayloadHeader.new(1_u16, 1_u16, 1_u8, true, false,
      secured_extensions: oversized)
    expect_raises(Matter::CodecError, /Secured extension/) do
      Codec::Base.encode_payload(Codec::Message.new(packet_header, payload_header, Bytes.empty))
    end
  end

  it "round-trips vendor and protocol IDs as separate little-endian fields" do
    header = Codec::PacketHeader.new(1_u16, Codec::SessionType::Unicast, 1_u32)
    payload_header = Codec::PayloadHeader.new(1_u16, 0x1234_5678_u32, 2_u8, true, false)
    message = Codec::Message.new(header, payload_header, Bytes[0xAA])
    encoded = Codec::Base.encode_payload(message)
    encoded.payload.should eq(Bytes[0x11, 0x02, 0x01, 0x00, 0x34, 0x12, 0x78, 0x56, 0xAA])
    decoded = Codec::Base.decode_payload(encoded)
    decoded.payload_header.protocol_id.should eq(0x1234_5678_u32)
    decoded.payload.should eq(Bytes[0xAA])
  end
end
