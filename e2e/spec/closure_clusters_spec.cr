require "./e2e_helper"

private CONTROL_CLUSTER   = "0x104"
private DIMENSION_CLUSTER = "0x105"
private TIMED             = ["--timedInteractionTimeoutMs", "2000"]

private def closure_read(device : E2E::Device, cluster : String, id : String, endpoint : String) : E2E::Result
  expect_success(device.chip("any", "read-by-id", cluster, id, device.node, endpoint))
end

private def closure_command(device : E2E::Device, cluster : String, id : String, payload : String,
                            endpoint : String, timed : Bool = true) : E2E::Result
  args = ["any", "command-by-id", cluster, id, payload, device.node, endpoint]
  args.concat(TIMED) if timed
  device.chip(args)
end

describe "Matter 1.6 Closure Control and Dimension interoperability" do
  device = E2E::Device["matter_closure"]

  it "commissions the Closure and Closure Panel endpoints with revision-one clusters" do
    device.commission!
    expect_success(device.read("descriptor", "server-list", 1)).int_list("ServerList").should contain(0x0104_i64)
    expect_success(device.read("descriptor", "server-list", 2)).int_list("ServerList").should contain(0x0105_i64)
    closure_read(device, CONTROL_CLUSTER, "0xfffd", "1").output.should contain("Data = 1")
    closure_read(device, DIMENSION_CLUSTER, "0xfffd", "2").output.should contain("Data = 1")
    closure_read(device, DIMENSION_CLUSTER, "0x2", "2").output.should contain("Data = 100")
    closure_read(device, DIMENSION_CLUSTER, "0x3", "2").output.should contain("Data = 500")
    expect_failure(device.chip("any", "read-by-id", CONTROL_CLUSTER, "0x5", device.node, "1"), "UNSUPPORTED_ATTRIBUTE")
  end

  it "enforces timed commands and reports admitted control targets" do
    expect_failure(closure_command(device, CONTROL_CLUSTER, "0x1", %({"0": "u:1"}), "1", false),
      "NEEDS_TIMED_INTERACTION")
    expect_success(closure_command(device, CONTROL_CLUSTER, "0x1", %({"0": "u:1"}), "1"))
    closure_read(device, CONTROL_CLUSTER, "0x4", "1").output.should contain("1")
    expect_success(closure_command(device, CONTROL_CLUSTER, "0x0", "{}", "1", false))
    closure_read(device, CONTROL_CLUSTER, "0x1", "1").output.should contain("Data = 0")
    expect_success(closure_command(device, CONTROL_CLUSTER, "0x2", "{}", "1"))
    closure_read(device, CONTROL_CLUSTER, "0x1", "1").output.should contain("Data = 4")
  end

  it "rounds panel targets and applies bounded steps" do
    expect_success(closure_command(device, DIMENSION_CLUSTER, "0x0", %({"0": "u:1234"}), "2"))
    closure_read(device, DIMENSION_CLUSTER, "0x1", "2").output.should contain("1200")
    expect_success(closure_command(device, DIMENSION_CLUSTER, "0x1",
      %({"0": "u:1", "1": "u:2"}), "2"))
    closure_read(device, DIMENSION_CLUSTER, "0x1", "2").output.should contain("2200")
    expect_failure(closure_command(device, DIMENSION_CLUSTER, "0x1",
      %({"0": "u:1", "1": "u:0"}), "2"), "CONSTRAINT_ERROR")
  end
end
