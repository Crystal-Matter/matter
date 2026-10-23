require "./e2e_helper"

describe "Matter 1.6 Energy EVSE interoperability" do
  device = E2E::Device["matter_appliance_modes"]
  timed = ["--timedInteractionTimeoutMs", "2000"]

  it "reads mandatory charging preferences and the disabled base state" do
    device.commission!
    read_int(device, "energyevse", "cluster-revision", "ClusterRevision", 1).should eq(4_i64)
    read_int(device, "energyevse", "feature-map", "FeatureMap", 1).should eq(1_i64)
    read_int(device, "energyevse", "supply-state", "SupplyState", 1).should eq(0_i64)
    read_int(device, "energyevse", "circuit-capacity", "CircuitCapacity", 1).should eq(32_000_i64)
    expect_failure(device.chip("any", "read-by-id", "0x99", "0x4", device.node, "1"),
      "UNSUPPORTED_ATTRIBUTE")
  end

  it "requires timed charging commands and persists enabled current limits" do
    expect_failure(device.invoke("energyevse", "enable-charging", ["null", "6000", "16000"], endpoint: 1),
      "NEEDS_TIMED_INTERACTION")
    expect_success(device.invoke("energyevse", "enable-charging", ["null", "6000", "16000"],
      endpoint: 1, options: timed))
    read_int(device, "energyevse", "supply-state", "SupplyState", 1).should eq(1_i64)
    read_int(device, "energyevse", "maximum-charge-current", "MaximumChargeCurrent", 1).should eq(16_000_i64)
    device.restart!
    read_int(device, "energyevse", "supply-state", "SupplyState", 1).should eq(1_i64)
    read_int(device, "energyevse", "maximum-charge-current", "MaximumChargeCurrent", 1).should eq(16_000_i64)
    expect_success(device.invoke("energyevse", "disable", endpoint: 1, options: timed))
    read_int(device, "energyevse", "supply-state", "SupplyState", 1).should eq(0_i64)
  end

  it "sets and reads persisted daily targets" do
    schedule = %([{"dayOfWeekForSequence":2,"chargingTargets":[{"targetTimeMinutesPastMidnight":480,"addedEnergy":12000}]}])
    expect_success(device.invoke("energyevse", "set-targets", [schedule], endpoint: 1, options: timed))
    expect_success(device.invoke("energyevse", "get-targets", endpoint: 1, options: timed))
      .output.should contain("12000")
    device.restart!
    expect_success(device.invoke("energyevse", "get-targets", endpoint: 1, options: timed))
      .output.should contain("12000")
    expect_success(device.invoke("energyevse", "clear-targets", endpoint: 1, options: timed))
    expect_success(device.invoke("energyevse", "get-targets", endpoint: 1, options: timed))
      .output.should contain("0 entries")
  end
end
