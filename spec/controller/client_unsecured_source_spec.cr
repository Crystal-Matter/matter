require "../spec_helper"
require "../../src/matter/controller/client"
require "../../src/matter/controller/datastore_propagator"
require "../support/capture_transport"

private class CaseCounterCapture < Matter::Spec::CaptureTransport
  def receive_for_spec(data : Bytes, peer : Socket::IPAddress) : Nil
    handle_received_data(data, peer)
  end
end

private def receive_case_reply(transport : CaseCounterCapture, peer : Socket::IPAddress,
                               exchange_id : UInt16, counter : UInt32,
                               message_type : Matter::Protocol::SecureChannelMessageType) : Nil
  header = Matter::Codec::MessageCodec::PacketHeader.new(
    session_id: Matter::Codec::MessageCodec::UNSECURED_SESSION_ID,
    session_type: Matter::Codec::MessageCodec::SessionType::Unicast,
    message_id: counter,
    source_node_id: Matter::DataType::NodeId.new(0x3333_u64),
    destination_node_id: Matter::DataType::NodeId.new(0x2222_u64))
  payload = Matter::Codec::MessageCodec::PayloadHeader.new(
    exchange_id: exchange_id,
    protocol_id: Matter::Protocol::ProtocolId::SecureChannel.value,
    message_type: message_type.value,
    initiator_message: false,
    requires_acknowledge: true)
  transport.receive_for_spec(Matter::Codec::MessageCodec::Base.encode_message(header, payload, Bytes.empty), peer)
end

describe Matter::Controller::Client do
  it "accounts for CASE replies' automatic unsecured ACKs within a reserved range" do
    transport = CaseCounterCapture.new_for_spec
    transport.message_counter.reset(UInt32::MAX - 2_u32)
    transport.message_counter.limit_messages(
      Matter::Controller::DatastorePropagator::CASE_UNSECURED_MESSAGES_PER_CANDIDATE)
    client = Matter::Controller::Client.new(transport: transport, unsecured_source_node_id: 0x2222_u64)
    peer = Socket::IPAddress.new("127.0.0.1", 5540)
    protocol_id = Matter::Protocol::ProtocolId::SecureChannel.value
    sigma1 = Matter::Protocol::SecureChannelMessageType::CaseSigma1.value
    sigma3 = Matter::Protocol::SecureChannelMessageType::CaseSigma3.value

    exchange_id = client.send_unsecured_request(peer, protocol_id, sigma1, Bytes.empty)
    receive_case_reply(transport, peer, exchange_id, 1_u32,
      Matter::Protocol::SecureChannelMessageType::CaseSigma2)
    Matter::Transport::UDPTransport::MRP_MAX_RETRANSMISSIONS.times do
      receive_case_reply(transport, peer, exchange_id, 1_u32,
        Matter::Protocol::SecureChannelMessageType::CaseSigma2)
    end
    client.send_unsecured_on_exchange(peer, exchange_id, protocol_id, sigma3, Bytes.empty)
    receive_case_reply(transport, peer, exchange_id, 2_u32,
      Matter::Protocol::SecureChannelMessageType::StatusReport)
    Matter::Transport::UDPTransport::MRP_MAX_RETRANSMISSIONS.times do
      receive_case_reply(transport, peer, exchange_id, 2_u32,
        Matter::Protocol::SecureChannelMessageType::StatusReport)
    end

    sent_counters = transport.sent_packets.map { |packet| Matter::Codec::MessageCodec::Base.decode_packet(packet[0]).header.message_id }
    sent_counters.should eq([UInt32::MAX - 1_u32, UInt32::MAX] + (0_u32..9_u32).to_a)
    expect_raises(Matter::SessionError, /exhausted/) do
      client.send_unsecured_on_exchange(peer, exchange_id, protocol_id, sigma3, Bytes.empty)
    end
  ensure
    client.try(&.close)
    transport.try(&.close)
  end

  it "sends a default ephemeral source Node ID on unsecured requests" do
    transport = Matter::Spec::CaptureTransport.new_for_spec
    client = Matter::Controller::Client.new(transport: transport)
    peer = Socket::IPAddress.new("::1", 5533)

    client.send_unsecured_request(peer, 0_u16, 0x20_u8, Bytes.empty, requires_ack: false)

    packet = Matter::Codec::MessageCodec::Base.decode_packet(transport.sent_packets.last[0])
    source = packet.header.source_node_id.as(Matter::DataType::NodeId).id
    source.should be >= Matter::DataType::NodeId::OPERATIONAL_MINIMUM
    source.should be <= Matter::DataType::NodeId::OPERATIONAL_MAXIMUM
    packet.header.destination_node_id.should be_nil
  ensure
    client.try(&.close)
    transport.try(&.close)
  end

  it "preserves an explicit unsecured source Node ID" do
    transport = Matter::Spec::CaptureTransport.new_for_spec
    source_id = 0xA101_u64
    client = Matter::Controller::Client.new(transport: transport, unsecured_source_node_id: source_id)
    peer = Socket::IPAddress.new("::1", 5533)

    client.send_unsecured_request(peer, 0_u16, 0x20_u8, Bytes.empty, requires_ack: false)

    packet = Matter::Codec::MessageCodec::Base.decode_packet(transport.sent_packets.last[0])
    packet.header.source_node_id.as(Matter::DataType::NodeId).id.should eq(source_id)
    packet.header.destination_node_id.should be_nil
  ensure
    client.try(&.close)
    transport.try(&.close)
  end
end
