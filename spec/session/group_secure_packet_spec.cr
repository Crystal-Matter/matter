require "../spec_helper"

alias GroupPacket = Matter::Session::GroupSecurePacket

describe Matter::Session::GroupSecurePacket do
  it "authenticates an opaque message extension before accepting a group counter" do
    operational_key = "a6f5306baf6d050af23ba4bd6b9dd960".hexbytes
    key = GroupPacket::Key.new(1_u8, 0x0042_u16, operational_key)
    header = Matter::Codec::MessageCodec::PacketHeader.new(
      key.session_id, Matter::Codec::MessageCodec::SessionType::Group, 77_u32,
      privacy_enhancements: true, message_extension_data: Bytes[0xaa],
      source_node_id: Matter::DataType::NodeId.new(0x1234_u64),
      destination_group_id: key.group_id)
    payload_header = Matter::Codec::MessageCodec::PayloadHeader.new(
      3_u16, 1_u16, 0x08_u8, true, false)
    application = Matter::Codec::MessageCodec::Base.encode_payload(
      Matter::Codec::MessageCodec::Message.new(header, payload_header, Bytes[0x47])).payload
    aad = Matter::Codec::MessageCodec::Base.encode_packet_header(header)
    nonce = Matter::Session::SecureMessage.build_nonce(0x1234_u64, 77_u32, header.security_flags)
    ciphertext = Matter::Crypto.encrypt(operational_key, application, nonce, aad)
    mic = ciphertext[ciphertext.size - 16, 16]
    privacy_nonce = Matter::Codec::MessagePrivacy.nonce(key.session_id, mic)
    private_header = aad.dup
    private_header[4, 14].copy_from(Matter::Codec::MessagePrivacy.obfuscate(key.privacy_key, aad[4, 14], privacy_nonce))
    wire = Slice.join([private_header, ciphertext])

    receiver = GroupPacket.new([key])
    tampered = wire.dup
    tampered[aad.size - 1] ^= 1_u8
    expect_raises(Matter::AuthenticationError) { receiver.decode(tampered) }
    receiver.decode(wire).message.payload.should eq(Bytes[0x47])
  end

  it "matches the Matter 1.6 operational key and group session ID vectors" do
    epoch = "235bf7e62823d358dca4ba50b1535f4b".hexbytes
    fabric = "87e1b004e235a130".hexbytes
    key = GroupPacket.derive_operational_key(epoch, fabric)
    key.hexstring.should eq("a6f5306baf6d050af23ba4bd6b9dd960")
    GroupPacket.session_id(key).should eq(0xb9f7_u16)
  end

  it "authenticates private group packets before advancing replay state" do
    key = "a6f5306baf6d050af23ba4bd6b9dd960".hexbytes
    candidate = GroupPacket::Key.new(1_u8, 0x0042_u16, key)
    sender = GroupPacket.new([candidate])
    receiver = GroupPacket.new([candidate])
    payload_header = Matter::Codec::MessageCodec::PayloadHeader.new(
      exchange_id: 3_u16, protocol_id: 1_u16, message_type: 0x08_u8,
      initiator_message: true, requires_acknowledge: false)
    wire = sender.encode(candidate, 0x1234_u64, 100_u32, payload_header, Bytes[0x01, 0x02])
    (wire[3] & 0x80).should eq(0x80)
    decoded = receiver.decode(wire)
    decoded.fabric_index.should eq(1_u8)
    decoded.message.packet_header.destination_group_id.should eq(Matter::DataType::GroupId.new(0x0042_u16))
    decoded.message.payload.should eq(Bytes[0x01, 0x02])
    expect_raises(Matter::SessionError) { receiver.decode(wire) }

    tampered = sender.encode(candidate, 0x1234_u64, 101_u32, payload_header, Bytes[0x01, 0x03])
    tampered[tampered.size - 1] ^= 1_u8
    expect_raises(Matter::AuthenticationError) { receiver.decode(tampered) }
    valid = sender.encode(candidate, 0x1234_u64, 101_u32, payload_header, Bytes[0x01, 0x03])
    receiver.decode(valid).message.payload.should eq(Bytes[0x01, 0x03])
  end

  it "retains the sender replay window across epoch key rotation on one installed fabric" do
    old_key = GroupPacket::Key.new(1_u8, 0x0042_u16, Bytes.new(16, 0x11_u8))
    new_key = GroupPacket::Key.new(1_u8, 0x0042_u16, Bytes.new(16, 0x22_u8))
    receiver = GroupPacket.new([old_key])
    old_sender = GroupPacket.new([old_key])
    new_sender = GroupPacket.new([new_key])
    header = Matter::Codec::MessageCodec::PayloadHeader.new(
      exchange_id: 3_u16, protocol_id: 1_u16, message_type: 0x08_u8,
      initiator_message: true, requires_acknowledge: false)
    source = 0x1234_u64
    receiver.decode(old_sender.encode(old_key, source, 100_u32, header, Bytes[0x01]))

    receiver.keys = [new_key]
    expect_raises(GroupPacket::Replay) do
      receiver.decode(new_sender.encode(new_key, source, 100_u32, header, Bytes[0x02]))
    end
    receiver.decode(new_sender.encode(new_key, source, 101_u32, header, Bytes[0x03]))
      .message.payload.should eq(Bytes[0x03])
  end

  it "rejects unknown mappings and never evicts a peer replay state within a boot" do
    key = "a6f5306baf6d050af23ba4bd6b9dd960".hexbytes
    mapped = GroupPacket::Key.new(1_u8, 0x0042_u16, key)
    other_group = GroupPacket::Key.new(1_u8, 0x0043_u16, key)
    payload_header = Matter::Codec::MessageCodec::PayloadHeader.new(
      exchange_id: 3_u16, protocol_id: 1_u16, message_type: 0x08_u8,
      initiator_message: true, requires_acknowledge: false)
    sender = GroupPacket.new([mapped])
    receiver = GroupPacket.new([other_group])
    wire = sender.encode(mapped, 1_u64, 1_u32, payload_header, Bytes[0x01])
    expect_raises(Matter::AuthenticationError) { receiver.decode(wire) }
    receiver = GroupPacket.new([mapped])
    (1_u64..10_u64).each do |source|
      receiver.decode(sender.encode(mapped, source, 1_u32, payload_header, Bytes[0x01]))
    end
    second = sender.encode(mapped, 11_u64, 1_u32, payload_header, Bytes[0x02])
    expect_raises(Matter::SessionError, /table is full/) { receiver.decode(second) }
    expect_raises(Matter::SessionError) { receiver.decode(wire) }
  end

  it "tries all operational keys with a colliding Group Session ID" do
    first = GroupPacket::Key.new(1_u8, 0x0042_u16, "0000000000000000000000000000003f".hexbytes)
    second = GroupPacket::Key.new(1_u8, 0x0042_u16, "00000000000000000000000000000090".hexbytes)
    first.session_id.should eq(second.session_id)
    payload_header = Matter::Codec::MessageCodec::PayloadHeader.new(
      exchange_id: 3_u16, protocol_id: 1_u16, message_type: 0x08_u8,
      initiator_message: true, requires_acknowledge: false)
    wire = GroupPacket.new([second]).encode(second, 1_u64, 1_u32, payload_header, Bytes[0x47])
    GroupPacket.new([first, second]).decode(wire).message.payload.should eq(Bytes[0x47])
  end

  it "tracks group data and control counters independently" do
    key = GroupPacket::Key.new(1_u8, 0x0042_u16,
      "a6f5306baf6d050af23ba4bd6b9dd960".hexbytes)
    sender = GroupPacket.new([key])
    receiver = GroupPacket.new([key])
    payload_header = Matter::Codec::MessageCodec::PayloadHeader.new(
      exchange_id: 3_u16, protocol_id: 1_u16, message_type: 0x08_u8,
      initiator_message: true, requires_acknowledge: false)
    data = sender.encode(key, 1_u64, 9_u32, payload_header, Bytes[0x01])
    control = sender.encode(key, 1_u64, 9_u32, payload_header, Bytes[0x02], control: true)
    receiver.decode(data).message.payload.should eq(Bytes[0x01])
    receiver.decode(control).message.payload.should eq(Bytes[0x02])
    expect_raises(Matter::SessionError) { receiver.decode(data) }
    expect_raises(Matter::SessionError) { receiver.decode(control) }
  end
end
