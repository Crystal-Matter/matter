require "../spec_helper"
require "../../src/matter/cluster/window_covering"

private alias Covering = Matter::Cluster::WindowCovering

describe "Window Covering revision 8 mode behavior" do
  it "rejects undefined Mode bits and synchronizes ConfigStatus" do
    cluster = build(Covering)
    expect_status(write(cluster, Covering::ATTR_MODE, 0x10_u8), Matter::InteractionModel::StatusCode::ConstraintError)
    expect_success(write(cluster, Covering::ATTR_MODE, 0x01_u8))
    cluster.config_status.lift_movement_reversed?.should be_true
    expect_success(write(cluster, Covering::ATTR_MODE, 0x04_u8))
    cluster.config_status.operational?.should be_false
    cluster.config_status.lift_movement_reversed?.should be_false
    expect_success(write(cluster, Covering::ATTR_MODE, 0x00_u8))
    cluster.config_status.operational?.should be_true
  end

  it "locks every motion command in maintenance and calibration modes" do
    cluster = build(Covering,
      feature_map: Covering::Feature::Lift | Covering::Feature::Tilt |
                   Covering::Feature::PositionAwareLift | Covering::Feature::PositionAwareTilt)
    commands = [
      {Covering::CMD_UP_OR_OPEN, nil},
      {Covering::CMD_DOWN_OR_CLOSE, nil},
      {Covering::CMD_STOP_MOTION, nil},
      {Covering::CMD_GO_TO_LIFT_PERCENTAGE, Covering::GoToLiftPercentageRequest.new(2_500_u16)},
      {Covering::CMD_GO_TO_TILT_PERCENTAGE, Covering::GoToTiltPercentageRequest.new(7_500_u16)},
    ]
    { {0x04_u8, Matter::InteractionModel::StatusCode::Busy},
     {0x02_u8, Matter::InteractionModel::StatusCode::Failure} }.each do |mode, expected|
      expect_success(write(cluster, Covering::ATTR_MODE, mode))
      commands.each do |command_id, payload|
        expect_status(invoke(cluster, command_id, payload), expected)
      end
    end
    cluster.target_position_lift_percent100ths.should be_nil
    cluster.target_position_tilt_percent100ths.should be_nil
  end

  it "persists Mode and exposed current position percentages" do
    cluster = build(Covering,
      feature_map: Covering::Feature::Lift | Covering::Feature::Tilt |
                   Covering::Feature::PositionAwareLift | Covering::Feature::PositionAwareTilt)
    expect_success(write(cluster, Covering::ATTR_MODE, 0x01_u8))
    cluster.current_position_lift_percent100ths = 2_550_u16
    cluster.current_position_tilt_percent100ths = 7_550_u16
    cluster.current_position_lift_percentage.should eq(25_u8)
    cluster.current_position_tilt_percentage.should eq(75_u8)
    stored = cluster.save_state.as(Matter::Storage::Document)
    stored["current_position_lift_percentage"].should eq(25_i64)
    stored["current_position_tilt_percentage"].should eq(75_i64)

    restored = build(Covering,
      feature_map: Covering::Feature::Lift | Covering::Feature::Tilt |
                   Covering::Feature::PositionAwareLift | Covering::Feature::PositionAwareTilt)
    restored.restore_state(stored)
    restored.mode.should eq(Covering::Mode::MotorDirectionReversed)
    restored.current_position_lift_percentage.should eq(25_u8)
    restored.current_position_tilt_percentage.should eq(75_u8)
    restored.config_status.lift_movement_reversed?.should be_true
  end
end
