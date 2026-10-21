require "../spec_helper"
require "../../src/matter/protocol/im_handler"
require "../../src/matter/cluster/on_off"
require "../../src/matter/cluster/descriptor"

describe "Interaction Model data version filters" do
  it "encodes the cluster path and version in ReadRequest and SubscribeRequest" do
    filter = Matter::InteractionModel::DataVersionFilterIB.new(
      Matter::InteractionModel::ClusterPath.new(1_u16, Matter::Cluster::OnOff::CLUSTER_ID),
      0x12345678_u32)
    read = Matter::InteractionModel::ReadRequestMessage.new(data_version_filters: [filter])
    subscribe = Matter::InteractionModel::SubscribeRequestMessage.new(data_version_filters: [filter])

    Matter::InteractionModel::ReadRequestMessage.from_slice(read.to_slice).data_version_filters.should eq([filter])
    Matter::InteractionModel::SubscribeRequestMessage.from_slice(subscribe.to_slice).data_version_filters.should eq([filter])
  end

  it "omits a matching cluster but still reports another cluster on a wildcard read" do
    on_off = Matter::Cluster::OnOff.new(endpoint(1))
    descriptor = Matter::Cluster::Descriptor.new(endpoint(1))
    on_off.data_version = 7_u32
    descriptor.data_version = 9_u32
    clusters = {
      {1_u16, Matter::Cluster::OnOff::CLUSTER_ID}      => on_off.as(Matter::Cluster::Base),
      {1_u16, Matter::Cluster::Descriptor::CLUSTER_ID} => descriptor.as(Matter::Cluster::Base),
    }
    path = Matter::InteractionModel::AttributePath.new(endpoint: 1_u16)
    filter = Matter::InteractionModel::DataVersionFilterIB.new(
      Matter::InteractionModel::ClusterPath.new(1_u16, Matter::Cluster::OnOff::CLUSTER_ID), 7_u32)

    reports = Matter::Protocol::IMHandler.read_attributes([path], clusters, data_version_filters: [filter])
    reports.should_not be_empty
    reports.all? do |report|
      (report.attribute_data.try(&.path.cluster) || report.attribute_status.try(&.path.cluster)) ==
        Matter::Cluster::Descriptor::CLUSTER_ID
    end.should be_true
  end

  it "returns attributes when the client's version is stale" do
    on_off = Matter::Cluster::OnOff.new(endpoint(1))
    on_off.data_version = 8_u32
    clusters = { {1_u16, Matter::Cluster::OnOff::CLUSTER_ID} => on_off.as(Matter::Cluster::Base) }
    path = Matter::InteractionModel::AttributePath.new(
      endpoint: 1_u16, cluster: Matter::Cluster::OnOff::CLUSTER_ID,
      attribute: Matter::Cluster::OnOff::ATTR_ON_OFF)
    filter = Matter::InteractionModel::DataVersionFilterIB.new(
      Matter::InteractionModel::ClusterPath.new(1_u16, Matter::Cluster::OnOff::CLUSTER_ID), 7_u32)

    reports = Matter::Protocol::IMHandler.read_attributes([path], clusters, data_version_filters: [filter])
    reports.size.should eq(1)
    reports.first.attribute_data.should_not be_nil
  end

  it "suppresses a concrete attribute when its cluster version matches" do
    on_off = Matter::Cluster::OnOff.new(endpoint(1))
    on_off.data_version = 8_u32
    clusters = { {1_u16, Matter::Cluster::OnOff::CLUSTER_ID} => on_off.as(Matter::Cluster::Base) }
    path = Matter::InteractionModel::AttributePath.new(
      endpoint: 1_u16, cluster: Matter::Cluster::OnOff::CLUSTER_ID,
      attribute: Matter::Cluster::OnOff::ATTR_ON_OFF)
    filter = Matter::InteractionModel::DataVersionFilterIB.new(
      Matter::InteractionModel::ClusterPath.new(1_u16, Matter::Cluster::OnOff::CLUSTER_ID), 8_u32)

    Matter::Protocol::IMHandler.read_attributes([path], clusters,
      data_version_filters: [filter]).should be_empty
  end
end
