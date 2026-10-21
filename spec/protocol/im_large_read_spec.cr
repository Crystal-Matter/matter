require "../spec_helper"
require "../../src/matter/protocol/im_handler"

private def large_read_report(value : TLV::Any) : Matter::InteractionModel::AttributeReportIB
  path = Matter::InteractionModel::AttributePath.new(endpoint: 1_u16, cluster: 6_u32, attribute: 0_u32)
  data = Matter::InteractionModel::AttributeDataIB.new(path, value, 9_u32)
  Matter::InteractionModel::AttributeReportIB.new(attribute_data: data)
end

describe "large Read responses" do
  it "splits an oversized list attribute into ordered item reports" do
    values = Array.new(20) { |index| "#{index}:" + "A" * 100 }
    report = large_read_report(TLV::Any.from_slice(values.to_tlv))

    chunks = Matter::Protocol::IMHandler.encode_chunked_report_data([report])

    chunks.size.should be > 1
    chunks.each { |payload, _| payload.size.should be <= Matter::Protocol::IMHandler::MAX_REPORT_PAYLOAD_SIZE }
    data = chunks.flat_map do |payload, _|
      Matter::InteractionModel::ReportDataMessage.from_slice(payload).attribute_reports
        .as(Array(Matter::InteractionModel::AttributeReportIB)).compact_map(&.attribute_data)
    end
    data.first.path.list_index.should be_nil
    data.first.data.as_list.size.should be >= 1
    data[1..].each do |item|
      item.path.list_index_null?.should be_true
    end
    restored = data.first.data.as_list.map(&.value.as(String)) + data[1..].map(&.data.value.as(String))
    restored.should eq values
  end

  it "replaces an oversized scalar with ResourceExhausted status" do
    report = large_read_report(TLV::Any.new("A" * 1500, nil))

    chunks = Matter::Protocol::IMHandler.encode_chunked_report_data([report])

    chunks.size.should eq 1
    chunks.first[0].size.should be <= Matter::Protocol::IMHandler::MAX_REPORT_PAYLOAD_SIZE
    status = Matter::InteractionModel::ReportDataMessage.from_slice(chunks.first[0])
      .attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB)).first.attribute_status
    status.try(&.status.status).should eq Matter::InteractionModel::StatusCode::ResourceExhausted.value
  end

  it "returns ResourceExhausted for a list containing an indivisible large item" do
    report = large_read_report(TLV::Any.from_slice(["A" * 1500].to_tlv))

    chunks = Matter::Protocol::IMHandler.encode_chunked_report_data([report], 7_u32)

    chunks.size.should eq 1
    chunks.first[0].size.should be <= Matter::Protocol::IMHandler::MAX_REPORT_PAYLOAD_SIZE
    status = Matter::InteractionModel::ReportDataMessage.from_slice(chunks.first[0])
      .attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB)).first.attribute_status
    status.try(&.status.status).should eq Matter::InteractionModel::StatusCode::ResourceExhausted.value
  end

  it "does not split an oversized value at an existing list item path" do
    path = Matter::InteractionModel::AttributePath.new(endpoint: 1_u16, cluster: 6_u32,
      attribute: 0_u32, list_index_null: true)
    data = Matter::InteractionModel::AttributeDataIB.new(path,
      TLV::Any.from_slice(Array.new(20) { "A" * 100 }.to_tlv), 9_u32)
    report = Matter::InteractionModel::AttributeReportIB.new(attribute_data: data)

    chunks = Matter::Protocol::IMHandler.encode_chunked_report_data([report])

    chunks.size.should eq 1
    status = Matter::InteractionModel::ReportDataMessage.from_slice(chunks.first[0])
      .attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB)).first.attribute_status
    status.try(&.status.status).should eq Matter::InteractionModel::StatusCode::ResourceExhausted.value
  end

  it "replaces an oversized event payload with ResourceExhausted status" do
    path = Matter::InteractionModel::EventPath.new(endpoint: 1_u16, cluster: 6_u32, event: 0_u32)
    data = Matter::InteractionModel::EventDataIB.new(path, 1_u64,
      Matter::InteractionModel::EventPriority::Info, TLV::Any.new("A" * 1500, nil))
    event = Matter::InteractionModel::EventReportIB.new(event_data: data)

    chunks = Matter::Protocol::IMHandler.encode_chunked_report_data(
      [] of Matter::InteractionModel::AttributeReportIB, nil, [event])

    chunks.size.should eq 1
    chunks.first[0].size.should be <= Matter::Protocol::IMHandler::MAX_REPORT_PAYLOAD_SIZE
    status = Matter::InteractionModel::ReportDataMessage.from_slice(chunks.first[0])
      .event_reports.as(Array(Matter::InteractionModel::EventReportIB)).first.event_status
    status.try(&.status.status).should eq Matter::InteractionModel::StatusCode::ResourceExhausted.value
  end
end
