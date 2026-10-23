require "./e2e_helper"

private OVEN_MODE_CLUSTER  = "ovenmode"
private OVEN_STATE_CLUSTER = "ovencavityoperationalstate"

describe "Matter 1.6 paired oven interoperability" do
  device = E2E::Device["matter_oven"]

  it "commissions and reads the oven mode and cavity state schemas" do
    device.commission!
    read_int(device, OVEN_MODE_CLUSTER, "cluster-revision", "ClusterRevision", 1).should eq(2_i64)
    read_int(device, OVEN_MODE_CLUSTER, "feature-map", "FeatureMap", 1).should eq(0_i64)
    read_int(device, OVEN_MODE_CLUSTER, "current-mode", "CurrentMode", 1).should eq(0_i64)
    expect_success(device.read(OVEN_MODE_CLUSTER, "supported-modes", 1)).output.should contain("Bake")
    read_int(device, OVEN_STATE_CLUSTER, "cluster-revision", "ClusterRevision", 1).should eq(2_i64)
    read_int(device, OVEN_STATE_CLUSTER, "current-phase", "CurrentPhase", 1).should eq(0_i64)
    read_int(device, OVEN_STATE_CLUSTER, "countdown-time", "CountdownTime", 1).should eq(120_i64)
    read_int(device, OVEN_STATE_CLUSTER, "operational-state", "OperationalState", 1).should eq(0_i64)
  end

  it "changes mode and runs Start and Stop while refusing Pause and Resume" do
    unsupported = expect_success(device.invoke(OVEN_MODE_CLUSTER, "change-to-mode", ["7"], endpoint: 1))
    unsupported.int("status").should eq(1_i64)
    accepted = expect_success(device.invoke(OVEN_MODE_CLUSTER, "change-to-mode", ["1"], endpoint: 1))
    accepted.int("status").should eq(0_i64)
    read_int(device, OVEN_MODE_CLUSTER, "current-mode", "CurrentMode", 1).should eq(1_i64)

    { {"start", 1_i64}, {"stop", 0_i64} }.each do |command, state|
      response = expect_success(device.invoke(OVEN_STATE_CLUSTER, command, endpoint: 1))
      response.int("ErrorStateID").should eq(0_i64)
      read_int(device, OVEN_STATE_CLUSTER, "operational-state", "OperationalState", 1).should eq(state)
    end
    expect_failure(device.chip("any", "command-by-id", "0x48", "0x0", "{}", device.node, "1"), "UNSUPPORTED_COMMAND")
    expect_failure(device.chip("any", "command-by-id", "0x48", "0x3", "{}", device.node, "1"), "UNSUPPORTED_COMMAND")
  end

  it "restores the selected mode while physical state starts stopped" do
    device.restart!
    read_int(device, OVEN_MODE_CLUSTER, "current-mode", "CurrentMode", 1).should eq(1_i64)
    read_int(device, OVEN_STATE_CLUSTER, "operational-state", "OperationalState", 1).should eq(0_i64)
  end
end
