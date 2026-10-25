require "../spec_helper"
require "../../src/matter/controller"

private class ChunkedReadClient < Matter::Controller::Client
  getter sent = [] of Tuple(UInt16, UInt8, Bytes, UInt16?, UInt32?)
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
    @sent << {protocol_id, message_type, payload.to_slice, exchange_id, acknowledged_message_id}
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

  def queue(message_type : UInt8, payload : Bytes, exchange_id : UInt16 = 1_u16,
            message_id : UInt32 = 1_u32, session_id : UInt16 = 1_u16) : Nil
    packet = Matter::Codec::MessageCodec::PacketHeader.new(session_id,
      Matter::Codec::MessageCodec::SessionType::Unicast, message_id)
    header = Matter::Codec::MessageCodec::PayloadHeader.new(exchange_id,
      PROTOCOL_INTERACTION_MODEL, message_type, false, true)
    @replies << ReceivedMessage.new(
      Matter::Codec::MessageCodec::Message.new(packet, header, payload),
      Socket::IPAddress.new("127.0.0.1", 5540))
  end
end

private class ReportAckClient < Matter::Controller::Client
  getter capture : Matter::Spec::CaptureTransport

  def initialize
    super
    @transport.close
    @capture = Matter::Spec::CaptureTransport.new_for_spec
    @transport = @capture
  end

  def inject(message_type : UInt8, message_id : UInt32) : Nil
    packet = Matter::Codec::MessageCodec::PacketHeader.new(1_u16,
      Matter::Codec::MessageCodec::SessionType::Unicast, message_id)
    header = Matter::Codec::MessageCodec::PayloadHeader.new(1_u16,
      PROTOCOL_INTERACTION_MODEL, message_type, false, true)
    @inbox.send(ReceivedMessage.new(
      Matter::Codec::MessageCodec::Message.new(packet, header, Bytes.empty),
      Socket::IPAddress.new("127.0.0.1", 5540)))
  end
end

private def chunked_read_session : Matter::Session::SecureContext
  Matter::Session::SecureContext.new(
    session_id: 1_u16, peer_session_id: 1_u16,
    session_type: Matter::Session::SessionType::Unicast,
    encryption_key: Bytes.new(16), decryption_key: Bytes.new(16))
end

describe Matter::Controller::ImClient do
  it "reads event reports across chunks and sends an EventMin filter" do
    require_udp_sockets!
    client = ChunkedReadClient.new
    path = Matter::InteractionModel::EventPath.new(endpoint: 1_u16, cluster: 6_u32, event: 0_u32)
    [8_u64, 9_u64].each_with_index do |number, index|
      event = Matter::InteractionModel::EventDataIB.new(path, number,
        Matter::InteractionModel::EventPriority::Info)
      client.queue(0x05_u8, Matter::InteractionModel::ReportDataMessage.new(
        event_reports: [Matter::InteractionModel::EventReportIB.new(event_data: event)],
        more_chunked_messages: index == 0).to_slice, message_id: number.to_u32)
    end

    report = Matter::Controller::ImClient.new(client).read_events(chunked_read_session,
      Socket::IPAddress.new("127.0.0.1", 5540), [path], event_min: 8_u64)
    report.event_reports.try(&.compact_map(&.event_data).map(&.event_number)).should eq([8_u64, 9_u64])
    request = Matter::InteractionModel::ReadRequestMessage.from_slice(client.sent.first[2])
    request.event_requests.should eq([path])
    request.event_filters.try(&.first.event_min).should eq(8_u64)
    client.sent.map(&.[1]).should eq([0x02_u8, 0x01_u8, 0x01_u8])
  ensure
    client.try(&.close)
  end

  it "leaves ReportData for the IM acknowledgement ladder without an early MRP ACK" do
    require_udp_sockets!
    client = ReportAckClient.new
    client.register_session(chunked_read_session)
    client.inject(0x05_u8, 10_u32)
    client.wait_for(1_u16, Matter::Controller::Client::PROTOCOL_INTERACTION_MODEL,
      0x05_u8, 1.second).should_not be_nil
    client.capture.sent_packets.should be_empty

    client.inject(0x07_u8, 11_u32)
    client.wait_for(1_u16, Matter::Controller::Client::PROTOCOL_INTERACTION_MODEL,
      0x07_u8, 1.second).should_not be_nil
    client.capture.sent_packets.size.should eq(1)
  ensure
    client.try(&.close)
  end

  it "acknowledges and accumulates a chunked Read response" do
    require_udp_sockets!
    client = ChunkedReadClient.new
    client.queue(0x05_u8, Matter::InteractionModel::ReportDataMessage.new(
      attribute_reports: [Matter::InteractionModel::AttributeReportIB.new(
        attribute_data: Matter::InteractionModel::AttributeDataIB.new(
          Matter::InteractionModel::AttributePath.new(endpoint: 1_u16, cluster: 6_u32, attribute: 0_u32),
          TLV::Any.from_slice(1_u8.to_tlv)))], more_chunked_messages: true).to_slice,
      message_id: 11_u32)
    client.queue(0x05_u8, Matter::InteractionModel::ReportDataMessage.new(
      attribute_reports: [Matter::InteractionModel::AttributeReportIB.new(
        attribute_status: Matter::InteractionModel::AttributeStatusIB.new(
          Matter::InteractionModel::AttributePath.new(endpoint: 1_u16, cluster: 6_u32, attribute: 0_u32),
          Matter::InteractionModel::StatusIB.new(Matter::InteractionModel::StatusCode::UnsupportedAttribute.value)))],
      more_chunked_messages: false).to_slice, message_id: 12_u32)

    report = Matter::Controller::ImClient.new(client).read_attribute(chunked_read_session,
      Socket::IPAddress.new("127.0.0.1", 5540), 1_u16, 6_u32, 0_u32)
    report.attribute_reports.try(&.size).should eq(2)
    client.sent.map(&.[1]).should eq([0x02_u8, 0x01_u8, 0x01_u8])
    client.sent[1][4].should eq(11_u32)
    client.sent[2][4].should eq(12_u32)
  ensure
    client.try(&.close)
  end

  it "rejects an unrelated concrete path in a single-attribute read response" do
    require_udp_sockets!
    client = ChunkedReadClient.new
    wrong_path = Matter::InteractionModel::AttributePath.new(endpoint: 1_u16,
      cluster: 6_u32, attribute: 1_u32)
    client.queue(0x05_u8, Matter::InteractionModel::ReportDataMessage.new(
      attribute_reports: [Matter::InteractionModel::AttributeReportIB.new(
        attribute_data: Matter::InteractionModel::AttributeDataIB.new(wrong_path,
          TLV::Any.from_slice(1_u8.to_tlv)))],
      suppress_response: true).to_slice)

    expect_raises(Matter::ProtocolError, /Read response path/) do
      Matter::Controller::ImClient.new(client).read_attribute(chunked_read_session,
        Socket::IPAddress.new("127.0.0.1", 5540), 1_u16, 6_u32, 0_u32)
    end
  ensure
    client.try(&.close)
  end

  it "rejects a mixed read response containing an unrelated status path" do
    require_udp_sockets!
    client = ChunkedReadClient.new
    requested_path = Matter::InteractionModel::AttributePath.new(endpoint: 1_u16,
      cluster: 6_u32, attribute: 0_u32)
    wrong_path = Matter::InteractionModel::AttributePath.new(endpoint: 2_u16,
      cluster: 6_u32, attribute: 0_u32)
    client.queue(0x05_u8, Matter::InteractionModel::ReportDataMessage.new(
      attribute_reports: [
        Matter::InteractionModel::AttributeReportIB.new(
          attribute_data: Matter::InteractionModel::AttributeDataIB.new(requested_path,
            TLV::Any.from_slice(1_u8.to_tlv))),
        Matter::InteractionModel::AttributeReportIB.new(
          attribute_status: Matter::InteractionModel::AttributeStatusIB.new(wrong_path,
            Matter::InteractionModel::StatusIB.new(Matter::InteractionModel::StatusCode::UnsupportedAttribute.value))),
      ], suppress_response: true).to_slice)

    expect_raises(Matter::ProtocolError, /Read response path/) do
      Matter::Controller::ImClient.new(client).read_attribute(chunked_read_session,
        Socket::IPAddress.new("127.0.0.1", 5540), 1_u16, 6_u32, 0_u32)
    end
  ensure
    client.try(&.close)
  end

  it "retains multiple attributes for a wildcard read" do
    require_udp_sockets!
    client = ChunkedReadClient.new
    [0_u32, 1_u32].each do |attribute|
      path = Matter::InteractionModel::AttributePath.new(endpoint: 1_u16,
        cluster: 6_u32, attribute: attribute)
      client.queue(0x05_u8, Matter::InteractionModel::ReportDataMessage.new(
        attribute_reports: [Matter::InteractionModel::AttributeReportIB.new(
          attribute_data: Matter::InteractionModel::AttributeDataIB.new(path,
            TLV::Any.from_slice(attribute.to_tlv)))],
        more_chunked_messages: attribute == 0_u32,
        suppress_response: attribute == 1_u32).to_slice)
    end

    wildcard = Matter::InteractionModel::AttributePath.new(endpoint: 1_u16,
      cluster: 6_u32)
    report = Matter::Controller::ImClient.new(client).read(chunked_read_session,
      Socket::IPAddress.new("127.0.0.1", 5540), attribute_paths: [wildcard])
    report.attribute_reports.try(&.size).should eq(2)
  ensure
    client.try(&.close)
  end

  it "reassembles a list attribute split across ReportData chunks" do
    require_udp_sockets!
    client = ChunkedReadClient.new
    path = Matter::InteractionModel::AttributePath.new(endpoint: 1_u16,
      cluster: 6_u32, attribute: 0_u32)
    item_path = Matter::InteractionModel::AttributePath.new(endpoint: 1_u16,
      cluster: 6_u32, attribute: 0_u32, list_index: 1_u16)
    final_item_path = Matter::InteractionModel::AttributePath.new(endpoint: 1_u16,
      cluster: 6_u32, attribute: 0_u32, list_index: 2_u16)
    client.queue(0x05_u8, Matter::InteractionModel::ReportDataMessage.new(
      attribute_reports: [Matter::InteractionModel::AttributeReportIB.new(
        attribute_data: Matter::InteractionModel::AttributeDataIB.new(path,
          TLV::Any.from_slice([1_u16].to_tlv), 9_u32))],
      more_chunked_messages: true).to_slice)
    client.queue(0x05_u8, Matter::InteractionModel::ReportDataMessage.new(
      attribute_reports: [Matter::InteractionModel::AttributeReportIB.new(
        attribute_data: Matter::InteractionModel::AttributeDataIB.new(item_path,
          TLV::Any.from_slice(2_u16.to_tlv)))],
      more_chunked_messages: true).to_slice)
    client.queue(0x05_u8, Matter::InteractionModel::ReportDataMessage.new(
      attribute_reports: [Matter::InteractionModel::AttributeReportIB.new(
        attribute_data: Matter::InteractionModel::AttributeDataIB.new(final_item_path,
          TLV::Any.from_slice(3_u16.to_tlv)))],
      more_chunked_messages: false).to_slice)

    report = Matter::Controller::ImClient.new(client).read_attribute(chunked_read_session,
      Socket::IPAddress.new("127.0.0.1", 5540), 1_u16, 6_u32, 0_u32)
    values = report.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
    values.size.should eq(1)
    values.first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data_version.should eq(9_u32)
    Array(UInt16).from_tlv(values.first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.to_slice)
      .should eq([1_u16, 2_u16, 3_u16])
  ensure
    client.try(&.close)
  end

  it "reassembles list item reports whose append index decodes as nil" do
    require_udp_sockets!
    client = ChunkedReadClient.new
    path = Matter::InteractionModel::AttributePath.new(endpoint: 1_u16,
      cluster: 6_u32, attribute: 0_u32)
    [1_u16, 2_u16].each_with_index do |value, index|
      client.queue(0x05_u8, Matter::InteractionModel::ReportDataMessage.new(
        attribute_reports: [Matter::InteractionModel::AttributeReportIB.new(
          attribute_data: Matter::InteractionModel::AttributeDataIB.new(path,
            TLV::Any.from_slice(value.to_tlv)))],
        more_chunked_messages: index == 0).to_slice)
    end

    report = Matter::Controller::ImClient.new(client).read_attribute(chunked_read_session,
      Socket::IPAddress.new("127.0.0.1", 5540), 1_u16, 6_u32, 0_u32)
    value = report.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data
    Array(UInt16).from_tlv(value.to_slice).should eq([1_u16, 2_u16])
  ensure
    client.try(&.close)
  end
  it "rejects a global IM status instead of parsing it as ReportData" do
    require_udp_sockets!
    client = ChunkedReadClient.new
    client.queue(0x01_u8, Matter::InteractionModel::StatusResponseMessage.new(
      Matter::InteractionModel::StatusCode::UnsupportedRead.value).to_slice)
    expect_raises(Matter::ProtocolError, /Unsupported Read/) do
      Matter::Controller::ImClient.new(client).read_attribute(chunked_read_session,
        Socket::IPAddress.new("127.0.0.1", 5540), 1_u16, 6_u32, 0_u32)
    end
    client.sent.map(&.[1]).should eq([0x02_u8])
  ensure
    client.try(&.close)
  end

  it "does not acknowledge a final report with SuppressResponse" do
    require_udp_sockets!
    client = ChunkedReadClient.new
    client.queue(0x05_u8, Matter::InteractionModel::ReportDataMessage.new(
      attribute_reports: [] of Matter::InteractionModel::AttributeReportIB,
      suppress_response: true).to_slice)
    Matter::Controller::ImClient.new(client).read_attribute(chunked_read_session,
      Socket::IPAddress.new("127.0.0.1", 5540), 1_u16, 6_u32, 0_u32)
    client.sent.map(&.[1]).should eq([0x02_u8])
  ensure
    client.try(&.close)
  end

  it "rejects a Read report from another secure session" do
    require_udp_sockets!
    client = ChunkedReadClient.new
    client.queue(0x05_u8, Matter::InteractionModel::ReportDataMessage.new.to_slice,
      session_id: 2_u16)
    expect_raises(Matter::ProtocolError, /another session/) do
      Matter::Controller::ImClient.new(client).read_attribute(chunked_read_session,
        Socket::IPAddress.new("127.0.0.1", 5540), 1_u16, 6_u32, 0_u32)
    end
  ensure
    client.try(&.close)
  end

  it "rejects a malformed ReportData without sending success" do
    require_udp_sockets!
    client = ChunkedReadClient.new
    client.queue(0x05_u8, Bytes[0_u8])
    expect_raises(Matter::ProtocolError, /invalid ReportData/) do
      Matter::Controller::ImClient.new(client).read_attribute(chunked_read_session,
        Socket::IPAddress.new("127.0.0.1", 5540), 1_u16, 6_u32, 0_u32)
    end
    client.sent.map(&.[1]).should eq([0x02_u8])
  ensure
    client.try(&.close)
  end

  it "bounds a server that keeps MoreChunkedMessages set" do
    require_udp_sockets!
    client = ChunkedReadClient.new
    report = Matter::InteractionModel::ReportDataMessage.new(more_chunked_messages: true).to_slice
    (Matter::Controller::ImClient::MAX_READ_REPORT_CHUNKS + 1).times do |index|
      client.queue(0x05_u8, report, message_id: index.to_u32)
    end
    expect_raises(Matter::ProtocolError, /chunk limit/) do
      Matter::Controller::ImClient.new(client).read_attribute(chunked_read_session,
        Socket::IPAddress.new("127.0.0.1", 5540), 1_u16, 6_u32, 0_u32)
    end
    client.sent.count { |entry| entry[1] == 0x01_u8 }.should eq(Matter::Controller::ImClient::MAX_READ_REPORT_CHUNKS)
  ensure
    client.try(&.close)
  end
end
