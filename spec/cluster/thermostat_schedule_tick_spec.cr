require "../spec_helper"

private alias TickThermostat = Matter::Cluster::Thermostat

private class TickWireReadyThermostat < TickThermostat
  protected def preset_wire_ready? : Bool
    true
  end
end

private def tick_transition(day : UInt8, minute : UInt16, heating : Int16? = 2100_i16,
                            mode : TickThermostat::SystemMode? = nil,
                            preset : Bytes? = nil) : TickThermostat::ScheduleTransition
  TickThermostat::ScheduleTransition.new(day, minute, preset, mode, nil, heating)
end

private def tick_schedule(transitions : Array(TickThermostat::ScheduleTransition),
                          preset : Bytes? = nil) : TickThermostat::Schedule
  TickThermostat::Schedule.new(Bytes[1_u8], TickThermostat::SystemMode::Heat,
    nil, preset, transitions, false)
end

private def tick_cluster(transitions : Array(TickThermostat::ScheduleTransition),
                         *, features = TickThermostat::Feature::Heating | TickThermostat::Feature::MatterSchedules,
                         type_features = TickThermostat::ScheduleTypeFeatures::SupportsSetpoints,
                         preset : Bytes? = nil,
                         clock : Proc(Time?) = -> : Time? { nil }) : TickWireReadyThermostat
  type = TickThermostat::ScheduleType.new(TickThermostat::SystemMode::Heat, 1_u8, type_features)
  build(TickWireReadyThermostat, feature_map: features,
    schedule_types: [type], schedules: [tick_schedule(transitions, preset)],
    schedule_max_transitions: 4_u8, schedule_max_per_day: 3_u8,
    local_time_provider: clock)
end

describe "Thermostat MSCH timed schedule activation" do
  it "selects the latest weekly transition across midnight in the supplied local timezone" do
    zone = Time::Location.fixed(10 * 3600)
    sunday = tick_transition(0x01_u8, 18_u16 * 60, 1800_i16)
    monday = tick_transition(0x02_u8, 8_u16 * 60, 2100_i16)
    cluster = tick_cluster([sunday, monday])
    cluster.activate_schedule(TickThermostat::SetActiveScheduleRequest.new(Bytes[1_u8])).status.should eq(
      Matter::InteractionModel::StatusCode::Success)

    cluster.tick_schedule(Time.local(2026, 10, 26, 0, 30, location: zone)).should be_true
    cluster.occupied_heating_setpoint.should eq(1800_i16)
    cluster.tick_schedule(Time.local(2026, 10, 26, 7, 59, location: zone)).should be_false
    cluster.tick_schedule(Time.local(2026, 10, 26, 8, 0, location: zone)).should be_true
    cluster.occupied_heating_setpoint.should eq(2100_i16)
    cluster.tick_schedule(Time.local(2026, 10, 27, 12, 0, location: zone)).should be_false
  end

  it "applies a new occurrence once and only reports attributes that actually change" do
    monday = tick_transition(0x02_u8, 8_u16 * 60, 2100_i16)
    cluster = tick_cluster([monday], features: TickThermostat::Feature::Heating |
                                               TickThermostat::Feature::MatterSchedules | TickThermostat::Feature::Events)
    changed = [] of UInt32
    cluster.on_attribute_changed = ->(_ep : UInt16, _cl : UInt32, attr : UInt32) {
      changed << attr
      nil
    }
    cluster.activate_schedule(TickThermostat::SetActiveScheduleRequest.new(Bytes[1_u8]))
    changed.clear
    monday_at_eight = Time.utc(2026, 10, 26, 8, 0)
    cluster.tick_schedule(monday_at_eight).should be_true
    cluster.tick_schedule(monday_at_eight + 1.minute).should be_false
    changed.count(TickThermostat::ATTR_OCCUPIED_HEATING_SETPOINT).should eq(1)
    cluster.tick_schedule(monday_at_eight + 7.days).should be_true
    changed.count(TickThermostat::ATTR_OCCUPIED_HEATING_SETPOINT).should eq(1)
  end

  it "does not apply a transition without local time and resumes after time returns" do
    current = nil.as(Time?)
    clock = -> : Time? { current }
    cluster = tick_cluster([tick_transition(0x02_u8, 8_u16 * 60)], clock: clock)
    cluster.activate_schedule(TickThermostat::SetActiveScheduleRequest.new(Bytes[1_u8]))
    cluster.occupied_heating_setpoint.should eq(TickThermostat::DEFAULT_HEATING_SETPOINT)
    cluster.tick_schedule.should be_false
    current = Time.utc(2026, 10, 26, 8, 30)
    cluster.tick_schedule.should be_true
    cluster.occupied_heating_setpoint.should eq(2100_i16)
    current = nil
    cluster.tick_schedule.should be_false
    cluster.occupied_heating_setpoint = 1900_i16
    current = Time.utc(2026, 10, 26, 8, 31)
    cluster.tick_schedule.should be_true
    cluster.occupied_heating_setpoint.should eq(2100_i16)
  end

  it "applies schedule presets and later mode transitions without repeating changes" do
    preset_handle = Bytes[7_u8]
    features = TickThermostat::Feature::Heating | TickThermostat::Feature::MatterSchedules |
               TickThermostat::Feature::Presets
    on = tick_transition(0x02_u8, 8_u16 * 60, nil, preset: preset_handle)
    off = tick_transition(0x02_u8, 20_u16 * 60, 2200_i16, TickThermostat::SystemMode::Off)
    type_features = TickThermostat::ScheduleTypeFeatures::SupportsPresets |
                    TickThermostat::ScheduleTypeFeatures::SupportsSetpoints |
                    TickThermostat::ScheduleTypeFeatures::SupportsOff
    preset_type = TickThermostat::PresetType.new(TickThermostat::PresetScenario::Wake, 1_u8)
    preset = TickThermostat::Preset.new(preset_handle, TickThermostat::PresetScenario::Wake,
      nil, nil, 2200_i16, false)
    schedule_type = TickThermostat::ScheduleType.new(TickThermostat::SystemMode::Heat, 1_u8, type_features)
    cluster = build(TickWireReadyThermostat, feature_map: features,
      preset_types: [preset_type], presets: [preset],
      schedule_types: [schedule_type], schedules: [tick_schedule([on, off])],
      schedule_max_transitions: 4_u8, schedule_max_per_day: 3_u8,
      local_time_provider: -> : Time? { nil })
    cluster.activate_schedule(TickThermostat::SetActiveScheduleRequest.new(Bytes[1_u8]))

    cluster.tick_schedule(Time.utc(2026, 10, 26, 8, 0)).should be_true
    cluster.occupied_heating_setpoint.should eq(2200_i16)
    cluster.active_preset_handle.should eq(preset_handle)
    cluster.system_mode.should eq(TickThermostat::SystemMode::Heat)
    cluster.tick_schedule(Time.utc(2026, 10, 26, 20, 0)).should be_true
    cluster.system_mode.should eq(TickThermostat::SystemMode::Off)
    cluster.active_preset_handle.should be_nil
    cluster.tick_schedule(Time.utc(2026, 10, 26, 20, 1)).should be_false
  end

  it "re-evaluates the active transition after persisted state is restored" do
    cluster = tick_cluster([tick_transition(0x02_u8, 8_u16 * 60)])
    cluster.activate_schedule(TickThermostat::SetActiveScheduleRequest.new(Bytes[1_u8]))
    now = Time.utc(2026, 10, 26, 8, 0)
    cluster.tick_schedule(now).should be_true
    restored = tick_cluster([tick_transition(0x02_u8, 8_u16 * 60)])
    restored.restore_state(cluster.save_state)
    restored.occupied_heating_setpoint.should eq(2100_i16)
    restored.tick_schedule(now).should be_true
    restored.tick_schedule(now).should be_false
  end

  it "applies immediately when the host clock is known and refreshes an edited active schedule" do
    now = Time.utc(2026, 10, 26, 8, 30)
    cluster = tick_cluster([tick_transition(0x02_u8, 8_u16 * 60)],
      clock: -> : Time? { now })
    cluster.activate_schedule(TickThermostat::SetActiveScheduleRequest.new(Bytes[1_u8]))
    cluster.occupied_heating_setpoint.should eq(2100_i16)
    cluster.tick_schedule.should be_false

    edited = tick_schedule([tick_transition(0x02_u8, 8_u16 * 60, 2300_i16)])
    cluster.configure_schedules(cluster.schedule_types, [edited], 4_u8, 3_u8)
    cluster.tick_schedule.should be_true
    cluster.occupied_heating_setpoint.should eq(2300_i16)
  end

  it "preserves the Auto deadband for a single heat transition and refuses an impossible correction" do
    features = TickThermostat::Feature::Heating | TickThermostat::Feature::Cooling |
               TickThermostat::Feature::Automode | TickThermostat::Feature::MatterSchedules
    cluster = tick_cluster([tick_transition(0x02_u8, 8_u16 * 60, 2500_i16)], features: features)
    cluster.activate_schedule(TickThermostat::SetActiveScheduleRequest.new(Bytes[1_u8]))
    now = Time.utc(2026, 10, 26, 8, 0)
    cluster.tick_schedule(now).should be_true
    cluster.occupied_heating_setpoint.should eq(2500_i16)
    cluster.occupied_cooling_setpoint.should eq(2750_i16)

    impossible = tick_schedule([tick_transition(0x02_u8, 8_u16 * 60, 3000_i16)])
    cluster.configure_schedules(cluster.schedule_types, [impossible], 4_u8, 3_u8)
    cluster.tick_schedule(now).should be_false
    cluster.occupied_heating_setpoint.should eq(2500_i16)
    cluster.occupied_cooling_setpoint.should eq(2750_i16)
  end

  it "uses a schedule's default preset until a direct transition overrides it" do
    preset_handle = Bytes[7_u8]
    features = TickThermostat::Feature::Heating | TickThermostat::Feature::MatterSchedules |
               TickThermostat::Feature::Presets
    type_features = TickThermostat::ScheduleTypeFeatures::SupportsPresets |
                    TickThermostat::ScheduleTypeFeatures::SupportsSetpoints
    preset_type = TickThermostat::PresetType.new(TickThermostat::PresetScenario::Wake, 1_u8)
    preset = TickThermostat::Preset.new(preset_handle, TickThermostat::PresetScenario::Wake,
      nil, nil, 2200_i16, false)
    morning = tick_transition(0x02_u8, 8_u16 * 60, nil)
    evening = tick_transition(0x02_u8, 20_u16 * 60, 1900_i16)
    schedule_type = TickThermostat::ScheduleType.new(TickThermostat::SystemMode::Heat, 1_u8, type_features)
    cluster = build(TickWireReadyThermostat, feature_map: features,
      preset_types: [preset_type], presets: [preset],
      schedule_types: [schedule_type], schedules: [tick_schedule([morning, evening], preset_handle)],
      schedule_max_transitions: 4_u8, schedule_max_per_day: 3_u8,
      local_time_provider: -> : Time? { nil })
    cluster.activate_schedule(TickThermostat::SetActiveScheduleRequest.new(Bytes[1_u8]))

    cluster.tick_schedule(Time.utc(2026, 10, 26, 8, 0)).should be_true
    cluster.occupied_heating_setpoint.should eq(2200_i16)
    cluster.active_preset_handle.should eq(preset_handle)
    cluster.tick_schedule(Time.utc(2026, 10, 26, 20, 0)).should be_true
    cluster.occupied_heating_setpoint.should eq(1900_i16)
    cluster.active_preset_handle.should be_nil
  end

  it "does not replay earlier transitions during a repeated daylight-saving hour" do
    early = tick_transition(0x01_u8, 60_u16, 1800_i16)
    late = tick_transition(0x01_u8, 90_u16, 2100_i16)
    cluster = tick_cluster([early, late])
    cluster.activate_schedule(TickThermostat::SetActiveScheduleRequest.new(Bytes[1_u8]))

    before_fallback = Time.local(2026, 11, 1, 1, 31,
      location: Time::Location.fixed(-4 * 3600))
    after_fallback = Time.local(2026, 11, 1, 1, 10,
      location: Time::Location.fixed(-5 * 3600))
    repeated_late = Time.local(2026, 11, 1, 1, 31,
      location: Time::Location.fixed(-5 * 3600))
    cluster.tick_schedule(before_fallback).should be_true
    cluster.occupied_heating_setpoint.should eq(2100_i16)
    cluster.tick_schedule(after_fallback).should be_false
    cluster.tick_schedule(repeated_late).should be_false
    cluster.occupied_heating_setpoint.should eq(2100_i16)
  end

  it "does not inherit a parent preset when a transition specifies a direct setpoint" do
    preset_handle = Bytes[7_u8]
    features = TickThermostat::Feature::Heating | TickThermostat::Feature::Cooling |
               TickThermostat::Feature::MatterSchedules | TickThermostat::Feature::Presets
    preset_type = TickThermostat::PresetType.new(TickThermostat::PresetScenario::Wake, 1_u8)
    preset = TickThermostat::Preset.new(preset_handle, TickThermostat::PresetScenario::Wake,
      nil, 2700_i16, 2200_i16, false)
    type_features = TickThermostat::ScheduleTypeFeatures::SupportsPresets |
                    TickThermostat::ScheduleTypeFeatures::SupportsSetpoints
    transition = tick_transition(0x02_u8, 8_u16 * 60, 1900_i16)
    schedule_type = TickThermostat::ScheduleType.new(TickThermostat::SystemMode::Heat, 1_u8, type_features)
    cluster = build(TickWireReadyThermostat, feature_map: features,
      occupied_cooling_setpoint: 2800_i16,
      preset_types: [preset_type], presets: [preset],
      schedule_types: [schedule_type], schedules: [tick_schedule([transition], preset_handle)],
      schedule_max_transitions: 4_u8, schedule_max_per_day: 3_u8,
      local_time_provider: -> : Time? { nil })
    cluster.activate_schedule(TickThermostat::SetActiveScheduleRequest.new(Bytes[1_u8]))

    cluster.tick_schedule(Time.utc(2026, 10, 26, 8, 0)).should be_true
    cluster.occupied_heating_setpoint.should eq(1900_i16)
    cluster.occupied_cooling_setpoint.should eq(2800_i16)
    cluster.active_preset_handle.should be_nil
  end
end
