require "./e2e_helper"

describe "Mode Select CurrentMode scene extension over chip-tool" do
  device = E2E::Device["matter_scenes_fabric"]

  endpoint = 1
  group_id = 73
  scene_id = 6
  eco_mode = 1
  boost_mode = 2

  it "stores and recalls CurrentMode through Scenes Management" do
    device.commission!
    read_int(device, "modeselect", "cluster-revision", "ClusterRevision", endpoint).should eq(2_i64)
    expect_success(device.read("modeselect", "supported-modes", endpoint)).output.should contain("Boost")

    expect_success(device.invoke("modeselect", "change-to-mode", [eco_mode.to_s], endpoint: endpoint))
    expect_success(device.invoke("scenesmanagement", "store-scene", [group_id.to_s, scene_id.to_s], endpoint: endpoint))

    expect_success(device.invoke("modeselect", "change-to-mode", [boost_mode.to_s], endpoint: endpoint))
    read_int(device, "modeselect", "current-mode", "CurrentMode", endpoint).should eq(boost_mode.to_i64)

    expect_success(device.invoke("scenesmanagement", "view-scene", [group_id.to_s, scene_id.to_s], endpoint: endpoint))
    expect_success(device.invoke("scenesmanagement", "recall-scene", [group_id.to_s, scene_id.to_s], endpoint: endpoint))
    read_int(device, "modeselect", "current-mode", "CurrentMode", endpoint).should eq(eco_mode.to_i64)
    expect_success(device.invoke("scenesmanagement", "remove-scene", [group_id.to_s, scene_id.to_s], endpoint: endpoint))
  end
end
