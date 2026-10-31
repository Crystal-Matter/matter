require "../spec_helper"
require "../../src/matter/cluster/access_control"
require "../../src/matter/cluster/scenes_management"
require "../../src/matter/protocol/im_handler"

private alias FabricScenes = Matter::Cluster::ScenesManagement
private alias FabricScenesAcl = Matter::Cluster::AccessControl

private def read_fabric_scene_info(cluster : FabricScenes, acl : FabricScenesAcl,
                                   fabric_index : UInt8, fabric_filtered : Bool) : Array(Matter::Cluster::SceneInfoTlv)
  path = Matter::InteractionModel::AttributePath.new(
    endpoint: cluster.endpoint_id.number,
    cluster: FabricScenes::CLUSTER_ID,
    attribute: FabricScenes::ATTR_FABRIC_SCENE_INFO)
  request = Matter::InteractionModel::ReadRequestMessage.new(
    attribute_requests: [path], fabric_filtered: fabric_filtered)
  parsed = Matter::Protocol::IMHandler.parse_read_request(request.to_slice)
    .as(Matter::InteractionModel::ReadRequestMessage)
  clusters = {
    {Matter::Node::ROOT_ENDPOINT_ID, FabricScenesAcl::CLUSTER_ID} => acl.as(Matter::Cluster::Base),
    {cluster.endpoint_id.number, FabricScenes::CLUSTER_ID}        => cluster.as(Matter::Cluster::Base),
  }
  reports = Matter::Protocol::IMHandler.read_attributes(parsed.attribute_requests, clusters,
    fabric_index: fabric_index, is_case_session: true, peer_subject_ids: [101_u64],
    fabric_filtered: parsed.fabric_filtered != false)
  reports.size.should eq(1)
  data = reports.first.attribute_data || fail "expected FabricSceneInfo attribute data"
  TLV::Serializable.deserialize_value(data.data, Array(Matter::Cluster::SceneInfoTlv))
end

describe "Scenes Management FabricSceneInfo fabric filtering" do
  it "includes other fabrics only for unfiltered authenticated reads, including after restart" do
    acl = FabricScenesAcl.new(endpoint(0))
    [1_u8, 2_u8].each do |fabric_index|
      acl.acl << FabricScenesAcl::AccessControlEntry.new(
        FabricScenesAcl::AccessControlEntryPrivilege::Administer,
        FabricScenesAcl::AccessControlEntryAuthMode::CASE, [101_u64], nil, fabric_index)
    end
    cluster = FabricScenes.new(endpoint(1))
    {1_u8 => [1_u8], 2_u8 => [1_u8, 2_u8]}.each do |fabric_index, scene_ids|
      scene_ids.each do |scene_id|
        response = invoke(cluster, FabricScenes::CMD_ADD_SCENE,
          Matter::Cluster::AddSceneRequest.new(1_u16, scene_id, 0_u32, "Saved"),
          is_case_session: true, fabric_index: fabric_index)
        Matter::Cluster::SceneStatusResponse.from_tlv(
          response.as(Matter::Cluster::CommandResponse).response.as(TLV::Any)).status.should eq(
          Matter::InteractionModel::StatusCode::Success.value)
      end
    end

    restored = FabricScenes.new(endpoint(1))
    restored.restore_state(cluster.save_state.as(Matter::Storage::Document))
    [cluster, restored].each do |scenes|
      [1_u8, 2_u8].each do |fabric_index|
        filtered = read_fabric_scene_info(scenes, acl, fabric_index, true)
        filtered.map(&.fabric_index).should eq([fabric_index])
        filtered.first.scene_count.should eq(fabric_index)

        unfiltered = read_fabric_scene_info(scenes, acl, fabric_index, false)
        unfiltered.map(&.fabric_index).should eq([1_u8, 2_u8])
        unfiltered.map(&.scene_count).should eq([1_u8, 2_u8])
      end
    end
  end

  it "synthesizes the accessing fabric's empty info without exposing an absent fabric as a stored scene" do
    acl = FabricScenesAcl.new(endpoint(0))
    acl.acl << FabricScenesAcl::AccessControlEntry.new(
      FabricScenesAcl::AccessControlEntryPrivilege::Administer,
      FabricScenesAcl::AccessControlEntryAuthMode::CASE, [101_u64], nil, 1_u8)
    cluster = FabricScenes.new(endpoint(1))
    read_fabric_scene_info(cluster, acl, 1_u8, false).map(&.fabric_index).should eq([1_u8])
    read_fabric_scene_info(cluster, acl, 1_u8, false).first.scene_count.should eq(0_u8)
    cluster.scene_info_by_fabric.should be_empty

    cluster.request_fabric_filtered = false
    cluster.read_attribute(FabricScenes::ATTR_FABRIC_SCENE_INFO)
      .as(Matter::InteractionModel::Status).status.should eq(
      Matter::InteractionModel::StatusCode::UnsupportedAccess)
  end
end
