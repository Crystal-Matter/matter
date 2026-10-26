require "../spec_helper"

require "../../src/matter/protocol/message_handler"

private PEER        = Socket::IPAddress.new("127.0.0.1", 5540)
private EXCHANGE_ID = 21_u16
private COUNTER     =  3_u32
private ENDPOINT    =  1_u16
private LOCK_EVENT  = Matter::Cluster::DoorLock::EVENT_LOCK_OPERATION

private record RouterFixture,
  handler : Matter::Protocol::MessageHandler,
  transport : Matter::Spec::CaptureTransport,
  session : Matter::Session::SecureContext,
  lock : Matter::Cluster::DoorLock

private def router_fixture : RouterFixture
  transport = Matter::Spec::CaptureTransport.new_for_spec
  handler = Matter::Protocol::MessageHandler.new(
    transport: transport,
    setup_pin: 20202021_u32,
    discriminator: 3840_u16,
    fabric_table: Matter::FabricTable.new(Matter::Storage::Memory.new)
  )

  endpoint = Matter::Endpoint.new(endpoint(ENDPOINT))
  lock = build(Matter::Cluster::DoorLock, ENDPOINT)
  endpoint.add_cluster(lock)
  handler.node.add_endpoint(endpoint)
  handler.setup_cluster_notifications

  session = Matter::Spec::ProtocolMessages.case_session(1_u16)
  handler.sessions[session.session_id] = session
  transport.sent_packets.clear

  RouterFixture.new(handler, transport, session, lock)
end

private def decrypt(packet_bytes : Bytes, session : Matter::Session::SecureContext) : Bytes
  packet = Matter::Codec::MessageCodec::Base.decode_packet(packet_bytes)
  header_bytes = packet_bytes[0, packet_bytes.size - packet.payload.size]
  nonce = Matter::Session::SecureMessage.build_nonce(
    session.local_node_id.as(Matter::DataType::NodeId).id,
    packet.header.message_id,
    header_bytes[Matter::Codec::MessageCodec::SECURITY_FLAGS_OFFSET]
  )
  plaintext = Matter::Crypto::StandardCrypto.new.decrypt(session.encryption_key, packet.payload, nonce, header_bytes)
  Matter::Codec::MessageCodec::Base.decode_payload(
    Matter::Codec::MessageCodec::Packet.new(packet.header, plaintext)).payload
end

private def first_report(fixture : RouterFixture) : Matter::InteractionModel::ReportDataMessage
  packet_bytes, _ = fixture.transport.sent_packets.first
  Matter::InteractionModel::ReportDataMessage.from_slice(decrypt(packet_bytes, fixture.session))
end

private def send(fixture : RouterFixture, message_type : Matter::InteractionModel::MessageType, payload : Bytes) : Nil
  fixture.handler.handle_message(
    Matter::Spec::ProtocolMessages.from_peer(
      session: fixture.session,
      message_type: message_type.value,
      payload: payload,
      message_counter: COUNTER,
      exchange_id: EXCHANGE_ID
    ),
    PEER
  )
end

describe "InteractionRouter event paths" do
  it "answers a ReadRequest carrying event requests with event reports" do
    fixture = router_fixture
    fixture.lock.lock(pin: fixture.lock.default_pin_code)

    send(fixture, Matter::InteractionModel::MessageType::ReadRequest,
      Matter::InteractionModel::ReadRequestMessage.new(
        event_requests: [Matter::InteractionModel::EventPath.new(
          endpoint: ENDPOINT, cluster: Matter::Cluster::DoorLock::CLUSTER_ID, event: LOCK_EVENT)]
      ).to_slice)

    report = first_report(fixture)
    report.attribute_reports.should be_nil
    events = report.event_reports.as(Array(Matter::InteractionModel::EventReportIB))
    events.size.should eq(1)
    events.compact_map(&.event_data).first.path.event.should eq(LOCK_EVENT)
  end

  it "honours event filters on a ReadRequest" do
    fixture = router_fixture
    2.times { fixture.lock.lock(pin: fixture.lock.default_pin_code) }
    latest = fixture.handler.node.event_journal.latest_event_number

    send(fixture, Matter::InteractionModel::MessageType::ReadRequest,
      Matter::InteractionModel::ReadRequestMessage.new(
        event_requests: [Matter::InteractionModel::EventPath.new],
        event_filters: [Matter::InteractionModel::EventFilterIB.new(event_min: latest)]
      ).to_slice)

    events = first_report(fixture).event_reports.as(Array(Matter::InteractionModel::EventReportIB))
    events.compact_map(&.event_data).map(&.event_number).should eq([latest])
  end

  it "ignores a foreign node's event minimum in a wildcard ReadRequest" do
    fixture = router_fixture
    2.times { fixture.lock.lock(pin: fixture.lock.default_pin_code) }
    latest = fixture.handler.node.event_journal.latest_event_number

    send(fixture, Matter::InteractionModel::MessageType::ReadRequest,
      Matter::InteractionModel::ReadRequestMessage.new(
        event_requests: [Matter::InteractionModel::EventPath.new],
        event_filters: [
          Matter::InteractionModel::EventFilterIB.new(event_min: 100_u64, node: 0x3333_u64),
          Matter::InteractionModel::EventFilterIB.new(event_min: latest),
        ]
      ).to_slice)

    events = first_report(fixture).event_reports.as(Array(Matter::InteractionModel::EventReportIB))
    events.compact_map(&.event_data).map(&.event_number).should eq([latest])
  ensure
    fixture.try(&.handler.close)
  end

  it "uses the session's local NodeID for an explicit matching filter" do
    fixture = router_fixture
    2.times { fixture.lock.lock(pin: fixture.lock.default_pin_code) }
    latest = fixture.handler.node.event_journal.latest_event_number

    send(fixture, Matter::InteractionModel::MessageType::ReadRequest,
      Matter::InteractionModel::ReadRequestMessage.new(
        event_requests: [Matter::InteractionModel::EventPath.new],
        event_filters: [Matter::InteractionModel::EventFilterIB.new(event_min: latest, node: 0x1111_u64)]
      ).to_slice)

    events = first_report(fixture).event_reports.as(Array(Matter::InteractionModel::EventReportIB))
    events.compact_map(&.event_data).map(&.event_number).should eq([latest])
  ensure
    fixture.try(&.handler.close)
  end

  it "ignores foreign node filters in a subscription's wildcard priming report" do
    fixture = router_fixture
    2.times { fixture.lock.lock(pin: fixture.lock.default_pin_code) }
    expected = fixture.handler.node.event_journal.query([Matter::InteractionModel::EventPath.new]).map(&.event_number)

    send(fixture, Matter::InteractionModel::MessageType::SubscribeRequest,
      Matter::InteractionModel::SubscribeRequestMessage.new(
        min_interval_floor: 0_u16,
        max_interval_ceiling: 60_u16,
        event_requests: [Matter::InteractionModel::EventPath.new],
        event_filters: [Matter::InteractionModel::EventFilterIB.new(event_min: 100_u64, node: 0x3333_u64)]
      ).to_slice)

    events = first_report(fixture).event_reports.as(Array(Matter::InteractionModel::EventReportIB))
    events.compact_map(&.event_data).map(&.event_number).should eq(expected)
  ensure
    fixture.try(&.handler.close)
  end

  it "returns attribute and event reports in the same ReportData" do
    fixture = router_fixture
    fixture.lock.lock(pin: fixture.lock.default_pin_code)

    send(fixture, Matter::InteractionModel::MessageType::ReadRequest,
      Matter::InteractionModel::ReadRequestMessage.new(
        attribute_requests: [Matter::InteractionModel::AttributePath.new(
          endpoint: ENDPOINT,
          cluster: Matter::Cluster::DoorLock::CLUSTER_ID,
          attribute: Matter::Cluster::DoorLock::ATTR_LOCK_STATE)],
        event_requests: [Matter::InteractionModel::EventPath.new]
      ).to_slice)

    report = first_report(fixture)
    report.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB)).size.should eq(1)
    report.event_reports.as(Array(Matter::InteractionModel::EventReportIB)).size.should be >= 1
  end

  it "carries the subscribed event paths and cursor onto the active subscription" do
    fixture = router_fixture
    fixture.lock.lock(pin: fixture.lock.default_pin_code)
    latest = fixture.handler.node.event_journal.latest_event_number

    urgent = Matter::InteractionModel::EventPath.new(
      endpoint: ENDPOINT, cluster: Matter::Cluster::DoorLock::CLUSTER_ID, event: LOCK_EVENT, is_urgent: true)
    send(fixture, Matter::InteractionModel::MessageType::SubscribeRequest,
      Matter::InteractionModel::SubscribeRequestMessage.new(
        min_interval_floor: 0_u16,
        max_interval_ceiling: 60_u16,
        event_requests: [urgent]
      ).to_slice)

    # The priming report goes out; acknowledge it to complete the handshake
    fixture.handler.handle_message(
      Matter::Spec::ProtocolMessages.status_response(fixture.session, COUNTER + 1, EXCHANGE_ID), PEER)

    subscription = fixture.handler.active_subscriptions.values.first
    subscription.event_paths.size.should eq(1)
    subscription.event_paths.first.is_urgent?.should be_true
    subscription.last_event_number.should eq(latest)

    fixture.handler.close
  end
end
