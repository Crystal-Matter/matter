require "./e2e_helper"

private CAMERA_VIDEO_CLUSTER  = "0x551"
private CAMERA_VIDEO_ENDPOINT = "1"

private def read_camera_video(device : E2E::Device, attribute : UInt32) : E2E::Result
  expect_success(device.chip("any", "read-by-id", CAMERA_VIDEO_CLUSTER,
    "0x#{attribute.to_s(16)}", device.node, CAMERA_VIDEO_ENDPOINT))
end

private def camera_video_command(device : E2E::Device, command : UInt32, payload : String) : E2E::Result
  device.chip("any", "command-by-id", CAMERA_VIDEO_CLUSTER,
    "0x#{command.to_s(16)}", payload, device.node, CAMERA_VIDEO_ENDPOINT)
end

describe "Matter 1.6 Camera AV Stream Management video interoperability" do
  device = E2E::Device["matter_camera_video"]

  it "commissions VDO and reads its required capabilities" do
    device.commission!
    expect_success(device.read("descriptor", "server-list", 1)).int_list("ServerList").should contain(0x0551_i64)
    read_camera_video(device, 0xFFFC_u32).output.should contain("10") # VDO + PRIV
    read_camera_video(device, 0x0000_u32).output.should contain("1")
    read_camera_video(device, 0x0002_u32).output.should contain("1920")
    read_camera_video(device, 0x0004_u32).output.should contain("160")
    read_camera_video(device, 0x0005_u32).output.should contain("200000")
    read_camera_video(device, 0x0018_u32).output.should contain("1920")
    expect_failure(device.write("cameraavstreammanagement", "viewport",
      %({"x1":0,"y1":0,"x2":100,"y2":100}), 1), "CONSTRAINT_ERROR")
    expect_success(device.write("cameraavstreammanagement", "viewport",
      %({"x1":20,"y1":10,"x2":660,"y2":370}), 1))
    read_camera_video(device, 0x0018_u32).output.should contain("660")
    read_camera_video(device, 0x000F_u32)
  end

  it "validates, allocates, reuses and releases video streams" do
    payload = %({"0":"u:3","1":"u:0","2":"u:15","3":"u:30","4":{"0":"u:320","1":"u:180"},"5":{"0":"u:1280","1":"u:720"},"6":"u:200000","7":"u:1000000","8":"u:30"})
    expect_failure(camera_video_command(device, 0x03_u32,
      %({"0":"u:3","1":"u:0","2":"u:31","3":"u:30","4":{"0":"u:320","1":"u:180"},"5":{"0":"u:1280","1":"u:720"},"6":"u:200000","7":"u:1000000","8":"u:30"})), "CONSTRAINT_ERROR")
    expect_success(camera_video_command(device, 0x03_u32, payload))
    read_camera_video(device, 0x000F_u32).output.should contain("1000000")
    expect_success(camera_video_command(device, 0x03_u32, payload))
    read_camera_video(device, 0x000F_u32).output.should contain("2")
    expect_failure(camera_video_command(device, 0x0B_u32, %({"0":["u:1","u:3"]})), "INVALID_IN_STATE")
    expect_success(camera_video_command(device, 0x06_u32, %({"0":"u:0"})))
    expect_success(camera_video_command(device, 0x06_u32, %({"0":"u:0"})))
    expect_failure(camera_video_command(device, 0x06_u32, %({"0":"u:0"})), "NOT_FOUND")
    device.restart!
    read_camera_video(device, 0x000F_u32).output.should_not contain("1000000")
    read_camera_video(device, 0x0018_u32).output.should contain("660")
  end
end
