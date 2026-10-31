require "../../examples/support/console"
require "../../examples/support/main"

# The fixture supplies local civil time from a host-owned clock file. A real
# device should supply its timezone-aware local clock through the same API.
module MatterThermostatSchedulesFixture
  alias Thermostat = Matter::Cluster::Thermostat

  class ScheduledThermostat < Thermostat
    FIXTURE_TIME = Time.utc(2026, 10, 26, 8, 30)
    CLOCK_PATH   = ENV["MATTER_THERMOSTAT_CLOCK_PATH"]? || "/e2e/logs/matter_thermostat_schedules.clock"

    def self.local_time : Time?
      return FIXTURE_TIME unless File.exists?(CLOCK_PATH)
      seconds = File.read(CLOCK_PATH).strip.to_i64?
      seconds.try { |value| Time.unix(value) }
    end

    def initialize(endpoint_id : Matter::DataType::EndpointNumber, feature_map : Feature)
      type = ScheduleType.new(SystemMode::Heat, 1_u8,
        ScheduleTypeFeatures::SupportsSetpoints)
      transition = ScheduleTransition.new(0x02_u8, 480_u16, nil, nil, nil, 1900_i16)
      schedule = Schedule.new(Bytes[1_u8], SystemMode::Heat, nil, nil,
        [transition], false)
      super(endpoint_id, feature_map: feature_map,
        schedule_types: [type], schedules: [schedule], schedule_max_transitions: 2_u8,
        schedule_max_per_day: 2_u8,
        local_time_provider: -> : Time? { ScheduledThermostat.local_time })
    end
  end

  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Crystal Schedules Thermostat",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: rand(0x0001_u16..0xFFFF_u16),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::THERMOSTAT

    storage yaml: "matter_thermostat_schedules_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::THERMOSTAT do
      cluster Matter::Cluster::Identify, identify_type: :visible_led
      cluster Matter::Cluster::Groups
      cluster ScheduledThermostat,
        feature_map: Thermostat::Feature::Heating | Thermostat::Feature::MatterSchedules |
                     Thermostat::Feature::Events,
        as: :thermostat
    end
  end
end

Examples.main("Crystal Schedules Test Thermostat") { MatterThermostatSchedulesFixture::Device.new }
