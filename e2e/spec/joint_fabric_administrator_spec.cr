require "./e2e_helper"

describe "joint fabric administrator example" do
  device = E2E::Device["matter_joint_fabric_administrator"]

  it "commissions and exposes the Matter 1.6 administrator device type" do
    device.commission!
    device.commissioned?.should be_true

    expect_success(device.read("descriptor", "device-type-list", 1)).int("DeviceType").should eq(0x0130_i64)

    server_clusters = expect_success(device.read("descriptor", "server-list", 1)).int_list("ServerList")
    server_clusters.should contain(0x0752_i64)
    server_clusters.should contain(0x0753_i64)

    expect_success(device.read("jointfabricadministrator", "cluster-revision", 1)).int("ClusterRevision").should eq(1_i64)
    # The Datastore requires Administer privilege; this commissioner has not
    # been granted access to the shared fabric's administration state.
    device.read("jointfabricdatastore", "cluster-revision", 1).im_status.should eq("UNSUPPORTED_ACCESS")

    administrator_commands = expect_success(device.read("jointfabricadministrator", "accepted-command-list", 1)).int_list("AcceptedCommandList")
    administrator_commands.should contain(0_i64) # ICACCSRRequest
    administrator_commands.should contain(8_i64) # AnnounceJointFabricAdministrator

    device.read("jointfabricdatastore", "accepted-command-list", 1).im_status.should eq("UNSUPPORTED_ACCESS")
  end
end
