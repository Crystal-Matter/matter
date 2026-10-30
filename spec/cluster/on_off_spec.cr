require "../spec_helper"
require "../../src/matter/cluster/on_off"

describe Matter::Cluster::OnOff do
  it "rejects a command at the cluster boundary before changing state" do
    cluster = build(Matter::Cluster::OnOff)
    cluster.on_before_command = ->(_command : UInt32) {
      raise Matter::ClusterError.new("Participant recovery lease", Matter::InteractionModel::StatusCode::Busy)
    }

    result = cluster.invoke_command(Matter::Cluster::OnOff::CMD_ON)
    result.as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::Busy)
    cluster.on_off?.should be_false
  end

  describe "initialization" do
    it "creates on/off cluster with default off state" do
      cluster = build(Matter::Cluster::OnOff)

      cluster.cluster_id.id.should eq(0x0006_u32)
      cluster.name.should eq("OnOff")
      cluster.on_off?.should be_false
    end

    it "creates on/off cluster with initial on state" do
      cluster = build(Matter::Cluster::OnOff, on_off: true)

      cluster.on_off?.should be_true
    end
  end

  describe "attributes" do
    it "has required OnOff attribute" do
      cluster = build(Matter::Cluster::OnOff)

      attributes = cluster.attributes
      attributes.should_not be_empty

      on_off_attr = attributes.find { |attr| attr.id.id == Matter::Cluster::OnOff::ATTR_ON_OFF }
      on_off_attr.should_not be_nil
      on_off_attribute = on_off_attr.as(Matter::Cluster::AttributeMetadata)
      on_off_attribute.name.should eq("onOff")
      on_off_attribute.type.should eq(:bool)
      on_off_attribute.writable?.should be_false
    end

    it "reads OnOff attribute when off" do
      cluster = build(Matter::Cluster::OnOff, on_off: false)

      read(cluster, Matter::Cluster::OnOff::ATTR_ON_OFF).should be_false
    end

    it "reads OnOff attribute when on" do
      cluster = build(Matter::Cluster::OnOff, on_off: true)

      read(cluster, Matter::Cluster::OnOff::ATTR_ON_OFF).should be_true
    end

    it "rejects writing to read-only OnOff attribute" do
      cluster = build(Matter::Cluster::OnOff)

      status = write(cluster,
        Matter::Cluster::OnOff::ATTR_ON_OFF,
        1_u8
      )

      status.status.should eq(Matter::InteractionModel::StatusCode::UnsupportedWrite)
    end
  end

  describe "commands" do
    it "has required commands" do
      cluster = build(Matter::Cluster::OnOff)

      commands = cluster.commands
      commands.size.should be >= 3

      off_cmd = commands.find { |cmd| cmd.id.id == Matter::Cluster::OnOff::CMD_OFF }
      off_cmd.should_not be_nil
      off_cmd.as(Matter::Cluster::CommandMetadata).name.should eq("off")

      on_cmd = commands.find { |cmd| cmd.id.id == Matter::Cluster::OnOff::CMD_ON }
      on_cmd.should_not be_nil
      on_cmd.as(Matter::Cluster::CommandMetadata).name.should eq("on")

      toggle_cmd = commands.find { |cmd| cmd.id.id == Matter::Cluster::OnOff::CMD_TOGGLE }
      toggle_cmd.should_not be_nil
      toggle_cmd.as(Matter::Cluster::CommandMetadata).name.should eq("toggle")
    end

    describe "Off command" do
      it "turns off when already off" do
        cluster = build(Matter::Cluster::OnOff, on_off: false)

        result = invoke(cluster, Matter::Cluster::OnOff::CMD_OFF, Bytes.new(0))

        result.should be_a(Matter::InteractionModel::Status)
        result.as(Matter::InteractionModel::Status).success?.should be_true
        cluster.on_off?.should be_false
      end

      it "turns off when on" do
        cluster = build(Matter::Cluster::OnOff, on_off: true)

        cluster.on_off?.should be_true

        result = invoke(cluster, Matter::Cluster::OnOff::CMD_OFF, Bytes.new(0))

        result.as(Matter::InteractionModel::Status).success?.should be_true
        cluster.on_off?.should be_false
      end

      it "updates attribute value after Off command" do
        cluster = build(Matter::Cluster::OnOff, on_off: true)

        invoke(cluster, Matter::Cluster::OnOff::CMD_OFF, Bytes.new(0))

        read(cluster, Matter::Cluster::OnOff::ATTR_ON_OFF).should be_false
      end
    end

    describe "On command" do
      it "turns on when already on" do
        cluster = build(Matter::Cluster::OnOff, on_off: true)

        result = invoke(cluster, Matter::Cluster::OnOff::CMD_ON, Bytes.new(0))

        result.as(Matter::InteractionModel::Status).success?.should be_true
        cluster.on_off?.should be_true
      end

      it "turns on when off" do
        cluster = build(Matter::Cluster::OnOff, on_off: false)

        cluster.on_off?.should be_false

        result = invoke(cluster, Matter::Cluster::OnOff::CMD_ON, Bytes.new(0))

        result.as(Matter::InteractionModel::Status).success?.should be_true
        cluster.on_off?.should be_true
      end

      it "updates attribute value after On command" do
        cluster = build(Matter::Cluster::OnOff, on_off: false)

        invoke(cluster, Matter::Cluster::OnOff::CMD_ON, Bytes.new(0))

        read(cluster, Matter::Cluster::OnOff::ATTR_ON_OFF).should be_true
      end
    end

    describe "Toggle command" do
      it "toggles from off to on" do
        cluster = build(Matter::Cluster::OnOff, on_off: false)

        result = invoke(cluster, Matter::Cluster::OnOff::CMD_TOGGLE, Bytes.new(0))

        result.as(Matter::InteractionModel::Status).success?.should be_true
        cluster.on_off?.should be_true
      end

      it "toggles from on to off" do
        cluster = build(Matter::Cluster::OnOff, on_off: true)

        result = invoke(cluster, Matter::Cluster::OnOff::CMD_TOGGLE, Bytes.new(0))

        result.as(Matter::InteractionModel::Status).success?.should be_true
        cluster.on_off?.should be_false
      end

      it "toggles multiple times correctly" do
        cluster = build(Matter::Cluster::OnOff, on_off: false)

        cluster.on_off?.should be_false

        invoke(cluster, Matter::Cluster::OnOff::CMD_TOGGLE, Bytes.new(0))
        cluster.on_off?.should be_true

        invoke(cluster, Matter::Cluster::OnOff::CMD_TOGGLE, Bytes.new(0))
        cluster.on_off?.should be_false

        invoke(cluster, Matter::Cluster::OnOff::CMD_TOGGLE, Bytes.new(0))
        cluster.on_off?.should be_true
      end
    end

    describe "OffWithEffect command" do
      it "executes OffWithEffect command with Lighting feature" do
        cluster = build(Matter::Cluster::OnOff,
          on_off: true,
          feature_map: Matter::Cluster::OnOff::Feature::Lighting
        )

        request = Matter::Cluster::OnOff::OffWithEffectRequest.new(Matter::Cluster::OnOff::EffectIdentifier::DelayedAllOff, 0_u8)
        result = invoke(cluster, Matter::Cluster::OnOff::CMD_OFF_WITH_EFFECT, request)

        result.as(Matter::InteractionModel::Status).success?.should be_true
        cluster.on_off?.should be_false
      end
    end

    describe "OnWithRecallGlobalScene command" do
      it "discards OnWithRecallGlobalScene while GlobalSceneControl is true" do
        cluster = build(Matter::Cluster::OnOff,
          on_off: false,
          feature_map: Matter::Cluster::OnOff::Feature::Lighting
        )

        cluster.global_scene_control?.should be_true
        result = invoke(cluster, Matter::Cluster::OnOff::CMD_ON_WITH_RECALL_GLOBAL_SCENE, Bytes.new(0))

        result.as(Matter::InteractionModel::Status).success?.should be_true
        cluster.on_off?.should be_false
      end
    end

    describe "OnWithTimedOff command" do
      it "executes OnWithTimedOff command with Lighting feature" do
        cluster = build(Matter::Cluster::OnOff,
          on_off: false,
          feature_map: Matter::Cluster::OnOff::Feature::Lighting
        )

        request = Matter::Cluster::OnOff::OnWithTimedOffRequest.new(Matter::Cluster::OnOff::OnOffControl::None, 10_u16, 20_u16)
        result = invoke(cluster, Matter::Cluster::OnOff::CMD_ON_WITH_TIMED_OFF, request)

        result.as(Matter::InteractionModel::Status).success?.should be_true
        cluster.on_off?.should be_true
      end
    end
  end

  describe "callbacks" do
    it "calls callback when turning on" do
      cluster = build(Matter::Cluster::OnOff, on_off: false)

      callback_called = false
      new_state = false

      cluster.on_state_changed do |state|
        callback_called = true
        new_state = state
      end

      invoke(cluster, Matter::Cluster::OnOff::CMD_ON, Bytes.new(0))

      callback_called.should be_true
      new_state.should be_true
    end

    it "calls callback when turning off" do
      cluster = build(Matter::Cluster::OnOff, on_off: true)

      callback_called = false
      new_state = true

      cluster.on_state_changed do |state|
        callback_called = true
        new_state = state
      end

      invoke(cluster, Matter::Cluster::OnOff::CMD_OFF, Bytes.new(0))

      callback_called.should be_true
      new_state.should be_false
    end

    it "calls callback on each toggle" do
      cluster = build(Matter::Cluster::OnOff, on_off: false)

      call_count = 0
      states = [] of Bool

      cluster.on_state_changed do |state|
        call_count += 1
        states << state
      end

      invoke(cluster, Matter::Cluster::OnOff::CMD_TOGGLE, Bytes.new(0))
      invoke(cluster, Matter::Cluster::OnOff::CMD_TOGGLE, Bytes.new(0))
      invoke(cluster, Matter::Cluster::OnOff::CMD_TOGGLE, Bytes.new(0))

      call_count.should eq(3)
      states.should eq([true, false, true])
    end

    it "does not call callback if state doesn't change" do
      cluster = build(Matter::Cluster::OnOff, on_off: true)

      callback_called = false

      cluster.on_state_changed do |_|
        callback_called = true
      end

      # Turn on when already on - state doesn't change
      invoke(cluster, Matter::Cluster::OnOff::CMD_ON, Bytes.new(0))

      callback_called.should be_false
    end

    # Behavioral test migrated from matter.js
    # packages/node/test/behaviors/on-off/OnOffServerTest.ts
    it "properly supports observers on toggle sequence" do
      cluster = build(Matter::Cluster::OnOff, on_off: false)

      observed_values = [] of Bool

      cluster.on_state_changed do |state|
        observed_values << state
      end

      # Toggle twice - should observe [true, false]
      2.times do
        invoke(cluster, Matter::Cluster::OnOff::CMD_TOGGLE, Bytes.new(0))
      end

      observed_values.should eq([true, false])
    end
  end

  describe "data versioning" do
    it "increments version when state changes" do
      cluster = build(Matter::Cluster::OnOff, on_off: false)

      initial_version = cluster.data_version

      invoke(cluster, Matter::Cluster::OnOff::CMD_ON, Bytes.new(0))

      cluster.data_version.should eq(initial_version + 1)
    end

    it "increments version on each state change" do
      cluster = build(Matter::Cluster::OnOff, on_off: false)

      initial_version = cluster.data_version

      invoke(cluster, Matter::Cluster::OnOff::CMD_ON, Bytes.new(0))
      invoke(cluster, Matter::Cluster::OnOff::CMD_OFF, Bytes.new(0))
      invoke(cluster, Matter::Cluster::OnOff::CMD_ON, Bytes.new(0))

      cluster.data_version.should eq(initial_version + 3)
    end

    it "does not increment version if state unchanged" do
      cluster = build(Matter::Cluster::OnOff, on_off: true)

      initial_version = cluster.data_version

      invoke(cluster, Matter::Cluster::OnOff::CMD_ON, Bytes.new(0))

      cluster.data_version.should eq(initial_version)
    end
  end

  describe "error handling" do
    it "returns error for unsupported attribute" do
      cluster = build(Matter::Cluster::OnOff)

      read_status(cluster, 0x9999_u32).status.should eq(
        Matter::InteractionModel::StatusCode::UnsupportedAttribute
      )
    end

    it "returns error for unsupported command" do
      cluster = build(Matter::Cluster::OnOff)

      result = invoke(cluster, 0x99_u32, Bytes.new(0))
      result.should be_a(Matter::InteractionModel::Status)
      result.as(Matter::InteractionModel::Status).status.should eq(
        Matter::InteractionModel::StatusCode::UnsupportedCommand
      )
    end
  end

  describe "practical scenarios" do
    it "simulates light switch sequence" do
      light = build(Matter::Cluster::OnOff)

      # Initially off
      light.on_off?.should be_false

      # User turns on light
      invoke(light, Matter::Cluster::OnOff::CMD_ON, Bytes.new(0))
      light.on_off?.should be_true

      # User turns off light
      invoke(light, Matter::Cluster::OnOff::CMD_OFF, Bytes.new(0))
      light.on_off?.should be_false
    end

    it "simulates toggle button presses" do
      outlet = build(Matter::Cluster::OnOff)

      states = [] of Bool

      # Simulate 5 button presses
      5.times do
        invoke(outlet, Matter::Cluster::OnOff::CMD_TOGGLE, Bytes.new(0))
        states << outlet.on_off?
      end

      states.should eq([true, false, true, false, true])
    end

    it "tracks state changes with callback" do
      device = build(Matter::Cluster::OnOff)

      transitions = [] of String

      device.on_state_changed do |state|
        transitions << (state ? "ON" : "OFF")
      end

      invoke(device, Matter::Cluster::OnOff::CMD_ON, Bytes.new(0))
      invoke(device, Matter::Cluster::OnOff::CMD_OFF, Bytes.new(0))
      invoke(device, Matter::Cluster::OnOff::CMD_TOGGLE, Bytes.new(0))
      invoke(device, Matter::Cluster::OnOff::CMD_TOGGLE, Bytes.new(0))

      transitions.should eq(["ON", "OFF", "ON", "OFF"])
    end
  end

  describe "integration with other clusters" do
    it "maintains state independently per endpoint" do
      cluster1 = build(Matter::Cluster::OnOff, on_off: false)
      cluster2 = build(Matter::Cluster::OnOff, 2, on_off: true)

      cluster1.on_off?.should be_false
      cluster2.on_off?.should be_true

      invoke(cluster1, Matter::Cluster::OnOff::CMD_ON, Bytes.new(0))

      cluster1.on_off?.should be_true
      cluster2.on_off?.should be_true # Unchanged
    end
  end
end
