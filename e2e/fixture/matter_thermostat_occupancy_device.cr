require "../../examples/support/console"
require "../../examples/support/main"

# Certification fixture only: production Thermostat rejects OCC until its
# remaining wire conformance checks are completed.
module MatterThermostatOccupancyFixture
  alias Thermostat = Matter::Cluster::Thermostat

  class WireThermostat < Thermostat
    protected def occupancy_wire_ready? : Bool
      true
    end
  end

  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Crystal Occupancy Test Thermostat",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: rand(0x0001_u16..0xFFFF_u16),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::THERMOSTAT

    storage yaml: "matter_thermostat_occupancy_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::THERMOSTAT do
      cluster Matter::Cluster::Identify, identify_type: :visible_led
      cluster Matter::Cluster::Groups
      cluster WireThermostat,
        feature_map: Thermostat::Feature::Heating | Thermostat::Feature::Cooling |
                     Thermostat::Feature::Occupancy | Thermostat::Feature::Events,
        occupancy: 0_u8,
        as: :thermostat
    end
  end
end

Examples.main("Crystal Occupancy Test Thermostat") { MatterThermostatOccupancyFixture::Device.new }
