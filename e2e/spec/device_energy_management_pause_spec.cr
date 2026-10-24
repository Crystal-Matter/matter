require "./e2e_helper"

private PAUSE_CLUSTER = "deviceenergymanagement"

describe "Matter 1.6 Device Energy Management PAU interoperability" do
  device = E2E::Device["matter_pausable_washer"]

  it "reads the pausable active slot and pauses then resumes over chip-tool" do
    device.commission!
    read_int(device, PAUSE_CLUSTER, "feature-map", "FeatureMap").should eq(18_i64)
    forecast = expect_success(device.read(PAUSE_CLUSTER, "forecast"))
    forecast.int("ActiveSlotNumber").should eq(0_i64)
    forecast.ints("MinPauseDuration").should eq([1_i64])
    forecast.ints("MaxPauseDuration").should eq([60_i64])
    expect_failure(device.chip("any", "command-by-id", "0x98", "0x3",
      %({"0":"u:61","1":"u:0"}), device.node, "1"), "CONSTRAINT_ERROR")
    expect_success(device.chip("any", "command-by-id", "0x98", "0x3",
      %({"0":"u:30","1":"u:0"}), device.node, "1"))
    read_int(device, PAUSE_CLUSTER, "esastate", "ESAState").should eq(4_i64)
    expect_success(device.chip(PAUSE_CLUSTER, "read-event", "paused", device.node, "1"))
    expect_success(device.invoke(PAUSE_CLUSTER, "resume-request"))
    read_int(device, PAUSE_CLUSTER, "esastate", "ESAState").should eq(1_i64)
    expect_success(device.chip(PAUSE_CLUSTER, "read-event", "resumed", device.node, "1"))
  end

  it "expires a short pause and resets volatile state on restart" do
    expect_success(device.chip("any", "command-by-id", "0x98", "0x3",
      %({"0":"u:1","1":"u:0"}), device.node, "1"))
    sleep 1.2.seconds
    read_int(device, PAUSE_CLUSTER, "esastate", "ESAState").should eq(1_i64)
    expect_success(device.chip("any", "command-by-id", "0x98", "0x3",
      %({"0":"u:30","1":"u:0"}), device.node, "1"))
    read_int(device, PAUSE_CLUSTER, "esastate", "ESAState").should eq(4_i64)
    device.restart!
    read_int(device, PAUSE_CLUSTER, "esastate", "ESAState").should eq(1_i64)
    expect_success(device.read(PAUSE_CLUSTER, "forecast")).int("ForecastID").should eq(1_i64)
  end
end
