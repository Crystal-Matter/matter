require "./e2e_helper"

describe "Matter Thermostat LocalTemperatureNotExposed interoperability" do
  device = E2E::Device["matter_thermostat_ltne"]

  it "commissions and reports TLV null for a private sensor value" do
    device.commission!
    read_int(device, "thermostat", "cluster-revision", "ClusterRevision", 1).should eq(9_i64)
    read_int(device, "thermostat", "feature-map", "FeatureMap", 1).should eq(99_i64)
    expect_success(device.read("thermostat", "local-temperature", 1)).value("LocalTemperature").try(&.downcase).should eq("null")
    read_int(device, "thermostat", "thermostat-running-mode", "ThermostatRunningMode", 1).should eq(3_i64)
  end

  it "keeps the measurement private through mode writes and restart" do
    expect_success(device.write("thermostat", "system-mode", 0, 1))
    read_int(device, "thermostat", "thermostat-running-mode", "ThermostatRunningMode", 1).should eq(0_i64)
    expect_success(device.write("thermostat", "system-mode", 1, 1))
    read_int(device, "thermostat", "thermostat-running-mode", "ThermostatRunningMode", 1).should eq(3_i64)
    device.restart!
    expect_success(device.read("thermostat", "local-temperature", 1)).value("LocalTemperature").try(&.downcase).should eq("null")
  end
end
