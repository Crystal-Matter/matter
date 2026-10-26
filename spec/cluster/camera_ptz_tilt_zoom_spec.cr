require "../spec_helper"

private alias AxisCamera = Matter::Cluster::CameraAvSettingsUserLevelManagement
private alias AxisStatus = Matter::InteractionModel::Status
private alias AxisCode = Matter::InteractionModel::StatusCode

private def axis_camera(features : AxisCamera::Feature, max_presets : UInt8 = 0_u8)
  build(AxisCamera, feature_map: features, max_presets: max_presets,
    pan_min: -20_i16, pan_max: 20_i16,
    tilt_min: -15_i16, tilt_max: 15_i16, zoom_max: 5_u8)
end

describe "Camera AV Settings mechanical tilt and zoom" do
  it "advertises the conditional position fields and bounds for single-axis profiles" do
    tilt = axis_camera(AxisCamera::Feature::MechanicalTilt)
    tilt.feature_map.value.should eq(0x04_u32)
    tilt.attributes.map(&.id.id).should contain(AxisCamera::ATTR_MPTZ_POSITION)
    tilt.attributes.map(&.id.id).should contain(AxisCamera::ATTR_MOVEMENT_STATE)
    tilt.attributes.map(&.id.id).should contain(AxisCamera::ATTR_TILT_MIN)
    tilt.attributes.map(&.id.id).should contain(AxisCamera::ATTR_TILT_MAX)
    tilt.attributes.map(&.id.id).should_not contain(AxisCamera::ATTR_PAN_MIN)
    tilt.commands.map(&.id.id).should eq([AxisCamera::CMD_MPTZ_SET_POSITION, AxisCamera::CMD_MPTZ_RELATIVE_MOVE])
    tilt.mptz_position.to_tlv.as_structure.keys.should eq([1_u8])
    expect_status(invoke(tilt, AxisCamera::CMD_MPTZ_SET_POSITION,
      AxisCamera::MPTZSetPositionRequest.new), AxisCode::ConstraintError)
    expect_status(invoke(tilt, AxisCamera::CMD_MPTZ_SET_POSITION,
      AxisCamera::MPTZSetPositionRequest.new(1_i16)), AxisCode::InvalidCommand)
    tilt.on_mptz_move { |_position| AxisStatus.success }
    expect_success(invoke(tilt, AxisCamera::CMD_MPTZ_SET_POSITION,
      AxisCamera::MPTZSetPositionRequest.new(nil, 10_i16)))
    tilt.report_mptz_position(AxisCamera::MPTZPosition.new(nil, 10_i16))
    expect_status(invoke(tilt, AxisCamera::CMD_MPTZ_RELATIVE_MOVE,
      AxisCamera::MPTZRelativeMoveRequest.new(1_i16)), AxisCode::InvalidCommand)
    expect_status(invoke(tilt, AxisCamera::CMD_MPTZ_RELATIVE_MOVE,
      AxisCamera::MPTZRelativeMoveRequest.new(nil, 10_i16)), AxisCode::ConstraintError)

    zoom = axis_camera(AxisCamera::Feature::MechanicalZoom)
    zoom.feature_map.value.should eq(0x08_u32)
    zoom.attributes.map(&.id.id).should contain(AxisCamera::ATTR_MPTZ_POSITION)
    zoom.attributes.map(&.id.id).should contain(AxisCamera::ATTR_MOVEMENT_STATE)
    zoom.attributes.map(&.id.id).should contain(AxisCamera::ATTR_ZOOM_MAX)
    zoom.mptz_position.to_tlv.as_structure.keys.should eq([2_u8])
    zoom.mptz_position.zoom.should eq(1_u8)
    zoom.on_mptz_move { |_position| AxisStatus.success }
    expect_status(invoke(zoom, AxisCamera::CMD_MPTZ_SET_POSITION,
      AxisCamera::MPTZSetPositionRequest.new(nil, nil, 6_u8)), AxisCode::ConstraintError)
    expect_success(invoke(zoom, AxisCamera::CMD_MPTZ_RELATIVE_MOVE,
      AxisCamera::MPTZRelativeMoveRequest.new(nil, nil, 2_i8)))
    zoom.report_mptz_position(AxisCamera::MPTZPosition.new(nil, nil, 3_u8))
    zoom.mptz_position.zoom.should eq(3_u8)
  end

  it "moves multiple axes atomically and saves and recalls all measured settings" do
    features = AxisCamera::Feature::MechanicalPan | AxisCamera::Feature::MechanicalTilt |
               AxisCamera::Feature::MechanicalZoom | AxisCamera::Feature::MechanicalPresets
    camera = axis_camera(features, 2_u8)
    camera.feature_map.value.should eq(0x1e_u32)
    camera.mptz_position.to_tlv.as_structure.keys.should eq([0_u8, 1_u8, 2_u8])
    targets = [] of AxisCamera::MPTZPosition
    camera.on_mptz_move { |_position| AxisStatus.failure }
    expect_status(invoke(camera, AxisCamera::CMD_MPTZ_SET_POSITION,
      AxisCamera::MPTZSetPositionRequest.new(5_i16, -3_i16, 4_u8)), AxisCode::Failure)
    camera.movement_state.should eq(AxisCamera::PhysicalMovement::Idle)
    camera.mptz_position.should eq(AxisCamera::MPTZPosition.new(0_i16, 0_i16, 1_u8))
    camera.on_mptz_move { |position| targets << position; AxisStatus.success }
    expect_status(invoke(camera, AxisCamera::CMD_MPTZ_SET_POSITION,
      AxisCamera::MPTZSetPositionRequest.new(nil, nil, nil)), AxisCode::ConstraintError)
    expect_success(invoke(camera, AxisCamera::CMD_MPTZ_SET_POSITION,
      AxisCamera::MPTZSetPositionRequest.new(5_i16, -3_i16, 4_u8)))
    targets.last.should eq(AxisCamera::MPTZPosition.new(5_i16, -3_i16, 4_u8))
    camera.mptz_position.should eq(AxisCamera::MPTZPosition.new(0_i16, 0_i16, 1_u8))
    camera.report_mptz_position(AxisCamera::MPTZPosition.new(5_i16, -3_i16, 4_u8))
    camera.movement_state.should eq(AxisCamera::PhysicalMovement::Idle)
    expect_success(invoke(camera, AxisCamera::CMD_MPTZ_RELATIVE_MOVE,
      AxisCamera::MPTZRelativeMoveRequest.new(-2_i16, 2_i16, -1_i8)))
    targets.last.should eq(AxisCamera::MPTZPosition.new(3_i16, -1_i16, 3_u8))
    camera.on_preset_save { |_preset| AxisStatus.success }
    expect_success(invoke(camera, AxisCamera::CMD_MPTZ_SAVE_PRESET,
      AxisCamera::MPTZSavePresetRequest.new(nil, "Scene")))
    camera.mptz_presets.first.settings.to_tlv.as_structure.keys.should eq([0_u8, 1_u8, 2_u8])
    camera.report_mptz_position(AxisCamera::MPTZPosition.new(0_i16, 0_i16, 1_u8))
    expect_raises(ArgumentError) { camera.pan_max = 4_i16 }
    expect_raises(ArgumentError) { camera.tilt_min = -2_i16 }
    expect_raises(ArgumentError) { camera.zoom_max = 3_u8 }
    expect_success(invoke(camera, AxisCamera::CMD_MPTZ_MOVE_TO_PRESET,
      AxisCamera::MPTZMoveToPresetRequest.new(1_u8)))
    targets.last.should eq(AxisCamera::MPTZPosition.new(5_i16, -3_i16, 4_u8))
    restored = axis_camera(features, 2_u8)
    restored.restore_state(camera.save_state.as(Matter::Storage::Document))
    restored.mptz_presets.first.settings.should eq(AxisCamera::MPTZPosition.new(5_i16, -3_i16, 4_u8))
    limited = build(AxisCamera, feature_map: features, max_presets: 2_u8,
      pan_min: -20_i16, pan_max: 20_i16, tilt_min: -2_i16, tilt_max: 15_i16, zoom_max: 3_u8)
    limited.restore_state(camera.save_state.as(Matter::Storage::Document))
    limited.mptz_presets.should be_empty
  end

  it "rejects invalid mechanical bounds and unsupported feature combinations" do
    expect_raises(ArgumentError) { axis_camera(AxisCamera::Feature::MechanicalTilt | AxisCamera::Feature::DigitalPtz) }
    expect_raises(ArgumentError) { build(AxisCamera, feature_map: AxisCamera::Feature::MechanicalTilt, tilt_min: -181_i16) }
    expect_raises(ArgumentError) { build(AxisCamera, feature_map: AxisCamera::Feature::MechanicalZoom, zoom_max: 1_u8) }
    camera = axis_camera(AxisCamera::Feature::MechanicalTilt | AxisCamera::Feature::MechanicalZoom)
    expect_raises(ArgumentError) { camera.report_mptz_position(AxisCamera::MPTZPosition.new(nil, 16_i16, 1_u8)) }
    expect_raises(ArgumentError) { camera.report_mptz_position(AxisCamera::MPTZPosition.new(nil, 0_i16, 0_u8)) }
  end

  it "saves presets for mechanical profiles without pan" do
    features = AxisCamera::Feature::MechanicalTilt | AxisCamera::Feature::MechanicalZoom |
               AxisCamera::Feature::MechanicalPresets
    camera = axis_camera(features, 1_u8)
    camera.report_mptz_position(AxisCamera::MPTZPosition.new(nil, -4_i16, 3_u8))
    camera.on_preset_save { |_preset| AxisStatus.success }
    expect_success(invoke(camera, AxisCamera::CMD_MPTZ_SAVE_PRESET,
      AxisCamera::MPTZSavePresetRequest.new(nil, "TiltZoom")))
    camera.mptz_presets.first.settings.to_tlv.as_structure.keys.should eq([1_u8, 2_u8])
    targets = [] of AxisCamera::MPTZPosition
    camera.on_mptz_move { |target| targets << target; AxisStatus.success }
    expect_success(invoke(camera, AxisCamera::CMD_MPTZ_MOVE_TO_PRESET,
      AxisCamera::MPTZMoveToPresetRequest.new(1_u8)))
    targets.should eq([AxisCamera::MPTZPosition.new(nil, -4_i16, 3_u8)])
  end
end
