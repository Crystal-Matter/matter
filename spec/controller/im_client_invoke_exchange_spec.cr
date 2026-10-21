require "../spec_helper"
require "../../src/matter/controller/im_client"
require "../../src/matter/protocol/im_handler"
require "../../src/matter/protocol/message_handler"

# Couples the controller's continuation requests to the device's real pending
# InvokeResponse ladder. The first response stands in for the command handler;
# every later response must be released by a Status.Success on that exchange.
private class GatedInvokeClient < Matter::Controller::Client
  getter status_acks = [] of UInt32?
  getter received_ids = [] of UInt32
  getter? released_before_status = false
  property response_chunks = [] of Bytes

  @next_peer_counter = 5_u32
  @first_response : ReceivedMessage? = nil

  def initialize(@handler : Matter::Protocol::MessageHandler,
                 @capture : Matter::Spec::CaptureTransport,
                 @device_session : Matter::Session::SecureContext,
                 @peer : Socket::IPAddress)
    super()
  end

  def send_encrypted_request(session : Matter::Session::SecureContext,
                             peer : Socket::IPAddress, protocol_id : UInt16,
                             message_type : UInt8, payload : Bytes | Slice(UInt8),
                             exchange_id : UInt16 = next_exchange_id,
                             initiator_message : Bool = true,
                             requires_ack : Bool = true,
                             acknowledged_message_id : UInt32? = nil) : UInt16
    if message_type == Matter::Controller::ImClient::MSG_INVOKE_REQUEST
      @handler.subscriptions.await_invoke(exchange_id,
        Matter::Protocol::SubscriptionManager::PendingInvoke.new(
          @peer, @device_session, @response_chunks[1..]))
      @released_before_status = !@capture.sent_packets.empty?
      packet = Matter::Codec::MessageCodec::PacketHeader.new(session.session_id,
        Matter::Codec::MessageCodec::SessionType::Unicast, 11_u32)
      header = Matter::Codec::MessageCodec::PayloadHeader.new(exchange_id,
        protocol_id, Matter::Controller::ImClient::MSG_INVOKE_RESPONSE, false, false)
      @first_response = ReceivedMessage.new(
        Matter::Codec::MessageCodec::Message.new(packet, header, @response_chunks.first), @peer)
    elsif message_type == Matter::Controller::ImClient::MSG_STATUS_RESPONSE
      @status_acks << acknowledged_message_id
      @handler.handle_message(Matter::Spec::ProtocolMessages.from_peer(
        @device_session, message_type, payload.to_slice, @next_peer_counter, exchange_id,
        requires_acknowledge: false), @peer)
      @next_peer_counter &+= 1_u32
    end
    exchange_id
  end

  def wait_for_any(exchange_id : UInt16, protocol_id : UInt16,
                   message_types : Array(UInt8), timeout : Time::Span) : ReceivedMessage?
    if first = @first_response
      @first_response = nil
      @received_ids << first.message.packet_header.message_id
      return first
    end

    while sent = @capture.sent_packets.shift?
      packet = Matter::Codec::MessageCodec::Base.decode_packet(sent[0])
      header_bytes = sent[0][0, sent[0].size - packet.payload.size]
      nonce = Matter::Session::SecureMessage.build_nonce(
        @device_session.local_node_id.as(Matter::DataType::NodeId).id,
        packet.header.message_id,
        header_bytes[Matter::Codec::MessageCodec::SECURITY_FLAGS_OFFSET])
      plaintext = Matter::Crypto::StandardCrypto.new.decrypt(
        @device_session.encryption_key, packet.payload, nonce, header_bytes)
      message = Matter::Codec::MessageCodec::Base.decode_payload(
        Matter::Codec::MessageCodec::Packet.new(packet.header, plaintext))
      next unless message.payload_header.exchange_id == exchange_id
      next unless message.payload_header.protocol_id == protocol_id
      next unless message_types.includes?(message.payload_header.message_type)
      @received_ids << message.packet_header.message_id
      return ReceivedMessage.new(message, sent[1])
    end
    nil
  end
end

describe "controller and device chunked InvokeResponse exchange" do
  it "reassembles server chunks released only by IM Status.Success on the same exchange" do
    require_udp_sockets!
    capture = Matter::Spec::CaptureTransport.new_for_spec
    handler = Matter::Protocol::MessageHandler.new(capture, 20202021_u32, 3840_u16,
      Matter::FabricTable.new(Matter::Storage::Memory.new))
    device_session = Matter::Spec::ProtocolMessages.case_session(1_u16)
    device_session.peer_session_id = device_session.session_id
    handler.sessions[device_session.session_id] = device_session
    session = Matter::Session::SecureContext.new(
      session_id: device_session.peer_session_id,
      peer_session_id: device_session.session_id,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: device_session.decryption_key,
      decryption_key: device_session.encryption_key,
      initiator: true,
      peer_node_id: device_session.local_node_id,
      local_node_id: device_session.peer_node_id,
      case_session: true,
      fabric_index: device_session.fabric_index)
    peer = Socket::IPAddress.new("127.0.0.1", 5540)
    client = GatedInvokeClient.new(handler, capture, device_session, peer)
    responses = Array.new(20) do |index|
      path = Matter::InteractionModel::CommandPath.new(0_u16, 0x0028_u32, index.to_u32)
      data = Matter::InteractionModel::CommandDataIBTlv.new(path, TLV::Any.new("A" * 80, nil))
      Matter::InteractionModel::InvokeResponseIB.new(command_data: data)
    end
    client.response_chunks = Matter::Protocol::IMHandler.encode_chunked_invoke_response(responses)
    client.response_chunks.size.should be > 1

    result = Matter::Controller::ImClient.new(client).invoke(session, peer, 0_u16, 0x0028_u32, 1_u32)

    result.invoke_responses.compact_map(&.command_data).map(&.command_path.command)
      .should eq((0...20).map(&.to_u32))
    client.released_before_status?.should be_false
    client.status_acks.size.should eq(client.response_chunks.size - 1)
    client.status_acks.should eq(client.received_ids[0...-1].map(&.as(UInt32?)))
  ensure
    client.try(&.close)
    handler.try(&.close)
  end
end
