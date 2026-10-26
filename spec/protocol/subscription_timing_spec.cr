require "../spec_helper"
require "../../src/matter/cluster/on_off"
require "../../src/matter/protocol/message_handler"

private def subscription_timing_fixture(min_interval : UInt16, max_interval : UInt16)
  transport = Matter::Spec::CaptureTransport.new_for_spec
  handler = Matter::Protocol::MessageHandler.new(
    transport: transport,
    setup_pin: 20202021_u32,
    discriminator: 3840_u16,
    fabric_table: Matter::FabricTable.new(Matter::Storage::Memory.new)
  )
  endpoint = Matter::Endpoint.new(endpoint(1_u16))
  on_off = build(Matter::Cluster::OnOff, 1_u16)
  endpoint.add_cluster(on_off)
  handler.node.add_endpoint(endpoint)
  handler.setup_cluster_notifications

  session = Matter::Spec::ProtocolMessages.case_session(1_u16)
  handler.sessions[session.session_id] = session
  subscription = Matter::Protocol::ActiveSubscription.new(
    subscription_id: 7_u32,
    min_interval: min_interval,
    max_interval: max_interval,
    peer: Socket::IPAddress.new("127.0.0.1", 5540),
    session: session,
    attribute_paths: [Matter::InteractionModel::AttributePath.new(
      endpoint: 1_u16,
      cluster: Matter::Cluster::OnOff::CLUSTER_ID,
      attribute: Matter::Cluster::OnOff::ATTR_ON_OFF
    )],
    exchange_id: 11_u16
  )
  handler.active_subscriptions[subscription.subscription_id] = subscription
  transport.sent_packets.clear
  {handler, transport, subscription}
end

private def timing_report(packet_bytes : Bytes, session : Matter::Session::SecureContext)
  packet = Matter::Codec::MessageCodec::Base.decode_packet(packet_bytes)
  header_bytes = packet_bytes[0, packet_bytes.size - packet.payload.size]
  nonce = Matter::Session::SecureMessage.build_nonce(
    session.local_node_id.as(Matter::DataType::NodeId).id,
    packet.header.message_id,
    header_bytes[Matter::Codec::MessageCodec::SECURITY_FLAGS_OFFSET]
  )
  plaintext = Matter::Crypto::StandardCrypto.new.decrypt(session.encryption_key, packet.payload, nonce, header_bytes)
  payload = Matter::Codec::MessageCodec::Base.decode_payload(
    Matter::Codec::MessageCodec::Packet.new(packet.header, plaintext)).payload
  Matter::InteractionModel::ReportDataMessage.from_slice(payload)
end

describe "Subscription reporting intervals" do
  it "runs the heartbeat through the background sweep" do
    handler, transport, subscription = subscription_timing_fixture(0_u16, 1_u16)
    deadline = Time.monotonic + 3.seconds
    until transport.sent_packets.size > 0 || Time.monotonic >= deadline
      sleep 10.milliseconds
    end

    transport.sent_packets.size.should be >= 1
    handler.active_subscriptions.has_key?(subscription.subscription_id).should be_true
    handler.close
  end

  it "sends a max-interval heartbeat and retains a quiet subscription" do
    handler, transport, subscription = subscription_timing_fixture(0_u16, 1_u16)
    now = Time.utc
    subscription.last_report_time = now - 2.seconds

    handler.subscriptions.tick(now)
    handler.process_expired_subscriptions(now).should eq(0)

    transport.sent_packets.size.should eq(1)
    report = timing_report(transport.sent_packets.first[0], subscription.session)
    report.subscription_id.should eq(subscription.subscription_id)
    report.attribute_reports.should be_nil
    report.event_reports.should be_nil
    handler.active_subscriptions.has_key?(subscription.subscription_id).should be_true
    handler.close
  end

  it "coalesces attribute changes until the minimum interval" do
    handler, transport, subscription = subscription_timing_fixture(10_u16, 30_u16)
    now = Time.utc
    subscription.last_report_time = now
    attribute = Matter::Cluster::OnOff::ATTR_ON_OFF
    cluster = Matter::Cluster::OnOff::CLUSTER_ID

    handler.notify_subscriptions(1_u16, cluster, attribute)
    handler.notify_subscriptions(1_u16, cluster, attribute)
    transport.sent_packets.should be_empty

    subscription.last_report_time = now - 10.seconds
    handler.subscriptions.tick(now)
    transport.sent_packets.size.should eq(1)
    report = timing_report(transport.sent_packets.first[0], subscription.session)
    report.subscription_id.should eq(subscription.subscription_id)
    report.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB)).size.should eq(1)
    handler.close
  end

  it "replays an unacknowledged update after CASE session renewal" do
    handler, transport, subscription = subscription_timing_fixture(0_u16, 60_u16)
    handler.notify_subscriptions(1_u16, Matter::Cluster::OnOff::CLUSTER_ID,
      Matter::Cluster::OnOff::ATTR_ON_OFF)
    transport.sent_packets.size.should eq(1)

    renewed = Matter::Spec::ProtocolMessages.case_session(2_u16)
    handler.sessions[renewed.session_id] = renewed
    subscription.session = renewed
    handler.subscriptions.tick

    transport.sent_packets.size.should eq(2)
    report = timing_report(transport.sent_packets.last[0], renewed)
    report.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB)).size.should eq(1)
    handler.close
  end

  it "terminates an update that never receives an IM status before MaxInterval" do
    handler, transport, subscription = subscription_timing_fixture(0_u16, 600_u16)
    handler.notify_subscriptions(1_u16, Matter::Cluster::OnOff::CLUSTER_ID,
      Matter::Cluster::OnOff::ATTR_ON_OFF)
    transport.sent_packets.size.should eq(1)

    handler.subscriptions.tick(Time.utc, monotonic_now: Time.monotonic + 31.seconds)

    handler.active_subscriptions.has_key?(subscription.subscription_id).should be_false
    transport.sent_packets.size.should eq(1)
    handler.close
  end
end
