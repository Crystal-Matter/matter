require "./e2e_helper"

private ALARM_CLUSTER_ID = "0x64"
private ALARM_ENDPOINT   = "1"

private def read_alarm(device : E2E::Device, attribute_id : UInt32) : Int64
  result = expect_success(device.chip("any", "read-by-id", ALARM_CLUSTER_ID,
    "0x#{attribute_id.to_s(16)}", device.node, ALARM_ENDPOINT))
  value = result.output.scan(/\bData = (-?\d+)\b/).last?
  value.try(&.[1].to_i64) || fail("#{result.command}: no numeric data in chip-tool response\n#{result.tail}")
end

private def invoke_alarm(device : E2E::Device, command_id : UInt32, payload : String) : E2E::Result
  device.chip("any", "command-by-id", ALARM_CLUSTER_ID, "0x#{command_id.to_s(16)}",
    payload, device.node, ALARM_ENDPOINT)
end

describe "Matter 1.6 Temperature Alarm interoperability" do
  device = E2E::Device["matter_temperature_alarm"]

  it "commissions and exposes Alarm Base and temperature threshold metadata" do
    device.commission!
    read_alarm(device, 0xFFFD_u32).should eq(1_i64)                                          # ClusterRevision
    read_alarm(device, 0xFFFC_u32).should eq((1 | (1 << 20) | (1 << 21) | (1 << 24)).to_i64) # FeatureMap
    read_alarm(device, 0x0003_u32).should eq(33_i64)                                         # Supported
    read_alarm(device, 0x0000_u32).should eq(33_i64)                                         # Mask
    read_alarm(device, 0x0002_u32).should eq(0_i64)                                          # State
    read_alarm(device, 0x0080_u32).should eq(5000_i64)                                       # CriticalOverTemperatureThreshold
    expect_failure(device.chip("any", "read-by-id", ALARM_CLUSTER_ID,
      "0x81", device.node, ALARM_ENDPOINT), "UNSUPPORTED_ATTRIBUTE")
  end

  it "validates a threshold command and recomputes the alarm state" do
    expect_failure(invoke_alarm(device, 0x80_u32, %({"0": -2000})), "CONSTRAINT_ERROR")
    read_alarm(device, 0x0080_u32).should eq(5000_i64)
    expect_success(invoke_alarm(device, 0x80_u32, %({"0": "s:4000"})))
    read_alarm(device, 0x0080_u32).should eq(4000_i64)
    read_alarm(device, 0x0002_u32).should eq(1_i64)
    expect_success(invoke_alarm(device, 0x01_u32, %({"0": "u:0"})))
    read_alarm(device, 0x0002_u32).should eq(0_i64)
    read_alarm(device, 0x0000_u32).should eq(0_i64)
  end
end
