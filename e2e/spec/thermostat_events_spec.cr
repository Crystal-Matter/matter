require "./e2e_helper"

describe "Matter Thermostat Events interoperability" do
  device = E2E::Device["matter_thermostat_events"]

  it "commissions and exposes the opt-in TEVT feature at revision nine" do
    device.commission!
    read_int(device, "thermostat", "cluster-revision", "ClusterRevision", 1).should eq(11_i64)
    read_int(device, "thermostat", "feature-map", "FeatureMap", 1).should eq(0x223_i64)
    read_int(device, "thermostat", "thermostat-running-state", "ThermostatRunningState", 1).should eq(0_i64)
  end

  it "accepts but ignores a legacy MinSetpointDeadBand write" do
    original = read_int(device, "thermostat", "min-setpoint-dead-band", "MinSetpointDeadBand", 1)
    expect_success(device.write("thermostat", "min-setpoint-dead-band", (original + 1).to_s, 1))
    read_int(device, "thermostat", "min-setpoint-dead-band", "MinSetpointDeadBand", 1).should eq(original)
  end

  it "rejects a cooling SystemMode when the fixed control sequence is heating only" do
    read_int(device, "thermostat", "control-sequence-of-operation", "ControlSequenceOfOperation", 2).should eq(2_i64)
    expect_failure(device.write("thermostat", "system-mode", 3, 2), "CONSTRAINT_ERROR")
    read_int(device, "thermostat", "system-mode", "SystemMode", 2).should eq(0_i64)
    expect_success(device.write("thermostat", "system-mode", 4, 2))
    read_int(device, "thermostat", "system-mode", "SystemMode", 2).should eq(4_i64)
  end

  it "reports typed mode, relay and setpoint events and restores controller writes" do
    expect_success(device.write("thermostat", "system-mode", 1, 1))
    expect_success(device.chip("thermostat", "read-event", "system-mode-change", device.node, "1"))
      .output.should contain("CurrentSystemMode")
    expect_success(device.chip("thermostat", "read-event", "running-mode-change", device.node, "1"))
      .output.should contain("CurrentRunningMode")
    expect_success(device.chip("thermostat", "read-event", "running-state-change", device.node, "1"))
      .output.should contain("CurrentRunningState")
    read_int(device, "thermostat", "thermostat-running-state", "ThermostatRunningState", 1).should eq(2_i64)

    expect_success(device.write("thermostat", "occupied-cooling-setpoint", 2500, 1))
    expect_success(device.chip("thermostat", "read-event", "setpoint-change", device.node, "1"))
      .output.should contain("CurrentSetpoint")
    device.restart!
    read_int(device, "thermostat", "system-mode", "SystemMode", 1).should eq(1_i64)
    read_int(device, "thermostat", "occupied-cooling-setpoint", "OccupiedCoolingSetpoint", 1).should eq(2500_i64)
  end
end
