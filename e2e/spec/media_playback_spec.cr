require "./e2e_helper"

private def playback_status(device : E2E::Device, command : String, fields : Array(String) = [] of String) : Int64?
  response = expect_success(device.invoke("mediaplayback", command, fields, endpoint: 1))
  response.output.should contain("PlaybackResponse: {")
  response.int("status")
end

describe "Matter 1.6 Media Playback interoperability" do
  device = E2E::Device["matter_media_playback"]

  it "commissions, reads feature-gated attributes and exercises playback transitions" do
    device.commission!
    expect_success(device.read("descriptor", "server-list", 1)).int_list("ServerList").should contain(0x0506_i64)
    read_int(device, "mediaplayback", "cluster-revision", "ClusterRevision", 1).should eq(2_i64)
    read_int(device, "mediaplayback", "feature-map", "FeatureMap", 1).should eq(31_i64)
    read_int(device, "mediaplayback", "current-state", "CurrentState", 1).should eq(2_i64)
    read_int(device, "mediaplayback", "duration", "Duration", 1).should eq(120_000_i64)

    playback_status(device, "play").should eq(0_i64)
    read_int(device, "mediaplayback", "current-state", "CurrentState", 1).should eq(0_i64)
    playback_status(device, "seek", ["60000"]).should eq(0_i64)
    playback_status(device, "seek", ["130000"]).should eq(5_i64)
    playback_status(device, "pause").should eq(0_i64)
    read_int(device, "mediaplayback", "current-state", "CurrentState", 1).should eq(1_i64)
    playback_status(device, "stop").should eq(0_i64)
    read_int(device, "mediaplayback", "current-state", "CurrentState", 1).should eq(2_i64)
  end
end
