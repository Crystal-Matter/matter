require "./e2e_helper"

private CON_CLUSTER              = "deviceenergymanagement"
private CON_REQUEST_LEAD_SECONDS = 3_600_i64

private def constrain(device : E2E::Device, start_time : Int64, duration : Int32,
                      power : Int32) : E2E::Result
  payload = %({"0":[{"0":"u:#{start_time}","1":"u:#{duration}","2":"s:#{power}","3":"s:900"}],"1":"u:0"})
  device.chip("any", "command-by-id", "0x98", "0x6", payload, device.node, "1")
end

describe "Matter 1.6 Device Energy Management CON interoperability" do
  device = E2E::Device["matter_constrained_heater"]

  it "requests a bounded host forecast and cancels it over chip-tool" do
    device.commission!
    read_int(device, CON_CLUSTER, "feature-map", "FeatureMap").should eq(66_i64)
    before = expect_success(device.read(CON_CLUSTER, "forecast"))
    original_start = before.int("StartTime") || raise "missing StartTime"
    before.int("ForecastID").should eq(1_i64)
    # The fixture may have started long before this spec in the full E2E suite.
    # Build the valid constraint from the command-time clock so it stays future-dated.
    requested = Time.utc.to_unix - Matter::Cluster::DeviceEnergyManagement::MATTER_EPOCH_UNIX_SECONDS +
                CON_REQUEST_LEAD_SECONDS
    expect_failure(constrain(device, requested, 86_401, 2_500), "CONSTRAINT_ERROR")
    expect_success(constrain(device, requested, 1_200, 2_500))
    changed = expect_success(device.read(CON_CLUSTER, "forecast"))
    changed.int("ForecastID").should eq(2_i64)
    changed.int("StartTime").should eq(requested)
    changed.ints("NominalPower").should eq([2_500_i64])
    changed.int("ForecastUpdateReason").should eq(1_i64)
    expect_success(device.invoke(CON_CLUSTER, "cancel-request"))
    restored = expect_success(device.read(CON_CLUSTER, "forecast"))
    restored.int("ForecastID").should eq(3_i64)
    restored.int("StartTime").should eq(original_start)
  end

  it "starts with a fresh host forecast after restart" do
    device.restart!
    forecast = expect_success(device.read(CON_CLUSTER, "forecast"))
    forecast.int("ForecastID").should eq(1_i64)
    forecast.ints("NominalPower").should eq([2_000_i64])
  end
end
