require "../spec_helper"
require "../../src/matter/protocol/response_sender"

describe Matter::Protocol::ResponseSender do
  it "retains a device ReportData as the same ciphertext for retransmission" do
    transport = Matter::Spec::CaptureTransport.new_for_spec
    sender = Matter::Protocol::ResponseSender.new(transport, Matter::Protocol::MrpCache.new(transport))
    session = Matter::Session::SecureContext.new(
      session_id: 4_u16, peer_session_id: 5_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16, 4_u8), decryption_key: Bytes.new(16, 4_u8)
    )
    peer = Socket::IPAddress.new("::1", 5540)
    sender.send_report(session, peer, Bytes[1, 2])
    counter = session.local_message_counter
    transport.pending_reliable_count.should eq(1)
    transport.retransmit_due(Time.instant + 2.seconds)
    transport.sent_packets.map(&.[0]).should eq([transport.sent_packets[0][0], transport.sent_packets[0][0]])
    session.local_message_counter.should eq(counter)
    transport.close
  end

  it "drops a selected encoded response without queuing or caching it" do
    transport = Matter::Spec::CaptureTransport.new_for_spec
    cache = Matter::Protocol::MrpCache.new(transport)
    sender = Matter::Protocol::ResponseSender.new(transport, cache)
    session = Matter::Session::SecureContext.new(
      session_id: 4_u16, peer_session_id: 5_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16, 4_u8), decryption_key: Bytes.new(16, 4_u8)
    )
    request = Matter::Codec::MessageCodec::Message.new(
      packet_header: Matter::Codec::MessageCodec::PacketHeader.new(
        session_id: session.session_id,
        session_type: Matter::Codec::MessageCodec::SessionType::Unicast,
        message_id: 10_u32),
      payload_header: Matter::Codec::MessageCodec::PayloadHeader.new(
        exchange_id: 11_u16,
        protocol_id: Matter::Protocol::ProtocolId::InteractionModel.value,
        message_type: Matter::InteractionModel::MessageType::InvokeRequest.value,
        initiator_message: true,
        requires_acknowledge: true),
      payload: Bytes.empty)
    encoded = Bytes.empty
    sender.on_im_response_packet = ->(_request : Matter::Codec::MessageCodec::Message, _type : UInt8, packet : Bytes) do
      encoded = packet.dup
      true
    end

    expect_raises(Matter::TransportError, "discarded before transport enqueue") do
      sender.send_im_response(request, Socket::IPAddress.new("::1", 5540), session,
        Matter::InteractionModel::MessageType::InvokeResponse.value,
        Bytes[1, 2], cache_for_mrp: true)
    end
    encoded.empty?.should be_false
    transport.sent_packets.should be_empty
    transport.pending_reliable_count.should eq(0)
    cache.size.should eq(0)
    transport.close
  end
end
