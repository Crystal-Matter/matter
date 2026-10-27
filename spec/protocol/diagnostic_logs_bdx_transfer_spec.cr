require "../spec_helper"
require "../../src/matter/protocol/message_handler"

private alias DiagnosticBdx = Matter::Protocol::Bdx
private DIAGNOSTIC_PEER = Socket::IPAddress.new("127.0.0.1", 5540)

private class FailingBdxTransport < Matter::Spec::CaptureTransport
  property? fail_next_send : Bool = false

  protected def transmit(data : Bytes | Slice(UInt8), peer_address : Socket::IPAddress) : Nil
    if @fail_next_send
      @fail_next_send = false
      raise IO::Error.new("synthetic BDX send failure")
    end
    super
  end
end

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
  it "returns the full 1024-byte LogContent limit in one encrypted InvokeResponse" do
    handler, transport, session = diagnostic_bdx_fixture
    session.peer_subject_ids = [0x2222_u64]
    cluster = Matter::Cluster::DiagnosticLogs.new(Matter::DataType::EndpointNumber.new(0_u16))
    cluster.log("L" * 1100)
    handler.clusters[{0_u16, Matter::Cluster::DiagnosticLogs::CLUSTER_ID}] = cluster

    command = Matter::Cluster::DiagnosticLogs::RetrieveLogsRequest.new(
      Matter::Cluster::DiagnosticLogs::Intent::EndUserSupport,
      Matter::Cluster::DiagnosticLogs::TransferProtocol::ResponsePayload)
    path = Matter::InteractionModel::CommandPath.new(0_u16,
      Matter::Cluster::DiagnosticLogs::CLUSTER_ID,
      Matter::Cluster::DiagnosticLogs::CMD_RETRIEVE_LOGS_REQUEST)
    request = Matter::InteractionModel::InvokeRequestMessage.new([
      Matter::InteractionModel::CommandDataIBTlv.new(path, command.to_tlv(nil)),
    ])
    inbound = Matter::Spec::ProtocolMessages.from_peer(session,
      Matter::InteractionModel::MessageType::InvokeRequest.value,
      request.to_slice, 1_u32, 16_u16)
    handler.handle_message(inbound, DIAGNOSTIC_PEER)

    transport.sent_packets.size.should eq(1)
    outbound = diagnostic_bdx_outgoing(transport.sent_packets.first[0], session)
    outbound.payload.size.should be <= Matter::Protocol::IMHandler::MAX_REPORT_PAYLOAD_SIZE
    response = Matter::InteractionModel::InvokeResponseMessage.from_slice(outbound.payload)
    data = response.invoke_responses.first.command_data.as(Matter::InteractionModel::CommandDataIBTlv)
    payload = Matter::Cluster::DiagnosticLogs::RetrieveLogsResponse.from_tlv(data.command_fields.as(TLV::Any))
    payload.status.should eq(Matter::Cluster::DiagnosticLogs::LogsStatus::Success)
    payload.log_content.size.should eq(Matter::Cluster::DiagnosticLogs::MAX_INLINE_LOG_BYTES)
    handler.close
  end

  it "preserves another session's queued BDX when an Invoke response is suppressed" do
    handler, transport, first = diagnostic_bdx_fixture
    second = Matter::Spec::ProtocolMessages.case_session(182_u16)
    handler.sessions[second.session_id] = second
    handler.queue_bdx_transfer(second.session_id, 1_u8, 0x2222_u64,
      DIAGNOSTIC_PEER, "second-log".to_slice, Bytes[1], 18_u16).should be_true

    unsupported_path = Matter::InteractionModel::CommandPath.new(0_u16,
      Matter::Cluster::DiagnosticLogs::CLUSTER_ID, 99_u32)
    command = Matter::Cluster::DiagnosticLogs::RetrieveLogsRequest.new(
      Matter::Cluster::DiagnosticLogs::Intent::EndUserSupport)
    request = Matter::InteractionModel::InvokeRequestMessage.new([
      Matter::InteractionModel::CommandDataIBTlv.new(unsupported_path, command.to_tlv(nil)),
    ], suppress_response: true)
    inbound = Matter::Spec::ProtocolMessages.from_peer(first,
      Matter::InteractionModel::MessageType::InvokeRequest.value,
      request.to_slice, 1_u32, 17_u16)
    handler.handle_message(inbound, DIAGNOSTIC_PEER)
    transport.sent_packets.should be_empty

    handler.bdx_initiator.start_pending
    sent = transport.sent_packets.map(&.[0]).map { |wire| diagnostic_bdx_outgoing(wire, second) }
    sent.size.should eq(1)
    sent.first.payload_header.protocol_id.should eq(Matter::Protocol::ProtocolId::Bdx.value)
    handler.close
  end

  it "does not start another session's queued BDX after an unrelated Invoke succeeds" do
    handler, transport, first = diagnostic_bdx_fixture
    second = Matter::Spec::ProtocolMessages.case_session(182_u16)
    handler.sessions[second.session_id] = second
    handler.queue_bdx_transfer(second.session_id, 1_u8, 0x2222_u64,
      DIAGNOSTIC_PEER, "second-log".to_slice, Bytes[1], 18_u16).should be_true

    unsupported_path = Matter::InteractionModel::CommandPath.new(0_u16,
      Matter::Cluster::DiagnosticLogs::CLUSTER_ID, 99_u32)
    command = Matter::Cluster::DiagnosticLogs::RetrieveLogsRequest.new(
      Matter::Cluster::DiagnosticLogs::Intent::EndUserSupport)
    request = Matter::InteractionModel::InvokeRequestMessage.new([
      Matter::InteractionModel::CommandDataIBTlv.new(unsupported_path, command.to_tlv(nil)),
    ])
    inbound = Matter::Spec::ProtocolMessages.from_peer(first,
      Matter::InteractionModel::MessageType::InvokeRequest.value,
      request.to_slice, 1_u32, 17_u16)
    handler.handle_message(inbound, DIAGNOSTIC_PEER)
    transport.sent_packets.size.should eq(1)
    diagnostic_bdx_outgoing(transport.sent_packets.first[0], first).payload_header.message_type
      .should eq(Matter::InteractionModel::MessageType::InvokeResponse.value)

    handler.bdx_initiator.start_pending
    sent = diagnostic_bdx_outgoing(transport.sent_packets.last[0], second)
    sent.payload_header.protocol_id.should eq(Matter::Protocol::ProtocolId::Bdx.value)
    handler.close
  end

  it "does not defer an unrelated Invoke on the same CASE session for another exchange's queued log" do
    handler, transport, session = diagnostic_bdx_fixture
    handler.queue_bdx_transfer(session.session_id, 1_u8, 0x2222_u64,
      DIAGNOSTIC_PEER, "later-log".to_slice, Bytes[1], 18_u16).should be_true

    unsupported_path = Matter::InteractionModel::CommandPath.new(0_u16,
      Matter::Cluster::DiagnosticLogs::CLUSTER_ID, 99_u32)
    command = Matter::Cluster::DiagnosticLogs::RetrieveLogsRequest.new(
      Matter::Cluster::DiagnosticLogs::Intent::EndUserSupport)
    request = Matter::InteractionModel::InvokeRequestMessage.new([
      Matter::InteractionModel::CommandDataIBTlv.new(unsupported_path, command.to_tlv(nil)),
    ])
    inbound = Matter::Spec::ProtocolMessages.from_peer(session,
      Matter::InteractionModel::MessageType::InvokeRequest.value,
      request.to_slice, 1_u32, 17_u16)
    handler.handle_message(inbound, DIAGNOSTIC_PEER)

    transport.sent_packets.size.should eq(1)
    diagnostic_bdx_outgoing(transport.sent_packets.first[0], session).payload_header.message_type
      .should eq(Matter::InteractionModel::MessageType::InvokeResponse.value)
    handler.bdx_initiator.start_pending(session.object_id.to_u64, 18_u16)
    transport.sent_packets.size.should eq(2)
    diagnostic_bdx_outgoing(transport.sent_packets.last[0], session).payload_header.protocol_id
      .should eq(Matter::Protocol::ProtocolId::Bdx.value)
    handler.close
  end

  it "scopes pending BDX to the originating exchange on one live CASE session" do
    handler, transport, session = diagnostic_bdx_fixture
    identity = session.object_id.to_u64
    handler.queue_bdx_transfer(session.session_id, 1_u8, 0x2222_u64,
      DIAGNOSTIC_PEER, "new-log".to_slice, Bytes[2], 18_u16).should be_true

    handler.bdx_initiator.discard_pending(identity, 17_u16)
    handler.bdx_initiator.start_pending(identity, 17_u16)
    transport.sent_packets.should be_empty
    handler.bdx_initiator.start_pending(identity, 18_u16)
    sent = diagnostic_bdx_outgoing(transport.sent_packets.first[0], session)
    sent.payload_header.protocol_id.should eq(Matter::Protocol::ProtocolId::Bdx.value)
    init = DiagnosticBdx::Wire::Init.decode(DiagnosticBdx::Wire::Opcode::SendInit, sent.payload)
    String.new(init.file_designator).should eq("new-log")
    handler.close
  end

  it "allows a new matching BDX transfer after SendInit fails" do
    transport = FailingBdxTransport.new_for_spec
    handler = Matter::Protocol::MessageHandler.new(transport,
      setup_pin: 20202021_u32, discriminator: 3840_u16,
      fabric_table: Matter::FabricTable.new(Matter::Storage::Memory.new))
    session = Matter::Spec::ProtocolMessages.case_session(181_u16)
    handler.sessions[session.session_id] = session
    identity = session.object_id.to_u64
    handler.queue_bdx_transfer(session.session_id, 1_u8, 0x2222_u64,
      DIAGNOSTIC_PEER, "first-log".to_slice, Bytes[1], 17_u16).should be_true

    failed_exchange = handler.sender.next_exchange_id
    transport.fail_next_send = true
    expect_raises(IO::Error) { handler.bdx_initiator.start_pending(identity, 17_u16) }
    handler.bdx_initiator.handles?(session.session_id, failed_exchange).should be_false
    handler.queue_bdx_transfer(session.session_id, 1_u8, 0x2222_u64,
      DIAGNOSTIC_PEER, "second-log".to_slice, Bytes[2], 17_u16).should be_true
    handler.bdx_initiator.start_pending(identity, 17_u16)
    transport.sent_packets.size.should eq(1)
    sent = diagnostic_bdx_outgoing(transport.sent_packets.first[0], session)
    init = DiagnosticBdx::Wire::Init.decode(DiagnosticBdx::Wire::Opcode::SendInit, sent.payload)
    String.new(init.file_designator).should eq("second-log")
    handler.close
  end

  it "admits only one pending or active Diagnostic Logs BDX transfer" do
    handler, transport, session = diagnostic_bdx_fixture
    identity = session.object_id.to_u64
    handler.queue_bdx_transfer(session.session_id, 1_u8, 0x2222_u64,
      DIAGNOSTIC_PEER, "first-log".to_slice, Bytes[1], 17_u16).should be_true
    handler.queue_bdx_transfer(session.session_id, 1_u8, 0x2222_u64,
      DIAGNOSTIC_PEER, "second-log".to_slice, Bytes[2], 17_u16).should be_false

    handler.bdx_initiator.start_pending(identity, 17_u16)
    transport.sent_packets.size.should eq(1)
    handler.queue_bdx_transfer(session.session_id, 1_u8, 0x2222_u64,
      DIAGNOSTIC_PEER, "second-log".to_slice, Bytes[2], 17_u16).should be_false
    handler.close
  end

  it "sends SendInit before the encrypted RetrieveLogsResponse and waits for SendAccept" do
    handler, transport, session = diagnostic_bdx_fixture
    session.peer_subject_ids = [0x2222_u64]
    cluster = Matter::Cluster::DiagnosticLogs.new(Matter::DataType::EndpointNumber.new(0_u16))
    cluster.log("B" * 1100)
    cluster.on_bdx_transfer = ->(session_id : UInt16, fabric : UInt8, node : UInt64, peer : Socket::IPAddress, designator : Bytes, content : Bytes) do
      if exchange_id = cluster.request_exchange_id
        handler.queue_diagnostic_log_transfer(session_id, fabric, node, peer, designator, content, exchange_id)
      else
        Matter::Cluster::DiagnosticLogs::TransferStartResult::Unavailable
      end
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
    init_index = sent.index! { |message| message.payload_header.protocol_id == Matter::Protocol::ProtocolId::Bdx.value }
    init_message = sent[init_index]
    init_message.payload_header.message_type.should eq(DiagnosticBdx::Wire::Opcode::SendInit.value)
    sent.none? { |message| message.payload_header.message_type == Matter::InteractionModel::MessageType::InvokeResponse.value && message.payload_header.protocol_id == Matter::Protocol::ProtocolId::InteractionModel.value }.should be_true

    handler.handle_message(inbound, DIAGNOSTIC_PEER)
    replay = diagnostic_bdx_outgoing(transport.sent_packets.last[0], session)
    replay.payload_header.message_type.should eq(Matter::Protocol::SecureChannelMessageType::StandaloneAck.value)
    transport.sent_packets.map(&.[0]).map { |wire| diagnostic_bdx_outgoing(wire, session) }
      .count { |message| message.payload_header.protocol_id == Matter::Protocol::ProtocolId::Bdx.value && message.payload_header.message_type == DiagnosticBdx::Wire::Opcode::SendInit.value }
      .should eq(1)

    accept = DiagnosticBdx::Wire::Accept.new(DiagnosticBdx::Wire::Opcode::SendAccept,
      DiagnosticBdx::Wire::TransferControl::SenderDrive, 1024_u16)
    handler.handle_message(diagnostic_bdx_incoming(session, 2_u32,
      init_message.payload_header.exchange_id, accept.opcode, accept.to_slice), DIAGNOSTIC_PEER)

    sent = transport.sent_packets.map(&.[0]).map { |wire| diagnostic_bdx_outgoing(wire, session) }
    response_index = sent.index! { |message| message.payload_header.protocol_id == Matter::Protocol::ProtocolId::InteractionModel.value && message.payload_header.message_type == Matter::InteractionModel::MessageType::InvokeResponse.value }
    response_index.should be > init_index
    block_index = sent.index! { |message| message.payload_header.protocol_id == Matter::Protocol::ProtocolId::Bdx.value && message.payload_header.message_type == DiagnosticBdx::Wire::Opcode::Block.value }
    response_index.should be < block_index
    response = Matter::InteractionModel::InvokeResponseMessage.from_slice(sent[response_index].payload)
    response.invoke_responses.first.command_status.should be_nil
    data = response.invoke_responses.first.command_data.as(Matter::InteractionModel::CommandDataIBTlv)
    payload = Matter::Cluster::DiagnosticLogs::RetrieveLogsResponse.from_tlv(data.command_fields.as(TLV::Any))
    payload.status.should eq(Matter::Cluster::DiagnosticLogs::LogsStatus::Success)
    payload.log_content.should be_empty

    response_wire = transport.sent_packets[response_index][0]
    handler.handle_message(inbound, DIAGNOSTIC_PEER)
    transport.sent_packets.last[0].should eq(response_wire)
    handler.close
  end

  it "sends Denied after a BDX failure StatusReport and does not start a block" do
    handler, transport, session = diagnostic_bdx_fixture
    session.peer_subject_ids = [0x2222_u64]
    cluster = Matter::Cluster::DiagnosticLogs.new(Matter::DataType::EndpointNumber.new(0_u16))
    cluster.log("D" * 1100)
    cluster.on_bdx_transfer = ->(session_id : UInt16, fabric : UInt8, node : UInt64, peer : Socket::IPAddress, designator : Bytes, content : Bytes) do
      if exchange_id = cluster.request_exchange_id
        handler.queue_diagnostic_log_transfer(session_id, fabric, node, peer, designator, content, exchange_id)
      else
        Matter::Cluster::DiagnosticLogs::TransferStartResult::Unavailable
      end
    end
    handler.clusters[{0_u16, Matter::Cluster::DiagnosticLogs::CLUSTER_ID}] = cluster

    command = Matter::Cluster::DiagnosticLogs::RetrieveLogsRequest.new(
      Matter::Cluster::DiagnosticLogs::Intent::EndUserSupport,
      Matter::Cluster::DiagnosticLogs::TransferProtocol::BDX,
      "reject-log")
    path = Matter::InteractionModel::CommandPath.new(0_u16,
      Matter::Cluster::DiagnosticLogs::CLUSTER_ID,
      Matter::Cluster::DiagnosticLogs::CMD_RETRIEVE_LOGS_REQUEST)
    request = Matter::InteractionModel::InvokeRequestMessage.new([
      Matter::InteractionModel::CommandDataIBTlv.new(path, command.to_tlv(nil)),
    ])
    inbound = Matter::Spec::ProtocolMessages.from_peer(session,
      Matter::InteractionModel::MessageType::InvokeRequest.value,
      request.to_slice, 1_u32, 18_u16)
    handler.handle_message(inbound, DIAGNOSTIC_PEER)

    sent = transport.sent_packets.map(&.[0]).map { |wire| diagnostic_bdx_outgoing(wire, session) }
    init = sent.find! { |message| message.payload_header.protocol_id == Matter::Protocol::ProtocolId::Bdx.value }
    sent.none? { |message| message.payload_header.protocol_id == Matter::Protocol::ProtocolId::InteractionModel.value }.should be_true

    report = Matter::Session::Pase::Definitions::StatusReport.new(
      general_status: 1_u16,
      protocol_id: Matter::Protocol::ProtocolId::Bdx.value,
      protocol_status: DiagnosticBdx::Transfer::StatusCode::FileDesignatorUnknown.value)
    failure = Matter::Spec::ProtocolMessages.from_peer(session,
      Matter::Protocol::SecureChannelMessageType::StatusReport.value,
      report.to_bytes, 2_u32, init.payload_header.exchange_id,
      protocol_id: Matter::Protocol::ProtocolId::SecureChannel.value,
      initiator_message: false)
    handler.handle_message(failure, DIAGNOSTIC_PEER)

    sent = transport.sent_packets.map(&.[0]).map { |wire| diagnostic_bdx_outgoing(wire, session) }
    response = sent.find! do |message|
      message.payload_header.protocol_id == Matter::Protocol::ProtocolId::InteractionModel.value &&
        message.payload_header.message_type == Matter::InteractionModel::MessageType::InvokeResponse.value
    end
    response.payload_header.exchange_id.should eq(inbound.payload_header.exchange_id)
    data = Matter::InteractionModel::InvokeResponseMessage.from_slice(response.payload)
      .invoke_responses.first.command_data.as(Matter::InteractionModel::CommandDataIBTlv)
    payload = Matter::Cluster::DiagnosticLogs::RetrieveLogsResponse.from_tlv(data.command_fields.as(TLV::Any))
    payload.status.should eq(Matter::Cluster::DiagnosticLogs::LogsStatus::Denied)
    sent.none? { |message| message.payload_header.message_type == DiagnosticBdx::Wire::Opcode::Block.value && message.payload_header.protocol_id == Matter::Protocol::ProtocolId::Bdx.value }.should be_true
    handler.close
  end

  it "reports Busy for a second BDX request from the same CASE peer during an active transfer" do
    handler, transport, session = diagnostic_bdx_fixture
    session.peer_subject_ids = [0x2222_u64]
    cluster = Matter::Cluster::DiagnosticLogs.new(Matter::DataType::EndpointNumber.new(0_u16))
    cluster.log("C" * 1100)
    cluster.on_bdx_transfer = ->(session_id : UInt16, fabric : UInt8, node : UInt64, peer : Socket::IPAddress, designator : Bytes, content : Bytes) do
      if exchange_id = cluster.request_exchange_id
        handler.queue_diagnostic_log_transfer(session_id, fabric, node, peer, designator, content, exchange_id)
      else
        Matter::Cluster::DiagnosticLogs::TransferStartResult::Unavailable
      end
    end
    handler.clusters[{0_u16, Matter::Cluster::DiagnosticLogs::CLUSTER_ID}] = cluster

    command = Matter::Cluster::DiagnosticLogs::RetrieveLogsRequest.new(
      Matter::Cluster::DiagnosticLogs::Intent::EndUserSupport,
      Matter::Cluster::DiagnosticLogs::TransferProtocol::BDX,
      "busy-log")
    path = Matter::InteractionModel::CommandPath.new(0_u16,
      Matter::Cluster::DiagnosticLogs::CLUSTER_ID,
      Matter::Cluster::DiagnosticLogs::CMD_RETRIEVE_LOGS_REQUEST)
    request = Matter::InteractionModel::InvokeRequestMessage.new([
      Matter::InteractionModel::CommandDataIBTlv.new(path, command.to_tlv(nil)),
    ])
    first = Matter::Spec::ProtocolMessages.from_peer(session,
      Matter::InteractionModel::MessageType::InvokeRequest.value,
      request.to_slice, 1_u32, 19_u16)
    handler.handle_message(first, DIAGNOSTIC_PEER)
    second = Matter::Spec::ProtocolMessages.from_peer(session,
      Matter::InteractionModel::MessageType::InvokeRequest.value,
      request.to_slice, 2_u32, 20_u16)
    handler.handle_message(second, DIAGNOSTIC_PEER)

    sent = transport.sent_packets.map(&.[0]).map { |wire| diagnostic_bdx_outgoing(wire, session) }
    sent.count { |message| message.payload_header.protocol_id == Matter::Protocol::ProtocolId::Bdx.value && message.payload_header.message_type == DiagnosticBdx::Wire::Opcode::SendInit.value }.should eq(1)
    response = sent.find! do |message|
      message.payload_header.protocol_id == Matter::Protocol::ProtocolId::InteractionModel.value &&
        message.payload_header.message_type == Matter::InteractionModel::MessageType::InvokeResponse.value &&
        message.payload_header.exchange_id == second.payload_header.exchange_id
    end
    data = Matter::InteractionModel::InvokeResponseMessage.from_slice(response.payload)
      .invoke_responses.first.command_data.as(Matter::InteractionModel::CommandDataIBTlv)
    payload = Matter::Cluster::DiagnosticLogs::RetrieveLogsResponse.from_tlv(data.command_fields.as(TLV::Any))
    payload.status.should eq(Matter::Cluster::DiagnosticLogs::LogsStatus::Busy)
    handler.close
  end

  it "waits for the final chunk of a batched InvokeResponse before sending BDX data" do
    handler, transport, session = diagnostic_bdx_fixture
    session.peer_subject_ids = [0x2222_u64]
    cluster = Matter::Cluster::DiagnosticLogs.new(Matter::DataType::EndpointNumber.new(0_u16))
    cluster.log("E" * 1100)
    cluster.on_bdx_transfer = ->(session_id : UInt16, fabric : UInt8, node : UInt64, peer : Socket::IPAddress, designator : Bytes, content : Bytes) do
      if exchange_id = cluster.request_exchange_id
        handler.queue_diagnostic_log_transfer(session_id, fabric, node, peer, designator, content, exchange_id)
      else
        Matter::Cluster::DiagnosticLogs::TransferStartResult::Unavailable
      end
    end
    handler.clusters[{0_u16, Matter::Cluster::DiagnosticLogs::CLUSTER_ID}] = cluster

    command = Matter::Cluster::DiagnosticLogs::RetrieveLogsRequest.new(
      Matter::Cluster::DiagnosticLogs::Intent::EndUserSupport,
      Matter::Cluster::DiagnosticLogs::TransferProtocol::BDX,
      "chunk-log")
    path = Matter::InteractionModel::CommandPath.new(0_u16,
      Matter::Cluster::DiagnosticLogs::CLUSTER_ID,
      Matter::Cluster::DiagnosticLogs::CMD_RETRIEVE_LOGS_REQUEST)
    invalid_path = Matter::InteractionModel::CommandPath.new(0_u16,
      Matter::Cluster::DiagnosticLogs::CLUSTER_ID, UInt32::MAX)
    commands = [Matter::InteractionModel::CommandDataIBTlv.new(path, command.to_tlv(nil))]
    80.times { commands << Matter::InteractionModel::CommandDataIBTlv.new(invalid_path, command.to_tlv(nil)) }
    request = Matter::InteractionModel::InvokeRequestMessage.new(commands)
    invoke = Matter::Spec::ProtocolMessages.from_peer(session,
      Matter::InteractionModel::MessageType::InvokeRequest.value,
      request.to_slice, 1_u32, 21_u16)
    handler.handle_message(invoke, DIAGNOSTIC_PEER)

    outgoing = transport.sent_packets.map(&.[0]).map { |wire| diagnostic_bdx_outgoing(wire, session) }
    init = outgoing.find! { |message| message.payload_header.protocol_id == Matter::Protocol::ProtocolId::Bdx.value }
    accept = DiagnosticBdx::Wire::Accept.new(DiagnosticBdx::Wire::Opcode::SendAccept,
      DiagnosticBdx::Wire::TransferControl::SenderDrive, 1024_u16)
    handler.handle_message(diagnostic_bdx_incoming(session, 2_u32,
      init.payload_header.exchange_id, accept.opcode, accept.to_slice), DIAGNOSTIC_PEER)

    outgoing = transport.sent_packets.map(&.[0]).map { |wire| diagnostic_bdx_outgoing(wire, session) }
    response = Matter::InteractionModel::InvokeResponseMessage.from_slice(outgoing.reverse.find! do |message|
      message.payload_header.protocol_id == Matter::Protocol::ProtocolId::InteractionModel.value &&
        message.payload_header.message_type == Matter::InteractionModel::MessageType::InvokeResponse.value
    end.payload)
    response.more_chunked_messages.should be_true
    outgoing.none? { |message| message.payload_header.protocol_id == Matter::Protocol::ProtocolId::Bdx.value && message.payload_header.message_type == DiagnosticBdx::Wire::Opcode::Block.value }.should be_true

    counter = 3_u32
    while response.more_chunked_messages == true
      handler.handle_message(Matter::Spec::ProtocolMessages.status_response(session, counter, 21_u16), DIAGNOSTIC_PEER)
      counter += 1_u32
      outgoing = transport.sent_packets.map(&.[0]).map { |wire| diagnostic_bdx_outgoing(wire, session) }
      response = Matter::InteractionModel::InvokeResponseMessage.from_slice(outgoing.reverse.find! do |message|
        message.payload_header.protocol_id == Matter::Protocol::ProtocolId::InteractionModel.value &&
          message.payload_header.message_type == Matter::InteractionModel::MessageType::InvokeResponse.value
      end.payload)
      if response.more_chunked_messages == true
        outgoing.none? { |message| message.payload_header.protocol_id == Matter::Protocol::ProtocolId::Bdx.value && message.payload_header.message_type == DiagnosticBdx::Wire::Opcode::Block.value }.should be_true
      end
    end
    outgoing.any? { |message| message.payload_header.protocol_id == Matter::Protocol::ProtocolId::Bdx.value && message.payload_header.message_type == DiagnosticBdx::Wire::Opcode::Block.value }.should be_true
    handler.close
  end

  it "sends command data after BDX acceptance even when InvokeRequest suppresses statuses" do
    handler, transport, session = diagnostic_bdx_fixture
    session.peer_subject_ids = [0x2222_u64]
    cluster = Matter::Cluster::DiagnosticLogs.new(Matter::DataType::EndpointNumber.new(0_u16))
    cluster.log("B" * 1100)
    cluster.on_bdx_transfer = ->(session_id : UInt16, fabric : UInt8, node : UInt64, peer : Socket::IPAddress, designator : Bytes, content : Bytes) do
      if exchange_id = cluster.request_exchange_id
        handler.queue_diagnostic_log_transfer(session_id, fabric, node, peer, designator, content, exchange_id)
      else
        Matter::Cluster::DiagnosticLogs::TransferStartResult::Unavailable
      end
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
    ], suppress_response: true)
    inbound = Matter::Spec::ProtocolMessages.from_peer(session,
      Matter::InteractionModel::MessageType::InvokeRequest.value,
      request.to_slice, 1_u32, 17_u16)
    handler.handle_message(inbound, DIAGNOSTIC_PEER)

    sent = transport.sent_packets.map(&.[0]).map { |wire| diagnostic_bdx_outgoing(wire, session) }
    sent.size.should eq(2)
    sent[0].payload_header.message_type.should eq(Matter::Protocol::SecureChannelMessageType::StandaloneAck.value)
    sent[1].payload_header.protocol_id.should eq(Matter::Protocol::ProtocolId::Bdx.value)
    sent[1].payload_header.message_type.should eq(DiagnosticBdx::Wire::Opcode::SendInit.value)

    accept = DiagnosticBdx::Wire::Accept.new(DiagnosticBdx::Wire::Opcode::SendAccept,
      DiagnosticBdx::Wire::TransferControl::SenderDrive, 1024_u16)
    handler.handle_message(diagnostic_bdx_incoming(session, 2_u32,
      sent[1].payload_header.exchange_id, accept.opcode, accept.to_slice), DIAGNOSTIC_PEER)
    response = transport.sent_packets.map(&.[0]).map { |wire| diagnostic_bdx_outgoing(wire, session) }
      .find! do |message|
        message.payload_header.protocol_id == Matter::Protocol::ProtocolId::InteractionModel.value &&
          message.payload_header.message_type == Matter::InteractionModel::MessageType::InvokeResponse.value
      end
    Matter::InteractionModel::InvokeResponseMessage.from_slice(response.payload)
      .invoke_responses.first.command_data.should_not be_nil
    handler.close
  end

  it "suppresses an InvokeResponse containing only command statuses" do
    handler, transport, session = diagnostic_bdx_fixture
    cluster = Matter::Cluster::DiagnosticLogs.new(Matter::DataType::EndpointNumber.new(0_u16))
    handler.clusters[{0_u16, Matter::Cluster::DiagnosticLogs::CLUSTER_ID}] = cluster

    command = Matter::Cluster::DiagnosticLogs::RetrieveLogsRequest.new(
      Matter::Cluster::DiagnosticLogs::Intent::EndUserSupport,
      Matter::Cluster::DiagnosticLogs::TransferProtocol::ResponsePayload,
      "support-log")
    unsupported_path = Matter::InteractionModel::CommandPath.new(0_u16,
      Matter::Cluster::DiagnosticLogs::CLUSTER_ID, 99_u32)
    request = Matter::InteractionModel::InvokeRequestMessage.new([
      Matter::InteractionModel::CommandDataIBTlv.new(unsupported_path, command.to_tlv(nil)),
    ], suppress_response: true)
    inbound = Matter::Spec::ProtocolMessages.from_peer(session,
      Matter::InteractionModel::MessageType::InvokeRequest.value,
      request.to_slice, 1_u32, 17_u16)
    handler.handle_message(inbound, DIAGNOSTIC_PEER)

    transport.sent_packets.should be_empty
    handler.close
  end

  it "sends a named multi-block log on the authenticated CASE exchange" do
    handler, transport, session = diagnostic_bdx_fixture
    contents = Bytes.new(1500) { |index| (index % 251).to_u8 }
    handler.queue_bdx_transfer(session.session_id, 1_u8, 0x2222_u64,
      DIAGNOSTIC_PEER, "support-log".to_slice, contents, 17_u16).should be_true
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

  it "piggybacks the ReceiverDrive BlockQuery acknowledgement on its Block" do
    handler, transport, session = diagnostic_bdx_fixture
    handler.queue_bdx_transfer(session.session_id, 1_u8, 0x2222_u64,
      DIAGNOSTIC_PEER, "support-log".to_slice, Bytes.new(1200, 0x41_u8), 17_u16).should be_true
    handler.bdx_initiator.start_pending
    init = diagnostic_bdx_outgoing(transport.sent_packets.last[0], session)
    exchange = init.payload_header.exchange_id

    accept = DiagnosticBdx::Wire::Accept.new(DiagnosticBdx::Wire::Opcode::SendAccept,
      DiagnosticBdx::Wire::TransferControl::ReceiverDrive, 1024_u16)
    handler.handle_message(diagnostic_bdx_incoming(session, 1_u32, exchange,
      accept.opcode, accept.to_slice), DIAGNOSTIC_PEER)
    query = DiagnosticBdx::Wire::BlockCounterMessage.new(DiagnosticBdx::Wire::Opcode::BlockQuery, 0_u32)
    handler.handle_message(diagnostic_bdx_incoming(session, 2_u32, exchange,
      query.opcode, query.to_slice), DIAGNOSTIC_PEER)

    blocks = transport.sent_packets.map(&.[0]).map { |wire| diagnostic_bdx_outgoing(wire, session) }
      .select { |message| message.payload_header.message_type == DiagnosticBdx::Wire::Opcode::Block.value }
    blocks.size.should eq(1)
    blocks.first.payload_header.acknowledged_message_id.should eq(2_u32)
    original_block = transport.sent_packets.find! do |wire, _peer|
      diagnostic_bdx_outgoing(wire, session).payload_header.message_type == DiagnosticBdx::Wire::Opcode::Block.value
    end[0]
    handler.handle_message(diagnostic_bdx_incoming(session, 2_u32, exchange,
      query.opcode, query.to_slice), DIAGNOSTIC_PEER)
    transport.sent_packets.last[0].should eq(original_block)
    handler.close
  end

  it "rejects a queue request for another fabric or peer and cleans up on session removal" do
    handler, _transport, session = diagnostic_bdx_fixture
    handler.queue_bdx_transfer(session.session_id, 2_u8, 0x2222_u64,
      DIAGNOSTIC_PEER, "log".to_slice, Bytes[1], 17_u16).should be_false
    handler.queue_bdx_transfer(session.session_id, 1_u8, 0x9999_u64,
      DIAGNOSTIC_PEER, "log".to_slice, Bytes[1], 17_u16).should be_false
    handler.queue_bdx_transfer(session.session_id, 1_u8, 0x2222_u64,
      DIAGNOSTIC_PEER, "log".to_slice, Bytes[1], 17_u16).should be_true
    handler.delete_session(session.session_id).should be_true
    handler.bdx_initiator.start_pending
    handler.close
  end

  it "aborts malformed transfer negotiation with a BDX StatusReport" do
    handler, transport, session = diagnostic_bdx_fixture
    handler.queue_bdx_transfer(session.session_id, 1_u8, 0x2222_u64,
      DIAGNOSTIC_PEER, "log".to_slice, Bytes[1], 17_u16).should be_true
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
