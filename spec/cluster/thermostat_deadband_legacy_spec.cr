require "../spec_helper"

private alias DeadbandThermostat = Matter::Cluster::Thermostat
private alias DeadbandStatus = Matter::InteractionModel::StatusCode

# Matter 1.6 §4.3.11.19: legacy writes are accepted but cannot change the
# host-defined minimum deadband used to constrain heating and cooling.
describe "Thermostat MinSetpointDeadBand legacy writes" do
  it "silently ignores a valid write and keeps its data version" do
    cluster = build(DeadbandThermostat,
      feature_map: DeadbandThermostat::Feature::Heating | DeadbandThermostat::Feature::Cooling |
                   DeadbandThermostat::Feature::Automode,
      min_setpoint_dead_band: 25_i8)
    version = cluster.data_version

    result = cluster.write_attribute(DeadbandThermostat::ATTR_MIN_SETPOINT_DEAD_BAND,
      TLV::Serializable.serialize_value(30_i8, nil))

    result.status.should eq(DeadbandStatus::Success)
    cluster.min_setpoint_dead_band.should eq(25_i8)
    cluster.data_version.should eq(version)
  end

  it "still rejects a value outside the Matter range before ignoring it" do
    cluster = build(DeadbandThermostat,
      feature_map: DeadbandThermostat::Feature::Heating | DeadbandThermostat::Feature::Cooling |
                   DeadbandThermostat::Feature::Automode)
    version = cluster.data_version

    result = cluster.write_attribute(DeadbandThermostat::ATTR_MIN_SETPOINT_DEAD_BAND,
      TLV::Serializable.serialize_value(-1_i8, nil))

    result.status.should eq(DeadbandStatus::ConstraintError)
    cluster.min_setpoint_dead_band.should eq(DeadbandThermostat::DEFAULT_DEAD_BAND)
    cluster.data_version.should eq(version)
  end
end
