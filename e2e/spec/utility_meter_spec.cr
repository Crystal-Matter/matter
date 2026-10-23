require "./e2e_helper"

private METER_CLUSTER_ID = "0xb06"
private METER_ENDPOINT   = "1"

private def meter_read(device : E2E::Device, attribute_id : UInt32) : E2E::Result
  expect_success(device.chip("any", "read-by-id", METER_CLUSTER_ID,
    "0x#{attribute_id.to_s(16)}", device.node, METER_ENDPOINT))
end

private def meter_read_int(device : E2E::Device, attribute_id : UInt32) : Int64
  result = meter_read(device, attribute_id)
  value = result.output.scan(/\bData = (-?\d+)\b/).last?
  value.try(&.[1].to_i64) || fail("#{result.command}: no numeric data in chip-tool response\n#{result.tail}")
end

describe "Matter 1.6 Meter Identification interoperability" do
  device = E2E::Device["matter_utility_meter"]

  it "commissions a utility meter and exposes its identity and power limit" do
    device.commission!
    expect_success(device.read("descriptor", "device-type-list", 1)).int("DeviceType").should eq(0x0511_i64)
    meter_read_int(device, 0xFFFD_u32).should eq(1_i64)
    meter_read_int(device, 0xFFFC_u32).should eq(1_i64)
    meter_read_int(device, 0x0000_u32).should eq(0_i64)
    meter_read(device, 0x0001_u32).output.should contain("AU-NSW-POD-001")
    meter_read(device, 0x0002_u32).output.should contain("MTR-2026-001")
    meter_read(device, 0x0003_u32).output.should contain("DLMS/COSEM 1.0")
    threshold = meter_read(device, 0x0004_u32).output
    threshold.should contain("12000")
    threshold.should contain("15000")

    device.restart!
    meter_read(device, 0x0002_u32).output.should contain("MTR-2026-001")
  end

  it "serves Matter 1.6 grid conditions and accepts local-generation writes" do
    read_int(device, "electricalgridconditions", "cluster-revision", "ClusterRevision", 1).should eq(1_i64)
    read_int(device, "electricalgridconditions", "feature-map", "FeatureMap", 1).should eq(1_i64)
    current = expect_success(device.read("electricalgridconditions", "current-conditions", 1)).output
    current.should contain("220")
    forecast = expect_success(device.read("electricalgridconditions", "forecast-conditions", 1)).output
    forecast.should contain("180")
    forecast.should contain("260")

    expect_success(device.write("electricalgridconditions", "local-generation-available", "true", 1))
    expect_success(device.read("electricalgridconditions", "local-generation-available", 1))
      .value("LocalGenerationAvailable").should eq("TRUE")
    device.restart!
    expect_success(device.read("electricalgridconditions", "current-conditions", 1)).output.should contain("220")
  end
end
