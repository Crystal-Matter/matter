require "../spec_helper"
require "../../src/matter/endpoint"
require "../../src/matter/cluster/level_control"
require "../../src/matter/cluster/on_off"

private alias CoupledLevel = Matter::Cluster::LevelControl
private alias CoupledOnOff = Matter::Cluster::OnOff

private def coupled_clusters(initial_level : UInt8 = 40_u8, on : Bool = false)
  on_off = build(CoupledOnOff, on_off: on, feature_map: CoupledOnOff::Feature::Lighting)
  level = build(CoupledLevel, current_level: initial_level, min_level: 1_u8,
    feature_map: CoupledLevel::Feature::OnOff | CoupledLevel::Feature::Lighting)
  endpoint = Matter::Endpoint.new(level.endpoint_id)
  endpoint.add_cluster(on_off)
  endpoint.add_cluster(level)
  {on_off, level}
end

describe "LevelControl OnOff coupling" do
  it "gates an ordinary level command while off unless ExecuteIfOff is set" do
    on_off, level = coupled_clusters
    invoke(level, CoupledLevel::CMD_MOVE_TO_LEVEL,
      CoupledLevel::MoveToLevelRequest.new(100_u8, 0_u16, 0_u8, 0_u8))
    level.current_level.should eq(40_u8)

    execute_if_off = 1_u8
    invoke(level, CoupledLevel::CMD_MOVE_TO_LEVEL,
      CoupledLevel::MoveToLevelRequest.new(100_u8, 0_u16, execute_if_off, execute_if_off))
    level.current_level.should eq(100_u8)
    on_off.on_off?.should be_false
  end

  it "lets OptionsOverride clear ExecuteIfOff for one command" do
    _, level = coupled_clusters
    level.options = 1_u8
    invoke(level, CoupledLevel::CMD_MOVE_TO_LEVEL,
      CoupledLevel::MoveToLevelRequest.new(100_u8, 0_u16, 1_u8, 0_u8))
    level.current_level.should eq(40_u8)
  end

  it "turns on immediately for MoveToLevelWithOnOff above the minimum" do
    on_off, level = coupled_clusters
    invoke(level, CoupledLevel::CMD_MOVE_TO_LEVEL_WITH_ON_OFF,
      CoupledLevel::MoveToLevelWithOnOffRequest.new(100_u8, 10_u16, 0_u8, 0_u8))
    started = Time.instant
    on_off.on_off?.should be_true
    level.current_level.should eq(40_u8)
    level.advance_transition(started + 1100.milliseconds)
    level.current_level.should eq(100_u8)
    on_off.on_off?.should be_true
  end

  it "turns off only after a WithOnOff transition reaches the minimum" do
    on_off, level = coupled_clusters(initial_level: 100_u8, on: true)
    invoke(level, CoupledLevel::CMD_MOVE_TO_LEVEL_WITH_ON_OFF,
      CoupledLevel::MoveToLevelWithOnOffRequest.new(1_u8, 10_u16, 0_u8, 0_u8))
    started = Time.instant
    on_off.on_off?.should be_true
    level.advance_transition(started + 1100.milliseconds)
    level.current_level.should eq(1_u8)
    on_off.on_off?.should be_false
  end

  it "keeps OnOff on when a downward transition is stopped early" do
    on_off, level = coupled_clusters(initial_level: 100_u8, on: true)
    invoke(level, CoupledLevel::CMD_MOVE_TO_LEVEL_WITH_ON_OFF,
      CoupledLevel::MoveToLevelWithOnOffRequest.new(1_u8, 10_u16, 0_u8, 0_u8))
    started = Time.instant
    level.advance_transition(started + 500.milliseconds)
    invoke(level, CoupledLevel::CMD_STOP_WITH_ON_OFF,
      CoupledLevel::StopWithOnOffRequest.new(0_u8, 0_u8))
    level.advance_transition(started + 2.seconds)
    level.current_level.as(UInt8).should be > 1_u8
    on_off.on_off?.should be_true
  end
end
