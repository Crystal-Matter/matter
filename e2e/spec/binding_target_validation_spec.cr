require "./e2e_helper"

# Official chip-tool writes the fabric-scoped Binding attribute over CASE.
describe "Matter 1.6 Binding TargetStruct interoperability" do
  device = E2E::Device["matter_binding_validation"]

  it "accepts valid targets and preserves them across restart" do
    device.commission!
    read_int(device, "binding", "cluster-revision", "ClusterRevision").should eq(1)

    valid_unicast = %([{"node":2,"endpoint":1,"cluster":6}])
    expect_success(device.write("binding", "binding", valid_unicast))
    expect_success(device.read("binding", "binding")).output.should contain("Node:")

    device.restart!
    expect_success(device.read("binding", "binding")).output.should contain("Node:")
    expect_success(device.write("binding", "binding", %([{"group":3}])))
    expect_success(device.read("binding", "binding")).output.should contain("Group:")
  end
end
