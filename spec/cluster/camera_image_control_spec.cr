require "../spec_helper"

private alias ImageControlCamera = Matter::Cluster::CameraAvStreamManagement
private alias ImageControlStatus = Matter::InteractionModel::Status
private alias ImageControlCode = Matter::InteractionModel::StatusCode

private def image_control_camera(features : ImageControlCamera::Feature = ImageControlCamera::Feature::Snapshot | ImageControlCamera::Feature::ImageControl)
  build(ImageControlCamera,
    supported_stream_usages: [ImageControlCamera::StreamUsage::LiveView],
    max_content_buffer_size: 1024_u32, max_network_bandwidth: 100_000_u32,
    max_concurrent_encoders: 1_u8, max_encoded_pixel_rate: 2_000_000_u32,
    snapshot_capabilities: [ImageControlCamera::SnapshotCapability.new(
      ImageControlCamera::VideoResolution.new(640_u16, 480_u16), 10_u16,
      ImageControlCamera::ImageCodec::Jpeg, true, true)],
    feature_map: features)
end

describe "Camera AV Image Control rotation" do
  it "advertises a manageable rotation only with Image Control" do
    camera = image_control_camera
    read(camera, Matter::Cluster::Base::GLOBAL_FEATURE_MAP)
      .should eq((ImageControlCamera::Feature::Snapshot | ImageControlCamera::Feature::ImageControl).value)
    camera.attributes.map(&.id.id).should contain(ImageControlCamera::ATTR_IMAGE_ROTATION)
    metadata = camera.get_attribute_metadata(ImageControlCamera::ATTR_IMAGE_ROTATION)
      .as(Matter::Cluster::AttributeMetadata)
    metadata.access.should eq(Matter::InteractionModel::EntryPrivilege::Manage)
    metadata.write_access.should eq(Matter::InteractionModel::EntryPrivilege::Manage)
    expect_status(read_status(image_control_camera(ImageControlCamera::Feature::Snapshot),
      ImageControlCamera::ATTR_IMAGE_ROTATION), ImageControlCode::UnsupportedAttribute)
  end

  it "requires Video or Snapshot when Image Control is advertised" do
    microphone = ImageControlCamera::AudioCapabilities.new(1_u8,
      [ImageControlCamera::AudioCodec::Opus], [48_000_u32], [16_u8])
    expect_raises(ArgumentError, "Image Control requires Snapshot or Video") do
      build(ImageControlCamera,
        supported_stream_usages: [ImageControlCamera::StreamUsage::LiveView],
        max_content_buffer_size: 1024_u32, max_network_bandwidth: 100_000_u32,
        microphone_capabilities: microphone,
        feature_map: ImageControlCamera::Feature::Audio | ImageControlCamera::Feature::ImageControl)
    end
  end

  it "admits orientation before committing, validates bounds, and restores state" do
    camera = image_control_camera
    expect_status(write(camera, ImageControlCamera::ATTR_IMAGE_ROTATION, 90_u16),
      ImageControlCode::InvalidInState)
    applied = [] of UInt16
    reject_next = false
    camera.on_image_rotation_changed do |angle|
      if reject_next
        reject_next = false
        ImageControlStatus.failure
      else
        applied << angle
        ImageControlStatus.success
      end
    end
    applied.should eq([0_u16])
    expect_status(write(camera, ImageControlCamera::ATTR_IMAGE_ROTATION, 360_u16),
      ImageControlCode::ConstraintError)
    reject_next = true
    expect_status(write(camera, ImageControlCamera::ATTR_IMAGE_ROTATION, 90_u16),
      ImageControlCode::Failure)
    camera.image_rotation.should eq(0_u16)
    expect_success(write(camera, ImageControlCamera::ATTR_IMAGE_ROTATION, 90_u16))
    camera.image_rotation.should eq(90_u16)
    applied.should eq([0_u16, 90_u16])

    restored = image_control_camera
    restored.restore_state(camera.save_state.as(Matter::Storage::Document))
    restored.image_rotation.should eq(90_u16)
    restored_applied = [] of UInt16
    restored.on_image_rotation_changed do |angle|
      restored_applied << angle
      ImageControlStatus.success
    end
    restored_applied.should eq([90_u16])
  end
end
