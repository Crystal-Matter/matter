require "./e2e_helper"

describe "Matter Thermostat Presets guarded fixture" do
  device = E2E::Device["matter_thermostat_presets"]

  it "commissions and exposes the guarded PRES metadata and configured list" do
    device.commission!
    read_int(device, "thermostat", "cluster-revision", "ClusterRevision", 1).should eq(9_i64)
    read_int(device, "thermostat", "feature-map", "FeatureMap", 1).should eq(0x303_i64)
    read_int(device, "thermostat", "number-of-presets", "NumberOfPresets", 1).should eq(2_i64)
    expect_success(device.read("thermostat", "preset-types", 1)).output.should contain("PresetScenario")
    expect_success(device.read("thermostat", "presets", 1)).output.should contain("BuiltIn")
  end

  it "activates a preset and emits the TEVT ActivePresetChange event" do
    expect_success(device.chip("thermostat", "set-active-preset-request", "hex:01", device.node, "1"))
    expect_success(device.read("thermostat", "active-preset-handle", 1)).output.should contain("01")
    read_int(device, "thermostat", "occupied-heating-setpoint", "OccupiedHeatingSetpoint", 1).should eq(1800_i64)
    expect_success(device.chip("thermostat", "read-event", "active-preset-change", device.node, "1"))
      .output.should contain("CurrentPresetHandle")
  end
end
