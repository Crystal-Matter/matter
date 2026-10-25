require "./e2e_helper"

private WEBRTC_CLUSTER  = "0x553"
private WEBRTC_ENDPOINT = "1"
private CAMERA_CLUSTER  = "0x551"

private def webrtc_command(device : E2E::Device, id : UInt32, payload : String) : E2E::Result
  device.chip("any", "command-by-id", WEBRTC_CLUSTER, "0x#{id.to_s(16)}",
    payload, device.node, WEBRTC_ENDPOINT)
end

private def webrtc_read(device : E2E::Device, id : UInt32) : E2E::Result
  device.chip("any", "read-by-id", WEBRTC_CLUSTER, "0x#{id.to_s(16)}",
    device.node, WEBRTC_ENDPOINT)
end

describe "Matter 1.6 WebRTC Provider signaling wire behavior" do
  device = E2E::Device["matter_webrtc_signaling"]

  it "commissions the opt-in signaling fixture and scopes a session lifecycle" do
    device.commission!
    expect_success(device.read("descriptor", "server-list", 1))
      .int_list("ServerList").should contain(0x0553_i64)
    expect_success(webrtc_read(device, 0xFFFD_u32)).output.should contain("2")
    expect_success(webrtc_read(device, 0x0000_u32))

    allocated = device.chip("any", "command-by-id", CAMERA_CLUSTER, "0x0",
      %({"0":"u:3","1":"u:0","2":"u:1","3":"u:48000","4":"u:64000","5":"u:16"}),
      device.node, WEBRTC_ENDPOINT)
    expect_success(allocated)

    offer = %({"0":null,"1":"v=0","2":"u:3","3":"u:22","11":["u:0"]})
    expect_success(webrtc_command(device, 0x02_u32, offer))
    expect_failure(webrtc_command(device, 0x02_u32,
      %({"1":"v=0","2":"u:3","3":"u:22","11":["u:0"]})), "INVALID_COMMAND")
    sessions = expect_success(webrtc_read(device, 0x0000_u32)).output
    sessions.should contain("PeerEndpointID: 22")
    sessions.should contain("AudioStreams: 1 entries")

    expect_success(webrtc_command(device, 0x04_u32, %({"0":"u:0","1":"v=0"})))
    candidates = %({"0":"u:0","1":[{"0":"candidate:1 1 UDP 1 127.0.0.1 1234 typ host","1":"0","2":"u:0"}]})
    expect_success(webrtc_command(device, 0x05_u32, candidates))
    nullable_candidates = %({"0":"u:0","1":[{"0":"candidate:2 1 UDP 1 127.0.0.1 1235 typ host","1":null,"2":null}]})
    expect_success(webrtc_command(device, 0x05_u32, nullable_candidates))
    absent_candidates = %({"0":"u:0","1":[{"0":"candidate:3 1 UDP 1 127.0.0.1 1236 typ host"}]})
    expect_failure(webrtc_command(device, 0x05_u32, absent_candidates), "INVALID_COMMAND")

    window = expect_success(device.chip(["pairing", "open-commissioning-window",
                                         device.node, "1", "180", "1000", "3840"]))
    code = window.output.match(/Manual pairing code:\s*\[?([0-9]{4}-[0-9]{3}-[0-9]{4}|[0-9]{11})\]?/i)
      .try(&.[1]) || fail("no second-fabric pairing code\n#{window.tail}")
    second = File.join(E2E::STORAGE_ROOT, "matter-webrtc-second-fabric")
    Dir.mkdir_p(second)
    expect_success(E2E.run(["pairing", "code", "2", code], second))
    second_sessions = expect_success(E2E.run(
      ["any", "read-by-id", WEBRTC_CLUSTER, "0x0", "2", WEBRTC_ENDPOINT], second))
    second_sessions.output.should contain("0 entries")
    expect_failure(E2E.run(["any", "command-by-id", WEBRTC_CLUSTER, "0x6",
                            %({"0":"u:0","1":"u:2"}), "2", WEBRTC_ENDPOINT], second), "NOT_FOUND")

    expect_success(webrtc_command(device, 0x06_u32, %({"0":"u:0","1":"u:2"})))
    expect_success(webrtc_read(device, 0x0000_u32)).output.should contain("0 entries")
  end

  it "signals an allocated H.264 video-only session and ends it after release" do
    device.restart!
    allocated = device.chip("any", "command-by-id", CAMERA_CLUSTER, "0x3",
      %({"0":"u:3","1":"u:0","2":"u:15","3":"u:30","4":{"0":"u:320","1":"u:180"},"5":{"0":"u:1280","1":"u:720"},"6":"u:200000","7":"u:1000000","8":"u:30"}),
      device.node, WEBRTC_ENDPOINT)
    expect_success(allocated)

    offer = %({"0":null,"1":"v=0","2":"u:3","3":"u:22","4":null})
    expect_success(webrtc_command(device, 0x02_u32, offer)).int("videoStreamID").should eq(0_i64)
    sessions = expect_success(webrtc_read(device, 0x0000_u32)).output
    sessions.should contain("VideoStreams: 1 entries")
    sessions.should contain("VideoStreamID: 0")
    expect_success(webrtc_command(device, 0x04_u32, %({"0":"u:0","1":"v=0"})))
    candidates = %({"0":"u:0","1":[{"0":"candidate:1 1 UDP 1 127.0.0.1 1234 typ host","1":"0","2":"u:0"}]})
    expect_success(webrtc_command(device, 0x05_u32, candidates))

    expect_success(device.chip("any", "command-by-id", CAMERA_CLUSTER, "0x6",
      %({"0":"u:0"}), device.node, WEBRTC_ENDPOINT))
    expect_success(webrtc_read(device, 0x0000_u32)).output.should contain("0 entries")
  end
end
