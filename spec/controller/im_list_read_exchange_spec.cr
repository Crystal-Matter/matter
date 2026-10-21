require "../spec_helper"
require "../../src/matter/controller/im_client"
require "../../src/matter/cluster/user_label"
require "../../src/matter/protocol/message_handler"

# Sends controller IM requests through the real device MessageHandler, then
# decrypts each response before the controller folds list item reports.
private class ListReadExchangeClient < Matter::Controller::Client
  getter report_chunks = [] of Matter::InteractionModel::ReportDataMessage
  getter status_count = 0

  @message_counter = 1_u32

  def initialize(@handler : Matter::Protocol::MessageHandler,
                 @capture : Matter::Spec::CaptureTransport,
                 @device_session : Matter::Session::SecureContext)
    super()
  end

  def send_encrypted_request(session : Matter::Session::SecureContext,
                             peer : Socket::IPAddress, protocol_id : UInt16,
                             message_type : UInt8, payload : Bytes | Slice(UInt8),
                             exchange_id : UInt16 = next_exchange_id,
                             initiator_message : Bool = true,
                             requires_ack : Bool = true,
                             acknowledged_message_id : UInt32? = nil) : UInt16
    @status_count += 1 if message_type == Matter::Controller::ImClient::MSG_STATUS_RESPONSE
    @handler.handle_message(Matter::Spec::ProtocolMessages.from_peer(
      @device_session, message_type, payload.to_slice, @message_counter, exchange_id,
      protocol_id: protocol_id, requires_acknowledge: requires_ack), peer)
    @message_counter &+= 1_u32
    exchange_id
  end

  def wait_for_any(exchange_id : UInt16, protocol_id : UInt16,
                   message_types : Array(UInt8), timeout : Time::Span) : ReceivedMessage?
    while sent = @capture.sent_packets.shift?
      packet = Matter::Codec::MessageCodec::Base.decode_packet(sent[0])
      header_bytes = sent[0][0, sent[0].size - packet.payload.size]
      nonce = Matter::Session::SecureMessage.build_nonce(
        @device_session.local_node_id.as(Matter::DataType::NodeId).id,
        packet.header.message_id,
        header_bytes[Matter::Codec::MessageCodec::SECURITY_FLAGS_OFFSET])
      plaintext = Matter::Crypto::StandardCrypto.new.decrypt(
        @device_session.encryption_key, packet.payload, nonce, header_bytes)
      message = Matter::Codec::MessageCodec::Base.decode_payload(
        Matter::Codec::MessageCodec::Packet.new(packet.header, plaintext))
      next unless message.payload_header.exchange_id == exchange_id
      next unless message.payload_header.protocol_id == protocol_id
      next unless message_types.includes?(message.payload_header.message_type)
      if message.payload_header.message_type == Matter::Controller::ImClient::MSG_REPORT_DATA
        @report_chunks << Matter::InteractionModel::ReportDataMessage.from_slice(message.payload)
      end
      return ReceivedMessage.new(message, sent[1])
    end
    nil
  end
end

describe "controller and device multi-chunk list read" do
  it "reassembles an initial array prefix and null-index appends over a secure exchange" do
    require_udp_sockets!
    capture = Matter::Spec::CaptureTransport.new_for_spec
    handler = Matter::Protocol::MessageHandler.new(capture, 20202021_u32, 3840_u16,
      Matter::FabricTable.new(Matter::Storage::Memory.new))
    labels = Array.new(100) do |index|
      Matter::Cluster::LabelStruct.new("room#{index}", "value#{index}")
    end
    endpoint = Matter::Endpoint.new(endpoint(1))
    cluster = Matter::Cluster::UserLabel.new(Matter::DataType::EndpointNumber.new(1_u16), labels)
    endpoint.add_cluster(cluster)
    handler.node.add_endpoint(endpoint)
    session = Matter::Spec::ProtocolMessages.case_session(1_u16)
    session.peer_session_id = session.session_id
    handler.sessions[session.session_id] = session
    peer = Socket::IPAddress.new("127.0.0.1", 5540)
    client = ListReadExchangeClient.new(handler, capture, session)

    report = Matter::Controller::ImClient.new(client).read_attribute(session, peer, 1_u16,
      Matter::Cluster::UserLabel::CLUSTER_ID, Matter::Cluster::UserLabel::ATTR_LABEL_LIST)

    client.report_chunks.size.should be > 1
    client.status_count.should eq(client.report_chunks.size)
    wire_data = client.report_chunks.flat_map do |chunk|
      chunk.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
        .compact_map(&.attribute_data)
    end
    wire_data.first.path.list_index_null?.should be_false
    wire_data.first.data.as_list.size.should be > 0
    wire_data[1..].all?(&.path.list_index_null?).should be_true
    final_data = report.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB)
    final_data.data_version.should eq(cluster.data_version)
    Array(Matter::Cluster::LabelStruct).from_tlv(final_data.data.to_slice).should eq(labels)
  ensure
    client.try(&.close)
    handler.try(&.close)
  end
end
