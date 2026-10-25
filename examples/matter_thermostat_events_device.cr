require "./support/console"
require "./support/main"

# Opt-in thermostat exercising the Matter 1.6 TEVT event wire surface.
module MatterThermostatEvents
  class Device < Matter::Device
    include Examples::Console

    INITIAL_TEMPERATURE = 3000_i16

    identity vendor: "Spider-Gazelle", product: "Crystal Event Thermostat",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: rand(0x0001_u16..0xFFFF_u16),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::THERMOSTAT

    storage yaml: "matter_thermostat_events_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::THERMOSTAT do
      cluster Matter::Cluster::Identify, identify_type: :visible_led
      cluster Matter::Cluster::Groups
      cluster Matter::Cluster::Thermostat,
        feature_map: Matter::Cluster::Thermostat::Feature::Heating |
                     Matter::Cluster::Thermostat::Feature::Cooling |
                     Matter::Cluster::Thermostat::Feature::Automode |
                     Matter::Cluster::Thermostat::Feature::Events,
        as: :thermostat
    end

    protected def before_start : Nil
      thermostat.update_local_temperature(INITIAL_TEMPERATURE)
      super
    end
  end
end

Examples.main("Crystal Event Thermostat") { MatterThermostatEvents::Device.new }
