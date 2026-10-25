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

# The official chip-tool logger splits octet strings across `data:` and `....:`
# lines. Reassemble its CaptureSnapshotResponse before checking image content.
private def snapshot_response_data(result : E2E::Result) : Bytes
  chunks = [] of String
  reading = false
  result.output.each_line do |line|
    if match = line.match(/\bdata:\s*([0-9A-Fa-f]+)\s*$/)
      chunks << match[1]
      reading = true
    elsif reading && (match = line.match(/\.{4}:\s*([0-9A-Fa-f]+)\s*$/))
      chunks << match[1]
    elsif reading && line.includes?("imageCodec:")
      break
    end
  end
  raise "chip-tool omitted CaptureSnapshotResponse.data: #{result.tail}" if chunks.empty?
  chunks.join.hexbytes
end

private def snapshot_jpeg_dimensions(data : Bytes) : Tuple(Int32, Int32)
  raise "JPEG SOI missing" unless data.size >= 4 && data[0] == 0xFF && data[1] == 0xD8
  offset = 2
  while offset + 8 < data.size
    raise "JPEG marker missing" unless data[offset] == 0xFF
    marker = data[offset + 1]
    offset += 2
    next if marker == 0xFF
    break if marker == 0xDA
    length = (data[offset].to_i << 8) | data[offset + 1].to_i
    raise "Invalid JPEG segment" if length < 2 || offset + length > data.size
    if marker == 0xC0 || marker == 0xC2
      height = (data[offset + 3].to_i << 8) | data[offset + 4].to_i
      width = (data[offset + 5].to_i << 8) | data[offset + 6].to_i
      return {width, height}
    end
    offset += length
  end
  raise "JPEG frame dimensions missing"
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
    image = snapshot_response_data(expect_success(snapshot_command(device, 0x0C_u32,
      %({"0":"u:0","1":{"0":"u:320","1":"u:240"}}))))
    image.size.should be > 512
    snapshot_jpeg_dimensions(image).should eq({320, 240})
    image.should eq(File.read("examples/assets/snapshot_320x240.jpg").to_slice)
    snapshot_response_data(expect_success(snapshot_command(device, 0x0C_u32,
      %({"0":null,"1":{"0":"u:320","1":"u:240"}})))).should eq(image)
    expect_failure(snapshot_command(device, 0x0C_u32,
      %({"1":{"0":"u:320","1":"u:240"}})), "INVALID_COMMAND")
    expect_success(device.write("cameraavstreammanagement", "soft-livestream-privacy-mode-enabled", "true", 1))
    expect_failure(snapshot_command(device, 0x0C_u32,
      %({"0":"u:0","1":{"0":"u:320","1":"u:240"}})), "INVALID_IN_STATE")
    expect_success(snapshot_command(device, 0x0A_u32, %({"0":"u:0"})))
    expect_failure(snapshot_command(device, 0x0A_u32, %({"0":"u:0"})), "NOT_FOUND")
  end
end
