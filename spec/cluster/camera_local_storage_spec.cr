require "../spec_helper"

private alias StorageCamera = Matter::Cluster::CameraAvStreamManagement
private alias StorageStatus = Matter::InteractionModel::Status
private alias StorageCode = Matter::InteractionModel::StatusCode

private def storage_video_camera
  build(StorageCamera,
    supported_stream_usages: [StorageCamera::StreamUsage::Recording],
    max_content_buffer_size: 65_536_u32, max_network_bandwidth: 2_000_000_u32,
    video_sensor_params: StorageCamera::VideoSensorParams.new(1920_u16, 1080_u16, 30_u16),
    min_viewport_resolution: StorageCamera::VideoResolution.new(160_u16, 90_u16),
    rate_distortion_trade_off_points: [StorageCamera::RateDistortionPoint.new(
      StorageCamera::VideoCodec::H264, StorageCamera::VideoResolution.new(640_u16, 360_u16), 200_000_u32)],
    max_concurrent_encoders: 1_u8, max_encoded_pixel_rate: 62_208_000_u32,
    feature_map: StorageCamera::Feature::Video | StorageCamera::Feature::LocalStorage)
end

private def storage_snapshot_camera
  build(StorageCamera,
    supported_stream_usages: [StorageCamera::StreamUsage::Recording],
    max_content_buffer_size: 1024_u32, max_network_bandwidth: 100_000_u32,
    max_concurrent_encoders: 1_u8, max_encoded_pixel_rate: 2_000_000_u32,
    snapshot_capabilities: [StorageCamera::SnapshotCapability.new(
      StorageCamera::VideoResolution.new(640_u16, 480_u16), 10_u16,
      StorageCamera::ImageCodec::Jpeg, true, true)],
    feature_map: StorageCamera::Feature::Snapshot | StorageCamera::Feature::LocalStorage)
end

describe "Camera AV Local Storage feature" do
  it "exposes only the mandatory Manage attributes for each STOR profile" do
    video = storage_video_camera
    snapshot = storage_snapshot_camera
    video.attributes.map(&.id.id).should contain(StorageCamera::ATTR_LOCAL_VIDEO_RECORDING_ENABLED)
    video.attributes.map(&.id.id).should_not contain(StorageCamera::ATTR_LOCAL_SNAPSHOT_RECORDING_ENABLED)
    snapshot.attributes.map(&.id.id).should contain(StorageCamera::ATTR_LOCAL_SNAPSHOT_RECORDING_ENABLED)
    snapshot.attributes.map(&.id.id).should_not contain(StorageCamera::ATTR_LOCAL_VIDEO_RECORDING_ENABLED)
    read(video, StorageCamera::ATTR_LOCAL_VIDEO_RECORDING_ENABLED).should be_false
    read(snapshot, StorageCamera::ATTR_LOCAL_SNAPSHOT_RECORDING_ENABLED).should be_false
    video.get_attribute_metadata(StorageCamera::ATTR_LOCAL_VIDEO_RECORDING_ENABLED)
      .as(Matter::Cluster::AttributeMetadata).access.should eq(Matter::InteractionModel::EntryPrivilege::Manage)
    snapshot.get_attribute_metadata(StorageCamera::ATTR_LOCAL_SNAPSHOT_RECORDING_ENABLED)
      .as(Matter::Cluster::AttributeMetadata).access.should eq(Matter::InteractionModel::EntryPrivilege::Manage)
  end

  it "applies a host admission decision before persisting recording settings" do
    video = storage_video_camera
    expect_status(write(video, StorageCamera::ATTR_LOCAL_VIDEO_RECORDING_ENABLED, true), StorageCode::InvalidInState)
    applied = [] of Bool
    video.on_local_video_recording_changed do |enabled|
      applied << enabled
      StorageStatus.success
    end
    expect_success(write(video, StorageCamera::ATTR_LOCAL_VIDEO_RECORDING_ENABLED, true))
    applied.should eq([false, true])

    saved = video.save_state.as(Matter::Storage::Document)
    restored = storage_video_camera
    restored.restore_state(saved)
    read(restored, StorageCamera::ATTR_LOCAL_VIDEO_RECORDING_ENABLED).should be_true
    resumed = [] of Bool
    restored.on_local_video_recording_changed do |enabled|
      resumed << enabled
      StorageStatus.success
    end
    resumed.should eq([true])

    snapshot = storage_snapshot_camera
    expect_status(write(snapshot, StorageCamera::ATTR_LOCAL_SNAPSHOT_RECORDING_ENABLED, true), StorageCode::InvalidInState)
    snapshot.on_local_snapshot_recording_changed do |enabled|
      enabled ? StorageStatus.invalid_in_state : StorageStatus.success
    end
    expect_status(write(snapshot, StorageCamera::ATTR_LOCAL_SNAPSHOT_RECORDING_ENABLED, true), StorageCode::InvalidInState)
    read(snapshot, StorageCamera::ATTR_LOCAL_SNAPSHOT_RECORDING_ENABLED).should be_false
  end
end
