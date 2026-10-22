require "../spec_helper"
require "../../src/matter/cluster/window_covering"

alias Covering = Matter::Cluster::WindowCovering

describe "Window Covering Matter 1.6 state and feature composition" do
  it "does not advertise the removed AbsolutePosition feature" do
    Covering::Feature.parse?("AbsolutePosition").should be_nil
    cluster = build(Covering,
      feature_map: Covering::Feature::Lift | Covering::Feature::Tilt |
                   Covering::Feature::PositionAwareLift | Covering::Feature::PositionAwareTilt)
    (cluster.feature_map.value & 0x08_u32).should eq(0_u32)
    accepted_command_ids(cluster).should_not contain(0x04_u32)
    accepted_command_ids(cluster).should_not contain(0x07_u32)

    expect_raises(ArgumentError) { build(Covering, feature_map: Covering::Feature.new(0x08_u32)) }
  end

  it "starts with unknown current and target positions on both position-aware axes" do
    cluster = build(Covering,
      feature_map: Covering::Feature::Lift | Covering::Feature::Tilt |
                   Covering::Feature::PositionAwareLift | Covering::Feature::PositionAwareTilt)

    read(cluster, Covering::ATTR_CURRENT_POSITION_LIFT_PERCENT100THS).should be_nil
    read(cluster, Covering::ATTR_CURRENT_POSITION_TILT_PERCENT100THS).should be_nil
    read(cluster, Covering::ATTR_TARGET_POSITION_LIFT_PERCENT100THS).should be_nil
    read(cluster, Covering::ATTR_TARGET_POSITION_TILT_PERCENT100THS).should be_nil
  end

  it "requires an axis for each position-aware feature" do
    expect_raises(ArgumentError) { build(Covering, feature_map: Covering::Feature::None) }
    expect_raises(ArgumentError) { build(Covering, feature_map: Covering::Feature::PositionAwareLift) }
    expect_raises(ArgumentError) { build(Covering, feature_map: Covering::Feature::PositionAwareTilt) }
  end

  it "sets both supported targets and stops at the last reported positions" do
    cluster = build(Covering,
      feature_map: Covering::Feature::Lift | Covering::Feature::Tilt |
                   Covering::Feature::PositionAwareLift | Covering::Feature::PositionAwareTilt)

    expect_success(invoke(cluster, Covering::CMD_DOWN_OR_CLOSE))
    cluster.target_position_lift_percent100ths.should eq(10_000_u16)
    cluster.target_position_tilt_percent100ths.should eq(10_000_u16)

    cluster.current_position_lift_percent100ths = 3_000_u16
    cluster.current_position_tilt_percent100ths = 6_000_u16
    expect_success(invoke(cluster, Covering::CMD_STOP_MOTION))
    cluster.target_position_lift_percent100ths.should eq(3_000_u16)
    cluster.target_position_tilt_percent100ths.should eq(6_000_u16)

    expect_success(invoke(cluster, Covering::CMD_UP_OR_OPEN))
    cluster.target_position_lift_percent100ths.should eq(0_u16)
    cluster.target_position_tilt_percent100ths.should eq(0_u16)
  end

  it "uses the correct direction bits for lift and tilt motion" do
    both = build(Covering,
      feature_map: Covering::Feature::Lift | Covering::Feature::Tilt |
                   Covering::Feature::PositionAwareLift | Covering::Feature::PositionAwareTilt)
    expect_success(invoke(both, Covering::CMD_UP_OR_OPEN))
    both.operational_status.value.should eq(0x15_u8) # global, lift, tilt opening
    expect_success(invoke(both, Covering::CMD_DOWN_OR_CLOSE))
    both.operational_status.value.should eq(0x2A_u8) # global, lift, tilt closing
    expect_success(invoke(both, Covering::CMD_STOP_MOTION))
    both.operational_status.value.should eq(0_u8)

    tilt_only = build(Covering,
      feature_map: Covering::Feature::Tilt | Covering::Feature::PositionAwareTilt)
    expect_success(invoke(tilt_only, Covering::CMD_UP_OR_OPEN))
    tilt_only.operational_status.value.should eq(0x11_u8) # global and tilt opening
    expect_success(invoke(tilt_only, Covering::CMD_DOWN_OR_CLOSE))
    tilt_only.operational_status.value.should eq(0x22_u8) # global and tilt closing
  end

  it "derives percentage-move direction from a reported position" do
    tilt_only = build(Covering,
      feature_map: Covering::Feature::Tilt | Covering::Feature::PositionAwareTilt)
    tilt_only.current_position_tilt_percent100ths = 2_000_u16
    expect_success(invoke(tilt_only, Covering::CMD_GO_TO_TILT_PERCENTAGE,
      Covering::GoToTiltPercentageRequest.new(8_000_u16)))
    tilt_only.operational_status.value.should eq(0x22_u8)
    expect_success(invoke(tilt_only, Covering::CMD_GO_TO_TILT_PERCENTAGE,
      Covering::GoToTiltPercentageRequest.new(1_000_u16)))
    tilt_only.operational_status.value.should eq(0x11_u8)
  end
end
