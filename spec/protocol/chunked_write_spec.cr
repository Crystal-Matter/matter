require "../spec_helper"
require "../../src/matter/protocol/message_handler"

private WRITE_PEER     = Socket::IPAddress.new("127.0.0.1", 5540)
private WRITE_EXCHANGE = 53_u16

private def chunked_write_fixture
  transport = Matter::Spec::CaptureTransport.new_for_spec
  handler = Matter::Protocol::MessageHandler.new(
    transport: transport,
    setup_pin: 20202021_u32,
    discriminator: 3840_u16,
    fabric_table: Matter::FabricTable.new(Matter::Storage::Memory.new)
  )
  endpoint = Matter::Endpoint.new(Matter::DataType::EndpointNumber.new(1_u16))
  labels = Matter::Cluster::UserLabel.new(Matter::DataType::EndpointNumber.new(1_u16))
  endpoint.add_cluster(labels)
  handler.node.add_endpoint(endpoint)
  session = Matter::Spec::ProtocolMessages.case_session(1_u16)
  handler.sessions[session.session_id] = session
  {handler, transport, session, labels}
end

private def chunked_write_payload(packet : Bytes, session : Matter::Session::SecureContext) : Bytes
  decoded = Matter::Codec::MessageCodec::Base.decode_packet(packet)
  header_bytes = packet[0, packet.size - decoded.payload.size]
  nonce = Matter::Session::SecureMessage.build_nonce(
    session.local_node_id.as(Matter::DataType::NodeId).id,
    decoded.header.message_id,
    header_bytes[Matter::Codec::MessageCodec::SECURITY_FLAGS_OFFSET]
  )
  plaintext = Matter::Crypto::StandardCrypto.new.decrypt(session.encryption_key, decoded.payload, nonce, header_bytes)
  Matter::Codec::MessageCodec::Base.decode_payload(
    Matter::Codec::MessageCodec::Packet.new(decoded.header, plaintext)).payload
end

private def chunked_write_response(packet : Bytes, session : Matter::Session::SecureContext) : Matter::InteractionModel::WriteResponseMessage
  Matter::InteractionModel::WriteResponseMessage.from_slice(chunked_write_payload(packet, session))
end

describe "chunked WriteRequest" do
  it "keeps a list replacement open for an append in the next chunk of the same exchange" do
    handler, transport, session, labels = chunked_write_fixture

    base_path = Matter::InteractionModel::AttributePath.new(
      endpoint: 1_u16, cluster: Matter::Cluster::UserLabel::CLUSTER_ID,
      attribute: Matter::Cluster::UserLabel::ATTR_LABEL_LIST)
    append_path = Matter::InteractionModel::AttributePath.new(
      endpoint: 1_u16, cluster: Matter::Cluster::UserLabel::CLUSTER_ID,
      attribute: Matter::Cluster::UserLabel::ATTR_LABEL_LIST, list_index_null: true)
    clear = Matter::InteractionModel::AttributeDataIB.new(base_path,
      TLV::Any.from_tlv(([] of Matter::Cluster::LabelStruct).to_tlv))
    append = Matter::InteractionModel::AttributeDataIB.new(append_path,
      Matter::Cluster::LabelStruct.new("room", "office").to_tlv)
    first = Matter::InteractionModel::WriteRequestMessage.new(write_requests: [clear], more_chunked_messages: true)
    second = Matter::InteractionModel::WriteRequestMessage.new(write_requests: [append], more_chunked_messages: false)

    [
      {first, WRITE_EXCHANGE},
      {second, WRITE_EXCHANGE + 1_u16},
      {second, WRITE_EXCHANGE},
      {second, WRITE_EXCHANGE},
    ].each_with_index do |(request, exchange), index|
      handler.handle_message(Matter::Spec::ProtocolMessages.from_peer(
        session: session,
        message_type: Matter::InteractionModel::MessageType::WriteRequest.value,
        payload: request.to_slice,
        message_counter: (10 + index).to_u32,
        exchange_id: exchange
      ), WRITE_PEER)
    end

    statuses = transport.sent_packets.map { |packet, _| chunked_write_response(packet, session).write_responses.first.status.status }
    statuses.should eq([
      Matter::InteractionModel::StatusCode::Success.value,
      Matter::InteractionModel::StatusCode::Busy.value,
      Matter::InteractionModel::StatusCode::Success.value,
      Matter::InteractionModel::StatusCode::Busy.value,
    ])
    labels.label_list.should eq([Matter::Cluster::LabelStruct.new("room", "office")])
    handler.close
  end

  it "rejects a timed request that declares more write chunks" do
    handler, transport, session, labels = chunked_write_fixture
    timed = Matter::InteractionModel::TimedRequestMessage.new(1_000_u16)
    handler.handle_message(Matter::Spec::ProtocolMessages.from_peer(
      session: session,
      message_type: Matter::InteractionModel::MessageType::TimedRequest.value,
      payload: timed.to_slice,
      message_counter: 30_u32,
      exchange_id: WRITE_EXCHANGE
    ), WRITE_PEER)

    item = Matter::Cluster::LabelStruct.new("room", "office")
    path = Matter::InteractionModel::AttributePath.new(
      endpoint: 1_u16, cluster: Matter::Cluster::UserLabel::CLUSTER_ID,
      attribute: Matter::Cluster::UserLabel::ATTR_LABEL_LIST)
    data = Matter::InteractionModel::AttributeDataIB.new(path, TLV::Any.from_tlv([item].to_tlv))
    write = Matter::InteractionModel::WriteRequestMessage.new(
      timed_request: true, write_requests: [data], more_chunked_messages: true)
    handler.handle_message(Matter::Spec::ProtocolMessages.from_peer(
      session: session,
      message_type: Matter::InteractionModel::MessageType::WriteRequest.value,
      payload: write.to_slice,
      message_counter: 31_u32,
      exchange_id: WRITE_EXCHANGE
    ), WRITE_PEER)

    labels.label_list.should be_empty
    payload = chunked_write_payload(transport.sent_packets.last[0], session)
    Matter::InteractionModel::StatusResponseMessage.from_slice(payload).status.should eq(
      Matter::InteractionModel::StatusCode::InvalidAction.value)
    handler.close
  end
end
