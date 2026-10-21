require "../spec_helper"
require "../../src/matter/controller/client"

class ReplaySpecClient < Matter::Controller::Client
  def receive_for_spec(message : Matter::Codec::MessageCodec::Message, peer : Socket::IPAddress)
    handle_transport_message(message, peer)
  end
end

describe Matter::Controller::Client do
  it "retains the encrypted request bytes until an authenticated ACK arrives" do
    require_udp_sockets!
    client = ReplaySpecClient.new
    peer = UDPSocket.new(Socket::Family::INET6)
    peer.bind("::1", 0)
    peer.read_timeout = 1.second
    session = Matter::Session::SecureContext.new(
      session_id: 3_u16, peer_session_id: 3_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16, 3_u8), decryption_key: Bytes.new(16, 3_u8)
    )
    client.register_session(session)
    exchange_id = client.send_encrypted_request(session, peer.local_address,
      Matter::Controller::Client::PROTOCOL_INTERACTION_MODEL, 2_u8, Bytes[1])
    first, _ = peer.receive
    counter = Matter::Codec::MessageCodec::Base.decode_packet(first.to_slice).header.message_id
    client.transport.as(Matter::Transport::UDPTransport).pending_reliable_count.should eq(1)

    client.transport.as(Matter::Transport::UDPTransport).retransmit_due(Time.instant + 2.seconds)
    second, _ = peer.receive
    second.should eq(first)
    session.local_message_counter.should eq(counter)

    ack_header = Matter::Codec::MessageCodec::PayloadHeader.new(
      exchange_id: exchange_id,
      protocol_id: Matter::Controller::Client::PROTOCOL_SECURE_CHANNEL,
      message_type: Matter::Controller::Client::MSG_STANDALONE_ACK,
      initiator_message: false, requires_acknowledge: false,
      acknowledged_message_id: counter)
    ack, _ = Matter::Session::SecureMessage.encode(session, ack_header, Bytes.empty,
      message_counter: counter &+ 1)
    packet = Matter::Codec::MessageCodec::Base.decode_packet(ack)
    client.receive_for_spec(Matter::Codec::MessageCodec::Message.new(packet.header,
      ack_header, packet.payload, packet.header_bytes), peer.local_address)
    client.transport.as(Matter::Transport::UDPTransport).pending_reliable_count.should eq(0)
  ensure
    client.try(&.close)
    peer.try(&.close)
  end

  it "resends the same encrypted ACK for duplicate messages without advancing its outgoing counter" do
    require_udp_sockets!
    client = ReplaySpecClient.new
    peer = UDPSocket.new(Socket::Family::INET6)
    peer.bind("::1", 0)
    peer.read_timeout = 1.second
    session = Matter::Session::SecureContext.new(
      session_id: 1_u16, peer_session_id: 1_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16, 1_u8), decryption_key: Bytes.new(16, 1_u8)
    )
    client.register_session(session)
    header = Matter::Codec::MessageCodec::PayloadHeader.new(
      exchange_id: 1_u16, protocol_id: 1_u16, message_type: 1_u8,
      initiator_message: false, requires_acknowledge: true
    )
    bytes, _ = Matter::Session::SecureMessage.encode(session, header, Bytes[1], message_counter: 1_u32)
    packet = Matter::Codec::MessageCodec::Base.decode_packet(bytes)
    message = Matter::Codec::MessageCodec::Message.new(packet.header, header, packet.payload, packet.header_bytes)
    client.receive_for_spec(message, peer.local_address)
    received = client.wait_for(1_u16, 1_u16, 1_u8, 1.second)
    received.should_not be_nil
    first_ack, _ = peer.receive
    counter = session.local_message_counter

    client.receive_for_spec(message, peer.local_address)
    repeated_ack, _ = peer.receive
    repeated_ack.should eq(first_ack)
    session.local_message_counter.should eq(counter)
    client.wait_for(1_u16, 1_u16, 1_u8, 1.millisecond).should be_nil
  ensure
    client.try(&.close)
    peer.try(&.close)
  end
end
