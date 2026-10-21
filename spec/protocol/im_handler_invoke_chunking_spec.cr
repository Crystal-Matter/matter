require "../spec_helper"
require "../../src/matter/protocol/im_handler"

describe Matter::Protocol::IMHandler do
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
end
