require "../spec_helper"
require "../../src/matter/cluster/level_control"

private alias TimedLevel = Matter::Cluster::LevelControl

describe "LevelControl transition timing" do
  it "moves gradually over a requested decisecond transition" do
    cluster = build(TimedLevel, current_level: 10_u8)
    invoke(cluster, TimedLevel::CMD_MOVE_TO_LEVEL,
      TimedLevel::MoveToLevelRequest.new(110_u8, 10_u16, 0_u8, 0_u8))
    started = Time.instant

    cluster.current_level.should eq(10_u8)
    read(cluster, TimedLevel::ATTR_REMAINING_TIME).should eq(10_u16)
    cluster.advance_transition(started + 500.milliseconds)
    cluster.current_level.as(UInt8).should be_close(60, 2)
    read(cluster, TimedLevel::ATTR_REMAINING_TIME).as(UInt8 | UInt16).to_i.should be <= 5
    cluster.advance_transition(started + 1100.milliseconds)
    cluster.current_level.should eq(110_u8)
    read(cluster, TimedLevel::ATTR_REMAINING_TIME).should eq(0_u16)
  end

  it "stops a step at its current level" do
    cluster = build(TimedLevel, current_level: 50_u8)
    invoke(cluster, TimedLevel::CMD_STEP,
      TimedLevel::StepRequest.new(TimedLevel::StepMode::Up, 100_u8, 10_u16, 0_u8, 0_u8))
    started = Time.instant
    cluster.advance_transition(started + 500.milliseconds)
    stopped_level = cluster.current_level.as(UInt8)
    stopped_level.should be_close(100, 2)

    invoke(cluster, TimedLevel::CMD_STOP, TimedLevel::StopRequest.new(0_u8, 0_u8))
    cluster.advance_transition(started + 2.seconds)
    cluster.current_level.should eq(stopped_level)
    read(cluster, TimedLevel::ATTR_REMAINING_TIME).should eq(0_u16)
  end

  it "honors a move rate in levels per second" do
    cluster = build(TimedLevel, current_level: 40_u8)
    invoke(cluster, TimedLevel::CMD_MOVE,
      TimedLevel::MoveRequest.new(TimedLevel::MoveMode::Up, 20_u8, 0_u8, 0_u8))
    started = Time.instant
    cluster.current_level.should eq(40_u8)
    cluster.advance_transition(started + 1.second)
    cluster.current_level.as(UInt8).should be_close(60, 1)
    cluster.advance_transition(started + 20.seconds)
    cluster.current_level.should eq(TimedLevel::HIGHEST_LEVEL)
  end

  it "advances without an application tick" do
    cluster = build(TimedLevel, current_level: 10_u8)
    invoke(cluster, TimedLevel::CMD_MOVE_TO_LEVEL,
      TimedLevel::MoveToLevelRequest.new(30_u8, 1_u16, 0_u8, 0_u8))
    deadline = Time.instant + 2.seconds
    while cluster.current_level != 30_u8 && Time.instant < deadline
      sleep 10.milliseconds
    end
    cluster.current_level.should eq(30_u8)
    read(cluster, TimedLevel::ATTR_REMAINING_TIME).should eq(0_u16)
  end

  it "rejects a zero move rate" do
    cluster = build(TimedLevel, current_level: 40_u8)
    status = invoke(cluster, TimedLevel::CMD_MOVE,
      TimedLevel::MoveRequest.new(TimedLevel::MoveMode::Up, 0_u8, 0_u8, 0_u8))
    status.as(Matter::InteractionModel::Status).status.should eq(
      Matter::InteractionModel::StatusCode::InvalidCommand)
    cluster.current_level.should eq(40_u8)
  end

  it "steps immediately when TransitionTime is null even with a default move time" do
    cluster = build(TimedLevel, current_level: 40_u8)
    cluster.on_off_transition_time = 5_u16
    invoke(cluster, TimedLevel::CMD_STEP,
      TimedLevel::StepRequest.new(TimedLevel::StepMode::Up, 20_u8, nil, 0_u8, 0_u8))
    cluster.current_level.should eq(60_u8)
    read(cluster, TimedLevel::ATTR_REMAINING_TIME).should eq(0_u16)
  end
end
