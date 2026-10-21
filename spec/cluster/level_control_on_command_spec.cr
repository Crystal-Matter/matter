require "../spec_helper"
require "../../src/matter/endpoint"
require "../../src/matter/cluster/level_control"
require "../../src/matter/cluster/on_off"

private alias OnCommandLevel = Matter::Cluster::LevelControl
private alias OnCommandOnOff = Matter::Cluster::OnOff

private def on_command_clusters(on_level : UInt8? = 80_u8)
  on_off = build(OnCommandOnOff, on_off: false, feature_map: OnCommandOnOff::Feature::Lighting)
  level = build(OnCommandLevel, current_level: 40_u8, min_level: 1_u8,
    on_level: on_level, feature_map: OnCommandLevel::Feature::OnOff | OnCommandLevel::Feature::Lighting)
  endpoint = Matter::Endpoint.new(level.endpoint_id)
  endpoint.add_cluster(level)
  endpoint.add_cluster(on_off)
  {on_off, level}
end

describe "LevelControl effect of OnOff On commands" do
  it "moves to OnLevel when the On command turns on" do
    on_off, level = on_command_clusters
    on_off.on
    on_off.on_off?.should be_true
    level.current_level.should eq(80_u8)
  end

  it "uses OnTransitionTime for an On command" do
    on_off, level = on_command_clusters
    level.on_transition_time = 10_u16
    on_off.on
    started = Time.instant
    level.current_level.should eq(40_u8)
    level.advance_transition(started + 1100.milliseconds)
    level.current_level.should eq(80_u8)
  end

  it "falls back to OnOffTransitionTime when OnTransitionTime is null" do
    on_off, level = on_command_clusters
    level.on_off_transition_time = 10_u16
    on_off.on
    started = Time.instant
    level.current_level.should eq(40_u8)
    level.advance_transition(started + 1100.milliseconds)
    level.current_level.should eq(80_u8)
  end

  it "applies OnLevel when Toggle turns an off device on" do
    on_off, level = on_command_clusters
    on_off.toggle
    level.current_level.should eq(80_u8)
  end

  it "does not change the level when OnLevel is null" do
    on_off, level = on_command_clusters(nil)
    on_off.on
    level.current_level.should eq(40_u8)
  end

  it "does not replace a WithOnOff command target with OnLevel" do
    on_off, level = on_command_clusters
    invoke(level, OnCommandLevel::CMD_MOVE_TO_LEVEL_WITH_ON_OFF,
      OnCommandLevel::MoveToLevelWithOnOffRequest.new(50_u8, 0_u16, 0_u8, 0_u8))
    on_off.on_off?.should be_true
    level.current_level.should eq(50_u8)
  end
end
