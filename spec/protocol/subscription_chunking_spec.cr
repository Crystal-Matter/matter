require "../spec_helper"

require "../../src/matter/cluster/on_off"
require "../../src/matter/protocol/message_handler"

private PEER          = Socket::IPAddress.new("127.0.0.1", 5540)
private EXCHANGE_ID   = 7_u16
private FIRST_COUNTER = 5_u32

# Records which persistence hooks the protocol layer fires.
private class RecordingPersistence < Matter::Protocol::Persistence::Base
  getter established_subscriptions : Array(UInt32) = [] of UInt32

  def restore(registry : Matter::Protocol::SessionRegistry, fabric_table : Matter::FabricTable) : Nil
  end

  def session_established(registry : Matter::Protocol::SessionRegistry, session : Matter::Session::SecureContext) : Nil
  end

  def session_updated(registry : Matter::Protocol::SessionRegistry, session : Matter::Session::SecureContext) : Nil
  end

  def session_removed(registry : Matter::Protocol::SessionRegistry, session_id : UInt16) : Nil
  end

  def subscription_established(registry : Matter::Protocol::SessionRegistry, subscription : Matter::Protocol::ActiveSubscription) : Nil
    @established_subscriptions << subscription.subscription_id
  end

  def subscription_removed(registry : Matter::Protocol::SessionRegistry, subscription_id : UInt32) : Nil
  end
end

private record ChunkFixture,
  handler : Matter::Protocol::MessageHandler,
  transport : Matter::Spec::CaptureTransport,
  session : Matter::Session::SecureContext,
  persistence : RecordingPersistence

# A subscription whose priming report has one chunk still to send.
private def pending_subscription_fixture : ChunkFixture
  transport = Matter::Spec::CaptureTransport.new_for_spec
  storage = Matter::Storage::Memory.new
  persistence = RecordingPersistence.new
  handler = Matter::Protocol::MessageHandler.new(
    transport: transport,
    setup_pin: 20202021_u32,
    discriminator: 3840_u16,
    fabric_table: Matter::FabricTable.new(storage),
    persistence: persistence
  )

  session = Matter::Spec::ProtocolMessages.case_session(1_u16)
  handler.sessions[session.session_id] = session

  handler.subscriptions.await_subscription(
    EXCHANGE_ID,
    Matter::Protocol::SubscriptionManager::PendingSubscription.new(
      subscription_id: 42_u32,
      min_interval: 0_u16,
      max_interval: 60_u16,
      attribute_paths: [Matter::InteractionModel::AttributePath.new(
        endpoint: 1_u16,
        cluster: Matter::Cluster::OnOff::CLUSTER_ID,
        attribute: Matter::Cluster::OnOff::ATTR_ON_OFF
      )],
      peer: PEER,
      session: session,
      remaining_chunks: [Bytes[0x18]]
    )
  )

  ChunkFixture.new(handler, transport, session, persistence)
end

private def sent_message_types(fixture : ChunkFixture) : Array(UInt8?)
  fixture.transport.sent_packets.map do |packet_bytes, _|
    Matter::Spec::ProtocolMessages.decode_message_type(packet_bytes, fixture.session)
  end
end

describe "Subscription chunk ladder" do
  report_data = Matter::InteractionModel::MessageType::ReportData.value
  subscribe_response = Matter::InteractionModel::MessageType::SubscribeResponse.value

  it "sends the remaining chunk then the SubscribeResponse when acknowledged by StatusResponse" do
    fixture = pending_subscription_fixture

    fixture.handler.handle_message(
      Matter::Spec::ProtocolMessages.status_response(fixture.session, FIRST_COUNTER, EXCHANGE_ID), PEER)
    sent_message_types(fixture).should eq([report_data])

    fixture.handler.handle_message(
      Matter::Spec::ProtocolMessages.status_response(fixture.session, FIRST_COUNTER + 1, EXCHANGE_ID), PEER)
    sent_message_types(fixture).should eq([report_data, subscribe_response])

    fixture.handler.active_subscriptions.keys.should eq([42_u32])
    fixture.persistence.established_subscriptions.should eq([42_u32])

    fixture.handler.close
  end

  it "drives the same ladder from bare MRP acknowledgements, as iOS sends" do
    fixture = pending_subscription_fixture

    fixture.handler.handle_message(
      Matter::Spec::ProtocolMessages.standalone_ack(fixture.session, FIRST_COUNTER, EXCHANGE_ID), PEER)
    sent_message_types(fixture).should eq([report_data])

    fixture.handler.handle_message(
      Matter::Spec::ProtocolMessages.standalone_ack(fixture.session, FIRST_COUNTER + 1, EXCHANGE_ID), PEER)
    sent_message_types(fixture).should eq([report_data, subscribe_response])

    fixture.handler.active_subscriptions.keys.should eq([42_u32])

    # The acknowledgement path used to skip persistence, so a subscription
    # completed by an iOS controller was lost on restart.
    fixture.persistence.established_subscriptions.should eq([42_u32])

    fixture.handler.close
  end

  it "abandons the subscription when the controller rejects a chunk" do
    fixture = pending_subscription_fixture

    fixture.handler.handle_message(
      Matter::Spec::ProtocolMessages.status_response(
        fixture.session, FIRST_COUNTER, EXCHANGE_ID,
        status: Matter::InteractionModel::StatusCode::Failure.value
      ), PEER)

    fixture.transport.sent_packets.should be_empty
    fixture.handler.active_subscriptions.should be_empty
    fixture.persistence.established_subscriptions.should be_empty

    fixture.handler.close
  end

  it "acknowledges a StatusResponse that belongs to no chunked exchange" do
    fixture = pending_subscription_fixture
    other_exchange = EXCHANGE_ID &+ 1_u16

    fixture.handler.handle_message(
      Matter::Spec::ProtocolMessages.status_response(fixture.session, FIRST_COUNTER, other_exchange), PEER)

    # A Secure Channel standalone ACK, not an Interaction Model message.
    sent_message_types(fixture).should eq([nil])

    fixture.handler.close
  end
end

describe "Invoke response chunk ladder" do
  it "sends each remaining InvokeResponse after Status.Success and stops at the last chunk" do
    fixture = pending_subscription_fixture
    fixture.handler.subscriptions.await_invoke(EXCHANGE_ID &+ 1_u16,
      Matter::Protocol::SubscriptionManager::PendingInvoke.new(
        PEER, fixture.session, [Bytes[0x18], Bytes[0x18]]))

    fixture.handler.handle_message(
      Matter::Spec::ProtocolMessages.status_response(fixture.session, FIRST_COUNTER, EXCHANGE_ID &+ 1_u16), PEER)
    fixture.handler.handle_message(
      Matter::Spec::ProtocolMessages.status_response(fixture.session, FIRST_COUNTER + 1, EXCHANGE_ID &+ 1_u16), PEER)
    fixture.handler.handle_message(
      Matter::Spec::ProtocolMessages.status_response(fixture.session, FIRST_COUNTER + 2, EXCHANGE_ID &+ 1_u16), PEER)

    sent_message_types(fixture).should eq([
      Matter::InteractionModel::MessageType::InvokeResponse.value,
      Matter::InteractionModel::MessageType::InvokeResponse.value,
      nil,
    ])
    fixture.handler.close
  end

  it "does not advance another session's exchange with the same ID" do
    fixture = pending_subscription_fixture
    other_session = Matter::Spec::ProtocolMessages.case_session(2_u16)
    fixture.handler.sessions[other_session.session_id] = other_session
    fixture.handler.subscriptions.await_invoke(EXCHANGE_ID &+ 1_u16,
      Matter::Protocol::SubscriptionManager::PendingInvoke.new(
        PEER, fixture.session, [Bytes[0x18]]))

    fixture.handler.handle_message(
      Matter::Spec::ProtocolMessages.status_response(other_session, FIRST_COUNTER, EXCHANGE_ID &+ 1_u16), PEER)
    sent_message_types(fixture).should eq([nil])

    fixture.handler.handle_message(
      Matter::Spec::ProtocolMessages.status_response(fixture.session, FIRST_COUNTER, EXCHANGE_ID &+ 1_u16), PEER)
    sent_message_types(fixture).last.should eq Matter::InteractionModel::MessageType::InvokeResponse.value
    fixture.handler.close
  end

  it "stops sending invoke chunks after a rejection" do
    fixture = pending_subscription_fixture
    fixture.handler.subscriptions.await_invoke(EXCHANGE_ID &+ 1_u16,
      Matter::Protocol::SubscriptionManager::PendingInvoke.new(
        PEER, fixture.session, [Bytes[0x18]]))

    fixture.handler.handle_message(
      Matter::Spec::ProtocolMessages.status_response(
        fixture.session, FIRST_COUNTER, EXCHANGE_ID &+ 1_u16,
        status: Matter::InteractionModel::StatusCode::Failure.value), PEER)

    fixture.transport.sent_packets.should be_empty
    fixture.handler.close
  end

  it "waits for IM Status.Success after an MRP acknowledgement" do
    fixture = pending_subscription_fixture
    fixture.handler.subscriptions.await_invoke(EXCHANGE_ID &+ 1_u16,
      Matter::Protocol::SubscriptionManager::PendingInvoke.new(
        PEER, fixture.session, [Bytes[0x18]]))

    fixture.handler.handle_message(
      Matter::Spec::ProtocolMessages.standalone_ack(fixture.session, FIRST_COUNTER, EXCHANGE_ID &+ 1_u16), PEER)
    fixture.transport.sent_packets.should be_empty

    fixture.handler.handle_message(
      Matter::Spec::ProtocolMessages.status_response(fixture.session, FIRST_COUNTER + 1, EXCHANGE_ID &+ 1_u16), PEER)
    sent_message_types(fixture).should eq([Matter::InteractionModel::MessageType::InvokeResponse.value])
    fixture.handler.close
  end
end
