require "./spec_helper"
require "../src/matter/device_type"

describe Matter::DeviceType do
  describe "constants" do
    it "defines common device types" do
      Matter::DeviceType::ON_OFF_LIGHT.should eq(0x0100_u32)
      Matter::DeviceType::DIMMABLE_LIGHT.should eq(0x0101_u32)
      Matter::DeviceType::ON_OFF_PLUG_IN_UNIT.should eq(0x010A_u32)
      Matter::DeviceType::THERMOSTAT.should eq(0x0301_u32)
      Matter::DeviceType::DOOR_LOCK.should eq(0x000A_u32)
      Matter::DeviceType::CONTACT_SENSOR.should eq(0x0015_u32)
    end

    it "defines utility device types" do
      Matter::DeviceType::ROOT_NODE.should eq(0x0016_u32)
      Matter::DeviceType::POWER_SOURCE.should eq(0x0011_u32)
      Matter::DeviceType::OTA_REQUESTOR.should eq(0x0012_u32)
    end

    it "matches the ids carried by the factory device types" do
      Matter::DeviceType.root_node.device_type_id.id.should eq(Matter::DeviceType::ROOT_NODE)
      Matter::DeviceType.on_off_light.device_type_id.id.should eq(Matter::DeviceType::ON_OFF_LIGHT)
      Matter::DeviceType.thermostat.device_type_id.id.should eq(Matter::DeviceType::THERMOSTAT)
    end
  end

  describe "definitions" do
    it "creates root node device type" do
      device_type = Matter::DeviceType.root_node

      device_type.device_type_id.id.should eq(0x0016_u32)
      device_type.name.should eq("Root Node")
      device_type.revision.should eq(1_u16)
      device_type.required_server_clusters.should_not be_empty
      device_type.requires_cluster?(0x001D_u32).should be_true # Descriptor
      device_type.requires_cluster?(0x0028_u32).should be_true # Basic Information
    end

    it "creates on/off light device type" do
      device_type = Matter::DeviceType.on_off_light

      device_type.device_type_id.id.should eq(0x0100_u32)
      device_type.name.should eq("On/Off Light")
      device_type.revision.should eq(2_u16)
      device_type.requires_cluster?(0x001D_u32).should be_true          # Descriptor
      device_type.requires_cluster?(0x0003_u32).should be_true          # Identify
      device_type.requires_cluster?(0x0004_u32).should be_true          # Groups
      device_type.requires_cluster?(0x0006_u32).should be_true          # On/Off
      device_type.supports_optional_cluster?(0x0062_u32).should be_true # Scenes Management
      device_type.supports_optional_cluster?(0x0008_u32).should be_true # Level Control
    end

    it "creates dimmable light device type" do
      device_type = Matter::DeviceType.dimmable_light

      device_type.device_type_id.id.should eq(0x0101_u32)
      device_type.name.should eq("Dimmable Light")
      device_type.requires_cluster?(0x0006_u32).should be_true # On/Off
      device_type.requires_cluster?(0x0008_u32).should be_true # Level Control
    end

    it "defines the Matter 1.6 Air Quality Sensor concentration endpoints" do
      device_type = Matter::DeviceType.air_quality_sensor

      device_type.device_type_id.id.should eq(0x002C_u32)
      device_type.revision.should eq(1_u16)
      device_type.requires_cluster?(0x0003_u32).should be_true
      device_type.requires_cluster?(0x005B_u32).should be_true
      [0x040C_u32, 0x040D_u32, 0x0413_u32, 0x0415_u32, 0x042A_u32,
       0x042B_u32, 0x042C_u32, 0x042D_u32, 0x042E_u32, 0x042F_u32].each do |id|
        device_type.supports_optional_cluster?(id).should be_true
      end
    end

    it "defines the Matter 1.6 Soil Sensor with required soil measurement" do
      device_type = Matter::DeviceType.for(Matter::DeviceType::SOIL_SENSOR)

      device_type.name.should eq("Soil Sensor")
      device_type.revision.should eq(1_u16)
      device_type.requires_cluster?(0x0003_u32).should be_true
      device_type.requires_cluster?(0x0430_u32).should be_true
      device_type.supports_optional_cluster?(0x0402_u32).should be_true
    end

    it "defines the Matter 1.6 Microwave Oven with its required clusters and countdown" do
      device_type = Matter::DeviceType.for(Matter::DeviceType::MICROWAVE_OVEN)

      device_type.name.should eq("Microwave Oven")
      device_type.revision.should eq(2_u16)
      device_type.required_server_clusters.should eq([0x001D_u32, 0x0060_u32, 0x005E_u32, 0x005F_u32])
      device_type.required_server_attributes[0x0060_u32].should eq([0x0002_u32])
      device_type.supports_optional_cluster?(0x0003_u32).should be_true
      device_type.supports_optional_cluster?(0x0202_u32).should be_true
    end

    it "checks cluster requirements" do
      device_type = Matter::DeviceType.on_off_light

      device_type.requires_cluster?(0x0006_u32).should be_true
      device_type.requires_cluster?(0x9999_u32).should be_false

      device_type.supports_optional_cluster?(0x0008_u32).should be_true
      device_type.supports_optional_cluster?(0x9999_u32).should be_false

      device_type.allows_cluster?(0x0006_u32).should be_true  # Required
      device_type.allows_cluster?(0x0008_u32).should be_true  # Optional
      device_type.allows_cluster?(0x9999_u32).should be_false # Neither
    end

    it "creates custom device types" do
      device_type = Matter::DeviceType.new(
        Matter::DataType::DeviceTypeId.new(0x1234_u32),
        "Custom Device",
        1_u16,
        required_server_clusters: [0x0006_u32],
        optional_server_clusters: [0x0008_u32]
      )

      device_type.device_type_id.id.should eq(0x1234_u32)
      device_type.name.should eq("Custom Device")
      device_type.requires_cluster?(0x0006_u32).should be_true
      device_type.supports_optional_cluster?(0x0008_u32).should be_true
    end
  end

  describe ".for" do
    it "returns the definition of a known device type" do
      device_type = Matter::DeviceType.for(Matter::DeviceType::ON_OFF_LIGHT)

      device_type.device_type_id.id.should eq(Matter::DeviceType::ON_OFF_LIGHT)
      device_type.revision.should eq(Matter::DeviceType.on_off_light.revision)
      device_type.required_server_clusters.should eq(Matter::DeviceType.on_off_light.required_server_clusters)
    end

    it "names an unknown device type it has no definition for" do
      device_type = Matter::DeviceType.for(Matter::DeviceType::HUMIDITY_SENSOR)

      device_type.device_type_id.id.should eq(Matter::DeviceType::HUMIDITY_SENSOR)
      device_type.name.should eq("Humidity Sensor")
      device_type.revision.should eq(Matter::DeviceType::UNKNOWN_REVISION)
      device_type.required_server_clusters.should be_empty
    end

    it "falls back to the id for a device type with no name" do
      device_type = Matter::DeviceType.for(0xFFFF_FFFF_u32)

      device_type.name.should eq("Device Type 0xffffffff")
      device_type.required_server_clusters.should be_empty
    end
  end

  describe ".name" do
    it "returns device type names" do
      Matter::DeviceType.name(Matter::DeviceType::ON_OFF_LIGHT).should eq("On/Off Light")
      Matter::DeviceType.name(Matter::DeviceType::DIMMABLE_LIGHT).should eq("Dimmable Light")
      Matter::DeviceType.name(Matter::DeviceType::THERMOSTAT).should eq("Thermostat")
      Matter::DeviceType.name(Matter::DeviceType::DOOR_LOCK).should eq("Door Lock")
      Matter::DeviceType.name(Matter::DeviceType::CONTACT_SENSOR).should eq("Contact Sensor")
    end

    it "agrees with the factory device type names" do
      Matter::DeviceType.name(Matter::DeviceType::ROOT_NODE).should eq(Matter::DeviceType.root_node.name)
      Matter::DeviceType.name(Matter::DeviceType::FAN).should eq(Matter::DeviceType.fan.name)
    end

    it "returns nil for unknown device types" do
      Matter::DeviceType.name(0xFFFF_FFFF_u32).should be_nil
    end
  end
end
