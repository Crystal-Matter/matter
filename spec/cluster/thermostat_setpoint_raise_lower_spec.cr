require "../spec_helper"

# Matter 1.6 Thermostat §4.3.11.11–12 and §4.3.12.1, cross-checked against
# connectedhomeip ThermostatCluster.cpp SetpointRaiseLower and matter.js
# ThermostatServer#setpointRaiseLower.
private alias Thermostat = Matter::Cluster::Thermostat
private alias IMStatus = Matter::InteractionModel::Status

private def raise_lower(thermostat : Thermostat, mode : Thermostat::SetpointAdjustMode, amount : Int8) : IMStatus
  thermostat.setpoint_raise_lower(Thermostat::SetpointRaiseLowerRequest.new(mode, amount))
end

describe "Thermostat SetpointRaiseLower" do
  it "rejects a requested setpoint whose feature is absent without changing state" do
    cooling_only = build(Thermostat, feature_map: Thermostat::Feature::Cooling)
    heating_only = build(Thermostat, feature_map: Thermostat::Feature::Heating)

    raise_lower(cooling_only, Thermostat::SetpointAdjustMode::Heat, 10_i8).should eq(IMStatus.invalid_command)
    cooling_only.occupied_heating_setpoint.should eq(Thermostat::DEFAULT_HEATING_SETPOINT)
    raise_lower(heating_only, Thermostat::SetpointAdjustMode::Cool, -10_i8).should eq(IMStatus.invalid_command)
    heating_only.occupied_cooling_setpoint.should eq(Thermostat::DEFAULT_COOLING_SETPOINT)
  end

  it "applies Both to the only setpoint on a single-feature thermostat" do
    heating_only = build(Thermostat, feature_map: Thermostat::Feature::Heating)
    cooling_only = build(Thermostat, feature_map: Thermostat::Feature::Cooling)

    raise_lower(heating_only, Thermostat::SetpointAdjustMode::Both, 10_i8).should eq(IMStatus.success)
    heating_only.occupied_heating_setpoint.should eq(2100_i16)
    cooling_only.occupied_cooling_setpoint.should eq(Thermostat::DEFAULT_COOLING_SETPOINT)

    raise_lower(cooling_only, Thermostat::SetpointAdjustMode::Both, -10_i8).should eq(IMStatus.success)
    cooling_only.occupied_cooling_setpoint.should eq(2500_i16)
    cooling_only.occupied_heating_setpoint.should eq(Thermostat::DEFAULT_HEATING_SETPOINT)
  end

  it "clamps a Both adjustment by the first limit while keeping the heat/cool separation" do
    thermostat = build(Thermostat, max_cool_setpoint_limit: 2700_i16, max_heat_setpoint_limit: 2200_i16)

    raise_lower(thermostat, Thermostat::SetpointAdjustMode::Both, 20_i8).should eq(IMStatus.success)
    thermostat.occupied_heating_setpoint.should eq(2100_i16)
    thermostat.occupied_cooling_setpoint.should eq(2700_i16)
  end

  it "preserves the pair offset when a Both decrease hits the heating minimum" do
    thermostat = build(Thermostat, min_heat_setpoint_limit: 1950_i16, min_cool_setpoint_limit: 2300_i16)

    raise_lower(thermostat, Thermostat::SetpointAdjustMode::Both, -20_i8).should eq(IMStatus.success)
    thermostat.occupied_heating_setpoint.should eq(1950_i16)
    thermostat.occupied_cooling_setpoint.should eq(2550_i16)
  end

  it "adjusts the opposite setpoint to maintain the Auto deadband" do
    thermostat = build(Thermostat,
      feature_map: Thermostat::Feature::Heating | Thermostat::Feature::Cooling | Thermostat::Feature::Automode,
      min_setpoint_dead_band: 25_i8)

    raise_lower(thermostat, Thermostat::SetpointAdjustMode::Heat, 40_i8).should eq(IMStatus.success)
    thermostat.occupied_heating_setpoint.should eq(2400_i16)
    thermostat.occupied_cooling_setpoint.should eq(2650_i16)
  end

  it "rejects an Auto adjustment that cannot maintain deadband without partial changes" do
    thermostat = build(Thermostat,
      feature_map: Thermostat::Feature::Heating | Thermostat::Feature::Cooling | Thermostat::Feature::Automode,
      max_cool_setpoint_limit: 2650_i16,
      min_setpoint_dead_band: 25_i8)

    raise_lower(thermostat, Thermostat::SetpointAdjustMode::Heat, 50_i8).should eq(IMStatus.invalid_command)
    thermostat.occupied_heating_setpoint.should eq(Thermostat::DEFAULT_HEATING_SETPOINT)
    thermostat.occupied_cooling_setpoint.should eq(Thermostat::DEFAULT_COOLING_SETPOINT)
  end

  it "adjusts the heating setpoint for an Auto cooling decrease" do
    thermostat = build(Thermostat,
      feature_map: Thermostat::Feature::Heating | Thermostat::Feature::Cooling | Thermostat::Feature::Automode,
      min_setpoint_dead_band: 25_i8)

    raise_lower(thermostat, Thermostat::SetpointAdjustMode::Cool, -40_i8).should eq(IMStatus.success)
    thermostat.occupied_cooling_setpoint.should eq(2200_i16)
    thermostat.occupied_heating_setpoint.should eq(1950_i16)
  end

  it "rejects an impossible Auto cooling decrease without partial changes" do
    thermostat = build(Thermostat,
      feature_map: Thermostat::Feature::Heating | Thermostat::Feature::Cooling | Thermostat::Feature::Automode,
      min_heat_setpoint_limit: 1950_i16,
      min_setpoint_dead_band: 25_i8)

    raise_lower(thermostat, Thermostat::SetpointAdjustMode::Cool, -50_i8).should eq(IMStatus.invalid_command)
    thermostat.occupied_heating_setpoint.should eq(Thermostat::DEFAULT_HEATING_SETPOINT)
    thermostat.occupied_cooling_setpoint.should eq(Thermostat::DEFAULT_COOLING_SETPOINT)
  end
end
