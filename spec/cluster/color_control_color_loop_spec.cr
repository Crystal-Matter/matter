require "../spec_helper"
require "../../src/matter/cluster/color_control"

private alias LoopingColor = Matter::Cluster::ColorControl

private def looping_color(current_hue : UInt8 = 10_u8)
  build(LoopingColor, current_hue: current_hue,
    feature_map: LoopingColor::Feature::HueSaturation |
                 LoopingColor::Feature::EnhancedHue |
                 LoopingColor::Feature::ColorLoop)
end

private def color_loop_request(flags : UInt8, action : LoopingColor::Action,
                               direction : LoopingColor::ColorLoopSetDirection,
                               time : UInt16 = 10_u16, start_hue : UInt16 = 1_000_u16)
  LoopingColor::ColorLoopSetRequest.new(flags, action, direction, time, start_hue)
end

describe "ColorControl ColorLoopSet" do
  it "uses update flags, loops in enhanced hue, and restores the stored hue when deactivated" do
    color = looping_color
    color.color_loop_set(color_loop_request(0x0F_u8,
      LoopingColor::Action::ActivateTheColorLoopFromTheValueInTheColorLoopStartEnhancedHueField,
      LoopingColor::ColorLoopSetDirection::IncrementTheHueInTheColorLoop)).success?.should be_true

    color.color_loop_active?.should be_true
    color.color_loop_direction.should eq(1_u8)
    color.color_loop_time.should eq(10_u16)
    color.color_loop_start_enhanced_hue.should eq(1_000_u16)
    color.color_loop_stored_enhanced_hue.should eq(10_u16 << LoopingColor::ENHANCED_HUE_SHIFT)
    color.enhanced_current_hue.should eq(1_000_u16)

    color.advance_movement(Time.instant + 1.second)
    color.enhanced_current_hue.should be > 7_000_u16
    color.enhanced_color_mode.should eq(LoopingColor::EnhancedColorMode::EnhancedCurrentHueAndCurrentSaturation)

    color.color_loop_set(color_loop_request(0x01_u8,
      LoopingColor::Action::DeActivateTheColorLoop,
      LoopingColor::ColorLoopSetDirection::DecrementTheHueInTheColorLoop,
      1_u16, 2_000_u16)).success?.should be_true
    color.color_loop_active?.should be_false
    color.enhanced_current_hue.should eq(10_u16 << LoopingColor::ENHANCED_HUE_SHIFT)
    color.color_loop_direction.should eq(1_u8)
    color.color_loop_time.should eq(10_u16)
    color.color_loop_start_enhanced_hue.should eq(1_000_u16)
    color.advance_movement(Time.instant + 3.seconds)
    color.enhanced_current_hue.should eq(10_u16 << LoopingColor::ENHANCED_HUE_SHIFT)
  end

  it "can start from the current enhanced hue and move in the decrement direction" do
    color = looping_color(0_u8)
    color.color_loop_set(color_loop_request(0x07_u8,
      LoopingColor::Action::ActivateTheColorLoopFromTheValueOfTheEnhancedCurrentHueAttribute,
      LoopingColor::ColorLoopSetDirection::DecrementTheHueInTheColorLoop,
      10_u16)).success?.should be_true
    color.enhanced_current_hue.should eq(0_u16)
    color.advance_movement(Time.instant + 1.second)
    color.enhanced_current_hue.should be > 58_000_u16
    color.color_loop_active?.should be_true
  end

  it "keeps the color loop active when StopMoveStep is invoked" do
    color = looping_color
    color.color_loop_set(color_loop_request(0x01_u8,
      LoopingColor::Action::ActivateTheColorLoopFromTheValueOfTheEnhancedCurrentHueAttribute,
      LoopingColor::ColorLoopSetDirection::IncrementTheHueInTheColorLoop)).success?.should be_true
    color.stop_move_step(LoopingColor::StopMoveStepRequest.new).success?.should be_true
    color.advance_movement(Time.instant + 1.second)
    color.color_loop_active?.should be_true
    color.enhanced_current_hue.should be > 2_560_u16
  end

  it "restarts an active loop from its current hue when direction or time changes" do
    color = looping_color
    color.color_loop_set(color_loop_request(0x07_u8,
      LoopingColor::Action::ActivateTheColorLoopFromTheValueOfTheEnhancedCurrentHueAttribute,
      LoopingColor::ColorLoopSetDirection::IncrementTheHueInTheColorLoop)).success?.should be_true
    color.advance_movement(Time.instant + 1.second)
    before = color.enhanced_current_hue

    color.color_loop_set(color_loop_request(0x06_u8,
      LoopingColor::Action::DeActivateTheColorLoop,
      LoopingColor::ColorLoopSetDirection::DecrementTheHueInTheColorLoop,
      20_u16)).success?.should be_true
    color.color_loop_active?.should be_true
    color.color_loop_direction.should eq(0_u8)
    color.color_loop_time.should eq(20_u16)
    color.advance_movement(Time.instant + 1.second)
    color.enhanced_current_hue.should be < before
  end

  it "ends an active loop when an ordinary hue command replaces it" do
    color = looping_color
    color.color_loop_set(color_loop_request(0x01_u8,
      LoopingColor::Action::ActivateTheColorLoopFromTheValueOfTheEnhancedCurrentHueAttribute,
      LoopingColor::ColorLoopSetDirection::IncrementTheHueInTheColorLoop)).success?.should be_true
    color.move_to_hue(LoopingColor::MoveToHueRequest.new(
      40_u8, LoopingColor::Direction::ShortestDistance, 0_u16)).success?.should be_true
    color.color_loop_active?.should be_false
    color.current_hue.should eq(40_u8)
    color.advance_movement(Time.instant + 1.second)
    color.current_hue.should eq(40_u8)
  end
end
