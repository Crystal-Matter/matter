require "../spec_helper"
require "../../src/matter/controller/im_subscription"

private class SubscriptionSpecClient < Matter::Controller::Client
  getter sent = [] of {UInt8, UInt16, Bool}
  property scripted_messages = [] of ReceivedMessage

  def send_encrypted_request(session : Matter::Session::SecureContext,
                             peer : Socket::IPAddress, protocol_id : UInt16,
                             message_type : UInt8, payload : Bytes | Slice(UInt8),
                             exchange_id : UInt16 = 7_u16,
                             initiator_message : Bool = true,
                             requires_ack : Bool = true,
                             acknowledged_message_id : UInt32? = nil) : UInt16
    @sent << {message_type, exchange_id, initiator_message}
    exchange_id
  end

  def receive_message(timeout_span : Time::Span) : ReceivedMessage?
    @scripted_messages.shift?
  end
end

private def subscription_message(type : UInt8, payload : Bytes, exchange_id : UInt16,
                                 peer : Socket::IPAddress, initiator : Bool = false) : Matter::Controller::Client::ReceivedMessage
  packet = Matter::Codec::MessageCodec::PacketHeader.new(1_u16,
    Matter::Codec::MessageCodec::SessionType::Unicast, 1_u32)
  header = Matter::Codec::MessageCodec::PayloadHeader.new(exchange_id, 1_u16,
    type, initiator, false)
  message = Matter::Codec::MessageCodec::Message.new(packet, header, payload)
  Matter::Controller::Client::ReceivedMessage.new(message, peer)
end

describe Matter::Controller::AttributeSubscription do
  it "completes the priming handshake and checks notification identity" do
    client = SubscriptionSpecClient.new
    peer = Socket::IPAddress.new("127.0.0.1", 5540)
    session = Matter::Session::SecureContext.new(session_id: 1_u16, peer_session_id: 1_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16), decryption_key: Bytes.new(16))
    path = Matter::InteractionModel::AttributePath.new(endpoint: 1_u16, cluster: 0x752_u32,
      attribute: 0_u32)
    data = Matter::InteractionModel::AttributeDataIB.new(path, TLV::Any.from_slice(5_u8.to_tlv))
    report = Matter::InteractionModel::ReportDataMessage.new(subscription_id: 42_u32,
      attribute_reports: [Matter::InteractionModel::AttributeReportIB.new(attribute_data: data)])
    client.scripted_messages << subscription_message(5_u8, report.to_slice, 7_u16, peer)
    response = Matter::InteractionModel::SubscribeResponseMessage.new(42_u32, 60_u16)
    client.scripted_messages << subscription_message(4_u8, response.to_slice, 7_u16, peer)
    subscription = Matter::Controller::AttributeSubscription.new(client, session, peer, path)
    subscription.subscription_id.should eq(42_u32)
    subscription.initial_reports.size.should eq(1)
    client.sent.should eq([{3_u8, 7_u16, true}, {1_u8, 7_u16, true}])

    # A quiet interval below MaxInterval is healthy and must not force a new
    # CASE session or SubscribeRequest.
    subscription.poll_report(1.millisecond).should be_nil
    client.sent.should eq([{3_u8, 7_u16, true}, {1_u8, 7_u16, true}])

    client.scripted_messages << subscription_message(5_u8, report.to_slice, 9_u16, peer, true)
    subscription.poll_report(1.millisecond).try(&.size).should eq(1)
    client.sent.last.should eq({1_u8, 9_u16, false})
    wrong = Matter::InteractionModel::ReportDataMessage.new(subscription_id: 43_u32,
      attribute_reports: [Matter::InteractionModel::AttributeReportIB.new(attribute_data: data)])
    client.scripted_messages << subscription_message(5_u8, wrong.to_slice, 10_u16, peer, true)
    expect_raises(Matter::AuthenticationError, /Subscription ID changed/) { subscription.next_report }
  ensure
    client.try(&.close)
  end

  it "rejects a SubscribeResponse with a different ID" do
    client = SubscriptionSpecClient.new
    peer = Socket::IPAddress.new("127.0.0.1", 5540)
    session = Matter::Session::SecureContext.new(session_id: 1_u16, peer_session_id: 1_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16), decryption_key: Bytes.new(16))
    path = Matter::InteractionModel::AttributePath.new(endpoint: 1_u16, cluster: 0x752_u32,
      attribute: 0_u32)
    report = Matter::InteractionModel::ReportDataMessage.new(subscription_id: 42_u32)
    client.scripted_messages << subscription_message(5_u8, report.to_slice, 7_u16, peer)
    client.scripted_messages << subscription_message(4_u8,
      Matter::InteractionModel::SubscribeResponseMessage.new(43_u32, 60_u16).to_slice, 7_u16, peer)
    expect_raises(Matter::ProtocolError, /identity/) do
      Matter::Controller::AttributeSubscription.new(client, session, peer, path)
    end
  ensure
    client.try(&.close)
  end

  it "accepts an authenticated CASE report from a mapped IPv4 socket" do
    client = SubscriptionSpecClient.new
    peer = Socket::IPAddress.new("127.0.0.1", 5540)
    mapped_peer = Socket::IPAddress.new("::ffff:127.0.0.1", 5540)
    session = Matter::Session::SecureContext.new(session_id: 1_u16, peer_session_id: 1_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16), decryption_key: Bytes.new(16))
    path = Matter::InteractionModel::AttributePath.new(endpoint: 1_u16,
      cluster: 0x752_u32, attribute: 0_u32)
    report = Matter::InteractionModel::ReportDataMessage.new(subscription_id: 42_u32)
    client.scripted_messages << subscription_message(5_u8, report.to_slice, 7_u16, mapped_peer)
    client.scripted_messages << subscription_message(4_u8,
      Matter::InteractionModel::SubscribeResponseMessage.new(42_u32, 60_u16).to_slice, 7_u16, mapped_peer)
    subscription = Matter::Controller::AttributeSubscription.new(client, session, peer, path)
    subscription.subscription_id.should eq(42_u32)
    client.scripted_messages << subscription_message(5_u8, report.to_slice, 9_u16, mapped_peer, true)
    subscription.next_report.size.should eq(1)
  ensure
    client.try(&.close)
  end
end
