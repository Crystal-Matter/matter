require "../spec_helper"
require "../../src/matter/cluster/color_control"

private alias MovingColor = Matter::Cluster::ColorControl

describe "ColorControl continuous movement" do
  it "advances hue at the requested rate and wraps through the color wheel" do
    color = build(MovingColor, current_hue: 250_u8)
    color.move_hue(MovingColor::MoveHueRequest.new(MovingColor::MoveMode::Up, 10_u8))
    started = Time.instant
    color.advance_movement(started + 1.second)
    color.current_hue.should eq(5_u8)
    color.enhanced_current_hue.should eq(5_u16 << MovingColor::ENHANCED_HUE_SHIFT)
    color.stop_move_step(MovingColor::StopMoveStepRequest.new)
  end

  it "rejects zero hue rate without changing state" do
    color = build(MovingColor, current_hue: 50_u8)
    result = color.move_hue(MovingColor::MoveHueRequest.new(MovingColor::MoveMode::Up, 0_u8))
    result.status.should eq(Matter::InteractionModel::StatusCode::InvalidCommand)
    color.current_hue.should eq(50_u8)
  end

  it "advances a move on its own scheduler" do
    color = build(MovingColor)
    color.move_hue(MovingColor::MoveHueRequest.new(MovingColor::MoveMode::Up, 20_u8))
    deadline = Time.instant + 2.seconds
    while color.current_hue == 0_u8 && Time.instant < deadline
      sleep 20.milliseconds
    end
    color.current_hue.should be > 0_u8
    color.stop_move_step(MovingColor::StopMoveStepRequest.new)
  end

  it "advances saturation and stops at its maximum" do
    color = build(MovingColor, current_saturation: 250_u8)
    color.move_saturation(MovingColor::MoveSaturationRequest.new(MovingColor::MoveMode::Up, 10_u8))
    started = Time.instant
    color.advance_movement(started + 1.second)
    color.current_saturation.should eq(254_u8)
  end

  it "stops a running movement without resetting its current value" do
    color = build(MovingColor, current_saturation: 50_u8)
    color.move_saturation(MovingColor::MoveSaturationRequest.new(MovingColor::MoveMode::Up, 20_u8))
    started = Time.instant
    color.advance_movement(started + 500.milliseconds)
    color.stop_move_step(MovingColor::StopMoveStepRequest.new)
    stopped = color.current_saturation
    color.advance_movement(started + 2.seconds)
    color.current_saturation.should eq(stopped)
  end

  it "lets a new MoveTo command replace a running move" do
    color = build(MovingColor)
    color.move_hue(MovingColor::MoveHueRequest.new(MovingColor::MoveMode::Up, 20_u8))
    color.move_to_hue(MovingColor::MoveToHueRequest.new(
      80_u8, MovingColor::Direction::ShortestDistance, 0_u16))
    color.advance_movement(Time.instant + 2.seconds)
    color.current_hue.should eq(80_u8)
  end

  it "moves X and Y independently at signed rates" do
    color = build(MovingColor, current_x: 100_u16, current_y: 200_u16)
    color.move_color(MovingColor::MoveColorRequest.new(20_i16, -30_i16))
    started = Time.instant
    color.advance_movement(started + 1.second)
    color.current_x.should eq(120_u16)
    color.current_y.should eq(170_u16)
    color.stop_move_step(MovingColor::StopMoveStepRequest.new)
  end

  it "moves color temperature to its command bound" do
    color = build(MovingColor, color_temperature_mireds: 250_u16)
    color.move_color_temperature(MovingColor::MoveColorTemperatureRequest.new(
      MovingColor::MoveMode::Up, 50_u16, 0_u16, 300_u16))
    started = Time.instant
    color.advance_movement(started + 2.seconds)
    color.color_temperature_mireds.should eq(300_u16)
  end
end
