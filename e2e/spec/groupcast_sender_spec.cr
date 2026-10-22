require "./e2e_helper"

# The official chip-tool configures an SD-only Matter 1.6 Groupcast node over
# CASE. An empty Endpoints list is a sender membership, with no listener ACL.
describe "Matter 1.6 Groupcast Sender advertisement" do
  device = E2E::Device["matter_groupcast_sender"]

  it "joins a send-only group, hides LN-only fields, and persists it across restart" do
    device.commission!
    server_list = expect_success(device.read("descriptor", "server-list", 0))
    server_list.int_list("ServerList").should contain(Matter::Cluster::Groupcast::CLUSTER_ID.to_i64)
    read_int(device, "groupcast", "feature-map", "FeatureMap", 0).should eq(2)
    read_int(device, "groupkeymanagement", "feature-map", "FeatureMap", 0).should eq(2)
    read_int(device, "accesscontrol", "feature-map", "FeatureMap", 0).should eq(1)

    group_id = 0x7521
    key_set_id = 0x7522
    epoch_key = "75757575757575757575757575757575"
    key_set = %({"groupKeySetID":#{key_set_id},"groupKeySecurityPolicy":0,"epochKey0":"#{epoch_key}","epochStartTime0":1110000,"epochKey1":null,"epochStartTime1":null,"epochKey2":null,"epochStartTime2":null})
    expect_success(device.chip("groupkeymanagement", "key-set-write", key_set, device.node, "0"))
    expect_success(device.invoke("groupcast", "join-group", [group_id.to_s, "[]", key_set_id.to_s], 0))
    membership = expect_success(device.read("groupcast", "membership", 0))
    membership.output.should contain(group_id.to_s)
    expect_success(device.invoke("groupcast", "groupcast-testing", ["2"], 0))
    read_int(device, "groupcast", "fabric-under-test", "FabricUnderTest", 0).should eq(1)
    expect_success(device.invoke("groupcast", "groupcast-testing", ["0"], 0))

    device.restart!
    read_int(device, "groupcast", "feature-map", "FeatureMap", 0).should eq(2)
    expect_success(device.read("groupcast", "membership", 0)).output.should contain(group_id.to_s)
    expect_success(device.invoke("groupcast", "leave-group", [group_id.to_s], 0))
    expect_success(device.read("groupcast", "membership", 0)).output.should contain("0 entries")
  end
end
