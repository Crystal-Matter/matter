require "../spec_helper"

private alias Thermostat = Matter::Cluster::Thermostat
private alias Priority = Matter::InteractionModel::EventPriority

private def capture_thermostat_events(cluster : Thermostat) : Array(Tuple(UInt32, TLV::Any))
  events = [] of Tuple(UInt32, TLV::Any)
  cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, id : UInt32, priority : Priority, data : TLV::Any, _fabric : UInt8?) do
    priority.should eq(Priority::Info)
    events << {id, data}
    nil
  end
  events
end

describe "Thermostat Events feature" do
  it "gates event metadata and the optional running-state attribute" do
    plain = build(Thermostat)
    plain.events.should be_empty
    plain.get_event_metadata(Thermostat::EVENT_SYSTEM_MODE_CHANGE).should be_nil
    plain.get_attribute_metadata(Thermostat::ATTR_THERMOSTAT_RUNNING_STATE).should be_nil

    features = Thermostat::Feature::Heating | Thermostat::Feature::Cooling |
               Thermostat::Feature::Automode | Thermostat::Feature::Events
    cluster = build(Thermostat, feature_map: features)
    cluster.cluster_revision.should eq(9_u16)
    cluster.feature_map.value.should eq(0x223_u32)
    cluster.events.map(&.id.id).should eq([0_u32, 1_u32, 3_u32, 4_u32, 5_u32])
    cluster.read_attribute(Thermostat::ATTR_THERMOSTAT_RUNNING_STATE, nil).as(TLV::Any).value.should eq(0_u64)
  end

  it "suppresses LocalTemperatureChange metadata when LTNE protects the sensor" do
    features = Thermostat::Feature::Heating | Thermostat::Feature::Cooling |
               Thermostat::Feature::Events | Thermostat::Feature::LocalTemperatureNotExposed
    cluster = build(Thermostat, feature_map: features)
    cluster.get_event_metadata(Thermostat::EVENT_LOCAL_TEMPERATURE_CHANGE).should be_nil
    events = capture_thermostat_events(cluster)
    cluster.update_local_temperature(2100_i16)
    events.should be_empty
  end

  it "emits typed mode, setpoint and running-state changes once per real change" do
    features = Thermostat::Feature::Heating | Thermostat::Feature::Cooling |
               Thermostat::Feature::Automode | Thermostat::Feature::Events
    cluster = build(Thermostat, feature_map: features)
    events = capture_thermostat_events(cluster)

    cluster.system_mode = Thermostat::SystemMode::Auto
    cluster.update_local_temperature(3000_i16)
    cluster.occupied_cooling_setpoint = 2500_i16
    cluster.occupied_cooling_setpoint = 2500_i16

    events.map(&.[0]).should eq([
      Thermostat::EVENT_SYSTEM_MODE_CHANGE,
      Thermostat::EVENT_RUNNING_STATE_CHANGE,
      Thermostat::EVENT_RUNNING_MODE_CHANGE,
      Thermostat::EVENT_LOCAL_TEMPERATURE_CHANGE,
      Thermostat::EVENT_SETPOINT_CHANGE,
    ])
    Thermostat::SystemModeChangeEvent.from_tlv(events[0][1]).current_system_mode.should eq(Thermostat::SystemMode::Auto)
    Thermostat::RunningStateChangeEvent.from_tlv(events[1][1]).current_running_state.should eq(Thermostat::RelayState::Cool)
    Thermostat::RunningModeChangeEvent.from_tlv(events[2][1]).current_running_mode.should eq(Thermostat::ThermostatRunningMode::Cool)
    setpoint = Thermostat::SetpointChangeEvent.from_tlv(events[4][1])
    setpoint.system_mode.should eq(Thermostat::SystemMode::Cool)
    setpoint.current_setpoint.should eq(2500_i16)
    cluster.read_attribute(Thermostat::ATTR_THERMOSTAT_RUNNING_STATE, nil).as(TLV::Any).value.should eq(2_u64)
  end

  it "reports relay changes without AUTO but omits RunningModeChange" do
    cluster = build(Thermostat, feature_map: Thermostat::Feature::Heating | Thermostat::Feature::Events)
    events = capture_thermostat_events(cluster)
    cluster.mode = Thermostat::SystemMode::Heat
    events.map(&.[0]).should eq([
      Thermostat::EVENT_SYSTEM_MODE_CHANGE,
      Thermostat::EVENT_RUNNING_STATE_CHANGE,
    ])
    cluster.get_event_metadata(Thermostat::EVENT_RUNNING_MODE_CHANGE).should be_nil
    cluster.thermostat_running_state.should eq(Thermostat::RelayState::Heat)
  end

  it "keeps running state and events in sync for direct attribute setters" do
    features = Thermostat::Feature::Heating | Thermostat::Feature::Cooling |
               Thermostat::Feature::Automode | Thermostat::Feature::Events
    cluster = build(Thermostat, feature_map: features)
    events = capture_thermostat_events(cluster)

    cluster.system_mode = Thermostat::SystemMode::Heat
    cluster.thermostat_running_state.should eq(Thermostat::RelayState::Heat)
    events.map(&.[0]).should eq([
      Thermostat::EVENT_SYSTEM_MODE_CHANGE,
      Thermostat::EVENT_RUNNING_STATE_CHANGE,
      Thermostat::EVENT_RUNNING_MODE_CHANGE,
    ])

    cluster.system_mode = Thermostat::SystemMode::Auto
    cluster.local_temperature = 2400_i16
    cluster.occupied_cooling_setpoint = 2300_i16
    cluster.thermostat_running_state.should eq(Thermostat::RelayState::Cool)
    events.last[0].should eq(Thermostat::EVENT_RUNNING_MODE_CHANGE)
  end

  it "rate-limits significant temperature changes while retaining the latest attribute value" do
    cluster = build(Thermostat, feature_map: Thermostat::Feature::Heating | Thermostat::Feature::Events)
    events = capture_thermostat_events(cluster)
    cluster.update_local_temperature(2000_i16)
    cluster.update_local_temperature(2010_i16)
    cluster.update_local_temperature(2100_i16)
    cluster.update_local_temperature(nil)
    events.map(&.[0]).should eq([Thermostat::EVENT_LOCAL_TEMPERATURE_CHANGE])
    Thermostat::LocalTemperatureChangeEvent.from_tlv(events.first[1]).current_local_temperature.should eq(2000_i16)
    cluster.local_temperature.should be_nil
  end

  it "encodes the nullable temperature field as TLV null on an initial sensor loss" do
    cluster = build(Thermostat,
      feature_map: Thermostat::Feature::Heating | Thermostat::Feature::Events,
      local_temperature: 2200_i16)
    events = capture_thermostat_events(cluster)
    cluster.update_local_temperature(nil)
    events.map(&.[0]).should eq([Thermostat::EVENT_LOCAL_TEMPERATURE_CHANGE])
    events.first[1].header.element_type.should eq(TLV::ElementType::Structure)
    events.first[1].as_structure[0_u8].value.should be_nil
    Thermostat::LocalTemperatureChangeEvent.from_tlv(events.first[1]).current_local_temperature.should be_nil
  end

  it "compares small sensor steps to the last event, so they accumulate" do
    cluster = build(Thermostat,
      feature_map: Thermostat::Feature::Heating | Thermostat::Feature::Events,
      local_temperature: 2000_i16)
    events = capture_thermostat_events(cluster)
    cluster.update_local_temperature(2010_i16)
    cluster.update_local_temperature(2040_i16)
    events.should be_empty
    cluster.update_local_temperature(2050_i16)
    events.map(&.[0]).should eq([Thermostat::EVENT_LOCAL_TEMPERATURE_CHANGE])
    Thermostat::LocalTemperatureChangeEvent.from_tlv(events.first[1]).current_local_temperature.should eq(2050_i16)
  end
end
