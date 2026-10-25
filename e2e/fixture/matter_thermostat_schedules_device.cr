require "../../examples/support/console"
require "../../examples/support/main"

# Certification fixture only: production Thermostat keeps MSCH gated while
# its remaining wire conformance checks are completed.
module MatterThermostatSchedulesFixture
  alias Thermostat = Matter::Cluster::Thermostat

  class WireThermostat < Thermostat
    # Activation observes the Monday 08:00 transition without relying on the
    # runner's timezone, wall clock, or a background timer.
    FIXTURE_TIME = Time.utc(2026, 10, 26, 8, 30)

    def initialize(endpoint_id : Matter::DataType::EndpointNumber, feature_map : Feature)
      super(endpoint_id, feature_map: feature_map,
        local_time_provider: -> : Time? { FIXTURE_TIME })
      type = ScheduleType.new(SystemMode::Heat, 1_u8,
        ScheduleTypeFeatures::SupportsSetpoints)
      transition = ScheduleTransition.new(0x02_u8, 480_u16, nil, nil, nil, 1900_i16)
      schedule = Schedule.new(Bytes[1_u8], SystemMode::Heat, nil, nil,
        [transition], false)
      configure_schedules([type], [schedule], 2_u8, 2_u8)
    end

    protected def schedule_wire_ready? : Bool
      true
    end
  end

  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Crystal Schedules Test Thermostat",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: rand(0x0001_u16..0xFFFF_u16),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::THERMOSTAT

    storage yaml: "matter_thermostat_schedules_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::THERMOSTAT do
      cluster Matter::Cluster::Identify, identify_type: :visible_led
      cluster Matter::Cluster::Groups
      cluster WireThermostat,
        feature_map: Thermostat::Feature::Heating | Thermostat::Feature::MatterSchedules |
                     Thermostat::Feature::Events,
        as: :thermostat
    end
  end
end

Examples.main("Crystal Schedules Test Thermostat") { MatterThermostatSchedulesFixture::Device.new }
