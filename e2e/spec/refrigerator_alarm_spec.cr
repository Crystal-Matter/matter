require "./e2e_helper"

private REFRIGERATOR_ALARM_CLUSTER  = "0x57"
private REFRIGERATOR_MODE_CLUSTER   = "0x52"
private REFRIGERATOR_ALARM_ENDPOINT = "1"
private REFRIGERATOR_RESET_COMMAND  = "0x0"

private def read_refrigerator_alarm(device : E2E::Device, attribute : UInt32) : Int64
  result = expect_success(device.chip("any", "read-by-id", REFRIGERATOR_ALARM_CLUSTER,
    "0x#{attribute.to_s(16)}", device.node, REFRIGERATOR_ALARM_ENDPOINT))
  value = result.output.scan(/\bData = (-?\d+)\b/).last?
  value.try(&.[1].to_i64) || fail("#{result.command}: no numeric data in chip-tool response\n#{result.tail}")
end

describe "Matter 1.6 Refrigerator Alarm interoperability" do
  device = E2E::Device["matter_refrigerator_alarm"]

  it "commissions and exposes DoorOpen alarm without disallowed commands" do
    device.commission!
    read_refrigerator_alarm(device, 0xFFFD_u32).should eq(1_i64)
    read_refrigerator_alarm(device, 0xFFFC_u32).should eq(0_i64)
    read_refrigerator_alarm(device, 0x0003_u32).should eq(1_i64)
    read_refrigerator_alarm(device, 0x0000_u32).should eq(1_i64)
    read_refrigerator_alarm(device, 0x0002_u32).should eq(1_i64)
    expect_failure(device.chip("any", "command-by-id", REFRIGERATOR_ALARM_CLUSTER,
      REFRIGERATOR_RESET_COMMAND, %({"0": "u:1"}), device.node, REFRIGERATOR_ALARM_ENDPOINT), "UNSUPPORTED_COMMAND")
    device.restart!
    read_refrigerator_alarm(device, 0x0003_u32).should eq(1_i64)
    read_refrigerator_alarm(device, 0x0002_u32).should eq(1_i64)
  end

  it "exposes refrigerator mode and retains an accepted mode across restart" do
    revision = expect_success(device.chip("any", "read-by-id", REFRIGERATOR_MODE_CLUSTER,
      "0xFFFD", device.node, REFRIGERATOR_ALARM_ENDPOINT))
    revision.output.should contain("Data = 3")
    expect_failure(device.chip("any", "read-by-id", REFRIGERATOR_MODE_CLUSTER,
      "0x2", device.node, REFRIGERATOR_ALARM_ENDPOINT), "UNSUPPORTED_ATTRIBUTE")
    expect_success(device.chip("any", "command-by-id", REFRIGERATOR_MODE_CLUSTER,
      "0x0", %({"0": "u:9"}), device.node, REFRIGERATOR_ALARM_ENDPOINT))
    unchanged = expect_success(device.chip("any", "read-by-id", REFRIGERATOR_MODE_CLUSTER,
      "0x1", device.node, REFRIGERATOR_ALARM_ENDPOINT))
    unchanged.output.should contain("Data = 0")
    expect_success(device.chip("any", "command-by-id", REFRIGERATOR_MODE_CLUSTER,
      "0x0", %({"0": "u:1"}), device.node, REFRIGERATOR_ALARM_ENDPOINT))
    current = expect_success(device.chip("any", "read-by-id", REFRIGERATOR_MODE_CLUSTER,
      "0x1", device.node, REFRIGERATOR_ALARM_ENDPOINT))
    current.output.should contain("Data = 1")
    device.restart!
    retained = expect_success(device.chip("any", "read-by-id", REFRIGERATOR_MODE_CLUSTER,
      "0x1", device.node, REFRIGERATOR_ALARM_ENDPOINT))
    retained.output.should contain("Data = 1")
  end
end
