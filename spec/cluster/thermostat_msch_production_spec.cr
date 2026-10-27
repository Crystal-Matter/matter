require "../spec_helper"

private alias ProductionMSCH = Matter::Cluster::Thermostat

private def production_msch(clock : Proc(Time?)) : ProductionMSCH
  type = ProductionMSCH::ScheduleType.new(ProductionMSCH::SystemMode::Heat, 1_u8,
    ProductionMSCH::ScheduleTypeFeatures::SupportsSetpoints)
  transition = ProductionMSCH::ScheduleTransition.new(0x02_u8, 480_u16, nil, nil, nil, 1900_i16)
  schedule = ProductionMSCH::Schedule.new(Bytes[1_u8], ProductionMSCH::SystemMode::Heat,
    nil, nil, [transition], false)
  build(ProductionMSCH,
    feature_map: ProductionMSCH::Feature::Heating | ProductionMSCH::Feature::MatterSchedules |
                 ProductionMSCH::Feature::Events,
    schedule_types: [type], schedules: [schedule], schedule_max_transitions: 2_u8,
    schedule_max_per_day: 1_u8, local_time_provider: clock)
end

describe "Thermostat production MSCH" do
  it "requires an explicit host civil clock and configured schedule type before advertising MSCH" do
    expect_raises(ArgumentError) do
      build(ProductionMSCH, feature_map: ProductionMSCH::Feature::Heating |
                                         ProductionMSCH::Feature::MatterSchedules)
    end
    clock = -> : Time? { nil }
    expect_raises(ArgumentError, "schedule_types are required for MSCH") do
      build(ProductionMSCH,
        feature_map: ProductionMSCH::Feature::Heating | ProductionMSCH::Feature::MatterSchedules,
        local_time_provider: clock)
    end

    configured = production_msch(clock)
    configured.get_attribute_metadata(ProductionMSCH::ATTR_SCHEDULES).should_not be_nil
    configured.get_command_metadata(ProductionMSCH::CMD_SET_ACTIVE_SCHEDULE).should_not be_nil
    configured.get_command_metadata(ProductionMSCH::CMD_ATOMIC_REQUEST).should_not be_nil
    configured.schedule_polling_enabled?.should be_true
    [ProductionMSCH::ATTR_SCHEDULE_TYPES, ProductionMSCH::ATTR_NUMBER_OF_SCHEDULES,
     ProductionMSCH::ATTR_NUMBER_OF_SCHEDULE_TRANSITIONS,
     ProductionMSCH::ATTR_NUMBER_OF_SCHEDULE_TRANSITION_PER_DAY].each do |id|
      metadata = configured.get_attribute_metadata(id) || raise "missing MSCH capacity attribute"
      metadata.fixed?.should be_true
      metadata.optional?.should be_false
    end
    [ProductionMSCH::ATTR_ACTIVE_SCHEDULE_HANDLE, ProductionMSCH::ATTR_SCHEDULES].each do |id|
      metadata = configured.get_attribute_metadata(id) || raise "missing MSCH state attribute"
      metadata.optional?.should be_false
    end
    expect_raises(ArgumentError, "fixed after construction") do
      configured.configure_schedules(configured.schedule_types, configured.schedules, 3_u8, 1_u8)
    end
  end

  it "activates a persisted schedule when civil time arrives" do
    now = nil.as(Time?)
    clock = -> : Time? { now }
    cluster = production_msch(clock)
    cluster.activate_schedule(ProductionMSCH::SetActiveScheduleRequest.new(Bytes[1_u8])).status.should eq(
      Matter::InteractionModel::StatusCode::Success)
    cluster.occupied_heating_setpoint.should eq(ProductionMSCH::DEFAULT_HEATING_SETPOINT)
    cluster.tick_schedule.should be_false

    now = Time.utc(2026, 10, 26, 8, 0)
    cluster.tick_schedule.should be_true
    cluster.occupied_heating_setpoint.should eq(1900_i16)
    saved = cluster.save_state || raise "missing thermostat state"
    restored = production_msch(clock)
    restored.restore_state(saved)
    restored.active_schedule_handle.should eq(Bytes[1_u8])
    restored.tick_schedule.should be_true
    restored.occupied_heating_setpoint.should eq(1900_i16)
    restored.tick_schedule.should be_false
  end
end
