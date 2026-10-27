require "../spec_helper"
require "../../src/matter/cluster/diagnostic_logs"

describe Matter::Cluster::DiagnosticLogs do
  it "reports Exhausted when a BDX request fits completely in LogContent" do
    cluster = Matter::Cluster::DiagnosticLogs.new(Matter::DataType::EndpointNumber.new(0_u16))
    cluster.log("one diagnostic event")

    response = cluster.retrieve_logs_request(
      Matter::Cluster::DiagnosticLogs::RetrieveLogsRequest.new(
        Matter::Cluster::DiagnosticLogs::Intent::EndUserSupport,
        Matter::Cluster::DiagnosticLogs::TransferProtocol::BDX,
        "diagnostic-log-1")).as(Matter::Cluster::DiagnosticLogs::RetrieveLogsResponse)

    response.status.should eq(Matter::Cluster::DiagnosticLogs::LogsStatus::Exhausted)
    String.new(response.log_content).should contain("one diagnostic event")
  end

  it "keeps ResponsePayload logs inline" do
    cluster = Matter::Cluster::DiagnosticLogs.new(Matter::DataType::EndpointNumber.new(0_u16))
    cluster.log("inline diagnostic event")

    response = cluster.retrieve_logs_request(
      Matter::Cluster::DiagnosticLogs::RetrieveLogsRequest.new(
        Matter::Cluster::DiagnosticLogs::Intent::EndUserSupport,
        Matter::Cluster::DiagnosticLogs::TransferProtocol::ResponsePayload))
      .as(Matter::Cluster::DiagnosticLogs::RetrieveLogsResponse)

    response.status.should eq(Matter::Cluster::DiagnosticLogs::LogsStatus::Success)
    String.new(response.log_content).should contain("inline diagnostic event")
  end

  it "queues a large BDX transfer with the authenticated peer and returns empty LogContent" do
    cluster = Matter::Cluster::DiagnosticLogs.new(Matter::DataType::EndpointNumber.new(0_u16))
    expected_designator = "D" * Matter::Cluster::DiagnosticLogs::MAX_FILE_DESIGNATOR_BYTES
    cluster.log("A" * 1100)
    cluster.request_session_id = 12_u64
    cluster.request_fabric_index = 2_u8
    cluster.request_peer_node_id = 53_u64
    cluster.request_peer_address = Socket::IPAddress.new("127.0.0.1", 5540)
    cluster.request_is_case_session = true
    queued = false
    cluster.on_bdx_transfer = ->(session : UInt16, fabric : UInt8, node : UInt64, peer : Socket::IPAddress, designator : Bytes, content : Bytes) do
      session.should eq(12_u16)
      fabric.should eq(2_u8)
      node.should eq(53_u64)
      peer.should eq(Socket::IPAddress.new("127.0.0.1", 5540))
      String.new(designator).should eq(expected_designator)
      String.new(content).should contain("A" * 1100)
      queued = true
      true
    end

    response = cluster.retrieve_logs_request(
      Matter::Cluster::DiagnosticLogs::RetrieveLogsRequest.new(
        Matter::Cluster::DiagnosticLogs::Intent::EndUserSupport,
        Matter::Cluster::DiagnosticLogs::TransferProtocol::BDX,
        expected_designator)).as(Matter::Cluster::DiagnosticLogs::RetrieveLogsResponse)
    queued.should be_true
    response.status.should eq(Matter::Cluster::DiagnosticLogs::LogsStatus::Success)
    response.log_content.should be_empty
  end

  it "returns InvalidCommand for an absent BDX file designator before reading logs" do
    cluster = Matter::Cluster::DiagnosticLogs.new(Matter::DataType::EndpointNumber.new(0_u16))
    result = invoke(cluster, Matter::Cluster::DiagnosticLogs::CMD_RETRIEVE_LOGS_REQUEST,
      Matter::Cluster::DiagnosticLogs::RetrieveLogsRequest.new(
        Matter::Cluster::DiagnosticLogs::Intent::EndUserSupport,
        Matter::Cluster::DiagnosticLogs::TransferProtocol::BDX))
    expect_status(result, Matter::InteractionModel::StatusCode::InvalidCommand)
  end

  it "rejects BDX file designators longer than 32 UTF-8 bytes" do
    cluster = Matter::Cluster::DiagnosticLogs.new(Matter::DataType::EndpointNumber.new(0_u16))
    cluster.log("one diagnostic event")
    result = invoke(cluster, Matter::Cluster::DiagnosticLogs::CMD_RETRIEVE_LOGS_REQUEST,
      Matter::Cluster::DiagnosticLogs::RetrieveLogsRequest.new(
        Matter::Cluster::DiagnosticLogs::Intent::EndUserSupport,
        Matter::Cluster::DiagnosticLogs::TransferProtocol::BDX,
        "é" * 17))
    expect_status(result, Matter::InteractionModel::StatusCode::ConstraintError)
  end

  it "applies the designator length constraint to ResponsePayload requests too" do
    cluster = Matter::Cluster::DiagnosticLogs.new(Matter::DataType::EndpointNumber.new(0_u16))
    result = invoke(cluster, Matter::Cluster::DiagnosticLogs::CMD_RETRIEVE_LOGS_REQUEST,
      Matter::Cluster::DiagnosticLogs::RetrieveLogsRequest.new(
        Matter::Cluster::DiagnosticLogs::Intent::EndUserSupport,
        Matter::Cluster::DiagnosticLogs::TransferProtocol::ResponsePayload,
        "D" * (Matter::Cluster::DiagnosticLogs::MAX_FILE_DESIGNATOR_BYTES + 1)))
    expect_status(result, Matter::InteractionModel::StatusCode::ConstraintError)
  end

  it "bounds ResponsePayload LogContent to its inline budget" do
    cluster = Matter::Cluster::DiagnosticLogs.new(Matter::DataType::EndpointNumber.new(0_u16))
    cluster.log("R" * 1100)
    response = cluster.retrieve_logs_request(
      Matter::Cluster::DiagnosticLogs::RetrieveLogsRequest.new(
        Matter::Cluster::DiagnosticLogs::Intent::EndUserSupport,
        Matter::Cluster::DiagnosticLogs::TransferProtocol::ResponsePayload))
      .as(Matter::Cluster::DiagnosticLogs::RetrieveLogsResponse)
    response.status.should eq(Matter::Cluster::DiagnosticLogs::LogsStatus::Success)
    response.log_content.size.should eq(Matter::Cluster::DiagnosticLogs::MAX_INLINE_LOG_BYTES)
  end

  it "bounds a BDX fallback and reports Exhausted when no sender is installed" do
    cluster = Matter::Cluster::DiagnosticLogs.new(Matter::DataType::EndpointNumber.new(0_u16))
    cluster.log("C" * 1100)
    response = cluster.retrieve_logs_request(
      Matter::Cluster::DiagnosticLogs::RetrieveLogsRequest.new(
        Matter::Cluster::DiagnosticLogs::Intent::EndUserSupport,
        Matter::Cluster::DiagnosticLogs::TransferProtocol::BDX,
        "fallback-log"))
      .as(Matter::Cluster::DiagnosticLogs::RetrieveLogsResponse)
    response.status.should eq(Matter::Cluster::DiagnosticLogs::LogsStatus::Exhausted)
    response.log_content.size.should eq(Matter::Cluster::DiagnosticLogs::MAX_INLINE_LOG_BYTES)
  end

  it "falls back to bounded inline logs when the BDX sender cannot queue" do
    cluster = Matter::Cluster::DiagnosticLogs.new(Matter::DataType::EndpointNumber.new(0_u16))
    cluster.log("Q" * 1100)
    cluster.request_session_id = 12_u64
    cluster.request_fabric_index = 2_u8
    cluster.request_peer_node_id = 53_u64
    cluster.request_peer_address = Socket::IPAddress.new("127.0.0.1", 5540)
    cluster.request_is_case_session = true
    cluster.on_bdx_transfer = ->(_session : UInt16, _fabric : UInt8, _node : UInt64, _peer : Socket::IPAddress, _designator : Bytes, _content : Bytes) { false }

    response = cluster.retrieve_logs_request(
      Matter::Cluster::DiagnosticLogs::RetrieveLogsRequest.new(
        Matter::Cluster::DiagnosticLogs::Intent::EndUserSupport,
        Matter::Cluster::DiagnosticLogs::TransferProtocol::BDX,
        "fallback-log"))
      .as(Matter::Cluster::DiagnosticLogs::RetrieveLogsResponse)
    response.status.should eq(Matter::Cluster::DiagnosticLogs::LogsStatus::Exhausted)
    response.log_content.size.should eq(Matter::Cluster::DiagnosticLogs::MAX_INLINE_LOG_BYTES)
  end
end
