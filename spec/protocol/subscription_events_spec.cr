require "../spec_helper"

require "../../src/matter/cluster/on_off"
require "../../src/matter/cluster/wi_fi_network_management"
require "../../src/matter/cluster/access_control"
require "../../src/matter/protocol/message_handler"

private PEER        = Socket::IPAddress.new("127.0.0.1", 5540)
private EXCHANGE_ID = 11_u16
private ENDPOINT    =  1_u16
private LOCK_EVENT  = Matter::Cluster::DoorLock::EVENT_LOCK_OPERATION

private record EventSubscriptionFixture,
  handler : Matter::Protocol::MessageHandler,
  transport : Matter::Spec::CaptureTransport,
  session : Matter::Session::SecureContext,
  lock : Matter::Cluster::DoorLock,
  # The node emits BasicInformation's StartUp event as it comes up, so the
  # subscription starts from whatever the journal already holds.
  base_event_number : UInt64

private class FailingSubscriptionTransport < Matter::Spec::CaptureTransport
  property fail_on_send : Int32? = nil
  getter send_attempts = 0

  protected def transmit(data : Bytes | Slice(UInt8), peer_address : Socket::IPAddress) : Nil
    @send_attempts += 1
    if @fail_on_send == @send_attempts
      raise Matter::TransportError.new("simulated subscription send failure")
    end
    super
  end
end

# A handler with a door lock on endpoint 1 and one active subscription whose
# event paths and damping the caller chooses.
private def event_subscription_fixture(
  event_paths : Array(Matter::InteractionModel::EventPath),
  min_interval : UInt16 = 0_u16,
  transport : Matter::Spec::CaptureTransport = Matter::Spec::CaptureTransport.new_for_spec,
) : EventSubscriptionFixture
  storage = Matter::Storage::Memory.new
  handler = Matter::Protocol::MessageHandler.new(
    transport: transport,
    setup_pin: 20202021_u32,
    discriminator: 3840_u16,
    fabric_table: Matter::FabricTable.new(storage)
  )

  endpoint = Matter::Endpoint.new(endpoint(ENDPOINT))
  lock = build(Matter::Cluster::DoorLock, ENDPOINT)
  endpoint.add_cluster(lock)
  handler.node.add_endpoint(endpoint)
  handler.setup_cluster_notifications

  session = Matter::Spec::ProtocolMessages.case_session(1_u16)
  session.peer_subject_ids = [0x2222_u64]
  handler.sessions[session.session_id] = session

  base_event_number = handler.node.event_journal.latest_event_number
  handler.active_subscriptions[7_u32] = Matter::Protocol::ActiveSubscription.new(
    subscription_id: 7_u32,
    min_interval: min_interval,
    max_interval: 60_u16,
    peer: PEER,
    session: session,
    attribute_paths: [] of Matter::InteractionModel::AttributePath,
    exchange_id: EXCHANGE_ID,
    event_paths: event_paths,
    last_event_number: base_event_number
  )

  transport.sent_packets.clear
  EventSubscriptionFixture.new(handler, transport, session, lock, base_event_number)
end

# The decrypted Interaction Model payload of a packet the node sent.
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

private def reported_events(fixture : EventSubscriptionFixture) : Array(UInt64)
  fixture.transport.sent_packets.select do |packet_bytes, _|
    Matter::Spec::ProtocolMessages.decode_message_type(packet_bytes, fixture.session) ==
      Matter::InteractionModel::MessageType::ReportData.value
  end.flat_map do |packet_bytes, _|
    message = Matter::InteractionModel::ReportDataMessage.from_slice(decrypt(packet_bytes, fixture.session))
    (message.event_reports || [] of Matter::InteractionModel::EventReportIB).compact_map(&.event_data).map(&.event_number)
  end
end

private def acknowledge_event_reports(fixture : EventSubscriptionFixture,
                                      from_index : Int32 = 0, first_counter : UInt32 = 100_u32) : Nil
  index = from_index
  counter = first_counter
  loop do
    packets = fixture.transport.sent_packets.select do |packet_bytes, _|
      Matter::Spec::ProtocolMessages.decode_message_type(packet_bytes, fixture.session) ==
        Matter::InteractionModel::MessageType::ReportData.value
    end
    break if index >= packets.size
    packet_bytes = packets[index][0]
    packet = Matter::Codec::MessageCodec::Base.decode_packet(packet_bytes)
    header_bytes = packet_bytes[0, packet_bytes.size - packet.payload.size]
    nonce = Matter::Session::SecureMessage.build_nonce(
      fixture.session.local_node_id.as(Matter::DataType::NodeId).id,
      packet.header.message_id,
      header_bytes[Matter::Codec::MessageCodec::SECURITY_FLAGS_OFFSET])
    plaintext = Matter::Crypto::StandardCrypto.new.decrypt(
      fixture.session.encryption_key, packet.payload, nonce, header_bytes)
    message = Matter::Codec::MessageCodec::Base.decode_payload(
      Matter::Codec::MessageCodec::Packet.new(packet.header, plaintext))
    fixture.handler.handle_message(
      Matter::Spec::ProtocolMessages.status_response(fixture.session, counter,
        message.payload_header.exchange_id), PEER)
    index += 1
    counter += 1
  end
end

private def lock_event_path(urgent : Bool) : Matter::InteractionModel::EventPath
  Matter::InteractionModel::EventPath.new(
    endpoint: ENDPOINT,
    cluster: Matter::Cluster::DoorLock::CLUSTER_ID,
    event: LOCK_EVENT,
    is_urgent: urgent
  )
end

private def restricted_event_subscription_fixture(paths : Array(Matter::InteractionModel::EventPath))
  fixture = event_subscription_fixture(paths)
  acl = Matter::Cluster::AccessControl.new(endpoint(0))
  fixture.handler.node.clusters[{0_u16, Matter::Cluster::AccessControl::CLUSTER_ID}] = acl
  fixture.session.peer_subject_ids = [0x2222_u64]
  acl.acl << Matter::Cluster::AccessControl::AccessControlEntry.new(
    Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer,
    Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
    [0x2222_u64], nil, 1_u8)
  acl.configure_access_restrictions(1_u8, [
    Matter::Cluster::AccessControl::AccessRestrictionEntry.new(ENDPOINT,
      Matter::Cluster::DoorLock::CLUSTER_ID, [
      Matter::Cluster::AccessControl::AccessRestriction.new(
        Matter::Cluster::AccessControl::AccessRestrictionType::EventForbidden, LOCK_EVENT),
    ]),
  ])
  {fixture, acl}
end

describe "Subscription event reporting" do
  it "skips restricted wildcard events and advances the subscription cursor" do
    fixture, acl = restricted_event_subscription_fixture([Matter::InteractionModel::EventPath.new])
    fixture.handler.node.event_journal.record(ENDPOINT, Matter::Cluster::DoorLock::CLUSTER_ID,
      LOCK_EVENT, :critical, TLV::Any.new(1_u32, nil))
    fixture.handler.subscriptions.notify_events
    fixture.transport.sent_packets.should be_empty
    fixture.handler.active_subscriptions[7_u32].last_event_number.should eq(fixture.base_event_number + 1_u64)

    fixture.handler.node.event_journal.record(ENDPOINT, Matter::Cluster::DoorLock::CLUSTER_ID,
      Matter::Cluster::DoorLock::EVENT_DOOR_LOCK_ALARM, :critical, TLV::Any.new(2_u32, nil))
    fixture.handler.subscriptions.notify_events
    reported_events(fixture).should eq([fixture.base_event_number + 2_u64])
    acl.feature_map.value.should eq(Matter::Cluster::AccessControl::Feature::Extension.value)
    fixture.handler.close
  end

  it "reports AccessRestricted for a concrete restricted event subscription" do
    fixture, _acl = restricted_event_subscription_fixture([lock_event_path(true)])
    fixture.handler.node.event_journal.record(ENDPOINT, Matter::Cluster::DoorLock::CLUSTER_ID,
      LOCK_EVENT, :critical, TLV::Any.new(1_u32, nil))
    fixture.handler.subscriptions.notify_events

    reports = fixture.transport.sent_packets.flat_map do |packet_bytes, _|
      message = Matter::InteractionModel::ReportDataMessage.from_slice(decrypt(packet_bytes, fixture.session))
      message.event_reports || [] of Matter::InteractionModel::EventReportIB
    end
    reports.compact_map(&.event_status).map(&.status.status).should eq([0x9d_u8])
    reports.compact_map(&.event_data).should be_empty
    fixture.handler.active_subscriptions[7_u32].last_event_number.should eq(fixture.base_event_number)
    acknowledge_event_reports(fixture)
    fixture.handler.active_subscriptions[7_u32].last_event_number.should eq(fixture.base_event_number + 1_u64)
    fixture.handler.close
  end

  it "commits a cursor past filtered and reported events only after final IM status" do
    fixture, _acl = restricted_event_subscription_fixture([Matter::InteractionModel::EventPath.new])
    fixture.handler.node.event_journal.record(ENDPOINT, Matter::Cluster::DoorLock::CLUSTER_ID,
      LOCK_EVENT, :critical, TLV::Any.new(1_u32, nil))
    fixture.handler.node.event_journal.record(ENDPOINT, Matter::Cluster::DoorLock::CLUSTER_ID,
      Matter::Cluster::DoorLock::EVENT_DOOR_LOCK_ALARM, :critical, TLV::Any.new(2_u32, nil))

    fixture.handler.subscriptions.notify_events
    reported_events(fixture).should eq([fixture.base_event_number + 2_u64])
    fixture.handler.active_subscriptions[7_u32].last_event_number.should eq(fixture.base_event_number)

    acknowledge_event_reports(fixture)
    fixture.handler.active_subscriptions[7_u32].last_event_number.should eq(fixture.base_event_number + 2_u64)
    fixture.handler.close
  end

  it "drains a journal batch across bounded subscription updates" do
    fixture = event_subscription_fixture([Matter::InteractionModel::EventPath.new])
    count = 40
    count.times do
      fixture.handler.node.event_journal.record(
        ENDPOINT, Matter::Cluster::DoorLock::CLUSTER_ID, LOCK_EVENT, :critical,
        TLV::Any.new("event payload" * 4, nil))
    end

    fixture.handler.subscriptions.notify_events
    acknowledge_event_reports(fixture)

    expected = (fixture.base_event_number + 1_u64..fixture.base_event_number + count.to_u64).to_a
    reported_events(fixture).should eq(expected)
    fixture.transport.sent_packets.size.should be > 1
    fixture.handler.active_subscriptions[7_u32].last_event_number.should eq(expected.last)

    fixture.handler.close
  end

  it "keeps unsent events queued when a later batch fails to send" do
    transport = FailingSubscriptionTransport.new_for_spec
    fixture = event_subscription_fixture([Matter::InteractionModel::EventPath.new], transport: transport)
    40.times do
      fixture.handler.node.event_journal.record(
        ENDPOINT, Matter::Cluster::DoorLock::CLUSTER_ID, LOCK_EVENT, :critical,
        TLV::Any.new("event payload" * 4, nil))
    end
    fixture.handler.subscriptions.notify_events
    transport.fail_on_send = 2
    acknowledge_event_reports(fixture)
    delivered = reported_events(fixture)
    delivered.should_not be_empty
    fixture.handler.active_subscriptions[7_u32].last_event_number.should eq(fixture.base_event_number)

    transport.fail_on_send = nil
    acknowledge_event_reports(fixture, first_counter: 200_u32)
    reported_events(fixture).should eq((fixture.base_event_number + 1_u64..fixture.base_event_number + 40_u64).to_a)
    fixture.handler.active_subscriptions[7_u32].last_event_number.should eq(fixture.base_event_number + 40_u64)
    fixture.handler.close
  end

  it "reports ResourceExhausted for one indivisible event and continues" do
    fixture = event_subscription_fixture([Matter::InteractionModel::EventPath.new])
    fixture.handler.node.event_journal.record(
      ENDPOINT, Matter::Cluster::DoorLock::CLUSTER_ID, LOCK_EVENT, :critical,
      TLV::Any.new("Z" * 1500, nil))
    fixture.handler.subscriptions.notify_events
    acknowledge_event_reports(fixture)

    report_packet = fixture.transport.sent_packets.find do |packet_bytes, _|
      Matter::Spec::ProtocolMessages.decode_message_type(packet_bytes, fixture.session) ==
        Matter::InteractionModel::MessageType::ReportData.value
    end.as(Tuple(Bytes, Socket::IPAddress))[0]
    report = Matter::InteractionModel::ReportDataMessage.from_slice(decrypt(report_packet, fixture.session))
    report.event_reports.as(Array(Matter::InteractionModel::EventReportIB)).first.event_status
      .as(Matter::InteractionModel::EventStatusIB).status.status.should eq(
      Matter::InteractionModel::StatusCode::ResourceExhausted.value)
    fixture.handler.active_subscriptions[7_u32].last_event_number.should eq(fixture.base_event_number + 1_u64)

    fixture.handler.node.event_journal.record(
      ENDPOINT, Matter::Cluster::DoorLock::CLUSTER_ID, LOCK_EVENT, :critical,
      TLV::Any.new("small", nil))
    fixture.handler.subscriptions.notify_events
    acknowledge_event_reports(fixture, from_index: 1)
    reported_events(fixture).should eq([fixture.base_event_number + 2_u64])
    fixture.handler.close
  end

  it "drains the journal from last_event_number on each report" do
    fixture = event_subscription_fixture([Matter::InteractionModel::EventPath.new])

    first = fixture.base_event_number + 1
    fixture.lock.lock(pin: fixture.lock.default_pin_code)
    reported_events(fixture).should eq([first])
    acknowledge_event_reports(fixture)
    fixture.handler.active_subscriptions[7_u32].last_event_number.should eq(first)

    fixture.transport.sent_packets.clear
    fixture.lock.unlock(pin: fixture.lock.default_pin_code)
    # The second report carries only what the first did not
    reported_events(fixture).should eq([first + 1])

    fixture.handler.close
  end

  it "does not report to a subscription that watches no events" do
    fixture = event_subscription_fixture([] of Matter::InteractionModel::EventPath)

    fixture.lock.lock(pin: fixture.lock.default_pin_code)
    fixture.transport.sent_packets.should be_empty

    fixture.handler.close
  end

  it "damps a non-urgent event until the minimum interval has elapsed" do
    fixture = event_subscription_fixture([lock_event_path(false)], min_interval: 60_u16)

    fixture.lock.lock(pin: fixture.lock.default_pin_code)
    fixture.transport.sent_packets.should be_empty
    fixture.handler.active_subscriptions[7_u32].last_event_number.should eq(fixture.base_event_number)

    # Still journaled, so the next report that does go out carries it
    fixture.handler.node.event_journal.latest_event_number.should eq(fixture.base_event_number + 1)

    fixture.handler.close
  end

  it "lets an urgent path bypass the minimum interval" do
    fixture = event_subscription_fixture([lock_event_path(true)], min_interval: 60_u16)

    fixture.lock.lock(pin: fixture.lock.default_pin_code)
    reported_events(fixture).should eq([fixture.base_event_number + 1])

    fixture.handler.close
  end

  it "carries damped events with a coalesced attribute report after the minimum interval" do
    fixture = event_subscription_fixture([lock_event_path(false)], min_interval: 60_u16)
    subscription = fixture.handler.active_subscriptions[7_u32]
    subscription.attribute_paths << Matter::InteractionModel::AttributePath.new(
      endpoint: ENDPOINT,
      cluster: Matter::Cluster::DoorLock::CLUSTER_ID,
      attribute: Matter::Cluster::DoorLock::ATTR_LOCK_STATE
    )

    fixture.lock.lock(pin: fixture.lock.default_pin_code)
    fixture.transport.sent_packets.clear

    fixture.handler.notify_subscriptions(ENDPOINT, Matter::Cluster::DoorLock::CLUSTER_ID, Matter::Cluster::DoorLock::ATTR_LOCK_STATE)
    fixture.transport.sent_packets.should be_empty
    subscription.last_report_time = Time.utc - 60.seconds
    fixture.handler.subscriptions.tick
    reported_events(fixture).should eq([fixture.base_event_number + 1])

    fixture.handler.close
  end

  it "hides a fabric scoped event from a subscriber on another fabric" do
    fixture = event_subscription_fixture([Matter::InteractionModel::EventPath.new])
    other_fabric = fixture.session.fabric_index.as(UInt8) + 1_u8

    fixture.handler.node.event_journal.record(
      ENDPOINT, Matter::Cluster::DoorLock::CLUSTER_ID, LOCK_EVENT, :critical,
      TLV::Any.new(1_u32, nil), fabric_index: other_fabric)
    fixture.handler.subscriptions.notify_events

    fixture.transport.sent_packets.should be_empty

    fixture.handler.close
  end
end

describe "Subscription attribute policy changes" do
  it "reports AccessRestricted after a CASE subscriber's fabric gains an ARL restriction" do
    fixture = event_subscription_fixture([] of Matter::InteractionModel::EventPath)
    wifi = build(Matter::Cluster::WiFiNetworkManagement, ENDPOINT)
    fixture.handler.node.clusters[{ENDPOINT, Matter::Cluster::WiFiNetworkManagement::CLUSTER_ID}] = wifi
    path = Matter::InteractionModel::AttributePath.new(endpoint: ENDPOINT,
      cluster: Matter::Cluster::WiFiNetworkManagement::CLUSTER_ID,
      attribute: Matter::Cluster::WiFiNetworkManagement::ATTR_SSID)
    fixture.handler.active_subscriptions[7_u32].attribute_paths = [path]
    acl = Matter::Cluster::AccessControl.new(endpoint(0))
    fixture.handler.node.clusters[{0_u16, Matter::Cluster::AccessControl::CLUSTER_ID}] = acl
    acl.acl << Matter::Cluster::AccessControl::AccessControlEntry.new(
      Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer,
      Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
      [0x2222_u64], nil, 1_u8)

    initial = Matter::Protocol::IMHandler.read_attributes([path], fixture.handler.node.clusters,
      fabric_index: 1_u8, is_case_session: true, peer_subject_ids: fixture.session.peer_subject_ids)
    initial.compact_map(&.attribute_data).size.should eq(1)
    acl.configure_access_restrictions(1_u8, [
      Matter::Cluster::AccessControl::AccessRestrictionEntry.new(ENDPOINT,
        Matter::Cluster::WiFiNetworkManagement::CLUSTER_ID, [
        Matter::Cluster::AccessControl::AccessRestriction.new(
          Matter::Cluster::AccessControl::AccessRestrictionType::AttributeAccessForbidden,
          Matter::Cluster::WiFiNetworkManagement::ATTR_SSID),
      ]),
    ])
    fixture.handler.subscriptions.notify(ENDPOINT, Matter::Cluster::WiFiNetworkManagement::CLUSTER_ID,
      Matter::Cluster::WiFiNetworkManagement::ATTR_SSID)
    reports = fixture.transport.sent_packets.flat_map do |packet_bytes, _|
      message = Matter::InteractionModel::ReportDataMessage.from_slice(decrypt(packet_bytes, fixture.session))
      message.attribute_reports || [] of Matter::InteractionModel::AttributeReportIB
    end
    reports.compact_map(&.attribute_status).map(&.status.status).should eq([0x9d_u8])
    reports.compact_map(&.attribute_data).should be_empty
    fixture.handler.close
  end
end

describe Matter::Protocol::ActiveSubscription do
  it "round trips event paths and the event cursor through its record" do
    session = Matter::Spec::ProtocolMessages.case_session(1_u16)
    subscription = Matter::Protocol::ActiveSubscription.new(
      subscription_id: 3_u32,
      min_interval: 1_u16,
      max_interval: 60_u16,
      peer: PEER,
      session: session,
      attribute_paths: [] of Matter::InteractionModel::AttributePath,
      exchange_id: EXCHANGE_ID,
      event_paths: [lock_event_path(true), Matter::InteractionModel::EventPath.new],
      last_event_number: 12_u64
    )

    document = subscription.to_record.to_document
    restored = Matter::Protocol::ActiveSubscription.from_record(
      Matter::Protocol::ActiveSubscription::SubscriptionRecord.from_document(document), session)

    restored.last_event_number.should eq(12_u64)
    restored.event_paths.size.should eq(2)
    restored.event_paths.first.endpoint.should eq(ENDPOINT)
    restored.event_paths.first.event.should eq(LOCK_EVENT)
    restored.event_paths.first.is_urgent?.should be_true
    restored.event_paths.last.endpoint.should be_nil
    restored.event_paths.last.is_urgent?.should be_false
  end

  it "restores a document written before event subscriptions existed" do
    session = Matter::Spec::ProtocolMessages.case_session(1_u16)
    legacy = Matter::Protocol::ActiveSubscription.new(
      subscription_id: 3_u32,
      min_interval: 1_u16,
      max_interval: 60_u16,
      peer: PEER,
      session: session,
      attribute_paths: [Matter::InteractionModel::AttributePath.new(endpoint: 1_u16, cluster: 6_u32, attribute: 0_u32)],
      exchange_id: EXCHANGE_ID
    ).to_record.to_document
    legacy.delete("event_paths")
    legacy.delete("last_event_number")

    restored = Matter::Protocol::ActiveSubscription.from_record(
      Matter::Protocol::ActiveSubscription::SubscriptionRecord.from_document(legacy), session)

    restored.event_paths.should be_empty
    restored.last_event_number.should eq(0_u64)
    restored.events?.should be_false
    restored.attribute_paths.size.should eq(1)
  end
end
