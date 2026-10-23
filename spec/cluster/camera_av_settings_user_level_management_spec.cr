require "../spec_helper"

private alias CameraSettings = Matter::Cluster::CameraAvSettingsUserLevelManagement
private alias CameraCode = Matter::InteractionModel::StatusCode
private alias CameraStatus = Matter::InteractionModel::Status

private def camera_settings(**options)
  build(CameraSettings, **options)
end

describe CameraSettings do
  it "advertises only MechanicalPan attributes and mandatory commands" do
    cluster = camera_settings
    cluster.cluster_id.id.should eq(0x0552_u32)
    cluster.cluster_revision.should eq(1_u16)
    cluster.feature_map.value.should eq(0x02_u32)
    cluster.attributes.map(&.id.id).should eq([
      CameraSettings::ATTR_MPTZ_POSITION,
      CameraSettings::ATTR_PAN_MIN,
      CameraSettings::ATTR_PAN_MAX,
      CameraSettings::ATTR_MOVEMENT_STATE,
    ])
    accepted_command_ids(cluster).should eq([
      CameraSettings::CMD_MPTZ_SET_POSITION,
      CameraSettings::CMD_MPTZ_RELATIVE_MOVE,
    ])
    cluster.commands.each do |command|
      command.access.should eq(Matter::InteractionModel::EntryPrivilege::Operate)
    end
    generated_command_ids(cluster).should be_empty
    expect_raises(ArgumentError) { camera_settings(feature_map: CameraSettings::Feature::None) }
  end

  it "uses canonical context tags and signed pan values" do
    CameraSettings::MPTZPosition.new(-10_i16).to_tlv(nil).as_structure.keys.should eq([0_u8])
    CameraSettings::MPTZSetPositionRequest.new(15_i16).to_tlv(nil).as_structure.keys.should eq([0_u8])
    CameraSettings::MPTZRelativeMoveRequest.new(-5_i16).to_tlv(nil).as_structure.keys.should eq([0_u8])
    CameraSettings::MPTZPosition.from_tlv(CameraSettings::MPTZPosition.new(-10_i16).to_tlv(nil)).pan
      .should eq(-10_i16)
  end

  it "validates configured mechanical limits and initial position" do
    expect_raises(ArgumentError) { camera_settings(pan_min: -181_i16) }
    expect_raises(ArgumentError) { camera_settings(pan_min: 1_i16) }
    expect_raises(ArgumentError) { camera_settings(pan_max: 0_i16) }
    expect_raises(ArgumentError) { camera_settings(pan_max: 181_i16) }
    expect_raises(ArgumentError) { camera_settings(pan_min: -20_i16, pan_max: 20_i16, initial_pan: 21_i16) }
    cluster = camera_settings(pan_min: -20_i16, pan_max: 20_i16)
    expect_raises(ArgumentError) { cluster.report_pan_position(21_i16) }
    cluster.report_pan_position(10_i16)
    expect_raises(ArgumentError) { cluster.pan_max = 9_i16 }
    expect_raises(ArgumentError) { cluster.pan_min = -181_i16 }
    cluster.pan_max.should eq(20_i16)
    cluster.pan_min.should eq(-20_i16)
    cluster.mptz_position.pan.should eq(10_i16)
  end

  it "requires an actuator, validates commands and publishes host-reported movement" do
    cluster = camera_settings(pan_min: -20_i16, pan_max: 20_i16)
    set = CameraSettings::CMD_MPTZ_SET_POSITION
    relative = CameraSettings::CMD_MPTZ_RELATIVE_MOVE
    expect_status(invoke(cluster, set, CameraSettings::MPTZSetPositionRequest.new), CameraCode::ConstraintError)
    expect_status(invoke(cluster, set, CameraSettings::MPTZSetPositionRequest.new(21_i16)), CameraCode::ConstraintError)
    expect_status(invoke(cluster, set, CameraSettings::MPTZSetPositionRequest.new(10_i16)), CameraCode::InvalidInState)
    targets = [] of Int16
    cluster.on_pan_move do |target|
      targets << target
      CameraStatus.success
    end
    expect_success(invoke(cluster, set, CameraSettings::MPTZSetPositionRequest.new(10_i16)))
    targets.should eq([10_i16])
    cluster.movement_state.should eq(CameraSettings::PhysicalMovement::Moving)
    cluster.mptz_position.pan.should eq(0_i16)
    cluster.report_pan_position(10_i16)
    cluster.movement_state.should eq(CameraSettings::PhysicalMovement::Idle)
    expect_success(invoke(cluster, relative, CameraSettings::MPTZRelativeMoveRequest.new(-15_i16)))
    targets.should eq([10_i16, -5_i16])
    expect_status(invoke(cluster, relative, CameraSettings::MPTZRelativeMoveRequest.new), CameraCode::ConstraintError)
    expect_status(invoke(cluster, relative, CameraSettings::MPTZRelativeMoveRequest.new(30_i16)), CameraCode::ConstraintError)
    expect_status(invoke(cluster, relative, CameraSettings::MPTZRelativeMoveRequest.new(41_i16)), CameraCode::ConstraintError)
    targets.should eq([10_i16, -5_i16])
  end

  it "restores idle on a host failure and persists measured pan across restart" do
    cluster = camera_settings
    cluster.on_pan_move { |_target| CameraStatus.failure }
    expect_status(invoke(cluster, CameraSettings::CMD_MPTZ_SET_POSITION,
      CameraSettings::MPTZSetPositionRequest.new(15_i16)), CameraCode::Failure)
    cluster.movement_state.should eq(CameraSettings::PhysicalMovement::Idle)
    cluster.report_pan_position(-12_i16)
    saved = cluster.save_state.as(Matter::Storage::Document)
    restored = camera_settings
    restored.restore_state(saved)
    restored.mptz_position.pan.should eq(-12_i16)
    restored.movement_state.should eq(CameraSettings::PhysicalMovement::Idle)
  end

  it "restores idle when the host actuator raises" do
    cluster = camera_settings
    cluster.on_pan_move { |_target| raise "motor failed" }
    expect_status(invoke(cluster, CameraSettings::CMD_MPTZ_SET_POSITION,
      CameraSettings::MPTZSetPositionRequest.new(15_i16)), CameraCode::Failure)
    cluster.movement_state.should eq(CameraSettings::PhysicalMovement::Idle)
    cluster.mptz_position.pan.should eq(0_i16)
  end

  it "reconciles saved position to changed host limits" do
    source = camera_settings
    source.report_pan_position(90_i16)
    saved = source.save_state.as(Matter::Storage::Document)
    target = camera_settings(pan_min: -20_i16, pan_max: 20_i16)
    target.restore_state(saved)
    target.mptz_position.pan.should eq(0_i16)
  end
end
