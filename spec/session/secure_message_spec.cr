require "../spec_helper"

private def wire_session
  Matter::Session::SecureContext.new(
    session_id: 1_u16, peer_session_id: 1_u16,
    session_type: Matter::Session::SessionType::Unicast,
    encryption_key: Bytes.new(16, 7_u8), decryption_key: Bytes.new(16, 7_u8)
  )
end

private def wire_payload_header
  Matter::Codec::MessageCodec::PayloadHeader.new(
    exchange_id: 1_u16, protocol_id: 1_u16, message_type: 1_u8,
    initiator_message: true, requires_acknowledge: false
  )
end

describe Matter::Session::SecureMessage do
  it "authenticates optional source and destination node ids" do
    session = wire_session
    encoded, counter = Matter::Session::SecureMessage.encode(session, wire_payload_header, Bytes[1, 2],
      source_node_id: Matter::DataType::NodeId.new(10_u64),
      destination_node_id: Matter::DataType::NodeId.new(20_u64), message_counter: 9_u32)
    packet = Matter::Codec::MessageCodec::Base.decode_packet(encoded)
    packet.header.message_id.should eq(counter)
    packet.header.source_node_id.should eq(Matter::DataType::NodeId.new(10_u64))
    packet.header.destination_node_id.should eq(Matter::DataType::NodeId.new(20_u64))
    Matter::Session::SecureMessage.decode(session, packet).payload.should eq(Bytes[1, 2])
  end

  it "uses the unspecified PASE nonce identity even when temporary header and session node ids exist" do
    session = wire_session
    temporary_id = Matter::DataType::NodeId.new(0xFFFFFFFB00000001_u64)
    session.local_node_id = temporary_id
    session.peer_node_id = temporary_id
    encoded, counter = Matter::Session::SecureMessage.encode(session, wire_payload_header, Bytes[1], source_node_id: temporary_id)
    packet = Matter::Codec::MessageCodec::Base.decode_packet(encoded)
    aad = packet.header_bytes.as(Bytes)
    nonce = Matter::Session::SecureMessage.build_nonce(Matter::DataType::NodeId::UNSPECIFIED, counter, packet.header.security_flags)
    plaintext = Matter::Crypto::StandardCrypto.new.decrypt(session.decryption_key, packet.payload, nonce, aad)
    Matter::Codec::MessageCodec::Base.decode_payload(Matter::Codec::MessageCodec::Packet.new(packet.header, plaintext)).payload.should eq(Bytes[1])
    Matter::Session::SecureMessage.decode(session, packet).payload.should eq(Bytes[1])
  end

  it "does not advance receive state when authentication fails" do
    session = wire_session
    encoded, _ = Matter::Session::SecureMessage.encode(session, wire_payload_header, Bytes[1], message_counter: 100_u32)
    encoded[-1] ^= 1_u8
    expect_raises(Matter::AuthenticationError) do
      Matter::Session::SecureMessage.decode(session, Matter::Codec::MessageCodec::Base.decode_packet(encoded))
    end
    session.peer_message_counter.should be_nil
    session.check_peer_message_counter(1_u32).accept?.should be_true
  end

  it "refuses to decode a packet without the received header bytes" do
    session = wire_session
    encoded, _ = Matter::Session::SecureMessage.encode(session, wire_payload_header, Bytes[1])
    packet = Matter::Codec::MessageCodec::Base.decode_packet(encoded)
    bare = Matter::Codec::MessageCodec::Packet.new(packet.header, packet.payload)
    expect_raises(Matter::CodecError, /header bytes/) do
      Matter::Session::SecureMessage.decode(session, bare)
    end
    session.peer_message_counter.should be_nil
  end

  it "rejects tampering with optional header identities" do
    session = wire_session
    encoded, _ = Matter::Session::SecureMessage.encode(session, wire_payload_header, Bytes[1],
      destination_node_id: Matter::DataType::NodeId.new(20_u64))
    packet = Matter::Codec::MessageCodec::Base.decode_packet(encoded)
    header_bytes = packet.header_bytes.as(Bytes)
    encoded[header_bytes.size - 1] ^= 1_u8
    expect_raises(Matter::AuthenticationError) do
      Matter::Session::SecureMessage.decode(session, Matter::Codec::MessageCodec::Base.decode_packet(encoded))
    end
    session.peer_message_counter.should be_nil
  end

  it "authenticates the received raw flags even when semantic fields omit reserved bits" do
    session = wire_session
    header = Matter::Codec::MessageCodec::PacketHeader.new(
      session_id: session.session_id, session_type: Matter::Codec::MessageCodec::SessionType::Unicast, message_id: 1_u32)
    aad = Matter::Codec::MessageCodec::Base.encode_packet_header(header)
    # Bit 3 is reserved in the message flags byte, and must still be authenticated.
    reserved_message_flag = 0b00001000_u8
    aad[Matter::Codec::MessageCodec::FLAGS_OFFSET] |= reserved_message_flag
    plaintext = Matter::Codec::MessageCodec::Base.encode_payload(
      Matter::Codec::MessageCodec::Message.new(header, wire_payload_header, Bytes[1])).payload
    nonce = Matter::Session::SecureMessage.build_nonce(0_u64, header.message_id)
    ciphertext = Matter::Crypto::StandardCrypto.new.encrypt(session.encryption_key, plaintext, nonce, aad)
    packet = Matter::Codec::MessageCodec::Base.decode_packet(Slice.join([aad, ciphertext]))
    packet.header.flags.should eq(0_u8)
    Matter::Session::SecureMessage.decode(session, packet).payload.should eq(Bytes[1])
  end

  it "authenticates packet extensions and parses secured extensions after decryption" do
    session = wire_session
    header = Matter::Codec::MessageCodec::PacketHeader.new(
      session_id: session.session_id, session_type: Matter::Codec::MessageCodec::SessionType::Unicast,
      message_id: 1_u32, message_extension_data: Bytes[0xAA, 0xBB])
    payload_header = Matter::Codec::MessageCodec::PayloadHeader.new(
      exchange_id: 1_u16, protocol_id: 1_u16, message_type: 1_u8,
      initiator_message: true, requires_acknowledge: false,
      secured_extensions: Bytes[0xCC])
    aad = Matter::Codec::MessageCodec::Base.encode_packet_header(header)
    plaintext = Matter::Codec::MessageCodec::Base.encode_payload(
      Matter::Codec::MessageCodec::Message.new(header, payload_header, Bytes[0xDD])).payload
    nonce = Matter::Session::SecureMessage.build_nonce(0_u64, header.message_id, header.security_flags)
    encrypted = Matter::Crypto::StandardCrypto.new.encrypt(session.encryption_key, plaintext, nonce, aad)
    encoded = Slice.join([aad, encrypted])

    message = Matter::Session::SecureMessage.decode(session,
      Matter::Codec::MessageCodec::Base.decode_packet(encoded))
    message.packet_header.message_extension_data.should eq(Bytes[0xAA, 0xBB])
    message.payload_header.secured_extensions.should eq(Bytes[0xCC])
    message.payload.should eq(Bytes[0xDD])

    encoded[aad.size - 1] ^= 1_u8
    expect_raises(Matter::AuthenticationError) do
      Matter::Session::SecureMessage.decode(wire_session,
        Matter::Codec::MessageCodec::Base.decode_packet(encoded))
    end
  end

  it "allocates one outgoing counter and uses it in the packet" do
    session = wire_session
    session.local_message_counter = 10_u32
    encoded, counter = Matter::Session::SecureMessage.encode(session, wire_payload_header, Bytes.empty)
    counter.should eq(11_u32)
    session.local_message_counter.should eq(counter)
    Matter::Codec::MessageCodec::Base.decode_packet(encoded).header.message_id.should eq(counter)
  end

  it "accepts authenticated reordered datagrams and classifies subsequent duplicates" do
    session = wire_session
    [100_u32, 102_u32, 101_u32].each do |counter|
      session.check_peer_message_counter(counter).accept?.should be_true
      encoded, _ = Matter::Session::SecureMessage.encode(session, wire_payload_header, Bytes.empty, message_counter: counter)
      Matter::Session::SecureMessage.decode(session, Matter::Codec::MessageCodec::Base.decode_packet(encoded))
    end
    session.peer_message_counter.should eq(102_u32)
    session.check_peer_message_counter(101_u32).duplicate?.should be_true
    session.check_peer_message_counter(1_u32).stale?.should be_true
  end

  it "expires secure counters instead of overflowing or wrapping" do
    session = wire_session
    session.local_message_counter = UInt32::MAX - 1
    session.next_message_counter.should eq(UInt32::MAX)
    expect_raises(Matter::SessionError, /renegotiated/) { session.next_message_counter }
    session.local_message_counter.should eq(UInt32::MAX)
  end

  it "conservatively rejects counters preceding a restored receive watermark" do
    session = wire_session
    session.accept_peer_message_counter(100_u32)
    restored = Matter::Session::SecureContext.from_record(session.to_record)
    restored.check_peer_message_counter(99_u32).stale?.should be_true
    restored.check_peer_message_counter(100_u32).stale?.should be_true
    restored.check_peer_message_counter(101_u32).accept?.should be_true
  end

  it "restores authenticated CASE subjects including CATs" do
    session = wire_session
    subjects = [0x1234_u64, 0xFFFF_FFFD_FFFF_0001_u64]
    session.peer_subject_ids = subjects
    session.peer_icac = Bytes[1, 2, 3]

    restored = Matter::Session::SecureContext.from_record(
      Matter::Session::SecureContext::SessionRecord.from_document(session.to_record.to_document)
    )
    restored.peer_subject_ids.should eq(subjects)
    restored.peer_icac.should eq(Bytes[1, 2, 3])

    # Existing records have no peer_subject_ids field.
    legacy_document = session.to_record.to_document
    legacy_document.delete("peer_subject_ids")
    legacy_document.delete("peer_icac")
    legacy = Matter::Session::SecureContext.from_record(
      Matter::Session::SecureContext::SessionRecord.from_document(legacy_document)
    )
    legacy.peer_subject_ids.should be_empty
    legacy.peer_icac.should be_nil
  end
end
