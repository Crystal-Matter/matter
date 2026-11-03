require "../spec_helper"
require "../../src/matter/media/jpeg_encoder"

private alias RgbFrame = Matter::Media::DecodedRgbFrame
private alias JpegEncoder = Matter::Media::JpegEncoder
private alias CameraSnp = Matter::Cluster::CameraAvStreamManagement

describe Matter::Media::JpegEncoder do
  it "rejects unbounded or malformed decoded frames" do
    expect_raises(ArgumentError) { RgbFrame.new(0_u16, 8_u16, Bytes.empty) }
    expect_raises(ArgumentError) { RgbFrame.new(8_u16, 8_u16, Bytes.new(8 * 8 * 3 - 1)) }
    expect_raises(ArgumentError) { RgbFrame.new(3840_u16, 2161_u16, Bytes.empty) }
    expect_raises(ArgumentError) { RgbFrame.new(UInt16::MAX, UInt16::MAX, Bytes.empty) }
  end

  it "encodes decoded RGB pixels as a JPEG that decodes to the same dimensions and regions" do
    pixels = Bytes.new(16 * 16 * RgbFrame::CHANNELS) do |index|
      x = index // RgbFrame::CHANNELS % 16
      channel = index % RgbFrame::CHANNELS
      if x < 8
        channel == 0 ? 240_u8 : 0_u8
      else
        channel == 2 ? 240_u8 : 0_u8
      end
    end
    frame = RgbFrame.new(16_u16, 16_u16, pixels)
    pixels[0] = 0_u8
    frame.pixels[0].should eq(240_u8)
    jpeg = JpegEncoder.new.encode(frame, 90_u8)
    jpeg.size.should be > 100

    decoded = CrImage::JPEG.read(IO::Memory.new(jpeg))
    decoded.bounds.width.should eq(16)
    decoded.bounds.height.should eq(16)
    left_red, _, left_blue, _ = decoded.at(3, 8).rgba
    right_red, _, right_blue, _ = decoded.at(12, 8).rgba
    left_red.should be > left_blue
    right_blue.should be > right_red

    # The adapter can supply real JPEG bytes to SNP without adding a Camera
    # device-type declaration or pretending to implement WebRTC.
    resolution = CameraSnp::VideoResolution.new(16_u16, 16_u16)
    camera = build(CameraSnp,
      supported_stream_usages: [CameraSnp::StreamUsage::LiveView],
      max_content_buffer_size: 65_000_u32, max_network_bandwidth: 1_000_000_u32,
      max_concurrent_encoders: 1_u8, max_encoded_pixel_rate: 2_560_u32,
      snapshot_capabilities: [CameraSnp::SnapshotCapability.new(
        resolution, 10_u16, CameraSnp::ImageCodec::Jpeg, true, true)],
      feature_map: CameraSnp::Feature::Snapshot)
    camera.on_snapshot_allocate { |_request, _id| Matter::InteractionModel::Status.success }
    camera.on_snapshot_capture do |stream, requested|
      requested.should eq(resolution)
      CameraSnp::SnapshotImage.new(JpegEncoder.new.encode(frame, stream.quality),
        CameraSnp::ImageCodec::Jpeg, requested)
    end
    allocation = invoke_response(camera, CameraSnp::CMD_SNAPSHOT_STREAM_ALLOCATE,
      CameraSnp::SnapshotStreamAllocateRequest.new(CameraSnp::ImageCodec::Jpeg,
        10_u16, resolution, resolution, 90_u8), CameraSnp::SnapshotStreamAllocateResponse)
    captured = invoke_response(camera, CameraSnp::CMD_CAPTURE_SNAPSHOT,
      CameraSnp::CaptureSnapshotRequest.new(allocation.snapshot_stream_id, resolution),
      CameraSnp::CaptureSnapshotResponse)
    captured.data.should eq(jpeg)
    captured.resolution.should eq(resolution)
  end

  it "rejects invalid quality" do
    frame = RgbFrame.new(1_u16, 1_u16, Bytes[255, 0, 0])
    expect_raises(ArgumentError) { JpegEncoder.new.encode(frame, 0_u8) }
    expect_raises(ArgumentError) { JpegEncoder.new.encode(frame, 101_u8) }
  end
end
