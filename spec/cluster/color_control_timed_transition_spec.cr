require "../spec_helper"
require "../../src/matter/endpoint"
require "../../src/matter/cluster/color_control"
require "../../src/matter/cluster/on_off"

private alias TimedColor = Matter::Cluster::ColorControl

describe "ColorControl timed transitions" do
  # The cluster records Time.instant when each command starts. Freeze the
  # monotonic clock so a later Time.instant sample is the same origin; otherwise
  # exact midpoint assertions can be one tick ahead on a loaded CI runner.
  around_each do |example|
    Timecop.freeze(Time.utc) { example.run }
    nil
  end

  it "interpolates hue in the requested direction and reports remaining deciseconds" do
    color = build(TimedColor, current_hue: 250_u8)
    color.move_to_hue(TimedColor::MoveToHueRequest.new(10_u8, TimedColor::Direction::Up, 20_u16)).success?.should be_true
    color.current_hue.should eq(250_u8)
    color.remaining_time.should eq(20_u16)
    started = Time.instant
    color.advance_movement(started + 1.second)
    color.current_hue.should be < 10_u8
    color.remaining_time.should be <= 10_u16
    color.advance_movement(started + 2.seconds)
    color.current_hue.should eq(10_u8)
    color.remaining_time.should eq(0_u16)
  end

  it "moves both chromaticity coordinates over the same transition and stops at the midpoint" do
    color = build(TimedColor, current_x: 100_u16, current_y: 400_u16)
    color.move_to_color(TimedColor::MoveToColorRequest.new(300_u16, 200_u16, 20_u16)).success?.should be_true
    color.current_x.should eq(100_u16)
    color.current_y.should eq(400_u16)
    started = Time.instant
    color.advance_movement(started + 1.second)
    color.current_x.should eq(200_u16)
    color.current_y.should eq(300_u16)
    color.stop_move_step(TimedColor::StopMoveStepRequest.new).success?.should be_true
    stopped = color.current_x
    color.advance_movement(started + 2.seconds)
    color.current_x.should eq(stopped)
    color.remaining_time.should eq(0_u16)
  end

  it "takes the shortest or longest hue path and times a StepHue wrap" do
    color = build(TimedColor, current_hue: 250_u8)
    color.move_to_hue(TimedColor::MoveToHueRequest.new(10_u8, TimedColor::Direction::ShortestDistance, 20_u16))
    started = Time.instant
    color.advance_movement(started + 1.second)
    color.current_hue.should be < 10_u8
    color.advance_movement(started + 2.seconds)

    color.move_to_hue(TimedColor::MoveToHueRequest.new(250_u8, TimedColor::Direction::LongestDistance, 20_u16))
    started = Time.instant
    color.advance_movement(started + 1.second)
    color.current_hue.should be >= 100_u8
    color.current_hue.should be <= 150_u8
    color.advance_movement(started + 2.seconds)

    color.step_hue(TimedColor::StepHueRequest.new(TimedColor::StepMode::Up, 20_u8, 20_u8))
    color.current_hue.should eq(250_u8)
    started = Time.instant
    color.advance_movement(started + 1.second)
    color.current_hue.should be < 10_u8
    color.advance_movement(started + 2.seconds)
    color.current_hue.should eq(15_u8)
  end

  it "times saturation MoveTo and Step, including the upper bound" do
    color = build(TimedColor, current_saturation: 50_u8)
    color.move_to_saturation(TimedColor::MoveToSaturationRequest.new(150_u8, 20_u16))
    color.current_saturation.should eq(50_u8)
    started = Time.instant
    color.advance_movement(started + 1.second)
    color.current_saturation.should eq(100_u8)
    color.advance_movement(started + 2.seconds)

    color.step_saturation(TimedColor::StepSaturationRequest.new(TimedColor::StepMode::Up, 200_u8, 20_u8))
    color.current_saturation.should eq(150_u8)
    started = Time.instant
    color.advance_movement(started + 2.seconds)
    color.current_saturation.should eq(254_u8)
  end

  it "times combined hue and saturation and an XY step within the XML bounds" do
    color = build(TimedColor, current_hue: 50_u8, current_saturation: 50_u8,
      current_x: 65_000_u16, current_y: 100_u16)
    color.move_to_hue_and_saturation(TimedColor::MoveToHueAndSaturationRequest.new(150_u8, 200_u8, 20_u16))
    started = Time.instant
    color.advance_movement(started + 1.second)
    color.current_hue.should eq(100_u8)
    color.current_saturation.should eq(125_u8)
    color.advance_movement(started + 2.seconds)
    color.current_hue.should eq(150_u8)
    color.current_saturation.should eq(200_u8)

    color.step_color(TimedColor::StepColorRequest.new(1_000_i16, -200_i16, 20_u16))
    color.current_x.should eq(65_000_u16)
    started = Time.instant
    color.advance_movement(started + 2.seconds)
    color.current_x.should eq(TimedColor::CHROMATICITY_MAX)
    color.current_y.should eq(0_u16)
  end

  it "times MoveTo and Step color temperature within command and physical bounds" do
    color = build(TimedColor, color_temperature_mireds: 250_u16)
    color.move_to_color_temperature(TimedColor::MoveToColorTemperatureRequest.new(400_u16, 20_u16))
    color.color_temperature_mireds.should eq(250_u16)
    started = Time.instant
    color.advance_movement(started + 1.second)
    color.color_temperature_mireds.should eq(325_u16)
    color.advance_movement(started + 2.seconds)

    color.step_color_temperature(TimedColor::StepColorTemperatureRequest.new(
      TimedColor::StepMode::Up, 200_u16, 20_u16, 0_u16, 450_u16))
    color.color_temperature_mireds.should eq(400_u16)
    started = Time.instant
    color.advance_movement(started + 2.seconds)
    color.color_temperature_mireds.should eq(450_u16)
  end

  it "clamps a temperature step to both command bounds when starting outside the interval" do
    below = build(TimedColor, color_temperature_mireds: 250_u16)
    below.step_color_temperature(TimedColor::StepColorTemperatureRequest.new(
      TimedColor::StepMode::Up, 10_u16, 0_u16, 300_u16, 400_u16))
    below.color_temperature_mireds.should eq(300_u16)

    above = build(TimedColor, color_temperature_mireds: 450_u16)
    above.step_color_temperature(TimedColor::StepColorTemperatureRequest.new(
      TimedColor::StepMode::Down, 10_u16, 0_u16, 200_u16, 300_u16))
    above.color_temperature_mireds.should eq(300_u16)
  end

  it "times enhanced hue and combined enhanced hue/saturation" do
    color = build(TimedColor, feature_map: TimedColor::Feature::HueSaturation | TimedColor::Feature::EnhancedHue)
    color.enhanced_move_to_hue(TimedColor::EnhancedMoveToHueRequest.new(20_000_u16, TimedColor::Direction::Up, 20_u16))
    color.enhanced_current_hue.should eq(0_u16)
    started = Time.instant
    color.advance_movement(started + 1.second)
    color.enhanced_current_hue.should eq(10_000_u16)
    color.advance_movement(started + 2.seconds)

    color.enhanced_step_hue(TimedColor::EnhancedStepHueRequest.new(TimedColor::StepMode::Up, 2_000_u16, 20_u16))
    color.enhanced_current_hue.should eq(20_000_u16)
    started = Time.instant
    color.advance_movement(started + 2.seconds)
    color.enhanced_current_hue.should eq(22_000_u16)

    color.enhanced_move_to_hue_and_saturation(TimedColor::EnhancedMoveToHueAndSaturationRequest.new(32_000_u16, 200_u8, 20_u16))
    color.enhanced_current_hue.should eq(22_000_u16)
    started = Time.instant
    color.advance_movement(started + 1.second)
    color.enhanced_current_hue.should eq(27_000_u16)
    color.current_saturation.should eq(100_u8)
    color.advance_movement(started + 2.seconds)
    color.enhanced_current_hue.should eq(32_000_u16)
    color.current_saturation.should eq(200_u8)
  end

  it "sets the combined command color mode even when numeric targets already match" do
    features = TimedColor::Feature::HueSaturation | TimedColor::Feature::EnhancedHue | TimedColor::Feature::Xy
    color = build(TimedColor, feature_map: features)
    color.move_to_color(TimedColor::MoveToColorRequest.new(100_u16, 200_u16, 0_u16))
    color.move_to_hue_and_saturation(TimedColor::MoveToHueAndSaturationRequest.new(0_u8, 0_u8, 0_u16))
    color.color_mode.should eq(TimedColor::ColorMode::CurrentHueAndCurrentSaturation)

    color.move_to_color(TimedColor::MoveToColorRequest.new(100_u16, 200_u16, 0_u16))
    color.enhanced_move_to_hue_and_saturation(TimedColor::EnhancedMoveToHueAndSaturationRequest.new(0_u16, 0_u8, 0_u16))
    color.enhanced_color_mode.should eq(TimedColor::EnhancedColorMode::EnhancedCurrentHueAndCurrentSaturation)
  end

  it "replaces a timed transition from its interpolated value" do
    color = build(TimedColor, current_x: 100_u16)
    color.move_to_color(TimedColor::MoveToColorRequest.new(300_u16, 0_u16, 20_u16))
    started = Time.instant
    color.advance_movement(started + 1.second)
    color.current_x.should eq(200_u16)
    color.move_to_color(TimedColor::MoveToColorRequest.new(400_u16, 0_u16, 20_u16))
    color.current_x.should eq(200_u16)
    color.remaining_time.should eq(20_u16)
    started = Time.instant
    color.advance_movement(started + 2.seconds)
    color.current_x.should eq(400_u16)
  end

  it "rejects the XML-reserved transition duration without stopping the current movement" do
    color = build(TimedColor, current_hue: 10_u8)
    color.move_to_hue(TimedColor::MoveToHueRequest.new(100_u8, TimedColor::Direction::Up, 20_u16))
    result = color.move_to_hue(TimedColor::MoveToHueRequest.new(200_u8, TimedColor::Direction::Up, UInt16::MAX))
    result.status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    color.remaining_time.should be > 0_u16
    started = Time.instant
    color.advance_movement(started + 2.seconds)
    color.current_hue.should eq(100_u8)
  end

  it "rejects out-of-range MoveTo fields without changing color or its active transition" do
    features = TimedColor::Feature::HueSaturation | TimedColor::Feature::EnhancedHue |
               TimedColor::Feature::Xy | TimedColor::Feature::ColorTemperature
    color = build(TimedColor, feature_map: features, current_hue: 10_u8,
      current_saturation: 50_u8, current_x: 100_u16)
    color.move_to_hue(TimedColor::MoveToHueRequest.new(100_u8, TimedColor::Direction::Up, 20_u16))

    invalid = [
      color.move_to_hue(TimedColor::MoveToHueRequest.new(255_u8, TimedColor::Direction::Up, 0_u16)),
      color.move_to_saturation(TimedColor::MoveToSaturationRequest.new(255_u8, 0_u16)),
      color.move_to_hue_and_saturation(TimedColor::MoveToHueAndSaturationRequest.new(50_u8, 255_u8, 0_u16)),
      color.move_to_color(TimedColor::MoveToColorRequest.new(65_535_u16, 100_u16, 0_u16)),
      color.move_to_color_temperature(TimedColor::MoveToColorTemperatureRequest.new(65_535_u16, 0_u16)),
      color.enhanced_move_to_hue_and_saturation(TimedColor::EnhancedMoveToHueAndSaturationRequest.new(10_000_u16, 255_u8, 0_u16)),
    ]
    invalid.each do |result|
      result.status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    end
    color.current_hue.should eq(10_u8)
    color.current_saturation.should eq(50_u8)
    color.current_x.should eq(100_u16)
    color.remaining_time.should be > 0_u16
  end

  it "validates MoveTo fields before ExecuteIfOff suppresses an off-device command" do
    color = build(TimedColor, current_hue: 10_u8)
    on_off = build(Matter::Cluster::OnOff, on_off: false)
    endpoint = Matter::Endpoint.new(color.endpoint_id)
    endpoint.add_cluster(color)
    endpoint.add_cluster(on_off)

    color.move_to_hue(TimedColor::MoveToHueRequest.new(
      255_u8, TimedColor::Direction::Up, 0_u16)).status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    color.move_to_hue(TimedColor::MoveToHueRequest.new(
      100_u8, TimedColor::Direction::Up, UInt16::MAX)).status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    color.move_to_color(TimedColor::MoveToColorRequest.new(
      65_535_u16, 100_u16, 0_u16)).status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    color.move_to_hue(TimedColor::MoveToHueRequest.new(
      100_u8, TimedColor::Direction::Up, 0_u16)).success?.should be_true
    color.current_hue.should eq(10_u8)
  end

  it "uses the downward hue path and completes an immediate replacement" do
    color = build(TimedColor, current_hue: 10_u8)
    color.move_to_hue(TimedColor::MoveToHueRequest.new(250_u8, TimedColor::Direction::Down, 20_u16))
    started = Time.instant
    color.advance_movement(started + 1.second)
    color.current_hue.should eq(3_u8)
    color.move_to_hue(TimedColor::MoveToHueRequest.new(100_u8, TimedColor::Direction::Up, 0_u16))
    color.current_hue.should eq(100_u8)
    color.remaining_time.should eq(0_u16)
  end
end
