require "./e2e_helper"

private REQUESTOR_CLUSTER  = "0x554"
private REQUESTOR_ENDPOINT = "1"

private def requestor_command(device : E2E::Device, command : String, payload : String) : E2E::Result
  device.chip("any", "command-by-id", REQUESTOR_CLUSTER, command,
    payload, device.node, REQUESTOR_ENDPOINT)
end

describe "Matter 1.6 WebRTC Requestor signaling interoperability" do
  device = E2E::Device["matter_webrtc_requestor"]

  it "commissions an Aggregator with a fabric-scoped host session" do
    device.commission!
    expect_success(device.read("descriptor", "server-list", 1)).int_list("ServerList").should contain(0x0554_i64)
    read_int(device, "webrtctransportrequestor", "cluster-revision", "ClusterRevision").should eq(2_i64)
    sessions = expect_success(device.read("webrtctransportrequestor", "current-sessions"))
    sessions.output.should contain("7")
  end

  it "binds all signaling commands to an existing CASE session and delegates without media" do
    expect_failure(requestor_command(device, "0x0", %({"0":"u:99","1":"v=0"})), "NOT_FOUND")
    expect_failure(requestor_command(device, "0x1", %({"0":"u:99","1":"v=0"})), "NOT_FOUND")
    expect_failure(requestor_command(device, "0x2", %({"0":"u:99","1":[{"0":"candidate","1":"0","2":"u:0"}]})), "NOT_FOUND")
    expect_failure(requestor_command(device, "0x3", %({"0":"u:99","1":"u:2"})), "NOT_FOUND")

    expect_failure(requestor_command(device, "0x0", %({"0":"u:7","1":""})), "CONSTRAINT_ERROR")
    expect_failure(requestor_command(device, "0x0", %({"0":"u:7","1":"v=0"})), "INVALID_IN_STATE")
    expect_failure(requestor_command(device, "0x1", %({"0":"u:7","1":"v=0"})), "INVALID_IN_STATE")
    expect_failure(requestor_command(device, "0x2", %({"0":"u:7","1":[{"0":"candidate","1":"0","2":"u:0"}]})), "INVALID_IN_STATE")
    expect_failure(requestor_command(device, "0x3", %({"0":"u:7","1":"u:2"})), "INVALID_IN_STATE")
    expect_failure(requestor_command(device, "0x0", %({"0":"u:7","1":"v=0"})), "NOT_FOUND")
  end
end
