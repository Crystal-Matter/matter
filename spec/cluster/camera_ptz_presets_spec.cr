require "../spec_helper"

private alias PresetCamera = Matter::Cluster::CameraAvSettingsUserLevelManagement
private alias PresetStatus = Matter::InteractionModel::Status
private alias PresetCode = Matter::InteractionModel::StatusCode

private def preset_camera(max_presets : UInt8 = 2_u8,
                          pan_min : Int16 = PresetCamera::PAN_MIN_LIMIT,
                          pan_max : Int16 = PresetCamera::PAN_MAX_LIMIT)
  build(PresetCamera, max_presets: max_presets,
    feature_map: PresetCamera::Feature::MechanicalPan | PresetCamera::Feature::MechanicalPresets,
    pan_min: pan_min, pan_max: pan_max)
end

describe "Camera AV Settings MPAN+MPRESETS" do
  it "advertises the mandatory preset attributes and commands with canonical fields" do
    camera = preset_camera
    camera.feature_map.value.should eq(0x12_u32)
    camera.attributes.map(&.id.id).should contain(PresetCamera::ATTR_MAX_PRESETS)
    camera.attributes.map(&.id.id).should contain(PresetCamera::ATTR_MPTZ_PRESETS)
    camera.commands.map(&.id.id).should contain(PresetCamera::CMD_MPTZ_MOVE_TO_PRESET)
    camera.commands.map(&.id.id).should contain(PresetCamera::CMD_MPTZ_SAVE_PRESET)
    camera.commands.map(&.id.id).should contain(PresetCamera::CMD_MPTZ_REMOVE_PRESET)
    camera.commands.select(&.id.id.in?(2_u32, 3_u32, 4_u32)).each do |command|
      command.access.should eq(Matter::InteractionModel::EntryPrivilege::Operate)
    end
    read(camera, PresetCamera::ATTR_MAX_PRESETS).should eq(2_u8)
    read_tlv(camera, PresetCamera::ATTR_MPTZ_PRESETS).as_list.should be_empty
    PresetCamera::MPTZSavePresetRequest.new(nil, "Door").to_tlv.as_structure.keys.should eq([1_u8])
    PresetCamera::MPTZMoveToPresetRequest.new(1_u8).to_tlv.as_structure.keys.should eq([0_u8])
    PresetCamera::MPTZRemovePresetRequest.new(1_u8).to_tlv.as_structure.keys.should eq([0_u8])
    expect_raises(ArgumentError) { preset_camera(0_u8) }
    expect_raises(ArgumentError) { camera.feature_map = PresetCamera::Feature::MechanicalPan }
    expect_raises(ArgumentError) { camera.max_presets = 0_u8 }
  end

  it "captures measured pan, allocates the first free ID, moves through the actuator, and persists presets" do
    camera = preset_camera
    camera.report_pan_position(15_i16)
    saved = [] of PresetCamera::MPTZPreset
    removed = [] of UInt8
    camera.on_preset_save { |preset| saved << preset; PresetStatus.success }
    camera.on_preset_remove { |id| removed << id; PresetStatus.success }
    expect_success(invoke(camera, PresetCamera::CMD_MPTZ_SAVE_PRESET,
      PresetCamera::MPTZSavePresetRequest.new(nil, "Door")))
    saved.first.preset_id.should eq(1_u8)
    saved.first.settings.pan.should eq(15_i16)
    camera.mptz_presets.first.name.should eq("Door")
    camera.mptz_presets.first.to_tlv.as_structure.keys.should eq([0_u8, 1_u8, 2_u8])
    camera.report_pan_position(-10_i16)
    expect_success(invoke(camera, PresetCamera::CMD_MPTZ_SAVE_PRESET,
      PresetCamera::MPTZSavePresetRequest.new(nil, "Window")))
    camera.mptz_presets.map(&.preset_id).should eq([1_u8, 2_u8])
    expect_status(invoke(camera, PresetCamera::CMD_MPTZ_SAVE_PRESET,
      PresetCamera::MPTZSavePresetRequest.new(nil, "Full")), PresetCode::ResourceExhausted)
    targets = [] of Int16
    camera.on_pan_move { |target| targets << target; PresetStatus.success }
    expect_success(invoke(camera, PresetCamera::CMD_MPTZ_MOVE_TO_PRESET,
      PresetCamera::MPTZMoveToPresetRequest.new(1_u8)))
    targets.should eq([15_i16])
    camera.mptz_position.pan.should eq(-10_i16)
    camera.movement_state.should eq(PresetCamera::PhysicalMovement::Moving)
    restored = preset_camera
    restored.restore_state(camera.save_state.as(Matter::Storage::Document))
    restored.mptz_presets.map(&.name).should eq(["Door", "Window"])
    restored.movement_state.should eq(PresetCamera::PhysicalMovement::Idle)
    expect_success(invoke(camera, PresetCamera::CMD_MPTZ_REMOVE_PRESET,
      PresetCamera::MPTZRemovePresetRequest.new(1_u8)))
    removed.should eq([1_u8])
    camera.mptz_presets.map(&.preset_id).should eq([2_u8])
  end

  it "validates names, IDs, limits and preserves state when host rejects a change" do
    camera = preset_camera(1_u8, pan_min: -20_i16, pan_max: 20_i16)
    save = PresetCamera::CMD_MPTZ_SAVE_PRESET
    expect_status(invoke(camera, save, PresetCamera::MPTZSavePresetRequest.new(0_u8, "Bad")), PresetCode::ConstraintError)
    expect_status(invoke(camera, save, PresetCamera::MPTZSavePresetRequest.new(2_u8, "Bad")), PresetCode::ConstraintError)
    expect_status(invoke(camera, save, PresetCamera::MPTZSavePresetRequest.new(nil, "x" * 33)), PresetCode::ConstraintError)
    expect_status(invoke(camera, save, PresetCamera::MPTZSavePresetRequest.new(1_u8, "Door")), PresetCode::InvalidInState)
    camera.on_preset_save { |_preset| PresetStatus.failure }
    expect_status(invoke(camera, save, PresetCamera::MPTZSavePresetRequest.new(1_u8, "Door")), PresetCode::Failure)
    camera.mptz_presets.should be_empty
    camera.on_preset_save { |_preset| PresetStatus.success }
    expect_success(invoke(camera, save, PresetCamera::MPTZSavePresetRequest.new(1_u8, "Door")))
    camera.report_pan_position(10_i16)
    expect_success(invoke(camera, save, PresetCamera::MPTZSavePresetRequest.new(1_u8, "Changed")))
    camera.mptz_presets.map(&.name).should eq(["Changed"])
    camera.mptz_presets.first.settings.pan.should eq(10_i16)
    expect_raises(ArgumentError) { camera.mptz_presets = [PresetCamera::MPTZPreset.new(2_u8, "Bad", PresetCamera::MPTZPosition.new(0_i16))] }
    expect_status(invoke(camera, PresetCamera::CMD_MPTZ_MOVE_TO_PRESET,
      PresetCamera::MPTZMoveToPresetRequest.new(2_u8)), PresetCode::ConstraintError)
    expect_status(invoke(camera, PresetCamera::CMD_MPTZ_REMOVE_PRESET,
      PresetCamera::MPTZRemovePresetRequest.new(1_u8)), PresetCode::InvalidInState)
    camera.on_preset_remove { |_id| PresetStatus.failure }
    expect_status(invoke(camera, PresetCamera::CMD_MPTZ_REMOVE_PRESET,
      PresetCamera::MPTZRemovePresetRequest.new(1_u8)), PresetCode::Failure)
    camera.mptz_presets.size.should eq(1)
    restored = preset_camera(1_u8, pan_min: -5_i16, pan_max: 5_i16)
    restored.restore_state(camera.save_state.as(Matter::Storage::Document))
    restored.mptz_presets.should be_empty
  end
end
