require "../spec_helper"

private alias SpeakerCamera = Matter::Cluster::CameraAvStreamManagement

private def speaker_audio_capabilities
  SpeakerCamera::AudioCapabilities.new(1_u8, [SpeakerCamera::AudioCodec::Opus], [48_000_u32], [16_u8])
end

private def speaker_camera(feature_map : SpeakerCamera::Feature = SpeakerCamera::Feature.new(0x11_u32),
                           speaker_capabilities : SpeakerCamera::AudioCapabilities? = speaker_audio_capabilities,
                           two_way_talk_support : SpeakerCamera::TwoWayTalkSupport? = SpeakerCamera::TwoWayTalkSupport::HalfDuplex,
                           speaker_min_level : UInt8 = 10_u8,
                           speaker_max_level : UInt8 = 100_u8,
                           speaker_volume_level : UInt8 = 50_u8)
  build(SpeakerCamera,
    microphone_capabilities: speaker_audio_capabilities,
    speaker_capabilities: speaker_capabilities,
    two_way_talk_support: two_way_talk_support,
    speaker_min_level: speaker_min_level,
    speaker_max_level: speaker_max_level,
    speaker_volume_level: speaker_volume_level,
    supported_stream_usages: [SpeakerCamera::StreamUsage::LiveView],
    max_content_buffer_size: 65_536_u32,
    max_network_bandwidth: 96_000_u32,
    feature_map: feature_map)
end

describe "Camera AV Speaker profile" do
  it "admits the Matter 1.6 Speaker feature only with Audio" do
    camera = speaker_camera
    read(camera, Matter::Cluster::Base::GLOBAL_FEATURE_MAP).should eq(0x11_u32)
    expect_raises(ArgumentError) { speaker_camera(SpeakerCamera::Feature::Speaker) }
    expect_raises(ArgumentError) { speaker_camera(speaker_capabilities: nil) }
    expect_raises(ArgumentError) { speaker_camera(two_way_talk_support: nil) }
    expect_raises(ArgumentError) { speaker_camera(two_way_talk_support: SpeakerCamera::TwoWayTalkSupport.new(3_u8)) }
    audio_only = speaker_camera(SpeakerCamera::Feature::Audio,
      speaker_capabilities: nil, two_way_talk_support: nil)
    expect_status(read_status(audio_only, SpeakerCamera::ATTR_SPEAKER_MUTED),
      Matter::InteractionModel::StatusCode::UnsupportedAttribute)
  end

  it "advertises the required fixed and persistent speaker attributes with Manage privilege" do
    camera = speaker_camera
    ids = camera.attributes.map(&.id.id)
    [SpeakerCamera::ATTR_SPEAKER_CAPABILITIES, SpeakerCamera::ATTR_TWO_WAY_TALK_SUPPORT,
     SpeakerCamera::ATTR_SPEAKER_MUTED, SpeakerCamera::ATTR_SPEAKER_VOLUME_LEVEL,
     SpeakerCamera::ATTR_SPEAKER_MAX_LEVEL, SpeakerCamera::ATTR_SPEAKER_MIN_LEVEL].each do |id|
      ids.should contain(id)
    end
    read_tlv(camera, SpeakerCamera::ATTR_SPEAKER_CAPABILITIES).as_structure.keys
      .should eq([0_u8, 1_u8, 2_u8, 3_u8])
    read(camera, SpeakerCamera::ATTR_TWO_WAY_TALK_SUPPORT).should eq(SpeakerCamera::TwoWayTalkSupport::HalfDuplex.value)
    [SpeakerCamera::ATTR_SPEAKER_MUTED, SpeakerCamera::ATTR_SPEAKER_VOLUME_LEVEL,
     SpeakerCamera::ATTR_SPEAKER_MAX_LEVEL, SpeakerCamera::ATTR_SPEAKER_MIN_LEVEL].each do |id|
      metadata = camera.get_attribute_metadata(id).as(Matter::Cluster::AttributeMetadata)
      metadata.access.should eq(Matter::InteractionModel::EntryPrivilege::Manage)
      metadata.write_access.should eq(Matter::InteractionModel::EntryPrivilege::Manage)
    end
    camera.get_attribute_metadata(SpeakerCamera::ATTR_SPEAKER_CAPABILITIES)
      .as(Matter::Cluster::AttributeMetadata).fixed?.should be_true
    camera.get_attribute_metadata(SpeakerCamera::ATTR_TWO_WAY_TALK_SUPPORT)
      .as(Matter::Cluster::AttributeMetadata).fixed?.should be_true
  end

  it "validates speaker volume bounds before exposing the profile" do
    expect_raises(ArgumentError) { speaker_camera(speaker_min_level: 101_u8) }
    expect_raises(ArgumentError) { speaker_camera(speaker_max_level: 255_u8) }
    expect_raises(ArgumentError) { speaker_camera(speaker_volume_level: 9_u8) }
    expect_raises(ArgumentError) { speaker_camera(speaker_volume_level: 101_u8) }
  end

  it "applies settings through the host before committing and preserves them across restore" do
    camera = speaker_camera
    expect_status(write(camera, SpeakerCamera::ATTR_SPEAKER_MUTED, true),
      Matter::InteractionModel::StatusCode::InvalidInState)
    applied = [] of {Bool, UInt8}
    reject_next = false
    camera.on_speaker_settings_changed do |muted, volume|
      if reject_next
        reject_next = false
        Matter::InteractionModel::Status.failure
      else
        applied << {muted, volume}
        Matter::InteractionModel::Status.success
      end
    end
    applied.should eq([{false, 50_u8}])
    reject_next = true
    expect_status(write(camera, SpeakerCamera::ATTR_SPEAKER_MUTED, true),
      Matter::InteractionModel::StatusCode::Failure)
    camera.speaker_muted?.should be_false
    expect_status(write(camera, SpeakerCamera::ATTR_SPEAKER_VOLUME_LEVEL, 9_u8),
      Matter::InteractionModel::StatusCode::ConstraintError)
    expect_status(write(camera, SpeakerCamera::ATTR_SPEAKER_VOLUME_LEVEL, 101_u8),
      Matter::InteractionModel::StatusCode::ConstraintError)
    reject_next = true
    expect_status(write(camera, SpeakerCamera::ATTR_SPEAKER_VOLUME_LEVEL, 70_u8),
      Matter::InteractionModel::StatusCode::Failure)
    camera.speaker_volume_level.should eq(50_u8)
    expect_success(write(camera, SpeakerCamera::ATTR_SPEAKER_MUTED, true))
    expect_success(write(camera, SpeakerCamera::ATTR_SPEAKER_VOLUME_LEVEL, 70_u8))
    applied.should eq([{false, 50_u8}, {true, 50_u8}, {true, 70_u8}])

    saved = camera.save_state.as(Matter::Storage::Document)
    restored = speaker_camera
    restored.restore_state(saved)
    restored.speaker_muted?.should be_true
    restored.speaker_volume_level.should eq(70_u8)
    restored_applied = [] of {Bool, UInt8}
    restored.on_speaker_settings_changed do |muted, volume|
      restored_applied << {muted, volume}
      Matter::InteractionModel::Status.success
    end
    restored_applied.should eq([{true, 70_u8}])
  end

  it "refuses to attach a speaker host that cannot apply restored settings" do
    camera = speaker_camera
    expect_raises(Matter::ClusterError) do
      camera.on_speaker_settings_changed { |_muted, _volume| Matter::InteractionModel::Status.failure }
    end
    expect_status(write(camera, SpeakerCamera::ATTR_SPEAKER_MUTED, true),
      Matter::InteractionModel::StatusCode::InvalidInState)
  end
end
