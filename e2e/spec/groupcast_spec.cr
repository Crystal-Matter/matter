require "./e2e_helper"

# Official chip-tool provisions and transmits legacy Matter groupcast to a
# Crystal device. The same fabric's CASE ACL is kept for subsequent reads.
describe "private groupcast interoperability" do
  device = E2E::Device["matter_level_control"]
  group_id = 0x5551
  group_node = "0xffffffffffff5551"
  keyset_id = 0x6651
  epoch_key = "a0a1a2a3a4a5a6a7a8a9aaabacadaeaf"

  it "accepts mapped group commands only with membership and Group ACL, including after restart" do
    device.commission!
    key_set = %({"groupKeySetID":#{keyset_id},"groupKeySecurityPolicy":0,"epochKey0":"#{epoch_key}","epochStartTime0":1110000,"epochKey1":null,"epochStartTime1":null,"epochKey2":null,"epochStartTime2":null})
    expect_success(device.chip("groupkeymanagement", "key-set-write", key_set, device.node, "0"))
    mapping = %([{"groupId":#{group_id},"groupKeySetID":#{keyset_id},"fabricIndex":1}])
    expect_success(device.write("groupkeymanagement", "group-key-map", mapping, 0))
    expect_success(device.invoke("groups", "add-group", [group_id.to_s, "Groupcast test"]))
    allow_acl = %([{"fabricIndex":1,"privilege":5,"authMode":2,"subjects":[],"targets":[]},{"fabricIndex":1,"privilege":3,"authMode":3,"subjects":[#{group_id}],"targets":[]}])
    deny_acl = %([{"fabricIndex":1,"privilege":5,"authMode":2,"subjects":[],"targets":[]}])
    expect_success(device.write("accesscontrol", "acl", allow_acl, 0))

    expect_success(device.chip("groupsettings", "add-group", "Groupcast test", group_id.to_s))
    expect_success(device.chip("groupsettings", "add-keysets", keyset_id.to_s, "0", "1110000", "hex:#{epoch_key}"))
    expect_success(device.chip("groupsettings", "bind-keyset", group_id.to_s, keyset_id.to_s))

    expect_success(device.invoke("onoff", "off"))
    expect_success(device.chip("onoff", "on", group_node, "1"))
    sleep 1.second
    read_bool(device, "onoff", "on-off", "OnOff").should be_true

    expect_success(device.write("accesscontrol", "acl", deny_acl, 0))
    expect_success(device.invoke("onoff", "off"))
    expect_success(device.chip("onoff", "on", group_node, "1"))
    sleep 1.second
    read_bool(device, "onoff", "on-off", "OnOff").should be_false

    expect_success(device.write("accesscontrol", "acl", allow_acl, 0))
    device.restart!
    expect_success(device.chip("onoff", "on", group_node, "1"))
    sleep 1.second
    read_bool(device, "onoff", "on-off", "OnOff").should be_true
  end
end
