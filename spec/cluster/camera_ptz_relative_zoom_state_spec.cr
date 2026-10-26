require "../spec_helper"

private alias ReviewPtz = Matter::Cluster::CameraAvSettingsUserLevelManagement
private alias ReviewPtzStatus = Matter::InteractionModel::Status
private alias ReviewPtzCode = Matter::InteractionModel::StatusCode

describe "Camera PTZ relative zoom and movement state" do
  it "adds ZoomDelta units to the measured zoom" do
    camera = build(ReviewPtz, feature_map: ReviewPtz::Feature::MechanicalZoom,
      zoom_max: 100_u8, initial_zoom: 50_u8)
    targets = [] of ReviewPtz::MPTZPosition
    camera.on_mptz_move { |target| targets << target; ReviewPtzStatus.success }

    expect_success(invoke(camera, ReviewPtz::CMD_MPTZ_RELATIVE_MOVE,
      ReviewPtz::MPTZRelativeMoveRequest.new(nil, nil, 10_i8)))
    targets.last.zoom.should eq(60_u8)
    expect_success(invoke(camera, ReviewPtz::CMD_MPTZ_RELATIVE_MOVE,
      ReviewPtz::MPTZRelativeMoveRequest.new(nil, nil, -10_i8)))
    targets.last.zoom.should eq(40_u8)

    camera.report_mptz_position(ReviewPtz::MPTZPosition.new(nil, nil, 25_u8))
    expect_success(invoke(camera, ReviewPtz::CMD_MPTZ_RELATIVE_MOVE,
      ReviewPtz::MPTZRelativeMoveRequest.new(nil, nil, 10_i8)))
    targets.last.zoom.should eq(35_u8)
    expect_success(invoke(camera, ReviewPtz::CMD_MPTZ_RELATIVE_MOVE,
      ReviewPtz::MPTZRelativeMoveRequest.new(nil, nil, -10_i8)))
    targets.last.zoom.should eq(15_u8)
  end

  it "checks XML delta limits and clamps targets at the end stops" do
    camera = build(ReviewPtz, feature_map: ReviewPtz::Feature::MechanicalZoom,
      zoom_max: 100_u8, initial_zoom: 100_u8)
    targets = [] of ReviewPtz::MPTZPosition
    camera.on_mptz_move { |target| targets << target; ReviewPtzStatus.success }

    expect_success(invoke(camera, ReviewPtz::CMD_MPTZ_RELATIVE_MOVE,
      ReviewPtz::MPTZRelativeMoveRequest.new(nil, nil, 1_i8)))
    targets.last.zoom.should eq(100_u8)
    expect_status(invoke(camera, ReviewPtz::CMD_MPTZ_RELATIVE_MOVE,
      ReviewPtz::MPTZRelativeMoveRequest.new(nil, nil, Int8::MIN)), ReviewPtzCode::ConstraintError)
    camera.report_mptz_position(ReviewPtz::MPTZPosition.new(nil, nil, 1_u8))
    expect_success(invoke(camera, ReviewPtz::CMD_MPTZ_RELATIVE_MOVE,
      ReviewPtz::MPTZRelativeMoveRequest.new(nil, nil, -99_i8)))
    targets.last.zoom.should eq(1_u8)

    camera.report_mptz_position(ReviewPtz::MPTZPosition.new(nil, nil, 50_u8))
    expect_success(invoke(camera, ReviewPtz::CMD_MPTZ_RELATIVE_MOVE,
      ReviewPtz::MPTZRelativeMoveRequest.new(nil, nil, 99_i8)))
    targets.last.zoom.should eq(100_u8)
  end

  it "clamps a bounded pan delta at the configured limit" do
    camera = build(ReviewPtz, feature_map: ReviewPtz::Feature::MechanicalPan,
      initial_pan: 170_i16)
    targets = [] of Int16
    camera.on_pan_move { |target| targets << target; ReviewPtzStatus.success }
    expect_success(invoke(camera, ReviewPtz::CMD_MPTZ_RELATIVE_MOVE,
      ReviewPtz::MPTZRelativeMoveRequest.new(20_i16)))
    targets.should eq([180_i16])
  end

  it "keeps an earlier move active when a later host callback rejects or raises" do
    camera = build(ReviewPtz, feature_map: ReviewPtz::Feature::MechanicalPan)
    camera.on_pan_move { |_target| ReviewPtzStatus.success }
    expect_success(invoke(camera, ReviewPtz::CMD_MPTZ_SET_POSITION,
      ReviewPtz::MPTZSetPositionRequest.new(10_i16)))
    camera.movement_state.should eq(ReviewPtz::PhysicalMovement::Moving)

    camera.on_pan_move { |_target| ReviewPtzStatus.failure }
    expect_status(invoke(camera, ReviewPtz::CMD_MPTZ_SET_POSITION,
      ReviewPtz::MPTZSetPositionRequest.new(20_i16)), ReviewPtzCode::Failure)
    camera.movement_state.should eq(ReviewPtz::PhysicalMovement::Moving)

    camera.on_pan_move { |_target| raise "actuator disconnected" }
    expect_status(invoke(camera, ReviewPtz::CMD_MPTZ_SET_POSITION,
      ReviewPtz::MPTZSetPositionRequest.new(30_i16)), ReviewPtzCode::Failure)
    camera.movement_state.should eq(ReviewPtz::PhysicalMovement::Moving)
  end
end
