require "../spec_helper"

private alias Thermostat = Matter::Cluster::Thermostat
private alias Status = Matter::InteractionModel::Status

private def preset_type : Thermostat::PresetType
  Thermostat::PresetType.new(Thermostat::PresetScenario::Sleep, 2_u8,
    Thermostat::PresetTypeFeatures::SupportsNames)
end

private def sleep_preset(handle : Bytes = Bytes[1_u8]) : Thermostat::Preset
  Thermostat::Preset.new(handle, Thermostat::PresetScenario::Sleep,
    "Sleep", 2700_i16, 1800_i16, false)
end

describe "Thermostat preset foundation" do
  it "uses the Matter 1.6 TLV tags and mandatory null handle for preset creation" do
    preset = Thermostat::Preset.new(nil, Thermostat::PresetScenario::Sleep,
      "Sleep", 2700_i16, 1800_i16, false)
    encoded = preset.to_tlv
    encoded.as_structure[0_u8].value.should be_nil
    Thermostat::Preset.from_tlv(encoded).preset_scenario.should eq(Thermostat::PresetScenario::Sleep)
    request = Thermostat::SetActivePresetRequest.new(nil)
    request.to_tlv.as_structure[0_u8].value.should be_nil
    Thermostat::SetActivePresetRequest.from_tlv(request.to_tlv).preset_handle.should be_nil
  end

  it "activates a configured preset, applies its setpoints and clears on manual change" do
    thermostat = build(Thermostat)
    thermostat.configure_presets([preset_type], [sleep_preset])
    thermostat.activate_preset(Thermostat::SetActivePresetRequest.new(Bytes[1_u8])).should eq(Status.success)
    thermostat.active_preset_handle.should eq(Bytes[1_u8])
    thermostat.occupied_cooling_setpoint.should eq(2700_i16)
    thermostat.occupied_heating_setpoint.should eq(1800_i16)
    thermostat.occupied_heating_setpoint = 1900_i16
    thermostat.active_preset_handle.should be_nil
  end

  it "rejects unknown handles and invalid configuration without partial mutation" do
    thermostat = build(Thermostat)
    thermostat.configure_presets([preset_type], [sleep_preset])
    thermostat.activate_preset(Thermostat::SetActivePresetRequest.new(Bytes[2_u8])).should eq(Status.invalid_command)
    thermostat.active_preset_handle.should be_nil
    expect_raises(ArgumentError) do
      thermostat.configure_presets([preset_type], [sleep_preset, sleep_preset])
    end
    thermostat.presets.size.should eq(1)
    thermostat.activate_preset(Thermostat::SetActivePresetRequest.new(Bytes[1_u8])).should eq(Status.success)
    thermostat.activate_preset(Thermostat::SetActivePresetRequest.new(nil)).should eq(Status.success)
    thermostat.active_preset_handle.should be_nil
  end

  it "enforces scenario capacity, names and setpoint limits" do
    thermostat = build(Thermostat)
    named = preset_type
    thermostat.configure_presets([named], [sleep_preset])
    expect_raises(ArgumentError) do
      thermostat.configure_presets([Thermostat::PresetType.new(Thermostat::PresetScenario::Sleep, 1_u8)],
        [sleep_preset])
    end
    expect_raises(ArgumentError) do
      thermostat.configure_presets([named], [Thermostat::Preset.new(Bytes[2_u8],
        Thermostat::PresetScenario::Sleep, "Hot", 4000_i16, 1800_i16, false)])
    end
    expect_raises(ArgumentError) do
      thermostat.configure_presets([named], [sleep_preset, sleep_preset(Bytes[2_u8]), sleep_preset(Bytes[3_u8])])
    end
    thermostat.presets.map(&.preset_handle).should eq([Bytes[1_u8]])
  end

  it "keeps caller-owned handles and returned lists independent of live state" do
    thermostat = build(Thermostat)
    handle = Bytes[1_u8]
    thermostat.configure_presets([preset_type], [sleep_preset(handle)])
    handle[0] = 9_u8
    thermostat.presets.first.preset_handle.should eq(Bytes[1_u8])
    returned = thermostat.presets
    returned.first.preset_handle.try { |returned_handle| returned_handle[0] = 7_u8 }
    thermostat.presets.first.preset_handle.should eq(Bytes[1_u8])
  end

  it "persists the configured list and active handle while keeping PRES off the wire" do
    thermostat = build(Thermostat)
    thermostat.configure_presets([preset_type], [sleep_preset])
    thermostat.activate_preset(Thermostat::SetActivePresetRequest.new(Bytes[1_u8])).should eq(Status.success)
    saved = thermostat.save_state
    restored = build(Thermostat)
    restored.configure_presets([preset_type], [] of Thermostat::Preset)
    restored.restore_state(saved)
    restored.active_preset_handle.should eq(Bytes[1_u8])
    restored.presets.size.should eq(1)
    restored.occupied_heating_setpoint.should eq(1800_i16)
    restored.feature_map.value.should eq(0x3_u32)
    restored.get_command_metadata(0x06_u32).should be_nil
    restored.get_attribute_metadata(0x50_u32).should be_nil
    expect_status(invoke(restored, 0x06_u32, Thermostat::SetActivePresetRequest.new(Bytes[1_u8])),
      Matter::InteractionModel::StatusCode::UnsupportedCommand)
  end
end
