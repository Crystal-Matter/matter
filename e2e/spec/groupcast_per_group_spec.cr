require "./e2e_helper"

describe "Matter 1.6 Groupcast PerGroup shared-fabric delivery" do
  sender = E2E::Device["matter_groupcast_per_group_sender"]
  listener = E2E::Device["matter_groupcast_per_group_listener"]
  listener_node = "2"

  it "routes PerGroup packets across restart and releases the address on LeaveGroup" do
    sender.commission!
    read_int(sender, "groupcast", "feature-map", "FeatureMap", 0).should eq(6)
    _discriminator, pin = Matter::SetupPayload.parse_manual_code(listener.pairing_code)
    expect_success(E2E.run(["pairing", "already-discovered", listener_node,
                            pin.to_s, listener.address, E2E::DEVICE_PORT.to_s], sender.storage_dir))
    expect_success(E2E.run(["groupcast", "read", "feature-map", listener_node, "0"],
      sender.storage_dir)).int("FeatureMap").should eq(5)

    group_id = 0x7531
    key_set_id = 0x7532
    epoch_key = "75757575757575757575757575757575"
    key_set = %({"groupKeySetID":#{key_set_id},"groupKeySecurityPolicy":0,"epochKey0":"#{epoch_key}","epochStartTime0":1110000,"epochKey1":null,"epochStartTime1":null,"epochKey2":null,"epochStartTime2":null})
    expect_success(sender.chip("groupkeymanagement", "key-set-write", key_set, sender.node, "0"))
    expect_success(E2E.run(["groupkeymanagement", "key-set-write", key_set,
                            listener_node, "0"], sender.storage_dir))
    policy = ["--McastAddrPolicy", "1"]
    expect_success(sender.invoke("groupcast", "join-group", [group_id.to_s, "[]", key_set_id.to_s],
      0, policy))
    expect_success(E2E.run(["groupcast", "join-group", group_id.to_s, "[1]", key_set_id.to_s,
                            listener_node, "0"] + policy, sender.storage_dir))
    expect_success(E2E.run(["groupcast", "read", "used-mcast-addr-count", listener_node, "0"],
      sender.storage_dir)).int("UsedMcastAddrCount").should eq(1)
    expect_success(E2E.run(["groupcast", "configure-auxiliary-acl", group_id.to_s, "true",
                            listener_node, "0"], sender.storage_dir))
    expect_success(E2E.run(["onoff", "off", listener_node, "1"], sender.storage_dir))
    expect_success(sender.invoke("onoff", "on"))
    sleep 1.second
    expect_success(E2E.run(["onoff", "read", "on-off", listener_node, "1"], sender.storage_dir))
      .bool("OnOff").should be_true

    listener.restart!
    expect_success(E2E.run(["groupcast", "read", "used-mcast-addr-count", listener_node, "0"],
      sender.storage_dir)).int("UsedMcastAddrCount").should eq(1)
    expect_success(E2E.run(["onoff", "off", listener_node, "1"], sender.storage_dir))
    expect_success(sender.invoke("onoff", "off"))
    expect_success(sender.invoke("onoff", "on"))
    sleep 1.second
    expect_success(E2E.run(["onoff", "read", "on-off", listener_node, "1"], sender.storage_dir))
      .bool("OnOff").should be_true
    expect_success(E2E.run(["groupcast", "leave-group", group_id.to_s,
                            listener_node, "0"], sender.storage_dir))
    expect_success(E2E.run(["groupcast", "read", "used-mcast-addr-count", listener_node, "0"],
      sender.storage_dir)).int("UsedMcastAddrCount").should eq(0)
  end
end
