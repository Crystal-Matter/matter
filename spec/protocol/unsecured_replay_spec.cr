require "../spec_helper"
require "../../src/matter/protocol/secure_channel"

class UnsecuredReplayCapture < Matter::Spec::CaptureTransport
  def receive_for_spec(data : Bytes, peer : Socket::IPAddress) : Nil
    handle_received_data(data, peer)
  end
end

describe "unsecured PASE response replay" do
  it "replays the same PBKDFParamResponse when its request is retransmitted" do
    transport = UnsecuredReplayCapture.new_for_spec
    peer = Socket::IPAddress.new("127.0.0.1", 5540)
    cache = Matter::Protocol::MrpCache.new(transport)
    registry = Matter::Protocol::SessionRegistry.new(mrp_cache: cache)
    channel = Matter::Protocol::SecureChannel.new(
      fabric_table: Matter::FabricTable.new(Matter::Storage::Memory.new),
      registry: registry,
      sender: Matter::Protocol::ResponseSender.new(transport, cache),
      setup_pin: 20202021_u32,
      iterations: 1000_u32,
      salt: Bytes.new(32, 0x01_u8)
    )
    transport.on_message = ->(message : Matter::Codec::MessageCodec::Message, address : Socket::IPAddress) { channel.handle(message, address); nil }
    request_payload = Matter::Session::Pase::Definitions::PbkdfParamRequest.new(
      initiator_random: Bytes.new(32, 0x42_u8),
      initiator_session_id: 0x1111_u16,
      passcode_id: 0_u16,
      has_pbkdf_parameters: false
    ).to_slice
    request = Matter::Codec::MessageCodec::Message.new(
      packet_header: Matter::Codec::MessageCodec::PacketHeader.new(
        session_id: 0_u16,
        session_type: Matter::Codec::MessageCodec::SessionType::Unicast,
        message_id: 0x12345678_u32),
      payload_header: Matter::Codec::MessageCodec::PayloadHeader.new(
        exchange_id: 9_u16,
        protocol_id: Matter::Protocol::ProtocolId::SecureChannel.value,
        message_type: Matter::Protocol::SecureChannelMessageType::PbkdfParamRequest.value,
        initiator_message: true,
        requires_acknowledge: true),
      payload: request_payload)
    bytes = Matter::Codec::MessageCodec::Base.encode_message(
      request.packet_header, request.payload_header, request.payload)

    transport.receive_for_spec(bytes, peer)
    responses = transport.sent_packets.map(&.[0]).select do |packet_bytes|
      packet = Matter::Codec::MessageCodec::Base.decode_packet(packet_bytes)
      message = Matter::Codec::MessageCodec::Base.decode_payload(packet)
      message.payload_header.message_type == Matter::Protocol::SecureChannelMessageType::PbkdfParamResponse.value
    end
    responses.size.should eq(1)
    original = responses.first.dup
    counter = Matter::Codec::MessageCodec::Base.decode_packet(original).header.message_id

    # Simulate loss of the first response. The commissioner resends the exact
    # same request, so replay must use the same random response and counter.
    transport.receive_for_spec(bytes, peer)
    replayed = transport.sent_packets.map(&.[0]).select do |packet_bytes|
      packet = Matter::Codec::MessageCodec::Base.decode_packet(packet_bytes)
      message = Matter::Codec::MessageCodec::Base.decode_payload(packet)
      message.payload_header.message_type == Matter::Protocol::SecureChannelMessageType::PbkdfParamResponse.value
    end
    replayed.size.should eq(2)
    replayed.last.should eq(original)
    Matter::Codec::MessageCodec::Base.decode_packet(replayed.last).header.message_id.should eq(counter)
    channel.handshakes_in_flight.should eq(1)

    # A different packet reusing the same unsecured message counter cannot
    # solicit the cached response or a new acknowledgement.
    altered = bytes.dup
    altered[altered.size - 2] = altered[altered.size - 2] ^ 1_u8
    before = transport.sent_packets.size
    transport.receive_for_spec(altered, peer)
    transport.sent_packets.size.should eq(before)
  end
end
