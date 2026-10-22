require "./e2e_helper"

# A dedicated switch enables the provisional Matter 1.6 Listener. Official
# chip-tool commissions it and confirms the three coupled feature adverts.
describe "Matter 1.6 Groupcast Listener advertisement" do
  device = E2E::Device["matter_groupcast_listener"]

  it "joins and adopts a group with chip-tool, derives AUX access, and persists membership" do
    device.commission!
    server_list = expect_success(device.read("descriptor", "server-list", 0))
    server_list.int_list("ServerList").should contain(Matter::Cluster::Groupcast::CLUSTER_ID.to_i64)
    read_int(device, "groupkeymanagement", "feature-map", "FeatureMap", 0).should eq(2)
    read_int(device, "accesscontrol", "feature-map", "FeatureMap", 0).should eq(5)
    group_id = 0x7511
    key_set_id = 0x7512
    epoch_key = "75757575757575757575757575757575"
    key_set = %({"groupKeySetID":#{key_set_id},"groupKeySecurityPolicy":0,"epochKey0":"#{epoch_key}","epochStartTime0":1,"epochKey1":null,"epochStartTime1":null,"epochKey2":null,"epochStartTime2":null})
    expect_success(device.chip("groupkeymanagement", "key-set-write", key_set, device.node, "0"))
    expect_success(device.invoke("groupcast", "join-group", [group_id.to_s, "[1]", key_set_id.to_s], 0))
    membership = expect_success(device.read("groupcast", "membership", 0))
    membership.output.should contain(group_id.to_s)
    expect_success(device.invoke("groupcast", "configure-auxiliary-acl", [group_id.to_s, "true"], 0))
    auxiliary = expect_success(device.read("accesscontrol", "auxiliary-acl", 0))
    auxiliary.output.should contain(group_id.to_s)
    adoption = %([{"groupcastAdopted":true,"fabricIndex":1}])
    expect_success(device.write("groupkeymanagement", "groupcast-adoption", adoption, 0))
    expect_success(device.read("groupkeymanagement", "group-key-map", 0)).output.should contain("0 entries")
    expect_success(device.invoke("groupcast", "groupcast-testing", ["1"], 0))
    read_int(device, "groupcast", "fabric-under-test", "FabricUnderTest", 0).should eq(1)
    expect_success(device.invoke("groupcast", "groupcast-testing", ["0"], 0))
    device.restart!
    read_int(device, "groupkeymanagement", "feature-map", "FeatureMap", 0).should eq(2)
    server_list = expect_success(device.read("descriptor", "server-list", 0))
    server_list.int_list("ServerList").should contain(Matter::Cluster::Groupcast::CLUSTER_ID.to_i64)
    expect_success(device.read("groupcast", "membership", 0)).output.should contain(group_id.to_s)
    expect_success(device.read("groupkeymanagement", "group-key-map", 0)).output.should contain("0 entries")
    expect_success(device.invoke("groupcast", "leave-group", [group_id.to_s], 0))
    expect_success(device.read("groupcast", "membership", 0)).output.should contain("0 entries")
  end
end
