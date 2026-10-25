require "../spec_helper"

private alias OccThermostat = Matter::Cluster::Thermostat
private alias OccStatus = Matter::InteractionModel::Status

private class OccupancyReadyThermostat < OccThermostat
  protected def occupancy_wire_ready? : Bool
    true
  end
end

private def occupancy_features : OccThermostat::Feature
  OccThermostat::Feature::Heating | OccThermostat::Feature::Cooling |
    OccThermostat::Feature::Occupancy | OccThermostat::Feature::Events
end

describe "Thermostat Occupancy preparation" do
  it "gates OCC in production while exposing its mandatory attributes in the guarded fixture" do
    expect_raises(ArgumentError) { build(OccThermostat, feature_map: occupancy_features) }
    cluster = build(OccupancyReadyThermostat, feature_map: occupancy_features)
    cluster.cluster_revision.should eq(9_u16)
    [0x02_u32, 0x13_u32, 0x14_u32].each { |id| cluster.get_attribute_metadata(id).should_not be_nil }
    cluster.get_event_metadata(0x02_u32).should_not be_nil
    cluster.occupancy.should eq(1_u8)
    cluster.unoccupied_cooling_setpoint.should eq(2600_i16)
    cluster.unoccupied_heating_setpoint.should eq(2000_i16)
  end

  it "validates occupancy and emits a typed TEVT change only when it changes" do
    cluster = build(OccupancyReadyThermostat, feature_map: occupancy_features)
    events = [] of TLV::Any
    cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, id : UInt32, _priority : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) {
      events << data if id == OccThermostat::EVENT_OCCUPANCY_CHANGE
      nil
    }
    cluster.occupancy = 0_u8
    cluster.occupancy = 0_u8
    expect_raises(ArgumentError) { cluster.occupancy = 2_u8 }
    cluster.occupancy.should eq(0_u8)
    events.size.should eq(1)
    event = OccThermostat::OccupancyChangeEvent.from_tlv(events.first)
    event.previous_occupancy.should eq(1_u8)
    event.current_occupancy.should eq(0_u8)
  end

  it "routes setpoint adjustment to unoccupied values and persists them" do
    cluster = build(OccupancyReadyThermostat, feature_map: occupancy_features)
    cluster.occupancy = 0_u8
    cluster.setpoint_raise_lower(OccThermostat::SetpointRaiseLowerRequest.new(
      OccThermostat::SetpointAdjustMode::Heat, 10_i8)).should eq(OccStatus.success)
    cluster.unoccupied_heating_setpoint.should eq(2100_i16)
    cluster.occupied_heating_setpoint.should eq(2000_i16)
    restored = build(OccupancyReadyThermostat, feature_map: occupancy_features)
    restored.restore_state(cluster.save_state)
    restored.occupancy.should eq(0_u8)
    restored.unoccupied_heating_setpoint.should eq(2100_i16)
  end

  it "rejects out-of-limit unoccupied writes without a partial state change" do
    cluster = build(OccupancyReadyThermostat, feature_map: occupancy_features)
    version = cluster.data_version
    result = cluster.write_attribute(0x14_u32, TLV::Serializable.serialize_value(3100_i16, nil))
    result.status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    cluster.unoccupied_heating_setpoint.should eq(2000_i16)
    cluster.data_version.should eq(version)
  end

  it "adjusts the unoccupied Auto pair within bounds and labels its TEVT setpoint event" do
    features = occupancy_features | OccThermostat::Feature::Automode
    cluster = build(OccupancyReadyThermostat, feature_map: features,
      min_setpoint_dead_band: 25_i8)
    changes = [] of OccThermostat::SetpointChangeEvent
    cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, id : UInt32, _priority : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) {
      changes << OccThermostat::SetpointChangeEvent.from_tlv(data) if id == OccThermostat::EVENT_SETPOINT_CHANGE
      nil
    }
    cluster.occupancy = 0_u8
    result = cluster.write_attribute(0x14_u32, TLV::Serializable.serialize_value(2500_i16, nil))
    result.should eq(OccStatus.success)
    cluster.unoccupied_heating_setpoint.should eq(2500_i16)
    cluster.unoccupied_cooling_setpoint.should eq(2750_i16)
    cluster.occupied_cooling_setpoint.should eq(2600_i16)
    changes.map(&.occupancy).should eq([0_u8, 0_u8])

    version = cluster.data_version
    result = cluster.write_attribute(0x14_u32, TLV::Serializable.serialize_value(3100_i16, nil))
    result.status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    cluster.data_version.should eq(version)
  end
end
