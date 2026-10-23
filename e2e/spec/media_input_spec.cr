require "./e2e_helper"

describe "Matter 1.6 Media Input interoperability" do
  device = E2E::Device["matter_media_input"]

  it "commissions, selects, presents and renames inputs across restart" do
    device.commission!
    expect_success(device.read("descriptor", "server-list", 1)).int_list("ServerList").should contain(0x0507_i64)
    read_int(device, "mediainput", "cluster-revision", "ClusterRevision", 1).should eq(1_i64)
    read_int(device, "mediainput", "feature-map", "FeatureMap", 1).should eq(1_i64)
    list = expect_success(device.read("mediainput", "input-list", 1))
    list.output.should contain("HDMI 1")
    list.output.should contain("HDMI 2")
    read_int(device, "mediainput", "current-input", "CurrentInput", 1).should eq(1_i64)

    expect_success(device.invoke("mediainput", "select-input", ["2"]))
    read_int(device, "mediainput", "current-input", "CurrentInput", 1).should eq(2_i64)
    expect_failure(device.invoke("mediainput", "select-input", ["3"]), "NOT_FOUND")
    expect_success(device.invoke("mediainput", "show-input-status"))
    expect_success(device.invoke("mediainput", "hide-input-status"))
    expect_success(device.invoke("mediainput", "rename-input", ["2", "Media Box"]))
    expect_success(device.read("mediainput", "input-list", 1)).output.should contain("Media Box")

    device.restart!
    read_int(device, "mediainput", "current-input", "CurrentInput", 1).should eq(2_i64)
    expect_success(device.read("mediainput", "input-list", 1)).output.should contain("Media Box")
  end
end
