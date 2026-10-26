require "./e2e_helper"

private PTZ_CLUSTER  = "0x552"
private PTZ_ENDPOINT = "1"

private def ptz_read(device : E2E::Device, attribute : String) : E2E::Result
  expect_success(device.chip("any", "read-by-id", PTZ_CLUSTER, attribute, device.node, PTZ_ENDPOINT))
end

private def ptz_command(device : E2E::Device, command : String, payload : String) : E2E::Result
  device.chip("any", "command-by-id", PTZ_CLUSTER, command, payload, device.node, PTZ_ENDPOINT)
end

private def ptz_stream_id(device : E2E::Device) : Int32
  output = ptz_read(device, "0x3").output
  match = output.match(/VideoStreamID:\s*(\d+)/) || raise "No registered PTZ stream in #{output}"
  match[1].to_i
end

describe "Matter 1.6 Camera AV Settings mechanical and digital PTZ interoperability" do
  device = E2E::Device["matter_camera_ptz"]

  it "commissions and advertises the combined PTZ profile" do
    device.commission!
    ptz_read(device, "0xfffc").output.should contain("15")
    ptz_read(device, "0x4").output.should contain("20")
    ptz_read(device, "0x5").output.should contain("-45")
    ptz_read(device, "0x6").output.should contain("45")
    ptz_read(device, "0x3").output.should contain("1920")
  end

  it "sets mechanical axes, moves relatively, and persists measured position" do
    expect_success(ptz_command(device, "0x0", %({"0":"s:12","1":"s:-8","2":"u:4"})))
    ptz_read(device, "0x0").output.should contain("12")
    ptz_read(device, "0x0").output.should contain("-8")
    expect_success(ptz_command(device, "0x1", %({"1":"s:5","2":"s:3"})))
    ptz_read(device, "0x0").output.should contain("-3")
    ptz_read(device, "0x0").output.should contain("7")
    expect_failure(ptz_command(device, "0x0", %({"1":"s:46"})), "CONSTRAINT_ERROR")
    device.restart!
    ptz_read(device, "0x0").output.should contain("-3")
    ptz_read(device, "0x0").output.should contain("7")
  end

  it "moves a registered video crop through both digital PTZ commands" do
    stream_id = ptz_stream_id(device)
    expect_success(ptz_command(device, "0x5",
      %({"0":"u:#{stream_id}","1":{"0":"u:0","1":"u:0","2":"u:960","3":"u:540"}})))
    ptz_read(device, "0x3").output.should contain("960")
    expect_success(ptz_command(device, "0x6", %({"0":"u:#{stream_id}","1":"s:10","2":"s:10"})))
    ptz_read(device, "0x3").output.should contain("X2: 970")
    expect_failure(ptz_command(device, "0x5",
      %({"0":"u:#{stream_id}","1":{"0":"u:0","1":"u:0","2":"u:100","3":"u:100"}})),
      "CONSTRAINT_ERROR")
  end
end
