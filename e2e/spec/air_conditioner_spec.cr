require "./e2e_helper"

# examples/matter_air_conditioner_device.cr - Thermostat (endpoint 1) + Fan (endpoint 2)
describe "matter_air_conditioner example" do
  device = E2E::Device["matter_air_conditioner"]

  thermostat = 1
  fan = 2

  it "commissions with chip-tool" do
    device.commission!
  end

  it "exposes a thermostat and a fan endpoint" do
    parts = expect_success(device.read("descriptor", "parts-list", 0)).int_list("PartsList")
    parts.should contain(1_i64)
    parts.should contain(2_i64)
    expect_success(device.read("descriptor", "device-type-list", thermostat)).int("DeviceType").should eq 0x0301_i64
    expect_success(device.read("descriptor", "device-type-list", fan)).int("DeviceType").should eq 0x002B_i64
  end

  it "reads the thermostat temperature and setpoints" do
    read_int(device, "thermostat", "local-temperature", "LocalTemperature", thermostat).should be_in(1500..3500)
    read_int(device, "thermostat", "occupied-cooling-setpoint", "OccupiedCoolingSetpoint", thermostat).should be_in(1600..3200)
    read_int(device, "thermostat", "occupied-heating-setpoint", "OccupiedHeatingSetpoint", thermostat).should be_in(700..3000)
  end

  it "writes the cooling setpoint" do
    expect_success(device.write("thermostat", "occupied-cooling-setpoint", 2500, thermostat))
    read_int(device, "thermostat", "occupied-cooling-setpoint", "OccupiedCoolingSetpoint", thermostat).should eq 2500
  end

  it "rejects an out of range cooling setpoint" do
    expect_failure(device.write("thermostat", "occupied-cooling-setpoint", 5000, thermostat), "CONSTRAINT_ERROR")
    read_int(device, "thermostat", "occupied-cooling-setpoint", "OccupiedCoolingSetpoint", thermostat).should eq 2500
  end

  it "keeps the heat/cool separation when SetpointRaiseLower Both reaches a limit" do
    expect_success(device.write("thermostat", "occupied-cooling-setpoint", 2600, thermostat))
    expect_success(device.write("thermostat", "occupied-heating-setpoint", 2000, thermostat))

    expect_success(device.invoke("thermostat", "setpoint-raise-lower", ["2", "100"], endpoint: thermostat))
    read_int(device, "thermostat", "occupied-heating-setpoint", "OccupiedHeatingSetpoint", thermostat).should eq 2600
    read_int(device, "thermostat", "occupied-cooling-setpoint", "OccupiedCoolingSetpoint", thermostat).should eq 3200
  end

  it "switches the system mode to cool and back off" do
    expect_success(device.write("thermostat", "system-mode", 3, thermostat))
    read_int(device, "thermostat", "system-mode", "SystemMode", thermostat).should eq 3
    expect_success(device.write("thermostat", "system-mode", 0, thermostat))
    read_int(device, "thermostat", "system-mode", "SystemMode", thermostat).should eq 0
  end

  it "sets the fan speed percentage" do
    expect_success(device.write("fancontrol", "percent-setting", 50, fan))
    read_int(device, "fancontrol", "percent-setting", "PercentSetting", fan).should eq 50
    read_int(device, "fancontrol", "fan-mode", "FanMode", fan).should_not eq 0
  end

  it "turns the fan off through the percent setting" do
    expect_success(device.write("fancontrol", "percent-setting", 0, fan))
    read_int(device, "fancontrol", "fan-mode", "FanMode", fan).should eq 0
  end

  it "toggles the fan on/off cluster" do
    before = read_bool(device, "onoff", "on-off", "OnOff", fan)
    expect_success(device.invoke("onoff", "toggle", endpoint: fan))
    read_bool(device, "onoff", "on-off", "OnOff", fan).should eq !before
  end

  it "exposes Fan Control revision 6 and its feature-gated Step behavior" do
    read_int(device, "fancontrol", "cluster-revision", "ClusterRevision", fan).should eq(6_i64)
    read_int(device, "fancontrol", "feature-map", "FeatureMap", fan).should eq(17_i64)
    expect_success(device.read("fancontrol", "accepted-command-list", fan))
      .int_list("AcceptedCommandList").should eq([0_i64])

    expect_success(device.write("fancontrol", "percent-setting", 0, fan))
    expect_success(device.invoke("fancontrol", "step", ["0"], endpoint: fan))
    read_int(device, "fancontrol", "percent-setting", "PercentSetting", fan).should eq(20_i64)
  end

  it "retains FanMode but resets volatile settings after restart" do
    expect_success(device.write("fancontrol", "fan-mode", 3, fan))
    expect_success(device.write("fancontrol", "percent-setting", 75, fan))
    device.restart!
    read_int(device, "fancontrol", "fan-mode", "FanMode", fan).should eq(3_i64)
    read_int(device, "fancontrol", "percent-setting", "PercentSetting", fan).should eq(0_i64)
    read_int(device, "fancontrol", "speed-setting", "SpeedSetting", fan).should eq(0_i64)
  end
end
