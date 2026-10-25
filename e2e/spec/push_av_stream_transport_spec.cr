require "./e2e_helper"

describe "official SDK Push AV Stream Transport" do
  device = E2E::Device["matter_push_av_stream_transport"]

  it "commissions and reads the revision-2 fabric-scoped configuration surface" do
    device.commission!
    read_int(device, "pushavstreamtransport", "cluster-revision", "ClusterRevision", 0).should eq(2_i64)
    formats = expect_success(device.read("pushavstreamtransport", "supported-formats", 0))
    formats.output.should contain("SupportedFormats: 1 entries")
    formats.int("ContainerFormat").should eq(0_i64)
    formats.int("IngestMethod").should eq(0_i64)
    expect_success(device.read("pushavstreamtransport", "current-connections", 0)).output
      .should contain("CurrentConnections: 0 entries")
    expect_success(device.read("pushavstreamtransport", "accepted-command-list", 0))
      .int_list("AcceptedCommandList").should eq([0_i64, 2_i64, 3_i64, 4_i64, 5_i64, 6_i64])
    expect_failure(device.invoke("pushavstreamtransport", "manually-trigger-transport",
      ["0", "0"], endpoint: 0), "NOT_FOUND")
    expect_failure(device.invoke("pushavstreamtransport", "find-transport", ["0"], endpoint: 0), "NOT_FOUND")
    device.restart!
    expect_success(device.read("pushavstreamtransport", "current-connections", 0)).output
      .should contain("CurrentConnections: 0 entries")
  end
end
