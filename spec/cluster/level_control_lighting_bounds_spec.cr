require "../spec_helper"

private alias Level = Matter::Cluster::LevelControl

describe "LevelControl lighting bounds" do
  it "starts a lighting cluster within the Matter 1.6 level range" do
    cluster = build(Level)
    cluster.feature_map.lighting?.should be_true
    cluster.min_level.should eq(1_u8)
    cluster.max_level.should eq(254_u8)
    cluster.current_level.should eq(1_u8)
    read(cluster, Level::ATTR_MIN_LEVEL).should eq(1_u8)
    read(cluster, Level::ATTR_MAX_LEVEL).should eq(254_u8)
  end

  it "rejects lighting bounds outside the fixed range" do
    expect_raises(ArgumentError) { build(Level, min_level: 0_u8) }
    expect_raises(ArgumentError) { build(Level, max_level: 253_u8) }
    expect_raises(ArgumentError) { build(Level, current_level: 0_u8) }
  end

  it "retains configurable non-lighting bounds including zero" do
    cluster = build(Level, feature_map: Level::Feature::None,
      current_level: 0_u8, min_level: 0_u8, max_level: 200_u8)
    cluster.min_level.should eq(0_u8)
    cluster.max_level.should eq(200_u8)
    cluster.current_level.should eq(0_u8)
  end

  it "rejects a non-lighting maximum above the Matter level ceiling" do
    expect_raises(ArgumentError) do
      build(Level, feature_map: Level::Feature::None, max_level: 255_u8)
    end
  end
end
