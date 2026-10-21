require "../spec_helper"

describe Matter::Codec::MessagePrivacy do
  it "matches the Matter 1.6 and CHIP/matter.js privacy vectors" do
    mic = "c5a0063ad5d2518191400dd68c5c163b".hexbytes
    Matter::Codec::MessagePrivacy.nonce(0x002a_u16, mic).hexstring.should eq("002ad2518191400dd68c5c163b")
    key = Matter::Codec::MessagePrivacy.derive_key("ca92d7a0942d1a511a0e26ad074f4c2f".hexbytes)
    key.hexstring.should eq("bfe9da016a765365f2dd97a9f939e425")
    privacy_nonce = "db7d408217b3c0c921a2fca4e1".hexbytes
    clear = "7956341201000000000000000200".hexbytes
    obfuscated = "d926afce24c8a0981bdd44f4e730".hexbytes
    Matter::Codec::MessagePrivacy.obfuscate(key, clear, privacy_nonce).should eq(obfuscated)
    Matter::Codec::MessagePrivacy.obfuscate(key, obfuscated, privacy_nonce).should eq(clear)
  end

  it "obfuscates only the group header region and recovers it for authenticated decryption" do
    header = Matter::Codec::MessageCodec::PacketHeader.new(
      session_id: 0x1234_u16, session_type: Matter::Codec::MessageCodec::SessionType::Group,
      message_id: 0x12345678_u32, privacy_enhancements: true,
      source_node_id: Matter::DataType::NodeId.new(1_u64),
      destination_group_id: Matter::DataType::GroupId.new(2_u16))
    encryption_key = "ca92d7a0942d1a511a0e26ad074f4c2f".hexbytes
    nonce = Matter::Session::SecureMessage.build_nonce(1_u64, header.message_id, header.security_flags)
    aad = Matter::Codec::MessageCodec::Base.encode_packet_header(header)
    plaintext = Bytes[0x01, 0x02, 0x03]
    payload = Matter::Crypto.encrypt(encryption_key, plaintext, nonce, aad)
    packet = Matter::Codec::MessageCodec::Packet.new(header, payload)
    key = Matter::Codec::MessagePrivacy.derive_key(encryption_key)
    wire = Matter::Codec::MessageCodec::Base.encode_private_packet(packet, key)
    wire[0, 4].should eq(Matter::Codec::MessageCodec::Base.encode_packet_header(header)[0, 4])
    wire[4, 14].should_not eq(Matter::Codec::MessageCodec::Base.encode_packet_header(header)[4, 14])
    expect_raises(Matter::CodecError) { Matter::Codec::MessageCodec::Base.decode_packet(wire) }
    recovered = Matter::Codec::MessageCodec::Base.decode_private_packet(wire, key)
    recovered.header.message_id.should eq(header.message_id)
    recovered.header.source_node_id.should eq(header.source_node_id)
    recovered.header.destination_group_id.should eq(header.destination_group_id)
    recovered.header_bytes.should eq(Matter::Codec::MessageCodec::Base.encode_packet_header(header))
    recovered.payload.should eq(payload)
    Matter::Crypto.decrypt(encryption_key, recovered.payload,
      Matter::Session::SecureMessage.build_nonce(recovered.header.source_node_id.as(Matter::DataType::NodeId).id,
        recovered.header.message_id, recovered.header.security_flags),
      recovered.header_bytes).should eq(plaintext)
    tampered = wire.dup
    tampered[tampered.size - 1] ^= 1_u8
    candidate = Matter::Codec::MessageCodec::Base.decode_private_packet(tampered, key)
    expect_raises(Matter::AuthenticationError) do
      Matter::Crypto.decrypt(encryption_key, candidate.payload,
        Matter::Session::SecureMessage.build_nonce(candidate.header.source_node_id.as(Matter::DataType::NodeId).id,
          candidate.header.message_id, candidate.header.security_flags),
        candidate.header_bytes)
    end
  end

  it "rejects malformed MICs, privacy on unicast, and accidental clear private encoding" do
    key = Bytes.new(16, 0x11_u8)
    expect_raises(Matter::CodecError) { Matter::Codec::MessagePrivacy.nonce(1_u16, Bytes.new(15)) }
    group = Matter::Codec::MessageCodec::PacketHeader.new(1_u16, Matter::Codec::MessageCodec::SessionType::Group, 1_u32, privacy_enhancements: true)
    expect_raises(Matter::CodecError) { Matter::Codec::MessageCodec::Base.encode_packet(Matter::Codec::MessageCodec::Packet.new(group, Bytes.new(16))) }
    expect_raises(Matter::CodecError) { Matter::Codec::MessageCodec::Base.encode_private_packet(Matter::Codec::MessageCodec::Packet.new(group, Bytes.new(15)), key) }
    unicast = Matter::Codec::MessageCodec::PacketHeader.new(1_u16, Matter::Codec::MessageCodec::SessionType::Unicast, 1_u32, privacy_enhancements: true)
    expect_raises(Matter::CodecError) { Matter::Codec::MessageCodec::Base.encode_private_packet(Matter::Codec::MessageCodec::Packet.new(unicast, Bytes.new(16)), key) }
  end
end
