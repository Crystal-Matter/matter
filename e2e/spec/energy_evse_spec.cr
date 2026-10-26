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

  it "exposes opt-in V2X only on the bidirectional EVSE endpoint" do
    read_int(device, "energyevse", "feature-map", "FeatureMap", 3).should eq(17_i64)
    read_int(device, "energyevse", "maximum-discharge-current", "MaximumDischargeCurrent", 3).should eq(0_i64)
    expect_success(device.invoke("energyevse", "enable-charging", ["null", "6000", "16000"],
      endpoint: 3, options: timed))
    expect_failure(device.invoke("energyevse", "enable-discharging", ["null", "10000"], endpoint: 3),
      "NEEDS_TIMED_INTERACTION")
    expect_success(device.invoke("energyevse", "enable-discharging", ["null", "10000"],
      endpoint: 3, options: timed))
    read_int(device, "energyevse", "supply-state", "SupplyState", 3).should eq(5_i64)
    read_int(device, "energyevse", "maximum-charge-current", "MaximumChargeCurrent", 3).should eq(16_000_i64)
    read_int(device, "energyevse", "maximum-discharge-current", "MaximumDischargeCurrent", 3).should eq(10_000_i64)
    device.restart!
    read_int(device, "energyevse", "supply-state", "SupplyState", 3).should eq(5_i64)
    expect_success(device.invoke("energyevse", "disable", endpoint: 3, options: timed))
    read_int(device, "energyevse", "supply-state", "SupplyState", 3).should eq(0_i64)
    read_int(device, "energyevse", "feature-map", "FeatureMap", 1).should eq(1_i64)
  end

  it "reports V2X charge and discharge session events through chip-tool" do
    key = "hex:000102030405060708090a0b0c0d0e0f"
    trigger = ->(id : UInt64) do
      expect_success(device.invoke("generaldiagnostics", "test-event-trigger",
        [key, id.to_s], endpoint: 0))
    end
    expect_failure(device.invoke("generaldiagnostics", "test-event-trigger",
      ["hex:ffffffffffffffffffffffffffffffff", 0x0099_0000_0000_0002_u64.to_s], endpoint: 0),
      "CONSTRAINT_ERROR")
    expect_success(device.invoke("energyevse", "enable-charging", ["null", "6000", "16000"],
      endpoint: 3, options: timed))
    expect_success(device.invoke("energyevse", "enable-discharging", ["null", "10000"],
      endpoint: 3, options: timed))

    trigger.call(0x0099_0000_0000_0002_u64)
    expect_success(device.chip("energyevse", "read-event", "evconnected", device.node, "3"))
      .ints("SessionID").last.should eq(1_i64)
    trigger.call(0x0099_0000_0000_0004_u64)
    started = expect_success(device.chip("energyevse", "read-event", "energy-transfer-started", device.node, "3"))
    started.ints("MaximumCurrent").last.should eq(16_000_i64)
    started.ints("MaximumDischargeCurrent").last.should eq(10_000_i64)
    trigger.call(0x0099_0000_0000_0005_u64)
    expect_success(device.chip("energyevse", "read-event", "energy-transfer-stopped", device.node, "3"))
      .ints("EnergyTransferred").last.should eq(1_000_i64)

    trigger.call(0x0099_0000_0000_0080_u64)
    started = expect_success(device.chip("energyevse", "read-event", "energy-transfer-started", device.node, "3"))
    started.ints("MaximumDischargeCurrent").last.should eq(10_000_i64)
    trigger.call(0x0099_0000_0000_0081_u64)
    stopped = expect_success(device.chip("energyevse", "read-event", "energy-transfer-stopped", device.node, "3"))
    stopped.ints("EnergyDischarged").last.should eq(2_000_i64)
    read_int(device, "energyevse", "session-energy-discharged", "SessionEnergyDischarged", 3)
      .should eq(2_000_i64)

    trigger.call(0x0099_0000_0000_0003_u64)
    expect_success(device.chip("energyevse", "read-event", "evnot-detected", device.node, "3"))
      .ints("SessionEnergyDischarged").last.should eq(2_000_i64)
    expect_success(device.invoke("energyevse", "disable", endpoint: 3, options: timed))
  end
end
