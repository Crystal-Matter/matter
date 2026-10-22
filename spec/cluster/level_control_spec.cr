require "../spec_helper"
require "../../src/matter/cluster/level_control"

# Note: Time-based transition tests from matter.js behavioral tests
# (packages/node/test/behaviors/level-control/LevelControlServerTest.ts)
# require transition manager support with gradual level updates over time.
# Current implementation performs instant level changes.
# These tests can be added when transition support is implemented.

describe Matter::Cluster::LevelControl do
  describe "initialization" do
    it "creates level control cluster" do
      cluster = build(Matter::Cluster::LevelControl)

      cluster.cluster_id.id.should eq(0x0008_u32)
      cluster.name.should eq("LevelControl")
      cluster.current_level.should eq(1_u8)
      cluster.min_level.should eq(1_u8)
      cluster.max_level.should eq(254_u8)
    end

    it "initializes with custom values" do
      cluster = build(Matter::Cluster::LevelControl,
        current_level: 127_u8,
        min_level: 10_u8,
        max_level: 200_u8,
        feature_map: Matter::Cluster::LevelControl::Feature::None
      )

      cluster.current_level.should eq(127_u8)
      cluster.min_level.should eq(10_u8)
      cluster.max_level.should eq(200_u8)
    end
  end

  describe "attributes" do
    it "has required attributes" do
      cluster = build(Matter::Cluster::LevelControl)

      attributes = cluster.attributes
      attributes.should_not be_empty
      attributes.size.should be >= 3

      current_level = attributes.find { |attr| attr.id.id == Matter::Cluster::LevelControl::ATTR_CURRENT_LEVEL }
      current_level.should_not be_nil
      current_level_attr = current_level.as(Matter::Cluster::AttributeMetadata)
      current_level_attr.name.should eq("currentLevel")
      current_level_attr.writable?.should be_false

      min_level = attributes.find { |attr| attr.id.id == Matter::Cluster::LevelControl::ATTR_MIN_LEVEL }
      min_level.should_not be_nil

      max_level = attributes.find { |attr| attr.id.id == Matter::Cluster::LevelControl::ATTR_MAX_LEVEL }
      max_level.should_not be_nil
    end

    it "reads CurrentLevel attribute" do
      cluster = build(Matter::Cluster::LevelControl, current_level: 100_u8)

      read(cluster, Matter::Cluster::LevelControl::ATTR_CURRENT_LEVEL).should eq(100_u8)
    end

    it "reads MinLevel attribute" do
      cluster = build(Matter::Cluster::LevelControl, min_level: 5_u8,
        feature_map: Matter::Cluster::LevelControl::Feature::None)

      read(cluster, Matter::Cluster::LevelControl::ATTR_MIN_LEVEL).should eq(5_u8)
    end

    it "reads MaxLevel attribute" do
      cluster = build(Matter::Cluster::LevelControl, max_level: 200_u8,
        feature_map: Matter::Cluster::LevelControl::Feature::None)

      read(cluster, Matter::Cluster::LevelControl::ATTR_MAX_LEVEL).should eq(200_u8)
    end

    it "reads RemainingTime attribute" do
      cluster = build(Matter::Cluster::LevelControl)

      read(cluster, Matter::Cluster::LevelControl::ATTR_REMAINING_TIME).should eq(0_u16)
    end
  end

  describe "commands" do
    it "has required commands" do
      cluster = build(Matter::Cluster::LevelControl)

      commands = cluster.commands
      commands.size.should be >= 4

      move_to_level = commands.find { |cmd| cmd.id.id == Matter::Cluster::LevelControl::CMD_MOVE_TO_LEVEL }
      move_to_level.should_not be_nil
      move_to_level.as(Matter::Cluster::CommandMetadata).name.should eq("moveToLevel")

      move = commands.find { |cmd| cmd.id.id == Matter::Cluster::LevelControl::CMD_MOVE }
      move.should_not be_nil

      step = commands.find { |cmd| cmd.id.id == Matter::Cluster::LevelControl::CMD_STEP }
      step.should_not be_nil

      stop = commands.find { |cmd| cmd.id.id == Matter::Cluster::LevelControl::CMD_STOP }
      stop.should_not be_nil
    end

    it "executes MoveToLevel command" do
      cluster = build(Matter::Cluster::LevelControl, current_level: 0_u8,
        min_level: 0_u8, feature_map: Matter::Cluster::LevelControl::Feature::None)

      cluster.current_level.should eq(0_u8)

      request = Matter::Cluster::LevelControl::MoveToLevelRequest.new(
        level: 200_u8,
        transition_time: 0_u16,
        mask: 0_u8,
        override: 0_u8
      )
      result = invoke(cluster,
        Matter::Cluster::LevelControl::CMD_MOVE_TO_LEVEL,
        request
      )

      result.should be_a(Matter::InteractionModel::Status)
      result.as(Matter::InteractionModel::Status).success?.should be_true
      cluster.current_level.should eq(200_u8)
    end

    it "executes Move command" do
      cluster = build(Matter::Cluster::LevelControl, current_level: 100_u8)

      request = Matter::Cluster::LevelControl::MoveRequest.new(
        move_mode: Matter::Cluster::LevelControl::MoveMode::Up,
        rate: 10_u8,
        mask: 0_u8,
        override: 0_u8
      )
      result = invoke(cluster,
        Matter::Cluster::LevelControl::CMD_MOVE,
        request
      )

      result.should be_a(Matter::InteractionModel::Status)
      result.as(Matter::InteractionModel::Status).success?.should be_true
    end

    it "executes Step command" do
      cluster = build(Matter::Cluster::LevelControl, current_level: 100_u8)

      request = Matter::Cluster::LevelControl::StepRequest.new(
        step_mode: Matter::Cluster::LevelControl::StepMode::Up,
        step_size: 20_u8,
        transition_time: 0_u16,
        mask: 0_u8,
        override: 0_u8
      )
      result = invoke(cluster,
        Matter::Cluster::LevelControl::CMD_STEP,
        request
      )

      result.should be_a(Matter::InteractionModel::Status)
      result.as(Matter::InteractionModel::Status).success?.should be_true
      cluster.current_level.should eq(120_u8)
    end

    it "executes Stop command" do
      cluster = build(Matter::Cluster::LevelControl)

      request = Matter::Cluster::LevelControl::StopRequest.new(
        mask: 0_u8,
        override: 0_u8
      )
      result = invoke(cluster,
        Matter::Cluster::LevelControl::CMD_STOP,
        request
      )

      result.should be_a(Matter::InteractionModel::Status)
      result.as(Matter::InteractionModel::Status).success?.should be_true
    end
  end

  describe "MoveMode enum" do
    it "has move modes" do
      Matter::Cluster::LevelControl::MoveMode::Up.value.should eq(0)
      Matter::Cluster::LevelControl::MoveMode::Down.value.should eq(1)
    end
  end

  describe "StepMode enum" do
    it "has step modes" do
      Matter::Cluster::LevelControl::StepMode::Up.value.should eq(0)
      Matter::Cluster::LevelControl::StepMode::Down.value.should eq(1)
    end
  end

  describe "level boundaries" do
    it "clamps level to min boundary" do
      cluster = build(Matter::Cluster::LevelControl,
        current_level: 100_u8,
        min_level: 50_u8,
        feature_map: Matter::Cluster::LevelControl::Feature::None
      )

      # Try to move below min
      request = Matter::Cluster::LevelControl::MoveToLevelRequest.new(
        level: 10_u8,
        transition_time: 0_u16,
        mask: 0_u8,
        override: 0_u8
      )
      invoke(cluster,
        Matter::Cluster::LevelControl::CMD_MOVE_TO_LEVEL,
        request
      )

      cluster.current_level.should eq(50_u8) # Clamped to min
    end

    it "clamps level to max boundary" do
      cluster = build(Matter::Cluster::LevelControl,
        current_level: 100_u8,
        max_level: 200_u8,
        feature_map: Matter::Cluster::LevelControl::Feature::None
      )

      # Try to move above max
      request = Matter::Cluster::LevelControl::MoveToLevelRequest.new(
        level: 250_u8,
        transition_time: 0_u16,
        mask: 0_u8,
        override: 0_u8
      )
      invoke(cluster,
        Matter::Cluster::LevelControl::CMD_MOVE_TO_LEVEL,
        request
      )

      cluster.current_level.should eq(200_u8) # Clamped to max
    end
  end

  describe "step command boundaries" do
    it "steps up within range" do
      cluster = build(Matter::Cluster::LevelControl, current_level: 100_u8)

      invoke(cluster,
        Matter::Cluster::LevelControl::CMD_STEP,
        Matter::Cluster::LevelControl::StepRequest.new(
          step_mode: Matter::Cluster::LevelControl::StepMode::Up,
          step_size: 50_u8,
          transition_time: 0_u16,
          mask: 0_u8,
          override: 0_u8
        )
      )

      cluster.current_level.should eq(150_u8)
    end

    it "steps down within range" do
      cluster = build(Matter::Cluster::LevelControl, current_level: 100_u8)

      invoke(cluster,
        Matter::Cluster::LevelControl::CMD_STEP,
        Matter::Cluster::LevelControl::StepRequest.new(
          step_mode: Matter::Cluster::LevelControl::StepMode::Down,
          step_size: 30_u8,
          transition_time: 0_u16,
          mask: 0_u8,
          override: 0_u8
        )
      )

      cluster.current_level.should eq(70_u8)
    end

    it "clamps step up to max" do
      cluster = build(Matter::Cluster::LevelControl,
        current_level: 240_u8,
        max_level: 254_u8
      )

      invoke(cluster,
        Matter::Cluster::LevelControl::CMD_STEP,
        Matter::Cluster::LevelControl::StepRequest.new(
          step_mode: Matter::Cluster::LevelControl::StepMode::Up,
          step_size: 50_u8,
          transition_time: 0_u16,
          mask: 0_u8,
          override: 0_u8
        )
      )

      cluster.current_level.should eq(254_u8) # Clamped to max
    end

    it "clamps step down to min" do
      cluster = build(Matter::Cluster::LevelControl,
        current_level: 10_u8,
        min_level: 0_u8,
        feature_map: Matter::Cluster::LevelControl::Feature::None
      )

      invoke(cluster,
        Matter::Cluster::LevelControl::CMD_STEP,
        Matter::Cluster::LevelControl::StepRequest.new(
          step_mode: Matter::Cluster::LevelControl::StepMode::Down,
          step_size: 50_u8,
          transition_time: 0_u16,
          mask: 0_u8,
          override: 0_u8
        )
      )

      cluster.current_level.should eq(0_u8) # Clamped to min
    end
  end

  describe "callbacks" do
    it "calls level changed callback" do
      cluster = build(Matter::Cluster::LevelControl, current_level: 50_u8)

      old_level = 0_u8
      new_level = 0_u8

      cluster.on_level_changed do |old, new|
        old_level = old
        new_level = new
      end

      invoke(cluster,
        Matter::Cluster::LevelControl::CMD_MOVE_TO_LEVEL,
        Matter::Cluster::LevelControl::MoveToLevelRequest.new(
          level: 100_u8,
          transition_time: 0_u16,
          mask: 0_u8,
          override: 0_u8
        )
      )

      old_level.should eq(50_u8)
      new_level.should eq(100_u8)
    end
  end

  describe "data versioning" do
    it "increments version when level changes" do
      cluster = build(Matter::Cluster::LevelControl, current_level: 50_u8)

      initial_version = cluster.data_version

      invoke(cluster,
        Matter::Cluster::LevelControl::CMD_MOVE_TO_LEVEL,
        Matter::Cluster::LevelControl::MoveToLevelRequest.new(
          level: 100_u8,
          transition_time: 0_u16,
          mask: 0_u8,
          override: 0_u8
        )
      )

      cluster.data_version.should eq(initial_version + 1)
    end
  end

  describe "persistence" do
    it "saves and restores state" do
      cluster = build(Matter::Cluster::LevelControl,
        current_level: 50_u8,
        min_level: 1_u8,
        max_level: 254_u8,
        feature_map: Matter::Cluster::LevelControl::Feature::OnOff |
                     Matter::Cluster::LevelControl::Feature::Lighting |
                     Matter::Cluster::LevelControl::Feature::Frequency
      )

      cluster.on_level = 42_u8
      cluster.options = 3_u8
      cluster.remaining_time = 9_u16
      cluster.on_off_transition_time = 5_u16
      cluster.on_transition_time = 7_u16
      cluster.off_transition_time = 8_u16
      cluster.default_move_rate = 10_u8
      cluster.start_up_current_level = 12_u8
      cluster.current_frequency = 111_u16
      cluster.min_frequency = 100_u16
      cluster.max_frequency = 120_u16
      cluster.data_version = 12_u32

      saved = cluster.save_state.as(Matter::Storage::Document)
      saved["current_level"].should eq(50_i64)
      saved["on_level"].should eq(42_i64)
      saved["data_version"].should eq(12_i64)

      restored = build(Matter::Cluster::LevelControl,
        current_level: 1_u8,
        min_level: 1_u8,
        max_level: 254_u8,
        feature_map: Matter::Cluster::LevelControl::Feature::OnOff |
                     Matter::Cluster::LevelControl::Feature::Lighting |
                     Matter::Cluster::LevelControl::Feature::Frequency
      )
      restored.restore_state(saved)

      restored.current_level.should eq(50_u8)
      restored.min_level.should eq(1_u8)
      restored.max_level.should eq(254_u8)
      restored.on_level.should eq(42_u8)
      restored.options.should eq(3_u8)
      restored.remaining_time.should eq(0_u16)
      restored.on_off_transition_time.should eq(5_u16)
      restored.on_transition_time.should eq(7_u16)
      restored.off_transition_time.should eq(8_u16)
      restored.default_move_rate.should eq(10_u8)
      restored.start_up_current_level.should eq(12_u8)
      restored.current_frequency.should eq(111_u16)
      restored.min_frequency.should eq(100_u16)
      restored.max_frequency.should eq(120_u16)
      restored.data_version.should eq(12_u32)
    end
  end

  describe "OnLevel writes" do
    it "rejects a level outside MinLevel..MaxLevel with ConstraintError" do
      cluster = build(Matter::Cluster::LevelControl, min_level: 10_u8, max_level: 200_u8,
        feature_map: Matter::Cluster::LevelControl::Feature::None)

      expect_status(write(cluster, Matter::Cluster::LevelControl::ATTR_ON_LEVEL, 201_u8), Matter::InteractionModel::StatusCode::ConstraintError)
      expect_status(write(cluster, Matter::Cluster::LevelControl::ATTR_ON_LEVEL, 9_u8), Matter::InteractionModel::StatusCode::ConstraintError)
      cluster.on_level.should be_nil

      expect_success(write(cluster, Matter::Cluster::LevelControl::ATTR_ON_LEVEL, 200_u8))
      cluster.on_level.should eq(200_u8)
    end
  end

  describe "nullable attribute writes" do
    nullable_attributes = {
      Matter::Cluster::LevelControl::ATTR_ON_LEVEL               => 42_u8,
      Matter::Cluster::LevelControl::ATTR_ON_TRANSITION_TIME     => 7_u16,
      Matter::Cluster::LevelControl::ATTR_OFF_TRANSITION_TIME    => 8_u16,
      Matter::Cluster::LevelControl::ATTR_DEFAULT_MOVE_RATE      => 10_u8,
      Matter::Cluster::LevelControl::ATTR_START_UP_CURRENT_LEVEL => 12_u8,
    }

    nullable_attributes.each do |attribute_id, populated|
      it "accepts null for attribute 0x#{attribute_id.to_s(16)}" do
        cluster = build(Matter::Cluster::LevelControl,
          feature_map: Matter::Cluster::LevelControl::Feature::OnOff | Matter::Cluster::LevelControl::Feature::Lighting)
        expect_success(write(cluster, attribute_id, populated))
        read(cluster, attribute_id).should eq(populated)

        changes = capture_changes(cluster) do
          version_delta(cluster) { expect_success(write(cluster, attribute_id, nil)) }.should eq(1_i64)
        end
        changes.map(&.attribute).should eq([attribute_id])
        read(cluster, attribute_id).should be_nil
      end
    end
  end

  describe "error handling" do
    it "returns error for unsupported attribute" do
      cluster = build(Matter::Cluster::LevelControl)

      read_status(cluster, 0x9999_u32).status.should eq(
        Matter::InteractionModel::StatusCode::UnsupportedAttribute
      )
    end

    it "returns error for unsupported command" do
      cluster = build(Matter::Cluster::LevelControl)

      result = invoke(cluster, 0x99_u32, Bytes.new(0))
      result.should be_a(Matter::InteractionModel::Status)
      result.as(Matter::InteractionModel::Status).status.should eq(
        Matter::InteractionModel::StatusCode::UnsupportedCommand
      )
    end
  end

  describe "practical scenarios" do
    it "dims a light from full to half" do
      light = build(Matter::Cluster::LevelControl, current_level: 254_u8)

      invoke(light,
        Matter::Cluster::LevelControl::CMD_MOVE_TO_LEVEL,
        Matter::Cluster::LevelControl::MoveToLevelRequest.new(
          level: 127_u8,
          transition_time: 0_u16,
          mask: 0_u8,
          override: 0_u8
        )
      )

      light.current_level.should eq(127_u8)
    end

    it "brightens a light in repeated steps" do
      light = build(Matter::Cluster::LevelControl, current_level: 50_u8)

      5.times do
        invoke(light,
          Matter::Cluster::LevelControl::CMD_STEP,
          Matter::Cluster::LevelControl::StepRequest.new(
            step_mode: Matter::Cluster::LevelControl::StepMode::Up,
            step_size: 10_u8,
            transition_time: 0_u16,
            mask: 0_u8,
            override: 0_u8
          )
        )
      end

      light.current_level.should eq(100_u8)
    end

    it "fades out to minimum" do
      light = build(Matter::Cluster::LevelControl,
        current_level: 200_u8,
        min_level: 10_u8,
        feature_map: Matter::Cluster::LevelControl::Feature::None
      )

      invoke(light,
        Matter::Cluster::LevelControl::CMD_MOVE_TO_LEVEL,
        Matter::Cluster::LevelControl::MoveToLevelRequest.new(
          level: 10_u8,
          transition_time: 0_u16,
          mask: 0_u8,
          override: 0_u8
        )
      )

      light.current_level.should eq(10_u8)
    end
  end
end
