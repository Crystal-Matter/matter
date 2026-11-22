require "../spec_helper"

private alias AgcCamera = Matter::Cluster::CameraAvStreamManagement
private alias AgcStatus = Matter::InteractionModel::Status
private alias AgcCode = Matter::InteractionModel::StatusCode

private def agc_audio_camera(supported : Bool = true)
  microphone = AgcCamera::AudioCapabilities.new(1_u8,
    [AgcCamera::AudioCodec::Opus], [48_000_u32], [16_u8])
  build(AgcCamera,
    supported_stream_usages: [AgcCamera::StreamUsage::LiveView],
    max_content_buffer_size: 1024_u32, max_network_bandwidth: 100_000_u32,
    microphone_capabilities: microphone,
    microphone_agc_supported: supported,
    feature_map: AgcCamera::Feature::Audio)
end

describe "Camera AV optional microphone AGC" do
  it "advertises a Manage writable default-on attribute only for opted-in ADO" do
    camera = agc_audio_camera
    camera.attributes.map(&.id.id).should contain(AgcCamera::ATTR_MICROPHONE_AGC_ENABLED)
    read(camera, AgcCamera::ATTR_MICROPHONE_AGC_ENABLED).should be_true
    metadata = camera.get_attribute_metadata(AgcCamera::ATTR_MICROPHONE_AGC_ENABLED)
      .as(Matter::Cluster::AttributeMetadata)
    metadata.access.should eq(Matter::InteractionModel::EntryPrivilege::Manage)
    metadata.write_access.should eq(Matter::InteractionModel::EntryPrivilege::Manage)
    expect_status(read_status(agc_audio_camera(false),
      AgcCamera::ATTR_MICROPHONE_AGC_ENABLED), AgcCode::UnsupportedAttribute)

    expect_raises(ArgumentError, "Microphone AGC requires Audio") do
      build(AgcCamera,
        supported_stream_usages: [AgcCamera::StreamUsage::LiveView],
        max_content_buffer_size: 1024_u32, max_network_bandwidth: 100_000_u32,
        max_concurrent_encoders: 1_u8, max_encoded_pixel_rate: 2_000_000_u32,
        snapshot_capabilities: [AgcCamera::SnapshotCapability.new(
          AgcCamera::VideoResolution.new(640_u16, 480_u16), 10_u16,
          AgcCamera::ImageCodec::Jpeg, true, true)],
        microphone_agc_supported: true,
        feature_map: AgcCamera::Feature::Snapshot)
    end
  end

  it "applies host admission before persisting an AGC write" do
    camera = agc_audio_camera
    expect_status(write(camera, AgcCamera::ATTR_MICROPHONE_AGC_ENABLED, false), AgcCode::InvalidInState)
    applied = [] of Bool
    camera.on_microphone_agc_changed do |enabled|
      applied << enabled
      AgcStatus.success
    end
    expect_success(write(camera, AgcCamera::ATTR_MICROPHONE_AGC_ENABLED, false))
    applied.should eq([true, false])

    restored = agc_audio_camera
    restored.restore_state(camera.save_state.as(Matter::Storage::Document))
    read(restored, AgcCamera::ATTR_MICROPHONE_AGC_ENABLED).should be_false
    resumed = [] of Bool
    restored.on_microphone_agc_changed do |enabled|
      resumed << enabled
      AgcStatus.success
    end
    resumed.should eq([false])

    rejected = agc_audio_camera
    rejected.on_microphone_agc_changed do |enabled|
      enabled ? AgcStatus.success : AgcStatus.invalid_in_state
    end
    expect_status(write(rejected, AgcCamera::ATTR_MICROPHONE_AGC_ENABLED, false), AgcCode::InvalidInState)
    read(rejected, AgcCamera::ATTR_MICROPHONE_AGC_ENABLED).should be_true
  end
end
