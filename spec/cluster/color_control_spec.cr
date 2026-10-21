require "../spec_helper"
require "../../src/matter/cluster/color_control"

# Note: Time-based transition tests from matter.js behavioral tests
# (packages/node/test/behaviors/color-control/ColorControlServerTest.ts)
# require transition manager support with gradual color changes over time.
# Current implementation performs instant color changes.
# These tests can be added when transition support is implemented.

describe Matter::Cluster::ColorControl do
  describe "initialization" do
    it "creates cluster with default values" do
      cluster = build(Matter::Cluster::ColorControl)

      cluster.cluster_id.id.should eq(0x0300_u32)
      cluster.name.should eq("ColorControl")
      cluster.current_hue.should eq(0_u8)
      cluster.current_saturation.should eq(0_u8)
      cluster.current_x.should eq(0_u16)
      cluster.current_y.should eq(0_u16)
      cluster.color_temperature_mireds.should eq(250_u16)
      cluster.color_mode.should eq(Matter::Cluster::ColorControl::ColorMode::CurrentHueAndCurrentSaturation)
    end

    it "creates cluster with custom values" do
      cluster = build(Matter::Cluster::ColorControl,
        current_hue: 100_u8,
        current_saturation: 200_u8,
        color_temperature_mireds: 300_u16
      )

      cluster.current_hue.should eq(100_u8)
      cluster.current_saturation.should eq(200_u8)
      cluster.color_temperature_mireds.should eq(300_u16)
    end
  end

  describe "hue commands" do
    it "executes MoveToHue command" do
      cluster = build(Matter::Cluster::ColorControl, current_hue: 0_u8)

      cluster.current_hue.should eq(0_u8)

      # MoveToHue(hue=127, ...)
      result = invoke(cluster, Matter::Cluster::ColorControl::CMD_MOVE_TO_HUE, Matter::Cluster::ColorControl::MoveToHueRequest.new(hue: (127).to_u8, direction: Matter::Cluster::ColorControl::Direction::ShortestDistance, transition_time: (0).to_u16))

      result.should be_a(Matter::InteractionModel::Status)
      result.as(Matter::InteractionModel::Status).success?.should be_true
      cluster.current_hue.should eq(127_u8)
      cluster.color_mode.should eq(Matter::Cluster::ColorControl::ColorMode::CurrentHueAndCurrentSaturation)
    end

    it "executes StepHue Up command" do
      cluster = build(Matter::Cluster::ColorControl, current_hue: 100_u8)

      # StepHue(mode=Up, step_size=20, ...)
      result = invoke(cluster, Matter::Cluster::ColorControl::CMD_STEP_HUE, Matter::Cluster::ColorControl::StepHueRequest.new(step_mode: Matter::Cluster::ColorControl::StepMode::Up, step_size: (20).to_u8, transition_time: (0).to_u8))

      result.as(Matter::InteractionModel::Status).success?.should be_true
      cluster.current_hue.should eq(120_u8)
    end

    it "executes StepHue Down command" do
      cluster = build(Matter::Cluster::ColorControl, current_hue: 100_u8)

      # StepHue(mode=Down, step_size=30, ...)
      result = invoke(cluster, Matter::Cluster::ColorControl::CMD_STEP_HUE, Matter::Cluster::ColorControl::StepHueRequest.new(step_mode: Matter::Cluster::ColorControl::StepMode::Down, step_size: (30).to_u8, transition_time: (0).to_u8))

      result.as(Matter::InteractionModel::Status).success?.should be_true
      cluster.current_hue.should eq(70_u8)
    end

    it "wraps hue around 255" do
      cluster = build(Matter::Cluster::ColorControl, current_hue: 250_u8)

      # Step up by 10 should wrap to 5
      invoke(cluster, Matter::Cluster::ColorControl::CMD_STEP_HUE, Matter::Cluster::ColorControl::StepHueRequest.new(step_mode: Matter::Cluster::ColorControl::StepMode::Up, step_size: (10).to_u8, transition_time: (0).to_u8))

      cluster.current_hue.should eq(5_u8)
    end
  end

  describe "saturation commands" do
    it "executes MoveToSaturation command" do
      cluster = build(Matter::Cluster::ColorControl, current_saturation: 0_u8)

      # MoveToSaturation(saturation=200, ...)
      result = invoke(cluster, Matter::Cluster::ColorControl::CMD_MOVE_TO_SATURATION, Matter::Cluster::ColorControl::MoveToSaturationRequest.new(saturation: (200).to_u8, transition_time: (0).to_u16))

      result.as(Matter::InteractionModel::Status).success?.should be_true
      cluster.current_saturation.should eq(200_u8)
    end

    it "executes StepSaturation Up command" do
      cluster = build(Matter::Cluster::ColorControl, current_saturation: 100_u8)

      invoke(cluster, Matter::Cluster::ColorControl::CMD_STEP_SATURATION, Matter::Cluster::ColorControl::StepSaturationRequest.new(step_mode: Matter::Cluster::ColorControl::StepMode::Up, step_size: (50).to_u8, transition_time: (0).to_u8))

      cluster.current_saturation.should eq(150_u8)
    end

    it "executes StepSaturation Down command" do
      cluster = build(Matter::Cluster::ColorControl, current_saturation: 100_u8)

      invoke(cluster, Matter::Cluster::ColorControl::CMD_STEP_SATURATION, Matter::Cluster::ColorControl::StepSaturationRequest.new(step_mode: Matter::Cluster::ColorControl::StepMode::Down, step_size: (40).to_u8, transition_time: (0).to_u8))

      cluster.current_saturation.should eq(60_u8)
    end

    it "clamps saturation to max (254)" do
      cluster = build(Matter::Cluster::ColorControl, current_saturation: 240_u8)

      invoke(cluster, Matter::Cluster::ColorControl::CMD_STEP_SATURATION, Matter::Cluster::ColorControl::StepSaturationRequest.new(step_mode: Matter::Cluster::ColorControl::StepMode::Up, step_size: (50).to_u8, transition_time: (0).to_u8))

      cluster.current_saturation.should eq(254_u8)
    end

    it "clamps saturation to min (0)" do
      cluster = build(Matter::Cluster::ColorControl, current_saturation: 10_u8)

      invoke(cluster, Matter::Cluster::ColorControl::CMD_STEP_SATURATION, Matter::Cluster::ColorControl::StepSaturationRequest.new(step_mode: Matter::Cluster::ColorControl::StepMode::Down, step_size: (50).to_u8, transition_time: (0).to_u8))

      cluster.current_saturation.should eq(0_u8)
    end
  end

  describe "hue and saturation combined" do
    it "executes MoveToHueAndSaturation command" do
      cluster = build(Matter::Cluster::ColorControl)

      # MoveToHueAndSaturation(hue=180, saturation=220, ...)
      result = invoke(cluster, Matter::Cluster::ColorControl::CMD_MOVE_TO_HUE_AND_SATURATION, Matter::Cluster::ColorControl::MoveToHueAndSaturationRequest.new(hue: (180).to_u8, saturation: (220).to_u8, transition_time: (0).to_u16))

      result.as(Matter::InteractionModel::Status).success?.should be_true
      cluster.current_hue.should eq(180_u8)
      cluster.current_saturation.should eq(220_u8)
      cluster.color_mode.should eq(Matter::Cluster::ColorControl::ColorMode::CurrentHueAndCurrentSaturation)
    end
  end

  describe "XY color commands" do
    it "executes MoveToColor command" do
      cluster = build(Matter::Cluster::ColorControl)

      # MoveToColor(x=32768, y=32768, ...)

      result = invoke(cluster, Matter::Cluster::ColorControl::CMD_MOVE_TO_COLOR, Matter::Cluster::ColorControl::MoveToColorRequest.new(x: 32768_u16, y: 32768_u16, transition_time: (0).to_u16))

      result.as(Matter::InteractionModel::Status).success?.should be_true
      cluster.current_x.should eq(32768_u16)
      cluster.current_y.should eq(32768_u16)
      cluster.color_mode.should eq(Matter::Cluster::ColorControl::ColorMode::CurrentXAndCurrentY)
    end

    it "executes StepColor command" do
      cluster = build(Matter::Cluster::ColorControl,
        current_x: 30000_u16,
        current_y: 30000_u16
      )

      # StepColor(step_x=1000, step_y=-500, ...)

      invoke(cluster, Matter::Cluster::ColorControl::CMD_STEP_COLOR, Matter::Cluster::ColorControl::StepColorRequest.new(x: 1000_i16, y: -500_i16, transition_time: (0).to_u16))

      cluster.current_x.should eq(31000_u16)
      cluster.current_y.should eq(29500_u16)
    end

    it "clamps XY to valid range" do
      cluster = build(Matter::Cluster::ColorControl,
        current_x: 65000_u16,
        current_y: 1000_u16
      )

      # Try to step beyond max

      invoke(cluster, Matter::Cluster::ColorControl::CMD_STEP_COLOR, Matter::Cluster::ColorControl::StepColorRequest.new(x: 2000_i16, y: -2000_i16, transition_time: (0).to_u16))

      cluster.current_x.should eq(Matter::Cluster::ColorControl::CHROMATICITY_MAX) # XML bound
      cluster.current_y.should eq(0_u16)                                           # Clamped to min
    end
  end

  describe "color temperature commands" do
    it "executes MoveToColorTemperature command" do
      cluster = build(Matter::Cluster::ColorControl, color_temperature_mireds: 200_u16)

      # MoveToColorTemperature(mireds=300, ...)

      result = invoke(cluster, Matter::Cluster::ColorControl::CMD_MOVE_TO_COLOR_TEMPERATURE, Matter::Cluster::ColorControl::MoveToColorTemperatureRequest.new(color_temperature_mireds: 300_u16, transition_time: (0).to_u16))

      result.as(Matter::InteractionModel::Status).success?.should be_true
      cluster.color_temperature_mireds.should eq(300_u16)
      cluster.color_mode.should eq(Matter::Cluster::ColorControl::ColorMode::ColorTemperatureMireds)
    end

    it "executes StepColorTemperature Up command" do
      cluster = build(Matter::Cluster::ColorControl, color_temperature_mireds: 300_u16)

      # StepColorTemperature(mode=Up, step_size=50, ...)

      invoke(cluster, Matter::Cluster::ColorControl::CMD_STEP_COLOR_TEMPERATURE, Matter::Cluster::ColorControl::StepColorTemperatureRequest.new(step_mode: Matter::Cluster::ColorControl::StepMode::Up, step_size: 50_u16, transition_time: (0).to_u16, color_temperature_minimum_mireds: (0).to_u16, color_temperature_maximum_mireds: (0).to_u16))

      cluster.color_temperature_mireds.should eq(350_u16)
    end

    it "executes StepColorTemperature Down command" do
      cluster = build(Matter::Cluster::ColorControl, color_temperature_mireds: 300_u16)

      # StepColorTemperature(mode=Down, step_size=50, ...)

      invoke(cluster, Matter::Cluster::ColorControl::CMD_STEP_COLOR_TEMPERATURE, Matter::Cluster::ColorControl::StepColorTemperatureRequest.new(step_mode: Matter::Cluster::ColorControl::StepMode::Down, step_size: 50_u16, transition_time: (0).to_u16, color_temperature_minimum_mireds: (0).to_u16, color_temperature_maximum_mireds: (0).to_u16))

      cluster.color_temperature_mireds.should eq(250_u16)
    end

    it "clamps to physical min mireds" do
      cluster = build(Matter::Cluster::ColorControl,
        color_temperature_mireds: 150_u16,
        color_temp_physical_min_mireds: 147_u16
      )

      # Try to go below min

      invoke(cluster, Matter::Cluster::ColorControl::CMD_MOVE_TO_COLOR_TEMPERATURE, Matter::Cluster::ColorControl::MoveToColorTemperatureRequest.new(color_temperature_mireds: 100_u16, transition_time: (0).to_u16))

      cluster.color_temperature_mireds.should eq(147_u16) # Clamped to min
    end

    it "clamps to physical max mireds" do
      cluster = build(Matter::Cluster::ColorControl,
        color_temperature_mireds: 450_u16,
        color_temp_physical_max_mireds: 500_u16
      )

      # Try to go above max

      invoke(cluster, Matter::Cluster::ColorControl::CMD_MOVE_TO_COLOR_TEMPERATURE, Matter::Cluster::ColorControl::MoveToColorTemperatureRequest.new(color_temperature_mireds: 600_u16, transition_time: (0).to_u16))

      cluster.color_temperature_mireds.should eq(500_u16) # Clamped to max
    end
  end

  describe "enhanced hue commands" do
    it "executes EnhancedMoveToHue command" do
      cluster = build(Matter::Cluster::ColorControl,
        feature_map: Matter::Cluster::ColorControl::Feature::HueSaturation |
                     Matter::Cluster::ColorControl::Feature::EnhancedHue
      )

      # EnhancedMoveToHue(enhanced_hue=32768, ...)

      result = invoke(cluster, Matter::Cluster::ColorControl::CMD_ENHANCED_MOVE_TO_HUE, Matter::Cluster::ColorControl::EnhancedMoveToHueRequest.new(enhanced_hue: 32768_u16, direction: Matter::Cluster::ColorControl::Direction::ShortestDistance, transition_time: (0).to_u16))

      result.as(Matter::InteractionModel::Status).success?.should be_true
      cluster.enhanced_current_hue.should eq(32768_u16)
      cluster.current_hue.should eq(128_u8) # High byte
      cluster.enhanced_color_mode.should eq(Matter::Cluster::ColorControl::EnhancedColorMode::EnhancedCurrentHueAndCurrentSaturation)
    end

    it "executes EnhancedStepHue Up command" do
      cluster = build(Matter::Cluster::ColorControl,
        feature_map: Matter::Cluster::ColorControl::Feature::HueSaturation |
                     Matter::Cluster::ColorControl::Feature::EnhancedHue,
        current_hue: 100_u8
      )

      initial_enhanced_hue = cluster.enhanced_current_hue

      # EnhancedStepHue(mode=Up, step_size=1000, ...)

      invoke(cluster, Matter::Cluster::ColorControl::CMD_ENHANCED_STEP_HUE, Matter::Cluster::ColorControl::EnhancedStepHueRequest.new(step_mode: Matter::Cluster::ColorControl::StepMode::Up, step_size: 1000_u16, transition_time: (0).to_u16))

      cluster.enhanced_current_hue.should eq(initial_enhanced_hue + 1000)
    end

    it "wraps enhanced hue around 65536" do
      cluster = build(Matter::Cluster::ColorControl,
        feature_map: Matter::Cluster::ColorControl::Feature::HueSaturation |
                     Matter::Cluster::ColorControl::Feature::EnhancedHue
      )

      # Set to near max
      invoke(cluster, Matter::Cluster::ColorControl::CMD_ENHANCED_MOVE_TO_HUE, Matter::Cluster::ColorControl::EnhancedMoveToHueRequest.new(enhanced_hue: 65500_u16, direction: Matter::Cluster::ColorControl::Direction::ShortestDistance, transition_time: (0).to_u16))

      # Step up by 100 should wrap
      invoke(cluster, Matter::Cluster::ColorControl::CMD_ENHANCED_STEP_HUE, Matter::Cluster::ColorControl::EnhancedStepHueRequest.new(step_mode: Matter::Cluster::ColorControl::StepMode::Up, step_size: 100_u16, transition_time: (0).to_u16))

      cluster.enhanced_current_hue.should eq(64_u16) # Wrapped
    end

    it "executes EnhancedMoveToHueAndSaturation command" do
      cluster = build(Matter::Cluster::ColorControl,
        feature_map: Matter::Cluster::ColorControl::Feature::HueSaturation |
                     Matter::Cluster::ColorControl::Feature::EnhancedHue
      )

      # EnhancedMoveToHueAndSaturation(enhanced_hue=40000, saturation=200, ...)

      result = invoke(cluster, Matter::Cluster::ColorControl::CMD_ENHANCED_MOVE_TO_HUE_AND_SATURATION, Matter::Cluster::ColorControl::EnhancedMoveToHueAndSaturationRequest.new(enhanced_hue: 40000_u16, saturation: 200_u8, transition_time: (0).to_u16))

      result.as(Matter::InteractionModel::Status).success?.should be_true
      cluster.enhanced_current_hue.should eq(40000_u16)
      cluster.current_saturation.should eq(200_u8)
      cluster.current_hue.should eq(156_u8) # 40000 >> 8
    end
  end

  describe "color mode tracking" do
    it "sets color mode to HS when changing hue" do
      cluster = build(Matter::Cluster::ColorControl,
        color_mode: Matter::Cluster::ColorControl::ColorMode::ColorTemperatureMireds
      )

      invoke(cluster, Matter::Cluster::ColorControl::CMD_MOVE_TO_HUE, Matter::Cluster::ColorControl::MoveToHueRequest.new(hue: (100).to_u8, direction: Matter::Cluster::ColorControl::Direction::ShortestDistance, transition_time: (0).to_u16))

      cluster.color_mode.should eq(Matter::Cluster::ColorControl::ColorMode::CurrentHueAndCurrentSaturation)
    end

    it "sets color mode to XY when changing color" do
      cluster = build(Matter::Cluster::ColorControl,
        color_mode: Matter::Cluster::ColorControl::ColorMode::CurrentHueAndCurrentSaturation
      )

      invoke(cluster, Matter::Cluster::ColorControl::CMD_MOVE_TO_COLOR, Matter::Cluster::ColorControl::MoveToColorRequest.new(x: 30000_u16, y: 30000_u16, transition_time: (0).to_u16))

      cluster.color_mode.should eq(Matter::Cluster::ColorControl::ColorMode::CurrentXAndCurrentY)
    end

    it "sets color mode to CT when changing temperature" do
      cluster = build(Matter::Cluster::ColorControl,
        color_mode: Matter::Cluster::ColorControl::ColorMode::CurrentXAndCurrentY
      )

      invoke(cluster, Matter::Cluster::ColorControl::CMD_MOVE_TO_COLOR_TEMPERATURE, Matter::Cluster::ColorControl::MoveToColorTemperatureRequest.new(color_temperature_mireds: 300_u16, transition_time: (0).to_u16))

      cluster.color_mode.should eq(Matter::Cluster::ColorControl::ColorMode::ColorTemperatureMireds)
    end
  end

  describe "callbacks" do
    it "calls callback when color changes" do
      cluster = build(Matter::Cluster::ColorControl, current_hue: 50_u8)

      callback_called = false
      cluster.on_color_changed do
        callback_called = true
      end

      invoke(cluster, Matter::Cluster::ColorControl::CMD_MOVE_TO_HUE, Matter::Cluster::ColorControl::MoveToHueRequest.new(hue: (100).to_u8, direction: Matter::Cluster::ColorControl::Direction::ShortestDistance, transition_time: (0).to_u16))

      callback_called.should be_true
    end

    it "does not call callback if color doesn't change" do
      cluster = build(Matter::Cluster::ColorControl, current_hue: 100_u8)

      callback_called = false
      cluster.on_color_changed do
        callback_called = true
      end

      # Move to same hue
      invoke(cluster, Matter::Cluster::ColorControl::CMD_MOVE_TO_HUE, Matter::Cluster::ColorControl::MoveToHueRequest.new(hue: (100).to_u8, direction: Matter::Cluster::ColorControl::Direction::ShortestDistance, transition_time: (0).to_u16))

      callback_called.should be_false
    end
  end

  describe "data versioning" do
    it "increments version when color changes" do
      cluster = build(Matter::Cluster::ColorControl, current_hue: 50_u8)

      initial_version = cluster.data_version

      invoke(cluster, Matter::Cluster::ColorControl::CMD_MOVE_TO_HUE, Matter::Cluster::ColorControl::MoveToHueRequest.new(hue: (100).to_u8, direction: Matter::Cluster::ColorControl::Direction::ShortestDistance, transition_time: (0).to_u16))

      cluster.data_version.should be > initial_version
    end

    it "does not increment version if color unchanged" do
      cluster = build(Matter::Cluster::ColorControl, current_hue: 100_u8)

      initial_version = cluster.data_version

      # Move to same hue
      invoke(cluster, Matter::Cluster::ColorControl::CMD_MOVE_TO_HUE, Matter::Cluster::ColorControl::MoveToHueRequest.new(hue: (100).to_u8, direction: Matter::Cluster::ColorControl::Direction::ShortestDistance, transition_time: (0).to_u16))

      cluster.data_version.should eq(initial_version) # No increment
    end
  end

  describe "utility methods" do
    it "converts color temperature to Kelvin" do
      cluster = build(Matter::Cluster::ColorControl, color_temperature_mireds: 250_u16)

      kelvin = cluster.color_temperature_kelvin
      kelvin.should eq(4000_u32) # 1,000,000 / 250
    end

    it "sets color temperature from Kelvin" do
      cluster = build(Matter::Cluster::ColorControl)

      cluster.color_temperature_kelvin = 4000_u32

      cluster.color_temperature_mireds.should eq(250_u16)
    end
  end

  describe "reading attributes" do
    it "reads CurrentHue attribute" do
      cluster = build(Matter::Cluster::ColorControl, current_hue: 127_u8)

      result = read_tlv(cluster, Matter::Cluster::ColorControl::ATTR_CURRENT_HUE)
      result.should be_a(TLV::Any)
      result.value.should eq(127_u8)
    end

    it "reads CurrentSaturation attribute" do
      cluster = build(Matter::Cluster::ColorControl, current_saturation: 200_u8)

      result = read_tlv(cluster, Matter::Cluster::ColorControl::ATTR_CURRENT_SATURATION)
      result.should be_a(TLV::Any)
      result.value.should eq(200_u8)
    end

    it "reads ColorTemperatureMireds attribute" do
      cluster = build(Matter::Cluster::ColorControl, color_temperature_mireds: 350_u16)

      result = read_tlv(cluster, Matter::Cluster::ColorControl::ATTR_COLOR_TEMPERATURE_MIREDS)
      result.should be_a(TLV::Any)
      result.value.should eq(350_u16)
    end

    it "reads ColorMode attribute" do
      cluster = build(Matter::Cluster::ColorControl)

      result = read_tlv(cluster, Matter::Cluster::ColorControl::ATTR_COLOR_MODE)
      result.should be_a(TLV::Any)
      result.value.should eq(Matter::Cluster::ColorControl::ColorMode::CurrentHueAndCurrentSaturation.value)
    end
  end

  describe "practical scenarios" do
    it "creates warm white light (2700K)" do
      light = build(Matter::Cluster::ColorControl)

      # 2700K = 370 mireds
      light.color_temperature_kelvin = 2700_u32

      light.color_temperature_mireds.should eq(370_u16)
      light.color_temperature_kelvin.should eq(2702_u32) # Close to 2700
    end

    it "creates cool white light (6500K)" do
      light = build(Matter::Cluster::ColorControl)

      # 6500K = 154 mireds
      light.color_temperature_kelvin = 6500_u32

      light.color_temperature_mireds.should eq(153_u16)
      light.color_temperature_kelvin.should be_close(6500_u32, 100_u32)
    end

    it "creates red color (hue=0, sat=254)" do
      light = build(Matter::Cluster::ColorControl)

      invoke(light, Matter::Cluster::ColorControl::CMD_MOVE_TO_HUE_AND_SATURATION, Matter::Cluster::ColorControl::MoveToHueAndSaturationRequest.new(hue: (0).to_u8, saturation: (254).to_u8, transition_time: (0).to_u16))

      light.current_hue.should eq(0_u8)
      light.current_saturation.should eq(254_u8)
      light.color_mode.should eq(Matter::Cluster::ColorControl::ColorMode::CurrentHueAndCurrentSaturation)
    end

    it "creates blue color (hue=170, sat=254)" do
      light = build(Matter::Cluster::ColorControl)

      invoke(light, Matter::Cluster::ColorControl::CMD_MOVE_TO_HUE_AND_SATURATION, Matter::Cluster::ColorControl::MoveToHueAndSaturationRequest.new(hue: (170).to_u8, saturation: (254).to_u8, transition_time: (0).to_u16))

      light.current_hue.should eq(170_u8)
      light.current_saturation.should eq(254_u8)
    end

    it "gradually transitions through color wheel" do
      light = build(Matter::Cluster::ColorControl, current_hue: 0_u8)

      # Step through hues
      10.times do |_|
        invoke(light, Matter::Cluster::ColorControl::CMD_STEP_HUE, Matter::Cluster::ColorControl::StepHueRequest.new(step_mode: Matter::Cluster::ColorControl::StepMode::Up, step_size: (25).to_u8, transition_time: (0).to_u8))
      end

      light.current_hue.should eq(250_u8) # 0 + (25 * 10)
    end
  end

  describe "error handling" do
    it "returns error for unsupported command" do
      cluster = build(Matter::Cluster::ColorControl)

      result = invoke(cluster, 0x99_u32)
      result.should be_a(Matter::InteractionModel::Status)
      result.as(Matter::InteractionModel::Status).status.should eq(
        Matter::InteractionModel::StatusCode::UnsupportedCommand
      )
    end

    it "returns error for command with insufficient data" do
      cluster = build(Matter::Cluster::ColorControl)

      # MoveToColor needs at least 4 bytes
      result = invoke(cluster, Matter::Cluster::ColorControl::CMD_MOVE_TO_COLOR, TLV::Any.new({0_u8 => TLV::Any.new(1_u16)} of TLV::TagId => TLV::Any))

      result.should be_a(Matter::InteractionModel::Status)
      result.as(Matter::InteractionModel::Status).status.should eq(
        Matter::InteractionModel::StatusCode::InvalidCommand
      )
    end
  end
end
