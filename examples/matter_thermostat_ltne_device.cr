require "./support/console"
require "./support/main"

# Synthetic thermostat whose sensor value drives Auto mode without exposing it.
module MatterThermostatLTNE
  class Device < Matter::Device
    include Examples::Console

    PRIVATE_TEMPERATURE = 3000_i16

    identity vendor: "Spider-Gazelle", product: "Crystal Private Thermostat",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: rand(Examples::RANDOM_PRODUCT_ID_RANGE),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::THERMOSTAT

    storage yaml: "matter_thermostat_ltne_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::THERMOSTAT do
      cluster Matter::Cluster::Identify, identify_type: :visible_led
      cluster Matter::Cluster::Groups
      cluster Matter::Cluster::Thermostat,
        feature_map: Matter::Cluster::Thermostat::Feature::Heating |
                     Matter::Cluster::Thermostat::Feature::Cooling |
                     Matter::Cluster::Thermostat::Feature::Automode |
                     Matter::Cluster::Thermostat::Feature::LocalTemperatureNotExposed,
        system_mode: :auto,
        as: :thermostat
    end

    protected def before_start : Nil
      thermostat.update_local_temperature(PRIVATE_TEMPERATURE)
      super
    end
  end
end

Examples.main("Crystal Private Thermostat") { MatterThermostatLTNE::Device.new }
