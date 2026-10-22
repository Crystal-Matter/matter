require "./e2e_helper"

private def send_key_status(device : E2E::Device, code : String) : Int64?
  response = expect_success(device.invoke("keypadinput", "send-key", [code]))
  response.output.should contain("SendKeyResponse: {")
  response.int("status")
end

private def keypad_log_since(device : E2E::Device, offset : Int64) : String
  File.open(device.log_path) do |file|
    file.seek(offset)
    file.gets_to_end
  end
end

private def wait_for_keypad_release(device : E2E::Device, offset : Int64, key : String) : String
  deadline = Time.instant + 5.seconds
  loop do
    log = keypad_log_since(device, offset)
    return log if log.includes?("Keypad Release: #{key} on fabric 1")
    raise "Keypad release not observed for #{key}: #{log}" if Time.instant >= deadline
    sleep 100.milliseconds
  end
end

describe "Matter 1.6 Keypad Input interoperability" do
  device = E2E::Device["matter_keypad_input"]

  it "commissions and exchanges typed SendKey responses across restart" do
    device.commission!
    server_list = expect_success(device.read("descriptor", "server-list", 1)).int_list("ServerList")
    server_list.should contain(0x0509_i64)
    read_int(device, "keypadinput", "cluster-revision", "ClusterRevision", 1).should eq(1_i64)
    read_int(device, "keypadinput", "feature-map", "FeatureMap", 1).should eq(7_i64)

    log_offset = File.size(device.log_path)
    send_key_status(device, "1").should eq(0_i64)
    actions = wait_for_keypad_release(device, log_offset, "Up")
    actions.should contain("Keypad Press: Up on fabric 1")
    actions.index("Keypad Press: Up").as(Int32).should be < actions.index("Keypad Release: Up").as(Int32)
    send_key_status(device, "9").should eq(0_i64)
    send_key_status(device, "33").should eq(0_i64)
    send_key_status(device, "106").should eq(0_i64)
    send_key_status(device, "64").should eq(2_i64)
    send_key_status(device, "255").should eq(1_i64)

    device.restart!
    send_key_status(device, "10").should eq(0_i64)
  end
end
