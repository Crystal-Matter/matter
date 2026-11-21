require "../spec_helper"

private alias ImageControlCamera = Matter::Cluster::CameraAvStreamManagement
private alias ImageControlStatus = Matter::InteractionModel::Status
private alias ImageControlCode = Matter::InteractionModel::StatusCode

private def image_control_camera(features : ImageControlCamera::Feature = ImageControlCamera::Feature::Snapshot | ImageControlCamera::Feature::ImageControl,
                                 horizontal : Bool = false, vertical : Bool = false)
  build(ImageControlCamera,
    supported_stream_usages: [ImageControlCamera::StreamUsage::LiveView],
    max_content_buffer_size: 1024_u32, max_network_bandwidth: 100_000_u32,
    max_concurrent_encoders: 1_u8, max_encoded_pixel_rate: 2_000_000_u32,
    snapshot_capabilities: [ImageControlCamera::SnapshotCapability.new(
      ImageControlCamera::VideoResolution.new(640_u16, 480_u16), 10_u16,
      ImageControlCamera::ImageCodec::Jpeg, true, true)],
    image_flip_horizontal_supported: horizontal,
    image_flip_vertical_supported: vertical,
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

  it "advertises independently opted-in flip attributes with Manage privilege" do
    rotation_only = image_control_camera
    rotation_only.attributes.map(&.id.id).should_not contain(ImageControlCamera::ATTR_IMAGE_FLIP_HORIZONTAL)
    rotation_only.attributes.map(&.id.id).should_not contain(ImageControlCamera::ATTR_IMAGE_FLIP_VERTICAL)
    horizontal_only = image_control_camera(horizontal: true)
    horizontal_only.attributes.map(&.id.id).should contain(ImageControlCamera::ATTR_IMAGE_FLIP_HORIZONTAL)
    horizontal_only.attributes.map(&.id.id).should_not contain(ImageControlCamera::ATTR_IMAGE_FLIP_VERTICAL)
    camera = image_control_camera(horizontal: true, vertical: true)
    [ImageControlCamera::ATTR_IMAGE_FLIP_HORIZONTAL, ImageControlCamera::ATTR_IMAGE_FLIP_VERTICAL].each do |id|
      metadata = camera.get_attribute_metadata(id).as(Matter::Cluster::AttributeMetadata)
      metadata.access.should eq(Matter::InteractionModel::EntryPrivilege::Manage)
      metadata.write_access.should eq(Matter::InteractionModel::EntryPrivilege::Manage)
      metadata.optional?.should be_true
    end
    expect_raises(ArgumentError, "Image Control flip settings require Image Control") do
      image_control_camera(ImageControlCamera::Feature::Snapshot, horizontal: true)
    end
  end

  it "commits flips only after host admission and restores their state" do
    camera = image_control_camera(horizontal: true, vertical: true)
    expect_status(write(camera, ImageControlCamera::ATTR_IMAGE_FLIP_HORIZONTAL, true),
      ImageControlCode::InvalidInState)
    applied = [] of {Bool, Bool}
    reject_next = false
    camera.on_image_flip_changed do |horizontal, vertical|
      if reject_next
        reject_next = false
        ImageControlStatus.failure
      else
        applied << {horizontal, vertical}
        ImageControlStatus.success
      end
    end
    applied.should eq([{false, false}])
    reject_next = true
    expect_status(write(camera, ImageControlCamera::ATTR_IMAGE_FLIP_VERTICAL, true),
      ImageControlCode::Failure)
    camera.image_flip_vertical?.should be_false
    expect_success(write(camera, ImageControlCamera::ATTR_IMAGE_FLIP_HORIZONTAL, true))
    expect_success(write(camera, ImageControlCamera::ATTR_IMAGE_FLIP_VERTICAL, true))
    applied.should eq([{false, false}, {true, false}, {true, true}])

    restored = image_control_camera(horizontal: true, vertical: true)
    restored.restore_state(camera.save_state.as(Matter::Storage::Document))
    restored.image_flip_horizontal?.should be_true
    restored.image_flip_vertical?.should be_true
    restored_applied = [] of {Bool, Bool}
    restored.on_image_flip_changed do |horizontal, vertical|
      restored_applied << {horizontal, vertical}
      ImageControlStatus.success
    end
    restored_applied.should eq([{true, true}])
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
