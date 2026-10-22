require "../spec_helper"

private def invoke_scene_response(cluster : Matter::Cluster::ScenesManagement, command_id : UInt32,
                                  request, response_type : T.class) : T forall T
  result = invoke(cluster, command_id, request, is_case_session: true, fabric_index: 1_u8)
  T.from_tlv(result.as(Matter::Cluster::CommandResponse).response.as(TLV::Any))
end

# Scene payloads keep their typed extension attributes through command and storage boundaries.
describe Matter::Cluster::ScenesManagement do
  it "retains AddScene extension values when viewing, persisting and recalling a scene" do
    cluster = build(Matter::Cluster::ScenesManagement)
    extension = Matter::Cluster::ExtensionFieldSetTlv.new(
      Matter::Cluster::ColorControl::CLUSTER_ID,
      [Matter::Cluster::AttributeValuePairTlv.new(0_u32, value_unsigned8: 127_u8),
       Matter::Cluster::AttributeValuePairTlv.new(3_u32, value_unsigned16: 32768_u16),
       Matter::Cluster::AttributeValuePairTlv.new(4_u32, value_signed16: -500_i16)])
    request = Matter::Cluster::AddSceneRequest.new(group_id: 1_u16, scene_id: 2_u8, transition_time: 30_u32,
      scene_name: "Evening", extension_field_sets: [extension.to_tlv(nil)])
    added = invoke_scene_response(cluster, Matter::Cluster::ScenesManagement::CMD_ADD_SCENE,
      request, Matter::Cluster::SceneStatusResponse)
    added.status.should eq(Matter::InteractionModel::StatusCode::Success.value)

    restored = build(Matter::Cluster::ScenesManagement)
    restored.restore_state(cluster.save_state.as(Matter::Storage::Document))
    view = invoke_scene_response(restored, Matter::Cluster::ScenesManagement::CMD_VIEW_SCENE,
      Matter::Cluster::ViewSceneRequest.new(group_id: 1_u16, scene_id: 2_u8), Matter::Cluster::ViewSceneResponseTlv)
    view.transition_time.should eq(30_u32)
    view.scene_name.should eq("Evening")
    values = view.extension_field_sets.as(Array(Matter::Cluster::ExtensionFieldSetTlv)).first.attribute_value_list
    values[0].value_unsigned8.should eq(127_u8)
    values[1].value_unsigned16.should eq(32768_u16)
    values[2].value_signed16.should eq(-500_i16)

    applied = [] of Matter::Cluster::ScenesManagement::ExtensionFieldSet
    restored.apply_extension_field_sets = ->(fields : Array(Matter::Cluster::ScenesManagement::ExtensionFieldSet)) { applied.concat(fields); nil }
    expect_success(invoke(restored, Matter::Cluster::ScenesManagement::CMD_RECALL_SCENE,
      Matter::Cluster::RecallSceneRequest.new(group_id: 1_u16, scene_id: 2_u8),
      is_case_session: true, fabric_index: 1_u8))
    applied.first.attribute_value_list.map { |_, value| value.value }.should eq([127_u8, 32768_u16, -500_i16])
  end
end

describe "OnOff scene extension values" do
  [{0_u8, false}, {1_u8, true}, {UInt8::MAX, false}].each do |wire_value, expected|
    it "recalls the unsigned boolean scene value #{wire_value}" do
      scenes = build(Matter::Cluster::ScenesManagement)
      light = build(Matter::Cluster::OnOff, on_off: !expected)
      scenes.apply_extension_field_sets = ->(fields : Array(Matter::Cluster::ScenesManagement::ExtensionFieldSet)) {
        fields.each { |field| light.apply_scene_extension_field_set(field) }
        nil
      }
      extension = Matter::Cluster::ExtensionFieldSetTlv.new(
        Matter::Cluster::OnOff::CLUSTER_ID,
        [Matter::Cluster::AttributeValuePairTlv.new(Matter::Cluster::OnOff::ATTR_ON_OFF, value_unsigned8: wire_value)])
      request = Matter::Cluster::AddSceneRequest.new(group_id: 1_u16, scene_id: 2_u8, transition_time: 0_u32,
        scene_name: "Light", extension_field_sets: [extension.to_tlv(nil)])
      response = invoke_scene_response(scenes, Matter::Cluster::ScenesManagement::CMD_ADD_SCENE,
        request, Matter::Cluster::SceneStatusResponse)
      response.status.should eq(Matter::InteractionModel::StatusCode::Success.value)

      expect_success(invoke(scenes, Matter::Cluster::ScenesManagement::CMD_RECALL_SCENE,
        Matter::Cluster::RecallSceneRequest.new(group_id: 1_u16, scene_id: 2_u8),
        is_case_session: true, fabric_index: 1_u8))
      light.on_off?.should eq(expected)
    end
  end
end
