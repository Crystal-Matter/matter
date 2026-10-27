require "../spec_helper"
require "../../src/matter/cluster/mode_select"
require "../../src/matter/endpoint"

private alias SceneMode = Matter::Cluster::ModeSelect
private alias SceneManagement = Matter::Cluster::ScenesManagement

private def scene_mode : SceneMode
  build(SceneMode, description: "Operating mode",
    supported_modes: [SceneMode::ModeOption.new("Eco", 1_u8), SceneMode::ModeOption.new("Boost", 2_u8)],
    current_mode: 1_u8)
end

describe "Mode Select scene extension" do
  it "stores and recalls CurrentMode through the endpoint's Scenes Management wiring" do
    endpoint = Matter::Endpoint.new(endpoint(1_u16))
    mode = scene_mode
    scenes = build(SceneManagement)
    endpoint.add_cluster(mode)
    endpoint.add_cluster(scenes)
    endpoint.wire_scene_extensions

    response = invoke(scenes, SceneManagement::CMD_STORE_SCENE,
      Matter::Cluster::StoreSceneRequest.new(1_u16, 2_u8), is_case_session: true, fabric_index: 1_u8)
    status = Matter::Cluster::SceneStatusResponse.from_tlv(response.as(Matter::Cluster::CommandResponse).response.as(TLV::Any))
    status.status.should eq(Matter::InteractionModel::StatusCode::Success.value)

    view = invoke(scenes, SceneManagement::CMD_VIEW_SCENE,
      Matter::Cluster::ViewSceneRequest.new(1_u16, 2_u8), is_case_session: true, fabric_index: 1_u8)
    fields = Matter::Cluster::ViewSceneResponseTlv.from_tlv(view.as(Matter::Cluster::CommandResponse).response.as(TLV::Any))
      .extension_field_sets.as(Array(Matter::Cluster::ExtensionFieldSetTlv))
    mode_field = fields.find { |field| field.cluster_id == SceneMode::CLUSTER_ID }
    mode_field.should_not be_nil
    mode_field.as(Matter::Cluster::ExtensionFieldSetTlv).attribute_value_list.find! do |value|
      value.attribute_id == SceneMode::ATTR_CURRENT_MODE
    end.value_unsigned8.should eq(1_u8)

    mode.current_mode = 2_u8
    expect_success(invoke(scenes, SceneManagement::CMD_RECALL_SCENE,
      Matter::Cluster::RecallSceneRequest.new(1_u16, 2_u8), is_case_session: true, fabric_index: 1_u8))
    mode.current_mode.should eq(1_u8)
  end

  it "applies supported unsigned scene modes and ignores invalid or unrelated values" do
    mode = scene_mode
    mode.apply_scene_extension_field_set(SceneManagement::ExtensionFieldSet.new(SceneMode::CLUSTER_ID,
      [{SceneMode::ATTR_CURRENT_MODE, TLV::Any.new(2_u8)}])).should be_true
    mode.current_mode.should eq(2_u8)

    mode.apply_scene_extension_field_set(SceneManagement::ExtensionFieldSet.new(SceneMode::CLUSTER_ID,
      [{SceneMode::ATTR_CURRENT_MODE, TLV::Any.new(3_u8)}])).should be_false
    mode.apply_scene_extension_field_set(SceneManagement::ExtensionFieldSet.new(SceneMode::CLUSTER_ID,
      [{SceneMode::ATTR_CURRENT_MODE, TLV::Any.new(256_u16)}])).should be_false
    mode.apply_scene_extension_field_set(SceneManagement::ExtensionFieldSet.new(Matter::Cluster::OnOff::CLUSTER_ID,
      [{SceneMode::ATTR_CURRENT_MODE, TLV::Any.new(1_u8)}])).should be_false
    mode.current_mode.should eq(2_u8)
  end
end
