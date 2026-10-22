require "../spec_helper"

private alias LevelRev7 = Matter::Cluster::LevelControl

describe "Level Control revision 7 conformance slice" do
  it "requires Operate and Manage for the XML-defined writable attributes" do
    level = build(LevelRev7)
    operate_ids = [LevelRev7::ATTR_OPTIONS, LevelRev7::ATTR_ON_OFF_TRANSITION_TIME,
                   LevelRev7::ATTR_ON_LEVEL, LevelRev7::ATTR_ON_TRANSITION_TIME,
                   LevelRev7::ATTR_OFF_TRANSITION_TIME, LevelRev7::ATTR_DEFAULT_MOVE_RATE]
    operate_ids.each do |id|
      level.attributes.find!(&.id.id.==(id)).write_access.should eq(Matter::InteractionModel::EntryPrivilege::Operate)
    end
    level.attributes.find!(&.id.id.==(LevelRev7::ATTR_START_UP_CURRENT_LEVEL)).write_access
      .should eq(Matter::InteractionModel::EntryPrivilege::Manage)
  end

  it "persists only CurrentLevel and StartUpCurrentLevel under the revision 7 quality flags" do
    level = build(LevelRev7, feature_map: LevelRev7::Feature::OnOff | LevelRev7::Feature::Lighting | LevelRev7::Feature::Frequency)
    level.current_level = 100_u8
    level.current_frequency = 120_u16
    level.min_frequency = 100_u16
    level.max_frequency = 200_u16
    level.options = 1_u8
    level.on_off_transition_time = 5_u16
    level.on_level = 40_u8
    level.on_transition_time = 5_u16
    level.off_transition_time = 5_u16
    level.default_move_rate = 10_u8
    level.start_up_current_level = 55_u8

    saved = level.save_state.as(Matter::Storage::Document)
    saved.keys.sort!.should eq(%w[current_level data_version features start_up_current_level])

    restored = build(LevelRev7, feature_map: level.feature_map)
    restored.restore_state(saved)
    restored.current_level.should eq(100_u8)
    restored.start_up_current_level.should eq(55_u8)
    restored.on_level.should be_nil
    restored.options.should eq(0_u8)
    restored.current_frequency.should eq(0_u16)
  end

  it "exposes all eight mandatory commands without the optional OnOff feature" do
    level = build(LevelRev7, feature_map: LevelRev7::Feature::None)
    level.commands.map(&.id.id).should eq((0_u32..7_u32).to_a)
    request = LevelRev7::MoveToLevelWithOnOffRequest.new(42_u8, 0_u16, 0_u8, 0_u8)
    expect_success(invoke(level, LevelRev7::CMD_MOVE_TO_LEVEL_WITH_ON_OFF, request))
    level.current_level.should eq(42_u8)
  end

  it "exposes Frequency CurrentFrequency as a scene attribute" do
    level = build(LevelRev7, feature_map: LevelRev7::Feature::Frequency)
    level.attributes.find!(&.id.id.==(LevelRev7::ATTR_CURRENT_FREQUENCY)).scene?.should be_true
  end

  it "rejects a host CurrentLevel update outside configured bounds before changing state" do
    level = build(LevelRev7, feature_map: LevelRev7::Feature::None,
      min_level: 10_u8, max_level: 200_u8, current_level: 100_u8)
    initial_version = level.data_version
    expect_raises(ArgumentError) { level.current_level = 201_u8 }
    expect_raises(ArgumentError) { level.current_level = 9_u8 }
    level.current_level.should eq(100_u8)
    level.data_version.should eq(initial_version)
    level.current_level = nil
    level.current_level.should be_nil
  end
end
