require "../spec_helper"
require "../../src/matter/cluster/binding"

private alias BindingCluster = Matter::Cluster::Binding
private alias BindingTarget = BindingCluster::Target
private alias BindingStatus = Matter::InteractionModel::StatusCode

private def write_bindings(cluster : BindingCluster, entries : Array(BindingTarget)) : BindingStatus
  cluster.write_attribute(BindingCluster::ATTR_BINDING, TLV::Serializable.serialize_value(entries, nil)).status
end

private def provisioned_binding_cluster : BindingCluster
  cluster = BindingCluster.new(Matter::DataType::EndpointNumber.new(1_u16))
  cluster.request_fabric_index = 1_u8
  write_bindings(cluster, [BindingTarget.new(node: 2_u64, endpoint: 1_u16)]).should eq(BindingStatus::Success)
  cluster.request_fabric_index = 2_u8
  write_bindings(cluster, [BindingTarget.new(group: 3_u16)]).should eq(BindingStatus::Success)
  cluster
end

private def assert_rejected_binding_target(bad : BindingTarget) : Nil
  cluster = provisioned_binding_cluster
  prior_version = cluster.data_version
  cluster.request_fabric_index = 1_u8
  write_bindings(cluster, [bad]).should eq(BindingStatus::ConstraintError)
  cluster.binding.map(&.node).should eq([2_u64])
  cluster.data_version.should eq(prior_version)
  cluster.request_fabric_index = 2_u8
  cluster.binding.map(&.group).should eq([3_u16])
end

describe BindingCluster do
  it "accepts unicast and multicast TargetStruct shapes on the requesting fabric" do
    cluster = BindingCluster.new(Matter::DataType::EndpointNumber.new(1_u16))
    cluster.request_fabric_index = 1_u8

    write_bindings(cluster, [BindingTarget.new(node: 2_u64, endpoint: 1_u16),
                             BindingTarget.new(group: 3_u16)]).should eq(BindingStatus::Success)
    cluster.binding.map(&.fabric_index).should eq([1_u8, 1_u8])
    cluster.binding.map(&.node).should eq([2_u64, nil])

    cluster.request_fabric_index = 2_u8
    cluster.binding.should be_empty
    write_bindings(cluster, [BindingTarget.new(group: 4_u16)]).should eq(BindingStatus::Success)
    cluster.binding.map(&.group).should eq([4_u16])
    cluster.request_fabric_index = 1_u8
    cluster.binding.map(&.group).should eq([nil, 3_u16])
  end

  it "rejects a node without an endpoint and preserves both fabrics" do
    assert_rejected_binding_target(BindingTarget.new(node: 7_u64))
  end

  it "rejects group zero and preserves both fabrics" do
    assert_rejected_binding_target(BindingTarget.new(group: 0_u16))
  end

  it "rejects malformed trusted assignments without partially replacing the list" do
    cluster = BindingCluster.new(Matter::DataType::EndpointNumber.new(1_u16))
    cluster.binding = [BindingTarget.new(node: 2_u64, endpoint: 1_u16)]
    prior_version = cluster.data_version

    [BindingTarget.new(node: 3_u64, group: 4_u16),
     BindingTarget.new(group: 4_u16, endpoint: 1_u16),
     BindingTarget.new].each do |bad|
      expect_raises(Matter::ClusterError, /Invalid binding target/) do
        cluster.binding = [bad]
      end
      cluster.binding.map(&.node).should eq([2_u64])
      cluster.data_version.should eq(prior_version)
    end
  end
end
