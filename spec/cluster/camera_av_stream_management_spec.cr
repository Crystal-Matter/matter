require "../spec_helper"

private alias CameraAv = Matter::Cluster::CameraAvStreamManagement
private alias CameraCode = Matter::InteractionModel::StatusCode
private alias CameraStatus = Matter::InteractionModel::Status

private def camera_capabilities
  CameraAv::AudioCapabilities.new(2_u8, [CameraAv::AudioCodec::Opus],
    [16_000_u32, 48_000_u32], [16_u8, 24_u8])
end

private def camera_av(max_bandwidth = 128_000_u32, feature_map = CameraAv::Feature::Audio)
  build(CameraAv, microphone_capabilities: camera_capabilities,
    supported_stream_usages: [CameraAv::StreamUsage::LiveView, CameraAv::StreamUsage::Recording],
    max_content_buffer_size: 65_536_u32, max_network_bandwidth: max_bandwidth,
    feature_map: feature_map)
end

private def audio_request(usage = CameraAv::StreamUsage::LiveView, bit_rate = 64_000_u32)
  CameraAv::AudioStreamAllocateRequest.new(usage, CameraAv::AudioCodec::Opus,
    1_u8, 48_000_u32, bit_rate, 16_u8)
end

private def admit_audio(camera : CameraAv)
  camera.on_audio_allocate { |_request, _id| CameraStatus.success }
  camera.on_audio_deallocate { |_id| CameraStatus.success }
end

describe CameraAv do
  it "advertises revision two and only the implemented audio commands" do
    camera = camera_av
    camera.cluster_id.id.should eq(0x0551_u32)
    camera.cluster_revision.should eq(2_u16)
    read(camera, Matter::Cluster::Base::GLOBAL_FEATURE_MAP).should eq(CameraAv::Feature::Audio.value)
    camera.attributes.map(&.id.id).should eq([
      CameraAv::ATTR_MAX_CONTENT_BUFFER_SIZE, CameraAv::ATTR_MICROPHONE_CAPABILITIES,
      CameraAv::ATTR_MAX_NETWORK_BANDWIDTH, CameraAv::ATTR_SUPPORTED_STREAM_USAGES,
      CameraAv::ATTR_ALLOCATED_AUDIO_STREAMS, CameraAv::ATTR_STREAM_USAGE_PRIORITIES,
      CameraAv::ATTR_HARD_PRIVACY_MODE_ON, CameraAv::ATTR_MICROPHONE_MUTED,
      CameraAv::ATTR_MICROPHONE_VOLUME_LEVEL, CameraAv::ATTR_MICROPHONE_MAX_LEVEL,
      CameraAv::ATTR_MICROPHONE_MIN_LEVEL,
    ])
    camera.commands.map(&.id.id).should eq([
      CameraAv::CMD_AUDIO_STREAM_ALLOCATE, CameraAv::CMD_AUDIO_STREAM_DEALLOCATE,
      CameraAv::CMD_SET_STREAM_PRIORITIES,
    ])
    camera.get_command_metadata(CameraAv::CMD_AUDIO_STREAM_ALLOCATE)
      .as(Matter::Cluster::CommandMetadata).access.should eq(Matter::InteractionModel::EntryPrivilege::Manage)
    camera.get_command_metadata(CameraAv::CMD_SET_STREAM_PRIORITIES)
      .as(Matter::Cluster::CommandMetadata).access.should eq(Matter::InteractionModel::EntryPrivilege::Administer)
    camera.get_attribute_metadata(CameraAv::ATTR_MICROPHONE_VOLUME_LEVEL)
      .as(Matter::Cluster::AttributeMetadata).access.should eq(Matter::InteractionModel::EntryPrivilege::Manage)
    read_tlv(camera, CameraAv::ATTR_MICROPHONE_CAPABILITIES).as_structure.keys.should eq([0_u8, 1_u8, 2_u8, 3_u8])
    read_tlv(camera, CameraAv::ATTR_ALLOCATED_AUDIO_STREAMS).as_list.should be_empty
    expect_status(read_status(camera, CameraAv::ATTR_SOFT_RECORDING_PRIVACY_MODE_ENABLED), CameraCode::UnsupportedAttribute)
  end

  it "validates capabilities, usages and microphone bounds before exposing them" do
    expect_raises(ArgumentError) { CameraAv::AudioCapabilities.new(0_u8, [CameraAv::AudioCodec::Opus], [48_000_u32], [16_u8]) }
    expect_raises(ArgumentError) { CameraAv::AudioCapabilities.new(1_u8, [CameraAv::AudioCodec.new(3_u8)], [48_000_u32], [16_u8]) }
    expect_raises(ArgumentError) { CameraAv::AudioCapabilities.new(1_u8, [CameraAv::AudioCodec::Opus], [0_u32], [16_u8]) }
    expect_raises(ArgumentError) { CameraAv::AudioCapabilities.new(1_u8, [CameraAv::AudioCodec::Opus], [48_000_u32], [12_u8]) }
    CameraAv::AudioCapabilities.new(10_u8, [CameraAv::AudioCodec::Opus], [48_000_u32], [16_u8])
    expect_raises(ArgumentError) do
      build(CameraAv, microphone_capabilities: camera_capabilities,
        supported_stream_usages: [] of CameraAv::StreamUsage,
        max_content_buffer_size: 1_u32, max_network_bandwidth: 1_u32)
    end
    camera = camera_av
    camera.microphone_capabilities.supported_sample_rates.clear
    camera.microphone_capabilities.supported_sample_rates.should eq([16_000_u32, 48_000_u32])
    camera.supported_stream_usages.clear
    camera.supported_stream_usages.should eq([CameraAv::StreamUsage::LiveView, CameraAv::StreamUsage::Recording])
    expect_status(write(camera, CameraAv::ATTR_MICROPHONE_VOLUME_LEVEL, 101_u8), CameraCode::ConstraintError)
    expect_success(write(camera, CameraAv::ATTR_MICROPHONE_VOLUME_LEVEL, 80_u8))
    camera.microphone_volume_level.should eq(80_u8)
  end

  it "validates requests and admits unique audio streams through the host" do
    camera = camera_av
    request = audio_request
    expect_status(invoke(camera, CameraAv::CMD_AUDIO_STREAM_ALLOCATE, request), CameraCode::InvalidInState)
    allocated_ids = [] of UInt16
    camera.on_audio_allocate do |_requested, id|
      allocated_ids << id
      CameraStatus.success
    end
    camera.on_audio_deallocate { |_id| CameraStatus.success }
    first = invoke_response(camera, CameraAv::CMD_AUDIO_STREAM_ALLOCATE, request, CameraAv::AudioStreamAllocateResponse)
    first.audio_stream_id.should eq(0_u16)
    second = invoke_response(camera, CameraAv::CMD_AUDIO_STREAM_ALLOCATE,
      audio_request(CameraAv::StreamUsage::Recording), CameraAv::AudioStreamAllocateResponse)
    second.audio_stream_id.should eq(1_u16)
    allocated_ids.should eq([0_u16, 1_u16])
    camera.allocated_audio_streams.size.should eq(2)
    read_tlv(camera, CameraAv::ATTR_ALLOCATED_AUDIO_STREAMS).as_list.size.should eq(2)
    expect_status(invoke(camera, CameraAv::CMD_AUDIO_STREAM_ALLOCATE,
      audio_request(CameraAv::StreamUsage::Internal)), CameraCode::ConstraintError)
    expect_status(invoke(camera, CameraAv::CMD_AUDIO_STREAM_ALLOCATE,
      CameraAv::AudioStreamAllocateRequest.new(CameraAv::StreamUsage::LiveView,
        CameraAv::AudioCodec::AacLc, 1_u8, 48_000_u32, 32_000_u32, 16_u8)), CameraCode::ConstraintError)
    expect_status(invoke(camera, CameraAv::CMD_AUDIO_STREAM_ALLOCATE,
      CameraAv::AudioStreamAllocateRequest.new(CameraAv::StreamUsage::LiveView,
        CameraAv::AudioCodec::Opus, 9_u8, 48_000_u32, 32_000_u32, 16_u8)), CameraCode::ConstraintError)
  end

  it "reuses an exact stream with reference counts and releases only at zero" do
    camera = camera_av(64_000_u32)
    admit_audio(camera)
    request = audio_request
    first = invoke_response(camera, CameraAv::CMD_AUDIO_STREAM_ALLOCATE, request, CameraAv::AudioStreamAllocateResponse)
    again = invoke_response(camera, CameraAv::CMD_AUDIO_STREAM_ALLOCATE, request, CameraAv::AudioStreamAllocateResponse)
    again.audio_stream_id.should eq(first.audio_stream_id)
    camera.allocated_audio_streams.first.reference_count.should eq(2_u8)
    expect_status(invoke(camera, CameraAv::CMD_AUDIO_STREAM_ALLOCATE,
      audio_request(CameraAv::StreamUsage::Recording)), CameraCode::ResourceExhausted)
    expect_success(invoke(camera, CameraAv::CMD_AUDIO_STREAM_DEALLOCATE,
      CameraAv::AudioStreamDeallocateRequest.new(first.audio_stream_id)))
    camera.allocated_audio_streams.first.reference_count.should eq(1_u8)
    expect_success(invoke(camera, CameraAv::CMD_AUDIO_STREAM_DEALLOCATE,
      CameraAv::AudioStreamDeallocateRequest.new(first.audio_stream_id)))
    camera.allocated_audio_streams.should be_empty
    expect_status(invoke(camera, CameraAv::CMD_AUDIO_STREAM_DEALLOCATE,
      CameraAv::AudioStreamDeallocateRequest.new(first.audio_stream_id)), CameraCode::NotFound)
    next_id = invoke_response(camera, CameraAv::CMD_AUDIO_STREAM_ALLOCATE, request, CameraAv::AudioStreamAllocateResponse)
    next_id.audio_stream_id.should eq(1_u16)
  end

  it "rejects host admission or release failures without corrupting allocation state" do
    camera = camera_av
    camera.on_audio_allocate { |_request, _id| CameraStatus.resource_exhausted }
    expect_status(invoke(camera, CameraAv::CMD_AUDIO_STREAM_ALLOCATE, audio_request), CameraCode::ResourceExhausted)
    camera.allocated_audio_streams.should be_empty
    admit_audio(camera)
    id = invoke_response(camera, CameraAv::CMD_AUDIO_STREAM_ALLOCATE, audio_request,
      CameraAv::AudioStreamAllocateResponse).audio_stream_id
    camera.on_audio_deallocate { |_id| CameraStatus.invalid_in_state }
    expect_status(invoke(camera, CameraAv::CMD_AUDIO_STREAM_DEALLOCATE,
      CameraAv::AudioStreamDeallocateRequest.new(id)), CameraCode::InvalidInState)
    camera.allocated_audio_streams.first.audio_stream_id.should eq(id)
  end

  it "wraps audio IDs after 65534" do
    camera = camera_av
    saved = camera.save_state.as(Matter::Storage::Document)
    saved["next_audio_stream_id"] = 65_534_i64
    camera.restore_state(saved)
    admit_audio(camera)
    first = invoke_response(camera, CameraAv::CMD_AUDIO_STREAM_ALLOCATE, audio_request,
      CameraAv::AudioStreamAllocateResponse)
    first.audio_stream_id.should eq(65_534_u16)
    second = invoke_response(camera, CameraAv::CMD_AUDIO_STREAM_ALLOCATE,
      audio_request(CameraAv::StreamUsage::Recording), CameraAv::AudioStreamAllocateResponse)
    second.audio_stream_id.should eq(0_u16)
  end

  it "requires no allocated streams when changing priorities and persists the chosen order" do
    camera = camera_av
    requested = CameraAv::SetStreamPrioritiesRequest.new([CameraAv::StreamUsage::Recording])
    expect_success(invoke(camera, CameraAv::CMD_SET_STREAM_PRIORITIES, requested))
    camera.stream_usage_priorities.should eq([CameraAv::StreamUsage::Recording])
    expect_status(invoke(camera, CameraAv::CMD_SET_STREAM_PRIORITIES,
      CameraAv::SetStreamPrioritiesRequest.new([CameraAv::StreamUsage::LiveView,
                                                CameraAv::StreamUsage::LiveView])), CameraCode::ConstraintError)
    admit_audio(camera)
    invoke_response(camera, CameraAv::CMD_AUDIO_STREAM_ALLOCATE, audio_request,
      CameraAv::AudioStreamAllocateResponse)
    expect_status(invoke(camera, CameraAv::CMD_SET_STREAM_PRIORITIES, requested), CameraCode::InvalidInState)
    saved = camera.save_state.as(Matter::Storage::Document)
    restored = camera_av
    restored.restore_state(saved)
    restored.stream_usage_priorities.should eq([CameraAv::StreamUsage::Recording])
    restored.allocated_audio_streams.should be_empty
    restored.microphone_volume_level.should eq(camera.microphone_volume_level)
    admit_audio(restored)
    resumed = invoke_response(restored, CameraAv::CMD_AUDIO_STREAM_ALLOCATE,
      audio_request, CameraAv::AudioStreamAllocateResponse)
    resumed.audio_stream_id.should eq(1_u16)
  end

  it "exposes privacy modes and host pause hooks only when enabled" do
    camera = camera_av(128_000_u32, CameraAv::Feature::Audio | CameraAv::Feature::Privacy)
    changes = [] of {Bool, Bool, Bool}
    camera.on_privacy_changed { |hard, recording, live| changes << {hard, recording, live}; nil }
    camera.stream_delivery_allowed?(CameraAv::StreamUsage::LiveView).should be_true
    expect_success(write(camera, CameraAv::ATTR_SOFT_LIVESTREAM_PRIVACY_MODE_ENABLED, true))
    camera.stream_delivery_allowed?(CameraAv::StreamUsage::LiveView).should be_false
    camera.stream_delivery_allowed?(CameraAv::StreamUsage::Recording).should be_true
    camera.hard_privacy_mode_on = true
    camera.stream_delivery_allowed?(CameraAv::StreamUsage::Recording).should be_false
    changes.should eq([{false, false, false}, {false, false, true}, {true, false, true}])
    saved = camera.save_state.as(Matter::Storage::Document)
    restored = camera_av(128_000_u32, CameraAv::Feature::Audio | CameraAv::Feature::Privacy)
    restored.restore_state(saved)
    restored.soft_livestream_privacy_mode_enabled?.should be_true
    restored.hard_privacy_mode_on?.should be_false
    resumed_privacy = [] of {Bool, Bool, Bool}
    restored.on_privacy_changed { |hard, recording, live| resumed_privacy << {hard, recording, live}; nil }
    resumed_privacy.should eq([{false, false, true}])
  end

  it "reports microphone mute and gain changes to the host" do
    camera = camera_av
    applied = [] of {Bool, UInt8}
    camera.on_microphone_settings_changed { |muted, volume| applied << {muted, volume}; nil }
    expect_success(write(camera, CameraAv::ATTR_MICROPHONE_MUTED, true))
    camera.stream_delivery_allowed?(CameraAv::StreamUsage::LiveView).should be_false
    expect_success(write(camera, CameraAv::ATTR_MICROPHONE_VOLUME_LEVEL, 60_u8))
    applied.should eq([{false, 50_u8}, {true, 50_u8}, {true, 60_u8}])
  end
end

private def video_camera(max_bandwidth = 2_000_000_u32, max_encoders = 1_u8)
  build(CameraAv,
    supported_stream_usages: [CameraAv::StreamUsage::LiveView, CameraAv::StreamUsage::Recording],
    max_content_buffer_size: 65_536_u32, max_network_bandwidth: max_bandwidth,
    video_sensor_params: CameraAv::VideoSensorParams.new(1920_u16, 1080_u16, 30_u16),
    min_viewport_resolution: CameraAv::VideoResolution.new(160_u16, 90_u16),
    rate_distortion_trade_off_points: [CameraAv::RateDistortionPoint.new(CameraAv::VideoCodec::H264,
      CameraAv::VideoResolution.new(640_u16, 360_u16), 200_000_u32)],
    max_concurrent_encoders: max_encoders, max_encoded_pixel_rate: 62_208_000_u32,
    feature_map: CameraAv::Feature::Video | CameraAv::Feature::Privacy)
end

private def video_request(usage = CameraAv::StreamUsage::LiveView, max_bit_rate = 1_000_000_u32)
  CameraAv::VideoStreamAllocateRequest.new(usage, CameraAv::VideoCodec::H264,
    15_u16, 30_u16, CameraAv::VideoResolution.new(320_u16, 180_u16),
    CameraAv::VideoResolution.new(1280_u16, 720_u16), 200_000_u32, max_bit_rate, 30_u16)
end

describe "Camera AV video feature" do
  it "advertises the exact VDO attributes and commands without ADO" do
    camera = video_camera
    read(camera, Matter::Cluster::Base::GLOBAL_FEATURE_MAP).should eq(10_u32)
    camera.attributes.map(&.id.id).should eq([
      CameraAv::ATTR_MAX_CONCURRENT_ENCODERS, CameraAv::ATTR_MAX_ENCODED_PIXEL_RATE,
      CameraAv::ATTR_VIDEO_SENSOR_PARAMS, CameraAv::ATTR_MIN_VIEWPORT_RESOLUTION,
      CameraAv::ATTR_RATE_DISTORTION_TRADE_OFF_POINTS, CameraAv::ATTR_MAX_CONTENT_BUFFER_SIZE,
      CameraAv::ATTR_MAX_NETWORK_BANDWIDTH, CameraAv::ATTR_CURRENT_FRAME_RATE,
      CameraAv::ATTR_SUPPORTED_STREAM_USAGES, CameraAv::ATTR_ALLOCATED_VIDEO_STREAMS,
      CameraAv::ATTR_STREAM_USAGE_PRIORITIES, CameraAv::ATTR_SOFT_RECORDING_PRIVACY_MODE_ENABLED,
      CameraAv::ATTR_SOFT_LIVESTREAM_PRIVACY_MODE_ENABLED, CameraAv::ATTR_HARD_PRIVACY_MODE_ON,
      CameraAv::ATTR_VIEWPORT,
    ])
    camera.commands.map(&.id.id).should eq([
      CameraAv::CMD_VIDEO_STREAM_ALLOCATE, CameraAv::CMD_VIDEO_STREAM_DEALLOCATE,
      CameraAv::CMD_SET_STREAM_PRIORITIES,
    ])
    read_tlv(camera, CameraAv::ATTR_VIDEO_SENSOR_PARAMS).as_structure.keys.should eq([0_u8, 1_u8, 2_u8])
    read_tlv(camera, CameraAv::ATTR_VIEWPORT).as_structure.keys.should eq([0_u8, 1_u8, 2_u8, 3_u8])
    camera.current_frame_rate = 24_u16
    read(camera, CameraAv::ATTR_CURRENT_FRAME_RATE).should eq(24_u16)
    expect_status(read_status(camera, CameraAv::ATTR_MICROPHONE_CAPABILITIES), CameraCode::UnsupportedAttribute)
  end

  it "validates video capabilities before advertising them" do
    expect_raises(ArgumentError) { CameraAv::VideoSensorParams.new(63_u16, 1080_u16, 30_u16) }
    expect_raises(ArgumentError) { CameraAv::VideoResolution.new(0_u16, 720_u16) }
    expect_raises(ArgumentError) do
      CameraAv::RateDistortionPoint.new(CameraAv::VideoCodec::H264,
        CameraAv::VideoResolution.new(640_u16, 360_u16), 0_u32)
    end
    expect_raises(ArgumentError) do
      CameraAv::RateDistortionPoint.new(CameraAv::VideoCodec.new(9_u8),
        CameraAv::VideoResolution.new(640_u16, 360_u16), 200_000_u32)
    end
    camera = video_camera
    camera.rate_distortion_trade_off_points.clear
    camera.rate_distortion_trade_off_points.size.should eq(1)
  end

  it "allocates, reuses and releases video streams with host callbacks" do
    camera = video_camera
    expect_status(invoke(camera, CameraAv::CMD_VIDEO_STREAM_ALLOCATE, video_request), CameraCode::InvalidInState)
    admitted = [] of UInt16
    released = [] of UInt16
    camera.on_video_allocate { |_request, id| admitted << id; CameraStatus.success }
    camera.on_video_deallocate { |id| released << id; CameraStatus.success }
    id = invoke_response(camera, CameraAv::CMD_VIDEO_STREAM_ALLOCATE, video_request,
      CameraAv::VideoStreamAllocateResponse).video_stream_id
    id.should eq(0_u16)
    invoke_response(camera, CameraAv::CMD_VIDEO_STREAM_ALLOCATE, video_request,
      CameraAv::VideoStreamAllocateResponse).video_stream_id.should eq(id)
    admitted.should eq([id])
    camera.allocated_video_streams.first.reference_count.should eq(2_u8)
    read_tlv(camera, CameraAv::ATTR_ALLOCATED_VIDEO_STREAMS).as_list.first.as_structure.keys.should eq([
      0_u8, 1_u8, 2_u8, 3_u8, 4_u8, 5_u8, 6_u8, 7_u8, 8_u8, 9_u8, 12_u8,
    ])
    expect_status(invoke(camera, CameraAv::CMD_VIDEO_STREAM_ALLOCATE,
      video_request(CameraAv::StreamUsage::Recording)), CameraCode::ResourceExhausted)
    expect_success(invoke(camera, CameraAv::CMD_VIDEO_STREAM_DEALLOCATE,
      CameraAv::VideoStreamDeallocateRequest.new(id)))
    released.should be_empty
    expect_success(invoke(camera, CameraAv::CMD_VIDEO_STREAM_DEALLOCATE,
      CameraAv::VideoStreamDeallocateRequest.new(id)))
    released.should eq([id])
    camera.allocated_video_streams.should be_empty
    expect_status(invoke(camera, CameraAv::CMD_VIDEO_STREAM_DEALLOCATE,
      CameraAv::VideoStreamDeallocateRequest.new(id)), CameraCode::NotFound)
  end

  it "rejects invalid video negotiation and preserves state on host veto" do
    camera = video_camera
    camera.on_video_allocate { |_request, _id| CameraStatus.resource_exhausted }
    expect_status(invoke(camera, CameraAv::CMD_VIDEO_STREAM_ALLOCATE, video_request), CameraCode::ResourceExhausted)
    camera.allocated_video_streams.should be_empty
    expect_status(invoke(camera, CameraAv::CMD_VIDEO_STREAM_ALLOCATE,
      video_request(CameraAv::StreamUsage::Internal)), CameraCode::ConstraintError)
    bad = CameraAv::VideoStreamAllocateRequest.new(CameraAv::StreamUsage::LiveView, CameraAv::VideoCodec::H264,
      31_u16, 30_u16, CameraAv::VideoResolution.new(320_u16, 180_u16),
      CameraAv::VideoResolution.new(1280_u16, 720_u16), 200_000_u32, 1_000_000_u32, 30_u16)
    expect_status(invoke(camera, CameraAv::CMD_VIDEO_STREAM_ALLOCATE, bad), CameraCode::ConstraintError)
    camera.on_video_allocate { |_request, _id| CameraStatus.success }
    id = invoke_response(camera, CameraAv::CMD_VIDEO_STREAM_ALLOCATE, video_request,
      CameraAv::VideoStreamAllocateResponse).video_stream_id
    camera.on_video_deallocate { |_id| CameraStatus.invalid_in_state }
    expect_status(invoke(camera, CameraAv::CMD_VIDEO_STREAM_DEALLOCATE,
      CameraAv::VideoStreamDeallocateRequest.new(id)), CameraCode::InvalidInState)
    camera.allocated_video_streams.first.video_stream_id.should eq(id)
  end

  it "applies privacy to video without coupling it to microphone mute" do
    camera = video_camera
    camera.video_delivery_allowed?(CameraAv::StreamUsage::LiveView).should be_true
    expect_success(write(camera, CameraAv::ATTR_SOFT_LIVESTREAM_PRIVACY_MODE_ENABLED, true))
    camera.video_delivery_allowed?(CameraAv::StreamUsage::LiveView).should be_false
    camera.video_delivery_allowed?(CameraAv::StreamUsage::Recording).should be_true
    camera.hard_privacy_mode_on = true
    camera.video_delivery_allowed?(CameraAv::StreamUsage::Recording).should be_false
  end

  it "validates and persists a writable video viewport" do
    camera = video_camera
    camera.viewport.should eq(CameraAv::Viewport.new(0_u16, 0_u16, 1920_u16, 1080_u16))
    expect_status(write(camera, CameraAv::ATTR_VIEWPORT,
      CameraAv::Viewport.new(0_u16, 0_u16, 100_u16, 100_u16)), CameraCode::ConstraintError)
    expect_status(write(camera, CameraAv::ATTR_VIEWPORT,
      CameraAv::Viewport.new(0_u16, 0_u16, 1921_u16, 1080_u16)), CameraCode::ConstraintError)
    updated = CameraAv::Viewport.new(20_u16, 10_u16, 660_u16, 370_u16)
    expect_success(write(camera, CameraAv::ATTR_VIEWPORT, updated))
    camera.viewport.should eq(updated)
    saved = camera.save_state.as(Matter::Storage::Document)
    restored = video_camera
    restored.restore_state(saved)
    restored.viewport.should eq(updated)
  end

  it "reserves shared bandwidth and resets live allocations after restart" do
    camera = video_camera
    camera.on_video_allocate { |_request, _id| CameraStatus.success }
    camera.on_video_deallocate { |_id| CameraStatus.success }
    id = invoke_response(camera, CameraAv::CMD_VIDEO_STREAM_ALLOCATE, video_request,
      CameraAv::VideoStreamAllocateResponse).video_stream_id
    expect_status(invoke(camera, CameraAv::CMD_SET_STREAM_PRIORITIES,
      CameraAv::SetStreamPrioritiesRequest.new([CameraAv::StreamUsage::Recording])), CameraCode::InvalidInState)
    saved = camera.save_state.as(Matter::Storage::Document)
    restored = video_camera
    restored.restore_state(saved)
    restored.allocated_video_streams.should be_empty
    restored.on_video_allocate { |_request, _id| CameraStatus.success }
    next_id = invoke_response(restored, CameraAv::CMD_VIDEO_STREAM_ALLOCATE, video_request,
      CameraAv::VideoStreamAllocateResponse).video_stream_id
    next_id.should eq(id + 1_u16)
  end
end

private def combined_camera
  build(CameraAv,
    microphone_capabilities: camera_capabilities,
    supported_stream_usages: [CameraAv::StreamUsage::LiveView, CameraAv::StreamUsage::Recording],
    max_content_buffer_size: 65_536_u32, max_network_bandwidth: 1_000_000_u32,
    video_sensor_params: CameraAv::VideoSensorParams.new(1920_u16, 1080_u16, 30_u16),
    min_viewport_resolution: CameraAv::VideoResolution.new(160_u16, 90_u16),
    rate_distortion_trade_off_points: [CameraAv::RateDistortionPoint.new(CameraAv::VideoCodec::H264,
      CameraAv::VideoResolution.new(640_u16, 360_u16), 200_000_u32)],
    max_concurrent_encoders: 1_u8, max_encoded_pixel_rate: 62_208_000_u32,
    feature_map: CameraAv::Feature::Audio | CameraAv::Feature::Video)
end

describe "Camera AV shared audio/video resources" do
  it "counts audio and video against one network bandwidth budget" do
    camera = combined_camera
    admit_audio(camera)
    camera.on_video_allocate { |_request, _id| CameraStatus.success }
    camera.on_video_deallocate { |_id| CameraStatus.success }
    invoke_response(camera, CameraAv::CMD_AUDIO_STREAM_ALLOCATE, audio_request,
      CameraAv::AudioStreamAllocateResponse)
    expect_status(invoke(camera, CameraAv::CMD_VIDEO_STREAM_ALLOCATE,
      video_request(CameraAv::StreamUsage::LiveView, 1_000_000_u32)), CameraCode::ResourceExhausted)
    id = invoke_response(camera, CameraAv::CMD_VIDEO_STREAM_ALLOCATE,
      video_request(CameraAv::StreamUsage::LiveView, 900_000_u32), CameraAv::VideoStreamAllocateResponse).video_stream_id
    expect_status(invoke(camera, CameraAv::CMD_AUDIO_STREAM_ALLOCATE,
      audio_request(CameraAv::StreamUsage::Recording)), CameraCode::ResourceExhausted)
    expect_success(invoke(camera, CameraAv::CMD_VIDEO_STREAM_DEALLOCATE,
      CameraAv::VideoStreamDeallocateRequest.new(id)))
  end
end
