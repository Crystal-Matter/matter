require "../spec_helper"
require "../../src/matter/controller/im_client"
require "../../src/matter/protocol/im_handler"

private class ChunkedInvokeClient < Matter::Controller::Client
  getter sent_types = [] of UInt8
  property response_chunks = [] of Bytes

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
    @sent_types << message_type
    if message_type == Matter::Controller::ImClient::MSG_INVOKE_REQUEST
      @response_chunks.each_with_index do |chunk, index|
        packet = Matter::Codec::MessageCodec::PacketHeader.new(session.session_id,
          Matter::Codec::MessageCodec::SessionType::Unicast, index.to_u32)
        header = Matter::Codec::MessageCodec::PayloadHeader.new(exchange_id,
          PROTOCOL_INTERACTION_MODEL, Matter::Controller::ImClient::MSG_INVOKE_RESPONSE,
          false, false)
        @inbox.send(ReceivedMessage.new(
          Matter::Codec::MessageCodec::Message.new(packet, header, chunk), peer))
      end
    end
    exchange_id
  end
end

describe Matter::Controller::ImClient do
  it "accepts ResourceExhausted for an oversized response with a distinct response command ID" do
    require_udp_sockets!
    client = ChunkedInvokeClient.new
    session = Matter::Spec::ProtocolMessages.case_session(1_u16)
    peer = Socket::IPAddress.new("127.0.0.1", 5540)
    request_path = Matter::InteractionModel::CommandPath.new(0_u16,
      Matter::Cluster::GeneralCommissioning::CLUSTER_ID,
      Matter::Cluster::GeneralCommissioning::CMD_ARM_FAIL_SAFE)
    response_path = Matter::InteractionModel::CommandPath.new(0_u16,
      Matter::Cluster::GeneralCommissioning::CLUSTER_ID,
      Matter::Cluster::GeneralCommissioning::CMD_ARM_FAIL_SAFE_RESPONSE)
    data = Matter::InteractionModel::CommandDataIBTlv.new(response_path, TLV::Any.new("B" * 1300, nil))
    client.response_chunks = Matter::Protocol::IMHandler.encode_chunked_invoke_response([
      Matter::InteractionModel::InvokeResponseIB.new(command_data: data),
    ], request_paths: [request_path])

    result = Matter::Controller::ImClient.new(client).invoke(session, peer, 0_u16,
      Matter::Cluster::GeneralCommissioning::CLUSTER_ID,
      Matter::Cluster::GeneralCommissioning::CMD_ARM_FAIL_SAFE)

    status = result.invoke_responses.first.command_status
    status.try(&.command_path).should eq request_path
    status.try(&.status.status).should eq Matter::InteractionModel::StatusCode::ResourceExhausted.value
  ensure
    client.try(&.close)
  end

  it "acknowledges and combines chunked InvokeResponse messages" do
    require_udp_sockets!
    client = ChunkedInvokeClient.new
    session = Matter::Spec::ProtocolMessages.case_session(1_u16)
    peer = Socket::IPAddress.new("127.0.0.1", 5540)
    responses = Array.new(20) do |index|
      path = Matter::InteractionModel::CommandPath.new(0_u16, 0x0028_u32, index.to_u32)
      data = Matter::InteractionModel::CommandDataIBTlv.new(path, TLV::Any.new("A" * 80, nil))
      Matter::InteractionModel::InvokeResponseIB.new(command_data: data)
    end
    client.response_chunks = Matter::Protocol::IMHandler.encode_chunked_invoke_response(responses)

    result = Matter::Controller::ImClient.new(client).invoke(session, peer, 0_u16, 0x0028_u32, 1_u32)

    result.invoke_responses.size.should eq 20
    result.invoke_responses.compact_map(&.command_data).map(&.command_path.command)
      .should eq((0...20).map(&.to_u32))
    client.sent_types.count(Matter::Controller::ImClient::MSG_STATUS_RESPONSE)
      .should eq(client.response_chunks.size - 1)
  ensure
    client.try(&.close)
  end
end
