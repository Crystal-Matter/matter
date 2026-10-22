require "./e2e_helper"

describe "matter_soil_sensor example" do
  device = E2E::Device["matter_soil_sensor"]

  it "commissions as a Soil Sensor and exposes validated Matter 1.6 soil readings" do
    device.commission!
    expect_success(device.read("descriptor", "device-type-list", 1)).int("DeviceType").should eq(0x0045_i64)
    read_int(device, "soilmeasurement", "cluster-revision", "ClusterRevision").should eq(1)

    limits = expect_success(device.read("soilmeasurement", "soil-moisture-measurement-limits"))
    limits.int("MeasurementType").should eq(17)
    limits.int("MinMeasuredValue").should eq(10)
    limits.int("MaxMeasuredValue").should eq(90)
    limits.int("RangeMin").should eq(10)
    limits.int("RangeMax").should eq(90)
    limits.int("PercentMax").should eq(500)
    read_int(device, "soilmeasurement", "soil-moisture-measured-value", "SoilMoistureMeasuredValue").should eq(42)

    device.restart!
    read_int(device, "soilmeasurement", "soil-moisture-measured-value", "SoilMoistureMeasuredValue").should eq(42)
  end
end
