require "../spec_helper"
require "../../src/matter/controller"

private class InvokeChunkClient < Matter::Controller::Client
  getter sent = [] of Tuple(UInt8, Bytes, UInt16, UInt32?)
  getter replies = [] of ReceivedMessage

  def initialize
    super
    @next_exchange_id = 1_u16
  end

  def send_encrypted_request(
    session : Matter::Session::SecureContext,
    peer : Socket::IPAddress,
    protocol_id : UInt16,
    message_type : UInt8,
    payload : Bytes | Slice(UInt8),
    exchange_id : UInt16 = next_exchange_id,
    initiator_message : Bool = true,
    requires_ack : Bool = true,
    acknowledged_message_id : UInt32? = nil,
  ) : UInt16
    @sent << {message_type, payload.to_slice, exchange_id, acknowledged_message_id}
    exchange_id
  end

  def wait_for_any(exchange_id : UInt16, protocol_id : UInt16,
                   message_types : Array(UInt8), timeout : Time::Span) : ReceivedMessage?
    reply = @replies.shift?
    return unless reply
    raise "wrong exchange" unless reply.message.payload_header.exchange_id == exchange_id
    raise "wrong message type" unless message_types.includes?(reply.message.payload_header.message_type)
    reply
  end

  def wait_for(exchange_id : UInt16, protocol_id : UInt16,
               message_type : UInt8, timeout : Time::Span) : ReceivedMessage?
    wait_for_any(exchange_id, protocol_id, [message_type], timeout)
  end

  def queue(message_type : UInt8, payload : Bytes, message_id : UInt32,
            session_id : UInt16 = 1_u16) : Nil
    packet = Matter::Codec::MessageCodec::PacketHeader.new(session_id,
      Matter::Codec::MessageCodec::SessionType::Unicast, message_id)
    header = Matter::Codec::MessageCodec::PayloadHeader.new(1_u16,
      PROTOCOL_INTERACTION_MODEL, message_type, false, true)
    @replies << ReceivedMessage.new(
      Matter::Codec::MessageCodec::Message.new(packet, header, payload),
      Socket::IPAddress.new("127.0.0.1", 5540))
  end
end

private def invoke_chunk_session : Matter::Session::SecureContext
  Matter::Session::SecureContext.new(
    session_id: 1_u16, peer_session_id: 1_u16,
    session_type: Matter::Session::SessionType::Unicast,
    encryption_key: Bytes.new(16), decryption_key: Bytes.new(16))
end

private def invoke_chunk(status : Matter::InteractionModel::StatusCode,
                         more : Bool) : Bytes
  path = Matter::InteractionModel::CommandPath.new(endpoint: 1_u16, cluster: 6_u32, command: 0_u32)
  command_status = Matter::InteractionModel::CommandStatusIB.new(path,
    Matter::InteractionModel::StatusIB.new(status.value))
  Matter::InteractionModel::InvokeResponseMessage.new(
    invoke_responses: [Matter::InteractionModel::InvokeResponseIB.new(command_status: command_status)],
    more_chunked_messages: more).to_slice
end

describe "controller chunked InvokeResponse" do
  it "rejects a Success status for a different requested command" do
    require_udp_sockets!
    client = InvokeChunkClient.new
    path = Matter::InteractionModel::CommandPath.new(endpoint: 1_u16,
      cluster: Matter::Cluster::OnOff::CLUSTER_ID,
      command: Matter::Cluster::OnOff::CMD_OFF)
    status = Matter::InteractionModel::CommandStatusIB.new(path,
      Matter::InteractionModel::StatusIB.new(Matter::InteractionModel::StatusCode::Success.value))
    response = Matter::InteractionModel::InvokeResponseMessage.new(invoke_responses: [
      Matter::InteractionModel::InvokeResponseIB.new(command_status: status),
    ])
    client.queue(Matter::Controller::ImClient::MSG_INVOKE_RESPONSE, response.to_slice, 11_u32)

    expect_raises(Matter::ProtocolError, /InvokeResponse.*path/) do
      Matter::Controller::ImClient.new(client).invoke(invoke_chunk_session,
        Socket::IPAddress.new("127.0.0.1", 5540), 1_u16,
        Matter::Cluster::OnOff::CLUSTER_ID, Matter::Cluster::OnOff::CMD_ON)
    end
  ensure
    client.try(&.close)
  end

  it "rejects response data from another endpoint even when the command ID matches" do
    require_udp_sockets!
    client = InvokeChunkClient.new
    path = Matter::InteractionModel::CommandPath.new(endpoint: 2_u16,
      cluster: Matter::Cluster::OnOff::CLUSTER_ID,
      command: Matter::Cluster::OnOff::CMD_ON)
    data = Matter::InteractionModel::CommandDataIBTlv.new(path, TLV::Any.new(true, nil))
    response = Matter::InteractionModel::InvokeResponseMessage.new(invoke_responses: [
      Matter::InteractionModel::InvokeResponseIB.new(command_data: data),
    ])
    client.queue(Matter::Controller::ImClient::MSG_INVOKE_RESPONSE, response.to_slice, 11_u32)

    expect_raises(Matter::ProtocolError, /InvokeResponse.*path/) do
      Matter::Controller::ImClient.new(client).invoke(invoke_chunk_session,
        Socket::IPAddress.new("127.0.0.1", 5540), 1_u16,
        Matter::Cluster::OnOff::CLUSTER_ID, Matter::Cluster::OnOff::CMD_ON)
    end
  ensure
    client.try(&.close)
  end

  it "rejects response data from another cluster" do
    require_udp_sockets!
    client = InvokeChunkClient.new
    path = Matter::InteractionModel::CommandPath.new(endpoint: 1_u16,
      cluster: Matter::Cluster::Identify::CLUSTER_ID,
      command: Matter::Cluster::Identify::CMD_IDENTIFY)
    data = Matter::InteractionModel::CommandDataIBTlv.new(path, TLV::Any.new(true, nil))
    response = Matter::InteractionModel::InvokeResponseMessage.new(invoke_responses: [
      Matter::InteractionModel::InvokeResponseIB.new(command_data: data),
    ])
    client.queue(Matter::Controller::ImClient::MSG_INVOKE_RESPONSE, response.to_slice, 11_u32)

    expect_raises(Matter::ProtocolError, /InvokeResponse.*path/) do
      Matter::Controller::ImClient.new(client).invoke(invoke_chunk_session,
        Socket::IPAddress.new("127.0.0.1", 5540), 1_u16,
        Matter::Cluster::OnOff::CLUSTER_ID, Matter::Cluster::OnOff::CMD_ON)
    end
  ensure
    client.try(&.close)
  end

  it "rejects an unrelated Success status in a later chunk" do
    require_udp_sockets!
    client = InvokeChunkClient.new
    client.queue(Matter::Controller::ImClient::MSG_INVOKE_RESPONSE,
      invoke_chunk(Matter::InteractionModel::StatusCode::Success, true), 11_u32)
    path = Matter::InteractionModel::CommandPath.new(endpoint: 2_u16,
      cluster: Matter::Cluster::OnOff::CLUSTER_ID,
      command: Matter::Cluster::OnOff::CMD_OFF)
    status = Matter::InteractionModel::CommandStatusIB.new(path,
      Matter::InteractionModel::StatusIB.new(Matter::InteractionModel::StatusCode::Success.value))
    response = Matter::InteractionModel::InvokeResponseMessage.new(invoke_responses: [
      Matter::InteractionModel::InvokeResponseIB.new(command_status: status),
    ])
    client.queue(Matter::Controller::ImClient::MSG_INVOKE_RESPONSE, response.to_slice, 12_u32)

    expect_raises(Matter::ProtocolError, /InvokeResponse.*path/) do
      Matter::Controller::ImClient.new(client).invoke(invoke_chunk_session,
        Socket::IPAddress.new("127.0.0.1", 5540), 1_u16,
        Matter::Cluster::OnOff::CLUSTER_ID, Matter::Cluster::OnOff::CMD_OFF)
    end
    client.sent.map(&.[0]).should eq([Matter::Controller::ImClient::MSG_INVOKE_REQUEST,
                                      Matter::Controller::ImClient::MSG_STATUS_RESPONSE])
  ensure
    client.try(&.close)
  end

  it "rejects a chunk from another session before sending continuation" do
    require_udp_sockets!
    client = InvokeChunkClient.new
    client.queue(0x09_u8, invoke_chunk(Matter::InteractionModel::StatusCode::Success, true),
      11_u32, session_id: 2_u16)

    expect_raises(Matter::ProtocolError, /arrived on session 2, expected 1/) do
      Matter::Controller::ImClient.new(client).invoke(invoke_chunk_session,
        Socket::IPAddress.new("127.0.0.1", 5540), 1_u16, 6_u32, 0_u32)
    end
    client.sent.map(&.[0]).should eq([0x08_u8])
  ensure
    client.try(&.close)
  end

  it "times out when the final InvokeResponse chunk does not arrive" do
    require_udp_sockets!
    client = InvokeChunkClient.new
    client.queue(0x09_u8, invoke_chunk(Matter::InteractionModel::StatusCode::Success, true), 11_u32)

    expect_raises(Matter::TimeoutError, /InvokeResponse/) do
      Matter::Controller::ImClient.new(client).invoke(invoke_chunk_session,
        Socket::IPAddress.new("127.0.0.1", 5540), 1_u16, 6_u32, 0_u32)
    end
    client.sent.map(&.[0]).should eq([0x08_u8, 0x01_u8])
  ensure
    client.try(&.close)
  end

  it "rejects a global IM status after a continuation" do
    require_udp_sockets!
    client = InvokeChunkClient.new
    client.queue(0x09_u8, invoke_chunk(Matter::InteractionModel::StatusCode::Success, true), 11_u32)
    client.queue(0x01_u8, Matter::InteractionModel::StatusResponseMessage.new(
      Matter::InteractionModel::StatusCode::InvalidAction.value).to_slice, 12_u32)

    expect_raises(Matter::ProtocolError, /InvalidAction|Invalid Action/) do
      Matter::Controller::ImClient.new(client).invoke(invoke_chunk_session,
        Socket::IPAddress.new("127.0.0.1", 5540), 1_u16, 6_u32, 0_u32)
    end
    client.sent.map(&.[0]).should eq([0x08_u8, 0x01_u8])
  ensure
    client.try(&.close)
  end

  it "bounds the number of InvokeResponse chunks" do
    require_udp_sockets!
    client = InvokeChunkClient.new
    (Matter::Controller::ImClient::MAX_INVOKE_RESPONSE_CHUNKS + 1).times do |index|
      client.queue(0x09_u8, invoke_chunk(Matter::InteractionModel::StatusCode::Success,
        index < Matter::Controller::ImClient::MAX_INVOKE_RESPONSE_CHUNKS), index.to_u32 + 1_u32)
    end

    expect_raises(Matter::ProtocolError, /chunk limit/) do
      Matter::Controller::ImClient.new(client).invoke(invoke_chunk_session,
        Socket::IPAddress.new("127.0.0.1", 5540), 1_u16, 6_u32, 0_u32)
    end
  ensure
    client.try(&.close)
  end

  it "bounds the total bytes received before parsing an oversized chunk" do
    require_udp_sockets!
    client = InvokeChunkClient.new
    oversized = Bytes.new(Matter::Controller::ImClient::MAX_INVOKE_RESPONSE_BYTES + 1)
    client.queue(0x09_u8, oversized, 11_u32)

    expect_raises(Matter::ProtocolError, /chunk limit/) do
      Matter::Controller::ImClient.new(client).invoke(invoke_chunk_session,
        Socket::IPAddress.new("127.0.0.1", 5540), 1_u16, 6_u32, 0_u32)
    end
    client.sent.map(&.[0]).should eq([0x08_u8])
  ensure
    client.try(&.close)
  end
end
