require "../spec_helper"
require "../../src/matter/protocol/message_handler"

private alias BdxRoute = Matter::Protocol::Bdx
private BDX_PEER = Socket::IPAddress.new("127.0.0.1", 5540)

private def bdx_route_fixture
  transport = Matter::Spec::CaptureTransport.new_for_spec
  handler = Matter::Protocol::MessageHandler.new(transport,
    setup_pin: 20202021_u32, discriminator: 3840_u16,
    fabric_table: Matter::FabricTable.new(Matter::Storage::Memory.new))
  session = Matter::Spec::ProtocolMessages.case_session(81_u16)
  handler.sessions[session.session_id] = session
  {handler, transport, session}
end

private def bdx_route_message(session : Matter::Session::SecureContext, counter : UInt32,
                              exchange : UInt16, opcode : BdxRoute::Wire::Opcode,
                              payload : Bytes)
  Matter::Spec::ProtocolMessages.from_peer(session, opcode.value, payload,
    counter, exchange, protocol_id: Matter::Protocol::ProtocolId::Bdx.value)
end

private def bdx_route_response(packet_bytes : Bytes, session : Matter::Session::SecureContext)
  packet = Matter::Codec::MessageCodec::Base.decode_packet(packet_bytes)
  header_bytes = packet_bytes[0, packet_bytes.size - packet.payload.size]
  node_id = session.local_node_id.as(Matter::DataType::NodeId).id
  nonce = Matter::Session::SecureMessage.build_nonce(node_id,
    packet.header.message_id, header_bytes[Matter::Codec::MessageCodec::SECURITY_FLAGS_OFFSET])
  plaintext = Matter::Crypto::StandardCrypto.new.decrypt(session.encryption_key,
    packet.payload, nonce, header_bytes)
  Matter::Codec::MessageCodec::Base.decode_payload(
    Matter::Codec::MessageCodec::Packet.new(packet.header, plaintext))
end

describe "BDX encrypted routing" do
  it "routes a CASE download on one exchange and replays the same encrypted response to a duplicate" do
    handler, transport, session = bdx_route_fixture
    handler.bdx.on_download = ->(_session : Matter::Session::SecureContext, init : BdxRoute::Wire::Init) do
      init.file_designator == Bytes[0x61] ? BdxRoute::Responder::Source.new(IO::Memory.new(Bytes[1, 2, 3]), 3_u64).as(BdxRoute::Responder::Source?) : nil
    end
    init = BdxRoute::Wire::Init.new(BdxRoute::Wire::Opcode::ReceiveInit,
      BdxRoute::Wire::TransferControl::ReceiverDrive, 2_u16, Bytes[0x61])
    request = bdx_route_message(session, 1_u32, 7_u16, init.opcode, init.to_slice)
    handler.handle_message(request, BDX_PEER)
    response = bdx_route_response(transport.sent_packets.last[0], session)
    response.payload_header.protocol_id.should eq(Matter::Protocol::ProtocolId::Bdx.value)
    response.payload_header.message_type.should eq(BdxRoute::Wire::Opcode::ReceiveAccept.value)
    response.payload_header.exchange_id.should eq(7_u16)
    response.payload_header.initiator_message?.should be_false
    accept_bytes = transport.sent_packets.last[0]
    handler.handle_message(request, BDX_PEER)
    transport.sent_packets.last[0].should eq(accept_bytes)
    handler.bdx.active_count.should eq(1)

    query = BdxRoute::Wire::BlockCounterMessage.new(BdxRoute::Wire::Opcode::BlockQuery, 0_u32)
    handler.handle_message(bdx_route_message(session, 2_u32, 7_u16, query.opcode, query.to_slice), BDX_PEER)
    block = bdx_route_response(transport.sent_packets.last[0], session)
    block.payload_header.message_type.should eq(BdxRoute::Wire::Opcode::Block.value)
    BdxRoute::Wire::BlockData.decode(BdxRoute::Wire::Opcode::Block, block.payload, max_block_size: 2).data.should eq(Bytes[1, 2])
    handler.close
  end

  it "sends an encrypted BDX status for an unregistered file and never opens a transfer" do
    handler, transport, session = bdx_route_fixture
    init = BdxRoute::Wire::Init.new(BdxRoute::Wire::Opcode::ReceiveInit,
      BdxRoute::Wire::TransferControl::ReceiverDrive, 16_u16, Bytes[0xff])
    handler.handle_message(bdx_route_message(session, 1_u32, 9_u16, init.opcode, init.to_slice), BDX_PEER)
    response = bdx_route_response(transport.sent_packets.last[0], session)
    response.payload_header.protocol_id.should eq(Matter::Protocol::ProtocolId::SecureChannel.value)
    response.payload_header.message_type.should eq(Matter::Protocol::SecureChannelMessageType::StatusReport.value)
    report = Matter::Session::Pase::Definitions::StatusReport.from_bytes(response.payload)
    report.protocol_id.should eq(Matter::Protocol::ProtocolId::Bdx.value)
    report.protocol_status.should eq(BdxRoute::Transfer::StatusCode::FileDesignatorUnknown.value)
    handler.bdx.active_count.should eq(0)
    handler.close
  end

  it "releases a running BDX stream when its CASE session is deleted" do
    handler, _transport, session = bdx_route_fixture
    stream = IO::Memory.new(Bytes[1])
    handler.bdx.on_download = ->(_session : Matter::Session::SecureContext, _init : BdxRoute::Wire::Init) do
      BdxRoute::Responder::Source.new(stream, 1_u64).as(BdxRoute::Responder::Source?)
    end
    init = BdxRoute::Wire::Init.new(BdxRoute::Wire::Opcode::ReceiveInit,
      BdxRoute::Wire::TransferControl::ReceiverDrive, 2_u16, Bytes[0x61])
    handler.handle_message(bdx_route_message(session, 1_u32, 7_u16, init.opcode, init.to_slice), BDX_PEER)
    handler.bdx.active_count.should eq(1)
    handler.delete_session(session.session_id).should be_true
    deadline = Time.instant + 2.seconds
    until stream.closed? || Time.instant >= deadline
      sleep 1.millisecond
    end
    handler.bdx.active_count.should eq(0)
    stream.closed?.should be_true
    handler.close
  end

  it "replays both Accept and the first Block for sender-drive Init retransmission" do
    handler, transport, session = bdx_route_fixture
    handler.bdx.on_download = ->(_session : Matter::Session::SecureContext, _init : BdxRoute::Wire::Init) do
      BdxRoute::Responder::Source.new(IO::Memory.new(Bytes[7]), 1_u64).as(BdxRoute::Responder::Source?)
    end
    both = BdxRoute::Wire::TransferControl::SenderDrive | BdxRoute::Wire::TransferControl::ReceiverDrive
    init = BdxRoute::Wire::Init.new(BdxRoute::Wire::Opcode::ReceiveInit,
      both, 2_u16, Bytes[0x61])
    request = bdx_route_message(session, 1_u32, 21_u16, init.opcode, init.to_slice)
    handler.handle_message(request, BDX_PEER)
    transport.sent_packets.size.should eq(2)
    transport.sent_packets.map(&.[0]).map { |wire| bdx_route_response(wire, session).payload_header.message_type }
      .should eq([BdxRoute::Wire::Opcode::ReceiveAccept.value, BdxRoute::Wire::Opcode::BlockEOF.value])
    initial_packets = transport.sent_packets.map(&.[0])
    handler.handle_message(request, BDX_PEER)
    transport.sent_packets.last(2).map(&.[0]).should eq(initial_packets)
    handler.close
  end
end
