require "../spec_helper"

require "../../src/matter/cluster/on_off"
require "../../src/matter/codec/message_codec"
require "../../src/matter/crypto/crypto"
require "../../src/matter/datatype/node_id"
require "../../src/matter/protocol/message_handler"
require "../../src/matter/session/secure_message"
require "../../src/matter/transport/udp_transport"

private class OversizedSubscriptionOnOff < Matter::Cluster::OnOff
  def read_attribute(attribute_id : UInt32, fabric_index : UInt8? = nil) : Matter::InteractionModel::Status | TLV::Any
    return TLV::Any.new("X" * 1500, nil) if attribute_id == ATTR_ON_OFF
    super
  end
end

private class LargeListSubscriptionOnOff < Matter::Cluster::OnOff
  def values : Array(String)
    Array.new(20) { |index| "#{index}:" + "A" * 100 }
  end

  def read_attribute(attribute_id : UInt32, fabric_index : UInt8? = nil) : Matter::InteractionModel::Status | TLV::Any
    return TLV::Any.from_slice(values.to_tlv) if attribute_id == ATTR_ON_OFF
    super
  end
end

private def subscription_report(packet_bytes : Bytes, session : Matter::Session::SecureContext)
  packet = Matter::Codec::MessageCodec::Base.decode_packet(packet_bytes)
  header_bytes = packet_bytes[0, packet_bytes.size - packet.payload.size]
  nonce = Matter::Session::SecureMessage.build_nonce(
    session.local_node_id.as(Matter::DataType::NodeId).id,
    packet.header.message_id,
    header_bytes[Matter::Codec::MessageCodec::SECURITY_FLAGS_OFFSET])
  plaintext = Matter::Crypto::StandardCrypto.new.decrypt(session.encryption_key, packet.payload, nonce, header_bytes)
  message = Matter::Codec::MessageCodec::Base.decode_payload(
    Matter::Codec::MessageCodec::Packet.new(packet.header, plaintext))
  {message, Matter::InteractionModel::ReportDataMessage.from_slice(message.payload.to_slice)}
end

describe "Subscription report exchange regression" do
  it "reports ResourceExhausted for an indivisible oversized UDP attribute" do
    transport = Matter::Spec::CaptureTransport.new_for_spec
    handler = Matter::Protocol::MessageHandler.new(
      transport: transport, setup_pin: 20202021_u32, discriminator: 3840_u16,
      fabric_table: Matter::FabricTable.new(Matter::Storage::Memory.new))
    cluster = OversizedSubscriptionOnOff.new(endpoint(1))
    handler.clusters[{1_u16, Matter::Cluster::OnOff::CLUSTER_ID}] = cluster
    session = Matter::Session::SecureContext.new(
      session_id: 21_u16, peer_session_id: 22_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16, 0x11_u8), decryption_key: Bytes.new(16, 0x22_u8),
      peer_node_id: Matter::DataType::NodeId.new(0x2222_u64),
      local_node_id: Matter::DataType::NodeId.new(0x1111_u64),
      case_session: true, fabric_index: 1_u8)
    session.peer_subject_ids = [session.peer_node_id.as(Matter::DataType::NodeId).id]
    subscription = Matter::Protocol::ActiveSubscription.new(
      subscription_id: 3_u32, min_interval: 0_u16, max_interval: 60_u16,
      peer: Socket::IPAddress.new("127.0.0.1", 5540), session: session,
      attribute_paths: [Matter::InteractionModel::AttributePath.new(
        endpoint: 1_u16, cluster: Matter::Cluster::OnOff::CLUSTER_ID,
        attribute: Matter::Cluster::OnOff::ATTR_ON_OFF)], exchange_id: 1_u16)
    handler.active_subscriptions[subscription.subscription_id] = subscription
    before = subscription.last_report_time

    handler.notify_subscriptions(1_u16, Matter::Cluster::OnOff::CLUSTER_ID,
      Matter::Cluster::OnOff::ATTR_ON_OFF)

    transport.sent_packets.size.should eq(1)
    _message, report = subscription_report(transport.sent_packets.first[0], session)
    report.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB)).first.attribute_status
      .as(Matter::InteractionModel::AttributeStatusIB).status.status.should eq(
      Matter::InteractionModel::StatusCode::ResourceExhausted.value)
    subscription.last_report_time.should be >= before
    handler.close
  end

  it "chunks a large active list update on one exchange after IM status acknowledgements" do
    transport = Matter::Spec::CaptureTransport.new_for_spec
    handler = Matter::Protocol::MessageHandler.new(
      transport: transport, setup_pin: 20202021_u32, discriminator: 3840_u16,
      fabric_table: Matter::FabricTable.new(Matter::Storage::Memory.new))
    cluster = LargeListSubscriptionOnOff.new(endpoint(1))
    handler.clusters[{1_u16, Matter::Cluster::OnOff::CLUSTER_ID}] = cluster
    session = Matter::Spec::ProtocolMessages.case_session(21_u16)
    session.peer_subject_ids = [session.peer_node_id.as(Matter::DataType::NodeId).id]
    handler.sessions[session.session_id] = session
    subscription = Matter::Protocol::ActiveSubscription.new(
      subscription_id: 3_u32, min_interval: 0_u16, max_interval: 60_u16,
      peer: Socket::IPAddress.new("127.0.0.1", 5540), session: session,
      attribute_paths: [Matter::InteractionModel::AttributePath.new(
        endpoint: 1_u16, cluster: Matter::Cluster::OnOff::CLUSTER_ID,
        attribute: Matter::Cluster::OnOff::ATTR_ON_OFF)], exchange_id: 1_u16)
    handler.active_subscriptions[subscription.subscription_id] = subscription
    handler.sender.next_exchange_id = 0xBEEF_u16
    peer = subscription.peer

    handler.notify_subscriptions(1_u16, Matter::Cluster::OnOff::CLUSTER_ID,
      Matter::Cluster::OnOff::ATTR_ON_OFF)
    transport.sent_packets.size.should eq(1)
    first, first_report = subscription_report(transport.sent_packets.first[0], session)
    first.payload_header.exchange_id.should eq(0xBEEF_u16)
    first_report.more_chunked_messages.should be_true

    # Transport delivery alone does not acknowledge an Interaction Model report.
    handler.handle_message(Matter::Spec::ProtocolMessages.standalone_ack(session, 5_u32, 0xBEEF_u16), peer)
    handler.notify_subscriptions(1_u16, Matter::Cluster::OnOff::CLUSTER_ID,
      Matter::Cluster::OnOff::ATTR_ON_OFF)
    transport.sent_packets.size.should eq(1)

    reports = [first_report]
    counter = 6_u32
    while reports.last.more_chunked_messages
      handler.handle_message(Matter::Spec::ProtocolMessages.status_response(session, counter, 0xBEEF_u16), peer)
      counter += 1
      next_message, next_report = subscription_report(transport.sent_packets.last[0], session)
      next_message.payload_header.exchange_id.should eq(0xBEEF_u16)
      reports << next_report
    end
    reports.size.should be > 1
    data = reports.flat_map do |report|
      report.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB)).compact_map(&.attribute_data)
    end
    restored = data.first.data.as_list.map(&.value.as(String)) + data[1..].map(&.data.value.as(String))
    restored.should eq(cluster.values)
    # A second change notified during the in-flight transaction is retained.
    handler.handle_message(Matter::Spec::ProtocolMessages.status_response(session, counter, 0xBEEF_u16), peer)
    handler.subscriptions.tick
    reports_sent = transport.sent_packets.select do |packet_bytes, _|
      Matter::Spec::ProtocolMessages.decode_message_type(packet_bytes, session) ==
        Matter::InteractionModel::MessageType::ReportData.value
    end
    reports_sent.size.should be > reports.size
    next_message, _next_report = subscription_report(reports_sent.last[0], session)
    next_message.payload_header.exchange_id.should_not eq(0xBEEF_u16)
    handler.close
  end

  it "terminates an active subscription after a rejected ReportData" do
    transport = Matter::Spec::CaptureTransport.new_for_spec
    handler = Matter::Protocol::MessageHandler.new(
      transport: transport, setup_pin: 20202021_u32, discriminator: 3840_u16,
      fabric_table: Matter::FabricTable.new(Matter::Storage::Memory.new))
    cluster = Matter::Cluster::OnOff.new(endpoint(1))
    handler.clusters[{1_u16, Matter::Cluster::OnOff::CLUSTER_ID}] = cluster
    session = Matter::Spec::ProtocolMessages.case_session(21_u16)
    session.peer_subject_ids = [session.peer_node_id.as(Matter::DataType::NodeId).id]
    handler.sessions[session.session_id] = session
    subscription = Matter::Protocol::ActiveSubscription.new(
      subscription_id: 3_u32, min_interval: 0_u16, max_interval: 60_u16,
      peer: Socket::IPAddress.new("127.0.0.1", 5540), session: session,
      attribute_paths: [Matter::InteractionModel::AttributePath.new(
        endpoint: 1_u16, cluster: Matter::Cluster::OnOff::CLUSTER_ID,
        attribute: Matter::Cluster::OnOff::ATTR_ON_OFF)], exchange_id: 1_u16)
    handler.active_subscriptions[subscription.subscription_id] = subscription
    handler.sender.next_exchange_id = 0xBEEF_u16
    handler.notify_subscriptions(1_u16, Matter::Cluster::OnOff::CLUSTER_ID,
      Matter::Cluster::OnOff::ATTR_ON_OFF)

    handler.handle_message(Matter::Spec::ProtocolMessages.status_response(session, 5_u32, 0xBEEF_u16,
      status: Matter::InteractionModel::StatusCode::InvalidSubscription.value), subscription.peer)
    handler.active_subscriptions.should be_empty
    handler.close
  end

  it "sends subscription ReportData on a new exchange (initiator=true)" do
    transport = Matter::Spec::CaptureTransport.new_for_spec
    storage = Matter::Storage::Memory.new
    fabric_table = Matter::FabricTable.new(storage)

    handler = Matter::Protocol::MessageHandler.new(
      transport: transport,
      setup_pin: 20202021_u32,
      discriminator: 3840_u16,
      fabric_table: fabric_table
    )

    endpoint = endpoint(1)
    on_off = Matter::Cluster::OnOff.new(endpoint, on_off: false)
    handler.clusters[{1_u16, Matter::Cluster::OnOff::CLUSTER_ID}] = on_off

    session = Matter::Session::SecureContext.new(
      session_id: 1_u16,
      peer_session_id: 2_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16, 0x11_u8),
      decryption_key: Bytes.new(16, 0x22_u8),
      initiator: false,
      peer_node_id: Matter::DataType::NodeId.new(0x2222_u64),
      local_node_id: Matter::DataType::NodeId.new(0x1111_u64),
      case_session: true,
      fabric_index: 1_u8
    )
    session.peer_subject_ids = [session.peer_node_id.as(Matter::DataType::NodeId).id]

    subscription_exchange_id = 0x1234_u16
    subscription = Matter::Protocol::ActiveSubscription.new(
      subscription_id: 1_u32,
      min_interval: 0_u16,
      max_interval: 60_u16,
      peer: Socket::IPAddress.new("127.0.0.1", 5540),
      session: session,
      attribute_paths: [
        Matter::InteractionModel::AttributePath.new(
          endpoint: 1_u16,
          cluster: Matter::Cluster::OnOff::CLUSTER_ID,
          attribute: Matter::Cluster::OnOff::ATTR_ON_OFF
        ),
      ],
      exchange_id: subscription_exchange_id
    )
    handler.active_subscriptions[subscription.subscription_id] = subscription

    update_exchange_id = 0xBEEF_u16
    handler.sender.next_exchange_id = update_exchange_id

    # Trigger a subscription update send.
    handler.notify_subscriptions(1_u16, Matter::Cluster::OnOff::CLUSTER_ID, Matter::Cluster::OnOff::ATTR_ON_OFF)

    transport.sent_packets.size.should be >= 1
    packet_bytes, _peer = transport.sent_packets.last

    packet = Matter::Codec::MessageCodec::Base.decode_packet(packet_bytes)
    header_len = packet_bytes.size - packet.payload.size
    packet_header_bytes = packet_bytes[0, header_len]

    # Decrypt the encrypted application payload to inspect the PayloadHeader fields.
    crypto = Matter::Crypto::StandardCrypto.new
    message_counter = packet.header.message_id
    security_flags = packet_header_bytes[3]
    nonce = Matter::Session::SecureMessage.build_nonce(session.local_node_id.as(Matter::DataType::NodeId).id, message_counter, security_flags)
    decrypted = crypto.decrypt(session.encryption_key, packet.payload, nonce, packet_header_bytes)

    decrypted_packet = Matter::Codec::MessageCodec::Packet.new(packet.header, decrypted)
    message = Matter::Codec::MessageCodec::Base.decode_payload(decrypted_packet)

    message.payload_header.protocol_id.should eq(0x0001_u16) # Interaction Model
    message.payload_header.message_type.should eq(0x05_u8)   # ReportData
    message.payload_header.exchange_id.should eq(update_exchange_id)
    message.payload_header.initiator_message?.should be_true
  end
end
