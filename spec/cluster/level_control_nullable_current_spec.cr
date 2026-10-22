require "../spec_helper"

private alias NullableLevel = Matter::Cluster::LevelControl

private def level_with_unknown_current : NullableLevel
  cluster = build(NullableLevel)
  stored = cluster.save_state.as(Matter::Storage::Document)
  stored["current_level"] = nil
  cluster.restore_state(stored)
  cluster
end

describe "LevelControl nullable CurrentLevel" do
  it "declares CurrentLevel as a scene attribute" do
    metadata = build(NullableLevel).get_attribute_metadata(NullableLevel::ATTR_CURRENT_LEVEL)
    metadata.should_not be_nil
    metadata.as(Matter::Cluster::AttributeMetadata).scene?.should be_true
  end

  it "restores and reports an unknown current level as TLV null" do
    cluster = level_with_unknown_current
    cluster.current_level.should be_nil
    read_tlv(cluster, NullableLevel::ATTR_CURRENT_LEVEL).value.should be_nil
    saved = cluster.save_state.as(Matter::Storage::Document)
    saved.has_key?("current_level").should be_false
    restarted = build(NullableLevel)
    restarted.restore_state(saved)
    restarted.current_level.should be_nil
    read_tlv(restarted, NullableLevel::ATTR_CURRENT_LEVEL).value.should be_nil
  end

  it "persists a level that becomes unknown and restores it after restart" do
    cluster = build(NullableLevel)
    cluster.current_level = nil
    saved = cluster.save_state.as(Matter::Storage::Document)
    saved.has_key?("current_level").should be_false

    restarted = build(NullableLevel)
    restarted.restore_state(saved)
    restarted.current_level.should be_nil
    read_tlv(restarted, NullableLevel::ATTR_CURRENT_LEVEL).value.should be_nil
  end

  it "moves immediately to a known target when CurrentLevel is null" do
    cluster = level_with_unknown_current
    request = NullableLevel::MoveToLevelRequest.new(100_u8, 10_u16, 0_u8, 0_u8)
    expect_success(invoke(cluster, NullableLevel::CMD_MOVE_TO_LEVEL, request))
    cluster.current_level.should eq(100_u8)
    cluster.remaining_time.should eq(0_u16)
  end

  it "keeps the numeric callback safe across an unknown level" do
    cluster = build(NullableLevel)
    changes = [] of Tuple(UInt8, UInt8)
    cluster.on_level_changed { |old_level, new_level| changes << {old_level, new_level} }
    cluster.current_level = nil
    expect_success(invoke(cluster, NullableLevel::CMD_MOVE_TO_LEVEL,
      NullableLevel::MoveToLevelRequest.new(100_u8, 0_u16, 0_u8, 0_u8)))
    changes.should be_empty
    expect_success(invoke(cluster, NullableLevel::CMD_MOVE_TO_LEVEL,
      NullableLevel::MoveToLevelRequest.new(110_u8, 0_u16, 0_u8, 0_u8)))
    changes.should eq([{100_u8, 110_u8}])
  end

  it "returns Failure for relative Move and Step without a known level" do
    cluster = level_with_unknown_current
    move = NullableLevel::MoveRequest.new(NullableLevel::MoveMode::Up, 10_u8, 0_u8, 0_u8)
    step = NullableLevel::StepRequest.new(NullableLevel::StepMode::Up, 10_u8, 0_u16, 0_u8, 0_u8)
    expect_status(invoke(cluster, NullableLevel::CMD_MOVE, move), Matter::InteractionModel::StatusCode::Failure)
    expect_status(invoke(cluster, NullableLevel::CMD_STEP, step), Matter::InteractionModel::StatusCode::Failure)
    cluster.current_level.should be_nil
  end

  it "does not resume an old transition after the level becomes unknown" do
    cluster = build(NullableLevel)
    expect_success(invoke(cluster, NullableLevel::CMD_MOVE_TO_LEVEL,
      NullableLevel::MoveToLevelRequest.new(200_u8, 100_u16, 0_u8, 0_u8)))
    cluster.current_level = nil
    cluster.remaining_time.should eq(0_u16)

    step = NullableLevel::StepRequest.new(NullableLevel::StepMode::Up, 5_u8, 10_u16, 0_u8, 0_u8)
    expect_status(invoke(cluster, NullableLevel::CMD_STEP, step), Matter::InteractionModel::StatusCode::Failure)
    cluster.current_level.should be_nil

    expect_success(invoke(cluster, NullableLevel::CMD_MOVE_TO_LEVEL,
      NullableLevel::MoveToLevelRequest.new(100_u8, 10_u16, 0_u8, 0_u8)))
    cluster.current_level.should eq(100_u8)
    cluster.remaining_time.should eq(0_u16)
  end
end

describe "LevelControl optional rate constraint" do
  it "rejects zero DefaultMoveRate while allowing null" do
    cluster = build(NullableLevel)
    expect_status(write(cluster, NullableLevel::ATTR_DEFAULT_MOVE_RATE, 0_u8),
      Matter::InteractionModel::StatusCode::ConstraintError)
    cluster.default_move_rate.should be_nil
    expect_success(write(cluster, NullableLevel::ATTR_DEFAULT_MOVE_RATE, 1_u8))
    expect_success(write(cluster, NullableLevel::ATTR_DEFAULT_MOVE_RATE, nil))
  end
end
