require "../spec_helper"
require "../../src/matter/endpoint"

private alias GlobalSceneOnOff = Matter::Cluster::OnOff
private alias GlobalScenes = Matter::Cluster::ScenesManagement
private alias GlobalSceneMode = Matter::Cluster::ModeSelect

private def lighting_scene_endpoint
  number = endpoint(1_u16)
  light = Matter::Endpoint.new(number)
  on_off = GlobalSceneOnOff.new(number, feature_map: GlobalSceneOnOff::Feature::Lighting)
  mode = GlobalSceneMode.new(number, description: "Lighting mode",
    supported_modes: [GlobalSceneMode::ModeOption.new("Eco", 1_u8), GlobalSceneMode::ModeOption.new("Bright", 2_u8)],
    current_mode: 1_u8)
  scenes = GlobalScenes.new(number)
  light.add_cluster(on_off)
  light.add_cluster(mode)
  light.add_cluster(scenes)
  light.wire_scene_extensions
  {on_off, mode, scenes}
end

private def off_with_global_scene(on_off : GlobalSceneOnOff, fabric_index : UInt8)
  invoke(on_off, GlobalSceneOnOff::CMD_OFF_WITH_EFFECT,
    GlobalSceneOnOff::OffWithEffectRequest.new(GlobalSceneOnOff::EffectIdentifier::DelayedAllOff, 0_u8),
    is_case_session: true, fabric_index: fabric_index)
end

private def recall_global_scene(on_off : GlobalSceneOnOff, fabric_index : UInt8)
  invoke(on_off, GlobalSceneOnOff::CMD_ON_WITH_RECALL_GLOBAL_SCENE, Bytes.empty,
    is_case_session: true, fabric_index: fabric_index)
end

describe "OnOff Lighting global scene" do
  it "snapshots and recalls the fabric's same-endpoint scene extensions" do
    on_off, mode, scenes = lighting_scene_endpoint
    on_off.on
    mode.current_mode = 1_u8

    expect_success(off_with_global_scene(on_off, 1_u8))
    scenes.has_scene?(GlobalScenes::GLOBAL_SCENE_GROUP_ID, GlobalScenes::GLOBAL_SCENE_ID, 1_u8).should be_true
    on_off.on_off?.should be_false
    on_off.global_scene_control?.should be_false

    mode.current_mode = 2_u8
    expect_success(off_with_global_scene(on_off, 1_u8))
    expect_success(recall_global_scene(on_off, 1_u8))
    on_off.on_off?.should be_true
    mode.current_mode.should eq(1_u8)
    on_off.global_scene_control?.should be_true
  end

  it "turns on when the global scene cannot be recalled" do
    on_off, _mode, scenes = lighting_scene_endpoint
    on_off.off
    scenes.has_scene?(GlobalScenes::GLOBAL_SCENE_GROUP_ID, GlobalScenes::GLOBAL_SCENE_ID, 1_u8).should be_false

    expect_success(recall_global_scene(on_off, 1_u8))
    on_off.on_off?.should be_true
    on_off.global_scene_control?.should be_true
  end

  it "discards recall while GlobalSceneControl is already true" do
    on_off, _mode, _scenes = lighting_scene_endpoint
    on_off.on_off?.should be_false
    on_off.global_scene_control?.should be_true

    expect_success(recall_global_scene(on_off, 1_u8))
    on_off.on_off?.should be_false
    on_off.global_scene_control?.should be_true
  end

  it "does not recall another fabric's global scene" do
    on_off, mode, scenes = lighting_scene_endpoint
    on_off.on
    mode.current_mode = 1_u8
    expect_success(off_with_global_scene(on_off, 1_u8))

    mode.current_mode = 2_u8
    expect_success(recall_global_scene(on_off, 2_u8))
    on_off.on_off?.should be_true
    mode.current_mode.should eq(2_u8)
    scenes.has_scene?(GlobalScenes::GLOBAL_SCENE_GROUP_ID, GlobalScenes::GLOBAL_SCENE_ID, 2_u8).should be_false

    on_off.off
    expect_success(recall_global_scene(on_off, 1_u8))
    mode.current_mode.should eq(1_u8)
  end
end
