require "./e2e_helper"

describe "Matter 1.6 Dishwasher and Laundry Washer Mode interoperability" do
  device = E2E::Device["matter_appliance_modes"]

  it "commissions and reads the two derived Mode Base clusters" do
    device.commission!
    {"dishwashermode", "laundrywashermode"}.each do |cluster|
      read_int(device, cluster, "cluster-revision", "ClusterRevision", 1).should eq(3_i64)
      read_int(device, cluster, "feature-map", "FeatureMap", 1).should eq(0_i64)
      read_int(device, cluster, "current-mode", "CurrentMode", 1).should eq(0_i64)
      expect_success(device.read(cluster, "supported-modes", 1)).output.should contain("Normal")
    end
  end

  it "returns Mode Base response status for unsupported and supported transitions" do
    {"dishwashermode", "laundrywashermode"}.each do |cluster|
      unsupported = expect_success(device.invoke(cluster, "change-to-mode", ["7"], endpoint: 1))
      unsupported.int("status").should eq(1_i64)
      read_int(device, cluster, "current-mode", "CurrentMode", 1).should eq(0_i64)

      accepted = expect_success(device.invoke(cluster, "change-to-mode", ["1"], endpoint: 1))
      accepted.int("status").should eq(0_i64)
      read_int(device, cluster, "current-mode", "CurrentMode", 1).should eq(1_i64)
    end
    device.restart!
    read_int(device, "dishwashermode", "current-mode", "CurrentMode", 1).should eq(1_i64)
    read_int(device, "laundrywashermode", "current-mode", "CurrentMode", 1).should eq(1_i64)
  end

  it "exposes Microwave Oven Mode without its disallowed mode-change command" do
    revision = expect_success(device.chip("any", "read-by-id", "0x5e", "0xfffd", device.node, "1"))
    revision.output.should contain("Data = 2")
    current = expect_success(device.chip("any", "read-by-id", "0x5e", "0x1", device.node, "1"))
    current.output.should contain("Data = 0")
    catalogue = expect_success(device.chip("any", "read-by-id", "0x5e", "0x0", device.node, "1"))
    catalogue.output.should contain("Normal")
    expect_failure(device.chip("any", "read-by-id", "0x5e", "0x2", device.node, "1"), "UNSUPPORTED_ATTRIBUTE")
    expect_failure(device.chip("any", "command-by-id", "0x5e", "0x0", %({"0": "u:1"}), device.node, "1"),
      "UNSUPPORTED_COMMAND")
  end

  it "uses Microwave Oven Control to set mode, time and power atomically" do
    revision = expect_success(device.chip("any", "read-by-id", "0x5f", "0xfffd", device.node, "1"))
    revision.output.should contain("Data = 1")
    feature = expect_success(device.chip("any", "read-by-id", "0x5f", "0xfffc", device.node, "1"))
    feature.output.should contain("Data = 1")
    expect_failure(device.chip("any", "read-by-id", "0x5f", "0x3", device.node, "1"),
      "UNSUPPORTED_ATTRIBUTE")

    expect_failure(device.chip("any", "command-by-id", "0x5f", "0x0", "{}", device.node, "1"),
      "INVALID_COMMAND")
    expect_success(device.chip("any", "command-by-id", "0x5f", "0x0", %({"0": "u:0"}), device.node, "1"))
    read_int(device, "microwaveovenmode", "current-mode", "CurrentMode", 1).should eq(0_i64)
    read_int(device, "microwaveovencontrol", "cook-time", "CookTime", 1).should eq(30_i64)
    read_int(device, "microwaveovencontrol", "power-setting", "PowerSetting", 1).should eq(100_i64)

    expect_failure(device.chip("any", "command-by-id", "0x5f", "0x0",
      %({"0": "u:1", "1": "u:120", "2": "u:55"}), device.node, "1"), "CONSTRAINT_ERROR")
    expect_failure(device.chip("any", "command-by-id", "0x5f", "0x0",
      %({"3": "u:1"}), device.node, "1"), "INVALID_COMMAND")
    read_int(device, "microwaveovenmode", "current-mode", "CurrentMode", 1).should eq(0_i64)
    read_int(device, "microwaveovencontrol", "cook-time", "CookTime", 1).should eq(30_i64)

    expect_success(device.chip("any", "command-by-id", "0x5f", "0x0",
      %({"0": "u:1", "1": "u:120", "2": "u:50"}), device.node, "1"))
    read_int(device, "microwaveovenmode", "current-mode", "CurrentMode", 1).should eq(1_i64)
    read_int(device, "microwaveovencontrol", "cook-time", "CookTime", 1).should eq(120_i64)
    read_int(device, "microwaveovencontrol", "power-setting", "PowerSetting", 1).should eq(50_i64)

    expect_success(device.chip("any", "command-by-id", "0x5f", "0x1",
      %({"0": "u:30"}), device.node, "1"))
    read_int(device, "microwaveovencontrol", "cook-time", "CookTime", 1).should eq(150_i64)
    device.restart!
    read_int(device, "microwaveovenmode", "current-mode", "CurrentMode", 1).should eq(1_i64)
    read_int(device, "microwaveovencontrol", "cook-time", "CookTime", 1).should eq(150_i64)
    read_int(device, "microwaveovencontrol", "power-setting", "PowerSetting", 1).should eq(50_i64)
  end

  it "exposes a conforming Microwave Oven device endpoint" do
    expect_success(device.read("descriptor", "device-type-list", 2)).int("DeviceType").should eq(0x0079_i64)
    read_int(device, "operationalstate", "countdown-time", "CountdownTime", 2).should eq(0_i64)
    read_int(device, "operationalstate", "operational-state", "OperationalState", 2).should eq(0_i64)
    read_int(device, "microwaveovenmode", "current-mode", "CurrentMode", 2).should eq(0_i64)
    read_int(device, "microwaveovencontrol", "cook-time", "CookTime", 2).should eq(30_i64)

    expect_success(device.chip("any", "command-by-id", "0x5f", "0x0",
      %({"0": "u:1", "1": "u:120", "2": "u:50"}), device.node, "2"))
    read_int(device, "microwaveovenmode", "current-mode", "CurrentMode", 2).should eq(1_i64)
    read_int(device, "operationalstate", "countdown-time", "CountdownTime", 2).should eq(120_i64)
    read_int(device, "microwaveovencontrol", "power-setting", "PowerSetting", 2).should eq(50_i64)
  end
end
