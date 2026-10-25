require "../spec_helper"
require "../../src/matter/media/ffmpeg_jpeg_encoder"

private alias RgbFrame = Matter::Media::DecodedRgbFrame
private alias JpegEncoder = Matter::Media::FfmpegJpegEncoder
private alias CameraSnp = Matter::Cluster::CameraAvStreamManagement

private def ffmpeg_available? : Bool
  Process.run("ffmpeg", ["-version"], output: IO::Memory.new, error: IO::Memory.new).success?
rescue IO::Error
  false
end

describe Matter::Media::FfmpegJpegEncoder do
  it "rejects unbounded or malformed decoded frames before starting an encoder" do
    expect_raises(ArgumentError) { RgbFrame.new(0_u16, 8_u16, Bytes.empty) }
    expect_raises(ArgumentError) { RgbFrame.new(8_u16, 8_u16, Bytes.new(8 * 8 * 3 - 1)) }
    expect_raises(ArgumentError) { RgbFrame.new(3840_u16, 2161_u16, Bytes.empty) }
    expect_raises(ArgumentError) { RgbFrame.new(UInt16::MAX, UInt16::MAX, Bytes.empty) }
  end

  if ffmpeg_available?
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

      decoded = IO::Memory.new
      diagnostics = IO::Memory.new
      status = Process.run("ffmpeg", ["-hide_banner", "-loglevel", "error", "-nostdin",
                                      "-f", "mjpeg", "-i", "pipe:0", "-frames:v", "1", "-f", "rawvideo",
                                      "-pix_fmt", "rgb24", "pipe:1"],
        input: IO::Memory.new(jpeg), output: decoded, error: diagnostics)
      status.success?.should be_true
      raw = decoded.to_slice
      raw.size.should eq(16 * 16 * RgbFrame::CHANNELS)
      left = (8 * 16 + 3) * RgbFrame::CHANNELS
      right = (8 * 16 + 12) * RgbFrame::CHANNELS
      raw[left].should be > raw[left + 2]
      raw[right + 2].should be > raw[right]

      # The optional adapter can supply real JPEG bytes to SNP without adding
      # any Camera device-type declaration or pretending to implement WebRTC.
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
  else
    pending "encodes decoded RGB pixels as a JPEG that decodes to the same dimensions and regions"
  end

  it "rejects invalid quality and reports a missing encoder" do
    frame = RgbFrame.new(1_u16, 1_u16, Bytes[255, 0, 0])
    expect_raises(ArgumentError) { JpegEncoder.new.encode(frame, 0_u8) }
    expect_raises(Matter::ProtocolError, /unavailable/) do
      JpegEncoder.new("/nonexistent/ffmpeg").encode(frame, 80_u8)
    end
  end
end
