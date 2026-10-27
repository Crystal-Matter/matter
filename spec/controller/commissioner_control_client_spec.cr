require "../spec_helper"
require "../../src/matter/controller/commissioner_control_client"

private alias Control = Matter::Cluster::CommissionerControl
private alias IM = Matter::InteractionModel

private class CommissionerControlFakeIm < Matter::Controller::ImClient
  getter calls = [] of String
  getter response_timeouts = [] of Time::Span?
  property invoke_response : IM::InvokeResponseMessage?
  property event_response : IM::ReportDataMessage?

  def initialize
    super(Matter::Controller::Client.new)
  end

  def close : Nil
    @client.close
  end

  def invoke(session : Matter::Session::SecureContext, peer : Socket::IPAddress,
             endpoint_id : UInt16, cluster_id : UInt32, command_id : UInt32,
             fields : Bytes = Bytes.empty, timed_request : Bool = false,
             timed_request_timeout : Time::Span = DEFAULT_TIMED_REQUEST_TIMEOUT,
             response_timeout : Time::Span? = nil) : IM::InvokeResponseMessage
    @calls << "invoke #{command_id}"
    @response_timeouts << response_timeout
    @invoke_response || raise Matter::ProtocolError.new("No fake InvokeResponse")
  end

  def read_events(session : Matter::Session::SecureContext, peer : Socket::IPAddress,
                  paths : Array(IM::EventPath), event_min : UInt64? = nil,
                  fabric_filtered : Bool = true) : IM::ReportDataMessage
    @calls << "read events"
    @event_response || raise Matter::ProtocolError.new("No fake event report")
  end
end

private class CommissionerControlTimeoutClient < Matter::Controller::Client
  getter wait_timeouts = [] of Time::Span

  def send_encrypted_request(session : Matter::Session::SecureContext,
                             peer : Socket::IPAddress, protocol_id : UInt16,
                             message_type : UInt8, payload : Bytes | Slice(UInt8),
                             exchange_id : UInt16 = next_exchange_id,
                             initiator_message : Bool = true,
                             requires_ack : Bool = true,
                             acknowledged_message_id : UInt32? = nil) : UInt16
    exchange_id
  end

  def wait_for_any(exchange_id : UInt16, protocol_id : UInt16,
                   message_types : Array(UInt8), timeout : Time::Span) : ReceivedMessage?
    @wait_timeouts << timeout
    nil
  end
end

private def control_session : Matter::Session::SecureContext
  Matter::Session::SecureContext.new(session_id: 1_u16, peer_session_id: 2_u16,
    session_type: Matter::Session::SessionType::Unicast,
    encryption_key: Bytes.new(16), decryption_key: Bytes.new(16),
    local_node_id: Matter::DataType::NodeId.new(42_u64), fabric_index: 1_u8,
    case_session: true)
end

private def control_status(command : UInt32, status : IM::StatusCode = IM::StatusCode::Success) : IM::InvokeResponseMessage
  path = IM::CommandPath.new(1_u16, Control::CLUSTER_ID, command)
  result = IM::CommandStatusIB.new(path, IM::StatusIB.new(status.value))
  IM::InvokeResponseMessage.new(invoke_responses: [IM::InvokeResponseIB.new(command_status: result)])
end

private def control_result(request_id : UInt64, client_node_id : UInt64,
                           fabric_index : UInt8, status : IM::StatusCode) : IM::EventReportIB
  path = IM::EventPath.new(endpoint: 1_u16, cluster: Control::CLUSTER_ID,
    event: Control::EVENT_COMMISSIONING_REQUEST_RESULT)
  result = Control::CommissioningRequestResultEvent.new(request_id, client_node_id, status, fabric_index)
  event = IM::EventDataIB.new(path, 1_u64, IM::EventPriority::Info, TLV::Any.from_slice(result.to_slice))
  IM::EventReportIB.new(event_data: event)
end

describe Matter::Controller::CommissionerControlClient do
  it "allows a per-call InvokeResponse deadline without changing the default" do
    transport = CommissionerControlTimeoutClient.new
    im = Matter::Controller::ImClient.new(transport)
    session = control_session
    peer = Socket::IPAddress.new("127.0.0.1", 5540)
    expect_raises(Matter::TimeoutError) do
      im.invoke(session, peer, 1_u16, Control::CLUSTER_ID, Control::CMD_COMMISSION_NODE,
        response_timeout: 60.seconds)
    end
    transport.wait_timeouts.last.should be > 59.seconds
    expect_raises(Matter::TimeoutError) do
      im.invoke(session, peer, 1_u16, Control::CLUSTER_ID, Control::CMD_COMMISSION_NODE)
    end
    transport.wait_timeouts.last.should be < 11.seconds
  ensure
    transport.try(&.close)
  end

  it "correlates an approval result with request ID, client NodeID, and fabric" do
    im = CommissionerControlFakeIm.new
    client = Matter::Controller::CommissionerControlClient.new(im)
    session = control_session
    peer = Socket::IPAddress.new("127.0.0.1", 5540)
    im.invoke_response = control_status(Control::CMD_REQUEST_COMMISSIONING_APPROVAL)
    request = Control::RequestCommissioningApprovalRequest.new(99_u64, 0xFFF1_u16, 0x8001_u16)
    client.request_approval(session, peer, 1_u16, request)
    im.event_response = IM::ReportDataMessage.new(event_reports: [
      control_result(98_u64, 42_u64, 1_u8, IM::StatusCode::Success),
      control_result(99_u64, 43_u64, 1_u8, IM::StatusCode::Success),
      control_result(99_u64, 42_u64, 2_u8, IM::StatusCode::Success),
      control_result(99_u64, 42_u64, 1_u8, IM::StatusCode::Success),
    ])
    client.approval_result(session, peer, 1_u16, request.request_id).should eq(IM::StatusCode::Success)
    im.calls.should eq(["invoke #{Control::CMD_REQUEST_COMMISSIONING_APPROVAL}", "read events"])
  ensure
    im.try(&.close)
  end

  it "does not accept an unrelated result or an approval failure" do
    im = CommissionerControlFakeIm.new
    client = Matter::Controller::CommissionerControlClient.new(im)
    session = control_session
    peer = Socket::IPAddress.new("127.0.0.1", 5540)
    im.event_response = IM::ReportDataMessage.new(event_reports: [
      control_result(99_u64, 43_u64, 1_u8, IM::StatusCode::Success),
    ])
    client.approval_result(session, peer, 1_u16, 99_u64).should be_nil
    im.event_response = IM::ReportDataMessage.new(event_reports: [
      control_result(99_u64, 42_u64, 1_u8, IM::StatusCode::Failure),
    ])
    client.approval_result(session, peer, 1_u16, 99_u64).should eq(IM::StatusCode::Failure)
  ensure
    im.try(&.close)
  end

  it "fails closed on a rejected approval, non-CASE identity, or invalid response timeout" do
    im = CommissionerControlFakeIm.new
    client = Matter::Controller::CommissionerControlClient.new(im)
    session = control_session
    peer = Socket::IPAddress.new("127.0.0.1", 5540)
    request = Control::RequestCommissioningApprovalRequest.new(99_u64, 0xFFF1_u16, 0x8001_u16)
    im.invoke_response = control_status(Control::CMD_REQUEST_COMMISSIONING_APPROVAL, IM::StatusCode::Failure)
    expect_raises(Matter::CommissioningError, /RequestCommissioningApproval failed/) do
      client.request_approval(session, peer, 1_u16, request)
    end
    expect_raises(Matter::ConfigurationError, /response timeout/) do
      client.commission_node(session, peer, 1_u16,
        Control::CommissionNodeRequest.new(99_u64, Control::MIN_RESPONSE_TIMEOUT - 1_u16))
    end
    session.case_session = false
    expect_raises(Matter::ConfigurationError, /CASE session/) do
      client.request_approval(session, peer, 1_u16, request)
    end
  ensure
    im.try(&.close)
  end

  it "uses ResponseTimeoutSeconds for CommissionNode and checks the typed response path" do
    im = CommissionerControlFakeIm.new
    client = Matter::Controller::CommissionerControlClient.new(im)
    session = control_session
    peer = Socket::IPAddress.new("127.0.0.1", 5540)
    window = Control::ReverseOpenCommissioningWindowResponse.new(
      180_u16, Bytes.new(97), 3840_u16, 1000_u32, Bytes.new(16))
    path = IM::CommandPath.new(1_u16, Control::CLUSTER_ID, Control::CMD_COMMISSION_NODE_RESPONSE)
    data = IM::CommandDataIBTlv.new(path, TLV::Any.from_slice(window.to_slice))
    im.invoke_response = IM::InvokeResponseMessage.new(invoke_responses: [IM::InvokeResponseIB.new(command_data: data)])
    client.commission_node(session, peer, 1_u16, Control::CommissionNodeRequest.new(99_u64, 60_u16))
      .discriminator.should eq(3840_u16)
    im.response_timeouts.should eq([60.seconds])

    wrong = IM::CommandPath.new(1_u16, Control::CLUSTER_ID, Control::CMD_COMMISSION_NODE)
    im.invoke_response = IM::InvokeResponseMessage.new(invoke_responses: [
      IM::InvokeResponseIB.new(command_data: IM::CommandDataIBTlv.new(wrong, TLV::Any.from_slice(window.to_slice))),
    ])
    expect_raises(Matter::ProtocolError, /unexpected response path/) do
      client.commission_node(session, peer, 1_u16, Control::CommissionNodeRequest.new(99_u64))
    end
  ensure
    im.try(&.close)
  end

  it "rejects a well-typed reverse window with invalid PAKE parameters" do
    im = CommissionerControlFakeIm.new
    client = Matter::Controller::CommissionerControlClient.new(im)
    session = control_session
    peer = Socket::IPAddress.new("127.0.0.1", 5540)
    invalid = Control::ReverseOpenCommissioningWindowResponse.new(
      180_u16, Bytes.new(96), 3840_u16, 1000_u32, Bytes.new(16))
    path = IM::CommandPath.new(1_u16, Control::CLUSTER_ID, Control::CMD_COMMISSION_NODE_RESPONSE)
    data = IM::CommandDataIBTlv.new(path, TLV::Any.from_slice(invalid.to_slice))
    im.invoke_response = IM::InvokeResponseMessage.new(invoke_responses: [IM::InvokeResponseIB.new(command_data: data)])
    expect_raises(Matter::ProtocolError, /invalid reverse window/) do
      client.commission_node(session, peer, 1_u16, Control::CommissionNodeRequest.new(99_u64))
    end
  ensure
    im.try(&.close)
  end
end
