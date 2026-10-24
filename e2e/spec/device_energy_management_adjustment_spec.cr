require "./e2e_helper"

private FA_CLUSTER = "deviceenergymanagement"

private def modify_forecast(device : E2E::Device, id : Int32, power : Int32,
                            duration : Int32) : E2E::Result
  payload = %({"0":"u:#{id}","1":[{"0":"u:0","1":"s:#{power}","2":"u:#{duration}"}],"2":"u:0"})
  device.chip("any", "command-by-id", "0x98", "0x5", payload, device.node, "1")
end

describe "Matter 1.6 Device Energy Management FA interoperability" do
  device = E2E::Device["matter_adjustable_heater"]

  it "commissions the PFR+FA heater and modifies and cancels a forecast" do
    device.commission!
    read_int(device, FA_CLUSTER, "feature-map", "FeatureMap").should eq(34_i64)
    before = expect_success(device.read(FA_CLUSTER, "forecast"))
    before.int("ForecastID").should eq(1_i64)
    before.ints("MinPowerAdjustment").should eq([500_i64])
    before.ints("MaxDurationAdjustment").should eq([1_800_i64])
    expect_failure(modify_forecast(device, 0, 2_500, 1_500), "INVALID_IN_STATE")
    expect_failure(modify_forecast(device, 1, 4_001, 1_500), "CONSTRAINT_ERROR")
    expect_success(modify_forecast(device, 1, 2_500, 1_500))
    changed = expect_success(device.read(FA_CLUSTER, "forecast"))
    changed.int("ForecastID").should eq(2_i64)
    changed.ints("NominalPower").should eq([2_500_i64])
    changed.ints("DefaultDuration").should eq([1_500_i64])
    changed.int("ForecastUpdateReason").should eq(1_i64)
    expect_success(device.invoke(FA_CLUSTER, "cancel-request"))
    restored = expect_success(device.read(FA_CLUSTER, "forecast"))
    restored.int("ForecastID").should eq(3_i64)
    restored.ints("NominalPower").should eq([2_000_i64])
  end

  it "starts with a fresh host forecast after restart" do
    device.restart!
    forecast = expect_success(device.read(FA_CLUSTER, "forecast"))
    forecast.int("ForecastID").should eq(1_i64)
    forecast.ints("NominalPower").should eq([2_000_i64])
  end
end
