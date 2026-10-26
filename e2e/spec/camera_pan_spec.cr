require "./e2e_helper"

private CAMERA_CLUSTER  = "0x552"
private CAMERA_ENDPOINT = "1"

private def camera_read(device : E2E::Device, attribute : String) : E2E::Result
  expect_success(device.chip("any", "read-by-id", CAMERA_CLUSTER, attribute, device.node, CAMERA_ENDPOINT))
end

private def camera_command(device : E2E::Device, command : String, pan : Int32) : E2E::Result
  device.chip("any", "command-by-id", CAMERA_CLUSTER, command,
    %({"0": "s:#{pan}"}), device.node, CAMERA_ENDPOINT)
end

describe "Matter 1.6 Camera AV Settings MPAN interoperability" do
  device = E2E::Device["matter_camera_pan"]

  it "commissions and advertises only the mechanical pan surface" do
    device.commission!
    camera_read(device, "0xfffd").output.should contain("1")
    camera_read(device, "0xfffc").output.should contain("2")
    camera_read(device, "0x7").output.should contain("-90")
    camera_read(device, "0x8").output.should contain("90")
    camera_read(device, "0x9").output.should contain("0")
    expect_failure(device.chip("any", "read-by-id", CAMERA_CLUSTER, "0x4", device.node, CAMERA_ENDPOINT),
      "UNSUPPORTED_ATTRIBUTE")
    expect_failure(device.chip("any", "command-by-id", CAMERA_CLUSTER, "0x2", "{}", device.node, CAMERA_ENDPOINT),
      "UNSUPPORTED_COMMAND")
  end

  it "sets and moves pan, clamps targets, rejects invalid deltas, and persists its position" do
    expect_success(camera_command(device, "0x0", 30)).output.should contain("SUCCESS")
    camera_read(device, "0x0").output.should contain("30")
    expect_success(camera_command(device, "0x1", -12)).output.should contain("SUCCESS")
    camera_read(device, "0x0").output.should contain("18")
    expect_failure(camera_command(device, "0x0", 91), "CONSTRAINT_ERROR")
    expect_failure(camera_command(device, "0x1", -181), "CONSTRAINT_ERROR")
    expect_success(camera_command(device, "0x1", -110)).output.should contain("SUCCESS")
    camera_read(device, "0x0").output.should contain("-90")
    device.restart!
    camera_read(device, "0x0").output.should contain("-90")
    camera_read(device, "0x9").output.should contain("0")
  end
end
