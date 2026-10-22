require "./support/console"
require "./support/main"

# Synthetic thermostat with a local display and keypad configuration.
module MatterThermostatUI
  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Crystal Thermostat UI",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: rand(0x0001_u16..0xFFFF_u16),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::THERMOSTAT

    storage yaml: "matter_thermostat_ui_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::THERMOSTAT do
      cluster Matter::Cluster::Identify, identify_type: :visible_led
      cluster Matter::Cluster::Groups
      cluster Matter::Cluster::Thermostat
      cluster Matter::Cluster::ThermostatUserInterfaceConfiguration
    end
  end
end

Examples.main("Crystal Thermostat UI") { MatterThermostatUI::Device.new }
