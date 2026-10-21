require "../spec_helper"
require "../../src/matter/cluster/color_control"

private alias EnhancedMovingColor = Matter::Cluster::ColorControl

private def enhanced_moving_color(current_hue : UInt8 = 0_u8)
  build(EnhancedMovingColor, current_hue: current_hue,
    feature_map: EnhancedMovingColor::Feature::HueSaturation | EnhancedMovingColor::Feature::EnhancedHue)
end

describe "ColorControl EnhancedMoveHue" do
  it "advances the 16-bit hue at the requested rate and wraps through zero" do
    color = enhanced_moving_color(254_u8)
    color.enhanced_move_hue(EnhancedMovingColor::EnhancedMoveHueRequest.new(
      EnhancedMovingColor::MoveMode::Up, 512_u16)).success?.should be_true
    color.advance_movement(Time.instant + 1.second)
    color.enhanced_current_hue.should be < 256_u16
    color.current_hue.should eq(0_u8)
    color.enhanced_color_mode.should eq(EnhancedMovingColor::EnhancedColorMode::EnhancedCurrentHueAndCurrentSaturation)
    color.stop_move_step(EnhancedMovingColor::StopMoveStepRequest.new)
  end

  it "stops an enhanced hue movement at its current value" do
    color = enhanced_moving_color(100_u8)
    color.enhanced_move_hue(EnhancedMovingColor::EnhancedMoveHueRequest.new(
      EnhancedMovingColor::MoveMode::Up, 512_u16))
    color.advance_movement(Time.instant + 1.second)
    color.enhanced_move_hue(EnhancedMovingColor::EnhancedMoveHueRequest.new(
      EnhancedMovingColor::MoveMode::Stop, 0_u16)).success?.should be_true
    stopped = color.enhanced_current_hue
    color.advance_movement(Time.instant + 3.seconds)
    color.enhanced_current_hue.should eq(stopped)
  end

  it "wraps downward through the 16-bit hue range" do
    color = enhanced_moving_color
    color.enhanced_move_hue(EnhancedMovingColor::EnhancedMoveHueRequest.new(
      EnhancedMovingColor::MoveMode::Down, 512_u16)).success?.should be_true
    color.advance_movement(Time.instant + 1.second)
    color.enhanced_current_hue.should be > 64_000_u16
    color.current_hue.should eq(254_u8)
    color.stop_move_step(EnhancedMovingColor::StopMoveStepRequest.new)
  end

  it "rejects a zero rate for an up movement without changing state" do
    color = enhanced_moving_color(100_u8)
    result = color.enhanced_move_hue(EnhancedMovingColor::EnhancedMoveHueRequest.new(
      EnhancedMovingColor::MoveMode::Up, 0_u16))
    result.status.should eq(Matter::InteractionModel::StatusCode::InvalidCommand)
    color.enhanced_current_hue.should eq(100_u16 << EnhancedMovingColor::ENHANCED_HUE_SHIFT)
  end
end
