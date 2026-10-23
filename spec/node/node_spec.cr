require "../spec_helper"
require "../../src/matter/node"
require "../../src/matter/cluster/descriptor"
require "../../src/matter/cluster/on_off"
require "../../src/matter/cluster/level_control"
require "../../src/matter/cluster/identify"
require "../../src/matter/cluster/groups"
require "../../src/matter/cluster/power_source"
require "../../src/matter/cluster/smoke_co_alarm"

# An On/Off Light endpoint with every mandatory server cluster, so `add_endpoint`
# accepts it.
private def on_off_light(endpoint_id : UInt16) : Matter::Endpoint
  number = endpoint(endpoint_id)
  endpoint = Matter::Endpoint.new(number, Matter::DeviceType.on_off_light)
  endpoint.add_cluster(Matter::Cluster::Identify.new(number))
  endpoint.add_cluster(Matter::Cluster::Groups.new(number))
  endpoint.add_cluster(Matter::Cluster::OnOff.new(number))
  endpoint
end

describe Matter::Node do
  describe "endpoint management" do
    it "starts empty" do
      node = Matter::Node.new

      node.endpoint_count.should eq(0)
      node.clusters.should be_empty
      node.endpoint_ids.should be_empty
    end

    it "adds an endpoint and indexes its clusters" do
      node = Matter::Node.new
      node.add_endpoint(on_off_light(1_u16))

      node.endpoint_count.should eq(1)
      node.has_endpoint?(1_u16).should be_true
      node.endpoint(1_u16).as(Matter::Endpoint).number.should eq(1_u16)

      node.clusters[{1_u16, Matter::Cluster::OnOff::CLUSTER_ID}].should be_a(Matter::Cluster::OnOff)
      node.clusters[{1_u16, Matter::Cluster::Descriptor::CLUSTER_ID}].should be_a(Matter::Cluster::Descriptor)
      node.clusters.keys.all? { |(endpoint_id, _)| endpoint_id == 1_u16 }.should be_true
    end

    it "returns the added endpoint" do
      node = Matter::Node.new
      endpoint = on_off_light(1_u16)

      node.add_endpoint(endpoint).should be(endpoint)
    end

    it "returns nil for a missing endpoint and raises with the bang method" do
      node = Matter::Node.new

      node.endpoint(99_u16).should be_nil
      expect_raises(KeyError, /not found/) { node.endpoint!(99_u16) }
    end

    it "removes an endpoint and its clusters from the index" do
      node = Matter::Node.new
      node.add_endpoint(on_off_light(1_u16))
      node.add_endpoint(on_off_light(2_u16))

      removed = node.remove_endpoint(1_u16)

      removed.as(Matter::Endpoint).number.should eq(1_u16)
      node.endpoint(1_u16).should be_nil
      node.clusters.has_key?({1_u16, Matter::Cluster::OnOff::CLUSTER_ID}).should be_false
      node.clusters.has_key?({2_u16, Matter::Cluster::OnOff::CLUSTER_ID}).should be_true
    end

    it "returns nil when removing an endpoint that is not there" do
      Matter::Node.new.remove_endpoint(1_u16).should be_nil
    end

    it "replaces an endpoint added at the same number" do
      node = Matter::Node.new
      node.add_endpoint(on_off_light(1_u16))

      replacement = on_off_light(1_u16)
      replacement.add_cluster(Matter::Cluster::LevelControl.new(replacement.endpoint_id))
      node.add_endpoint(replacement)

      node.endpoint_count.should eq(1)
      node.endpoint(1_u16).should be(replacement)
      node.clusters[{1_u16, Matter::Cluster::OnOff::CLUSTER_ID}].should be(replacement.get_cluster!(Matter::Cluster::OnOff))
      node.clusters.has_key?({1_u16, Matter::Cluster::LevelControl::CLUSTER_ID}).should be_true
    end

    it "lists endpoint ids in ascending order" do
      node = Matter::Node.new
      [3_u16, 1_u16, 2_u16].each { |endpoint_id| node.add_endpoint(on_off_light(endpoint_id)) }

      node.endpoint_ids.should eq([1_u16, 2_u16, 3_u16])
    end

    it "hands out the lowest unused endpoint number" do
      node = Matter::Node.new

      node.next_endpoint_id.should eq(1_u16)

      node.add_endpoint(on_off_light(1_u16))
      node.add_endpoint(on_off_light(3_u16))
      node.next_endpoint_id.should eq(2_u16)

      node.add_endpoint(on_off_light(2_u16))
      node.next_endpoint_id.should eq(4_u16)
    end

    it "iterates every cluster on the node" do
      node = Matter::Node.new
      node.add_endpoint(on_off_light(1_u16))
      node.add_endpoint(on_off_light(2_u16))

      seen = [] of Matter::Cluster::Base
      node.each_cluster { |cluster| seen << cluster }

      seen.size.should eq(node.clusters.size)
      seen.count(&.is_a?(Matter::Cluster::OnOff)).should eq(2)
    end
  end

  describe "configuration errors" do
    it "raises when a cluster was built for another endpoint" do
      endpoint = Matter::Endpoint.new(endpoint(1))

      expect_raises(Matter::ConfigurationError, /does not match/) do
        endpoint.add_cluster(build(Matter::Cluster::OnOff, 2))
      end
    end

    it "raises when a mandatory cluster of the device type is missing" do
      node = Matter::Node.new
      number = endpoint(1)
      endpoint = Matter::Endpoint.new(number, Matter::DeviceType.on_off_light)
      endpoint.add_cluster(Matter::Cluster::OnOff.new(number))

      expect_raises(Matter::ConfigurationError, /Missing required cluster 0x0003/) do
        node.add_endpoint(endpoint)
      end

      node.endpoint_count.should eq(0)
      node.clusters.should be_empty
    end
  end

  describe "callbacks" do
    it "applies the attribute callback to clusters added later" do
      node = Matter::Node.new
      changes = [] of Tuple(UInt16, UInt32, UInt32)
      node.on_attribute_changed = ->(endpoint_id : UInt16, cluster_id : UInt32, attribute_id : UInt32) do
        changes << {endpoint_id, cluster_id, attribute_id}
        nil
      end

      node.add_endpoint(on_off_light(1_u16))
      node.get_cluster!(1_u16, Matter::Cluster::OnOff).on = true

      changes.should contain({1_u16, Matter::Cluster::OnOff::CLUSTER_ID, Matter::Cluster::OnOff::ATTR_ON_OFF})
    end

    it "applies the attribute callback to clusters already present" do
      node = Matter::Node.new
      node.add_endpoint(on_off_light(1_u16))

      changes = [] of UInt32
      node.on_attribute_changed = ->(_endpoint_id : UInt16, _cluster_id : UInt32, attribute_id : UInt32) do
        changes << attribute_id
        nil
      end

      node.get_cluster!(1_u16, Matter::Cluster::OnOff).on = true

      changes.should contain(Matter::Cluster::OnOff::ATTR_ON_OFF)
    end

    it "applies the version callback to clusters added later" do
      node = Matter::Node.new
      dirty = [] of Matter::Cluster::Base
      node.on_version_changed = ->(cluster : Matter::Cluster::Base) do
        dirty << cluster
        nil
      end

      node.add_endpoint(on_off_light(1_u16))
      on_off = node.get_cluster!(1_u16, Matter::Cluster::OnOff)
      on_off.on = true

      dirty.should contain(on_off)
    end

    it "unwires the clusters of a removed endpoint" do
      node = Matter::Node.new
      changes = 0
      node.on_attribute_changed = ->(_endpoint_id : UInt16, _cluster_id : UInt32, _attribute_id : UInt32) do
        changes += 1
        nil
      end
      node.add_endpoint(on_off_light(1_u16))
      on_off = node.get_cluster!(1_u16, Matter::Cluster::OnOff)

      node.remove_endpoint(1_u16)
      on_off.on = true

      changes.should eq(0)
      on_off.on_attribute_changed.should be_nil
      on_off.on_version_changed.should be_nil
    end
  end

  describe "typed cluster lookup" do
    it "finds a cluster on an endpoint" do
      node = Matter::Node.new
      node.add_endpoint(on_off_light(1_u16))

      node.get_cluster(1_u16, Matter::Cluster::OnOff).should_not be_nil
      node.get_cluster!(1_u16, Matter::Cluster::OnOff).should be_a(Matter::Cluster::OnOff)
      node.get_cluster(1_u16, Matter::Cluster::LevelControl).should be_nil
      node.get_cluster(2_u16, Matter::Cluster::OnOff).should be_nil
    end

    it "finds a cluster anywhere on the node" do
      node = Matter::Node.new
      node.add_endpoint(on_off_light(2_u16))

      node.get_cluster(Matter::Cluster::OnOff).should_not be_nil
      node.get_cluster!(Matter::Cluster::OnOff).endpoint_id.number.should eq(2_u16)
      node.get_cluster(Matter::Cluster::LevelControl).should be_nil
    end

    it "raises for a missing cluster with the bang methods" do
      node = Matter::Node.new

      expect_raises(KeyError, /not found on endpoint/) { node.get_cluster!(1_u16, Matter::Cluster::OnOff) }
      expect_raises(KeyError, /not found on node/) { node.get_cluster!(Matter::Cluster::OnOff) }
    end
  end

  describe "#validate" do
    it "requires a Power Source device type somewhere on a Smoke CO Alarm node" do
      node = Matter::Node.new
      detector_number = endpoint(1)
      detector = Matter::Endpoint.new(detector_number, Matter::DeviceType.smoke_co_alarm)
      detector.add_cluster(Matter::Cluster::Identify.new(detector_number))
      detector.add_cluster(Matter::Cluster::SmokeCOAlarm.new(detector_number,
        feature_map: Matter::Cluster::SmokeCOAlarm::Feature::SmokeAlarm))
      node.add_endpoint(detector)

      node.validate[1_u16].first.should contain("Power Source")
      node.valid?.should be_false

      power_number = endpoint(2)
      untyped_power = Matter::Endpoint.new(power_number)
      untyped_power.add_cluster(Matter::Cluster::PowerSource.new(power_number,
        feature_map: Matter::Cluster::PowerSource::Feature::None))
      node.add_endpoint(untyped_power)
      node.valid?.should be_false # The cluster alone does not satisfy the device-type requirement.

      power = Matter::Endpoint.new(power_number, Matter::DeviceType.power_source)
      power.add_cluster(Matter::Cluster::PowerSource.new(power_number,
        feature_map: Matter::Cluster::PowerSource::Feature::None))
      node.add_endpoint(power)

      node.validate.should be_empty
      node.valid?.should be_true

      node.remove_endpoint(2_u16)
      node.valid?.should be_false
    end

    it "is empty for a conformant node" do
      node = Matter::Node.new
      node.add_endpoint(on_off_light(1_u16))

      node.validate.should be_empty
      node.valid?.should be_true
    end

    it "reports the errors of an endpoint that stopped conforming" do
      node = Matter::Node.new
      endpoint = on_off_light(1_u16)
      node.add_endpoint(endpoint)

      endpoint.clusters.delete(Matter::Cluster::Groups::CLUSTER_ID)

      node.valid?.should be_false
      node.validate[1_u16].size.should eq(1)
      node.validate[1_u16].first.should contain("0x0004")
    end
  end

  describe "#description" do
    it "generates human-readable description" do
      node = Matter::Node.new
      node.add_endpoint(on_off_light(1_u16))
      node.add_endpoint(on_off_light(2_u16))

      description = node.description
      description.should contain("Node with 2 endpoint(s)")
      description.should contain("Endpoint 1")
      description.should contain("Endpoint 2")
      description.should contain("On/Off Light")
    end
  end
end
