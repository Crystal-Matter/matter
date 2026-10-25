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

  it "commits a whole Presets list through AtomicRequest, then activates it" do
    # chip-tool launches a separate process per command, so use the server's
    # bounded delegate maximum while this guarded conformance fixture runs.
    expect_success(device.chip("thermostat", "atomic-request", "0", "[80]",
      device.node, "1", "--Timeout", "60000"))
    preset = %([{"presetHandle":"hex:01","presetScenario":3,"coolingSetpoint":2700,"heatingSetpoint":1900,"builtIn":true}])
    expect_success(device.write("thermostat", "presets", preset, 1))
    expect_success(device.chip("thermostat", "atomic-request", "1", "[80]", device.node, "1"))
    expect_success(device.read("thermostat", "presets", 1)).output.should contain("1900")

    expect_success(device.chip("thermostat", "set-active-preset-request", "hex:01", device.node, "1"))
    expect_success(device.read("thermostat", "active-preset-handle", 1)).output.should contain("01")
    read_int(device, "thermostat", "occupied-heating-setpoint", "OccupiedHeatingSetpoint", 1).should eq(1900_i64)
    expect_success(device.chip("thermostat", "read-event", "active-preset-change", device.node, "1"))
      .output.should contain("CurrentPresetHandle")
  end
end
