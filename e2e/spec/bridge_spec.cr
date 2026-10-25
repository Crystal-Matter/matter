require "./e2e_helper"

# examples/matter_bridge_device.cr - Bridge exposing 1..2 bridged On/Off lights
describe "matter_bridge example" do
  device = E2E::Device["matter_bridge"]

  bridged_endpoints = -> {
    expect_success(device.read("descriptor", "parts-list", 0)).int_list("PartsList").map(&.to_i)
  }

  it "commissions with chip-tool" do
    device.commission!
  end

  it "exposes at least one bridged endpoint" do
    endpoints = bridged_endpoints.call
    endpoints.should_not be_empty
    endpoints.each do |endpoint|
      expect_success(device.read("descriptor", "device-type-list", endpoint)).ints("DeviceType").should contain(0x0100_i64)
    end
  end

  it "reports bridged device basic information" do
    endpoint = bridged_endpoints.call.first
    read_value(device, "bridgeddevicebasicinformation", "node-label", "NodeLabel", endpoint).should match(/^Bridged Light \d+$/)
    read_bool(device, "bridgeddevicebasicinformation", "reachable", "Reachable", endpoint).should be_true
  end

  it "does not claim BridgedICDSupport for non-ICD lights" do
    endpoint = bridged_endpoints.call.first
    feature_map = read_int(device, "bridgeddevicebasicinformation", "feature-map", "FeatureMap", endpoint)
    (feature_map & (1_i64 << 20)).should eq(0_i64)
    commands = expect_success(device.read("bridgeddevicebasicinformation", "accepted-command-list", endpoint)).int_list("AcceptedCommandList")
    commands.should_not contain(0x80_i64)
    expect_failure(device.chip("any", "command-by-id", "0x39", "0x80",
      %({"0": "u:1000", "1": "u:30000"}), device.node, endpoint.to_s), "UNSUPPORTED_COMMAND")
  end

  it "toggles every bridged light" do
    bridged_endpoints.call.each do |endpoint|
      before = read_bool(device, "onoff", "on-off", "OnOff", endpoint)
      expect_success(device.invoke("onoff", "toggle", endpoint: endpoint))
      read_bool(device, "onoff", "on-off", "OnOff", endpoint).should eq !before
    end
  end

  it "advertises Actions on the aggregator and invokes the explicit host callback" do
    read_int(device, "actions", "cluster-revision", "ClusterRevision", 0).should eq(1_i64)
    read_value(device, "actions", "action-list", "ActionList", 0).should eq("1 entries")
    endpoints = bridged_endpoints.call
    before = endpoints.map { |endpoint| read_bool(device, "onoff", "on-off", "OnOff", endpoint) }
    expect_success(device.invoke("actions", "instant-action", ["1"], endpoint: 0))
    after = endpoints.map { |endpoint| read_bool(device, "onoff", "on-off", "OnOff", endpoint) }
    after.should eq(before.map { |state| !state })
  end

  it "writes a bridged device node label" do
    endpoint = bridged_endpoints.call.first
    expect_success(device.write("bridgeddevicebasicinformation", "node-label", "Porch Light", endpoint))
    read_value(device, "bridgeddevicebasicinformation", "node-label", "NodeLabel", endpoint).should eq "Porch Light"
  end
end
