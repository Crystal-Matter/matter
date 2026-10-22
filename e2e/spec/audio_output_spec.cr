require "./e2e_helper"

describe "Matter 1.6 Audio Output interoperability" do
  device = E2E::Device["matter_audio_output"]

  it "commissions and selects, renames, and persists outputs with official chip-tool" do
    device.commission!
    server_list = expect_success(device.read("descriptor", "server-list", 1)).int_list("ServerList")
    server_list.should contain(0x050B_i64)
    read_int(device, "audiooutput", "cluster-revision", "ClusterRevision", 1).should eq(1_i64)
    read_int(device, "audiooutput", "feature-map", "FeatureMap", 1).should eq(1_i64)
    read_int(device, "audiooutput", "feature-map", "FeatureMap", 2).should eq(0_i64)
    base_commands = expect_success(device.read("audiooutput", "accepted-command-list", 2)).int_list("AcceptedCommandList")
    base_commands.should contain(0_i64)
    base_commands.should_not contain(1_i64)

    catalogue = expect_success(device.read("audiooutput", "output-list", 1))
    catalogue.output.should contain("Speakers")
    catalogue.output.should contain("Soundbar")
    read_int(device, "audiooutput", "current-output", "CurrentOutput", 1).should eq(0_i64)

    expect_failure(device.invoke("audiooutput", "select-output", ["9"]), "NOT_FOUND")
    expect_success(device.invoke("audiooutput", "select-output", ["2"]))
    read_int(device, "audiooutput", "current-output", "CurrentOutput", 1).should eq(2_i64)
    expect_failure(device.invoke("audiooutput", "rename-output", ["2", "é" * 17]), "CONSTRAINT_ERROR")
    expect_success(device.invoke("audiooutput", "rename-output", ["2", "Living Room"]))
    expect_success(device.read("audiooutput", "output-list", 1)).output.should contain("Living Room")
    expect_success(device.read("audiooutput", "output-list", 2)).output.should contain("Soundbar")

    device.restart!
    read_int(device, "audiooutput", "current-output", "CurrentOutput", 1).should eq(2_i64)
    expect_success(device.read("audiooutput", "output-list", 1)).output.should contain("Living Room")
    expect_success(device.read("audiooutput", "output-list", 2)).output.should contain("Soundbar")
    restarted_log = File.read(File.join(E2E::LOG_DIR, "matter_audio_output.log")).split(E2E::RESTART_BANNER).last
    restarted_log.should contain("Synthetic audio route: 2")
  end
end
