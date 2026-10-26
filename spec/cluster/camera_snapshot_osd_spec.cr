require "../spec_helper"

private alias OsdCamera = Matter::Cluster::CameraAvStreamManagement
private alias OsdStatus = Matter::InteractionModel::Status
private alias OsdCode = Matter::InteractionModel::StatusCode

private def osd_camera(features : OsdCamera::Feature)
  build(OsdCamera,
    supported_stream_usages: [OsdCamera::StreamUsage::LiveView],
    max_content_buffer_size: 1024_u32, max_network_bandwidth: 100_000_u32,
    max_concurrent_encoders: 1_u8, max_encoded_pixel_rate: 2_000_000_u32,
    snapshot_capabilities: [OsdCamera::SnapshotCapability.new(
      OsdCamera::VideoResolution.new(640_u16, 480_u16), 10_u16,
      OsdCamera::ImageCodec::Jpeg, true, true)],
    feature_map: features)
end

private def osd_request(watermark : Bool? = nil, osd : Bool? = nil)
  OsdCamera::SnapshotStreamAllocateRequest.new(OsdCamera::ImageCodec::Jpeg, 5_u16,
    OsdCamera::VideoResolution.new(320_u16, 240_u16),
    OsdCamera::VideoResolution.new(640_u16, 480_u16), 80_u8, watermark, osd)
end

describe "Camera AV Stream Management SNP+OSD" do
  it "advertises the OSD-only conditional stream and modify command" do
    camera = osd_camera(OsdCamera::Feature::Snapshot | OsdCamera::Feature::Osd)
    read(camera, Matter::Cluster::Base::GLOBAL_FEATURE_MAP).should eq(0x84_u32)
    camera.commands.map(&.id.id).should contain(OsdCamera::CMD_SNAPSHOT_STREAM_MODIFY)
    expect_status(invoke(camera, OsdCamera::CMD_SNAPSHOT_STREAM_ALLOCATE,
      osd_request), OsdCode::InvalidCommand)
    expect_status(invoke(camera, OsdCamera::CMD_SNAPSHOT_STREAM_ALLOCATE,
      osd_request(false, false)), OsdCode::InvalidCommand)

    camera.on_snapshot_allocate { |_request, _id| OsdStatus.success }
    id = invoke_response(camera, OsdCamera::CMD_SNAPSHOT_STREAM_ALLOCATE,
      osd_request(nil, false), OsdCamera::SnapshotStreamAllocateResponse).snapshot_stream_id
    stream = camera.allocated_snapshot_streams.first
    stream.osd_enabled.should be_false
    stream.watermark_enabled.should be_nil
    stream.to_tlv.as_structure.keys.should contain(10_u8)
    stream.to_tlv.as_structure.keys.should_not contain(9_u8)

    modified = [] of Tuple(UInt16, Bool?, Bool?)
    camera.on_snapshot_modify_overlays do |stream_id, watermark, osd|
      modified << {stream_id, watermark, osd}
      OsdStatus.success
    end
    expect_success(invoke(camera, OsdCamera::CMD_SNAPSHOT_STREAM_MODIFY,
      OsdCamera::SnapshotStreamModifyRequest.new(id, nil, true)))
    modified.should eq([{id, nil, true}])
    camera.allocated_snapshot_streams.first.osd_enabled.should be_true
    restored = osd_camera(OsdCamera::Feature::Snapshot | OsdCamera::Feature::Osd)
    restored.restore_state(camera.save_state.as(Matter::Storage::Document))
    restored.allocated_snapshot_streams.first.osd_enabled.should be_true
    unsupported = osd_camera(OsdCamera::Feature::Snapshot)
    unsupported.restore_state(camera.save_state.as(Matter::Storage::Document))
    unsupported.allocated_snapshot_streams.should be_empty
  end

  it "applies combined overlay changes atomically and rejects absent or unsupported fields" do
    features = OsdCamera::Feature::Snapshot | OsdCamera::Feature::Watermark | OsdCamera::Feature::Osd
    camera = osd_camera(features)
    camera.on_snapshot_allocate { |_request, _id| OsdStatus.success }
    id = invoke_response(camera, OsdCamera::CMD_SNAPSHOT_STREAM_ALLOCATE,
      osd_request(false, false), OsdCamera::SnapshotStreamAllocateResponse).snapshot_stream_id
    both = OsdCamera::SnapshotStreamModifyRequest.new(id, true, true)
    expect_status(invoke(camera, OsdCamera::CMD_SNAPSHOT_STREAM_MODIFY, both), OsdCode::InvalidInState)
    camera.on_snapshot_modify_overlays { |_id, _watermark, _osd| OsdStatus.failure }
    expect_status(invoke(camera, OsdCamera::CMD_SNAPSHOT_STREAM_MODIFY, both), OsdCode::Failure)
    camera.allocated_snapshot_streams.first.watermark_enabled.should be_false
    camera.allocated_snapshot_streams.first.osd_enabled.should be_false
    camera.on_snapshot_modify_overlays { |_id, _watermark, _osd| OsdStatus.success }
    expect_success(invoke(camera, OsdCamera::CMD_SNAPSHOT_STREAM_MODIFY, both))
    camera.allocated_snapshot_streams.first.watermark_enabled.should be_true
    camera.allocated_snapshot_streams.first.osd_enabled.should be_true
    expect_success(invoke(camera, OsdCamera::CMD_SNAPSHOT_STREAM_MODIFY,
      OsdCamera::SnapshotStreamModifyRequest.new(id, nil, false)))
    camera.allocated_snapshot_streams.first.watermark_enabled.should be_true
    camera.allocated_snapshot_streams.first.osd_enabled.should be_false
    expect_status(invoke(camera, OsdCamera::CMD_SNAPSHOT_STREAM_MODIFY,
      OsdCamera::SnapshotStreamModifyRequest.new(id)), OsdCode::InvalidCommand)
    expect_status(invoke(camera, OsdCamera::CMD_SNAPSHOT_STREAM_ALLOCATE,
      osd_request(true)), OsdCode::InvalidCommand)
  end
end
