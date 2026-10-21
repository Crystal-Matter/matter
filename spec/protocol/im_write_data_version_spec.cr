require "../spec_helper"
require "../../src/matter/cluster/on_off"
require "../../src/matter/protocol/im_handler"

private class VersionedWriteProbe < Matter::Cluster::OnOff
  getter writes = 0

  def write_attribute(attribute_id : UInt32, value : TLV::Any) : Matter::InteractionModel::Status
    @writes += 1
    @data_version &+= 1
    Matter::InteractionModel::Status.success
  end
end

describe "Interaction Model write data version" do
  it "rejects a stale write without mutating the cluster" do
    cluster = VersionedWriteProbe.new(endpoint(1))
    cluster.data_version = 11_u32
    clusters = { {1_u16, Matter::Cluster::OnOff::CLUSTER_ID} => cluster.as(Matter::Cluster::Base) }
    path = Matter::InteractionModel::AttributePath.new(1_u16,
      Matter::Cluster::OnOff::CLUSTER_ID, Matter::Cluster::OnOff::ATTR_ON_OFF)
    request = Matter::InteractionModel::AttributeDataIB.new(path, TLV::Any.new(true), 10_u32)

    statuses = Matter::Protocol::IMHandler.write_attributes([request], clusters)
    statuses.map(&.status.status).should eq([Matter::InteractionModel::StatusCode::DataVersionMismatch.value])
    cluster.writes.should eq(0)
    cluster.data_version.should eq(11_u32)
  end

  it "accepts a write at the current version and advances it" do
    cluster = VersionedWriteProbe.new(endpoint(1))
    cluster.data_version = 11_u32
    clusters = { {1_u16, Matter::Cluster::OnOff::CLUSTER_ID} => cluster.as(Matter::Cluster::Base) }
    path = Matter::InteractionModel::AttributePath.new(1_u16,
      Matter::Cluster::OnOff::CLUSTER_ID, Matter::Cluster::OnOff::ATTR_ON_OFF)
    request = Matter::InteractionModel::AttributeDataIB.new(path, TLV::Any.new(true), 11_u32)

    statuses = Matter::Protocol::IMHandler.write_attributes([request], clusters)
    statuses.map(&.status.status).should eq([Matter::InteractionModel::StatusCode::Success.value])
    cluster.writes.should eq(1)
    cluster.data_version.should eq(12_u32)
  end
end
