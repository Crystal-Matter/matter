require "../spec_helper"
require "../../src/matter/node"
require "../../src/matter/cluster/on_off"
require "../../src/matter/cluster/level_control"
require "../../src/matter/cluster/identify"
require "../../src/matter/cluster/groups"

# The mandatory server clusters of the given light device type, so the node
# accepts the endpoint.
private def light_endpoint(endpoint_id : UInt16, device_type : Matter::DeviceType) : Matter::Endpoint
  number = endpoint(endpoint_id)
  endpoint = Matter::Endpoint.new(number, device_type)
  endpoint.add_cluster(Matter::Cluster::Identify.new(number))
  endpoint.add_cluster(Matter::Cluster::Groups.new(number))
  endpoint
end

describe "Node ergonomics" do
  describe "simplified cluster access" do
    it "gets a cluster by type instead of numeric ID" do
      endpoint = light_endpoint(1_u16, Matter::DeviceType.on_off_light)
      endpoint.add_cluster(Matter::Cluster::OnOff.new(endpoint.endpoint_id, on_off: false))

      cluster = endpoint.get_cluster(Matter::Cluster::OnOff)
      cluster.should_not be_nil
      cluster.as(Matter::Cluster::OnOff).cluster_id.id.should eq(Matter::Cluster::OnOff::CLUSTER_ID)
      cluster.as(Matter::Cluster::OnOff).on_off?.should be_false
    end

    it "gets a cluster with a bang method that raises on missing" do
      endpoint = light_endpoint(1_u16, Matter::DeviceType.on_off_light)

      expect_raises(KeyError, /not found/) do
        endpoint.get_cluster!(Matter::Cluster::OnOff)
      end
    end

    it "works with node-level cluster access" do
      node = Matter::Node.new
      endpoint = light_endpoint(1_u16, Matter::DeviceType.dimmable_light)
      endpoint.add_cluster(Matter::Cluster::OnOff.new(endpoint.endpoint_id))
      endpoint.add_cluster(Matter::Cluster::LevelControl.new(endpoint.endpoint_id, current_level: 50_u8))
      node.add_endpoint(endpoint)

      cluster = node.get_cluster(1_u16, Matter::Cluster::LevelControl)
      cluster.should_not be_nil
      cluster.as(Matter::Cluster::LevelControl).current_level.should eq(50_u8)
    end
  end

  describe "high-level device control patterns" do
    it "demonstrates idiomatic control flow" do
      # Build a complete dimmable light
      node = Matter::Node.new
      endpoint = light_endpoint(1_u16, Matter::DeviceType.dimmable_light)
      endpoint.add_cluster(Matter::Cluster::OnOff.new(endpoint.endpoint_id, on_off: false))
      endpoint.add_cluster(Matter::Cluster::LevelControl.new(endpoint.endpoint_id, current_level: 1_u8))
      node.add_endpoint(endpoint)

      # Direct cluster access for reading state (most ergonomic)
      light = node.get_cluster!(1_u16, Matter::Cluster::OnOff)
      light.on_off?.should be_false

      dimmer = node.get_cluster!(1_u16, Matter::Cluster::LevelControl)
      dimmer.current_level.should eq(1_u8)

      # Commands go to the cluster the lookup returned
      invoke(light, Matter::Cluster::OnOff::CMD_ON)
      light.on_off?.should be_true

      invoke(light, Matter::Cluster::OnOff::CMD_OFF)
      light.on_off?.should be_false

      # Attribute reads go through the same reference
      read_tlv(dimmer, Matter::Cluster::LevelControl::ATTR_CURRENT_LEVEL).value.should eq(1_u8)
    end

    it "demonstrates multi-endpoint device control" do
      # Build a 2-gang light switch
      node = Matter::Node.new

      [1_u16, 2_u16].each do |endpoint_id|
        endpoint = light_endpoint(endpoint_id, Matter::DeviceType.on_off_light)
        endpoint.add_cluster(Matter::Cluster::OnOff.new(endpoint.endpoint_id, on_off: false))
        node.add_endpoint(endpoint)
      end

      # Control each light independently using typed cluster access
      light1 = node.get_cluster!(1_u16, Matter::Cluster::OnOff)
      light2 = node.get_cluster!(2_u16, Matter::Cluster::OnOff)

      invoke(light1, Matter::Cluster::OnOff::CMD_ON)
      invoke(light2, Matter::Cluster::OnOff::CMD_OFF)

      light1.on_off?.should be_true
      light2.on_off?.should be_false

      # Or control both at once
      node.endpoint_ids.each do |endpoint_id|
        invoke(node.get_cluster!(endpoint_id, Matter::Cluster::OnOff), Matter::Cluster::OnOff::CMD_ON)
      end

      light1.on_off?.should be_true
      light2.on_off?.should be_true
    end
  end
end
