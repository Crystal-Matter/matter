require "../spec_helper"

private alias OverlayCamera = Matter::Cluster::CameraAvStreamManagement
private alias OverlayStatus = Matter::InteractionModel::Status
private alias OverlayCode = Matter::InteractionModel::StatusCode

private def overlay_video_camera(features : OverlayCamera::Feature)
  build(OverlayCamera,
    supported_stream_usages: [OverlayCamera::StreamUsage::LiveView],
    max_content_buffer_size: 65_536_u32, max_network_bandwidth: 2_000_000_u32,
    video_sensor_params: OverlayCamera::VideoSensorParams.new(1920_u16, 1080_u16, 30_u16),
    min_viewport_resolution: OverlayCamera::VideoResolution.new(160_u16, 90_u16),
    rate_distortion_trade_off_points: [OverlayCamera::RateDistortionPoint.new(OverlayCamera::VideoCodec::H264,
      OverlayCamera::VideoResolution.new(640_u16, 360_u16), 200_000_u32)],
    max_concurrent_encoders: 1_u8, max_encoded_pixel_rate: 62_208_000_u32,
    feature_map: features)
end

private def overlay_video_request(watermark : Bool? = nil, osd : Bool? = nil)
  OverlayCamera::VideoStreamAllocateRequest.new(OverlayCamera::StreamUsage::LiveView, OverlayCamera::VideoCodec::H264,
    15_u16, 30_u16, OverlayCamera::VideoResolution.new(320_u16, 180_u16),
    OverlayCamera::VideoResolution.new(1280_u16, 720_u16), 200_000_u32, 1_000_000_u32, 30_u16,
    watermark, osd)
end

describe "Camera AV Stream Management VDO overlays" do
  it "advertises WMARK-only 0x05 and enforces conditional allocation fields" do
    camera = overlay_video_camera(OverlayCamera::Feature::Video | OverlayCamera::Feature::Watermark)
    read(camera, Matter::Cluster::Base::GLOBAL_FEATURE_MAP).should eq(0x42_u32)
    camera.commands.map(&.id.id).should contain(OverlayCamera::CMD_VIDEO_STREAM_MODIFY)
    camera.get_command_metadata(OverlayCamera::CMD_VIDEO_STREAM_MODIFY).as(Matter::Cluster::CommandMetadata)
      .access.should eq(Matter::InteractionModel::EntryPrivilege::Manage)
    expect_status(invoke(camera, OverlayCamera::CMD_VIDEO_STREAM_ALLOCATE,
      overlay_video_request), OverlayCode::InvalidCommand)
    expect_status(invoke(camera, OverlayCamera::CMD_VIDEO_STREAM_ALLOCATE,
      overlay_video_request(false, false)), OverlayCode::InvalidCommand)
    camera.on_video_allocate { |_request, _id| OverlayStatus.success }
    id = invoke_response(camera, OverlayCamera::CMD_VIDEO_STREAM_ALLOCATE,
      overlay_video_request(false), OverlayCamera::VideoStreamAllocateResponse).video_stream_id
    stream = camera.allocated_video_streams.first
    stream.watermark_enabled.should be_false
    stream.osd_enabled.should be_nil
    stream.to_tlv.as_structure.keys.should contain(10_u8)
    stream.to_tlv.as_structure.keys.should_not contain(11_u8)
    expect_status(invoke(camera, OverlayCamera::CMD_VIDEO_STREAM_MODIFY,
      OverlayCamera::VideoStreamModifyRequest.new(id)), OverlayCode::InvalidCommand)
    expect_status(invoke(camera, OverlayCamera::CMD_VIDEO_STREAM_MODIFY,
      OverlayCamera::VideoStreamModifyRequest.new(id, nil, true)), OverlayCode::InvalidCommand)
  end

  it "supports OSD-only and combined changes after host admission without reallocating resources" do
    osd_only = overlay_video_camera(OverlayCamera::Feature::Video | OverlayCamera::Feature::Osd)
    osd_only.commands.map(&.id.id).should contain(OverlayCamera::CMD_VIDEO_STREAM_MODIFY)
    expect_status(invoke(osd_only, OverlayCamera::CMD_VIDEO_STREAM_ALLOCATE,
      overlay_video_request), OverlayCode::InvalidCommand)
    expect_status(invoke(osd_only, OverlayCamera::CMD_VIDEO_STREAM_ALLOCATE,
      overlay_video_request(false, false)), OverlayCode::InvalidCommand)
    osd_only.on_video_allocate { |_request, _id| OverlayStatus.success }
    osd_id = invoke_response(osd_only, OverlayCamera::CMD_VIDEO_STREAM_ALLOCATE,
      overlay_video_request(nil, false), OverlayCamera::VideoStreamAllocateResponse).video_stream_id
    osd_only.allocated_video_streams.first.to_tlv.as_structure.keys.should contain(11_u8)
    osd_only.allocated_video_streams.first.to_tlv.as_structure.keys.should_not contain(10_u8)
    osd_only.on_video_modify { |_id, _watermark, _osd| OverlayStatus.success }
    expect_success(invoke(osd_only, OverlayCamera::CMD_VIDEO_STREAM_MODIFY,
      OverlayCamera::VideoStreamModifyRequest.new(osd_id, nil, true)))
    osd_only.allocated_video_streams.first.osd_enabled.should be_true
    both = overlay_video_camera(OverlayCamera::Feature::Video | OverlayCamera::Feature::Watermark | OverlayCamera::Feature::Osd)
    both.on_video_allocate { |_request, _id| OverlayStatus.success }
    id = invoke_response(both, OverlayCamera::CMD_VIDEO_STREAM_ALLOCATE,
      overlay_video_request(false, false), OverlayCamera::VideoStreamAllocateResponse).video_stream_id
    change = OverlayCamera::VideoStreamModifyRequest.new(id, true, true)
    expect_status(invoke(both, OverlayCamera::CMD_VIDEO_STREAM_MODIFY, change), OverlayCode::InvalidInState)
    both.on_video_modify { |_id, _watermark, _osd| OverlayStatus.failure }
    expect_status(invoke(both, OverlayCamera::CMD_VIDEO_STREAM_MODIFY, change), OverlayCode::Failure)
    both.allocated_video_streams.first.watermark_enabled.should be_false
    both.allocated_video_streams.first.osd_enabled.should be_false
    seen = [] of Tuple(UInt16, Bool?, Bool?)
    both.on_video_modify do |stream_id, watermark, osd|
      seen << {stream_id, watermark, osd}
      OverlayStatus.success
    end
    expect_success(invoke(both, OverlayCamera::CMD_VIDEO_STREAM_MODIFY, change))
    seen.should eq([{id, true, true}])
    stream = both.allocated_video_streams.first
    stream.watermark_enabled.should be_true
    stream.osd_enabled.should be_true
    stream.reference_count.should eq(1_u8)
    expect_success(invoke(both, OverlayCamera::CMD_VIDEO_STREAM_MODIFY,
      OverlayCamera::VideoStreamModifyRequest.new(id, nil, false)))
    both.allocated_video_streams.first.watermark_enabled.should be_true
    both.allocated_video_streams.first.osd_enabled.should be_false
    expect_status(invoke(both, OverlayCamera::CMD_VIDEO_STREAM_ALLOCATE,
      overlay_video_request(false, false)), OverlayCode::ResourceExhausted)
    invoke_response(both, OverlayCamera::CMD_VIDEO_STREAM_ALLOCATE,
      overlay_video_request(true, false), OverlayCamera::VideoStreamAllocateResponse).video_stream_id.should eq(id)
    both.allocated_video_streams.first.reference_count.should eq(2_u8)
    expect_status(invoke(both, OverlayCamera::CMD_VIDEO_STREAM_MODIFY,
      OverlayCamera::VideoStreamModifyRequest.new(12_u16, true)), OverlayCode::NotFound)
    restored = overlay_video_camera(OverlayCamera::Feature::Video | OverlayCamera::Feature::Watermark | OverlayCamera::Feature::Osd)
    restored.restore_state(both.save_state.as(Matter::Storage::Document))
    restored.allocated_video_streams.should be_empty
    restored.on_video_allocate { |_request, _id| OverlayStatus.success }
    next_id = invoke_response(restored, OverlayCamera::CMD_VIDEO_STREAM_ALLOCATE,
      overlay_video_request(false, false), OverlayCamera::VideoStreamAllocateResponse).video_stream_id
    next_id.should eq(id + 1_u16)
  end
end
