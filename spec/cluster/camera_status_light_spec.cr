require "../spec_helper"

private alias LightCamera = Matter::Cluster::CameraAvStreamManagement
private alias LightStatus = Matter::InteractionModel::Status
private alias LightCode = Matter::InteractionModel::StatusCode

private def status_light_camera(enabled : Bool = true, brightness : Bool = true)
  microphone = LightCamera::AudioCapabilities.new(1_u8,
    [LightCamera::AudioCodec::Opus], [48_000_u32], [16_u8])
  build(LightCamera,
    supported_stream_usages: [LightCamera::StreamUsage::LiveView],
    max_content_buffer_size: 1024_u32, max_network_bandwidth: 100_000_u32,
    microphone_capabilities: microphone,
    status_light_enabled_supported: enabled,
    status_light_brightness_supported: brightness,
    feature_map: LightCamera::Feature::Audio)
end

describe "Camera AV optional status light" do
  it "exposes the independent Manage attributes only when opted in" do
    both = status_light_camera
    enabled_only = status_light_camera(brightness: false)
    brightness_only = status_light_camera(enabled: false)
    neither = status_light_camera(enabled: false, brightness: false)

    both.attributes.map(&.id.id).should contain(LightCamera::ATTR_STATUS_LIGHT_ENABLED)
    both.attributes.map(&.id.id).should contain(LightCamera::ATTR_STATUS_LIGHT_BRIGHTNESS)
    enabled_only.attributes.map(&.id.id).should contain(LightCamera::ATTR_STATUS_LIGHT_ENABLED)
    enabled_only.attributes.map(&.id.id).should_not contain(LightCamera::ATTR_STATUS_LIGHT_BRIGHTNESS)
    brightness_only.attributes.map(&.id.id).should_not contain(LightCamera::ATTR_STATUS_LIGHT_ENABLED)
    brightness_only.attributes.map(&.id.id).should contain(LightCamera::ATTR_STATUS_LIGHT_BRIGHTNESS)
    neither.attributes.map(&.id.id).should_not contain(LightCamera::ATTR_STATUS_LIGHT_ENABLED)
    neither.attributes.map(&.id.id).should_not contain(LightCamera::ATTR_STATUS_LIGHT_BRIGHTNESS)
    read(both, LightCamera::ATTR_STATUS_LIGHT_ENABLED).should be_true
    read(both, LightCamera::ATTR_STATUS_LIGHT_BRIGHTNESS).should eq(LightCamera::ThreeLevelAuto::Auto.value)

    [LightCamera::ATTR_STATUS_LIGHT_ENABLED, LightCamera::ATTR_STATUS_LIGHT_BRIGHTNESS].each do |attribute|
      metadata = both.get_attribute_metadata(attribute).as(Matter::Cluster::AttributeMetadata)
      metadata.access.should eq(Matter::InteractionModel::EntryPrivilege::Manage)
      metadata.write_access.should eq(Matter::InteractionModel::EntryPrivilege::Manage)
    end
    expect_status(read_status(neither, LightCamera::ATTR_STATUS_LIGHT_ENABLED), LightCode::UnsupportedAttribute)
  end

  it "requires host admission, validates brightness, and restores settings" do
    camera = status_light_camera
    expect_status(write(camera, LightCamera::ATTR_STATUS_LIGHT_ENABLED, false), LightCode::InvalidInState)
    expect_status(write(camera, LightCamera::ATTR_STATUS_LIGHT_BRIGHTNESS,
      LightCamera::ThreeLevelAuto::High), LightCode::InvalidInState)

    enabled = [] of Bool
    brightness = [] of LightCamera::ThreeLevelAuto
    camera.on_status_light_enabled_changed do |value|
      enabled << value
      LightStatus.success
    end
    camera.on_status_light_brightness_changed do |value|
      brightness << value
      LightStatus.success
    end
    expect_success(write(camera, LightCamera::ATTR_STATUS_LIGHT_ENABLED, false))
    expect_success(write(camera, LightCamera::ATTR_STATUS_LIGHT_BRIGHTNESS,
      LightCamera::ThreeLevelAuto::High))
    enabled.should eq([true, false])
    brightness.should eq([LightCamera::ThreeLevelAuto::Auto, LightCamera::ThreeLevelAuto::High])
    expect_status(write(camera, LightCamera::ATTR_STATUS_LIGHT_BRIGHTNESS,
      LightCamera::ThreeLevelAuto.new(4_u8)), LightCode::ConstraintError)

    restored = status_light_camera
    restored.restore_state(camera.save_state.as(Matter::Storage::Document))
    read(restored, LightCamera::ATTR_STATUS_LIGHT_ENABLED).should be_false
    read(restored, LightCamera::ATTR_STATUS_LIGHT_BRIGHTNESS).should eq(LightCamera::ThreeLevelAuto::High.value)
    restored.on_status_light_enabled_changed { |value| enabled << value; LightStatus.success }
    restored.on_status_light_brightness_changed { |value| brightness << value; LightStatus.success }
    enabled.last.should be_false
    brightness.last.should eq(LightCamera::ThreeLevelAuto::High)
  end
end
