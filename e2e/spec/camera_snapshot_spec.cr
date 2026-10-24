require "./e2e_helper"

private CAMERA_SNAPSHOT_CLUSTER  = "0x551"
private CAMERA_SNAPSHOT_ENDPOINT = "1"

private def snapshot_command(device : E2E::Device, command : UInt32, payload : String) : E2E::Result
  device.chip("any", "command-by-id", CAMERA_SNAPSHOT_CLUSTER,
    "0x#{command.to_s(16)}", payload, device.node, CAMERA_SNAPSHOT_ENDPOINT)
end

private def snapshot_read(device : E2E::Device, attribute : UInt32) : E2E::Result
  expect_success(device.chip("any", "read-by-id", CAMERA_SNAPSHOT_CLUSTER,
    "0x#{attribute.to_s(16)}", device.node, CAMERA_SNAPSHOT_ENDPOINT))
end

describe "Matter 1.6 Camera AV Stream Management snapshot interoperability" do
  device = E2E::Device["matter_camera_snapshot"]

  it "commissions SNP, allocates and captures a bounded still image" do
    device.commission!
    expect_success(device.read("descriptor", "server-list", 1)).int_list("ServerList").should contain(0x0551_i64)
    snapshot_read(device, 0xFFFC_u32).output.should contain("12") # SNP + PRIV
    snapshot_read(device, 0x000A_u32).output.should contain("640")
    snapshot_read(device, 0x0011_u32)
    payload = %({"0":"u:0","1":"u:5","2":{"0":"u:320","1":"u:240"},"3":{"0":"u:640","1":"u:480"},"4":"u:80"})
    expect_failure(snapshot_command(device, 0x07_u32,
      %({"0":"u:0","1":"u:5","2":{"0":"u:320","1":"u:240"},"3":{"0":"u:640","1":"u:480"},"4":"u:0"})), "CONSTRAINT_ERROR")
    expect_success(snapshot_command(device, 0x07_u32, payload))
    snapshot_read(device, 0x0011_u32).output.should contain("80")
    expect_success(snapshot_command(device, 0x0C_u32,
      %({"0":"u:0","1":{"0":"u:320","1":"u:240"}})))
    expect_success(device.write("cameraavstreammanagement", "soft-livestream-privacy-mode-enabled", "true", 1))
    expect_failure(snapshot_command(device, 0x0C_u32,
      %({"0":"u:0","1":{"0":"u:320","1":"u:240"}})), "INVALID_IN_STATE")
    expect_success(snapshot_command(device, 0x0A_u32, %({"0":"u:0"})))
    expect_failure(snapshot_command(device, 0x0A_u32, %({"0":"u:0"})), "NOT_FOUND")
  end
end
