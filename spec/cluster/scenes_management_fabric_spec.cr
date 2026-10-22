require "../spec_helper"

private def scene_response(cluster : Matter::Cluster::ScenesManagement, command_id : UInt32,
                           request, response_type : T.class, fabric_index : UInt8) : T forall T
  result = invoke(cluster, command_id, request, is_case_session: true, fabric_index: fabric_index)
  T.from_tlv(result.as(Matter::Cluster::CommandResponse).response.as(TLV::Any))
end

describe "Scenes Management fabric isolation" do
  it "keeps the same group and scene IDs independent on two fabrics across restart" do
    cluster = build(Matter::Cluster::ScenesManagement)
    add = Matter::Cluster::ScenesManagement::CMD_ADD_SCENE
    view = Matter::Cluster::ScenesManagement::CMD_VIEW_SCENE
    group_id = 1_u16
    scene_id = 2_u8

    first = Matter::Cluster::AddSceneRequest.new(group_id: group_id, scene_id: scene_id,
      transition_time: 10_u32, scene_name: "Fabric one", extension_field_sets: [] of TLV::Any)
    scene_response(cluster, add, first, Matter::Cluster::SceneStatusResponse, 1_u8).status.should eq(
      Matter::InteractionModel::StatusCode::Success.value)

    lookup = Matter::Cluster::ViewSceneRequest.new(group_id: group_id, scene_id: scene_id)
    scene_response(cluster, view, lookup, Matter::Cluster::ViewSceneResponseTlv, 2_u8).status.should eq(
      Matter::InteractionModel::StatusCode::NotFound.value)

    second = Matter::Cluster::AddSceneRequest.new(group_id: group_id, scene_id: scene_id,
      transition_time: 20_u32, scene_name: "Fabric two", extension_field_sets: [] of TLV::Any)
    scene_response(cluster, add, second, Matter::Cluster::SceneStatusResponse, 2_u8).status.should eq(
      Matter::InteractionModel::StatusCode::Success.value)

    restored = build(Matter::Cluster::ScenesManagement)
    restored.restore_state(cluster.save_state.as(Matter::Storage::Document))
    scene_response(restored, view, lookup, Matter::Cluster::ViewSceneResponseTlv, 1_u8).scene_name.should eq("Fabric one")
    scene_response(restored, view, lookup, Matter::Cluster::ViewSceneResponseTlv, 2_u8).scene_name.should eq("Fabric two")
    restored.scene_count(1_u8).should eq(1)
    restored.scene_count(2_u8).should eq(1)
  end

  it "rejects scene commands without an authenticated fabric" do
    cluster = build(Matter::Cluster::ScenesManagement)
    request = Matter::Cluster::ViewSceneRequest.new(group_id: 1_u16, scene_id: 1_u8)
    expect_status(invoke(cluster, Matter::Cluster::ScenesManagement::CMD_VIEW_SCENE, request),
      Matter::InteractionModel::StatusCode::UnsupportedAccess)
    cluster.read_attribute(Matter::Cluster::ScenesManagement::ATTR_FABRIC_SCENE_INFO)
      .as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAccess)
  end

  it "does not let another fabric remove or recall a scene" do
    cluster = build(Matter::Cluster::ScenesManagement)
    add = Matter::Cluster::AddSceneRequest.new(group_id: 1_u16, scene_id: 1_u8,
      transition_time: 0_u32, scene_name: "Fabric one", extension_field_sets: [] of TLV::Any)
    scene_response(cluster, Matter::Cluster::ScenesManagement::CMD_ADD_SCENE, add,
      Matter::Cluster::SceneStatusResponse, 1_u8)

    removal = Matter::Cluster::RemoveSceneRequest.new(group_id: 1_u16, scene_id: 1_u8)
    scene_response(cluster, Matter::Cluster::ScenesManagement::CMD_REMOVE_SCENE, removal,
      Matter::Cluster::SceneStatusResponse, 2_u8).status.should eq(Matter::InteractionModel::StatusCode::NotFound.value)
    recall = Matter::Cluster::RecallSceneRequest.new(group_id: 1_u16, scene_id: 1_u8)
    expect_status(invoke(cluster, Matter::Cluster::ScenesManagement::CMD_RECALL_SCENE, recall,
      is_case_session: true, fabric_index: 2_u8), Matter::InteractionModel::StatusCode::NotFound)
    cluster.has_scene?(1_u16, 1_u8, 1_u8).should be_true
  end

  it "erases only the removed fabric before its index can be reused" do
    cluster = build(Matter::Cluster::ScenesManagement)
    request = Matter::Cluster::AddSceneRequest.new(group_id: 1_u16, scene_id: 1_u8,
      transition_time: 0_u32, scene_name: "Saved", extension_field_sets: [] of TLV::Any)
    [1_u8, 2_u8].each do |fabric_index|
      scene_response(cluster, Matter::Cluster::ScenesManagement::CMD_ADD_SCENE, request,
        Matter::Cluster::SceneStatusResponse, fabric_index)
    end

    cluster.remove_fabric(1_u8)
    cluster.has_scene?(1_u16, 1_u8, 1_u8).should be_false
    cluster.has_scene?(1_u16, 1_u8, 2_u8).should be_true

    restored = build(Matter::Cluster::ScenesManagement)
    restored.restore_state(cluster.save_state.as(Matter::Storage::Document))
    lookup = Matter::Cluster::ViewSceneRequest.new(group_id: 1_u16, scene_id: 1_u8)
    scene_response(restored, Matter::Cluster::ScenesManagement::CMD_VIEW_SCENE, lookup,
      Matter::Cluster::ViewSceneResponseTlv, 1_u8).status.should eq(Matter::InteractionModel::StatusCode::NotFound.value)
    scene_response(restored, Matter::Cluster::ScenesManagement::CMD_VIEW_SCENE, lookup,
      Matter::Cluster::ViewSceneResponseTlv, 2_u8).status.should eq(Matter::InteractionModel::StatusCode::Success.value)
  end
end
