require "../spec_helper"

private alias Thermostat = Matter::Cluster::Thermostat

# Matter 1.6 Thermostat §4.3.11.2: LTNE still uses a measured temperature
# internally, but LocalTemperature must always report TLV null.
describe "Thermostat LocalTemperatureNotExposed" do
  it "keeps the measurement private while Auto still responds to it" do
    thermostat = build(Thermostat,
      feature_map: Thermostat::Feature::Heating | Thermostat::Feature::Cooling |
                   Thermostat::Feature::Automode | Thermostat::Feature::LocalTemperatureNotExposed,
      local_temperature: 2900_i16,
      system_mode: Thermostat::SystemMode::Auto)

    thermostat.local_temperature.should be_nil
    thermostat.update_local_temperature(3000_i16)
    thermostat.thermostat_running_mode.should eq(Thermostat::ThermostatRunningMode::Cool)
    thermostat.local_temperature.should be_nil
    wire = thermostat.read_attribute(Thermostat::ATTR_LOCAL_TEMPERATURE, nil).as(TLV::Any)
    wire.header.element_type.should eq(TLV::ElementType::Null)

    thermostat.update_local_temperature(1900_i16)
    thermostat.thermostat_running_mode.should eq(Thermostat::ThermostatRunningMode::Heat)
    thermostat.local_temperature.should be_nil
    thermostat.read_attribute(Thermostat::ATTR_LOCAL_TEMPERATURE, nil).as(TLV::Any).value.should be_nil
  end

  it "does not allow the generated public setter to leak a private measurement" do
    thermostat = build(Thermostat,
      feature_map: Thermostat::Feature::Heating | Thermostat::Feature::Cooling |
                   Thermostat::Feature::LocalTemperatureNotExposed)

    expect_raises(ArgumentError) { thermostat.local_temperature = 2100_i16 }
    thermostat.local_temperature.should be_nil
    thermostat.read_attribute(Thermostat::ATTR_LOCAL_TEMPERATURE, nil).as(TLV::Any).value.should be_nil
  end

  it "continues exposing the measured value without LTNE" do
    thermostat = build(Thermostat,
      feature_map: Thermostat::Feature::Heating | Thermostat::Feature::Cooling | Thermostat::Feature::Automode,
      system_mode: Thermostat::SystemMode::Auto)
    thermostat.local_temperature = 3000_i16

    thermostat.thermostat_running_mode.should eq(Thermostat::ThermostatRunningMode::Cool)
    thermostat.local_temperature.should eq(3000_i16)
    thermostat.read_attribute(Thermostat::ATTR_LOCAL_TEMPERATURE, nil).as(TLV::Any).value.should eq(3000_i16)
  end
end
