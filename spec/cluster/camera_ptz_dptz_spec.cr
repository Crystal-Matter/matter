require "../spec_helper"

private alias DptzCamera = Matter::Cluster::CameraAvSettingsUserLevelManagement
private alias DptzAv = Matter::Cluster::CameraAvStreamManagement
private alias DptzStatus = Matter::InteractionModel::Status
private alias DptzCode = Matter::InteractionModel::StatusCode

private def dptz_av_camera
  build(DptzAv,
    supported_stream_usages: [DptzAv::StreamUsage::LiveView],
    max_content_buffer_size: 65_536_u32, max_network_bandwidth: 2_000_000_u32,
    video_sensor_params: DptzAv::VideoSensorParams.new(1920_u16, 1080_u16, 30_u16),
    min_viewport_resolution: DptzAv::VideoResolution.new(160_u16, 90_u16),
    rate_distortion_trade_off_points: [DptzAv::RateDistortionPoint.new(DptzAv::VideoCodec::H264,
      DptzAv::VideoResolution.new(1280_u16, 720_u16), 200_000_u32)],
    max_concurrent_encoders: 1_u8, max_encoded_pixel_rate: 62_208_000_u32,
    feature_map: DptzAv::Feature::Video)
end

private def dptz_video_request
  DptzAv::VideoStreamAllocateRequest.new(DptzAv::StreamUsage::LiveView, DptzAv::VideoCodec::H264,
    15_u16, 30_u16, DptzAv::VideoResolution.new(320_u16, 180_u16),
    DptzAv::VideoResolution.new(1280_u16, 720_u16), 200_000_u32, 1_000_000_u32, 30_u16)
end

private def allocate_dptz_video(av : DptzAv) : UInt16
  av.on_video_allocate { |_request, _id| DptzStatus.success }
  invoke_response(av, DptzAv::CMD_VIDEO_STREAM_ALLOCATE, dptz_video_request,
    DptzAv::VideoStreamAllocateResponse).video_stream_id
end

describe "Camera AV Settings DPTZ" do
  it "advertises the complete DPTZ command profile when bound to same-endpoint VDO" do
    av = dptz_av_camera
    camera = build(DptzCamera, feature_map: DptzCamera::Feature::DigitalPtz, video_stream_management: av)
    camera.feature_map.value.should eq(1_u32)
    camera.attributes.map(&.id.id).should eq([DptzCamera::ATTR_DPTZ_STREAMS])
    camera.commands.map(&.id.id).should eq([DptzCamera::CMD_DPTZ_SET_VIEWPORT, 0x06_u32])
    camera.commands.first.access.should eq(Matter::InteractionModel::EntryPrivilege::Operate)
    read_tlv(camera, DptzCamera::ATTR_DPTZ_STREAMS).as_list.should be_empty
    expect_raises(ArgumentError) { build(DptzCamera, feature_map: DptzCamera::Feature::DigitalPtz) }
    expect_raises(ArgumentError) { build(DptzCamera, 2, feature_map: DptzCamera::Feature::DigitalPtz, video_stream_management: av) }
    expect_raises(ArgumentError) { camera.feature_map = DptzCamera::Feature::MechanicalPan }
  end

  it "combines DPTZ with mechanical axes and presets without leaking gated fields" do
    av = dptz_av_camera
    features = DptzCamera::Feature::DigitalPtz | DptzCamera::Feature::MechanicalPan |
               DptzCamera::Feature::MechanicalPresets
    camera = build(DptzCamera, feature_map: features, max_presets: 1_u8,
      video_stream_management: av)
    camera.attributes.map(&.id.id).should eq([
      DptzCamera::ATTR_MPTZ_POSITION, DptzCamera::ATTR_MAX_PRESETS,
      DptzCamera::ATTR_MPTZ_PRESETS, DptzCamera::ATTR_DPTZ_STREAMS,
      DptzCamera::ATTR_PAN_MIN, DptzCamera::ATTR_PAN_MAX,
      DptzCamera::ATTR_MOVEMENT_STATE,
    ])
    camera.commands.map(&.id.id).should eq([
      DptzCamera::CMD_MPTZ_SET_POSITION, DptzCamera::CMD_MPTZ_RELATIVE_MOVE,
      DptzCamera::CMD_MPTZ_MOVE_TO_PRESET, DptzCamera::CMD_MPTZ_SAVE_PRESET,
      DptzCamera::CMD_MPTZ_REMOVE_PRESET, DptzCamera::CMD_DPTZ_SET_VIEWPORT,
      0x06_u32,
    ])
    id = allocate_dptz_video(av)
    expect_success(camera.register_dptz_stream(id))
    camera.on_pan_move { |_target| DptzStatus.success }
    expect_success(invoke(camera, DptzCamera::CMD_MPTZ_SET_POSITION,
      DptzCamera::MPTZSetPositionRequest.new(15_i16)))
    camera.on_dptz_set_viewport { |_stream_id, _viewport| DptzStatus.success }
    expect_success(invoke(camera, DptzCamera::CMD_DPTZ_SET_VIEWPORT,
      DptzCamera::DPTZSetViewportRequest.new(id,
        DptzAv::Viewport.new(0_u16, 0_u16, 960_u16, 540_u16))))
    camera.mptz_position.pan.should eq(0_i16)
    camera.dptz_streams.first.viewport.should eq(DptzAv::Viewport.new(0_u16, 0_u16, 960_u16, 540_u16))
    tilt_zoom = build(DptzCamera,
      feature_map: DptzCamera::Feature::DigitalPtz | DptzCamera::Feature::MechanicalTilt |
                   DptzCamera::Feature::MechanicalZoom,
      video_stream_management: av)
    tilt_zoom.attributes.map(&.id.id).should contain(DptzCamera::ATTR_TILT_MIN)
    tilt_zoom.attributes.map(&.id.id).should contain(DptzCamera::ATTR_ZOOM_MAX)
    tilt_zoom.attributes.map(&.id.id).should_not contain(DptzCamera::ATTR_PAN_MIN)
    expect_raises(ArgumentError) do
      build(DptzCamera, feature_map: DptzCamera::Feature::DigitalPtz |
                                     DptzCamera::Feature::MechanicalPresets, max_presets: 1_u8, video_stream_management: av)
    end
  end

  it "tracks move-capable streams and applies an aspect-matched viewport after host success" do
    av = dptz_av_camera
    camera = build(DptzCamera, feature_map: DptzCamera::Feature::DigitalPtz, video_stream_management: av)
    id = allocate_dptz_video(av)
    expect_status(invoke(camera, DptzCamera::CMD_DPTZ_SET_VIEWPORT,
      DptzCamera::DPTZSetViewportRequest.new(id, DptzAv::Viewport.new(0_u16, 0_u16, 960_u16, 540_u16))), DptzCode::NotFound)
    expect_success(camera.register_dptz_stream(id))
    camera.dptz_streams.first.video_stream_id.should eq(id)
    camera.dptz_streams.first.viewport.should eq(av.viewport)
    camera.dptz_streams.first.to_tlv.as_structure.keys.should eq([0_u8, 1_u8])
    read_tlv(camera, DptzCamera::ATTR_DPTZ_STREAMS).as_list.first.as_structure.keys.should eq([0_u8, 1_u8])
    DptzCamera::DPTZSetViewportRequest.new(id, av.viewport).to_tlv.as_structure.keys.should eq([0_u8, 1_u8])
    expect_status(invoke(camera, DptzCamera::CMD_DPTZ_SET_VIEWPORT,
      DptzCamera::DPTZSetViewportRequest.new(id, DptzAv::Viewport.new(0_u16, 0_u16, 100_u16, 100_u16))), DptzCode::ConstraintError)
    expect_status(invoke(camera, DptzCamera::CMD_DPTZ_SET_VIEWPORT,
      DptzCamera::DPTZSetViewportRequest.new(id, DptzAv::Viewport.new(0_u16, 0_u16, 800_u16, 600_u16))), DptzCode::ConstraintError)
    target = DptzAv::Viewport.new(100_u16, 50_u16, 1060_u16, 590_u16)
    expect_status(invoke(camera, DptzCamera::CMD_DPTZ_SET_VIEWPORT,
      DptzCamera::DPTZSetViewportRequest.new(id, target)), DptzCode::InvalidInState)
    camera.on_dptz_set_viewport { |_id, _viewport| DptzStatus.failure }
    expect_status(invoke(camera, DptzCamera::CMD_DPTZ_SET_VIEWPORT,
      DptzCamera::DPTZSetViewportRequest.new(id, target)), DptzCode::Failure)
    camera.dptz_streams.first.viewport.should eq(av.viewport)
    applied = [] of Tuple(UInt16, DptzAv::Viewport)
    camera.on_dptz_set_viewport do |stream_id, viewport|
      applied << {stream_id, viewport}
      DptzStatus.success
    end
    expect_success(invoke(camera, DptzCamera::CMD_DPTZ_SET_VIEWPORT,
      DptzCamera::DPTZSetViewportRequest.new(id, target)))
    applied.should eq([{id, target}])
    camera.dptz_streams.first.viewport.should eq(target)
    av.viewport = DptzAv::Viewport.new(0_u16, 0_u16, 1280_u16, 720_u16)
    camera.dptz_streams.first.viewport.should eq(av.viewport)
  end

  it "persists active entries and removes them when the video stream is released or absent after restart" do
    av = dptz_av_camera
    camera = build(DptzCamera, feature_map: DptzCamera::Feature::DigitalPtz, video_stream_management: av)
    id = allocate_dptz_video(av)
    expect_success(camera.register_dptz_stream(id))
    saved = camera.save_state.as(Matter::Storage::Document)
    rebound = build(DptzCamera, feature_map: DptzCamera::Feature::DigitalPtz, video_stream_management: av)
    rebound.restore_state(saved)
    rebound.dptz_streams.map(&.video_stream_id).should eq([id])
    av.on_video_deallocate { |_id| DptzStatus.success }
    expect_success(invoke(av, DptzAv::CMD_VIDEO_STREAM_DEALLOCATE, DptzAv::VideoStreamDeallocateRequest.new(id)))
    camera.dptz_streams.should be_empty
    rebound.dptz_streams.should be_empty
    fresh_av = dptz_av_camera
    restored = build(DptzCamera, feature_map: DptzCamera::Feature::DigitalPtz, video_stream_management: fresh_av)
    restored.restore_state(saved)
    restored.dptz_streams.should be_empty

    another_id = allocate_dptz_video(av)
    expect_success(camera.register_dptz_stream(another_id))
    camera.dptz_streams.size.should eq(1)
    av.restore_state(av.save_state.as(Matter::Storage::Document))
    camera.dptz_streams.should be_empty
  end

  it "moves a per-stream viewport in model X/Y directions and scales its area by percentage" do
    av = dptz_av_camera
    camera = build(DptzCamera, feature_map: DptzCamera::Feature::DigitalPtz, video_stream_management: av)
    id = allocate_dptz_video(av)
    expect_success(camera.register_dptz_stream(id))
    applied = [] of DptzAv::Viewport
    camera.on_dptz_set_viewport do |_stream_id, viewport|
      applied << viewport
      DptzStatus.success
    end
    start = DptzAv::Viewport.new(480_u16, 270_u16, 1440_u16, 810_u16)
    expect_success(invoke(camera, DptzCamera::CMD_DPTZ_SET_VIEWPORT,
      DptzCamera::DPTZSetViewportRequest.new(id, start)))
    request = DptzCamera::DPTZRelativeMoveRequest.new(id, 100_i16, 100_i16)
    request.to_tlv.as_structure.keys.should eq([0_u8, 1_u8, 2_u8])
    expect_success(invoke(camera, DptzCamera::CMD_DPTZ_RELATIVE_MOVE, request))
    camera.dptz_streams.first.viewport.should eq(DptzAv::Viewport.new(580_u16, 170_u16, 1540_u16, 710_u16))
    expect_success(invoke(camera, DptzCamera::CMD_DPTZ_RELATIVE_MOVE,
      DptzCamera::DPTZRelativeMoveRequest.new(id, nil, nil, 50_i8)))
    camera.dptz_streams.first.viewport.should eq(DptzAv::Viewport.new(820_u16, 305_u16, 1300_u16, 575_u16))
    expect_success(invoke(camera, DptzCamera::CMD_DPTZ_RELATIVE_MOVE,
      DptzCamera::DPTZRelativeMoveRequest.new(id, nil, nil, -100_i8)))
    camera.dptz_streams.first.viewport.should eq(DptzAv::Viewport.new(580_u16, 170_u16, 1540_u16, 710_u16))
    applied.last.should eq(camera.dptz_streams.first.viewport)

    rebound = build(DptzCamera, feature_map: DptzCamera::Feature::DigitalPtz, video_stream_management: av)
    rebound.restore_state(camera.save_state.as(Matter::Storage::Document))
    rebound.dptz_streams.first.viewport.should eq(camera.dptz_streams.first.viewport)
  end

  it "validates relative fields, clips sensor and minimum bounds, and commits only after host admission" do
    av = dptz_av_camera
    camera = build(DptzCamera, feature_map: DptzCamera::Feature::DigitalPtz, video_stream_management: av)
    id = allocate_dptz_video(av)
    expect_success(camera.register_dptz_stream(id))
    command = DptzCamera::CMD_DPTZ_RELATIVE_MOVE
    missing_id = TLV::Any.new({1_u8 => TLV::Any.new(100_i16)} of TLV::TagId => TLV::Any)
    expect_status(invoke(camera, command, missing_id), DptzCode::InvalidCommand)
    mistyped_delta = TLV::Any.new({
      0_u8 => TLV::Any.new(id),
      2_u8 => TLV::Any.new("down"),
    } of TLV::TagId => TLV::Any)
    expect_status(invoke(camera, command, mistyped_delta), DptzCode::InvalidCommand)
    expect_status(invoke(camera, command,
      DptzCamera::DPTZRelativeMoveRequest.new(id + 1_u16, nil, nil, 50_i8)), DptzCode::NotFound)
    expect_status(invoke(camera, command,
      DptzCamera::DPTZRelativeMoveRequest.new(id)), DptzCode::ConstraintError)
    [101_i8, -101_i8, Int8::MIN].each do |bad_zoom|
      expect_status(invoke(camera, command,
        DptzCamera::DPTZRelativeMoveRequest.new(id, nil, nil, bad_zoom)), DptzCode::ConstraintError)
    end
    zoom_in = DptzCamera::DPTZRelativeMoveRequest.new(id, nil, nil, 100_i8)
    expect_status(invoke(camera, command, zoom_in), DptzCode::InvalidInState)
    camera.on_dptz_set_viewport { |_stream_id, _viewport| DptzStatus.failure }
    expect_status(invoke(camera, command, zoom_in), DptzCode::Failure)
    camera.dptz_streams.first.viewport.should eq(av.viewport)
    camera.on_dptz_set_viewport { |_stream_id, _viewport| DptzStatus.success }
    expect_success(invoke(camera, command, zoom_in))
    camera.dptz_streams.first.viewport.should eq(DptzAv::Viewport.new(880_u16, 495_u16, 1040_u16, 585_u16))
    expect_success(invoke(camera, command,
      DptzCamera::DPTZRelativeMoveRequest.new(id, Int16::MIN, Int16::MAX)))
    camera.dptz_streams.first.viewport.should eq(DptzAv::Viewport.new(0_u16, 0_u16, 160_u16, 90_u16))
    expect_success(invoke(camera, command,
      DptzCamera::DPTZRelativeMoveRequest.new(id, nil, nil, -100_i8)))
    camera.dptz_streams.first.viewport.should eq(DptzAv::Viewport.new(0_u16, 0_u16, 320_u16, 180_u16))
  end
end
