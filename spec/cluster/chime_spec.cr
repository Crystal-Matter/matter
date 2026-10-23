require "../spec_helper"

private alias Chime = Matter::Cluster::Chime
private alias ChimeCode = Matter::InteractionModel::StatusCode
private alias ChimeStatus = Matter::InteractionModel::Status

private def chime_sounds
  [Chime::Sound.new(1_u8, "Classic"), Chime::Sound.new(2_u8, "Modern")]
end

private def chime
  build(Chime, sounds: chime_sounds, selected_chime: 1_u8)
end

describe Chime do
  it "advertises revision two, attributes, command, and started event" do
    cluster = chime
    cluster.cluster_id.id.should eq(0x0556_u32)
    cluster.cluster_revision.should eq(2_u16)
    cluster.attributes.map(&.id.id).should eq([
      Chime::ATTR_INSTALLED_CHIME_SOUNDS, Chime::ATTR_SELECTED_CHIME, Chime::ATTR_ENABLED,
    ])
    cluster.commands.map(&.id.id).should eq([Chime::CMD_PLAY_CHIME_SOUND])
    cluster.events.map(&.id.id).should eq([Chime::EVENT_CHIME_STARTED_PLAYING])
    read(cluster, Chime::ATTR_SELECTED_CHIME).should eq(1_u8)
    read(cluster, Chime::ATTR_ENABLED).should be_true
    read_tlv(cluster, Chime::ATTR_INSTALLED_CHIME_SOUNDS).as_list.size.should eq(2)
  end

  it "validates installed sounds and keeps the selected ID present" do
    expect_raises(ArgumentError) { build(Chime, sounds: [] of Chime::Sound, selected_chime: 1_u8) }
    expect_raises(ArgumentError) { build(Chime, sounds: chime_sounds, selected_chime: 3_u8) }
    expect_raises(ArgumentError) { Chime::Sound.new(1_u8, "") }
    expect_raises(ArgumentError) { Chime::Sound.new(1_u8, "x" * 49) }
    expect_raises(ArgumentError) do
      build(Chime, sounds: [Chime::Sound.new(1_u8, "Classic"), Chime::Sound.new(1_u8, "Other")], selected_chime: 1_u8)
    end
    expect_raises(ArgumentError) do
      build(Chime, sounds: [Chime::Sound.new(1_u8, "Classic"), Chime::Sound.new(2_u8, "Classic")], selected_chime: 1_u8)
    end
    cluster = chime
    expect_raises(ArgumentError) { cluster.installed_chime_sounds = [Chime::Sound.new(2_u8, "Modern")] }
  end

  it "returns NotFound on an unknown SelectedChime write and persists valid settings" do
    cluster = chime
    expect_status(write(cluster, Chime::ATTR_SELECTED_CHIME, 3_u8), ChimeCode::NotFound)
    expect_success(write(cluster, Chime::ATTR_SELECTED_CHIME, 2_u8))
    expect_success(write(cluster, Chime::ATTR_ENABLED, false))
    saved = cluster.save_state.as(Matter::Storage::Document)
    restored = chime
    restored.restore_state(saved)
    restored.selected_chime.should eq(2_u8)
    restored.enabled?.should be_false
  end

  it "falls back to a current installed sound when the persisted selection was removed" do
    previous = chime
    previous.selected_chime = 2_u8
    previous.enabled = false
    saved = previous.save_state.as(Matter::Storage::Document)

    restored = build(Chime, sounds: [Chime::Sound.new(4_u8, "New"), Chime::Sound.new(5_u8, "Other")], selected_chime: 5_u8)
    restored.restore_state(saved)

    restored.installed_chime_sounds.map(&.chime_id).should eq([4_u8, 5_u8])
    restored.selected_chime.should eq(4_u8)
    restored.enabled?.should be_false
  end

  it "plays selected or explicitly requested sounds and emits ChimeStartedPlaying" do
    node = Matter::Node.new
    endpoint1 = Matter::Endpoint.new(endpoint(1))
    cluster = chime
    endpoint1.add_cluster(cluster)
    node.add_endpoint(endpoint1)
    played = [] of UInt8
    cluster.on_play { |id| played << id; ChimeStatus.success }

    expect_success(invoke(cluster, Chime::CMD_PLAY_CHIME_SOUND, Chime::PlayRequest.new))
    expect_success(invoke(cluster, Chime::CMD_PLAY_CHIME_SOUND, Chime::PlayRequest.new(2_u8)))
    played.should eq([1_u8, 2_u8])
    events = node.event_journal.query([Matter::InteractionModel::EventPath.new(
      cluster: Chime::CLUSTER_ID, event: Chime::EVENT_CHIME_STARTED_PLAYING)])
    events.map { |event| Chime::StartedPlayingEvent.from_tlv(event.data).chime_id }.should eq([1_u8, 2_u8])
  end

  it "does not play disabled, absent-host, or unknown sounds" do
    cluster = chime
    expect_status(invoke(cluster, Chime::CMD_PLAY_CHIME_SOUND, Chime::PlayRequest.new), ChimeCode::InvalidInState)
    calls = 0
    cluster.on_play { |_id| calls += 1; ChimeStatus.failure }
    expect_status(invoke(cluster, Chime::CMD_PLAY_CHIME_SOUND, Chime::PlayRequest.new(2_u8)), ChimeCode::Failure)
    cluster.enabled = false
    expect_status(invoke(cluster, Chime::CMD_PLAY_CHIME_SOUND, Chime::PlayRequest.new), ChimeCode::InvalidInState)
    cluster.enabled = true
    expect_status(invoke(cluster, Chime::CMD_PLAY_CHIME_SOUND, Chime::PlayRequest.new(3_u8)), ChimeCode::NotFound)
    calls.should eq(1)
  end

  it "encodes optional PlayChimeSound ID and ChimeStartedPlaying event fields" do
    Chime::PlayRequest.new.to_tlv(nil).as_structure.should be_empty
    Chime::PlayRequest.new(2_u8).to_tlv(nil).as_structure.keys.should eq([0_u8])
    Chime::StartedPlayingEvent.new(2_u8).to_tlv(nil).as_structure.keys.should eq([0_u8])
  end
end
