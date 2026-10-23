require "./e2e_helper"

private DEM_CLUSTER  = "deviceenergymanagement"
private DEM_ENDPOINT = "1"

private def power_adjust(device : E2E::Device, power : Int64, duration : UInt32,
                         cause : UInt8 = 0_u8) : E2E::Result
  device.chip("any", "command-by-id", "0x98", "0x0",
    %({"0":"s:#{power}","1":"u:#{duration}","2":"u:#{cause}"}),
    device.node, DEM_ENDPOINT)
end

describe "Matter 1.6 Device Energy Management PA interoperability" do
  device = E2E::Device["matter_water_heater"]

  it "commissions the synthetic heater and reads its rev4 PA nameplate" do
    device.commission!
    servers = expect_success(device.read("descriptor", "server-list", 1)).int_list("ServerList")
    servers.should contain(0x0098_i64)
    read_int(device, DEM_CLUSTER, "cluster-revision", "ClusterRevision").should eq(4_i64)
    read_int(device, DEM_CLUSTER, "feature-map", "FeatureMap").should eq(1_i64)
    read_int(device, DEM_CLUSTER, "esatype", "ESAType").should eq(2_i64)
    read_bool(device, DEM_CLUSTER, "esacan-generate", "ESACanGenerate").should be_false
    read_int(device, DEM_CLUSTER, "abs-min-power", "AbsMinPower").should eq(0_i64)
    read_int(device, DEM_CLUSTER, "abs-max-power", "AbsMaxPower").should eq(5_000_000_i64)
    expect_failure(device.chip("any", "read-by-id", "0x98", "0x6", device.node, DEM_ENDPOINT),
      "UNSUPPORTED_ATTRIBUTE")
  end

  it "rejects out-of-range power, starts and cancels a real PA session" do
    expect_failure(power_adjust(device, 4_000_001_i64, 60_u32), "CONSTRAINT_ERROR")
    expect_failure(power_adjust(device, 2_000_000_i64, 3_601_u32), "CONSTRAINT_ERROR")
    expect_success(power_adjust(device, 2_000_000_i64, 60_u32))
    read_int(device, DEM_CLUSTER, "esastate", "ESAState").should eq(3_i64)
    read_int(device, "waterheatermanagement", "heat-demand", "HeatDemand").should eq(1_i64)
    expect_success(device.chip(DEM_CLUSTER, "read-event", "power-adjust-start", device.node, DEM_ENDPOINT))
    expect_success(device.invoke(DEM_CLUSTER, "cancel-power-adjust-request"))
    read_int(device, DEM_CLUSTER, "esastate", "ESAState").should eq(1_i64)
    read_int(device, "waterheatermanagement", "heat-demand", "HeatDemand").should eq(0_i64)
    expect_success(device.chip(DEM_CLUSTER, "read-event", "power-adjust-end", device.node, DEM_ENDPOINT))
  end

  it "resets a live adjustment on restart without restoring stale power control" do
    expect_success(power_adjust(device, 2_000_000_i64, 60_u32))
    read_int(device, DEM_CLUSTER, "esastate", "ESAState").should eq(3_i64)
    device.restart!
    read_int(device, DEM_CLUSTER, "esastate", "ESAState").should eq(1_i64)
    read_int(device, DEM_CLUSTER, "feature-map", "FeatureMap").should eq(1_i64)
    expect_success(device.invoke(DEM_CLUSTER, "cancel-power-adjust-request"))
  end
end
