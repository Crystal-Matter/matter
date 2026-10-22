require "../spec_helper"
require "../../src/matter/protocol/message_handler"

private TIMED_PEER = Socket::IPAddress.new("127.0.0.1", 5540)

private class TimedWritable < Matter::Cluster::Base
  cluster 0xFFF1_FC20, revision: 1
  attribute 0x0000, :value, UInt8, default: 0_u8, writable: true, timed: true
  command 0x00, :arm, timed: true

  def arm : Matter::InteractionModel::Status
    self.value = 1_u8
    Matter::InteractionModel::Status.success
  end
end

private def timed_fixture
  transport = Matter::Spec::CaptureTransport.new_for_spec
  handler = Matter::Protocol::MessageHandler.new(transport,
    setup_pin: 20202021_u32, discriminator: 3840_u16,
    fabric_table: Matter::FabricTable.new(Matter::Storage::Memory.new))
  session = Matter::Spec::ProtocolMessages.case_session(201_u16)
  handler.sessions[session.session_id] = session
  {handler, transport, session}
end

private def timed_response_payload(wire : Bytes, session : Matter::Session::SecureContext) : Bytes
  packet = Matter::Codec::MessageCodec::Base.decode_packet(wire)
  header = wire[0, wire.size - packet.payload.size]
  nonce = Matter::Session::SecureMessage.build_nonce(
    session.local_node_id.as(Matter::DataType::NodeId).id,
    packet.header.message_id, header[Matter::Codec::MessageCodec::SECURITY_FLAGS_OFFSET])
  plaintext = Matter::Crypto::StandardCrypto.new.decrypt(session.encryption_key,
    packet.payload, nonce, header)
  Matter::Codec::MessageCodec::Base.decode_payload(
    Matter::Codec::MessageCodec::Packet.new(packet.header, plaintext)).payload
end

describe "timed Interaction Model requirements over encrypted CASE" do
  it "rejects untimed AdministratorCommissioning OpenCommissioningWindow and RevokeCommissioning" do
    handler, transport, session = timed_fixture
    cluster = Matter::Cluster::AdministratorCommissioning.new(Matter::DataType::EndpointNumber.new(0_u16))
    handler.clusters[{0_u16, Matter::Cluster::AdministratorCommissioning::CLUSTER_ID}] = cluster

    [Matter::Cluster::AdministratorCommissioning::CMD_OPEN_COMMISSIONING_WINDOW,
     Matter::Cluster::AdministratorCommissioning::CMD_REVOKE_COMMISSIONING].each_with_index do |command_id, index|
      path = Matter::InteractionModel::CommandPath.new(0_u16,
        Matter::Cluster::AdministratorCommissioning::CLUSTER_ID, command_id)
      request = Matter::InteractionModel::InvokeRequestMessage.new([
        Matter::InteractionModel::CommandDataIBTlv.new(path, nil),
      ])
      handler.handle_message(Matter::Spec::ProtocolMessages.from_peer(session,
        Matter::InteractionModel::MessageType::InvokeRequest.value,
        request.to_slice, (index + 1).to_u32, (70 + index).to_u16), TIMED_PEER)

      response = Matter::InteractionModel::InvokeResponseMessage.from_slice(
        timed_response_payload(transport.sent_packets.last[0], session))
      response.invoke_responses.first.command_status.as(Matter::InteractionModel::CommandStatusIB)
        .status.status.should eq(0xC6_u8)
    end
    handler.close
  end

  it "allows a matching TimedRequest to reach the command handler" do
    handler, transport, session = timed_fixture
    cluster = TimedWritable.new(Matter::DataType::EndpointNumber.new(1_u16))
    handler.clusters[{1_u16, TimedWritable::CLUSTER_ID}] = cluster
    exchange = 80_u16
    timed = Matter::InteractionModel::TimedRequestMessage.new(1_000_u16)
    handler.handle_message(Matter::Spec::ProtocolMessages.from_peer(session,
      Matter::InteractionModel::MessageType::TimedRequest.value,
      timed.to_slice, 1_u32, exchange), TIMED_PEER)

    path = Matter::InteractionModel::CommandPath.new(1_u16,
      TimedWritable::CLUSTER_ID, TimedWritable::CMD_ARM)
    request = Matter::InteractionModel::InvokeRequestMessage.new([
      Matter::InteractionModel::CommandDataIBTlv.new(path, nil),
    ], timed_request: true)
    handler.handle_message(Matter::Spec::ProtocolMessages.from_peer(session,
      Matter::InteractionModel::MessageType::InvokeRequest.value,
      request.to_slice, 2_u32, exchange), TIMED_PEER)

    response = Matter::InteractionModel::InvokeResponseMessage.from_slice(
      timed_response_payload(transport.sent_packets.last[0], session))
    response.invoke_responses.first.command_status.as(Matter::InteractionModel::CommandStatusIB)
      .status.status.should eq(Matter::InteractionModel::StatusCode::Success.value)
    cluster.value.should eq(1_u8)
    handler.close
  end

  it "rejects an untimed write to a timed writable attribute before mutation" do
    handler, transport, session = timed_fixture
    cluster = TimedWritable.new(Matter::DataType::EndpointNumber.new(1_u16))
    handler.clusters[{1_u16, TimedWritable::CLUSTER_ID}] = cluster
    path = Matter::InteractionModel::AttributePath.new(endpoint: 1_u16,
      cluster: TimedWritable::CLUSTER_ID, attribute: TimedWritable::ATTR_VALUE)
    data = Matter::InteractionModel::AttributeDataIB.new(path, TLV::Any.new(7_u8))
    request = Matter::InteractionModel::WriteRequestMessage.new(write_requests: [data])
    handler.handle_message(Matter::Spec::ProtocolMessages.from_peer(session,
      Matter::InteractionModel::MessageType::WriteRequest.value,
      request.to_slice, 1_u32, 90_u16), TIMED_PEER)

    response = Matter::InteractionModel::WriteResponseMessage.from_slice(
      timed_response_payload(transport.sent_packets.last[0], session))
    response.write_responses.first.status.status.should eq(0xC6_u8)
    cluster.value.should eq(0_u8)
    handler.close
  end

  it "allows a timed write only after a TimedRequest on the same exchange" do
    handler, transport, session = timed_fixture
    cluster = TimedWritable.new(Matter::DataType::EndpointNumber.new(1_u16))
    handler.clusters[{1_u16, TimedWritable::CLUSTER_ID}] = cluster
    path = Matter::InteractionModel::AttributePath.new(endpoint: 1_u16,
      cluster: TimedWritable::CLUSTER_ID, attribute: TimedWritable::ATTR_VALUE)
    data = Matter::InteractionModel::AttributeDataIB.new(path, TLV::Any.new(7_u8))
    write = Matter::InteractionModel::WriteRequestMessage.new(timed_request: true, write_requests: [data])

    # A TimedRequest on a different exchange cannot authorize this write.
    handler.handle_message(Matter::Spec::ProtocolMessages.from_peer(session,
      Matter::InteractionModel::MessageType::WriteRequest.value,
      write.to_slice, 1_u32, 91_u16), TIMED_PEER)
    mismatch = Matter::InteractionModel::StatusResponseMessage.from_slice(
      timed_response_payload(transport.sent_packets.last[0], session))
    mismatch.status.should eq(0xC9_u8)
    cluster.value.should eq(0_u8)

    timed = Matter::InteractionModel::TimedRequestMessage.new(1_000_u16)
    handler.handle_message(Matter::Spec::ProtocolMessages.from_peer(session,
      Matter::InteractionModel::MessageType::TimedRequest.value,
      timed.to_slice, 2_u32, 92_u16), TIMED_PEER)
    handler.handle_message(Matter::Spec::ProtocolMessages.from_peer(session,
      Matter::InteractionModel::MessageType::WriteRequest.value,
      write.to_slice, 3_u32, 92_u16), TIMED_PEER)

    response = Matter::InteractionModel::WriteResponseMessage.from_slice(
      timed_response_payload(transport.sent_packets.last[0], session))
    response.write_responses.first.status.status.should eq(Matter::InteractionModel::StatusCode::Success.value)
    cluster.value.should eq(7_u8)
    handler.close
  end

  it "permits a timed attribute when the router supplies validated timed state" do
    cluster = TimedWritable.new(Matter::DataType::EndpointNumber.new(1_u16))
    clusters = {} of Tuple(UInt16, UInt32) => Matter::Cluster::Base
    clusters[{1_u16, TimedWritable::CLUSTER_ID}] = cluster
    path = Matter::InteractionModel::AttributePath.new(endpoint: 1_u16,
      cluster: TimedWritable::CLUSTER_ID, attribute: TimedWritable::ATTR_VALUE)
    data = Matter::InteractionModel::AttributeDataIB.new(path, TLV::Any.new(7_u8))

    statuses = Matter::Protocol::IMHandler.write_attributes([data], clusters,
      timed_interaction: true)
    statuses.first.status.status.should eq(Matter::InteractionModel::StatusCode::Success.value)
    cluster.value.should eq(7_u8)
  end

  it "rejects an untimed request sent inside an armed timed exchange" do
    handler, transport, session = timed_fixture
    cluster = TimedWritable.new(Matter::DataType::EndpointNumber.new(1_u16))
    handler.clusters[{1_u16, TimedWritable::CLUSTER_ID}] = cluster
    timed = Matter::InteractionModel::TimedRequestMessage.new(1_000_u16)
    handler.handle_message(Matter::Spec::ProtocolMessages.from_peer(session,
      Matter::InteractionModel::MessageType::TimedRequest.value,
      timed.to_slice, 1_u32, 93_u16), TIMED_PEER)

    path = Matter::InteractionModel::AttributePath.new(endpoint: 1_u16,
      cluster: TimedWritable::CLUSTER_ID, attribute: TimedWritable::ATTR_VALUE)
    data = Matter::InteractionModel::AttributeDataIB.new(path, TLV::Any.new(7_u8))
    write = Matter::InteractionModel::WriteRequestMessage.new(write_requests: [data])
    handler.handle_message(Matter::Spec::ProtocolMessages.from_peer(session,
      Matter::InteractionModel::MessageType::WriteRequest.value,
      write.to_slice, 2_u32, 93_u16), TIMED_PEER)

    mismatch = Matter::InteractionModel::StatusResponseMessage.from_slice(
      timed_response_payload(transport.sent_packets.last[0], session))
    mismatch.status.should eq(0xC9_u8)
    cluster.value.should eq(0_u8)
    handler.close
  end

  it "returns Timeout when a prelude expires even if the following request omits its timed flag" do
    handler, transport, session = timed_fixture
    cluster = TimedWritable.new(Matter::DataType::EndpointNumber.new(1_u16))
    handler.clusters[{1_u16, TimedWritable::CLUSTER_ID}] = cluster
    timed = Matter::InteractionModel::TimedRequestMessage.new(1_u16)
    handler.handle_message(Matter::Spec::ProtocolMessages.from_peer(session,
      Matter::InteractionModel::MessageType::TimedRequest.value,
      timed.to_slice, 1_u32, 94_u16), TIMED_PEER)
    sleep 2.milliseconds

    path = Matter::InteractionModel::AttributePath.new(endpoint: 1_u16,
      cluster: TimedWritable::CLUSTER_ID, attribute: TimedWritable::ATTR_VALUE)
    data = Matter::InteractionModel::AttributeDataIB.new(path, TLV::Any.new(7_u8))
    write = Matter::InteractionModel::WriteRequestMessage.new(write_requests: [data])
    handler.handle_message(Matter::Spec::ProtocolMessages.from_peer(session,
      Matter::InteractionModel::MessageType::WriteRequest.value,
      write.to_slice, 2_u32, 94_u16), TIMED_PEER)

    timeout = Matter::InteractionModel::StatusResponseMessage.from_slice(
      timed_response_payload(transport.sent_packets.last[0], session))
    timeout.status.should eq(Matter::InteractionModel::StatusCode::Timeout.value)
    cluster.value.should eq(0_u8)
    handler.close
  end
end
