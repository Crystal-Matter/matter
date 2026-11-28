require "./e2e_helper"

private CAMERA_AUDIO_CLUSTER          = "0x551"
private CAMERA_AUDIO_ENDPOINT         = "1"
private AUDIO_DOORBELL_DEVICE_TYPE_ID = 0x0141_u32

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
    doorbell_type = expect_success(device.read("descriptor", "device-type-list", 1))
    doorbell_type.int("DeviceType").should eq(AUDIO_DOORBELL_DEVICE_TYPE_ID.to_i64)
    doorbell_type.int("Revision").should eq(2_i64)
    servers = expect_success(device.read("descriptor", "server-list", 1)).int_list("ServerList")
    servers.should contain(Matter::Cluster::Identify::CLUSTER_ID.to_i64)
    servers.should contain(Matter::Cluster::Switch::CLUSTER_ID.to_i64)
    servers.should contain(Matter::Cluster::WebRtcTransportProvider::CLUSTER_ID.to_i64)
    clients = expect_success(device.read("descriptor", "client-list", 1)).int_list("ClientList")
    clients.should contain(Matter::Cluster::WebRtcTransportRequestor::CLUSTER_ID.to_i64)
    clients.should contain(Matter::Cluster::Chime::CLUSTER_ID.to_i64)
    root_types = expect_success(device.read("descriptor", "device-type-list", 0)).ints("DeviceType")
    root_types.should contain(Matter::DeviceType::POWER_SOURCE.to_i64)
    root_servers = expect_success(device.read("descriptor", "server-list", 0)).int_list("ServerList")
    root_servers.should contain(Matter::Cluster::PowerSource::CLUSTER_ID.to_i64)
    root_servers.should contain(Matter::Cluster::TlsCertificateManagement::CLUSTER_ID.to_i64)
    expect_success(device.read("descriptor", "server-list", 1)).int_list("ServerList").should contain(0x0551_i64)
    read_camera_audio_int(device, 0xFFFD_u32).should eq(2_i64)
    read_camera_audio_int(device, 0xFFFC_u32).should eq(25_i64) # ADO + PRIV + SPKR
    read_camera_audio_int(device, 0x0006_u32).should eq(65_536_i64)
    read_camera_audio_int(device, 0x000B_u32).should eq(96_000_i64)
    read_camera_audio(device, 0x0007_u32).output.should contain("48000")
    read_camera_audio(device, 0x0008_u32).output.should contain("48000")
    read_camera_audio_int(device, 0x0009_u32).should eq(0_i64)
    read_camera_audio_int(device, 0x001B_u32).should eq(100_i64)
    read_camera_audio_int(device, 0x001C_u32).should eq(0_i64)
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

  it "rejects a supported audio usage omitted from stream priorities" do
    device.restart!
    expect_success(camera_audio_command(device, 0x0B_u32, %({"0":["u:1"]})))
    begin
      request = %({"0":"u:3","1":"u:0","2":"u:1","3":"u:48000","4":"u:64000","5":"u:16"})
      expect_failure(camera_audio_command(device, 0x00_u32, request), "INVALID_IN_STATE")
      read_camera_audio(device, 0x0010_u32).output.should contain("0 entries")
    ensure
      device.restart!
      expect_success(camera_audio_command(device, 0x0B_u32, %({"0":["u:1","u:3"]})))
    end
  end

  it "persists microphone and soft privacy settings" do
    expect_success(device.write("cameraavstreammanagement", "microphone-volume-level", 70, 1))
    expect_success(device.write("cameraavstreammanagement", "soft-livestream-privacy-mode-enabled", "true", 1))
    device.restart!
    read_camera_audio_int(device, 0x001E_u32).should eq(70_i64)
    expect_success(device.read("cameraavstreammanagement", "soft-livestream-privacy-mode-enabled", 1))
      .bool("SoftLivestreamPrivacyModeEnabled").should be_true
  end

  it "applies speaker mute and volume with bounds and restores both settings" do
    expect_success(device.write("cameraavstreammanagement", "speaker-muted", "true", 1))
    expect_success(device.write("cameraavstreammanagement", "speaker-volume-level", 70, 1))
    expect_failure(device.write("cameraavstreammanagement", "speaker-volume-level", 255, 1), "CONSTRAINT_ERROR")
    device.restart!
    expect_success(device.read("cameraavstreammanagement", "speaker-muted", 1))
      .bool("SpeakerMuted").should be_true
    read_camera_audio_int(device, 0x001A_u32).should eq(70_i64)
  end

  it "writes optional microphone AGC through chip-tool and restores it" do
    cluster = "cameraavstreammanagement"
    attribute = "microphone-agcenabled"
    expect_success(device.read(cluster, attribute, 1)).bool("MicrophoneAGCEnabled").should be_true
    expect_success(device.write(cluster, attribute, "false", 1))
    expect_success(device.read(cluster, attribute, 1)).bool("MicrophoneAGCEnabled").should be_false
    device.restart!
    expect_success(device.read(cluster, attribute, 1)).bool("MicrophoneAGCEnabled").should be_false
    expect_success(device.write(cluster, attribute, "true", 1))
  end
end
