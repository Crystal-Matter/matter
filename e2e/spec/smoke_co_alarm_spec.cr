require "./e2e_helper"

private SMOKE_CO_CLUSTER  = "0x5C"
private SMOKE_CO_ENDPOINT = "1"

private def read_smoke_co(device : E2E::Device, attribute : UInt32) : Int64
  result = expect_success(device.chip("any", "read-by-id", SMOKE_CO_CLUSTER,
    "0x#{attribute.to_s(16)}", device.node, SMOKE_CO_ENDPOINT))
  value = result.output.scan(/\bData = (-?\d+)\b/).last?
  value.try(&.[1].to_i64) || fail("#{result.command}: no numeric data in chip-tool response\n#{result.tail}")
end

private def read_smoke_co_bool(device : E2E::Device, attribute : UInt32) : Bool
  result = expect_success(device.chip("any", "read-by-id", SMOKE_CO_CLUSTER,
    "0x#{attribute.to_s(16)}", device.node, SMOKE_CO_ENDPOINT))
  value = result.output.scan(/\bData = (true|false|0|1)\b/i).last?
  raw = value.try(&.[1].downcase) || fail("#{result.command}: no boolean data in chip-tool response\n#{result.tail}")
  raw == "true" || raw == "1"
end

describe "Matter 1.6 Smoke CO Alarm interoperability" do
  device = E2E::Device["matter_smoke_co_alarm"]

  it "commissions and exposes revision two and both sensor feature states" do
    device.commission!
    read_smoke_co(device, 0xFFFD_u32).should eq(2_i64)
    read_smoke_co(device, 0xFFFC_u32).should eq(3_i64)
    read_smoke_co(device, 0x0000_u32).should eq(0_i64)
    read_smoke_co(device, 0x0001_u32).should eq(0_i64)
    read_smoke_co(device, 0x0002_u32).should eq(0_i64)
    read_smoke_co_bool(device, 0x000D_u32).should be_false
  end

  it "starts a self test, rejects overlap, and reports completion" do
    expect_success(device.chip("any", "command-by-id", SMOKE_CO_CLUSTER,
      "0x0", "{}", device.node, SMOKE_CO_ENDPOINT))
    read_smoke_co_bool(device, 0x0005_u32).should be_true
    read_smoke_co(device, 0x0000_u32).should eq(4_i64)
    expect_failure(device.chip("any", "command-by-id", SMOKE_CO_CLUSTER,
      "0x0", "{}", device.node, SMOKE_CO_ENDPOINT), "BUSY")
    sleep 16.seconds
    read_smoke_co_bool(device, 0x0005_u32).should be_false
    read_smoke_co(device, 0x0000_u32).should eq(0_i64)
    complete = expect_success(device.chip(["smokecoalarm", "read-event", "self-test-complete",
                                           device.node, SMOKE_CO_ENDPOINT]))
    complete.output.should contain("SelfTestComplete")
    device.restart!
    read_smoke_co_bool(device, 0x0005_u32).should be_false
    read_smoke_co(device, 0x0000_u32).should eq(0_i64)
  end
end
