require "../../examples/support/console"
require "../../examples/support/main"

# Official chip-tool fixture for the normal Thermostat TSUGGEST profile.
module MatterThermostatSuggestionArbitrationFixture
  alias Thermostat = Matter::Cluster::Thermostat

  class WireThermostat < Thermostat
    CLOCK_PATH = "/e2e/logs/matter_thermostat_suggestion_arbitration.clock"

    def self.local_time : Time?
      seconds = File.read(CLOCK_PATH).strip.to_i64? if File.exists?(CLOCK_PATH)
      seconds.try { |value| Time.unix(value) }
    end

    def initialize(endpoint_id : Matter::DataType::EndpointNumber, feature_map : Feature)
      presets = [
        Preset.new(Bytes[1_u8], PresetScenario::Sleep, nil, nil, 1900_i16, false),
        Preset.new(Bytes[2_u8], PresetScenario::Wake, nil, nil, 2100_i16, false),
      ]
      transitions = [
        ScheduleTransition.new(0x02_u8, 480_u16, Bytes[2_u8], nil, nil, nil),
        ScheduleTransition.new(0x02_u8, 540_u16, Bytes[1_u8], nil, nil, nil),
      ]
      schedule = Schedule.new(Bytes[3_u8], SystemMode::Heat, nil, nil, transitions, false)
      super(endpoint_id, feature_map: feature_map,
        preset_types: [
          PresetType.new(PresetScenario::Sleep, 1_u8),
          PresetType.new(PresetScenario::Wake, 1_u8),
        ], presets: presets,
        schedule_types: [ScheduleType.new(SystemMode::Heat, 1_u8, ScheduleTypeFeatures::SupportsPresets)],
        schedules: [schedule], schedule_max_transitions: 2_u8, schedule_max_per_day: 2_u8,
        local_time_provider: -> : Time? { WireThermostat.local_time },
        use_root_utc_time: true)
    end
  end

  class Device < Matter::Device
    include Examples::Console

    OCCUPANCY_PATH = "/e2e/logs/matter_thermostat_suggestion_arbitration.occupancy"

    identity vendor: "Spider-Gazelle", product: "Crystal Suggestion Thermostat",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: rand(0x0001_u16..0xFFFF_u16),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::THERMOSTAT

    storage yaml: "matter_thermostat_suggestion_arbitration_storage.yml"

    endpoint 0, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Matter::Cluster::TimeSynchronization
    end

    endpoint 1, device_type: Matter::DeviceType::THERMOSTAT do
      cluster Matter::Cluster::Identify, identify_type: :visible_led
      cluster Matter::Cluster::Groups
      cluster WireThermostat,
        feature_map: Thermostat::Feature::Heating | Thermostat::Feature::Occupancy |
                     Thermostat::Feature::MatterSchedules | Thermostat::Feature::Presets |
                     Thermostat::Feature::ThermostatSuggestions,
        as: :thermostat
    end

    protected def on_started : Nil
      super
      every(1.second) do
        value = File.exists?(OCCUPANCY_PATH) && File.read(OCCUPANCY_PATH).strip == "0" ? 0_u8 : 1_u8
        thermostat.occupancy = value if thermostat.occupancy != value
      end
    end
  end
end

Examples.main("Crystal Suggestion Arbitration Test Thermostat") do
  MatterThermostatSuggestionArbitrationFixture::Device.new
end
