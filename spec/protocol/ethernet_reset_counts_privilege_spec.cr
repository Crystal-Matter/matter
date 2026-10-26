require "../spec_helper"
require "../../src/matter/cluster/access_control"
require "../../src/matter/cluster/ethernet_network_diagnostics"
require "../../src/matter/protocol/im_handler"

private alias EthernetDiagnostics = Matter::Cluster::EthernetNetworkDiagnostics
private alias EthernetAcl = Matter::Cluster::AccessControl
private ETHERNET_SUBJECT = 0x1234_u64

private def invoke_ethernet_reset(
  cluster : EthernetDiagnostics,
  privilege : EthernetAcl::AccessControlEntryPrivilege,
) : UInt8
  acl = EthernetAcl.new(endpoint(0))
  acl.acl << EthernetAcl::AccessControlEntry.new(privilege,
    EthernetAcl::AccessControlEntryAuthMode::CASE, [ETHERNET_SUBJECT], nil, 1_u8)
  clusters = {
    {0_u16, EthernetAcl::CLUSTER_ID}         => acl.as(Matter::Cluster::Base),
    {1_u16, EthernetDiagnostics::CLUSTER_ID} => cluster.as(Matter::Cluster::Base),
  }
  path = Matter::InteractionModel::CommandPath.new(1_u16,
    EthernetDiagnostics::CLUSTER_ID, EthernetDiagnostics::CMD_RESET_COUNTS)
  request = Matter::InteractionModel::InvokeRequestMessage.new([
    Matter::InteractionModel::CommandDataIBTlv.new(path, nil),
  ])
  parsed = Matter::Protocol::IMHandler.parse_invoke_request(request.to_slice)
    .as(Matter::InteractionModel::InvokeRequestMessage)
  Matter::Protocol::IMHandler.invoke_commands(parsed.invoke_requests, clusters,
    is_case_session: true, fabric_index: 1_u8, peer_subject_ids: [ETHERNET_SUBJECT])
    .first.command_status.as(Matter::InteractionModel::CommandStatusIB).status.status
end

describe "Matter 1.6 Ethernet Network Diagnostics ResetCounts privilege" do
  it "requires Manage before resetting counters on a CASE fabric" do
    cluster = EthernetDiagnostics.new(endpoint(1))
    cluster.record_rx_packet
    cluster.packet_rx_count.should eq(1_u64)

    invoke_ethernet_reset(cluster, EthernetAcl::AccessControlEntryPrivilege::Operate)
      .should eq(Matter::InteractionModel::StatusCode::UnsupportedAccess.value)
    cluster.packet_rx_count.should eq(1_u64)

    invoke_ethernet_reset(cluster, EthernetAcl::AccessControlEntryPrivilege::Manage)
      .should eq(Matter::InteractionModel::StatusCode::Success.value)
    cluster.packet_rx_count.should eq(0_u64)
  end
end
