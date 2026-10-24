require "../spec_helper"

private alias CameraSnp = Matter::Cluster::CameraAvStreamManagement
private alias SnpStatus = Matter::InteractionModel::Status
private alias SnpCode = Matter::InteractionModel::StatusCode

private def snapshot_camera
  build(CameraSnp,
    supported_stream_usages: [CameraSnp::StreamUsage::LiveView],
    max_content_buffer_size: 1024_u32, max_network_bandwidth: 100_000_u32,
    max_concurrent_encoders: 1_u8, max_encoded_pixel_rate: 2_000_000_u32,
    snapshot_capabilities: [CameraSnp::SnapshotCapability.new(
      CameraSnp::VideoResolution.new(640_u16, 480_u16), 10_u16,
      CameraSnp::ImageCodec::Jpeg, true, true)],
    feature_map: CameraSnp::Feature::Snapshot | CameraSnp::Feature::Privacy)
end

private def snapshot_request(quality = 80_u8)
  CameraSnp::SnapshotStreamAllocateRequest.new(CameraSnp::ImageCodec::Jpeg, 5_u16,
    CameraSnp::VideoResolution.new(320_u16, 240_u16),
    CameraSnp::VideoResolution.new(640_u16, 480_u16), quality)
end

describe "Camera AV Stream Management SNP" do
  it "advertises only canonical snapshot attributes and commands when SNP is enabled" do
    camera = snapshot_camera
    camera.cluster_revision.should eq(2_u16)
    camera.attributes.map(&.id.id).should contain(CameraSnp::ATTR_SNAPSHOT_CAPABILITIES)
    camera.attributes.map(&.id.id).should contain(CameraSnp::ATTR_ALLOCATED_SNAPSHOT_STREAMS)
    camera.commands.map(&.id.id).should contain(CameraSnp::CMD_SNAPSHOT_STREAM_ALLOCATE)
    camera.commands.map(&.id.id).should contain(CameraSnp::CMD_SNAPSHOT_STREAM_DEALLOCATE)
    camera.commands.map(&.id.id).should contain(CameraSnp::CMD_CAPTURE_SNAPSHOT)
    camera.commands.map(&.id.id).should_not contain(CameraSnp::CMD_AUDIO_STREAM_ALLOCATE)
  end

  it "requires host admission, reuses exact streams and releases at reference count zero" do
    camera = snapshot_camera
    expect_status(invoke(camera, CameraSnp::CMD_SNAPSHOT_STREAM_ALLOCATE, snapshot_request), SnpCode::InvalidInState)
    allocated = [] of UInt16
    released = [] of UInt16
    camera.on_snapshot_allocate { |_request, id| allocated << id; SnpStatus.success }
    camera.on_snapshot_deallocate { |id| released << id; SnpStatus.success }
    first = invoke_response(camera, CameraSnp::CMD_SNAPSHOT_STREAM_ALLOCATE,
      snapshot_request, CameraSnp::SnapshotStreamAllocateResponse)
    second = invoke_response(camera, CameraSnp::CMD_SNAPSHOT_STREAM_ALLOCATE,
      snapshot_request, CameraSnp::SnapshotStreamAllocateResponse)
    second.snapshot_stream_id.should eq(first.snapshot_stream_id)
    allocated.should eq([first.snapshot_stream_id])
    camera.allocated_snapshot_streams.first.reference_count.should eq(2_u8)
    expect_success(invoke(camera, CameraSnp::CMD_SNAPSHOT_STREAM_DEALLOCATE,
      CameraSnp::SnapshotStreamDeallocateRequest.new(first.snapshot_stream_id)))
    released.should be_empty
    expect_success(invoke(camera, CameraSnp::CMD_SNAPSHOT_STREAM_DEALLOCATE,
      CameraSnp::SnapshotStreamDeallocateRequest.new(first.snapshot_stream_id)))
    released.should eq([first.snapshot_stream_id])
    camera.allocated_snapshot_streams.should be_empty
  end

  it "rejects unsupported capabilities and shared encoder exhaustion" do
    camera = snapshot_camera
    camera.on_snapshot_allocate { |_request, _id| SnpStatus.success }
    expect_status(invoke(camera, CameraSnp::CMD_SNAPSHOT_STREAM_ALLOCATE,
      snapshot_request(0_u8)), SnpCode::ConstraintError)
    expect_status(invoke(camera, CameraSnp::CMD_SNAPSHOT_STREAM_ALLOCATE,
      CameraSnp::SnapshotStreamAllocateRequest.new(CameraSnp::ImageCodec::Jpeg, 5_u16,
        CameraSnp::VideoResolution.new(320_u16, 240_u16),
        CameraSnp::VideoResolution.new(640_u16, 480_u16), 80_u8, true)), SnpCode::InvalidCommand)
    expect_status(invoke(camera, CameraSnp::CMD_SNAPSHOT_STREAM_ALLOCATE,
      CameraSnp::SnapshotStreamAllocateRequest.new(CameraSnp::ImageCodec::Heic, 5_u16,
        CameraSnp::VideoResolution.new(320_u16, 240_u16),
        CameraSnp::VideoResolution.new(640_u16, 480_u16), 80_u8)), SnpCode::ConstraintError)
    invoke_response(camera, CameraSnp::CMD_SNAPSHOT_STREAM_ALLOCATE,
      snapshot_request, CameraSnp::SnapshotStreamAllocateResponse)
    expect_status(invoke(camera, CameraSnp::CMD_SNAPSHOT_STREAM_ALLOCATE,
      snapshot_request(70_u8)), SnpCode::ResourceExhausted)
    expect_status(invoke(camera, CameraSnp::CMD_SET_STREAM_PRIORITIES,
      CameraSnp::SetStreamPrioritiesRequest.new([CameraSnp::StreamUsage::LiveView])), SnpCode::InvalidInState)
  end

  it "preserves allocation and next ID across restart but requires rebound host callbacks" do
    camera = snapshot_camera
    camera.on_snapshot_allocate { |_request, _id| SnpStatus.success }
    first = invoke_response(camera, CameraSnp::CMD_SNAPSHOT_STREAM_ALLOCATE,
      snapshot_request, CameraSnp::SnapshotStreamAllocateResponse)
    saved = camera.save_state.as(Matter::Storage::Document)
    restored = snapshot_camera
    restored.restore_state(saved)
    restored.allocated_snapshot_streams.first.snapshot_stream_id.should eq(first.snapshot_stream_id)
    capture = CameraSnp::CaptureSnapshotRequest.new(first.snapshot_stream_id,
      CameraSnp::VideoResolution.new(320_u16, 240_u16))
    expect_status(invoke(restored, CameraSnp::CMD_CAPTURE_SNAPSHOT, capture), SnpCode::InvalidInState)
    restored.on_snapshot_deallocate { |_id| SnpStatus.success }
    expect_success(invoke(restored, CameraSnp::CMD_SNAPSHOT_STREAM_DEALLOCATE,
      CameraSnp::SnapshotStreamDeallocateRequest.new(first.snapshot_stream_id)))
    restored.on_snapshot_allocate { |_request, _id| SnpStatus.success }
    second = invoke_response(restored, CameraSnp::CMD_SNAPSHOT_STREAM_ALLOCATE,
      snapshot_request, CameraSnp::SnapshotStreamAllocateResponse)
    second.snapshot_stream_id.should eq(first.snapshot_stream_id + 1_u16)
  end

  it "shares hardware encoder capacity with video allocations" do
    camera = build(CameraSnp,
      supported_stream_usages: [CameraSnp::StreamUsage::LiveView],
      max_content_buffer_size: 1024_u32, max_network_bandwidth: 2_000_000_u32,
      max_concurrent_encoders: 1_u8, max_encoded_pixel_rate: 10_000_000_u32,
      video_sensor_params: CameraSnp::VideoSensorParams.new(640_u16, 480_u16, 10_u16),
      min_viewport_resolution: CameraSnp::VideoResolution.new(160_u16, 120_u16),
      rate_distortion_trade_off_points: [CameraSnp::RateDistortionPoint.new(
        CameraSnp::VideoCodec::H264, CameraSnp::VideoResolution.new(640_u16, 480_u16), 100_000_u32)],
      snapshot_capabilities: [CameraSnp::SnapshotCapability.new(
        CameraSnp::VideoResolution.new(640_u16, 480_u16), 10_u16,
        CameraSnp::ImageCodec::Jpeg, true, true)],
      feature_map: CameraSnp::Feature::Video | CameraSnp::Feature::Snapshot)
    camera.on_video_allocate { |_request, _id| SnpStatus.success }
    camera.on_snapshot_allocate { |_request, _id| SnpStatus.success }
    video = CameraSnp::VideoStreamAllocateRequest.new(CameraSnp::StreamUsage::LiveView,
      CameraSnp::VideoCodec::H264, 1_u16, 5_u16,
      CameraSnp::VideoResolution.new(320_u16, 240_u16),
      CameraSnp::VideoResolution.new(640_u16, 480_u16), 100_000_u32, 500_000_u32, 30_u16)
    invoke_response(camera, CameraSnp::CMD_VIDEO_STREAM_ALLOCATE,
      video, CameraSnp::VideoStreamAllocateResponse)
    expect_status(invoke(camera, CameraSnp::CMD_SNAPSHOT_STREAM_ALLOCATE,
      snapshot_request), SnpCode::ResourceExhausted)
  end

  it "keeps the snapshot request and response fields on canonical TLV tags" do
    request = snapshot_request
    request.to_tlv.as_structure.keys.should eq([0_u8, 1_u8, 2_u8, 3_u8, 4_u8])
    CameraSnp::SnapshotStreamAllocateRequest.from_tlv(request.to_tlv).quality.should eq(80_u8)
    capture = CameraSnp::CaptureSnapshotRequest.new(1_u16,
      CameraSnp::VideoResolution.new(320_u16, 240_u16))
    capture.to_tlv.as_structure.keys.should eq([0_u8, 1_u8])
    response = CameraSnp::CaptureSnapshotResponse.new(Bytes[0xFF, 0xD8],
      CameraSnp::ImageCodec::Jpeg, capture.requested_resolution)
    response.to_tlv.as_structure.keys.should eq([0_u8, 1_u8, 2_u8])
    CameraSnp::CaptureSnapshotResponse.from_tlv(response.to_tlv).data.should eq(Bytes[0xFF, 0xD8])
  end

  it "returns host capture failures and rejects oversized images" do
    camera = snapshot_camera
    camera.on_snapshot_allocate { |_request, _id| SnpStatus.success }
    id = invoke_response(camera, CameraSnp::CMD_SNAPSHOT_STREAM_ALLOCATE,
      snapshot_request, CameraSnp::SnapshotStreamAllocateResponse).snapshot_stream_id
    resolution = CameraSnp::VideoResolution.new(320_u16, 240_u16)
    capture = CameraSnp::CaptureSnapshotRequest.new(id, resolution)
    camera.on_snapshot_capture { |_stream, _resolution| SnpStatus.resource_exhausted }
    expect_status(invoke(camera, CameraSnp::CMD_CAPTURE_SNAPSHOT, capture), SnpCode::ResourceExhausted)
    camera.on_snapshot_capture do |_stream, _resolution|
      CameraSnp::SnapshotImage.new(Bytes.new(1025), CameraSnp::ImageCodec::Jpeg, resolution)
    end
    expect_status(invoke(camera, CameraSnp::CMD_CAPTURE_SNAPSHOT, capture), SnpCode::ResourceExhausted)
  end

  it "bounds capture payload and blocks capture during privacy" do
    camera = snapshot_camera
    camera.on_snapshot_allocate { |_request, _id| SnpStatus.success }
    id = invoke_response(camera, CameraSnp::CMD_SNAPSHOT_STREAM_ALLOCATE,
      snapshot_request, CameraSnp::SnapshotStreamAllocateResponse).snapshot_stream_id
    capture = CameraSnp::CaptureSnapshotRequest.new(id, CameraSnp::VideoResolution.new(320_u16, 240_u16))
    expect_status(invoke(camera, CameraSnp::CMD_CAPTURE_SNAPSHOT, capture), SnpCode::InvalidInState)
    camera.on_snapshot_capture do |_stream, resolution|
      CameraSnp::SnapshotImage.new(Bytes[0xFF, 0xD8, 0xFF, 0xD9],
        CameraSnp::ImageCodec::Jpeg, resolution)
    end
    response = invoke_response(camera, CameraSnp::CMD_CAPTURE_SNAPSHOT, capture,
      CameraSnp::CaptureSnapshotResponse)
    response.data.should eq(Bytes[0xFF, 0xD8, 0xFF, 0xD9])
    expect_success(write(camera, CameraSnp::ATTR_SOFT_LIVESTREAM_PRIVACY_MODE_ENABLED, true))
    expect_status(invoke(camera, CameraSnp::CMD_CAPTURE_SNAPSHOT, capture), SnpCode::InvalidInState)
  end
end
