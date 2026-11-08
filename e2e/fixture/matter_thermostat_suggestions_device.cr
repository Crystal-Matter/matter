require "../../examples/support/console"
require "../../examples/support/main"

# Official chip-tool fixture for the normal Thermostat TSUGGEST profile.
module MatterThermostatSuggestionsFixture
  alias Thermostat = Matter::Cluster::Thermostat

  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Crystal Suggestions Thermostat",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: rand(0x0001_u16..0xFFFF_u16),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::THERMOSTAT

    storage yaml: "matter_thermostat_suggestions_storage.yml"

    endpoint 0, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Matter::Cluster::TimeSynchronization
    end

    endpoint 1, device_type: Matter::DeviceType::THERMOSTAT do
      cluster Matter::Cluster::Identify, identify_type: :visible_led
      cluster Matter::Cluster::Groups
      cluster Thermostat,
        feature_map: Thermostat::Feature::Heating | Thermostat::Feature::Cooling |
                     Thermostat::Feature::Presets | Thermostat::Feature::ThermostatSuggestions,
        use_root_utc_time: true,
        preset_types: [
          Thermostat::PresetType.new(Thermostat::PresetScenario::Sleep, 1_u8),
          Thermostat::PresetType.new(Thermostat::PresetScenario::Wake, 1_u8),
        ],
        presets: [
          Thermostat::Preset.new(Bytes[1_u8], Thermostat::PresetScenario::Sleep,
            nil, 2700_i16, 1900_i16, true),
          Thermostat::Preset.new(Bytes[2_u8], Thermostat::PresetScenario::Wake,
            nil, 2800_i16, 2100_i16, true),
        ],
        as: :thermostat
    end
  end
end

Examples.main("Crystal Suggestions Test Thermostat") { MatterThermostatSuggestionsFixture::Device.new }
