require "./e2e_helper"

private WATER_HEATER_ENDPOINT = "1"
private WATER_HEATER_MGMT     = "0x94"

private def water_heater_boost(device : E2E::Device, duration : UInt32) : E2E::Result
  device.chip("any", "command-by-id", WATER_HEATER_MGMT, "0x0",
    %({"0":{"0":"u:#{duration}"}}), device.node, WATER_HEATER_ENDPOINT)
end

describe "Matter 1.6 Water Heater interoperability" do
  device = E2E::Device["matter_water_heater"]

  it "commissions a thermostat-backed endpoint with both Water Heater clusters" do
    device.commission!
    servers = expect_success(device.read("descriptor", "server-list", 1)).int_list("ServerList")
    servers.should contain(0x0201_i64)
    servers.should contain(0x0094_i64)
    servers.should contain(0x009E_i64)
    read_int(device, "waterheatermode", "cluster-revision", "ClusterRevision").should eq(1_i64)
    read_int(device, "waterheatermanagement", "cluster-revision", "ClusterRevision").should eq(2_i64)
    read_int(device, "waterheatermode", "feature-map", "FeatureMap").should eq(0_i64)
    read_int(device, "waterheatermanagement", "feature-map", "FeatureMap").should eq(3_i64)
    expect_failure(device.chip("any", "read-by-id", "0x9e", "0x2", device.node, WATER_HEATER_ENDPOINT), "UNSUPPORTED_ATTRIBUTE")
    expect_failure(device.chip("any", "read-by-id", "0x9e", "0x3", device.node, WATER_HEATER_ENDPOINT), "UNSUPPORTED_ATTRIBUTE")
    read_int(device, "waterheatermanagement", "tank-volume", "TankVolume").should eq(100_i64)
    read_int(device, "waterheatermanagement", "tank-percentage", "TankPercentage").should eq(40_i64)
  end

  it "changes modes through a typed response and retains CurrentMode across restart" do
    unsupported = expect_success(device.invoke("waterheatermode", "change-to-mode", ["9"]))
    unsupported.int("status").should eq(1_i64)
    accepted = expect_success(device.invoke("waterheatermode", "change-to-mode", ["1"]))
    accepted.int("status").should eq(0_i64)
    read_int(device, "waterheatermode", "current-mode", "CurrentMode").should eq(1_i64)
    device.restart!
    read_int(device, "waterheatermode", "current-mode", "CurrentMode").should eq(1_i64)
  end

  it "validates Boost, updates state, and emits revision-two events" do
    expect_failure(water_heater_boost(device, 0_u32), "CONSTRAINT_ERROR")
    expect_success(water_heater_boost(device, 60_u32))
    read_int(device, "waterheatermanagement", "boost-state", "BoostState").should eq(1_i64)
    read_int(device, "waterheatermanagement", "heat-demand", "HeatDemand").should eq(1_i64)
    expect_success(device.chip("waterheatermanagement", "read-event", "boost-started", device.node, WATER_HEATER_ENDPOINT))
    expect_success(device.invoke("waterheatermanagement", "cancel-boost"))
    read_int(device, "waterheatermanagement", "boost-state", "BoostState").should eq(0_i64)
    read_int(device, "waterheatermanagement", "heat-demand", "HeatDemand").should eq(0_i64)
    expect_success(device.chip("waterheatermanagement", "read-event", "boost-ended", device.node, WATER_HEATER_ENDPOINT))
  end
end
