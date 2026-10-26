require "../../examples/support/console"
require "../../examples/support/main"

module MatterThermostatBaseRevisionFixture
  alias Thermostat = Matter::Cluster::Thermostat

  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Crystal Base Thermostat",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: rand(0x0001_u16..0xFFFF_u16),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::THERMOSTAT

    storage yaml: "matter_thermostat_base_revision_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::THERMOSTAT do
      cluster Matter::Cluster::Identify, identify_type: :visible_led
      cluster Matter::Cluster::Groups
      cluster Thermostat, feature_map: Thermostat::Feature::Heating
    end

    endpoint 2, device_type: Matter::DeviceType::THERMOSTAT do
      cluster Matter::Cluster::Identify, identify_type: :visible_led
      cluster Matter::Cluster::Groups
      cluster Thermostat, feature_map: Thermostat::Feature::Cooling
    end

    endpoint 3, device_type: Matter::DeviceType::THERMOSTAT do
      cluster Matter::Cluster::Identify, identify_type: :visible_led
      cluster Matter::Cluster::Groups
      cluster Thermostat, feature_map: Thermostat::Feature::Heating |
                                       Thermostat::Feature::Cooling |
                                       Thermostat::Feature::Automode
    end
  end
end

Examples.main("Crystal Base Thermostat") { MatterThermostatBaseRevisionFixture::Device.new }
