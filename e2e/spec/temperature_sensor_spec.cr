require "./e2e_helper"

# examples/matter_temperature_sensor_device.cr - Temperature Sensor on endpoint 1
describe "matter_temperature_sensor example" do
  device = E2E::Device["matter_temperature_sensor"]

  it "commissions with chip-tool" do
    device.commission!
  end

  it "is a temperature sensor" do
    expect_success(device.read("descriptor", "device-type-list", 1)).int("DeviceType").should eq 0x0302_i64
    expect_success(device.read("fixedlabel", "label-list")).values("Value").should eq ["Example Temp"]
  end

  it "reads the measured temperature within the configured range" do
    read_int(device, "temperaturemeasurement", "cluster-revision", "ClusterRevision").should eq 6
    read_int(device, "temperaturemeasurement", "min-measured-value", "MinMeasuredValue").should eq 1500
    read_int(device, "temperaturemeasurement", "max-measured-value", "MaxMeasuredValue").should eq 3500
    read_int(device, "temperaturemeasurement", "tolerance", "Tolerance").should eq 25
    read_int(device, "temperaturemeasurement", "measured-value", "MeasuredValue").should be_in(1500..3500)
  end

  it "exposes nullable fixed capability bounds and an absent optional tolerance" do
    read_int(device, "temperaturemeasurement", "cluster-revision", "ClusterRevision", 2).should eq 6
    read_value(device, "temperaturemeasurement", "min-measured-value", "MinMeasuredValue", 2).should eq "null"
    read_value(device, "temperaturemeasurement", "max-measured-value", "MaxMeasuredValue", 2).should eq "null"
    read_int(device, "temperaturemeasurement", "measured-value", "MeasuredValue", 2).should eq 2250
    expect_failure(device.read("temperaturemeasurement", "tolerance", 2), "UNSUPPORTED_ATTRIBUTE")
    device.restart!
    read_value(device, "temperaturemeasurement", "min-measured-value", "MinMeasuredValue", 2).should eq "null"
    read_value(device, "temperaturemeasurement", "max-measured-value", "MaxMeasuredValue", 2).should eq "null"
    read_int(device, "temperaturemeasurement", "tolerance", "Tolerance").should eq 25
  end

  it "rejects writes to the read-only measured value" do
    device.write("temperaturemeasurement", "measured-value", 2000).success?.should be_false
  end

  it "writes the IdentifyTime attribute" do
    expect_success(device.write("identify", "identify-time", 60))
    read_int(device, "identify", "identify-time", "IdentifyTime").should be_in(1..60)
  end
end
