require "./e2e_helper"

private RVC_RUN   = "rvcrunmode"
private RVC_CLEAN = "rvccleanmode"
private RVC_STATE = "rvcoperationalstate"

describe "Matter 1.6 robotic vacuum interoperability" do
  device = E2E::Device["matter_rvc"]

  it "commissions and reads all three RVC cluster schemas" do
    device.commission!
    read_int(device, RVC_RUN, "cluster-revision", "ClusterRevision", 1).should eq(4_i64)
    read_int(device, RVC_RUN, "feature-map", "FeatureMap", 1).should eq(0_i64)
    expect_success(device.read(RVC_RUN, "supported-modes", 1)).output.should contain("Cleaning")
    read_int(device, RVC_CLEAN, "cluster-revision", "ClusterRevision", 1).should eq(5_i64)
    expect_success(device.read(RVC_CLEAN, "supported-modes", 1)).output.should contain("Vacuum")
    read_int(device, RVC_STATE, "cluster-revision", "ClusterRevision", 1).should eq(3_i64)
    read_int(device, RVC_STATE, "operational-state", "OperationalState", 1).should eq(0_i64)
    expect_success(device.read(RVC_STATE, "operational-state-list", 1)).output.should contain("64")
  end

  it "changes modes, enforces DirectModeChange, and handles Pause Resume GoHome" do
    expect_success(device.invoke(RVC_CLEAN, "change-to-mode", ["1"], endpoint: 1)).int("status").should eq(0_i64)
    expect_success(device.invoke(RVC_RUN, "change-to-mode", ["1"], endpoint: 1)).int("status").should eq(0_i64)
    read_int(device, RVC_STATE, "operational-state", "OperationalState", 1).should eq(1_i64)
    expect_success(device.invoke(RVC_RUN, "change-to-mode", ["2"], endpoint: 1)).int("status").should eq(3_i64)
    expect_success(device.invoke(RVC_CLEAN, "change-to-mode", ["0"], endpoint: 1)).int("status").should eq(3_i64)
    read_int(device, RVC_RUN, "current-mode", "CurrentMode", 1).should eq(1_i64)
    read_int(device, RVC_CLEAN, "current-mode", "CurrentMode", 1).should eq(1_i64)

    expect_success(device.invoke(RVC_STATE, "resume", endpoint: 1)).int("ErrorStateID").should eq(0_i64)
    read_int(device, RVC_STATE, "operational-state", "OperationalState", 1).should eq(1_i64)

    expect_success(device.invoke(RVC_STATE, "pause", endpoint: 1)).int("ErrorStateID").should eq(0_i64)
    read_int(device, RVC_STATE, "operational-state", "OperationalState", 1).should eq(2_i64)
    expect_success(device.invoke(RVC_STATE, "resume", endpoint: 1)).int("ErrorStateID").should eq(0_i64)
    read_int(device, RVC_STATE, "operational-state", "OperationalState", 1).should eq(1_i64)
    expect_success(device.invoke(RVC_STATE, "go-home", endpoint: 1)).int("ErrorStateID").should eq(0_i64)
    read_int(device, RVC_STATE, "operational-state", "OperationalState", 1).should eq(64_i64)
    expect_failure(device.chip("any", "command-by-id", "0x61", "0x1", "{}", device.node, "1"), "UNSUPPORTED_COMMAND")
  end

  it "returns to Idle and restores persistent modes after restart" do
    expect_success(device.invoke(RVC_RUN, "change-to-mode", ["0"], endpoint: 1)).int("status").should eq(0_i64)
    device.restart!
    read_int(device, RVC_RUN, "current-mode", "CurrentMode", 1).should eq(0_i64)
    read_int(device, RVC_CLEAN, "current-mode", "CurrentMode", 1).should eq(1_i64)
    read_int(device, RVC_STATE, "operational-state", "OperationalState", 1).should eq(0_i64)
  end
end
