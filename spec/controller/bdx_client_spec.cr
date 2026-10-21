require "../spec_helper"
require "../../src/matter/controller/bdx_client"
require "../../src/matter/protocol/bdx/responder"

private alias BdxClientWire = Matter::Protocol::Bdx::Wire
private BDX_CLIENT_PEER = Socket::IPAddress.new("127.0.0.1", 5540)

private class BdxLoopbackClient
  getter responder : Matter::Protocol::Bdx::Responder
  getter statuses_sent : Array(UInt16)
  getter timeouts : Array(Time::Span)

  @responses : Array(Matter::Controller::Client::ReceivedMessage)

  def initialize(@responder : Matter::Protocol::Bdx::Responder)
    @responses = [] of Matter::Controller::Client::ReceivedMessage
    @statuses_sent = [] of UInt16
    @timeouts = [] of Time::Span
  end

  def next_exchange_id : UInt16
    77_u16
  end

  def send_encrypted_request(session : Matter::Session::SecureContext, peer : Socket::IPAddress,
                             protocol_id : UInt16, message_type : UInt8, payload : Bytes | Slice(UInt8),
                             exchange_id : UInt16 = next_exchange_id, initiator_message : Bool = true,
                             requires_ack : Bool = true, acknowledged_message_id : UInt32? = nil) : UInt16
    if protocol_id == Matter::Protocol::ProtocolId::SecureChannel.value
      report = Matter::Session::Pase::Definitions::StatusReport.from_bytes(payload.to_slice)
      @statuses_sent << report.protocol_status
      return exchange_id
    end
    opcode = BdxClientWire::Opcode.from_value(message_type)
    step = @responder.receive(session, exchange_id, opcode, payload.to_slice)
    if status = step.status
      report = Matter::Session::Pase::Definitions::StatusReport.new(
        general_status: 1_u16, protocol_id: Matter::Protocol::ProtocolId::Bdx.value,
        protocol_status: status.value)
      queue(session, peer, exchange_id, Matter::Protocol::ProtocolId::SecureChannel.value,
        Matter::Protocol::SecureChannelMessageType::StatusReport.value, report.to_bytes)
    elsif message = step.message
      queue(session, peer, exchange_id, Matter::Protocol::ProtocolId::Bdx.value,
        message.opcode.value, message.to_slice)
      if follow_up = step.follow_up
        queue(session, peer, exchange_id, Matter::Protocol::ProtocolId::Bdx.value,
          follow_up.opcode.value, follow_up.to_slice)
      end
    end
    exchange_id
  end

  def wait_for_exchange_message(exchange_id : UInt16,
                                message_types : Array(Tuple(UInt16, UInt8)),
                                timeout : Time::Span) : Matter::Controller::Client::ReceivedMessage?
    @timeouts << timeout
    @responses.shift?
  end

  private def queue(session : Matter::Session::SecureContext, peer : Socket::IPAddress,
                    exchange_id : UInt16, protocol_id : UInt16, message_type : UInt8,
                    payload : Bytes) : Nil
    packet = Matter::Codec::MessageCodec::PacketHeader.new(
      session_id: session.session_id,
      session_type: Matter::Codec::MessageCodec::SessionType::Unicast,
      message_id: 1_u32)
    header = Matter::Codec::MessageCodec::PayloadHeader.new(
      exchange_id: exchange_id, protocol_id: protocol_id,
      message_type: message_type, initiator_message: false,
      requires_acknowledge: true)
    @responses << Matter::Controller::Client::ReceivedMessage.new(
      Matter::Codec::MessageCodec::Message.new(packet, header, payload), peer)
  end
end

private def bdx_client_case_session : Matter::Session::SecureContext
  Matter::Session::SecureContext.new(
    session_id: 41_u16, peer_session_id: 42_u16,
    session_type: Matter::Session::SessionType::Unicast,
    encryption_key: Bytes.new(16, 1_u8), decryption_key: Bytes.new(16, 2_u8),
    peer_node_id: Matter::DataType::NodeId.new(0x123_u64),
    case_session: true, fabric_index: 1_u8)
end

describe Matter::Controller::BdxClient do
  it "downloads a named stream through Accept, queries, EOF, and final ACK" do
    responder = Matter::Protocol::Bdx::Responder.new
    responder.on_download = ->(_session : Matter::Session::SecureContext, init : BdxClientWire::Init) do
      init.file_designator == Bytes[0x66] ? Matter::Protocol::Bdx::Responder::Source.new(IO::Memory.new(Bytes[1, 2, 3, 4, 5]), 5_u64).as(Matter::Protocol::Bdx::Responder::Source?) : nil
    end
    client = BdxLoopbackClient.new(responder)
    sink = IO::Memory.new
    bytes = Matter::Controller::BdxClient.new(client).download(
      bdx_client_case_session, BDX_CLIENT_PEER, Bytes[0x66], sink,
      max_bytes: 10_u64, block_size: 2_u16)
    bytes.should eq(5_u64)
    sink.to_slice.should eq(Bytes[1, 2, 3, 4, 5])
    responder.active_count.should eq(0)
    client.timeouts.should_not be_empty
    client.timeouts.each(&.should(be >= 5.minutes))
  end

  it "uploads a named stream and reports remote authorization failures" do
    sink = IO::Memory.new
    responder = Matter::Protocol::Bdx::Responder.new
    responder.on_upload = ->(_session : Matter::Session::SecureContext, init : BdxClientWire::Init) do
      init.file_designator == Bytes[0x75] ? sink.as(IO) : nil
    end
    client = BdxLoopbackClient.new(responder)
    bdx = Matter::Controller::BdxClient.new(client)
    bdx.upload(bdx_client_case_session, BDX_CLIENT_PEER, Bytes[0x75],
      IO::Memory.new(Bytes[1, 2, 3]), 3_u64, block_size: 2_u16).should eq(3_u64)
    sink.to_slice.should eq(Bytes[1, 2, 3])
    expect_raises(Matter::Controller::BdxClient::RemoteError) do
      bdx.upload(bdx_client_case_session, BDX_CLIENT_PEER, Bytes[0xff],
        IO::Memory.new(Bytes[1]), 1_u64)
    end
    client.statuses_sent.should be_empty
  end
end
