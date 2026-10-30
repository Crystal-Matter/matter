require "../spec_helper"

private def scene_response(cluster : Matter::Cluster::ScenesManagement, command_id : UInt32,
                           request, response_type : T.class, fabric_index : UInt8) : T forall T
  result = invoke(cluster, command_id, request, is_case_session: true, fabric_index: fabric_index)
  T.from_tlv(result.as(Matter::Cluster::CommandResponse).response.as(TLV::Any))
end

private def fabric_scoped_scene_commands : Array(Tuple(UInt32, TLV::Any))
  [
    {Matter::Cluster::ScenesManagement::CMD_ADD_SCENE,
     Matter::Cluster::AddSceneRequest.new(1_u16, 1_u8, 0_u32, "Rejected").to_tlv(nil)},
    {Matter::Cluster::ScenesManagement::CMD_VIEW_SCENE,
     Matter::Cluster::ViewSceneRequest.new(1_u16, 1_u8).to_tlv(nil)},
    {Matter::Cluster::ScenesManagement::CMD_REMOVE_SCENE,
     Matter::Cluster::RemoveSceneRequest.new(1_u16, 1_u8).to_tlv(nil)},
    {Matter::Cluster::ScenesManagement::CMD_REMOVE_ALL_SCENES,
     Matter::Cluster::RemoveAllScenesRequest.new(1_u16).to_tlv(nil)},
    {Matter::Cluster::ScenesManagement::CMD_STORE_SCENE,
     Matter::Cluster::StoreSceneRequest.new(1_u16, 1_u8).to_tlv(nil)},
    {Matter::Cluster::ScenesManagement::CMD_RECALL_SCENE,
     Matter::Cluster::RecallSceneRequest.new(1_u16, 1_u8).to_tlv(nil)},
    {Matter::Cluster::ScenesManagement::CMD_GET_SCENE_MEMBERSHIP,
     Matter::Cluster::GetSceneMembershipRequest.new(1_u16).to_tlv(nil)},
    {Matter::Cluster::ScenesManagement::CMD_COPY_SCENE,
     Matter::Cluster::CopySceneRequest.new(0_u8, 1_u16, 1_u8, 1_u16, 2_u8).to_tlv(nil)},
  ] of Tuple(UInt32, TLV::Any)
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

  it "rejects all fabric-scoped scene commands before changing state for unauthenticated or invalid fabrics" do
    cluster = build(Matter::Cluster::ScenesManagement)
    cluster.request_auth_mode = Matter::InteractionModel::EntryAuthMode::Case
    scene_response(cluster, Matter::Cluster::ScenesManagement::CMD_ADD_SCENE,
      Matter::Cluster::AddSceneRequest.new(1_u16, 1_u8, 0_u32, "Saved"),
      Matter::Cluster::SceneStatusResponse, Matter::Fabric::MIN_FABRIC_INDEX)
    before_version = cluster.data_version

    contexts = [
      {false, nil, Matter::Fabric::MIN_FABRIC_INDEX},
      {false, Matter::InteractionModel::EntryAuthMode::Pase, Matter::Fabric::MIN_FABRIC_INDEX},
      {true, Matter::InteractionModel::EntryAuthMode::Case, Matter::DataType::NO_FABRIC},
      {false, Matter::InteractionModel::EntryAuthMode::Group, Matter::DataType::NO_FABRIC},
      {true, Matter::InteractionModel::EntryAuthMode::Case, UInt8::MAX},
      {false, Matter::InteractionModel::EntryAuthMode::Group, UInt8::MAX},
    ]
    contexts.each do |is_case_session, auth_mode, fabric_index|
      cluster.request_auth_mode = auth_mode
      fabric_scoped_scene_commands.each do |command_id, payload|
        expect_status(cluster.invoke_command(command_id, payload,
          is_case_session: is_case_session, fabric_index: fabric_index),
          Matter::InteractionModel::StatusCode::UnsupportedAccess)
        cluster.data_version.should eq(before_version)
        cluster.scenes.size.should eq(1)
        cluster.scenes[{Matter::Fabric::MIN_FABRIC_INDEX, 1_u16, 1_u8}].scene_name.should eq("Saved")
        cluster.scene_info_by_fabric.size.should eq(1)
        cluster.scene_info_by_fabric[Matter::Fabric::MIN_FABRIC_INDEX].scene_valid?.should be_false
      end
    end
  end

  it "accepts group-authenticated scene commands on their fabric" do
    cluster = build(Matter::Cluster::ScenesManagement)
    cluster.request_auth_mode = Matter::InteractionModel::EntryAuthMode::Group
    added = invoke(cluster, Matter::Cluster::ScenesManagement::CMD_ADD_SCENE,
      Matter::Cluster::AddSceneRequest.new(1_u16, 1_u8, 0_u32, "Group scene"),
      is_case_session: false, fabric_index: Matter::Fabric::MIN_FABRIC_INDEX)
    Matter::Cluster::SceneStatusResponse.from_tlv(added.as(Matter::Cluster::CommandResponse).response.as(TLV::Any))
      .status.should eq(Matter::InteractionModel::StatusCode::Success.value)
    view = invoke(cluster, Matter::Cluster::ScenesManagement::CMD_VIEW_SCENE,
      Matter::Cluster::ViewSceneRequest.new(1_u16, 1_u8),
      is_case_session: false, fabric_index: Matter::Fabric::MIN_FABRIC_INDEX)
    Matter::Cluster::ViewSceneResponseTlv.from_tlv(view.as(Matter::Cluster::CommandResponse).response.as(TLV::Any))
      .scene_name.should eq("Group scene")
    expect_success(invoke(cluster, Matter::Cluster::ScenesManagement::CMD_RECALL_SCENE,
      Matter::Cluster::RecallSceneRequest.new(1_u16, 1_u8),
      is_case_session: false, fabric_index: Matter::Fabric::MIN_FABRIC_INDEX))
    cluster.request_auth_mode = Matter::InteractionModel::EntryAuthMode::Case
    scene_response(cluster, Matter::Cluster::ScenesManagement::CMD_VIEW_SCENE,
      Matter::Cluster::ViewSceneRequest.new(1_u16, 1_u8),
      Matter::Cluster::ViewSceneResponseTlv, Matter::Fabric::MIN_FABRIC_INDEX + 1_u8)
      .status.should eq(Matter::InteractionModel::StatusCode::NotFound.value)
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
