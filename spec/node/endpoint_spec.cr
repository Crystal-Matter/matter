require "../spec_helper"
require "../../src/matter/endpoint"
require "../../src/matter/cluster/descriptor"
require "../../src/matter/cluster/on_off"
require "../../src/matter/cluster/level_control"
require "../../src/matter/cluster/identify"
require "../../src/matter/cluster/groups"
require "../../src/matter/cluster/scenes_management"
require "../../src/matter/cluster/microwave_oven_control"
require "../../src/matter/cluster/operational_state"

private ENDPOINT_ID = endpoint(1)

# Every mandatory server cluster of an On/Off Light except the Descriptor,
# which the endpoint injects itself.
private def on_off_light_clusters(endpoint : Matter::Endpoint) : Nil
  endpoint.add_cluster(Matter::Cluster::Identify.new(endpoint.endpoint_id))
  endpoint.add_cluster(Matter::Cluster::Groups.new(endpoint.endpoint_id))
  endpoint.add_cluster(Matter::Cluster::OnOff.new(endpoint.endpoint_id))
end

describe Matter::Endpoint do
  describe "initialization" do
    it "creates endpoint with device type" do
      device_type = Matter::DeviceType.on_off_light
      endpoint = Matter::Endpoint.new(ENDPOINT_ID, device_type)

      endpoint.endpoint_id.number.should eq(1_u16)
      endpoint.number.should eq(1_u16)
      endpoint.primary_device_type.should eq(device_type)
      endpoint.cluster_count.should eq(0)
    end

    it "creates endpoint with multiple device types" do
      device_types = [Matter::DeviceType.on_off_light, Matter::DeviceType.temperature_sensor]
      endpoint = Matter::Endpoint.new(ENDPOINT_ID, device_types)

      endpoint.device_types.size.should eq(2)
    end

    it "creates endpoint with no device type" do
      Matter::Endpoint.new(ENDPOINT_ID).primary_device_type.should be_nil
    end
  end

  describe "cluster management" do
    it "adds cluster to endpoint" do
      endpoint = Matter::Endpoint.new(ENDPOINT_ID, Matter::DeviceType.on_off_light)
      endpoint.add_cluster(Matter::Cluster::Descriptor.new(ENDPOINT_ID))

      endpoint.cluster_count.should eq(1)
      endpoint.has_cluster?(Matter::Cluster::Descriptor::CLUSTER_ID).should be_true
    end

    it "rejects cluster with mismatched endpoint ID" do
      endpoint = Matter::Endpoint.new(ENDPOINT_ID, Matter::DeviceType.on_off_light)
      other_endpoint_id = endpoint(2)

      expect_raises(Matter::ConfigurationError, /does not match/) do
        endpoint.add_cluster(Matter::Cluster::OnOff.new(other_endpoint_id))
      end
    end

    it "retrieves cluster by ID" do
      endpoint = Matter::Endpoint.new(ENDPOINT_ID, Matter::DeviceType.on_off_light)
      endpoint.add_cluster(Matter::Cluster::OnOff.new(ENDPOINT_ID))

      cluster = endpoint.get_cluster(Matter::Cluster::OnOff::CLUSTER_ID)
      cluster.should_not be_nil
      cluster.as(Matter::Cluster::Base).cluster_id.id.should eq(Matter::Cluster::OnOff::CLUSTER_ID)
    end

    it "returns nil for missing cluster" do
      endpoint = Matter::Endpoint.new(ENDPOINT_ID, Matter::DeviceType.on_off_light)

      endpoint.get_cluster(0x9999_u32).should be_nil
    end

    it "raises for missing cluster with bang method" do
      endpoint = Matter::Endpoint.new(ENDPOINT_ID, Matter::DeviceType.on_off_light)

      expect_raises(KeyError, /not found/) do
        endpoint.get_cluster!(0x9999_u32)
      end
    end

    it "retrieves cluster by type" do
      endpoint = Matter::Endpoint.new(ENDPOINT_ID, Matter::DeviceType.on_off_light)
      endpoint.add_cluster(Matter::Cluster::OnOff.new(ENDPOINT_ID, on_off: true))

      endpoint.get_cluster(Matter::Cluster::OnOff).as(Matter::Cluster::OnOff).on_off?.should be_true
      endpoint.get_cluster!(Matter::Cluster::OnOff).on_off?.should be_true
      endpoint.get_cluster(Matter::Cluster::LevelControl).should be_nil
    end

    it "raises for a missing cluster type with bang method" do
      endpoint = Matter::Endpoint.new(ENDPOINT_ID, Matter::DeviceType.on_off_light)

      expect_raises(KeyError, /not found/) do
        endpoint.get_cluster!(Matter::Cluster::OnOff)
      end
    end

    it "lists cluster IDs in ascending order" do
      endpoint = Matter::Endpoint.new(ENDPOINT_ID, Matter::DeviceType.on_off_light)
      endpoint.add_cluster(Matter::Cluster::OnOff.new(ENDPOINT_ID))
      endpoint.add_cluster(Matter::Cluster::Identify.new(ENDPOINT_ID))

      endpoint.cluster_ids.should eq([Matter::Cluster::Identify::CLUSTER_ID, Matter::Cluster::OnOff::CLUSTER_ID])
    end

    it "replaces a cluster registered under the same id" do
      endpoint = Matter::Endpoint.new(ENDPOINT_ID, Matter::DeviceType.on_off_light)
      endpoint.add_cluster(Matter::Cluster::OnOff.new(ENDPOINT_ID, on_off: false))
      endpoint.add_cluster(Matter::Cluster::OnOff.new(ENDPOINT_ID, on_off: true))

      endpoint.cluster_count.should eq(1)
      endpoint.get_cluster!(Matter::Cluster::OnOff).on_off?.should be_true
    end
  end

  describe "#descriptor" do
    it "injects a Descriptor when the device did not provide one" do
      endpoint = Matter::Endpoint.new(ENDPOINT_ID, Matter::DeviceType.on_off_light)

      descriptor = endpoint.descriptor
      descriptor.endpoint_id.number.should eq(1_u16)
      endpoint.get_cluster(Matter::Cluster::Descriptor::CLUSTER_ID).should be(descriptor)
    end

    it "keeps the Descriptor the device provided" do
      endpoint = Matter::Endpoint.new(ENDPOINT_ID, Matter::DeviceType.on_off_light)
      descriptor = Matter::Cluster::Descriptor.new(ENDPOINT_ID)
      endpoint.add_cluster(descriptor)

      endpoint.descriptor.should be(descriptor)
    end
  end

  describe "#populate_descriptor" do
    it "fills the ServerList from the clusters present" do
      endpoint = Matter::Endpoint.new(ENDPOINT_ID, Matter::DeviceType.on_off_light)
      on_off_light_clusters(endpoint)

      descriptor = endpoint.populate_descriptor

      descriptor.server_list.should contain(Matter::Cluster::Descriptor::CLUSTER_ID)
      descriptor.server_list.should contain(Matter::Cluster::Identify::CLUSTER_ID)
      descriptor.server_list.should contain(Matter::Cluster::Groups::CLUSTER_ID)
      descriptor.server_list.should contain(Matter::Cluster::OnOff::CLUSTER_ID)
    end

    it "fills the DeviceTypeList at each device type's own revision" do
      endpoint = Matter::Endpoint.new(ENDPOINT_ID, [
        Matter::DeviceType.on_off_light,
        Matter::DeviceType.temperature_sensor,
      ])

      device_types = endpoint.populate_descriptor.device_type_list

      device_types.size.should eq(2)
      device_types[0].device_type.should eq(Matter::DeviceType::ON_OFF_LIGHT)
      device_types[0].revision.should eq(Matter::DeviceType.on_off_light.revision)
      device_types[1].device_type.should eq(Matter::DeviceType::TEMPERATURE_SENSOR)
      device_types[1].revision.should eq(Matter::DeviceType.temperature_sensor.revision)
    end

    it "is idempotent" do
      endpoint = Matter::Endpoint.new(ENDPOINT_ID, Matter::DeviceType.on_off_light)
      on_off_light_clusters(endpoint)

      first = endpoint.populate_descriptor.server_list.dup
      endpoint.populate_descriptor.server_list.should eq(first)
      endpoint.populate_descriptor.device_type_list.size.should eq(1)
    end
  end

  describe "#wire_scene_extensions" do
    it "stores and applies the state of the other clusters on the endpoint" do
      endpoint = Matter::Endpoint.new(ENDPOINT_ID, Matter::DeviceType.on_off_light)
      on_off_light_clusters(endpoint)
      scenes = Matter::Cluster::ScenesManagement.new(ENDPOINT_ID)
      endpoint.add_cluster(scenes)

      endpoint.wire_scene_extensions

      on_off = endpoint.get_cluster!(Matter::Cluster::OnOff)
      on_off.on = true
      field_sets = scenes.get_extension_field_sets.as(Proc(Array(Matter::Cluster::ScenesManagement::ExtensionFieldSet))).call
      field_sets.map(&.cluster_id).should contain(Matter::Cluster::OnOff::CLUSTER_ID)

      on_off.on = false
      scenes.apply_extension_field_sets.as(Proc(Array(Matter::Cluster::ScenesManagement::ExtensionFieldSet), Nil)).call(field_sets)
      on_off.on_off?.should be_true
    end

    it "does nothing when the endpoint has no Scenes Management cluster" do
      endpoint = Matter::Endpoint.new(ENDPOINT_ID, Matter::DeviceType.on_off_light)
      on_off_light_clusters(endpoint)

      endpoint.wire_scene_extensions
    end
  end

  describe "validation" do
    it "requires CountdownTime on a Matter 1.6 Microwave Oven endpoint" do
      endpoint = Matter::Endpoint.new(ENDPOINT_ID, Matter::DeviceType.microwave_oven)
      modes = [
        Matter::Cluster::ModeBase::Option.new("Normal", 0_u8,
          [Matter::Cluster::ModeBase::Tag.new(Matter::Cluster::MicrowaveOvenMode::ModeTag::Normal.value)]),
        Matter::Cluster::ModeBase::Option.new("Defrost", 1_u8,
          [Matter::Cluster::ModeBase::Tag.new(Matter::Cluster::MicrowaveOvenMode::ModeTag::Defrost.value)]),
      ]
      mode = Matter::Cluster::MicrowaveOvenMode.new(ENDPOINT_ID, modes, 0_u8)
      state = Matter::Cluster::OperationalState.new(ENDPOINT_ID)
      endpoint.add_cluster(Matter::Cluster::Descriptor.new(ENDPOINT_ID))
      endpoint.add_cluster(mode)
      endpoint.add_cluster(Matter::Cluster::MicrowaveOvenControl.new(ENDPOINT_ID, mode, 3600_u32))
      endpoint.add_cluster(state)

      endpoint.validate.should eq(["Missing required attribute 0x0002 in cluster 0x0060 for device type Microwave Oven"])
      state.update_countdown(0_u32)
      state.events.map(&.id.id).should contain(Matter::Cluster::OperationalState::EVENT_OPERATION_COMPLETION)
      endpoint.validate.should be_empty
    end

    it "validates complete on/off light endpoint" do
      endpoint = Matter::Endpoint.new(ENDPOINT_ID, Matter::DeviceType.on_off_light)
      endpoint.add_cluster(Matter::Cluster::Descriptor.new(ENDPOINT_ID))
      on_off_light_clusters(endpoint)
      endpoint.add_cluster(Matter::Cluster::ScenesManagement.new(ENDPOINT_ID))

      endpoint.valid?.should be_true
      endpoint.validate.should be_empty
    end

    it "validates on/off light endpoint without the optional Scenes Management cluster" do
      endpoint = Matter::Endpoint.new(ENDPOINT_ID, Matter::DeviceType.on_off_light)
      endpoint.add_cluster(Matter::Cluster::Descriptor.new(ENDPOINT_ID))
      on_off_light_clusters(endpoint)

      endpoint.validate.should be_empty
      endpoint.valid?.should be_true
    end

    it "reports every missing mandatory cluster" do
      endpoint = Matter::Endpoint.new(ENDPOINT_ID, Matter::DeviceType.on_off_light)
      endpoint.add_cluster(Matter::Cluster::OnOff.new(ENDPOINT_ID))

      endpoint.valid?.should be_false
      errors = endpoint.validate
      # Descriptor, Identify and Groups are all missing
      errors.size.should eq(3)
      errors.any?(&.includes?("0x001d")).should be_true
      errors.any?(&.includes?("0x0003")).should be_true
      errors.any?(&.includes?("0x0004")).should be_true
      errors.all?(&.includes?("On/Off Light")).should be_true
    end

    it "validates dimmable light endpoint" do
      endpoint = Matter::Endpoint.new(ENDPOINT_ID, Matter::DeviceType.dimmable_light)
      endpoint.add_cluster(Matter::Cluster::Descriptor.new(ENDPOINT_ID))
      on_off_light_clusters(endpoint)
      endpoint.add_cluster(Matter::Cluster::LevelControl.new(ENDPOINT_ID))

      endpoint.valid?.should be_true
    end

    it "accepts any cluster set for an endpoint with no device type" do
      endpoint = Matter::Endpoint.new(ENDPOINT_ID)
      endpoint.add_cluster(Matter::Cluster::OnOff.new(ENDPOINT_ID))

      endpoint.valid?.should be_true
    end
  end

  describe "description" do
    it "generates human-readable description" do
      endpoint = Matter::Endpoint.new(ENDPOINT_ID, Matter::DeviceType.on_off_light)
      endpoint.add_cluster(Matter::Cluster::OnOff.new(ENDPOINT_ID))

      description = endpoint.description
      description.should contain("Endpoint 1")
      description.should contain("On/Off Light")
      description.should contain("1 cluster")
    end
  end
end
