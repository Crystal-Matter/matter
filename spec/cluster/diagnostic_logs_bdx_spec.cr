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
        "diagnostic-log-1"))

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

    response.status.should eq(Matter::Cluster::DiagnosticLogs::LogsStatus::Success)
    String.new(response.log_content).should contain("inline diagnostic event")
  end

  it "queues a large BDX transfer with the authenticated peer and returns empty LogContent" do
    cluster = Matter::Cluster::DiagnosticLogs.new(Matter::DataType::EndpointNumber.new(0_u16))
    cluster.log("A" * 800)
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
      String.new(designator).should eq("diagnostic-log-2")
      String.new(content).should contain("A" * 800)
      queued = true
      true
    end

    response = cluster.retrieve_logs_request(
      Matter::Cluster::DiagnosticLogs::RetrieveLogsRequest.new(
        Matter::Cluster::DiagnosticLogs::Intent::EndUserSupport,
        Matter::Cluster::DiagnosticLogs::TransferProtocol::BDX,
        "diagnostic-log-2"))
    queued.should be_true
    response.status.should eq(Matter::Cluster::DiagnosticLogs::LogsStatus::Success)
    response.log_content.should be_empty
  end

  it "rejects a BDX request with no transfer file designator" do
    cluster = Matter::Cluster::DiagnosticLogs.new(Matter::DataType::EndpointNumber.new(0_u16))
    cluster.log("one diagnostic event")
    response = cluster.retrieve_logs_request(
      Matter::Cluster::DiagnosticLogs::RetrieveLogsRequest.new(
        Matter::Cluster::DiagnosticLogs::Intent::EndUserSupport,
        Matter::Cluster::DiagnosticLogs::TransferProtocol::BDX))
    response.status.should eq(Matter::Cluster::DiagnosticLogs::LogsStatus::Denied)
  end

  it "falls back to ResponsePayload when no BDX sender is installed" do
    cluster = Matter::Cluster::DiagnosticLogs.new(Matter::DataType::EndpointNumber.new(0_u16))
    cluster.log("C" * 800)
    response = cluster.retrieve_logs_request(
      Matter::Cluster::DiagnosticLogs::RetrieveLogsRequest.new(
        Matter::Cluster::DiagnosticLogs::Intent::EndUserSupport,
        Matter::Cluster::DiagnosticLogs::TransferProtocol::BDX,
        "fallback-log"))
    response.status.should eq(Matter::Cluster::DiagnosticLogs::LogsStatus::Success)
    String.new(response.log_content).should contain("C" * 800)
  end
end
