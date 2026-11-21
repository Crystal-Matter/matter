require "../spec_helper"

private alias HdrCamera = Matter::Cluster::CameraAvStreamManagement
private alias HdrStatus = Matter::InteractionModel::Status
private alias HdrCode = Matter::InteractionModel::StatusCode

private def hdr_video_camera(sensor : HdrCamera::VideoSensorParams = HdrCamera::VideoSensorParams.new(1920_u16, 1080_u16, 30_u16, 15_u16),
                             features : HdrCamera::Feature = HdrCamera::Feature::Video | HdrCamera::Feature::HighDynamicRange)
  build(HdrCamera,
    supported_stream_usages: [HdrCamera::StreamUsage::LiveView],
    max_content_buffer_size: 65_536_u32, max_network_bandwidth: 2_000_000_u32,
    video_sensor_params: sensor,
    min_viewport_resolution: HdrCamera::VideoResolution.new(160_u16, 90_u16),
    rate_distortion_trade_off_points: [HdrCamera::RateDistortionPoint.new(
      HdrCamera::VideoCodec::H264, HdrCamera::VideoResolution.new(640_u16, 360_u16), 200_000_u32)],
    max_concurrent_encoders: 1_u8, max_encoded_pixel_rate: 62_208_000_u32,
    feature_map: features)
end

private def hdr_snapshot_camera
  build(HdrCamera,
    supported_stream_usages: [HdrCamera::StreamUsage::LiveView],
    max_content_buffer_size: 1024_u32, max_network_bandwidth: 100_000_u32,
    max_concurrent_encoders: 1_u8, max_encoded_pixel_rate: 2_000_000_u32,
    snapshot_capabilities: [HdrCamera::SnapshotCapability.new(
      HdrCamera::VideoResolution.new(640_u16, 480_u16), 10_u16,
      HdrCamera::ImageCodec::Jpeg, true, true)],
    feature_map: HdrCamera::Feature::Snapshot | HdrCamera::Feature::HighDynamicRange)
end

describe "Camera AV High Dynamic Range feature" do
  it "advertises HDRModeEnabled for VDO and SNP with conditional MaxHDRFPS" do
    video = hdr_video_camera
    snapshot = hdr_snapshot_camera
    video.attributes.map(&.id.id).should contain(HdrCamera::ATTR_HDR_MODE_ENABLED)
    snapshot.attributes.map(&.id.id).should contain(HdrCamera::ATTR_HDR_MODE_ENABLED)
    read_tlv(video, HdrCamera::ATTR_VIDEO_SENSOR_PARAMS).as_structure.keys.should eq([0_u8, 1_u8, 2_u8, 3_u8])
    read_tlv(video, HdrCamera::ATTR_VIDEO_SENSOR_PARAMS).as_structure[3_u8].value.should eq(15_u16)
    read(video, HdrCamera::ATTR_HDR_MODE_ENABLED).should be_false
    metadata = video.get_attribute_metadata(HdrCamera::ATTR_HDR_MODE_ENABLED)
      .as(Matter::Cluster::AttributeMetadata)
    metadata.access.should eq(Matter::InteractionModel::EntryPrivilege::Manage)
    metadata.write_access.should eq(Matter::InteractionModel::EntryPrivilege::Manage)

    plain = hdr_video_camera(HdrCamera::VideoSensorParams.new(1920_u16, 1080_u16, 30_u16), HdrCamera::Feature::Video)
    read_tlv(plain, HdrCamera::ATTR_VIDEO_SENSOR_PARAMS).as_structure.keys.should eq([0_u8, 1_u8, 2_u8])
    expect_status(read_status(plain, HdrCamera::ATTR_HDR_MODE_ENABLED), HdrCode::UnsupportedAttribute)
  end

  it "validates the conditional HDR sensor limit and feature combination" do
    expect_raises(ArgumentError) { HdrCamera::VideoSensorParams.new(640_u16, 480_u16, 30_u16, 0_u16) }
    expect_raises(ArgumentError) { HdrCamera::VideoSensorParams.new(640_u16, 480_u16, 30_u16, 31_u16) }
    expect_raises(ArgumentError) do
      hdr_video_camera(HdrCamera::VideoSensorParams.new(640_u16, 480_u16, 30_u16))
    end
    expect_raises(ArgumentError) do
      hdr_video_camera(HdrCamera::VideoSensorParams.new(640_u16, 480_u16, 30_u16, 15_u16), HdrCamera::Feature::Video)
    end
  end

  it "admits HDR changes through the host and restores the nonvolatile setting" do
    camera = hdr_video_camera
    expect_status(write(camera, HdrCamera::ATTR_HDR_MODE_ENABLED, true), HdrCode::InvalidInState)
    applied = [] of Bool
    camera.on_hdr_mode_changed do |enabled|
      applied << enabled
      HdrStatus.success
    end
    expect_success(write(camera, HdrCamera::ATTR_HDR_MODE_ENABLED, true))
    applied.should eq([false, true])

    restored = hdr_video_camera
    restored.restore_state(camera.save_state.as(Matter::Storage::Document))
    read(restored, HdrCamera::ATTR_HDR_MODE_ENABLED).should be_true
    resumed = [] of Bool
    restored.on_hdr_mode_changed do |enabled|
      resumed << enabled
      HdrStatus.success
    end
    resumed.should eq([true])

    snapshot = hdr_snapshot_camera
    snapshot.on_hdr_mode_changed do |enabled|
      enabled ? HdrStatus.invalid_in_state : HdrStatus.success
    end
    expect_status(write(snapshot, HdrCamera::ATTR_HDR_MODE_ENABLED, true), HdrCode::InvalidInState)
    read(snapshot, HdrCamera::ATTR_HDR_MODE_ENABLED).should be_false
  end
end
