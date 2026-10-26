require "../spec_helper"
require "../../src/matter/protocol/im_handler"
require "../../src/matter/cluster/on_off"
require "../../src/matter/cluster/descriptor"
require "../../src/matter/protocol/message_handler"

private NODE_FILTER_PEER         = Socket::IPAddress.new("127.0.0.1", 5540)
private NODE_FILTER_LOCAL_NODE   = 0x1234_u64
private NODE_FILTER_FOREIGN_NODE = 0x5678_u64

private def assert_node_filter_priming(subscribe : Bool) : Nil
  own = node_filter_priming_report(subscribe, NODE_FILTER_LOCAL_NODE)
  own.attribute_reports.should be_nil

  foreign = node_filter_priming_report(subscribe, NODE_FILTER_FOREIGN_NODE)
  foreign.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB)).size.should eq(1)
end

private def node_filter_priming_report(subscribe : Bool, filter_node : UInt64) : Matter::InteractionModel::ReportDataMessage
  transport = Matter::Spec::CaptureTransport.new_for_spec
  handler = Matter::Protocol::MessageHandler.new(
    transport: transport,
    setup_pin: 20202021_u32,
    discriminator: 3840_u16,
    fabric_table: Matter::FabricTable.new(Matter::Storage::Memory.new))
  endpoint = Matter::Endpoint.new(endpoint(1))
  on_off = Matter::Cluster::OnOff.new(endpoint(1))
  on_off.data_version = 8_u32
  endpoint.add_cluster(on_off)
  handler.node.add_endpoint(endpoint)
  session = Matter::Spec::ProtocolMessages.case_session(1_u16)
  session.local_node_id = Matter::DataType::NodeId.new(NODE_FILTER_LOCAL_NODE)
  handler.sessions[session.session_id] = session

  path = Matter::InteractionModel::AttributePath.new(endpoint: 1_u16,
    cluster: Matter::Cluster::OnOff::CLUSTER_ID, attribute: Matter::Cluster::OnOff::ATTR_ON_OFF)
  filter = Matter::InteractionModel::DataVersionFilterIB.new(
    Matter::InteractionModel::ClusterPath.new(1_u16, Matter::Cluster::OnOff::CLUSTER_ID,
      node: filter_node), 8_u32)
  request = if subscribe
              Matter::InteractionModel::SubscribeRequestMessage.new(
                attribute_requests: [path], data_version_filters: [filter],
                min_interval_floor: 0_u16, max_interval_ceiling: 60_u16).to_slice
            else
              Matter::InteractionModel::ReadRequestMessage.new(
                attribute_requests: [path], data_version_filters: [filter]).to_slice
            end
  type = subscribe ? Matter::InteractionModel::MessageType::SubscribeRequest : Matter::InteractionModel::MessageType::ReadRequest
  handler.handle_message(Matter::Spec::ProtocolMessages.from_peer(
    session: session, message_type: type.value, payload: request,
    message_counter: 3_u32, exchange_id: 21_u16), NODE_FILTER_PEER)

  packet_bytes, _ = transport.sent_packets.first
  packet = Matter::Codec::MessageCodec::Base.decode_packet(packet_bytes)
  header_bytes = packet_bytes[0, packet_bytes.size - packet.payload.size]
  nonce = Matter::Session::SecureMessage.build_nonce(NODE_FILTER_LOCAL_NODE,
    packet.header.message_id, header_bytes[Matter::Codec::MessageCodec::SECURITY_FLAGS_OFFSET])
  plaintext = Matter::Crypto::StandardCrypto.new.decrypt(session.encryption_key,
    packet.payload, nonce, header_bytes)
  payload = Matter::Codec::MessageCodec::Base.decode_payload(
    Matter::Codec::MessageCodec::Packet.new(packet.header, plaintext)).payload
  Matter::InteractionModel::ReportDataMessage.from_slice(payload)
ensure
  handler.try(&.close)
end

describe "Interaction Model data version filters" do
  it "encodes the cluster path and version in ReadRequest and SubscribeRequest" do
    filter = Matter::InteractionModel::DataVersionFilterIB.new(
      Matter::InteractionModel::ClusterPath.new(1_u16, Matter::Cluster::OnOff::CLUSTER_ID),
      0x12345678_u32)
    read = Matter::InteractionModel::ReadRequestMessage.new(data_version_filters: [filter])
    subscribe = Matter::InteractionModel::SubscribeRequestMessage.new(data_version_filters: [filter])

    Matter::InteractionModel::ReadRequestMessage.from_slice(read.to_slice).data_version_filters.should eq([filter])
    Matter::InteractionModel::SubscribeRequestMessage.from_slice(subscribe.to_slice).data_version_filters.should eq([filter])
  end

  it "omits a matching cluster but still reports another cluster on a wildcard read" do
    on_off = Matter::Cluster::OnOff.new(endpoint(1))
    descriptor = Matter::Cluster::Descriptor.new(endpoint(1))
    on_off.data_version = 7_u32
    descriptor.data_version = 9_u32
    clusters = {
      {1_u16, Matter::Cluster::OnOff::CLUSTER_ID}      => on_off.as(Matter::Cluster::Base),
      {1_u16, Matter::Cluster::Descriptor::CLUSTER_ID} => descriptor.as(Matter::Cluster::Base),
    }
    path = Matter::InteractionModel::AttributePath.new(endpoint: 1_u16)
    filter = Matter::InteractionModel::DataVersionFilterIB.new(
      Matter::InteractionModel::ClusterPath.new(1_u16, Matter::Cluster::OnOff::CLUSTER_ID), 7_u32)

    reports = Matter::Protocol::IMHandler.read_attributes([path], clusters, data_version_filters: [filter])
    reports.should_not be_empty
    reports.all? do |report|
      (report.attribute_data.try(&.path.cluster) || report.attribute_status.try(&.path.cluster)) ==
        Matter::Cluster::Descriptor::CLUSTER_ID
    end.should be_true
  end

  it "returns attributes when the client's version is stale" do
    on_off = Matter::Cluster::OnOff.new(endpoint(1))
    on_off.data_version = 8_u32
    clusters = { {1_u16, Matter::Cluster::OnOff::CLUSTER_ID} => on_off.as(Matter::Cluster::Base) }
    path = Matter::InteractionModel::AttributePath.new(
      endpoint: 1_u16, cluster: Matter::Cluster::OnOff::CLUSTER_ID,
      attribute: Matter::Cluster::OnOff::ATTR_ON_OFF)
    filter = Matter::InteractionModel::DataVersionFilterIB.new(
      Matter::InteractionModel::ClusterPath.new(1_u16, Matter::Cluster::OnOff::CLUSTER_ID), 7_u32)

    reports = Matter::Protocol::IMHandler.read_attributes([path], clusters, data_version_filters: [filter])
    reports.size.should eq(1)
    reports.first.attribute_data.should_not be_nil
  end

  it "suppresses a concrete attribute when its cluster version matches" do
    on_off = Matter::Cluster::OnOff.new(endpoint(1))
    on_off.data_version = 8_u32
    clusters = { {1_u16, Matter::Cluster::OnOff::CLUSTER_ID} => on_off.as(Matter::Cluster::Base) }
    path = Matter::InteractionModel::AttributePath.new(
      endpoint: 1_u16, cluster: Matter::Cluster::OnOff::CLUSTER_ID,
      attribute: Matter::Cluster::OnOff::ATTR_ON_OFF)
    filter = Matter::InteractionModel::DataVersionFilterIB.new(
      Matter::InteractionModel::ClusterPath.new(1_u16, Matter::Cluster::OnOff::CLUSTER_ID), 8_u32)

    Matter::Protocol::IMHandler.read_attributes([path], clusters,
      data_version_filters: [filter]).should be_empty
  end

  it "applies only this node's data version filter to ReadRequest" do
    assert_node_filter_priming(false)
  end

  it "applies only this node's data version filter to SubscribeRequest priming" do
    assert_node_filter_priming(true)
  end

  it "applies a matching node-scoped filter during wildcard expansion" do
    on_off = Matter::Cluster::OnOff.new(endpoint(1))
    descriptor = Matter::Cluster::Descriptor.new(endpoint(1))
    on_off.data_version = 7_u32
    descriptor.data_version = 9_u32
    clusters = {
      {1_u16, Matter::Cluster::OnOff::CLUSTER_ID}      => on_off.as(Matter::Cluster::Base),
      {1_u16, Matter::Cluster::Descriptor::CLUSTER_ID} => descriptor.as(Matter::Cluster::Base),
    }
    path = Matter::InteractionModel::AttributePath.new(endpoint: 1_u16)
    filter = Matter::InteractionModel::DataVersionFilterIB.new(
      Matter::InteractionModel::ClusterPath.new(1_u16, Matter::Cluster::OnOff::CLUSTER_ID,
        node: NODE_FILTER_LOCAL_NODE), 7_u32)

    reports = Matter::Protocol::IMHandler.read_attributes([path], clusters,
      data_version_filters: [filter], local_node_id: NODE_FILTER_LOCAL_NODE)
    reports.should_not be_empty
    reports.all? do |report|
      (report.attribute_data.try(&.path.cluster) || report.attribute_status.try(&.path.cluster)) ==
        Matter::Cluster::Descriptor::CLUSTER_ID
    end.should be_true
  end
end
