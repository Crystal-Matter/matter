require "../spec_helper"
require "../../src/matter/controller/im_subscription"

private class SubscriptionSpecClient < Matter::Controller::Client
  getter sent = [] of {UInt8, UInt16, Bool}
  getter request_payloads = [] of Bytes
  property scripted_messages = [] of ReceivedMessage

  def next_exchange_id : UInt16
    7_u16
  end

  def send_encrypted_request(session : Matter::Session::SecureContext,
                             peer : Socket::IPAddress, protocol_id : UInt16,
                             message_type : UInt8, payload : Bytes | Slice(UInt8),
                             exchange_id : UInt16 = 7_u16,
                             initiator_message : Bool = true,
                             requires_ack : Bool = true,
                             acknowledged_message_id : UInt32? = nil) : UInt16
    @sent << {message_type, exchange_id, initiator_message}
    @request_payloads << payload.to_slice
    exchange_id
  end

  protected def receive_unfiltered_from_inbox(timeout_span : Time::Span) : ReceivedMessage?
    @scripted_messages.shift?
  end
end

private class SharedSubscriptionSpecClient < Matter::Controller::Client
  getter sent = [] of {UInt8, UInt16}
  getter status_payloads = [] of Bytes
  @next_request_exchange = 7_u16

  def next_exchange_id : UInt16
    id = @next_request_exchange
    @next_request_exchange &+= 1
    id
  end

  def send_encrypted_request(session : Matter::Session::SecureContext,
                             peer : Socket::IPAddress, protocol_id : UInt16,
                             message_type : UInt8, payload : Bytes | Slice(UInt8),
                             exchange_id : UInt16 = 0_u16,
                             initiator_message : Bool = true,
                             requires_ack : Bool = true,
                             acknowledged_message_id : UInt32? = nil) : UInt16
    @sent << {message_type, exchange_id}
    @status_payloads << payload.to_slice if message_type == Matter::InteractionModel::MessageType::StatusResponse.value
    exchange_id
  end

  def enqueue(message : ReceivedMessage) : Nil
    @inbox.send(message)
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
  it "routes two shared-client subscriptions while retaining an unrelated read response" do
    client = SharedSubscriptionSpecClient.new
    peer = Socket::IPAddress.new("127.0.0.1", 5540)
    session = Matter::Session::SecureContext.new(session_id: 1_u16, peer_session_id: 1_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16), decryption_key: Bytes.new(16))
    client.register_session(session)
    {42_u32, 43_u32}.each_with_index do |id, index|
      exchange = (7 + index).to_u16
      client.enqueue(subscription_message(5_u8,
        Matter::InteractionModel::ReportDataMessage.new(subscription_id: id).to_slice, exchange, peer))
      client.enqueue(subscription_message(4_u8,
        Matter::InteractionModel::SubscribeResponseMessage.new(id, 60_u16).to_slice, exchange, peer))
    end
    im = Matter::Controller::ImClient.new(client)
    first = im.subscribe_attribute(session, peer, 1_u16, 6_u32, 0_u32, keep_subscriptions: true)
    second = im.subscribe_attribute(session, peer, 1_u16, 6_u32, 0_u32, keep_subscriptions: true)

    read_exchange = 30_u16
    invoke_exchange = 31_u16
    client.enqueue(subscription_message(5_u8,
      Matter::InteractionModel::ReportDataMessage.new.to_slice, read_exchange, peer, true))
    client.enqueue(subscription_message(Matter::InteractionModel::MessageType::InvokeResponse.value,
      Bytes.empty, invoke_exchange, peer, true))
    client.enqueue(subscription_message(5_u8,
      Matter::InteractionModel::ReportDataMessage.new(subscription_id: 43_u32).to_slice, 20_u16, peer, true))
    client.enqueue(subscription_message(5_u8,
      Matter::InteractionModel::ReportDataMessage.new(subscription_id: 42_u32).to_slice, 21_u16, peer, true))

    first.next_report.first.subscription_id.should eq(42_u32)
    second.next_report.first.subscription_id.should eq(43_u32)
    retained = client.wait_for_any(read_exchange, Matter::Controller::Client::PROTOCOL_INTERACTION_MODEL,
      [5_u8], 1.second)
    retained.should_not be_nil
    retained.try(&.message.payload_header.exchange_id).should eq(read_exchange)
    client.wait_for_any(invoke_exchange, Matter::Controller::Client::PROTOCOL_INTERACTION_MODEL,
      [Matter::InteractionModel::MessageType::InvokeResponse.value], 1.second)
      .try(&.message.payload_header.exchange_id).should eq(invoke_exchange)
    client.enqueue(subscription_message(5_u8,
      Matter::InteractionModel::ReportDataMessage.new(subscription_id: 42_u32).to_slice, 22_u16, peer, true))
    client.enqueue(subscription_message(5_u8,
      Matter::InteractionModel::ReportDataMessage.new(subscription_id: 43_u32).to_slice, 23_u16, peer, true))
    second.next_report.first.subscription_id.should eq(43_u32)
    first.close
    client.enqueue(subscription_message(5_u8,
      Matter::InteractionModel::ReportDataMessage.new(subscription_id: 42_u32).to_slice, 24_u16, peer, true))
    client.receive_message(1.millisecond).should be_nil
    Matter::InteractionModel::StatusResponseMessage.from_slice(client.status_payloads.last).status.should eq(
      Matter::InteractionModel::StatusCode::InvalidSubscription.value)
    expect_raises(Matter::ConfigurationError, /closed/) { first.next_report }

    client.enqueue(subscription_message(5_u8,
      Matter::InteractionModel::ReportDataMessage.new(subscription_id: 42_u32).to_slice, 9_u16, peer))
    client.enqueue(subscription_message(4_u8,
      Matter::InteractionModel::SubscribeResponseMessage.new(42_u32, 60_u16).to_slice, 9_u16, peer))
    reused = im.subscribe_attribute(session, peer, 1_u16, 6_u32, 0_u32, keep_subscriptions: true)
    client.enqueue(subscription_message(5_u8,
      Matter::InteractionModel::ReportDataMessage.new(subscription_id: 42_u32).to_slice, 25_u16, peer, true))
    reused.next_report.first.subscription_id.should eq(42_u32)
    reused.close
    second.close
  ensure
    client.try(&.close)
  end

  it "bounds a priming stream that never finishes its ReportData chunks" do
    client = SubscriptionSpecClient.new
    peer = Socket::IPAddress.new("127.0.0.1", 5540)
    session = Matter::Session::SecureContext.new(session_id: 1_u16, peer_session_id: 1_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16), decryption_key: Bytes.new(16))
    path = Matter::InteractionModel::EventPath.new(endpoint: 1_u16, cluster: 6_u32, event: 0_u32)
    report = Matter::InteractionModel::ReportDataMessage.new(subscription_id: 42_u32,
      more_chunked_messages: true).to_slice
    (Matter::Controller::AttributeSubscription::MAX_REPORT_CHUNKS + 1).times do
      client.scripted_messages << subscription_message(5_u8, report, 7_u16, peer)
    end
    expect_raises(Matter::ProtocolError, /priming exceeded chunk limit/) do
      Matter::Controller::ImClient.new(client).subscribe_events(session, peer, [path])
    end
  ensure
    client.try(&.close)
  end

  it "requests attributes and events in one subscription" do
    client = SubscriptionSpecClient.new
    peer = Socket::IPAddress.new("127.0.0.1", 5540)
    session = Matter::Session::SecureContext.new(session_id: 1_u16, peer_session_id: 1_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16), decryption_key: Bytes.new(16))
    attribute_path = Matter::InteractionModel::AttributePath.new(endpoint: 1_u16,
      cluster: 6_u32, attribute: 0_u32)
    event_path = Matter::InteractionModel::EventPath.new(endpoint: 1_u16,
      cluster: 6_u32, event: 0_u32)
    client.scripted_messages << subscription_message(5_u8,
      Matter::InteractionModel::ReportDataMessage.new(subscription_id: 42_u32).to_slice, 7_u16, peer)
    client.scripted_messages << subscription_message(4_u8,
      Matter::InteractionModel::SubscribeResponseMessage.new(42_u32, 60_u16).to_slice, 7_u16, peer)
    Matter::Controller::ImClient.new(client).subscribe(session, peer,
      attribute_paths: [attribute_path], event_paths: [event_path])
    request = Matter::InteractionModel::SubscribeRequestMessage.from_slice(client.request_payloads.first)
    request.attribute_requests.should eq([attribute_path])
    request.event_requests.should eq([event_path])
    request.keep_subscriptions?.should be_false
  ensure
    client.try(&.close)
  end

  it "passes KeepSubscriptions through mixed and event subscription APIs" do
    peer = Socket::IPAddress.new("127.0.0.1", 5540)
    session = Matter::Session::SecureContext.new(session_id: 1_u16, peer_session_id: 1_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16), decryption_key: Bytes.new(16))
    attribute_path = Matter::InteractionModel::AttributePath.new(endpoint: 1_u16,
      cluster: 6_u32, attribute: 0_u32)
    event_path = Matter::InteractionModel::EventPath.new(endpoint: 1_u16,
      cluster: 6_u32, event: 0_u32)
    clients = [] of SubscriptionSpecClient
    2.times do
      client = SubscriptionSpecClient.new
      clients << client
      client.scripted_messages << subscription_message(5_u8,
        Matter::InteractionModel::ReportDataMessage.new(subscription_id: 42_u32).to_slice, 7_u16, peer)
      client.scripted_messages << subscription_message(4_u8,
        Matter::InteractionModel::SubscribeResponseMessage.new(42_u32, 60_u16).to_slice, 7_u16, peer)
    end

    Matter::Controller::ImClient.new(clients[0]).subscribe(session, peer,
      attribute_paths: [attribute_path], event_paths: [event_path], keep_subscriptions: true)
    Matter::Controller::ImClient.new(clients[1]).subscribe_events(session, peer,
      [event_path], keep_subscriptions: true)
    clients.each do |client|
      request = Matter::InteractionModel::SubscribeRequestMessage.from_slice(client.request_payloads.first)
      request.keep_subscriptions?.should be_true
    end
  ensure
    clients.try &.each(&.close)
  end

  it "passes KeepSubscriptions through attribute subscription APIs" do
    peer = Socket::IPAddress.new("127.0.0.1", 5540)
    session = Matter::Session::SecureContext.new(session_id: 1_u16, peer_session_id: 1_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16), decryption_key: Bytes.new(16))
    path = Matter::InteractionModel::AttributePath.new(endpoint: 1_u16,
      cluster: 6_u32, attribute: 0_u32)
    clients = [] of SubscriptionSpecClient
    2.times do
      client = SubscriptionSpecClient.new
      clients << client
      client.scripted_messages << subscription_message(5_u8,
        Matter::InteractionModel::ReportDataMessage.new(subscription_id: 42_u32).to_slice, 7_u16, peer)
      client.scripted_messages << subscription_message(4_u8,
        Matter::InteractionModel::SubscribeResponseMessage.new(42_u32, 60_u16).to_slice, 7_u16, peer)
    end

    Matter::Controller::ImClient.new(clients[0]).subscribe_attributes(session, peer,
      [path], keep_subscriptions: true)
    Matter::Controller::ImClient.new(clients[1]).subscribe_attribute(session, peer,
      1_u16, 6_u32, 0_u32, keep_subscriptions: true)
    clients.each do |client|
      request = Matter::InteractionModel::SubscribeRequestMessage.from_slice(client.request_payloads.first)
      request.keep_subscriptions?.should be_true
    end
  ensure
    clients.try &.each(&.close)
  end

  it "subscribes to events without attribute paths and rejects event status errors" do
    client = SubscriptionSpecClient.new
    peer = Socket::IPAddress.new("127.0.0.1", 5540)
    session = Matter::Session::SecureContext.new(session_id: 1_u16, peer_session_id: 1_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16), decryption_key: Bytes.new(16))
    path = Matter::InteractionModel::EventPath.new(endpoint: 1_u16, cluster: 6_u32, event: 0_u32)
    event = Matter::InteractionModel::EventDataIB.new(path, 8_u64,
      Matter::InteractionModel::EventPriority::Info)
    report = Matter::InteractionModel::ReportDataMessage.new(subscription_id: 42_u32,
      event_reports: [Matter::InteractionModel::EventReportIB.new(event_data: event)])
    client.scripted_messages << subscription_message(5_u8, report.to_slice, 7_u16, peer)
    response = Matter::InteractionModel::SubscribeResponseMessage.new(42_u32, 60_u16)
    client.scripted_messages << subscription_message(4_u8, response.to_slice, 7_u16, peer)
    subscription = Matter::Controller::ImClient.new(client).subscribe_events(session, peer,
      [path], event_min: 8_u64)
    subscription.initial_reports.first.event_reports.try(&.first.event_data.try(&.event_number)).should eq(8_u64)
    request = Matter::InteractionModel::SubscribeRequestMessage.from_slice(client.request_payloads.first)
    request.attribute_requests.should be_nil
    request.event_requests.should eq([path])
    request.event_filters.try(&.first.event_min).should eq(8_u64)

    failed = Matter::InteractionModel::ReportDataMessage.new(subscription_id: 42_u32,
      event_reports: [Matter::InteractionModel::EventReportIB.new(
        event_status: Matter::InteractionModel::EventStatusIB.new(path,
          Matter::InteractionModel::StatusIB.new(Matter::InteractionModel::StatusCode::UnsupportedEvent.value)))])
    client.scripted_messages << subscription_message(5_u8, failed.to_slice, 9_u16, peer, true)
    expect_raises(Matter::ProtocolError, /Subscription event status/) { subscription.next_report }
  ensure
    client.try(&.close)
  end

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
