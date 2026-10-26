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
    ptz_read(device, "0xfffc").int("FeatureMap").should eq(15_i64)
    ptz_read(device, "0x4").int("ZoomMax").should eq(20_i64)
    ptz_read(device, "0x5").int("TiltMin").should eq(-45_i64)
    ptz_read(device, "0x6").int("TiltMax").should eq(45_i64)
    ptz_read(device, "0x3").int("X2").should eq(1920_i64)
  end

  it "sets mechanical axes, moves relatively, and persists measured position" do
    expect_success(ptz_command(device, "0x0", %({"0":"s:12","1":"s:-8","2":"u:4"})))
    ptz_read(device, "0x0").int("Pan").should eq(12_i64)
    ptz_read(device, "0x0").int("Tilt").should eq(-8_i64)
    expect_success(ptz_command(device, "0x1", %({"1":"s:5","2":"s:3"})))
    ptz_read(device, "0x0").int("Tilt").should eq(-3_i64)
    ptz_read(device, "0x0").int("Zoom").should eq(7_i64)
    expect_failure(ptz_command(device, "0x0", %({"1":"s:46"})), "CONSTRAINT_ERROR")
    device.restart!
    ptz_read(device, "0x0").int("Tilt").should eq(-3_i64)
    ptz_read(device, "0x0").int("Zoom").should eq(7_i64)
  end

  it "moves a registered video crop through both digital PTZ commands" do
    stream_id = ptz_stream_id(device)
    expect_success(ptz_command(device, "0x5",
      %({"0":"u:#{stream_id}","1":{"0":"u:0","1":"u:0","2":"u:960","3":"u:540"}})))
    ptz_read(device, "0x3").int("X2").should eq(960_i64)
    expect_success(ptz_command(device, "0x6", %({"0":"u:#{stream_id}","1":"s:10","2":"s:10"})))
    ptz_read(device, "0x3").int("X2").should eq(970_i64)
    expect_failure(ptz_command(device, "0x5",
      %({"0":"u:#{stream_id}","1":{"0":"u:0","1":"u:0","2":"u:100","3":"u:100"}})),
      "CONSTRAINT_ERROR")
  end
end
