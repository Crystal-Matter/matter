require "./e2e_helper"

describe "Matter 1.6 Content Launcher interoperability" do
  device = E2E::Device["matter_content_launcher"]

  it "commissions and exposes revision two feature-gated metadata and persisted URL capabilities" do
    device.commission!
    expect_success(device.read("descriptor", "server-list", 1)).int_list("ServerList").should contain(0x050A_i64)
    read_int(device, "contentlauncher", "cluster-revision", "ClusterRevision", 1).should eq(2_i64)
    read_int(device, "contentlauncher", "feature-map", "FeatureMap", 1).should eq(31_i64)
    read_int(device, "contentlauncher", "feature-map", "FeatureMap", 2).should eq(1_i64)
    read_int(device, "contentlauncher", "supported-streaming-protocols", "SupportedStreamingProtocols", 1).should eq(3_i64)
    expect_success(device.read("contentlauncher", "accept-header", 1)).output.should contain("video/mp4")
    expect_failure(device.read("contentlauncher", "accept-header", 2), "UNSUPPORTED_ATTRIBUTE")
    device.restart!
    read_int(device, "contentlauncher", "supported-streaming-protocols", "SupportedStreamingProtocols", 1).should eq(3_i64)
  end

  it "invokes the URL playback host and receives typed LauncherResponse statuses" do
    launched = expect_success(device.invoke("contentlauncher", "launch-url", ["https://example.test/video.mp4"]))
    launched.output.should contain("LauncherResponse")
    launched.int("status").should eq(0_i64)
    unavailable = expect_success(device.invoke("contentlauncher", "launch-url", ["https://example.test/unavailable.mp4"]))
    unavailable.int("status").should eq(1_i64)
    expect_failure(device.invoke("contentlauncher", "launch-url", ["https://example.test/video.mp4"], endpoint: 2), "UNSUPPORTED_COMMAND")
  end
end
