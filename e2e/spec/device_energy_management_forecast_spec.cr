require "./e2e_helper"

private FORECAST_CLUSTER = "deviceenergymanagement"

describe "Matter 1.6 Device Energy Management PFR interoperability" do
  device = E2E::Device["matter_laundry_combo"]

  it "commissions a synthetic washer and reads its PFR+STA forecast" do
    device.commission!
    servers = expect_success(device.read("descriptor", "server-list", 1)).int_list("ServerList")
    servers.should contain(0x0098_i64)
    read_int(device, FORECAST_CLUSTER, "cluster-revision", "ClusterRevision").should eq(4_i64)
    read_int(device, FORECAST_CLUSTER, "feature-map", "FeatureMap").should eq(10_i64)
    attributes = expect_success(device.read(FORECAST_CLUSTER, "attribute-list")).int_list("AttributeList")
    attributes.should contain(0x0006_i64)
    attributes.should_not contain(0x0005_i64)
    attributes.should contain(0x0007_i64)
    forecast = expect_success(device.read(FORECAST_CLUSTER, "forecast"))
    forecast.int("ForecastID").should eq(1_i64)
    forecast.ints("NominalPower").should eq([2_500_i64, 800_i64])
    expect_failure(device.chip("any", "command-by-id", "0x98", "0x0",
      %({"0":"s:2000","1":"u:60","2":"u:0"}), device.node, "1"),
      "UNSUPPORTED_COMMAND")
  end

  it "regenerates the host forecast after a device restart" do
    device.restart!
    read_int(device, FORECAST_CLUSTER, "feature-map", "FeatureMap").should eq(10_i64)
    forecast = expect_success(device.read(FORECAST_CLUSTER, "forecast"))
    forecast.int("ForecastID").should eq(1_i64)
    forecast.ints("NominalPower").should eq([2_500_i64, 800_i64])
  end
end
