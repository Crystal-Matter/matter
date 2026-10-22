require "./e2e_helper"

private def send_key_status(device : E2E::Device, code : String) : Int64?
  response = expect_success(device.invoke("keypadinput", "send-key", [code]))
  response.output.should contain("SendKeyResponse: {")
  response.int("status")
end

describe "Matter 1.6 Keypad Input interoperability" do
  device = E2E::Device["matter_keypad_input"]

  it "commissions and exchanges typed SendKey responses across restart" do
    device.commission!
    server_list = expect_success(device.read("descriptor", "server-list", 1)).int_list("ServerList")
    server_list.should contain(0x0509_i64)
    read_int(device, "keypadinput", "cluster-revision", "ClusterRevision", 1).should eq(1_i64)
    read_int(device, "keypadinput", "feature-map", "FeatureMap", 1).should eq(7_i64)

    send_key_status(device, "1").should eq(0_i64)
    send_key_status(device, "9").should eq(0_i64)
    send_key_status(device, "33").should eq(0_i64)
    send_key_status(device, "106").should eq(0_i64)
    send_key_status(device, "64").should eq(2_i64)
    send_key_status(device, "255").should eq(1_i64)

    device.restart!
    send_key_status(device, "10").should eq(0_i64)
  end
end
