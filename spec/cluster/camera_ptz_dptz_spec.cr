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
  it "advertises only DPTZStreams and mandatory SetViewport when bound to same-endpoint VDO" do
    av = dptz_av_camera
    camera = build(DptzCamera, feature_map: DptzCamera::Feature::DigitalPtz, video_stream_management: av)
    camera.feature_map.value.should eq(1_u32)
    camera.attributes.map(&.id.id).should eq([DptzCamera::ATTR_DPTZ_STREAMS])
    camera.commands.map(&.id.id).should eq([DptzCamera::CMD_DPTZ_SET_VIEWPORT])
    camera.commands.first.access.should eq(Matter::InteractionModel::EntryPrivilege::Operate)
    read_tlv(camera, DptzCamera::ATTR_DPTZ_STREAMS).as_list.should be_empty
    expect_raises(ArgumentError) { build(DptzCamera, feature_map: DptzCamera::Feature::DigitalPtz) }
    expect_raises(ArgumentError) { build(DptzCamera, 2, feature_map: DptzCamera::Feature::DigitalPtz, video_stream_management: av) }
    expect_raises(ArgumentError) { camera.feature_map = DptzCamera::Feature::MechanicalPan }
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
end
