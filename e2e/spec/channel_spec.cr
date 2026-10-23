require "./e2e_helper"

describe "Matter 1.6 Channel interoperability" do
  device = E2E::Device["matter_channel"]

  it "commissions, reads feature-gated attributes, and tunes by number and text" do
    device.commission!
    server_list = expect_success(device.read("descriptor", "server-list", 1)).int_list("ServerList")
    server_list.should contain(0x0504_i64)
    read_int(device, "channel", "cluster-revision", "ClusterRevision", 1).should eq(2_i64)
    read_int(device, "channel", "feature-map", "FeatureMap", 1).should eq(15_i64)
    expect_success(device.read("channel", "channel-list", 1)).output.should contain("Seven")
    expect_success(device.read("channel", "lineup", 1)).output.should contain("Synthetic Cable")

    expect_success(device.invoke("channel", "change-channel-by-number", ["7", "1"]))
    expect_success(device.read("channel", "current-channel", 1)).output.should contain("Seven")
    response = expect_success(device.invoke("channel", "change-channel", ["sports-nine"]))
    response.output.should contain("ChangeChannelResponse")
    response.int("status").should eq(0_i64)
    expect_success(device.read("channel", "current-channel", 1)).output.should contain("Nine")
    expect_success(device.invoke("channel", "skip-channel", ["-1"]))
    expect_success(device.read("channel", "current-channel", 1)).output.should contain("Seven")

    guide = expect_success(device.invoke("channel", "get-program-guide", options: [
      "--StartTime", "100", "--EndTime", "200",
    ]))
    guide.output.should contain("ProgramGuideResponse")
    guide.output.should contain("Evening News")
    expect_success(device.invoke("channel", "record-program", ["news-100", "true", "[]", "00"]))
    expect_success(device.invoke("channel", "cancel-record-program", ["news-100", "true", "[]", "00"]))

    device.restart!
    expect_success(device.invoke("channel", "change-channel-by-number", ["9", "0"]))
    expect_success(device.read("channel", "current-channel", 1)).output.should contain("Nine")
  end
end
