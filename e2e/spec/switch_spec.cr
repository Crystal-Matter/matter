require "./e2e_helper"

# examples/matter_switch_device.cr - On/Off Light on endpoint 1
describe "matter_switch example" do
  device = E2E::Device["matter_switch"]

  it "commissions with chip-tool" do
    device.commission!
    device.commissioned?.should be_true
  end

  it "reports basic information" do
    read_value(device, "basicinformation", "vendor-name", "VendorName", 0).should eq "Spider-Gazelle"
    read_value(device, "basicinformation", "product-name", "ProductName", 0).should eq "Crystal Switch"
  end

  it "reports Matter 1.6 capability minima and configuration version" do
    capabilities = expect_success(device.read("basicinformation", "capability-minima", 0))
    capabilities.int("CaseSessionsPerFabric").should eq(3_i64)
    capabilities.int("SubscriptionsPerFabric").should eq(3_i64)
    capabilities.int("SimultaneousInvocationsSupported").should eq(1_i64)
    capabilities.int("SimultaneousWritesSupported").should eq(1_i64)
    capabilities.int("ReadPathsSupported").should eq(9_i64)
    capabilities.int("SubscribePathsSupported").should eq(3_i64)
    read_int(device, "basicinformation", "configuration-version", "ConfigurationVersion", 0).should eq(1_i64)
  end

  it "lists endpoint 1 in the root descriptor" do
    expect_success(device.read("descriptor", "parts-list", 0)).int_list("PartsList").should contain(1_i64)
    expect_success(device.read("descriptor", "device-type-list", 1)).int("DeviceType").should eq 0x0100_i64
  end

  it "exposes the fixed label" do
    expect_success(device.read("fixedlabel", "label-list")).values("Value").should eq ["Example Switch"]
  end

  it "reads the on/off attribute" do
    read_bool(device, "onoff", "on-off", "OnOff")
  end

  it "toggles on/off" do
    before = read_bool(device, "onoff", "on-off", "OnOff")
    expect_success(device.invoke("onoff", "toggle"))
    read_bool(device, "onoff", "on-off", "OnOff").should eq !before
  end

  it "turns on and off explicitly" do
    expect_success(device.invoke("onoff", "on"))
    read_bool(device, "onoff", "on-off", "OnOff").should be_true
    expect_success(device.invoke("onoff", "off"))
    read_bool(device, "onoff", "on-off", "OnOff").should be_false
  end

  it "writes the StartUpOnOff attribute" do
    expect_success(device.write("onoff", "start-up-on-off", 1))
    read_int(device, "onoff", "start-up-on-off", "StartUpOnOff").should eq 1
  end

  it "exposes the mandatory global attributes" do
    list = expect_success(device.read("onoff", "attribute-list")).int_list("AttributeList")
    list.should_not be_empty
    list.uniq.size.should eq list.size
    [65528_i64, 65529_i64, 65531_i64, 65532_i64, 65533_i64].each { |id| list.should contain(id) }
  end

  # The entrypoint stops the binary with SIGTERM (clean shutdown, storage
  # flushed) and starts it again in the same directory, so this covers the
  # persisted fabric, operational identity and cluster state end to end.
  it "persists on/off state and fabric across a device restart" do
    # StartUpOnOff null = "previous value": the earlier example set it to On,
    # which would make the switch come up on regardless of what was stored.
    expect_success(device.write("onoff", "start-up-on-off", "null"))
    expect_success(device.write("basicinformation", "node-label", "restart-test", 0))
    expect_success(device.invoke("onoff", "on"))
    read_bool(device, "onoff", "on-off", "OnOff").should be_true

    device.restart!

    # Came back commissioned: operational banner, no new pairing code.
    device.operational?.should be_true
    device.restart_log.should_not match(E2E::PAIRING_CODE_RE)

    # Reads succeed => the fabric persisted and CASE works against the restarted node.
    read_bool(device, "onoff", "on-off", "OnOff").should be_true
    read_value(device, "onoff", "start-up-on-off", "StartUpOnOff").should eq "null"
    read_value(device, "basicinformation", "node-label", "NodeLabel", 0).should eq "restart-test"
  end

  # Multi-fabric commissioning window, second fabric, ACL enforcement etc.
  it "passes examples/device_validation.cr" do
    validation = ENV["DEVICE_VALIDATION"]? || "/app/bin/device_validation"
    pending!("#{validation} not built") unless File.exists?(validation)

    device.commission!
    output = IO::Memory.new
    status = Process.run(validation, ["--chip-tool", E2E::CHIP_TOOL, "--storage-a", device.storage_dir, device.node, "1"], output: output, error: output)
    text = E2E.strip_ansi(output.to_s)
    puts "\n" + text.lines.select(&.matches?(/\[(passed|failed)\]|PASS|FAIL/)).join("\n")
    fail("device_validation exited #{status.exit_code}\n#{text}") unless status.success?
  end
end
