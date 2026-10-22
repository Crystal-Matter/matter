require "./e2e_helper"

describe "synthetic ecosystem bridge" do
  device = E2E::Device["matter_ecosystem_bridge"]

  it "commissions the opt-in fixture with official chip-tool" do
    device.commission!
  end

  it "reads the Matter 1.6 Ecosystem Information directories" do
    revision = expect_success(device.read("ecosysteminformation", "cluster-revision", 1))
    revision.int("ClusterRevision").should eq(1_i64)

    directory = expect_success(device.read("ecosysteminformation", "device-directory", 1))
    directory.output.should contain("Synthetic lamp fabric 1")
    directory.output.should contain("FabricIndex")

    locations = expect_success(device.read("ecosysteminformation", "location-directory", 1))
    locations.output.should contain("synthetic-room-1")
    locations.output.should contain("Synthetic kitchen fabric 1")
  end

  it "retains the published directory across a device restart" do
    device.restart!
    expect_success(device.read("ecosysteminformation", "device-directory", 1)).output
      .should contain("Synthetic lamp fabric 1")
    expect_success(device.read("ecosysteminformation", "location-directory", 1)).output
      .should contain("synthetic-room-1")
  end

  it "keeps synthetic metadata isolated after commissioning a second fabric" do
    window = expect_success(device.chip(["pairing", "open-commissioning-window",
                                         device.node, "1", "180", "1000", "3840"]))
    pairing_code = window.output.match(/Manual pairing code:\s*\[?([0-9]{4}-[0-9]{3}-[0-9]{4}|[0-9]{11})\]?/i)
      .try(&.[1]) || fail("no enhanced-window pairing code in chip-tool output\n#{window.tail}")

    second_storage = File.join(E2E::STORAGE_ROOT, "matter_ecosystem_bridge_second")
    Dir.mkdir_p(second_storage)
    expect_success(E2E.run(["pairing", "code", "2", pairing_code], second_storage))

    second_device = expect_success(E2E.run(
      ["ecosysteminformation", "read", "device-directory", "2", "1"], second_storage))
    second_device.output.should contain("Synthetic lamp fabric 2")
    second_device.output.should_not contain("Synthetic lamp fabric 1")

    second_location = expect_success(E2E.run(
      ["ecosysteminformation", "read", "location-directory", "2", "1"], second_storage))
    second_location.output.should contain("synthetic-room-2")
    second_location.output.should_not contain("synthetic-room-1")

    original = expect_success(device.read("ecosysteminformation", "device-directory", 1))
    original.output.should contain("Synthetic lamp fabric 1")
    original.output.should_not contain("Synthetic lamp fabric 2")
  end
end
