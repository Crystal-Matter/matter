require "../spec_helper"
require "../../src/matter/endpoint"

private alias ColorLevel = Matter::Cluster::LevelControl
private alias CoupledColor = Matter::Cluster::ColorControl

private def color_level_clusters(options : UInt8 = ColorLevel::COUPLE_COLOR_TEMP_TO_LEVEL,
                                 color_first : Bool = false,
                                 color_feature : CoupledColor::Feature = CoupledColor::Feature::ColorTemperature)
  level = build(ColorLevel, current_level: 254_u8, options: options)
  color = build(CoupledColor, feature_map: color_feature,
    color_temp_physical_min_mireds: 153_u16, color_temp_physical_max_mireds: 370_u16,
    color_mode: CoupledColor::ColorMode::ColorTemperatureMireds)
  color.couple_color_temp_to_level_min_mireds = 200_u16
  color.enhanced_color_mode = CoupledColor::EnhancedColorMode::ColorTemperatureMireds
  endpoint = Matter::Endpoint.new(level.endpoint_id)
  (color_first ? [color, level] : [level, color]).each { |cluster| endpoint.add_cluster(cluster) }
  {level, color, endpoint}
end

describe "LevelControl color temperature coupling" do
  it "couples an unchanged level when a command enables the option" do
    level, color, _ = color_level_clusters
    level.move_to_level_with_on_off(ColorLevel::MoveToLevelWithOnOffRequest.new(254_u8, 0_u16, 0_u8, 0_u8))
    color.color_temperature_mireds.should eq(200_u16)
  end

  it "normalizes both color modes when only enhanced mode is temperature" do
    level, color, _ = color_level_clusters
    color.color_mode = CoupledColor::ColorMode::CurrentXAndCurrentY
    color.color_temperature_mireds = 200_u16
    level.move_to_level_with_on_off(ColorLevel::MoveToLevelWithOnOffRequest.new(254_u8, 0_u16, 0_u8, 0_u8))
    color.color_mode.should eq(CoupledColor::ColorMode::ColorTemperatureMireds)
    color.enhanced_color_mode.should eq(CoupledColor::EnhancedColorMode::ColorTemperatureMireds)
  end

  it "maps minimum, midpoint and maximum levels to the coupled mired range" do
    level, color, _ = color_level_clusters
    {1_u8 => 370_u16, 128_u8 => 285_u16, 254_u8 => 200_u16}.each do |target, expected|
      level.move_to_level_with_on_off(ColorLevel::MoveToLevelWithOnOffRequest.new(target, 0_u16, 0_u8, 0_u8)).success?.should be_true
      color.color_temperature_mireds.should eq(expected)
    end
  end

  it "honors the effective option on ordinary and WithOnOff commands" do
    level, color, _ = color_level_clusters(0_u8)
    level.move_to_level(ColorLevel::MoveToLevelRequest.new(128_u8, 0_u16, 0_u8, 0_u8))
    color.color_temperature_mireds.should eq(250_u16)
    level.move_to_level(ColorLevel::MoveToLevelRequest.new(1_u8, 0_u16, 2_u8, 2_u8))
    color.color_temperature_mireds.should eq(370_u16)
    level.options = ColorLevel::COUPLE_COLOR_TEMP_TO_LEVEL
    level.move_to_level_with_on_off(ColorLevel::MoveToLevelWithOnOffRequest.new(128_u8, 0_u16, 2_u8, 0_u8))
    color.color_temperature_mireds.should eq(370_u16)
  end

  it "updates color at each transition tick and preserves a cleared override" do
    level, color, _ = color_level_clusters
    started = Time.instant
    level.move_to_level(ColorLevel::MoveToLevelRequest.new(1_u8, 20_u16, 2_u8, 0_u8))
    level.advance_transition(started + 1.second)
    color.color_temperature_mireds.should eq(250_u16)
    level.advance_transition(started + 3.seconds)
    color.color_temperature_mireds.should eq(250_u16)
    level.move_to_level(ColorLevel::MoveToLevelRequest.new(254_u8, 20_u16, 0_u8, 0_u8))
    second = Time.instant
    level.advance_transition(second + 1.second)
    color.color_temperature_mireds.should be > 200_u16
    color.color_temperature_mireds.should be < 370_u16
    level.advance_transition(second + 3.seconds)
    color.color_temperature_mireds.should eq(200_u16)
  end

  it "only couples in color temperature mode with the CT and LT features" do
    level, color, _ = color_level_clusters
    color.color_mode = CoupledColor::ColorMode::CurrentXAndCurrentY
    color.enhanced_color_mode = CoupledColor::EnhancedColorMode::CurrentXAndCurrentY
    level.move_to_level_with_on_off(ColorLevel::MoveToLevelWithOnOffRequest.new(1_u8, 0_u16, 0_u8, 0_u8))
    color.color_temperature_mireds.should eq(250_u16)

    color.enhanced_color_mode = CoupledColor::EnhancedColorMode::ColorTemperatureMireds
    level.move_to_level_with_on_off(ColorLevel::MoveToLevelWithOnOffRequest.new(128_u8, 0_u16, 0_u8, 0_u8))
    color.color_temperature_mireds.should eq(285_u16)

    no_ct_level, no_ct_color, _ = color_level_clusters(color_feature: CoupledColor::Feature::HueSaturation)
    no_ct_level.move_to_level_with_on_off(ColorLevel::MoveToLevelWithOnOffRequest.new(1_u8, 0_u16, 0_u8, 0_u8))
    no_ct_color.color_temperature_mireds.should eq(250_u16)

    level_with_no_lighting = build(ColorLevel, current_level: 254_u8,
      feature_map: ColorLevel::Feature::OnOff, options: ColorLevel::COUPLE_COLOR_TEMP_TO_LEVEL)
    endpoint = Matter::Endpoint.new(level_with_no_lighting.endpoint_id)
    endpoint.add_cluster(level_with_no_lighting)
    endpoint.add_cluster(color)
    level_with_no_lighting.current_level = 2_u8
    color.color_temperature_mireds.should eq(285_u16)
    level_with_no_lighting.move_to_level_with_on_off(ColorLevel::MoveToLevelWithOnOffRequest.new(1_u8, 0_u16, 0_u8, 0_u8))
    color.color_temperature_mireds.should eq(285_u16)
  end

  it "binds regardless of cluster add order and tolerates an absent ColorControl" do
    level, color, _ = color_level_clusters(color_first: true)
    level.move_to_level_with_on_off(ColorLevel::MoveToLevelWithOnOffRequest.new(1_u8, 0_u16, 0_u8, 0_u8))
    color.color_temperature_mireds.should eq(370_u16)

    lone = build(ColorLevel, current_level: 254_u8, options: ColorLevel::COUPLE_COLOR_TEMP_TO_LEVEL)
    Matter::Endpoint.new(lone.endpoint_id).add_cluster(lone)
    lone.move_to_level_with_on_off(ColorLevel::MoveToLevelWithOnOffRequest.new(1_u8, 0_u16, 0_u8, 0_u8)).success?.should be_true
  end
end
