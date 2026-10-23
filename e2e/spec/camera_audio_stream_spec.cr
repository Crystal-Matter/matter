require "./e2e_helper"

private CAMERA_AUDIO_CLUSTER  = "0x551"
private CAMERA_AUDIO_ENDPOINT = "1"

private def read_camera_audio(device : E2E::Device, attribute : UInt32) : E2E::Result
  expect_success(device.chip("any", "read-by-id", CAMERA_AUDIO_CLUSTER,
    "0x#{attribute.to_s(16)}", device.node, CAMERA_AUDIO_ENDPOINT))
end

private def read_camera_audio_int(device : E2E::Device, attribute : UInt32) : Int64
  result = read_camera_audio(device, attribute)
  value = result.output.scan(/\bData = (-?\d+)\b/).last?
  value.try(&.[1].to_i64) || fail("#{result.command}: no numeric data in chip-tool response\n#{result.tail}")
end

private def camera_audio_command(device : E2E::Device, command : UInt32, payload : String) : E2E::Result
  device.chip("any", "command-by-id", CAMERA_AUDIO_CLUSTER,
    "0x#{command.to_s(16)}", payload, device.node, CAMERA_AUDIO_ENDPOINT)
end

describe "Matter 1.6 Camera AV Stream Management audio interoperability" do
  device = E2E::Device["matter_camera_audio"]

  it "commissions a synthetic ADO endpoint and reads the mandatory capabilities" do
    device.commission!
    expect_success(device.read("descriptor", "server-list", 1)).int_list("ServerList").should contain(0x0551_i64)
    read_camera_audio_int(device, 0xFFFD_u32).should eq(2_i64)
    read_camera_audio_int(device, 0xFFFC_u32).should eq(9_i64) # ADO + PRIV
    read_camera_audio_int(device, 0x0006_u32).should eq(65_536_i64)
    read_camera_audio_int(device, 0x000B_u32).should eq(96_000_i64)
    read_camera_audio(device, 0x0007_u32).output.should contain("48000")
    read_camera_audio(device, 0x000E_u32).output.should contain("3")
    read_camera_audio(device, 0x0010_u32)
  end

  it "allocates, reuses and releases audio streams with chip-tool" do
    payload = %({"0":"u:3","1":"u:0","2":"u:1","3":"u:48000","4":"u:64000","5":"u:16"})
    expect_failure(camera_audio_command(device, 0x00_u32,
      %({"0":"u:3","1":"u:0","2":"u:3","3":"u:48000","4":"u:64000","5":"u:16"})), "CONSTRAINT_ERROR")
    expect_success(camera_audio_command(device, 0x00_u32, payload))
    streams = read_camera_audio(device, 0x0010_u32).output
    streams.should contain("64000")
    expect_success(camera_audio_command(device, 0x00_u32, payload))
    read_camera_audio(device, 0x0010_u32).output.should contain("2") # ReferenceCount
    expect_failure(camera_audio_command(device, 0x0B_u32, %({"0":["u:1","u:3"]})), "INVALID_IN_STATE")
    expect_success(camera_audio_command(device, 0x02_u32, %({"0":"u:0"})))
    expect_success(camera_audio_command(device, 0x02_u32, %({"0":"u:0"})))
    expect_failure(camera_audio_command(device, 0x02_u32, %({"0":"u:0"})), "NOT_FOUND")
    expect_success(camera_audio_command(device, 0x0B_u32, %({"0":["u:1","u:3"]})))
    device.restart!
    read_camera_audio(device, 0x0012_u32).output.should contain("1")
    expect_success(camera_audio_command(device, 0x00_u32, payload))
    read_camera_audio(device, 0x0010_u32).output.should contain("1")
  end

  it "persists microphone and soft privacy settings" do
    expect_success(device.write("cameraavstreammanagement", "microphone-volume-level", 70, 1))
    expect_success(device.write("cameraavstreammanagement", "soft-livestream-privacy-mode-enabled", "true", 1))
    device.restart!
    read_camera_audio_int(device, 0x001E_u32).should eq(70_i64)
    expect_success(device.read("cameraavstreammanagement", "soft-livestream-privacy-mode-enabled", 1))
      .bool("SoftLivestreamPrivacyModeEnabled").should be_true
  end
end
