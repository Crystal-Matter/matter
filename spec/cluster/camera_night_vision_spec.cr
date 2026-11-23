require "../spec_helper"

private alias NightCamera = Matter::Cluster::CameraAvStreamManagement
private alias NightStatus = Matter::InteractionModel::Status
private alias NightCode = Matter::InteractionModel::StatusCode

private def night_snapshot_camera(features : NightCamera::Feature = NightCamera::Feature::Snapshot | NightCamera::Feature::NightVision,
                                  infrared : Bool = true, illumination : Bool = false)
  build(NightCamera,
    supported_stream_usages: [NightCamera::StreamUsage::LiveView],
    max_content_buffer_size: 1024_u32, max_network_bandwidth: 100_000_u32,
    max_concurrent_encoders: 1_u8, max_encoded_pixel_rate: 2_000_000_u32,
    snapshot_capabilities: [NightCamera::SnapshotCapability.new(
      NightCamera::VideoResolution.new(640_u16, 480_u16), 10_u16,
      NightCamera::ImageCodec::Jpeg, true, true)],
    night_vision_uses_infrared: infrared,
    night_vision_illum_supported: illumination,
    feature_map: features)
end

describe "Camera AV Night Vision feature" do
  it "advertises the required fixed and Manage attributes only with NV" do
    camera = night_snapshot_camera
    camera.attributes.map(&.id.id).should contain(NightCamera::ATTR_NIGHT_VISION_USES_INFRARED)
    camera.attributes.map(&.id.id).should contain(NightCamera::ATTR_NIGHT_VISION)
    camera.attributes.map(&.id.id).should_not contain(NightCamera::ATTR_NIGHT_VISION_ILLUM)
    expect_status(read_status(camera, NightCamera::ATTR_NIGHT_VISION_ILLUM), NightCode::UnsupportedAttribute)
    read(camera, NightCamera::ATTR_NIGHT_VISION_USES_INFRARED).should be_true
    read(camera, NightCamera::ATTR_NIGHT_VISION).should eq(NightCamera::TriStateAuto::Off.value)
    metadata = camera.get_attribute_metadata(NightCamera::ATTR_NIGHT_VISION)
      .as(Matter::Cluster::AttributeMetadata)
    metadata.access.should eq(Matter::InteractionModel::EntryPrivilege::Manage)
    metadata.write_access.should eq(Matter::InteractionModel::EntryPrivilege::Manage)

    plain = night_snapshot_camera(NightCamera::Feature::Snapshot, infrared: false)
    expect_status(read_status(plain, NightCamera::ATTR_NIGHT_VISION), NightCode::UnsupportedAttribute)
    expect_raises(ArgumentError, "Night Vision requires Video or Snapshot") do
      night_snapshot_camera(NightCamera::Feature::Audio | NightCamera::Feature::NightVision)
    end
  end

  it "commits host admitted mode changes and restores both optional controls" do
    camera = night_snapshot_camera(illumination: true)
    camera.attributes.map(&.id.id).should contain(NightCamera::ATTR_NIGHT_VISION_ILLUM)
    expect_status(write(camera, NightCamera::ATTR_NIGHT_VISION, NightCamera::TriStateAuto::Auto),
      NightCode::InvalidInState)
    modes = [] of NightCamera::TriStateAuto
    camera.on_night_vision_changed do |mode|
      modes << mode
      NightStatus.success
    end
    camera.on_night_vision_illum_changed { |_mode| NightStatus.success }
    expect_status(write(camera, NightCamera::ATTR_NIGHT_VISION, NightCamera::TriStateAuto.new(3_u8)),
      NightCode::ConstraintError)
    expect_success(write(camera, NightCamera::ATTR_NIGHT_VISION, NightCamera::TriStateAuto::Auto))
    expect_success(write(camera, NightCamera::ATTR_NIGHT_VISION_ILLUM, NightCamera::TriStateAuto::On))
    modes.should eq([NightCamera::TriStateAuto::Off, NightCamera::TriStateAuto::Auto])

    restored = night_snapshot_camera(illumination: true)
    restored.restore_state(camera.save_state.as(Matter::Storage::Document))
    read(restored, NightCamera::ATTR_NIGHT_VISION).should eq(NightCamera::TriStateAuto::Auto.value)
    read(restored, NightCamera::ATTR_NIGHT_VISION_ILLUM).should eq(NightCamera::TriStateAuto::On.value)
    applied = [] of NightCamera::TriStateAuto
    restored.on_night_vision_changed do |mode|
      applied << mode
      NightStatus.success
    end
    applied.should eq([NightCamera::TriStateAuto::Auto])

    rejected = night_snapshot_camera
    rejected.on_night_vision_changed do |mode|
      mode == NightCamera::TriStateAuto::Off ? NightStatus.success : NightStatus.invalid_in_state
    end
    expect_status(write(rejected, NightCamera::ATTR_NIGHT_VISION, NightCamera::TriStateAuto::On),
      NightCode::InvalidInState)
    read(rejected, NightCamera::ATTR_NIGHT_VISION).should eq(NightCamera::TriStateAuto::Off.value)
  end
end
