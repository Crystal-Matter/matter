require "../spec_helper"

private alias LimitThermostat = Matter::Cluster::Thermostat
private alias LimitStatus = Matter::InteractionModel::StatusCode

private def write_limit(cluster : LimitThermostat, id : UInt32, value : Int16) : Matter::InteractionModel::Status
  cluster.write_attribute(id, TLV::Serializable.serialize_value(value, nil))
end

private def limit_features(auto : Bool = false) : LimitThermostat::Feature
  features = LimitThermostat::Feature::Heating | LimitThermostat::Feature::Cooling |
             LimitThermostat::Feature::Occupancy
  auto ? features | LimitThermostat::Feature::Automode : features
end

describe "Thermostat setpoint limit reconciliation" do
  it "raises both occupied and unoccupied heating setpoints to a new minimum" do
    cluster = build(LimitThermostat, feature_map: limit_features,
      occupied_heating_setpoint: 1800_i16, unoccupied_heating_setpoint: 1900_i16)
    write_limit(cluster, LimitThermostat::ATTR_MIN_HEAT_SETPOINT_LIMIT, 2100_i16)
      .status.should eq(LimitStatus::Success)
    cluster.min_heat_setpoint_limit.should eq(2100_i16)
    cluster.occupied_heating_setpoint.should eq(2100_i16)
    cluster.unoccupied_heating_setpoint.should eq(2100_i16)
    cluster.occupied_cooling_setpoint.should eq(2600_i16)
    cluster.unoccupied_cooling_setpoint.should eq(2600_i16)
  end

  it "lowers both heating setpoints to a new maximum while preserving Auto deadband" do
    cluster = build(LimitThermostat, feature_map: limit_features(true),
      occupied_heating_setpoint: 2500_i16, occupied_cooling_setpoint: 2800_i16,
      unoccupied_heating_setpoint: 2400_i16, unoccupied_cooling_setpoint: 2700_i16)
    write_limit(cluster, LimitThermostat::ATTR_MAX_HEAT_SETPOINT_LIMIT, 2200_i16)
      .status.should eq(LimitStatus::Success)
    cluster.occupied_heating_setpoint.should eq(2200_i16)
    cluster.unoccupied_heating_setpoint.should eq(2200_i16)
    cluster.occupied_cooling_setpoint.should eq(2800_i16)
    cluster.unoccupied_cooling_setpoint.should eq(2700_i16)
  end

  it "raises both cooling setpoints to a new minimum and lowers them to a new maximum" do
    cluster = build(LimitThermostat, feature_map: limit_features,
      occupied_cooling_setpoint: 2400_i16, unoccupied_cooling_setpoint: 2500_i16)
    write_limit(cluster, LimitThermostat::ATTR_MIN_COOL_SETPOINT_LIMIT, 2600_i16)
      .status.should eq(LimitStatus::Success)
    cluster.occupied_cooling_setpoint.should eq(2600_i16)
    cluster.unoccupied_cooling_setpoint.should eq(2600_i16)
    write_limit(cluster, LimitThermostat::ATTR_MAX_COOL_SETPOINT_LIMIT, 2500_i16)
      .status.should eq(LimitStatus::ConstraintError)
    cluster.max_cool_setpoint_limit.should eq(3200_i16)
    write_limit(cluster, LimitThermostat::ATTR_MIN_COOL_SETPOINT_LIMIT, 2200_i16)
      .status.should eq(LimitStatus::Success)
    write_limit(cluster, LimitThermostat::ATTR_MAX_COOL_SETPOINT_LIMIT, 2500_i16)
      .status.should eq(LimitStatus::Success)
    cluster.occupied_cooling_setpoint.should eq(2500_i16)
    cluster.unoccupied_cooling_setpoint.should eq(2500_i16)
  end

  it "rejects an impossible Auto limit relationship without changing either pair or DataVersion" do
    cluster = build(LimitThermostat, feature_map: limit_features(true))
    version = cluster.data_version
    write_limit(cluster, LimitThermostat::ATTR_MIN_HEAT_SETPOINT_LIMIT, 1500_i16)
      .status.should eq(LimitStatus::ConstraintError)
    write_limit(cluster, LimitThermostat::ATTR_MAX_COOL_SETPOINT_LIMIT, 3100_i16)
      .status.should eq(LimitStatus::ConstraintError)
    cluster.data_version.should eq(version)
    cluster.min_heat_setpoint_limit.should eq(700_i16)
    cluster.max_cool_setpoint_limit.should eq(3200_i16)
    cluster.occupied_heating_setpoint.should eq(2000_i16)
    cluster.unoccupied_heating_setpoint.should eq(2000_i16)
  end

  it "retains both stored pairs when occupancy changes after a limit write" do
    cluster = build(LimitThermostat, feature_map: limit_features,
      occupied_heating_setpoint: 1800_i16, unoccupied_heating_setpoint: 1900_i16)
    write_limit(cluster, LimitThermostat::ATTR_MIN_HEAT_SETPOINT_LIMIT, 2100_i16)
      .status.should eq(LimitStatus::Success)
    cluster.occupancy = 0_u8
    cluster.occupancy = 1_u8
    cluster.occupied_heating_setpoint.should eq(2100_i16)
    cluster.unoccupied_heating_setpoint.should eq(2100_i16)
  end

  it "applies the same validation and reconciliation to host limit setters" do
    cluster = build(LimitThermostat, feature_map: limit_features(true),
      min_cool_setpoint_limit: 2500_i16, unoccupied_heating_setpoint: 1800_i16)
    cluster.min_heat_setpoint_limit = 2200_i16
    cluster.occupied_heating_setpoint.should eq(2200_i16)
    cluster.unoccupied_heating_setpoint.should eq(2200_i16)
    version = cluster.data_version
    expect_raises(ArgumentError) { cluster.max_cool_setpoint_limit = 3100_i16 }
    cluster.max_cool_setpoint_limit.should eq(3200_i16)
    cluster.data_version.should eq(version)
  end
end
