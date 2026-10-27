require "../spec_helper"
require "../../src/matter/device"

private RVC_DEVICE_TYPE_ID = 0x0074_u32

private def rvc_endpoint : Matter::Endpoint
  Matter::Endpoint.new(Matter::DataType::EndpointNumber.new(1_u16),
    [Matter::DeviceType.for(RVC_DEVICE_TYPE_ID)])
end

describe "Matter 1.6 Robotic Vacuum Cleaner device type" do
  it "maps its canonical ID, revision, name, mandatory clusters and event" do
    definition = Matter::DeviceType.for(RVC_DEVICE_TYPE_ID)
    definition.revision.should eq(4_u16)
    definition.name.should eq("Robotic Vacuum Cleaner")
    definition.required_server_clusters.should eq([
      Matter::Cluster::Descriptor::CLUSTER_ID,
      Matter::Cluster::Identify::CLUSTER_ID,
      Matter::Cluster::RvcRunMode::CLUSTER_ID,
      Matter::Cluster::RvcOperationalState::CLUSTER_ID,
    ])
    definition.required_server_events[Matter::Cluster::RvcOperationalState::CLUSTER_ID].should eq([
      Matter::Cluster::RvcOperationalState::EVENT_OPERATION_COMPLETION,
    ])
  end

  it "rejects an endpoint missing its mandatory RVC clusters" do
    endpoint = rvc_endpoint
    endpoint.populate_descriptor
    errors = endpoint.validate.join(" ")
    errors.should contain("cluster 0x0003")
    errors.should contain("cluster 0x0054")
    errors.should contain("cluster 0x0061")
  end

  it "accepts the mandatory cluster and event composition" do
    endpoint = rvc_endpoint
    endpoint.add_cluster(Matter::Cluster::Identify.new(endpoint.endpoint_id))
    options = [
      Matter::Cluster::ModeBase::Option.new("Idle", 0_u8,
        [Matter::Cluster::ModeBase::Tag.new(Matter::Cluster::RvcRunMode::ModeTag::Idle.value)]),
      Matter::Cluster::ModeBase::Option.new("Cleaning", 1_u8,
        [Matter::Cluster::ModeBase::Tag.new(Matter::Cluster::RvcRunMode::ModeTag::Cleaning.value)]),
    ]
    endpoint.add_cluster(Matter::Cluster::RvcRunMode.new(endpoint.endpoint_id,
      supported_modes: options, current_mode: 0_u8))
    state = Matter::Cluster::RvcOperationalState.new(endpoint.endpoint_id)
    endpoint.add_cluster(state)
    endpoint.populate_descriptor
    endpoint.validate.should be_empty
    state.events.map(&.id.id).should contain(Matter::Cluster::RvcOperationalState::EVENT_OPERATION_COMPLETION)
  end
end
