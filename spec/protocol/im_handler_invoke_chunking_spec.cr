require "../spec_helper"
require "../../src/matter/protocol/im_handler"

describe Matter::Protocol::IMHandler do
  it "keeps a four-kilobyte command response intact within a TCP invoke budget" do
    path = Matter::InteractionModel::CommandPath.new(0_u16, 0x0028_u32, 1_u32)
    data = Matter::InteractionModel::CommandDataIBTlv.new(path, TLV::Any.new("B" * 4096, nil))
    response = Matter::InteractionModel::InvokeResponseIB.new(command_data: data)

    chunks = Matter::Protocol::IMHandler.encode_chunked_invoke_response([response],
      max_payload_size: Matter::Protocol::IMHandler::MAX_TCP_REPORT_PAYLOAD_SIZE)

    chunks.size.should eq 1
    chunks.first.size.should be > Matter::Protocol::IMHandler::MAX_REPORT_PAYLOAD_SIZE
    chunks.first.size.should be <= Matter::Protocol::IMHandler::MAX_TCP_REPORT_PAYLOAD_SIZE
    decoded = Matter::InteractionModel::InvokeResponseMessage.from_slice(chunks.first)
    decoded.invoke_responses.first.command_data.try(&.command_fields.try(&.value.as(String))).should eq("B" * 4096)
  end

  it "encodes large invoke response arrays as acknowledged chunks within the IPv6 payload budget" do
    responses = Array.new(30) do |index|
      path = Matter::InteractionModel::CommandPath.new(0_u16, 0x0028_u32, index.to_u32)
      fields = TLV::Any.new("A" * 80, nil)
      data = Matter::InteractionModel::CommandDataIBTlv.new(path, fields)
      Matter::InteractionModel::InvokeResponseIB.new(command_data: data)
    end

    chunks = Matter::Protocol::IMHandler.encode_chunked_invoke_response(responses)

    chunks.size.should be > 1
    decoded = chunks.map do |payload|
      payload.size.should be <= Matter::Protocol::IMHandler::MAX_REPORT_PAYLOAD_SIZE
      Matter::InteractionModel::InvokeResponseMessage.from_slice(payload)
    end
    decoded[0...-1].each(&.more_chunked_messages.should(be_true))
    decoded.last.more_chunked_messages.should_not be_true
    commands = decoded.flat_map(&.invoke_responses).compact_map(&.command_data).map(&.command_path.command)
    commands.should eq((0...30).map(&.to_u32))
  end

  it "returns ResourceExhausted for one command response that cannot fit a message" do
    path = Matter::InteractionModel::CommandPath.new(0_u16, 0x0028_u32, 1_u32)
    data = Matter::InteractionModel::CommandDataIBTlv.new(path, TLV::Any.new("B" * 1300, nil))
    response = Matter::InteractionModel::InvokeResponseIB.new(command_data: data)

    chunks = Matter::Protocol::IMHandler.encode_chunked_invoke_response([response])

    chunks.size.should eq 1
    chunks.first.size.should be <= Matter::Protocol::IMHandler::MAX_REPORT_PAYLOAD_SIZE
    status = Matter::InteractionModel::InvokeResponseMessage.from_slice(chunks.first)
      .invoke_responses.first.command_status
    status.should_not be_nil
    status.try(&.status.status).should eq Matter::InteractionModel::StatusCode::ResourceExhausted.value
  end

  it "uses the invoked command path when an oversized response uses a different command ID" do
    request_path = Matter::InteractionModel::CommandPath.new(0_u16,
      Matter::Cluster::GeneralCommissioning::CLUSTER_ID,
      Matter::Cluster::GeneralCommissioning::CMD_ARM_FAIL_SAFE)
    response_path = Matter::InteractionModel::CommandPath.new(0_u16,
      Matter::Cluster::GeneralCommissioning::CLUSTER_ID,
      Matter::Cluster::GeneralCommissioning::CMD_ARM_FAIL_SAFE_RESPONSE)
    data = Matter::InteractionModel::CommandDataIBTlv.new(response_path, TLV::Any.new("B" * 1300, nil))
    response = Matter::InteractionModel::InvokeResponseIB.new(command_data: data)

    chunks = Matter::Protocol::IMHandler.encode_chunked_invoke_response([response],
      request_paths: [request_path])

    status = Matter::InteractionModel::InvokeResponseMessage.from_slice(chunks.first)
      .invoke_responses.first.command_status
    status.try(&.command_path).should eq request_path
    status.try(&.status.status).should eq Matter::InteractionModel::StatusCode::ResourceExhausted.value
  end
end
