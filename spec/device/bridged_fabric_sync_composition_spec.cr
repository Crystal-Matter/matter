require "../spec_helper"
require "../../src/matter/endpoint"
require "../../src/matter/cluster/bridged_administrator_commissioning"
require "../../src/matter/cluster/ecosystem_information"
require "../../src/matter/cluster/bridged_device_basic_information"

private alias Admin = Matter::Cluster::BridgedAdministratorCommissioning
private alias RootAdmin = Matter::Cluster::AdministratorCommissioning
private alias Status = Matter::InteractionModel::Status

describe "FabricSynchronizedNode Bridged Node composition" do
  it "uses Bridged Node revision three and keeps ordinary bridges free of synchronized clusters" do
    definition = Matter::DeviceType.for(Matter::DeviceType::BRIDGED_NODE)
    definition.revision.should eq(3_u16)
    definition.requires_cluster?(Matter::Cluster::BridgedDeviceBasicInformation::CLUSTER_ID).should be_true
    endpoint_id = Matter::DataType::EndpointNumber.new(1_u16)
    endpoint = Matter::Endpoint.new(endpoint_id, definition)
    endpoint.add_cluster(Matter::Cluster::BridgedDeviceBasicInformation.new(endpoint_id, unique_id: "ordinary-bridge"))
    endpoint.populate_descriptor
    endpoint.validate.should be_empty
    endpoint.descriptor.server_list.should_not contain(RootAdmin::CLUSTER_ID)
    endpoint.descriptor.server_list.should_not contain(Matter::Cluster::EcosystemInformation::CLUSTER_ID)
  end

  it "requires Ecosystem Information when bridged Administrator Commissioning is opted in" do
    endpoint_id = Matter::DataType::EndpointNumber.new(2_u16)
    endpoint = Matter::Endpoint.new(endpoint_id,
      Matter::DeviceType.for(Matter::DeviceType::BRIDGED_NODE))
    endpoint.add_cluster(Matter::Cluster::BridgedDeviceBasicInformation.new(endpoint_id, unique_id: "synchronized-bridge"))
    endpoint.add_cluster(Admin.new(endpoint_id,
      target_fabric_index: 3_u8, target_node_id: 0x1234_u64,
      on_open: ->(_tf : UInt8, _tn : UInt64, _cf : UInt8, _r : RootAdmin::OpenCommissioningWindowRequest) { Status.success },
      on_revoke: ->(_tf : UInt8, _tn : UInt64, _cf : UInt8) { Status.success }))
    endpoint.populate_descriptor
    endpoint.validate.join.should contain("Ecosystem Information")
    endpoint.add_cluster(Matter::Cluster::EcosystemInformation.new(endpoint_id))
    endpoint.populate_descriptor
    endpoint.validate.should be_empty
    endpoint.descriptor.server_list.should contain(RootAdmin::CLUSTER_ID)
    endpoint.descriptor.server_list.should contain(Matter::Cluster::EcosystemInformation::CLUSTER_ID)
    endpoint.descriptor.device_type_list.first.revision.should eq(3_u16)
  end

  it "rejects the bridge-local Administrator Commissioning implementation on a bridged endpoint" do
    endpoint_id = Matter::DataType::EndpointNumber.new(2_u16)
    endpoint = Matter::Endpoint.new(endpoint_id,
      Matter::DeviceType.for(Matter::DeviceType::BRIDGED_NODE))
    endpoint.add_cluster(Matter::Cluster::BridgedDeviceBasicInformation.new(endpoint_id, unique_id: "bad-bridge"))
    endpoint.add_cluster(RootAdmin.new(endpoint_id))
    endpoint.populate_descriptor
    endpoint.validate.join.should contain("must forward")
  end
end
