require "./e2e_helper"

describe "Matter Thermostat Occupancy guarded fixture" do
  device = E2E::Device["matter_thermostat_occupancy"]

  it "commissions and exposes the OCC attributes" do
    device.commission!
    read_int(device, "thermostat", "cluster-revision", "ClusterRevision", 1).should eq(9_i64)
    read_int(device, "thermostat", "feature-map", "FeatureMap", 1).should eq(0x207_i64)
    read_int(device, "thermostat", "occupancy", "Occupancy", 1).should eq(0_i64)
    read_int(device, "thermostat", "unoccupied-heating-setpoint", "UnoccupiedHeatingSetpoint", 1).should eq(2000_i64)
  end

  it "accepts but ignores a legacy ControlSequenceOfOperation write" do
    original = read_int(device, "thermostat", "control-sequence-of-operation", "ControlSequenceOfOperation", 1)
    changed = original == 0_i64 ? 2 : 0
    expect_success(device.write("thermostat", "control-sequence-of-operation", changed, 1))
    read_int(device, "thermostat", "control-sequence-of-operation", "ControlSequenceOfOperation", 1).should eq(original)
  end

  it "writes and adjusts only the unoccupied heating setpoint" do
    expect_success(device.write("thermostat", "unoccupied-heating-setpoint", 2100, 1))
    expect_success(device.invoke("thermostat", "setpoint-raise-lower", ["0", "10"], endpoint: 1))
    read_int(device, "thermostat", "unoccupied-heating-setpoint", "UnoccupiedHeatingSetpoint", 1).should eq(2200_i64)
    read_int(device, "thermostat", "occupied-heating-setpoint", "OccupiedHeatingSetpoint", 1).should eq(2000_i64)
    expect_success(device.chip("thermostat", "read-event", "setpoint-change", device.node, "1"))
      .output.should contain("Occupancy")

    expect_success(device.write("thermostat", "min-heat-setpoint-limit", 2300, 1))
    read_int(device, "thermostat", "occupied-heating-setpoint", "OccupiedHeatingSetpoint", 1).should eq(2300_i64)
    read_int(device, "thermostat", "unoccupied-heating-setpoint", "UnoccupiedHeatingSetpoint", 1).should eq(2300_i64)
  end
end
