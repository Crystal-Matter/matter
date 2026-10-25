require "../../examples/support/console"
require "../../examples/support/main"

# Certification fixture only: production Thermostat rejects PRES while its
# remaining conformance checks are being completed.
module MatterThermostatPresetsFixture
  alias Thermostat = Matter::Cluster::Thermostat

  class WireThermostat < Thermostat
    protected def preset_wire_ready? : Bool
      true
    end

    protected def preset_wire_ready?(command_id : UInt32) : Bool
      true
    end
  end

  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Crystal Presets Test Thermostat",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: rand(0x0001_u16..0xFFFF_u16),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::THERMOSTAT

    storage yaml: "matter_thermostat_presets_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::THERMOSTAT do
      cluster Matter::Cluster::Identify, identify_type: :visible_led
      cluster Matter::Cluster::Groups
      cluster WireThermostat,
        feature_map: Thermostat::Feature::Heating | Thermostat::Feature::Cooling |
                     Thermostat::Feature::Presets | Thermostat::Feature::Events,
        preset_types: [Thermostat::PresetType.new(Thermostat::PresetScenario::Sleep, 2_u8)],
        presets: [Thermostat::Preset.new(Bytes[1_u8], Thermostat::PresetScenario::Sleep,
          nil, 2700_i16, 1800_i16, true)],
        as: :thermostat
    end
  end
end

Examples.main("Crystal Presets Test Thermostat") { MatterThermostatPresetsFixture::Device.new }
