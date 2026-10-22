require "./e2e_helper"

# The official chip-tool configures an SD-only Matter 1.6 Groupcast node over
# CASE, then commissions a Listener into the same fabric and observes an
# authenticated multicast command before and after the Sender restarts.
describe "Matter 1.6 Groupcast Sender shared-fabric delivery" do
  device = E2E::Device["matter_groupcast_sender"]
  listener = E2E::Device["matter_groupcast_sender_listener"]
  listener_node = "2"

  it "delivers a sender-only group command to a listener on its shared fabric across restart" do
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

    _discriminator, pin = Matter::SetupPayload.parse_manual_code(listener.pairing_code)
    pairing = expect_success(E2E.run(["pairing", "already-discovered", listener_node,
                                      pin.to_s, listener.address, E2E::DEVICE_PORT.to_s], device.storage_dir))
    pairing.output.should contain("Device commissioning completed with success")
    sender_fabric = expect_success(device.read("operationalcredentials", "fabrics", 0)).value("FabricID")
    listener_fabric = expect_success(E2E.run(["operationalcredentials", "read", "fabrics",
                                              listener_node, "0"], device.storage_dir)).value("FabricID")
    sender_fabric.should_not be_nil
    listener_fabric.should eq(sender_fabric)

    expect_success(E2E.run(["groupkeymanagement", "key-set-write", key_set, listener_node, "0"], device.storage_dir))
    expect_success(E2E.run(["groupcast", "join-group", group_id.to_s, "[1]", key_set_id.to_s,
                            listener_node, "0"], device.storage_dir))
    expect_success(E2E.run(["groupcast", "configure-auxiliary-acl", group_id.to_s, "true",
                            listener_node, "0"], device.storage_dir))
    adoption = %([{"groupcastAdopted":true,"fabricIndex":1}])
    expect_success(E2E.run(["groupkeymanagement", "write", "groupcast-adoption", adoption,
                            listener_node, "0"], device.storage_dir))
    expect_success(E2E.run(["onoff", "off", listener_node, "1"], device.storage_dir))
    expect_success(E2E.run(["onoff", "read", "on-off", listener_node, "1"], device.storage_dir))
      .bool("OnOff").should be_false
    expect_success(device.invoke("onoff", "off"))
    expect_success(device.invoke("onoff", "on"))
    sleep 1.second
    expect_success(E2E.run(["onoff", "read", "on-off", listener_node, "1"], device.storage_dir))
      .bool("OnOff").should be_true

    expect_success(E2E.run(["onoff", "off", listener_node, "1"], device.storage_dir))
    expect_success(E2E.run(["onoff", "read", "on-off", listener_node, "1"], device.storage_dir))
      .bool("OnOff").should be_false
    device.restart!
    read_int(device, "groupcast", "feature-map", "FeatureMap", 0).should eq(2)
    expect_success(device.read("groupcast", "membership", 0)).output.should contain(group_id.to_s)
    expect_success(E2E.run(["onoff", "read", "on-off", listener_node, "1"], device.storage_dir))
      .bool("OnOff").should be_false
    expect_success(device.invoke("onoff", "off"))
    expect_success(device.invoke("onoff", "on"))
    sleep 1.second
    expect_success(E2E.run(["onoff", "read", "on-off", listener_node, "1"], device.storage_dir))
      .bool("OnOff").should be_true
    expect_success(device.invoke("groupcast", "leave-group", [group_id.to_s], 0))
    expect_success(device.read("groupcast", "membership", 0)).output.should contain("0 entries")
  end
end
