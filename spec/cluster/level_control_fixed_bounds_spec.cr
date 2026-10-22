require "../spec_helper"

private alias FixedBoundsLevel = Matter::Cluster::LevelControl

describe "LevelControl fixed bounds across restart" do
  it "does not persist configured MinLevel and MaxLevel as mutable runtime state" do
    level = build(FixedBoundsLevel,
      current_level: 50_u8, min_level: 10_u8, max_level: 200_u8,
      feature_map: FixedBoundsLevel::Feature::None)

    saved = level.save_state.as(Matter::Storage::Document)
    saved.has_key?("min_level").should be_false
    saved.has_key?("max_level").should be_false
    saved["current_level"].should eq(50_i64)
  end

  it "keeps new fixed bounds instead of legacy stored bounds and clamps CurrentLevel" do
    previous = build(FixedBoundsLevel,
      current_level: 150_u8, min_level: 5_u8, max_level: 200_u8,
      feature_map: FixedBoundsLevel::Feature::None)
    saved = previous.save_state.as(Matter::Storage::Document)
    saved["min_level"] = 5_i64
    saved["max_level"] = 200_i64

    restarted = build(FixedBoundsLevel,
      current_level: 30_u8, min_level: 10_u8, max_level: 100_u8,
      feature_map: FixedBoundsLevel::Feature::None)
    restarted.restore_state(saved)

    restarted.min_level.should eq(10_u8)
    restarted.max_level.should eq(100_u8)
    restarted.current_level.should eq(100_u8)
    read(restarted, FixedBoundsLevel::ATTR_MIN_LEVEL).should eq(10_u8)
    read(restarted, FixedBoundsLevel::ATTR_MAX_LEVEL).should eq(100_u8)
  end
end
