require "./e2e_helper"

# examples/matter_ambient_light_sensor_device.cr - Light Sensor on endpoint 1
describe "matter_ambient_light_sensor example" do
  device = E2E::Device["matter_ambient_light_sensor"]

  it "commissions with chip-tool" do
    device.commission!
  end

  it "is a light sensor" do
    expect_success(device.read("descriptor", "device-type-list", 1)).int("DeviceType").should eq 0x0106_i64
    expect_success(device.read("fixedlabel", "label-list")).values("Value").should eq ["Example Ambient Light Sensor"]
  end

  it "reads the measured illuminance (25..1500 lux encoded as 10000*log10(lux)+1)" do
    read_int(device, "illuminancemeasurement", "measured-value", "MeasuredValue").should be_in(13_979..31_762)
  end

  it "reads revision 5 and the fixed sensor configuration" do
    read_int(device, "illuminancemeasurement", "cluster-revision", "ClusterRevision").should eq 5
    read_int(device, "illuminancemeasurement", "min-measured-value", "MinMeasuredValue").should eq 1
    read_int(device, "illuminancemeasurement", "max-measured-value", "MaxMeasuredValue").should eq Matter::Cluster::IlluminanceMeasurement.from_lux(2000.0)
    read_int(device, "illuminancemeasurement", "tolerance", "Tolerance").should eq 0
    read_int(device, "illuminancemeasurement", "light-sensor-type", "LightSensorType").should eq 0
  end

  it "writes the IdentifyTime attribute" do
    expect_success(device.write("identify", "identify-time", 60))
    read_int(device, "identify", "identify-time", "IdentifyTime").should be_in(1..60)
  end
end
