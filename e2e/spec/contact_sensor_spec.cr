require "./e2e_helper"

# examples/matter_contact_sensor_device.cr - Contact Sensor on endpoint 1
describe "matter_contact_sensor example" do
  device = E2E::Device["matter_contact_sensor"]

  it "commissions with chip-tool" do
    device.commission!
  end

  it "is a contact sensor" do
    expect_success(device.read("descriptor", "device-type-list", 1)).int("DeviceType").should eq 0x0015_i64
    expect_success(device.read("fixedlabel", "label-list")).values("Value").should eq ["Example Contact"]
  end

  it "reads the boolean state" do
    read_bool(device, "booleanstate", "state-value", "StateValue")
  end

  it "rejects writes to the read-only state" do
    device.write("booleanstate", "state-value", 1).success?.should be_false
  end

  it "writes the IdentifyTime attribute" do
    expect_success(device.write("identify", "identify-time", 60))
    read_int(device, "identify", "identify-time", "IdentifyTime").should be_in(1..60)
  end
end
