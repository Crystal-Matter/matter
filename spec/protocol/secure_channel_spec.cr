require "../spec_helper"

require "../../src/matter/protocol/secure_channel"

private PEER = Socket::IPAddress.new("127.0.0.1", 5540)

private ITERATIONS =     1000_u32
private SETUP_PIN  = 20202021_u32

private record SecureChannelFixture,
  channel : Matter::Protocol::SecureChannel,
  transport : Matter::Spec::CaptureTransport

private def build_secure_channel : SecureChannelFixture
  transport = Matter::Spec::CaptureTransport.new_for_spec
  storage = Matter::Storage::Memory.new
  mrp_cache = Matter::Protocol::MrpCache.new(transport)
  registry = Matter::Protocol::SessionRegistry.new(mrp_cache: mrp_cache)

  channel = Matter::Protocol::SecureChannel.new(
    fabric_table: Matter::FabricTable.new(storage),
    registry: registry,
    sender: Matter::Protocol::ResponseSender.new(transport, mrp_cache),
    setup_pin: SETUP_PIN,
    iterations: ITERATIONS,
    salt: Bytes.new(32, 0x01_u8)
  )

  SecureChannelFixture.new(channel, transport)
end

# An unsecured PBKDFParamRequest, as a commissioner opens PASE with.
private def pbkdf_param_request(exchange_id : UInt16, initiator_session_id : UInt16) : Matter::Codec::MessageCodec::Message
  payload = Matter::Session::Pase::Definitions::PbkdfParamRequest.new(
    initiator_random: Random::Secure.random_bytes(32),
    initiator_session_id: initiator_session_id,
    passcode_id: 0_u16,
    has_pbkdf_parameters: false
  ).to_slice

  Matter::Codec::MessageCodec::Message.new(
    packet_header: Matter::Codec::MessageCodec::PacketHeader.new(
      session_id: 0_u16,
      session_type: Matter::Codec::MessageCodec::SessionType::Unicast,
      message_id: 1_u32
    ),
    payload_header: Matter::Codec::MessageCodec::PayloadHeader.new(
      exchange_id: exchange_id,
      protocol_id: Matter::Protocol::ProtocolId::SecureChannel.value,
      message_type: Matter::Protocol::SecureChannelMessageType::PbkdfParamRequest.value,
      initiator_message: true,
      requires_acknowledge: false
    ),
    payload: payload
  )
end

private def decode_pbkdf_response(packet_bytes : Bytes) : Matter::Session::Pase::Definitions::PbkdfParamResponse
  packet = Matter::Codec::MessageCodec::Base.decode_packet(packet_bytes)
  message = Matter::Codec::MessageCodec::Base.decode_payload(packet)
  Matter::Session::Pase::Definitions::PbkdfParamResponse.from_slice(message.payload)
end

describe Matter::Protocol::SecureChannel do
  it "keeps a separate handshake per exchange, so two commissioners do not collide" do
    fixture = build_secure_channel

    fixture.channel.handle(pbkdf_param_request(1_u16, 0x1111_u16), PEER).should be_true
    fixture.channel.handle(pbkdf_param_request(2_u16, 0x2222_u16), PEER).should be_true

    fixture.channel.handshakes_in_flight.should eq(2)

    # Each commissioner is answered with its own responder session id.
    session_ids = fixture.transport.sent_packets.map { |packet_bytes, _| decode_pbkdf_response(packet_bytes).responder_session_id }
    session_ids.size.should eq(2)
    session_ids.uniq.size.should eq(2)
  end

  it "answers with the configured PBKDF parameters" do
    fixture = build_secure_channel

    fixture.channel.handle(pbkdf_param_request(1_u16, 0x1111_u16), PEER)
    response = decode_pbkdf_response(fixture.transport.sent_packets.first[0])

    parameters = response.pbkdf_parameters.as(Matter::Session::Pase::Definitions::PbkdfParametersTLV)
    parameters.iterations.should eq(ITERATIONS)
    parameters.salt.should eq(Bytes.new(32, 0x01_u8))
  end

  it "reports InvalidParam without starting PASE for a request missing mandatory fields" do
    original = pbkdf_param_request(3_u16, 0x3333_u16)
    payloads = [
      Matter::Session::Pase::Definitions::PbkdfParamRequest.new(
        initiator_random: Bytes.new(32, 0x42_u8),
        initiator_session_id: 0x3333_u16).to_slice,
      Bytes.empty,
    ]
    payloads.each do |payload|
      fixture = build_secure_channel
      malformed = Matter::Codec::MessageCodec::Message.new(
        packet_header: original.packet_header,
        payload_header: original.payload_header,
        payload: payload)

      fixture.channel.handle(malformed, PEER).should be_true
      fixture.channel.handshakes_in_flight.should eq(0)
      packet = Matter::Codec::MessageCodec::Base.decode_packet(fixture.transport.sent_packets.first[0])
      response = Matter::Codec::MessageCodec::Base.decode_payload(packet)
      response.payload_header.message_type.should eq(Matter::Protocol::SecureChannelMessageType::StatusReport.value)
      status = Matter::Session::Pase::Definitions::StatusReport.from_bytes(response.payload)
      status.general_status.should eq(1_u16)
      status.protocol_status.should eq(2_u16)
    end
  end

  it "forgets a handshake the commissioner abandoned" do
    fixture = build_secure_channel

    fixture.channel.handle(pbkdf_param_request(1_u16, 0x1111_u16), PEER)
    fixture.channel.handshakes_in_flight.should eq(1)

    fixture.channel.prune_expired_handshakes(Time.instant + Matter::Protocol::SecureChannel::HANDSHAKE_TIMEOUT - 1.second)
    fixture.channel.handshakes_in_flight.should eq(1)

    fixture.channel.prune_expired_handshakes(Time.instant + Matter::Protocol::SecureChannel::HANDSHAKE_TIMEOUT + 1.second)
    fixture.channel.handshakes_in_flight.should eq(0)
  end

  it "ignores a Pake1 for an exchange that never ran PBKDF parameter discovery" do
    fixture = build_secure_channel

    pake1 = Matter::Codec::MessageCodec::Message.new(
      packet_header: Matter::Codec::MessageCodec::PacketHeader.new(
        session_id: 0_u16,
        session_type: Matter::Codec::MessageCodec::SessionType::Unicast,
        message_id: 1_u32
      ),
      payload_header: Matter::Codec::MessageCodec::PayloadHeader.new(
        exchange_id: 9_u16,
        protocol_id: Matter::Protocol::ProtocolId::SecureChannel.value,
        message_type: Matter::Protocol::SecureChannelMessageType::PasePake1.value,
        initiator_message: true,
        requires_acknowledge: false
      ),
      payload: Matter::Session::Pase::Definitions::Pake1.new(x: Bytes.new(65, 0x04_u8)).to_slice
    )

    fixture.channel.handle(pake1, PEER).should be_true
    fixture.transport.sent_packets.should be_empty
  end

  it "reports an unknown Secure Channel message type as unhandled" do
    fixture = build_secure_channel

    unknown = Matter::Codec::MessageCodec::Message.new(
      packet_header: Matter::Codec::MessageCodec::PacketHeader.new(
        session_id: 0_u16,
        session_type: Matter::Codec::MessageCodec::SessionType::Unicast,
        message_id: 1_u32
      ),
      payload_header: Matter::Codec::MessageCodec::PayloadHeader.new(
        exchange_id: 1_u16,
        protocol_id: Matter::Protocol::ProtocolId::SecureChannel.value,
        message_type: 0x7F_u8,
        initiator_message: true,
        requires_acknowledge: false
      ),
      payload: Bytes.empty
    )

    fixture.channel.handle(unknown, PEER).should be_false
  end

  describe "commissioning window configuration" do
    it "advertises the window's parameters and drops handshakes started under the old ones" do
      fixture = build_secure_channel
      window_salt = Bytes.new(32, 0x02_u8)

      fixture.channel.handle(pbkdf_param_request(1_u16, 0x1111_u16), PEER)
      fixture.channel.handshakes_in_flight.should eq(1)

      fixture.channel.configure_pase_server(Bytes.new(97, 0x03_u8), 2000_u32, window_salt)

      fixture.channel.handshakes_in_flight.should eq(0)
      fixture.channel.iterations.should eq(2000_u32)
      fixture.channel.salt.should eq(window_salt)
      fixture.channel.passcode_verifier.should_not be_nil
    end

    it "restores the node's own parameters on reset" do
      fixture = build_secure_channel

      fixture.channel.configure_pase_pin(11223344_u32, 2000_u32, Bytes.new(32, 0x02_u8))
      fixture.channel.setup_pin.should eq(11223344_u32)

      fixture.channel.reset_pase_server

      fixture.channel.setup_pin.should eq(SETUP_PIN)
      fixture.channel.iterations.should eq(ITERATIONS)
      fixture.channel.salt.should eq(Bytes.new(32, 0x01_u8))
      fixture.channel.passcode_verifier.should be_nil
    end
  end
end
