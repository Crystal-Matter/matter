require "./e2e_helper"

# examples/matter_motion_sensor_device.cr - Occupancy (PIR) Sensor on endpoint 1
describe "matter_motion_sensor example" do
  device = E2E::Device["matter_motion_sensor"]

  it "commissions with chip-tool" do
    device.commission!
  end

  it "is an occupancy sensor" do
    expect_success(device.read("descriptor", "device-type-list", 1)).int("DeviceType").should eq 0x0107_i64
    expect_success(device.read("fixedlabel", "label-list")).values("Value").should eq ["Example Motion"]
  end

  it "reads occupancy and the PIR sensor type" do
    read_int(device, "occupancysensing", "occupancy", "Occupancy").should be_in(0..1)
    read_int(device, "occupancysensing", "occupancy-sensor-type-bitmap", "OccupancySensorTypeBitmap").should eq 1
    read_int(device, "occupancysensing", "cluster-revision", "ClusterRevision").should eq 7
    read_int(device, "occupancysensing", "feature-map", "FeatureMap").should eq 0x202
  end

  it "exposes valid HoldTimeLimits and rejects invalid timing writes" do
    limits = expect_success(device.read("occupancysensing", "hold-time-limits"))
    limits.int("HoldTimeMin").should eq 1
    limits.int("HoldTimeMax").should eq 600
    limits.int("HoldTimeDefault").should eq 60

    expect_failure(device.write("occupancysensing", "hold-time", 0), "CONSTRAINT_ERROR")
    expect_failure(device.write("occupancysensing", "piroccupied-to-unoccupied-delay", 0), "CONSTRAINT_ERROR")
    expect_failure(device.write("occupancysensing", "pirunoccupied-to-occupied-threshold", 0), "CONSTRAINT_ERROR")
    expect_success(device.write("occupancysensing", "hold-time", 120))
    read_int(device, "occupancysensing", "hold-time", "HoldTime").should eq 120
    read_int(device, "occupancysensing", "piroccupied-to-unoccupied-delay", "PIROccupiedToUnoccupiedDelay").should eq 120
  end

  it "writes the PIR occupied to unoccupied delay" do
    expect_success(device.write("occupancysensing", "piroccupied-to-unoccupied-delay", 10))
    read_int(device, "occupancysensing", "piroccupied-to-unoccupied-delay", "PIROccupiedToUnoccupiedDelay").should eq 10
    read_int(device, "occupancysensing", "hold-time", "HoldTime").should eq 10
  end

  it "restores configured timing values after restart" do
    device.restart!
    read_int(device, "occupancysensing", "hold-time", "HoldTime").should eq 10
    read_int(device, "occupancysensing", "piroccupied-to-unoccupied-delay", "PIROccupiedToUnoccupiedDelay").should eq 10
  end
end
