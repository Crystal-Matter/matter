require "../spec_helper"

private alias Playback = Matter::Cluster::MediaPlayback
private alias PlaybackCode = Matter::InteractionModel::StatusCode

private def playback_response(cluster : Playback, command : UInt32, request = nil) : Playback::PlaybackResponse
  response = invoke(cluster, command, request).as(Matter::Cluster::CommandResponse)
  response.command_id.should eq(Playback::CMD_PLAYBACK_RESPONSE)
  Playback::PlaybackResponse.from_tlv(response.response.as(TLV::Any))
end

describe Matter::Cluster::MediaPlayback do
  it "validates seek bounds and never calls the host for out-of-range positions" do
    cluster = build(Playback, feature_map: Playback::Feature::AdvancedSeek)
    cluster.update_seek_range(10_u64, 100_u64, 100_u64)
    calls = [] of Playback::Operation
    cluster.on_command do |_command, operation|
      calls << operation
      Playback::PlaybackStatus::Success
    end
    playback_response(cluster, Playback::CMD_SEEK, Playback::SeekRequest.new(9_u64)).status.should eq(Playback::PlaybackStatus::SeekOutOfRange)
    playback_response(cluster, Playback::CMD_SEEK, Playback::SeekRequest.new(101_u64)).status.should eq(Playback::PlaybackStatus::SeekOutOfRange)
    calls.should be_empty
    playback_response(cluster, Playback::CMD_SEEK, Playback::SeekRequest.new(50_u64)).status.should eq(Playback::PlaybackStatus::Success)
    calls.last.position.should eq(50_u64)
    expect_raises(ArgumentError, /SeekRangeStart/) { cluster.update_seek_range(101_u64, 100_u64) }
  end

  it "publishes typed tracks and changes active tracks only after host approval" do
    features = Playback::Feature::AudioTracks | Playback::Feature::TextTracks
    cluster = build(Playback, feature_map: features)
    english = Playback::Track.new("eng", Playback::TrackAttributes.new("en", [Playback::Characteristic::MainProgram], "English"))
    french = Playback::Track.new("fra", Playback::TrackAttributes.new("fr"))
    cluster.update_audio_tracks([english, french], english)
    cluster.update_text_tracks([english, french])
    cluster.report_state(Playback::PlaybackState::Playing)
    expect_status(invoke(cluster, Playback::CMD_ACTIVATE_AUDIO_TRACK,
      Playback::ActivateAudioTrackRequest.new("unknown")), PlaybackCode::InvalidCommand)
    read_tlv(cluster, Playback::ATTR_ACTIVE_AUDIO_TRACK).should_not be_nil
    expect_status(invoke(cluster, Playback::CMD_ACTIVATE_AUDIO_TRACK,
      Playback::ActivateAudioTrackRequest.new("fra")), PlaybackCode::Failure)
    Playback::Track.from_tlv(read_tlv(cluster, Playback::ATTR_ACTIVE_AUDIO_TRACK)).id.should eq("eng")
    cluster.on_command { |_command, _operation| Playback::PlaybackStatus::Success }
    expect_status(invoke(cluster, Playback::CMD_ACTIVATE_AUDIO_TRACK,
      Playback::ActivateAudioTrackRequest.new("fra")), PlaybackCode::Success)
    Playback::Track.from_tlv(read_tlv(cluster, Playback::ATTR_ACTIVE_AUDIO_TRACK)).id.should eq("fra")
    expect_status(invoke(cluster, Playback::CMD_ACTIVATE_TEXT_TRACK,
      Playback::ActivateTextTrackRequest.new("eng")), PlaybackCode::Success)
    Playback::Track.from_tlv(read_tlv(cluster, Playback::ATTR_ACTIVE_TEXT_TRACK)).id.should eq("eng")
    expect_status(invoke(cluster, Playback::CMD_DEACTIVATE_TEXT_TRACK), PlaybackCode::Success)
    read(cluster, Playback::ATTR_ACTIVE_TEXT_TRACK).should be_nil
    expect_raises(ArgumentError, /duplicate/) { cluster.update_audio_tracks([english, english]) }
    expect_raises(ArgumentError, /absent/) { cluster.update_audio_tracks([english], french) }
  end

  it "omits feature-gated StateChanged fields when those features are disabled" do
    cluster = build(Playback)
    events = [] of TLV::Any
    cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, event : UInt32, _priority : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) do
      event.should eq(Playback::EVENT_STATE_CHANGED)
      events << data
      nil
    end
    cluster.report_state(Playback::PlaybackState::Buffering)
    events.last.as_structure.keys.should eq([0_u8])
    payload = Playback::StateChangedEvent.from_tlv(events.last)
    payload.current_state.should eq(Playback::PlaybackState::Buffering)
    payload.start_time.should be_nil
    payload.duration.should be_nil
    payload.sampled_position.should be_nil
    payload.audio_advance_unmuted?.should be_nil
    events.size.should eq(1)
    cluster.current_state = Playback::PlaybackState::Paused
    events.size.should eq(2)
  end

  it "includes AdvancedSeek fields and AudioAdvanceUnmuted only with their features" do
    cluster = build(Playback, feature_map: Playback::Feature::AdvancedSeek)
    events = [] of TLV::Any
    cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, _event : UInt32, _priority : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) do
      events << data
      nil
    end
    cluster.report_state(Playback::PlaybackState::Playing)
    events.last.as_structure.keys.should eq([0_u8, 1_u8, 2_u8, 3_u8, 4_u8, 5_u8, 6_u8])
    cluster_with_aa = build(Playback, feature_map: Playback::Feature::AdvancedSeek | Playback::Feature::VariableSpeed | Playback::Feature::AudioAdvance)
    cluster_with_aa.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, _event : UInt32, _priority : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) do
      events << data
      nil
    end
    cluster_with_aa.report_state(Playback::PlaybackState::Playing, audio_advance_unmuted: true)
    events.last.as_structure.keys.should eq([0_u8, 1_u8, 2_u8, 3_u8, 4_u8, 5_u8, 6_u8, 8_u8])
  end

  it "rejects invalid duration and impossible reported speed without changing state" do
    cluster = build(Playback, feature_map: Playback::Feature::AdvancedSeek)
    expect_raises(ArgumentError, /Duration/) { cluster.update_seek_range(0_u64, 100_u64, 0_u64) }
    expect_raises(ArgumentError, /speed/) do
      cluster.report_state(Playback::PlaybackState::Paused, speed: 1_f32)
    end
    read(cluster, Playback::ATTR_CURRENT_STATE).should eq(Playback::PlaybackState::NotPlaying.value)
    expect_raises(ArgumentError, /900 bytes/) do
      cluster.report_state(Playback::PlaybackState::Playing, event_data: Bytes.new(901))
    end
    read(cluster, Playback::ATTR_CURRENT_STATE).should eq(Playback::PlaybackState::NotPlaying.value)
  end

  it "validates optional commands, audio advance and track length" do
    expect_raises(ArgumentError, /AudioAdvance/) do
      build(Playback, feature_map: Playback::Feature::AudioAdvance)
    end
    expect_raises(ArgumentError, /optional/) do
      build(Playback, optional_commands: [Playback::Command::Play])
    end
    cluster = build(Playback, feature_map: Playback::Feature::VariableSpeed,
      optional_commands: [Playback::Command::Next])
    accepted_command_ids(cluster).should contain(Playback::CMD_NEXT)
    playback_response(cluster, Playback::CMD_FAST_FORWARD,
      Playback::AdvanceRequest.new(true)).status.should eq(Playback::PlaybackStatus::NotAllowed)
    expect_raises(ArgumentError, /track ID/) do
      Playback::Track.new("x" * 33, Playback::TrackAttributes.new("en"))
    end
  end
  it "advertises the revision-two mandatory playback schema and response" do
    cluster = build(Playback)
    cluster.cluster_id.id.should eq(0x0506_u32)
    cluster.cluster_revision.should eq(2_u16)
    attribute_ids(cluster).should contain(Playback::ATTR_CURRENT_STATE)
    attribute_ids(cluster).should_not contain(Playback::ATTR_START_TIME)
    accepted_command_ids(cluster).should eq([Playback::CMD_PLAY, Playback::CMD_PAUSE, Playback::CMD_STOP])
    generated_command_ids(cluster).should eq([Playback::CMD_PLAYBACK_RESPONSE])
    read(cluster, Playback::ATTR_CURRENT_STATE).should eq(Playback::PlaybackState::NotPlaying.value)
    expect_status(invoke(cluster, Playback::CMD_SEEK), PlaybackCode::UnsupportedCommand)
  end

  it "keeps playback changes behind the host callback" do
    cluster = build(Playback)
    playback_response(cluster, Playback::CMD_PLAY).status.should eq(Playback::PlaybackStatus::NotAllowed)
    cluster.on_command do |_command, _request|
      Playback::PlaybackStatus::Success
    end
    playback_response(cluster, Playback::CMD_PLAY).status.should eq(Playback::PlaybackStatus::Success)
    read(cluster, Playback::ATTR_CURRENT_STATE).should eq(Playback::PlaybackState::Playing.value)
    playback_response(cluster, Playback::CMD_PAUSE).status.should eq(Playback::PlaybackStatus::Success)
    read(cluster, Playback::ATTR_CURRENT_STATE).should eq(Playback::PlaybackState::Paused.value)
    playback_response(cluster, Playback::CMD_STOP).status.should eq(Playback::PlaybackStatus::Success)
    read(cluster, Playback::ATTR_CURRENT_STATE).should eq(Playback::PlaybackState::NotPlaying.value)
  end

  it "gates advanced seek, variable speed and tracks by features" do
    cluster = build(Playback, feature_map: Playback::Feature::AdvancedSeek | Playback::Feature::VariableSpeed |
                                           Playback::Feature::AudioTracks | Playback::Feature::TextTracks)
    attribute_ids(cluster).should contain(Playback::ATTR_SAMPLED_POSITION)
    attribute_ids(cluster).should contain(Playback::ATTR_AVAILABLE_AUDIO_TRACKS)
    attribute_ids(cluster).should contain(Playback::ATTR_AVAILABLE_TEXT_TRACKS)
    accepted_command_ids(cluster).should contain(Playback::CMD_SEEK)
    accepted_command_ids(cluster).should contain(Playback::CMD_FAST_FORWARD)
    accepted_command_ids(cluster).should contain(Playback::CMD_ACTIVATE_AUDIO_TRACK)
    accepted_command_ids(cluster).should contain(Playback::CMD_DEACTIVATE_TEXT_TRACK)
  end
end
