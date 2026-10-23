require "./e2e_helper"

private DISHWASHER_ALARM_CLUSTER  = "0x5d"
private DISHWASHER_ALARM_ENDPOINT = "1"

private def read_dishwasher_alarm(device : E2E::Device, attribute : UInt32) : Int64
  result = expect_success(device.chip("any", "read-by-id", DISHWASHER_ALARM_CLUSTER,
    "0x#{attribute.to_s(16)}", device.node, DISHWASHER_ALARM_ENDPOINT))
  value = result.output.scan(/\bData = (-?\d+)\b/).last?
  value.try(&.[1].to_i64) || fail("#{result.command}: no numeric data in chip-tool response\n#{result.tail}")
end

private def invoke_dishwasher_alarm(device : E2E::Device, command : UInt32, payload : String) : E2E::Result
  device.chip("any", "command-by-id", DISHWASHER_ALARM_CLUSTER,
    "0x#{command.to_s(16)}", payload, device.node, DISHWASHER_ALARM_ENDPOINT)
end

describe "Matter 1.6 Dishwasher Alarm interoperability" do
  device = E2E::Device["matter_dishwasher_alarm"]

  it "commissions and advertises canonical Alarm Base attributes" do
    device.commission!
    read_dishwasher_alarm(device, 0xFFFD_u32).should eq(1_i64)
    read_dishwasher_alarm(device, 0xFFFC_u32).should eq(1_i64)
    read_dishwasher_alarm(device, 0x0003_u32).should eq(6_i64)
    read_dishwasher_alarm(device, 0x0000_u32).should eq(6_i64)
    read_dishwasher_alarm(device, 0x0001_u32).should eq(4_i64)
    read_dishwasher_alarm(device, 0x0002_u32).should eq(4_i64)
  end

  it "validates alarm masks and handles Reset and ModifyEnabledAlarms" do
    expect_failure(invoke_dishwasher_alarm(device, 0x01_u32, %({"0": "u:1"})), "INVALID_COMMAND")
    read_dishwasher_alarm(device, 0x0000_u32).should eq(6_i64)
    expect_success(invoke_dishwasher_alarm(device, 0x00_u32, %({"0": "u:4"})))
    read_dishwasher_alarm(device, 0x0002_u32).should eq(0_i64)
    expect_success(invoke_dishwasher_alarm(device, 0x01_u32, %({"0": "u:2"})))
    read_dishwasher_alarm(device, 0x0000_u32).should eq(2_i64)
    read_dishwasher_alarm(device, 0x0002_u32).should eq(0_i64)
    device.restart!
    read_dishwasher_alarm(device, 0x0003_u32).should eq(6_i64)
    read_dishwasher_alarm(device, 0x0001_u32).should eq(4_i64)
  end
end
