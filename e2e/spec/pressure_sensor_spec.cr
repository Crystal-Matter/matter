require "./e2e_helper"

# examples/matter_pressure_sensor_device.cr - Extended Pressure Sensor on endpoint 1
describe "matter_pressure_sensor example" do
  device = E2E::Device["matter_pressure_sensor"]

  it "commissions with chip-tool" do
    device.commission!
  end

  it "advertises Pressure Sensor and revision 5" do
    expect_success(device.read("descriptor", "device-type-list", 1)).int("DeviceType").should eq 0x0305_i64
    read_int(device, "pressuremeasurement", "cluster-revision", "ClusterRevision").should eq 5
    read_int(device, "pressuremeasurement", "feature-map", "FeatureMap").should eq 1
  end

  it "reads standard and scaled pressure values and rejects writes" do
    read_int(device, "pressuremeasurement", "measured-value", "MeasuredValue").should eq 1013
    read_int(device, "pressuremeasurement", "min-measured-value", "MinMeasuredValue").should eq 800
    read_int(device, "pressuremeasurement", "max-measured-value", "MaxMeasuredValue").should eq 1200
    read_int(device, "pressuremeasurement", "tolerance", "Tolerance").should eq 10
    read_int(device, "pressuremeasurement", "scaled-value", "ScaledValue").should eq 10130
    read_int(device, "pressuremeasurement", "min-scaled-value", "MinScaledValue").should eq 8000
    read_int(device, "pressuremeasurement", "max-scaled-value", "MaxScaledValue").should eq 12000
    read_int(device, "pressuremeasurement", "scaled-tolerance", "ScaledTolerance").should eq 100
    read_int(device, "pressuremeasurement", "scale", "Scale").should eq(-1)
    device.write("pressuremeasurement", "measured-value", 1000).success?.should be_false
    device.write("pressuremeasurement", "scaled-value", 10000).success?.should be_false
  end

  it "restores commissioning and fixed sensor capabilities after restart" do
    device.restart!
    read_int(device, "pressuremeasurement", "cluster-revision", "ClusterRevision").should eq 5
    read_int(device, "pressuremeasurement", "min-measured-value", "MinMeasuredValue").should eq 800
    read_int(device, "pressuremeasurement", "max-scaled-value", "MaxScaledValue").should eq 12000
    read_int(device, "pressuremeasurement", "scale", "Scale").should eq(-1)
  end
end
