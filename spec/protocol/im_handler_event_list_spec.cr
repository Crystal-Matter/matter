require "../spec_helper"
require "../../src/matter/protocol/message_handler"
require "../../src/matter/cluster/on_off"
require "../../src/matter/cluster/operational_state"
require "../../src/matter/cluster/descriptor"

private EVENT_LIST_PEER = Socket::IPAddress.new("127.0.0.1", 5540)

private def wildcard_event_list_report(subscribe : Bool) : Matter::InteractionModel::ReportDataMessage
  transport = Matter::Spec::CaptureTransport.new_for_spec
  handler = Matter::Protocol::MessageHandler.new(
    transport: transport,
    setup_pin: 20202021_u32,
    discriminator: 3840_u16,
    fabric_table: Matter::FabricTable.new(Matter::Storage::Memory.new))
  appliance = Matter::Endpoint.new(endpoint(1))
  appliance.add_cluster(Matter::Cluster::OperationalState.new(endpoint(1)))
  appliance.add_cluster(Matter::Cluster::OnOff.new(endpoint(1)))
  handler.node.add_endpoint(appliance)
  session = Matter::Spec::ProtocolMessages.case_session(1_u16)
  handler.sessions[session.session_id] = session
  Matter::Spec::ProtocolMessages.grant_case_access(handler.node.clusters, session)

  path = Matter::InteractionModel::AttributePath.new(endpoint: 1_u16)
  request = if subscribe
              Matter::InteractionModel::SubscribeRequestMessage.new(
                attribute_requests: [path], min_interval_floor: 0_u16,
                max_interval_ceiling: 60_u16).to_slice
            else
              Matter::InteractionModel::ReadRequestMessage.new(attribute_requests: [path]).to_slice
            end
  type = subscribe ? Matter::InteractionModel::MessageType::SubscribeRequest : Matter::InteractionModel::MessageType::ReadRequest
  handler.handle_message(Matter::Spec::ProtocolMessages.from_peer(
    session: session, message_type: type.value, payload: request,
    message_counter: 3_u32, exchange_id: 21_u16), EVENT_LIST_PEER)

  packet_bytes, _ = transport.sent_packets.first
  packet = Matter::Codec::MessageCodec::Base.decode_packet(packet_bytes)
  header_bytes = packet_bytes[0, packet_bytes.size - packet.payload.size]
  nonce = Matter::Session::SecureMessage.build_nonce(session.local_node_id.as(Matter::DataType::NodeId).id,
    packet.header.message_id, header_bytes[Matter::Codec::MessageCodec::SECURITY_FLAGS_OFFSET])
  plaintext = Matter::Crypto::StandardCrypto.new.decrypt(session.encryption_key,
    packet.payload, nonce, header_bytes)
  payload = Matter::Codec::MessageCodec::Base.decode_payload(
    Matter::Codec::MessageCodec::Packet.new(packet.header, plaintext)).payload
  Matter::InteractionModel::ReportDataMessage.from_slice(payload)
ensure
  handler.try(&.close)
end

private def assert_wildcard_event_lists(report : Matter::InteractionModel::ReportDataMessage) : Nil
  data = report.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
    .compact_map(&.attribute_data)
    .select { |entry| entry.path.attribute == Matter::Cluster::Base::GLOBAL_EVENT_LIST }
  data.size.should eq(3)
  lists = data.to_h do |entry|
    {entry.path.cluster.as(UInt32), entry.data.as_list.map(&.as_u32)}
  end
  lists[Matter::Cluster::OperationalState::CLUSTER_ID].should eq([
    Matter::Cluster::OperationalState::EVENT_OPERATIONAL_ERROR,
    Matter::Cluster::OperationalState::EVENT_OPERATION_COMPLETION,
  ])
  lists[Matter::Cluster::OnOff::CLUSTER_ID].should be_empty
  lists[Matter::Cluster::Descriptor::CLUSTER_ID].should be_empty
end

describe "Interaction Model wildcard EventList" do
  it "keeps a queued EventList report authorized during chunked subscription priming" do
    cluster = Matter::Cluster::OnOff.new(endpoint(1))
    clusters = { {1_u16, Matter::Cluster::OnOff::CLUSTER_ID} => cluster.as(Matter::Cluster::Base) }
    session = Matter::Spec::ProtocolMessages.case_session(1_u16)
    session.peer_subject_ids = [session.peer_node_id.as(Matter::DataType::NodeId).id]
    Matter::Spec::ProtocolMessages.grant_case_access(clusters, session)
    path = Matter::InteractionModel::AttributePath.new(endpoint: 1_u16,
      cluster: Matter::Cluster::OnOff::CLUSTER_ID,
      attribute: Matter::Cluster::Base::GLOBAL_EVENT_LIST)
    reports = Matter::Protocol::IMHandler.read_attributes([path], clusters,
      fabric_index: session.fabric_index, is_case_session: true,
      peer_subject_ids: session.peer_subject_ids)
    reports.first.attribute_data.should_not be_nil
    payload = Matter::Protocol::IMHandler.encode_report_data(reports, 1_u32)

    Matter::Protocol::IMHandler.report_chunk_authorized?(payload, clusters, session).should be_true
  end

  it "includes eventful and eventless clusters in wildcard Read" do
    assert_wildcard_event_lists(wildcard_event_list_report(false))
  end

  it "includes eventful and eventless clusters in initial Subscribe ReportData" do
    report = wildcard_event_list_report(true)
    report.subscription_id.should_not be_nil
    assert_wildcard_event_lists(report)
  end
end
