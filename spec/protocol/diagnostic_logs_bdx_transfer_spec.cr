require "../spec_helper"
require "../../src/matter/protocol/message_handler"

private alias DiagnosticBdx = Matter::Protocol::Bdx
private DIAGNOSTIC_PEER = Socket::IPAddress.new("127.0.0.1", 5540)

private def diagnostic_bdx_fixture
  transport = Matter::Spec::CaptureTransport.new_for_spec
  handler = Matter::Protocol::MessageHandler.new(transport,
    setup_pin: 20202021_u32, discriminator: 3840_u16,
    fabric_table: Matter::FabricTable.new(Matter::Storage::Memory.new))
  session = Matter::Spec::ProtocolMessages.case_session(181_u16)
  handler.sessions[session.session_id] = session
  {handler, transport, session}
end

private def diagnostic_bdx_outgoing(wire : Bytes, session : Matter::Session::SecureContext)
  packet = Matter::Codec::MessageCodec::Base.decode_packet(wire)
  header = wire[0, wire.size - packet.payload.size]
  node = session.local_node_id.as(Matter::DataType::NodeId).id
  nonce = Matter::Session::SecureMessage.build_nonce(node,
    packet.header.message_id, header[Matter::Codec::MessageCodec::SECURITY_FLAGS_OFFSET])
  plaintext = Matter::Crypto::StandardCrypto.new.decrypt(session.encryption_key,
    packet.payload, nonce, header)
  Matter::Codec::MessageCodec::Base.decode_payload(
    Matter::Codec::MessageCodec::Packet.new(packet.header, plaintext))
end

private def diagnostic_bdx_incoming(session : Matter::Session::SecureContext,
                                    counter : UInt32, exchange : UInt16,
                                    opcode : DiagnosticBdx::Wire::Opcode,
                                    payload : Bytes)
  Matter::Spec::ProtocolMessages.from_peer(session, opcode.value, payload,
    counter, exchange, protocol_id: Matter::Protocol::ProtocolId::Bdx.value,
    initiator_message: false)
end

describe "DiagnosticLogs outbound BDX transfer" do
  it "sends InvokeResponse before SendInit for a real encrypted RetrieveLogsRequest" do
    handler, transport, session = diagnostic_bdx_fixture
    session.peer_subject_ids = [0x2222_u64]
    cluster = Matter::Cluster::DiagnosticLogs.new(Matter::DataType::EndpointNumber.new(0_u16))
    cluster.log("B" * 900)
    cluster.on_bdx_transfer = ->(session_id : UInt16, fabric : UInt8, node : UInt64, peer : Socket::IPAddress, designator : Bytes, content : Bytes) do
      handler.queue_bdx_transfer(session_id, fabric, node, peer, designator, content)
    end
    handler.clusters[{0_u16, Matter::Cluster::DiagnosticLogs::CLUSTER_ID}] = cluster

    command = Matter::Cluster::DiagnosticLogs::RetrieveLogsRequest.new(
      Matter::Cluster::DiagnosticLogs::Intent::EndUserSupport,
      Matter::Cluster::DiagnosticLogs::TransferProtocol::BDX,
      "support-log")
    path = Matter::InteractionModel::CommandPath.new(0_u16,
      Matter::Cluster::DiagnosticLogs::CLUSTER_ID, 0_u32)
    request = Matter::InteractionModel::InvokeRequestMessage.new([
      Matter::InteractionModel::CommandDataIBTlv.new(path, command.to_tlv(nil)),
    ])
    inbound = Matter::Spec::ProtocolMessages.from_peer(session,
      Matter::InteractionModel::MessageType::InvokeRequest.value,
      request.to_slice, 1_u32, 17_u16)
    handler.handle_message(inbound, DIAGNOSTIC_PEER)

    sent = transport.sent_packets.map(&.[0]).map { |wire| diagnostic_bdx_outgoing(wire, session) }
    sent.size.should eq(2)
    sent[0].payload_header.protocol_id.should eq(Matter::Protocol::ProtocolId::InteractionModel.value)
    sent[0].payload_header.message_type.should eq(Matter::InteractionModel::MessageType::InvokeResponse.value)
    response = Matter::InteractionModel::InvokeResponseMessage.from_slice(sent[0].payload)
    response.invoke_responses.first.command_status.should be_nil
    data = response.invoke_responses.first.command_data.as(Matter::InteractionModel::CommandDataIBTlv)
    payload = Matter::Cluster::DiagnosticLogs::RetrieveLogsResponse.from_tlv(data.command_fields.as(TLV::Any))
    payload.status.should eq(Matter::Cluster::DiagnosticLogs::LogsStatus::Success)
    payload.log_content.should be_empty
    sent[1].payload_header.protocol_id.should eq(Matter::Protocol::ProtocolId::Bdx.value)
    sent[1].payload_header.message_type.should eq(DiagnosticBdx::Wire::Opcode::SendInit.value)
    handler.close
  end

  it "sends a named multi-block log on the authenticated CASE exchange" do
    handler, transport, session = diagnostic_bdx_fixture
    contents = Bytes.new(1500) { |index| (index % 251).to_u8 }
    handler.queue_bdx_transfer(session.session_id, 1_u8, 0x2222_u64,
      DIAGNOSTIC_PEER, "support-log".to_slice, contents).should be_true
    handler.bdx_initiator.start_pending

    init_message = diagnostic_bdx_outgoing(transport.sent_packets.last[0], session)
    init_message.payload_header.protocol_id.should eq(Matter::Protocol::ProtocolId::Bdx.value)
    init_message.payload_header.message_type.should eq(DiagnosticBdx::Wire::Opcode::SendInit.value)
    init_message.payload_header.initiator_message?.should be_true
    exchange = init_message.payload_header.exchange_id
    init = DiagnosticBdx::Wire::Init.decode(DiagnosticBdx::Wire::Opcode::SendInit, init_message.payload)
    String.new(init.file_designator).should eq("support-log")
    init.length.should eq(contents.size.to_u64)

    accept = DiagnosticBdx::Wire::Accept.new(DiagnosticBdx::Wire::Opcode::SendAccept,
      DiagnosticBdx::Wire::TransferControl::SenderDrive, 1024_u16)
    handler.handle_message(diagnostic_bdx_incoming(session, 1_u32, exchange,
      accept.opcode, accept.to_slice), DIAGNOSTIC_PEER)
    block = transport.sent_packets.map(&.[0]).map { |wire| diagnostic_bdx_outgoing(wire, session) }
      .find! do |msg|
        msg.payload_header.protocol_id == Matter::Protocol::ProtocolId::Bdx.value &&
          msg.payload_header.message_type == DiagnosticBdx::Wire::Opcode::Block.value
      end
    first = DiagnosticBdx::Wire::BlockData.decode(DiagnosticBdx::Wire::Opcode::Block,
      block.payload, 1024)
    first.data.should eq(contents[0, 1024])

    ack = DiagnosticBdx::Wire::BlockCounterMessage.new(DiagnosticBdx::Wire::Opcode::BlockAck, 0_u32)
    handler.handle_message(diagnostic_bdx_incoming(session, 2_u32, exchange,
      ack.opcode, ack.to_slice), DIAGNOSTIC_PEER)
    eof = transport.sent_packets.map(&.[0]).map { |wire| diagnostic_bdx_outgoing(wire, session) }
      .find! do |msg|
        msg.payload_header.protocol_id == Matter::Protocol::ProtocolId::Bdx.value &&
          msg.payload_header.message_type == DiagnosticBdx::Wire::Opcode::BlockEOF.value
      end
    final_block = DiagnosticBdx::Wire::BlockData.decode(DiagnosticBdx::Wire::Opcode::BlockEOF,
      eof.payload, 1024)
    (first.data + final_block.data).should eq(contents)

    final_ack = DiagnosticBdx::Wire::BlockCounterMessage.new(DiagnosticBdx::Wire::Opcode::BlockAckEOF, 1_u32)
    handler.handle_message(diagnostic_bdx_incoming(session, 3_u32, exchange,
      final_ack.opcode, final_ack.to_slice), DIAGNOSTIC_PEER)
    handler.bdx_initiator.handles?(session.session_id, exchange).should be_false
    handler.close
  end

  it "rejects a queue request for another fabric or peer and cleans up on session removal" do
    handler, _transport, session = diagnostic_bdx_fixture
    handler.queue_bdx_transfer(session.session_id, 2_u8, 0x2222_u64,
      DIAGNOSTIC_PEER, "log".to_slice, Bytes[1]).should be_false
    handler.queue_bdx_transfer(session.session_id, 1_u8, 0x9999_u64,
      DIAGNOSTIC_PEER, "log".to_slice, Bytes[1]).should be_false
    handler.queue_bdx_transfer(session.session_id, 1_u8, 0x2222_u64,
      DIAGNOSTIC_PEER, "log".to_slice, Bytes[1]).should be_true
    handler.delete_session(session.session_id).should be_true
    handler.bdx_initiator.start_pending
    handler.close
  end

  it "aborts malformed transfer negotiation with a BDX StatusReport" do
    handler, transport, session = diagnostic_bdx_fixture
    handler.queue_bdx_transfer(session.session_id, 1_u8, 0x2222_u64,
      DIAGNOSTIC_PEER, "log".to_slice, Bytes[1]).should be_true
    handler.bdx_initiator.start_pending
    init = diagnostic_bdx_outgoing(transport.sent_packets.last[0], session)
    exchange = init.payload_header.exchange_id

    handler.handle_message(diagnostic_bdx_incoming(session, 1_u32, exchange,
      DiagnosticBdx::Wire::Opcode::SendAccept, Bytes[0xff]), DIAGNOSTIC_PEER)
    response = diagnostic_bdx_outgoing(transport.sent_packets.last[0], session)
    response.payload_header.protocol_id.should eq(Matter::Protocol::ProtocolId::SecureChannel.value)
    report = Matter::Session::Pase::Definitions::StatusReport.from_bytes(response.payload)
    report.protocol_id.should eq(Matter::Protocol::ProtocolId::Bdx.value)
    report.protocol_status.should eq(DiagnosticBdx::Transfer::StatusCode::BadMessageContents.value)
    handler.bdx_initiator.handles?(session.session_id, exchange).should be_false
    handler.close
  end
end
