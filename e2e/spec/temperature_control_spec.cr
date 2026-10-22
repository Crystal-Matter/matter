require "./e2e_helper"

describe "Matter 1.6 Temperature Control interoperability" do
  device = E2E::Device["matter_temperature_control"]

  it "commissions and exposes the numeric and named-level feature choices" do
    device.commission!
    read_int(device, "temperaturecontrol", "cluster-revision", "ClusterRevision", 1).should eq(1_i64)
    read_int(device, "temperaturecontrol", "feature-map", "FeatureMap", 1).should eq(5_i64)
    read_int(device, "temperaturecontrol", "feature-map", "FeatureMap", 2).should eq(2_i64)
    read_int(device, "temperaturecontrol", "temperature-setpoint", "TemperatureSetpoint", 1).should eq(2000_i64)
    read_int(device, "temperaturecontrol", "step", "Step", 1).should eq(50_i64)
    read_int(device, "temperaturecontrol", "selected-temperature-level", "SelectedTemperatureLevel", 2).should eq(1_i64)
    expect_failure(device.read("temperaturecontrol", "selected-temperature-level", 1), "UNSUPPORTED_ATTRIBUTE")
    expect_failure(device.read("temperaturecontrol", "temperature-setpoint", 2), "UNSUPPORTED_ATTRIBUTE")
  end

  it "validates numeric steps and host refusal, then persists the accepted setpoint" do
    expect_failure(device.invoke("temperaturecontrol", "set-temperature", endpoint: 1,
      options: ["--TargetTemperature", "2025"]), "CONSTRAINT_ERROR")
    expect_failure(device.invoke("temperaturecontrol", "set-temperature", endpoint: 1,
      options: ["--TargetTemperature", "3500"]), "INVALID_IN_STATE")
    expect_success(device.invoke("temperaturecontrol", "set-temperature", endpoint: 1,
      options: ["--TargetTemperature", "2050"]))
    read_int(device, "temperaturecontrol", "temperature-setpoint", "TemperatureSetpoint", 1).should eq(2050_i64)
    device.restart!
    read_int(device, "temperaturecontrol", "temperature-setpoint", "TemperatureSetpoint", 1).should eq(2050_i64)
  end

  it "validates named levels and persists the accepted selection" do
    expect_failure(device.invoke("temperaturecontrol", "set-temperature", endpoint: 2,
      options: ["--TargetTemperatureLevel", "3"]), "CONSTRAINT_ERROR")
    expect_success(device.invoke("temperaturecontrol", "set-temperature", endpoint: 2,
      options: ["--TargetTemperatureLevel", "2"]))
    read_int(device, "temperaturecontrol", "selected-temperature-level", "SelectedTemperatureLevel", 2).should eq(2_i64)
    device.restart!
    read_int(device, "temperaturecontrol", "selected-temperature-level", "SelectedTemperatureLevel", 2).should eq(2_i64)
  end
end
