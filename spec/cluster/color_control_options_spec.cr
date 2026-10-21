require "../spec_helper"
require "../../src/matter/endpoint"
require "../../src/matter/cluster/color_control"
require "../../src/matter/cluster/on_off"

private alias OptionColor = Matter::Cluster::ColorControl
private alias OptionOnOff = Matter::Cluster::OnOff

private def color_with_on_off(on : Bool = false, options : UInt8 = 0_u8)
  color = build(OptionColor, current_hue: 20_u8, options: options)
  on_off = build(OptionOnOff, on_off: on)
  endpoint = Matter::Endpoint.new(color.endpoint_id)
  endpoint.add_cluster(color)
  endpoint.add_cluster(on_off)
  {color, on_off}
end

describe "ColorControl ExecuteIfOff options" do
  it "leaves color and a running movement unchanged while the sibling OnOff is off" do
    color, on_off = color_with_on_off(true)
    color.move_hue(OptionColor::MoveHueRequest.new(OptionColor::MoveMode::Up, 10_u8))
    on_off.off
    color.move_to_hue(OptionColor::MoveToHueRequest.new(
      90_u8, OptionColor::Direction::ShortestDistance, 0_u16)).success?.should be_true
    color.stop_move_step(OptionColor::StopMoveStepRequest.new).success?.should be_true
    color.current_hue.should eq(20_u8)
    color.advance_movement(Time.instant + 1.second)
    color.current_hue.should be > 20_u8
    color.stop_move_step(OptionColor::StopMoveStepRequest.new(1_u8, 1_u8))
  end

  it "executes while off when OptionsMask and OptionsOverride set ExecuteIfOff" do
    color, _ = color_with_on_off
    color.move_to_hue(OptionColor::MoveToHueRequest.new(
      90_u8, OptionColor::Direction::ShortestDistance, 0_u16, 1_u8, 1_u8))
    color.current_hue.should eq(90_u8)
  end

  it "uses the Options attribute when the command mask does not override it" do
    color, _ = color_with_on_off(options: 1_u8)
    color.move_to_color_temperature(OptionColor::MoveToColorTemperatureRequest.new(300_u16, 0_u16))
    color.color_temperature_mireds.should eq(300_u16)
  end

  it "lets a command mask clear ExecuteIfOff from the Options attribute" do
    color, _ = color_with_on_off(options: 1_u8)
    color.move_to_hue(OptionColor::MoveToHueRequest.new(
      90_u8, OptionColor::Direction::ShortestDistance, 0_u16, 1_u8, 0_u8))
    color.current_hue.should eq(20_u8)
  end

  it "executes normally while the sibling OnOff is on" do
    color, _ = color_with_on_off(true)
    color.move_to_hue(OptionColor::MoveToHueRequest.new(
      90_u8, OptionColor::Direction::ShortestDistance, 0_u16))
    color.current_hue.should eq(90_u8)
  end
end
