require "./e2e_helper"

private STA_CLUSTER = "deviceenergymanagement"

describe "Matter 1.6 Device Energy Management STA interoperability" do
  device = E2E::Device["matter_laundry_combo"]

  it "shifts a host-approved future forecast and cancels it over chip-tool" do
    device.commission!
    read_int(device, STA_CLUSTER, "feature-map", "FeatureMap").should eq(10_i64)
    before = expect_success(device.read(STA_CLUSTER, "forecast"))
    start = before.int("StartTime") || raise "missing forecast StartTime"
    ending = before.int("EndTime") || raise "missing forecast EndTime"
    before.int("ForecastID").should eq(1_i64)
    before.value("EarliestStartTime").should_not be_nil
    requested = start + 60_i64
    expect_success(device.chip("any", "command-by-id", "0x98", "0x2",
      %({"0":"u:#{requested}","1":"u:0"}), device.node, "1"))
    shifted = expect_success(device.read(STA_CLUSTER, "forecast"))
    shifted.int("ForecastID").should eq(2_i64)
    shifted.int("StartTime").should eq(requested)
    shifted.int("EndTime").should eq(ending + 60_i64)
    shifted.int("ForecastUpdateReason").should eq(1_i64)
    expect_success(device.invoke(STA_CLUSTER, "cancel-request"))
    restored = expect_success(device.read(STA_CLUSTER, "forecast"))
    restored.int("ForecastID").should eq(3_i64)
    restored.int("StartTime").should eq(start)
    restored.int("ForecastUpdateReason").should eq(0_i64)
  end

  it "starts with a new host forecast after restart" do
    device.restart!
    read_int(device, STA_CLUSTER, "feature-map", "FeatureMap").should eq(10_i64)
    expect_success(device.read(STA_CLUSTER, "forecast")).int("ForecastID").should eq(1_i64)
  end
end
