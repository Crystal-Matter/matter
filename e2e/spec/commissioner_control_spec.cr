require "./e2e_helper"

describe "synthetic Commissioner Control Aggregator" do
  device = E2E::Device["matter_commissioner_control"]

  it "commissions the opt-in fixture" do
    device.commission!
  end

  it "advertises FabricSynchronization only with its explicit test host" do
    categories = expect_success(device.read("commissionercontrol", "supported-device-categories", 0))
    categories.int("SupportedDeviceCategories").should eq(1_i64)
    identity = expect_success(device.read("basicinformation", "vendor-id", 0))
    identity.int("VendorID").should eq(0xFFF1_i64)
  end

  it "emits an approved result and returns a synthetic one-use reverse window" do
    request_id = "7001"
    expect_success(device.invoke("commissionercontrol", "request-commissioning-approval",
      [request_id, "65521", "4660"], endpoint: 0))

    result = expect_success(device.chip(
      ["commissionercontrol", "read-event", "commissioning-request-result", device.node, "0"]))
    result.output.should contain("RequestID")
    result.output.should contain(request_id)
    result.output.should contain("StatusCode")
    result.int("StatusCode").should eq(0_i64)

    reverse = expect_success(device.invoke("commissionercontrol", "commission-node",
      [request_id, "30"], endpoint: 0))
    reverse.output.should contain("ReverseOpenCommissioningWindow")
    reverse.int("commissioningTimeout").should eq(180_i64)
    reverse.int("discriminator").should eq(3840_i64)
    expect_failure(device.invoke("commissionercontrol", "commission-node",
      [request_id, "30"], endpoint: 0), "FAILURE")
  end

  it "denies a request for an unexpected target VID and PID" do
    request_id = "7002"
    expect_success(device.invoke("commissionercontrol", "request-commissioning-approval",
      [request_id, "65521", "4661"], endpoint: 0))
    expect_failure(device.invoke("commissionercontrol", "commission-node",
      [request_id, "30"], endpoint: 0), "FAILURE")
  end
end
