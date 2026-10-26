require "../spec_helper"
require "../../src/matter/cluster/on_off"
require "../../src/matter/protocol/im_handler"

private module EndpointStatusFixture
  EXISTING_ENDPOINT =      1_u16
  MISSING_ENDPOINT  =      9_u16
  MISSING_CLUSTER   = 0x1234_u32

  def self.clusters : Hash(Tuple(UInt16, UInt32), Matter::Cluster::Base)
    on_off = Matter::Cluster::OnOff.new(endpoint(EXISTING_ENDPOINT))
    { {EXISTING_ENDPOINT, Matter::Cluster::OnOff::CLUSTER_ID} => on_off.as(Matter::Cluster::Base) }
  end
end

describe "IMHandler concrete endpoint status" do
  it "distinguishes a missing endpoint from a missing cluster on Read and subscription priming" do
    clusters = EndpointStatusFixture.clusters
    attribute = Matter::Cluster::OnOff::ATTR_ON_OFF
    cluster = Matter::Cluster::OnOff::CLUSTER_ID

    missing_endpoint = Matter::InteractionModel::AttributePath.new(
      EndpointStatusFixture::MISSING_ENDPOINT, cluster, attribute)
    missing_cluster = Matter::InteractionModel::AttributePath.new(
      EndpointStatusFixture::EXISTING_ENDPOINT, EndpointStatusFixture::MISSING_CLUSTER, attribute)
    reports = Matter::Protocol::IMHandler.read_attributes([missing_endpoint, missing_cluster], clusters)
    reports.size.should eq(2)
    reports.compact_map(&.attribute_status).map(&.status.status).should eq([
      Matter::InteractionModel::StatusCode::UnsupportedEndpoint.value,
      Matter::InteractionModel::StatusCode::UnsupportedCluster.value,
    ])

    # SubscribeRequest priming calls this same reader; its initial ReportData
    # must retain the distinction when a subscription ID is supplied.
    chunks = Matter::Protocol::IMHandler.encode_chunked_report_data(reports, 7_u32)
    chunks.size.should eq(1)
    priming = Matter::InteractionModel::ReportDataMessage.from_slice(chunks.first[0])
    priming.subscription_id.should eq(7_u32)
    priming_reports = priming.attribute_reports || [] of Matter::InteractionModel::AttributeReportIB
    priming_reports.compact_map(&.attribute_status).map(&.status.status).should eq([
      Matter::InteractionModel::StatusCode::UnsupportedEndpoint.value,
      Matter::InteractionModel::StatusCode::UnsupportedCluster.value,
    ])
  end

  it "distinguishes a missing endpoint from a missing cluster on Write" do
    clusters = EndpointStatusFixture.clusters
    attribute = Matter::Cluster::OnOff::ATTR_ON_OFF
    value = TLV::Any.new(true, nil)
    requests = [
      Matter::InteractionModel::AttributeDataIB.new(
        path: Matter::InteractionModel::AttributePath.new(
          EndpointStatusFixture::MISSING_ENDPOINT, Matter::Cluster::OnOff::CLUSTER_ID, attribute), data: value),
      Matter::InteractionModel::AttributeDataIB.new(
        path: Matter::InteractionModel::AttributePath.new(
          EndpointStatusFixture::EXISTING_ENDPOINT, EndpointStatusFixture::MISSING_CLUSTER, attribute), data: value),
    ]
    statuses = Matter::Protocol::IMHandler.write_attributes(requests, clusters)
    statuses.map(&.status.status).should eq([
      Matter::InteractionModel::StatusCode::UnsupportedEndpoint.value,
      Matter::InteractionModel::StatusCode::UnsupportedCluster.value,
    ])
  end

  it "distinguishes a missing endpoint from a missing cluster on Event Read" do
    clusters = EndpointStatusFixture.clusters
    paths = [
      Matter::InteractionModel::EventPath.new(
        endpoint: EndpointStatusFixture::MISSING_ENDPOINT, cluster: Matter::Cluster::OnOff::CLUSTER_ID, event: 0_u32),
      Matter::InteractionModel::EventPath.new(
        endpoint: EndpointStatusFixture::EXISTING_ENDPOINT, cluster: EndpointStatusFixture::MISSING_CLUSTER, event: 0_u32),
    ]
    reports = Matter::Protocol::IMHandler.read_events(paths, Matter::EventJournal.new, clusters)
    reports.size.should eq(2)
    reports.compact_map(&.event_status).map(&.status.status).should eq([
      Matter::InteractionModel::StatusCode::UnsupportedEndpoint.value,
      Matter::InteractionModel::StatusCode::UnsupportedCluster.value,
    ])
  end

  it "distinguishes a missing endpoint from a missing cluster on Invoke" do
    clusters = EndpointStatusFixture.clusters
    commands = [
      Matter::InteractionModel::CommandDataIBTlv.new(
        Matter::InteractionModel::CommandPath.new(
          EndpointStatusFixture::MISSING_ENDPOINT, Matter::Cluster::OnOff::CLUSTER_ID, Matter::Cluster::OnOff::CMD_ON), nil),
      Matter::InteractionModel::CommandDataIBTlv.new(
        Matter::InteractionModel::CommandPath.new(
          EndpointStatusFixture::EXISTING_ENDPOINT, EndpointStatusFixture::MISSING_CLUSTER, Matter::Cluster::OnOff::CMD_ON), nil),
    ]
    responses = Matter::Protocol::IMHandler.invoke_commands(commands, clusters)
    responses.size.should eq(2)
    responses.compact_map(&.command_status).map(&.status.status).should eq([
      Matter::InteractionModel::StatusCode::UnsupportedEndpoint.value,
      Matter::InteractionModel::StatusCode::UnsupportedCluster.value,
    ])
  end

  it "keeps wildcard reads and events silent for an absent endpoint" do
    clusters = EndpointStatusFixture.clusters
    attribute_path = Matter::InteractionModel::AttributePath.new(
      endpoint: EndpointStatusFixture::MISSING_ENDPOINT, cluster: Matter::Cluster::OnOff::CLUSTER_ID)
    Matter::Protocol::IMHandler.read_attributes([attribute_path], clusters).should be_empty

    event_path = Matter::InteractionModel::EventPath.new(
      endpoint: EndpointStatusFixture::MISSING_ENDPOINT, cluster: Matter::Cluster::OnOff::CLUSTER_ID)
    Matter::Protocol::IMHandler.read_events([event_path], Matter::EventJournal.new, clusters).should be_empty
  end
end
