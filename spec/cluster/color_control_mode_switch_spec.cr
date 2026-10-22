require "../spec_helper"
require "../../src/matter/cluster/color_control"
require "../../src/matter/cluster/on_off"
require "../../src/matter/endpoint"

private alias ModeColor = Matter::Cluster::ColorControl

describe "ColorControl mode selection" do
  it "switches mode when a zero-duration target already equals the stored value" do
    features = ModeColor::Feature::HueSaturation | ModeColor::Feature::EnhancedHue |
               ModeColor::Feature::Xy | ModeColor::Feature::ColorTemperature
    color = build(ModeColor, feature_map: features)

    color.move_to_color_temperature(ModeColor::MoveToColorTemperatureRequest.new(250_u16, 0_u16)).success?.should be_true
    color.color_mode.should eq(ModeColor::ColorMode::ColorTemperatureMireds)
    color.enhanced_color_mode.should eq(ModeColor::EnhancedColorMode::ColorTemperatureMireds)

    color.move_to_color(ModeColor::MoveToColorRequest.new(0_u16, 0_u16, 0_u16)).success?.should be_true
    color.color_mode.should eq(ModeColor::ColorMode::CurrentXAndCurrentY)
    color.enhanced_color_mode.should eq(ModeColor::EnhancedColorMode::CurrentXAndCurrentY)

    color.move_to_hue(ModeColor::MoveToHueRequest.new(0_u8, ModeColor::Direction::ShortestDistance, 0_u16)).success?.should be_true
    color.color_mode.should eq(ModeColor::ColorMode::CurrentHueAndCurrentSaturation)
    color.enhanced_color_mode.should eq(ModeColor::EnhancedColorMode::CurrentHueAndCurrentSaturation)

    color.enhanced_move_to_hue(ModeColor::EnhancedMoveToHueRequest.new(0_u16, ModeColor::Direction::ShortestDistance, 0_u16)).success?.should be_true
    color.color_mode.should eq(ModeColor::ColorMode::CurrentHueAndCurrentSaturation)
    color.enhanced_color_mode.should eq(ModeColor::EnhancedColorMode::EnhancedCurrentHueAndCurrentSaturation)
  end

  it "selects the new mode immediately when a timed transition starts" do
    color = build(ModeColor)
    color.move_to_color_temperature(ModeColor::MoveToColorTemperatureRequest.new(300_u16, 20_u16)).success?.should be_true
    color.color_temperature_mireds.should eq(250_u16)
    color.color_mode.should eq(ModeColor::ColorMode::ColorTemperatureMireds)
    color.enhanced_color_mode.should eq(ModeColor::EnhancedColorMode::ColorTemperatureMireds)
    color.remaining_time.should eq(20_u16)

    color.move_to_hue(ModeColor::MoveToHueRequest.new(50_u8, ModeColor::Direction::ShortestDistance, 20_u16)).success?.should be_true
    color.current_hue.should eq(0_u8)
    color.color_mode.should eq(ModeColor::ColorMode::CurrentHueAndCurrentSaturation)
    color.enhanced_color_mode.should eq(ModeColor::EnhancedColorMode::CurrentHueAndCurrentSaturation)
    color.stop_move_step(ModeColor::StopMoveStepRequest.new)
  end

  it "selects the new mode immediately when a continuous movement starts" do
    color = build(ModeColor)
    color.move_color(ModeColor::MoveColorRequest.new(10_i16, 0_i16)).success?.should be_true
    color.current_x.should eq(0_u16)
    color.color_mode.should eq(ModeColor::ColorMode::CurrentXAndCurrentY)
    color.enhanced_color_mode.should eq(ModeColor::EnhancedColorMode::CurrentXAndCurrentY)
    color.stop_move_step(ModeColor::StopMoveStepRequest.new)
  end

  it "keeps the mode when ExecuteIfOff suppresses the command" do
    color = build(ModeColor)
    on_off = build(Matter::Cluster::OnOff, on_off: false)
    endpoint = Matter::Endpoint.new(color.endpoint_id)
    endpoint.add_cluster(color)
    endpoint.add_cluster(on_off)

    color.move_to_color_temperature(ModeColor::MoveToColorTemperatureRequest.new(300_u16, 0_u16)).success?.should be_true
    color.color_mode.should eq(ModeColor::ColorMode::CurrentHueAndCurrentSaturation)
    color.enhanced_color_mode.should eq(ModeColor::EnhancedColorMode::CurrentHueAndCurrentSaturation)
  end
end
