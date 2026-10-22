require "./e2e_helper"

module ScenesFabricE2E
  ENDPOINT =  1
  GROUP_ID = 72
  SCENE_ID =  5
  NODE_ID  =  1

  def self.invoke(storage_dir : String, command : String, args : Array(String)) : E2E::Result
    E2E.run(["scenesmanagement", command] + args + [NODE_ID.to_s, ENDPOINT.to_s], storage_dir)
  end

  def self.view(storage_dir : String) : E2E::Result
    invoke(storage_dir, "view-scene", [GROUP_ID.to_s, SCENE_ID.to_s])
  end

  def self.add(storage_dir : String, name : String) : E2E::Result
    invoke(storage_dir, "add-scene", [GROUP_ID.to_s, SCENE_ID.to_s, "0", name, "[]"])
  end

  def self.scene_count(storage_dir : String) : Int64
    result = expect_success(E2E.run(["scenesmanagement", "read", "fabric-scene-info",
                                     NODE_ID.to_s, ENDPOINT.to_s], storage_dir))
    result.int("SceneCount") || fail("chip-tool did not print SceneCount\n#{result.output}")
  end

  def self.open_window(storage_dir : String) : String
    result = expect_success(E2E.run(["pairing", "open-commissioning-window",
                                     NODE_ID.to_s, "1", "900", "1000", "3840"], storage_dir))
    result.output.match(/Manual pairing code:\s*\[?([0-9]{4}-[0-9]{3}-[0-9]{4}|[0-9]{11})\]?/i)
      .try(&.[1]) || fail("chip-tool did not report an enhanced-window pairing code\n#{result.output}")
  end

  def self.pair(storage_dir : String, code : String) : Nil
    Dir.mkdir_p(storage_dir)
    result = expect_success(E2E.run(["pairing", "code", NODE_ID.to_s, code], storage_dir))
    result.output.should contain("Device commissioning completed with success")
  end
end

describe "Scenes Management across independent chip-tool fabrics" do
  device = E2E::Device["matter_level_control"]

  it "isolates scenes and erases the removed fabric before index reuse" do
    device.commission!
    first = device.storage_dir
    second = File.join(E2E::STORAGE_ROOT, "scenes-fabric-second")
    third = File.join(E2E::STORAGE_ROOT, "scenes-fabric-replacement")

    ScenesFabricE2E.pair(second, ScenesFabricE2E.open_window(first))
    expect_success(ScenesFabricE2E.add(first, "Fabric A"))
    expect_success(ScenesFabricE2E.add(second, "Fabric B"))
    first_view = expect_success(ScenesFabricE2E.view(first))
    first_view.value("sceneName").should eq("Fabric A"), first_view.output
    second_view = expect_success(ScenesFabricE2E.view(second))
    second_view.value("sceneName").should eq("Fabric B"), second_view.output
    ScenesFabricE2E.scene_count(first).should eq(1)
    ScenesFabricE2E.scene_count(second).should eq(1)

    # The second administrator removes the first fabric. A third controller
    # then receives the freed local index and must not see the first scene.
    expect_success(E2E.run(["operationalcredentials", "remove-fabric", "1",
                            ScenesFabricE2E::NODE_ID.to_s, "0"], second))
    ScenesFabricE2E.pair(third, ScenesFabricE2E.open_window(second))
    replacement_view = expect_success(ScenesFabricE2E.view(third))
    replacement_view.int("status").should eq(Matter::InteractionModel::StatusCode::NotFound.value), replacement_view.output
    remaining_view = expect_success(ScenesFabricE2E.view(second))
    remaining_view.value("sceneName").should eq("Fabric B"), remaining_view.output
    ScenesFabricE2E.scene_count(third).should eq(0)
    ScenesFabricE2E.scene_count(second).should eq(1)
  end
end
