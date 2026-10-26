require "../spec_helper"

private alias WatermarkCamera = Matter::Cluster::CameraAvStreamManagement
private alias WatermarkStatus = Matter::InteractionModel::Status
private alias WatermarkCode = Matter::InteractionModel::StatusCode

private def watermark_camera
  build(WatermarkCamera,
    supported_stream_usages: [WatermarkCamera::StreamUsage::LiveView],
    max_content_buffer_size: 1024_u32, max_network_bandwidth: 100_000_u32,
    max_concurrent_encoders: 1_u8, max_encoded_pixel_rate: 2_000_000_u32,
    snapshot_capabilities: [WatermarkCamera::SnapshotCapability.new(
      WatermarkCamera::VideoResolution.new(640_u16, 480_u16), 10_u16,
      WatermarkCamera::ImageCodec::Jpeg, true, true)],
    feature_map: WatermarkCamera::Feature::Snapshot | WatermarkCamera::Feature::Watermark)
end

private def watermark_request(enabled : Bool)
  WatermarkCamera::SnapshotStreamAllocateRequest.new(WatermarkCamera::ImageCodec::Jpeg, 5_u16,
    WatermarkCamera::VideoResolution.new(320_u16, 240_u16),
    WatermarkCamera::VideoResolution.new(640_u16, 480_u16), 80_u8, enabled)
end

describe "Camera AV Stream Management SNP+WMARK" do
  it "advertises the conditional modify command and requires the allocation flag" do
    camera = watermark_camera
    read(camera, Matter::Cluster::Base::GLOBAL_FEATURE_MAP).should eq(0x44_u32)
    camera.commands.map(&.id.id).should contain(WatermarkCamera::CMD_SNAPSHOT_STREAM_MODIFY)
    camera.commands.map(&.id.id).should_not contain(0x05_u32)
    camera.get_command_metadata(WatermarkCamera::CMD_SNAPSHOT_STREAM_MODIFY).as(Matter::Cluster::CommandMetadata)
      .access.should eq(Matter::InteractionModel::EntryPrivilege::Manage)
    expect_status(invoke(camera, WatermarkCamera::CMD_SNAPSHOT_STREAM_ALLOCATE,
      WatermarkCamera::SnapshotStreamAllocateRequest.new(WatermarkCamera::ImageCodec::Jpeg, 5_u16,
        WatermarkCamera::VideoResolution.new(320_u16, 240_u16),
        WatermarkCamera::VideoResolution.new(640_u16, 480_u16), 80_u8)), WatermarkCode::InvalidCommand)
    watermark_request(false).to_tlv.as_structure.keys.should eq([0_u8, 1_u8, 2_u8, 3_u8, 4_u8, 5_u8])
    WatermarkCamera::SnapshotStreamModifyRequest.new(1_u16, true).to_tlv.as_structure.keys
      .should eq([0_u8, 1_u8])
  end

  it "passes watermark admission to the host and commits modify only on host success" do
    camera = watermark_camera
    admitted = [] of Bool
    modified = [] of Tuple(UInt16, Bool)
    camera.on_snapshot_allocate do |request, _id|
      admitted << request.watermark_enabled.as(Bool)
      WatermarkStatus.success
    end
    id = invoke_response(camera, WatermarkCamera::CMD_SNAPSHOT_STREAM_ALLOCATE,
      watermark_request(false), WatermarkCamera::SnapshotStreamAllocateResponse).snapshot_stream_id
    admitted.should eq([false])
    stream = camera.allocated_snapshot_streams.first
    stream.watermark_enabled.should be_false
    stream.to_tlv.as_structure[9_u8].as_bool.should be_false

    change = WatermarkCamera::SnapshotStreamModifyRequest.new(id, true)
    expect_status(invoke(camera, WatermarkCamera::CMD_SNAPSHOT_STREAM_MODIFY,
      WatermarkCamera::SnapshotStreamModifyRequest.new(id)), WatermarkCode::InvalidCommand)
    expect_status(invoke(camera, WatermarkCamera::CMD_SNAPSHOT_STREAM_MODIFY,
      WatermarkCamera::SnapshotStreamModifyRequest.new(id, true, false)), WatermarkCode::InvalidCommand)
    expect_status(invoke(camera, WatermarkCamera::CMD_SNAPSHOT_STREAM_MODIFY, change), WatermarkCode::InvalidInState)
    camera.allocated_snapshot_streams.first.watermark_enabled.should be_false
    camera.on_snapshot_modify do |stream_id, enabled|
      modified << {stream_id, enabled}
      WatermarkStatus.failure
    end
    expect_status(invoke(camera, WatermarkCamera::CMD_SNAPSHOT_STREAM_MODIFY, change), WatermarkCode::Failure)
    camera.allocated_snapshot_streams.first.watermark_enabled.should be_false
    camera.on_snapshot_modify do |stream_id, enabled|
      modified << {stream_id, enabled}
      WatermarkStatus.success
    end
    expect_success(invoke(camera, WatermarkCamera::CMD_SNAPSHOT_STREAM_MODIFY, change))
    camera.allocated_snapshot_streams.first.watermark_enabled.should be_true
    modified.should eq([{id, true}, {id, true}])

    restored = watermark_camera
    restored.restore_state(camera.save_state.as(Matter::Storage::Document))
    restored.allocated_snapshot_streams.first.watermark_enabled.should be_true
  end

  it "rejects partial feature profiles and unknown streams" do
    camera = watermark_camera
    expect_status(invoke(camera, WatermarkCamera::CMD_SNAPSHOT_STREAM_MODIFY,
      WatermarkCamera::SnapshotStreamModifyRequest.new(17_u16, true)), WatermarkCode::NotFound)
    expect_raises(ArgumentError) do
      build(WatermarkCamera,
        supported_stream_usages: [WatermarkCamera::StreamUsage::LiveView],
        max_content_buffer_size: 1024_u32, max_network_bandwidth: 100_000_u32,
        max_concurrent_encoders: 1_u8, max_encoded_pixel_rate: 2_000_000_u32,
        snapshot_capabilities: [WatermarkCamera::SnapshotCapability.new(
          WatermarkCamera::VideoResolution.new(640_u16, 480_u16), 10_u16,
          WatermarkCamera::ImageCodec::Jpeg, true, true)],
        feature_map: WatermarkCamera::Feature::Video | WatermarkCamera::Feature::Snapshot |
                     WatermarkCamera::Feature::Watermark)
    end
    plain = build(WatermarkCamera,
      supported_stream_usages: [WatermarkCamera::StreamUsage::LiveView],
      max_content_buffer_size: 1024_u32, max_network_bandwidth: 100_000_u32,
      max_concurrent_encoders: 1_u8, max_encoded_pixel_rate: 2_000_000_u32,
      snapshot_capabilities: [WatermarkCamera::SnapshotCapability.new(
        WatermarkCamera::VideoResolution.new(640_u16, 480_u16), 10_u16,
        WatermarkCamera::ImageCodec::Jpeg, true, true)],
      feature_map: WatermarkCamera::Feature::Snapshot)
    plain.commands.map(&.id.id).should_not contain(WatermarkCamera::CMD_SNAPSHOT_STREAM_MODIFY)
    expect_raises(ArgumentError) do
      plain.feature_map = WatermarkCamera::Feature::Snapshot | WatermarkCamera::Feature::Watermark
    end
  end
end
