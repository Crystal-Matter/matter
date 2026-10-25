require "../spec_helper"

private alias ScheduleThermostat = Matter::Cluster::Thermostat

private def schedule_type(mode = ScheduleThermostat::SystemMode::Heat,
                          features = ScheduleThermostat::ScheduleTypeFeatures::SupportsSetpoints,
                          capacity : UInt8 = 2_u8) : ScheduleThermostat::ScheduleType
  ScheduleThermostat::ScheduleType.new(mode, capacity, features)
end

private def schedule_transition(day : UInt8 = 0x02_u8, time : UInt16 = 480_u16,
                                heating : Int16? = 2100_i16) : ScheduleThermostat::ScheduleTransition
  ScheduleThermostat::ScheduleTransition.new(day, time, nil, nil, nil, heating)
end

private def configured_schedule(handle : Bytes = Bytes[1_u8], transitions = [schedule_transition]) : ScheduleThermostat::Schedule
  ScheduleThermostat::Schedule.new(handle, ScheduleThermostat::SystemMode::Heat,
    nil, nil, transitions, false)
end

describe "Thermostat Matter schedules foundation" do
  it "round-trips canonical ScheduleType, ScheduleTransition and Schedule TLV fields" do
    type = schedule_type
    ScheduleThermostat::ScheduleType.from_tlv(type.to_tlv).schedule_type_features.should eq(type.schedule_type_features)
    transition = schedule_transition
    ScheduleThermostat::ScheduleTransition.from_tlv(transition.to_tlv).transition_time.should eq(480_u16)
    schedule = configured_schedule
    decoded = ScheduleThermostat::Schedule.from_tlv(schedule.to_tlv)
    decoded.schedule_handle.should eq(Bytes[1_u8])
    decoded.transitions.first.heating_setpoint.should eq(2100_i16)
  end

  it "keeps MSCH unadvertised while accepting validated host schedules" do
    feature = ScheduleThermostat::Feature::Heating | ScheduleThermostat::Feature::MatterSchedules
    expect_raises(ArgumentError) { build(ScheduleThermostat, feature_map: feature) }
    cluster = build(ScheduleThermostat, feature_map: ScheduleThermostat::Feature::Heating)
    cluster.get_attribute_metadata(0x49_u32).should be_nil
    cluster.get_command_metadata(0x05_u32).should be_nil
    cluster.configure_schedules([schedule_type], [configured_schedule], 4_u8, 2_u8)
    cluster.number_of_schedules.should eq(2_u8)
    cluster.schedules.first.transitions.first.heating_setpoint.should eq(2100_i16)
    cluster.schedules.first.transitions.clear
    cluster.schedules.first.transitions.size.should eq(1)
  end

  it "rejects duplicate modes, overlapping transitions and invalid per-day capacity" do
    cluster = build(ScheduleThermostat, feature_map: ScheduleThermostat::Feature::Heating)
    expect_raises(ArgumentError) do
      cluster.configure_schedules([schedule_type, schedule_type], [] of ScheduleThermostat::Schedule, 4_u8, 2_u8)
    end
    overlaps = [schedule_transition(0x02_u8, 480_u16), schedule_transition(0x03_u8, 480_u16)]
    expect_raises(ArgumentError) do
      cluster.configure_schedules([schedule_type], [configured_schedule(transitions: overlaps)], 4_u8, 2_u8)
    end
    too_many = [schedule_transition(0x02_u8, 480_u16), schedule_transition(0x02_u8, 600_u16)]
    expect_raises(ArgumentError) do
      cluster.configure_schedules([schedule_type], [configured_schedule(transitions: too_many)], 4_u8, 1_u8)
    end
    cluster.schedules.should be_empty
  end

  it "validates modes, preset references, names and setpoint limits" do
    cluster = build(ScheduleThermostat, feature_map: ScheduleThermostat::Feature::Heating)
    expect_raises(ArgumentError) do
      cluster.configure_schedules([schedule_type(ScheduleThermostat::SystemMode::Off)],
        [] of ScheduleThermostat::Schedule, 4_u8, nil)
    end
    bad_setpoint = configured_schedule(transitions: [schedule_transition(heating: 4000_i16)])
    expect_raises(ArgumentError) { cluster.configure_schedules([schedule_type], [bad_setpoint], 4_u8, nil) }
    bad_preset = ScheduleThermostat::Schedule.new(Bytes[2_u8], ScheduleThermostat::SystemMode::Heat,
      nil, Bytes[3_u8], [schedule_transition], false)
    expect_raises(ArgumentError) { cluster.configure_schedules([schedule_type], [bad_preset], 4_u8, nil) }
    named = ScheduleThermostat::Schedule.new(Bytes[2_u8], ScheduleThermostat::SystemMode::Heat,
      "Wake", nil, [schedule_transition], false)
    expect_raises(ArgumentError) { cluster.configure_schedules([schedule_type], [named], 4_u8, nil) }
  end

  it "persists schedules and never reuses a removed schedule handle" do
    cluster = build(ScheduleThermostat, feature_map: ScheduleThermostat::Feature::Heating)
    types = [schedule_type]
    cluster.configure_schedules(types, [configured_schedule], 4_u8, nil)
    cluster.configure_schedules(types, [] of ScheduleThermostat::Schedule, 4_u8, nil)
    restored = build(ScheduleThermostat, feature_map: ScheduleThermostat::Feature::Heating)
    restored.configure_schedules(types, [] of ScheduleThermostat::Schedule, 4_u8, nil)
    restored.restore_state(cluster.save_state)
    expect_raises(ArgumentError) { restored.configure_schedules(types, [configured_schedule], 4_u8, nil) }
    restored.configure_schedules(types, [configured_schedule(Bytes[2_u8])], 4_u8, nil)
    restored.schedules.first.schedule_handle.should eq(Bytes[2_u8])
  end

  it "rejects invalid transition fields without replacing an existing schedule" do
    cluster = build(ScheduleThermostat, feature_map: ScheduleThermostat::Feature::Heating)
    types = [schedule_type]
    original = configured_schedule
    cluster.configure_schedules(types, [original], 4_u8, nil)

    invalid = [
      schedule_transition(0_u8),
      schedule_transition(0x80_u8),
      schedule_transition(time: 1440_u16),
      ScheduleThermostat::ScheduleTransition.new(0x02_u8, 480_u16, nil,
        ScheduleThermostat::SystemMode::Heat, nil, 2100_i16),
      ScheduleThermostat::ScheduleTransition.new(0x02_u8, 480_u16, nil,
        ScheduleThermostat::SystemMode::Off, nil, nil),
      ScheduleThermostat::ScheduleTransition.new(0x02_u8, 480_u16, nil, nil, 2000_i16, 2100_i16),
    ]
    invalid.each do |transition|
      expect_raises(ArgumentError) do
        cluster.configure_schedules(types, [configured_schedule(transitions: [transition])], 4_u8, nil)
      end
      cluster.schedules.should eq([original])
    end
  end

  it "preserves built-in schedules and rejects type capacities without setpoint support" do
    cluster = build(ScheduleThermostat, feature_map: ScheduleThermostat::Feature::Heating)
    types = [schedule_type]
    built_in = ScheduleThermostat::Schedule.new(Bytes[1_u8], ScheduleThermostat::SystemMode::Heat,
      nil, nil, [schedule_transition], true)
    cluster.configure_schedules(types, [built_in], 4_u8, nil)
    expect_raises(ArgumentError) do
      cluster.configure_schedules(types, [] of ScheduleThermostat::Schedule, 4_u8, nil)
    end
    expect_raises(ArgumentError) do
      cluster.configure_schedules(types, [configured_schedule], 4_u8, nil)
    end
    cluster.schedules.should eq([built_in])
    unsupported = schedule_type(features: ScheduleThermostat::ScheduleTypeFeatures::None)
    expect_raises(ArgumentError) do
      cluster.configure_schedules([unsupported], [built_in], 4_u8, nil)
    end
    zero_capacity = schedule_type(capacity: 0_u8)
    expect_raises(ArgumentError) do
      cluster.configure_schedules([zero_capacity], [built_in], 4_u8, nil)
    end
  end
end
