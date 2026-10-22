require "./e2e_helper"

describe "synthetic Target Navigator interoperability" do
  device = E2E::Device["matter_target_navigator"]

  it "commissions, reads targets, navigates with a typed response, and restarts" do
    device.commission!

    server_list = expect_success(device.read("descriptor", "server-list", 1)).int_list("ServerList")
    server_list.should contain(0x0505_i64)
    read_int(device, "targetnavigator", "cluster-revision", "ClusterRevision", 1).should eq(2_i64)
    read_int(device, "targetnavigator", "current-target", "CurrentTarget", 1).should eq(1_i64)

    targets = expect_success(device.read("targetnavigator", "target-list", 1))
    targets.output.should contain("Home")
    targets.output.should contain("Settings")

    missing = expect_success(device.invoke("targetnavigator", "navigate-target", ["7"], 1, options: ["--Data", "open"]))
    missing.int("status").should eq(1_i64), missing.output
    read_int(device, "targetnavigator", "current-target", "CurrentTarget", 1).should eq(1_i64)

    rejected = expect_success(device.invoke("targetnavigator", "navigate-target", ["2"], 1, options: ["--Data", "deny"]))
    rejected.int("status").should eq(2_i64), rejected.output
    read_int(device, "targetnavigator", "current-target", "CurrentTarget", 1).should eq(1_i64)

    accepted = expect_success(device.invoke("targetnavigator", "navigate-target", ["2"], 1, options: ["--Data", "open"]))
    accepted.int("status").should eq(0_i64), accepted.output
    accepted.output.should contain("ready")
    read_int(device, "targetnavigator", "current-target", "CurrentTarget", 1).should eq(2_i64)

    device.restart!
    expect_success(device.read("targetnavigator", "target-list", 1)).output.should contain("Settings")
    read_int(device, "targetnavigator", "current-target", "CurrentTarget", 1).should eq(1_i64)
  end
end
