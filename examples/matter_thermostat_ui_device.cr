require "./support/console"
require "./support/main"

# Synthetic thermostat with a local display and keypad configuration.
module MatterThermostatUI
  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Crystal Thermostat UI",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: rand(Examples::RANDOM_PRODUCT_ID_RANGE),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::THERMOSTAT

    storage yaml: "matter_thermostat_ui_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::THERMOSTAT do
      cluster Matter::Cluster::Identify, identify_type: :visible_led
      cluster Matter::Cluster::Groups
      cluster Matter::Cluster::Thermostat
      cluster Matter::Cluster::ThermostatUserInterfaceConfiguration
      cluster Matter::Cluster::EnergyPreference,
        feature_map: Matter::Cluster::EnergyPreference::Feature::EnergyBalance |
                     Matter::Cluster::EnergyPreference::Feature::LowPowerModeSensitivity,
        energy_balances: [
          Matter::Cluster::EnergyPreference::Balance.new(0_u8, "Comfort"),
          Matter::Cluster::EnergyPreference::Balance.new(50_u8, "Balanced"),
          Matter::Cluster::EnergyPreference::Balance.new(100_u8, "Efficient"),
        ],
        energy_priorities: [
          Matter::Cluster::EnergyPreference::EnergyPriority::Comfort,
          Matter::Cluster::EnergyPreference::EnergyPriority::Efficiency,
        ],
        low_power_mode_sensitivities: [
          Matter::Cluster::EnergyPreference::Balance.new(0_u8, "Conservative"),
          Matter::Cluster::EnergyPreference::Balance.new(100_u8, "Aggressive"),
        ]
    end
  end
end

Examples.main("Crystal Thermostat UI") { MatterThermostatUI::Device.new }
