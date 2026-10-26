require "../spec_helper"

private alias HostSuggest = Matter::Cluster::Thermostat
private alias HostSuggestCode = Matter::InteractionModel::StatusCode

private def host_suggestion_cluster : HostSuggest
  cluster = build(HostSuggest, feature_map: HostSuggest::Feature::Heating)
  types = [
    HostSuggest::PresetType.new(HostSuggest::PresetScenario::Sleep, 1_u8),
    HostSuggest::PresetType.new(HostSuggest::PresetScenario::Wake, 1_u8),
  ]
  presets = [
    HostSuggest::Preset.new(Bytes[1_u8], HostSuggest::PresetScenario::Sleep,
      nil, nil, 1900_i16, false),
    HostSuggest::Preset.new(Bytes[2_u8], HostSuggest::PresetScenario::Wake,
      nil, nil, 2100_i16, false),
  ]
  cluster.configure_presets(types, presets)
  cluster
end

private def host_suggestion_request(handle : Bytes = Bytes[1_u8], effective : UInt32? = nil,
                                    minutes : UInt16 = 30_u16) : HostSuggest::AddThermostatSuggestionRequest
  HostSuggest::AddThermostatSuggestionRequest.new(handle, effective, minutes)
end

describe "Thermostat guarded suggestion host state" do
  it "keeps TSUGGEST hidden while rejecting invalid UTC, handles, and future windows" do
    cluster = host_suggestion_cluster
    cluster.get_attribute_metadata(0x53_u32).should be_nil
    cluster.get_command_metadata(0x07_u32).should be_nil
    feature = HostSuggest::Feature::Heating | HostSuggest::Feature::Presets |
              HostSuggest::Feature::ThermostatSuggestions
    expect_raises(ArgumentError) { build(HostSuggest, feature_map: feature) }

    cluster.add_thermostat_suggestion(host_suggestion_request, nil)
      .as(Matter::InteractionModel::Status).status.should eq(HostSuggestCode::InvalidInState)
    cluster.add_thermostat_suggestion(host_suggestion_request(Bytes[99_u8]), 1_000_u32)
      .as(Matter::InteractionModel::Status).status.should eq(HostSuggestCode::NotFound)
    cluster.add_thermostat_suggestion(host_suggestion_request(effective: 1_000_u32 + 25_u32 * 60_u32 * 60_u32), 1_000_u32)
      .as(Matter::InteractionModel::Status).status.should eq(HostSuggestCode::InvalidCommand)
    cluster.add_thermostat_suggestion(host_suggestion_request(effective: UInt32::MAX - 60_u32), UInt32::MAX - 60_u32)
      .as(Matter::InteractionModel::Status).status.should eq(HostSuggestCode::InvalidCommand)
    cluster.thermostat_suggestions.should be_empty
  end

  it "accepts repeated handles with distinct IDs up to configured capacity" do
    cluster = host_suggestion_cluster
    cluster.configure_suggestion_capacity(5_u8)
    ids = Array.new(5) do
      cluster.add_thermostat_suggestion(host_suggestion_request, 1_000_u32)
        .as(HostSuggest::AddThermostatSuggestionResponse).unique_id
    end
    ids.uniq.size.should eq(5)
    cluster.thermostat_suggestions.size.should eq(5)
    cluster.add_thermostat_suggestion(host_suggestion_request, 1_000_u32)
      .as(Matter::InteractionModel::Status).status.should eq(HostSuggestCode::ResourceExhausted)
    cluster.remove_thermostat_suggestion(HostSuggest::RemoveThermostatSuggestionRequest.new(255_u8))
      .status.should eq(HostSuggestCode::NotFound)
    cluster.remove_thermostat_suggestion(HostSuggest::RemoveThermostatSuggestionRequest.new(ids.first))
      .status.should eq(HostSuggestCode::Success)
  end

  it "accepts a still-active past effective time and enforces the minimum duration" do
    expect_raises(ArgumentError) do
      host_suggestion_request(minutes: 0_u16)
    end
    cluster = host_suggestion_cluster
    added = cluster.add_thermostat_suggestion(host_suggestion_request(effective: 900_u32), 1_000_u32)
      .as(HostSuggest::AddThermostatSuggestionResponse)
    cluster.current_thermostat_suggestion.try(&.unique_id).should eq(added.unique_id)
    cluster.active_preset_handle.should eq(Bytes[1_u8])
  end

  it "selects effective suggestions, follows their presets, and reselects after removal and expiry" do
    cluster = host_suggestion_cluster
    first = cluster.add_thermostat_suggestion(host_suggestion_request(effective: 1_200_u32), 1_000_u32)
      .as(HostSuggest::AddThermostatSuggestionResponse)
    second = cluster.add_thermostat_suggestion(host_suggestion_request(Bytes[2_u8], effective: 1_500_u32), 1_000_u32)
      .as(HostSuggest::AddThermostatSuggestionResponse)
    cluster.current_thermostat_suggestion.should be_nil
    cluster.tick_suggestions(1_199_u32).should eq(0)
    cluster.current_thermostat_suggestion.should be_nil
    cluster.tick_suggestions(1_200_u32).should eq(0)
    cluster.current_thermostat_suggestion.try(&.unique_id).should eq(first.unique_id)
    cluster.active_preset_handle.should eq(Bytes[1_u8])
    cluster.occupied_heating_setpoint.should eq(1900_i16)
    cluster.tick_suggestions(1_500_u32).should eq(0)
    cluster.current_thermostat_suggestion.try(&.unique_id).should eq(first.unique_id)
    cluster.remove_thermostat_suggestion(HostSuggest::RemoveThermostatSuggestionRequest.new(first.unique_id))
      .status.should eq(HostSuggestCode::Success)
    cluster.current_thermostat_suggestion.try(&.unique_id).should eq(second.unique_id)
    cluster.active_preset_handle.should eq(Bytes[2_u8])
    cluster.occupied_heating_setpoint.should eq(2100_i16)
    cluster.tick_suggestions(3_300_u32).should eq(1)
    cluster.current_thermostat_suggestion.should be_nil
  end

  it "persists the list, returns independent handles, and removes orphan suggestions" do
    cluster = host_suggestion_cluster
    response = cluster.add_thermostat_suggestion(host_suggestion_request, 1_000_u32)
      .as(HostSuggest::AddThermostatSuggestionResponse)
    cluster.thermostat_suggestions.first.preset_handle[0] = 99_u8
    cluster.thermostat_suggestions.first.preset_handle.should eq(Bytes[1_u8])
    cluster.configure_suggestion_capacity(6_u8)
    restored = host_suggestion_cluster
    restored.restore_state(cluster.save_state)
    restored.thermostat_suggestions.first.unique_id.should eq(response.unique_id)
    5.times do
      restored.add_thermostat_suggestion(host_suggestion_request, 1_000_u32)
        .should be_a(HostSuggest::AddThermostatSuggestionResponse)
    end
    restored.tick_suggestions(1_000_u32)
    restored.active_preset_handle.should eq(Bytes[1_u8])
    restored.configure_presets([HostSuggest::PresetType.new(HostSuggest::PresetScenario::Wake, 1_u8)],
      [restored.presets.last])
    restored.thermostat_suggestions.should be_empty
    restored.current_thermostat_suggestion.should be_nil
  end

  it "keeps following a suggestion when host presets are reconfigured" do
    cluster = host_suggestion_cluster
    cluster.add_thermostat_suggestion(host_suggestion_request, 1_000_u32)
      .should be_a(HostSuggest::AddThermostatSuggestionResponse)
    cluster.active_preset_handle.should eq(Bytes[1_u8])
    cluster.configure_presets(cluster.preset_types, cluster.presets)
    cluster.current_thermostat_suggestion.try(&.preset_handle).should eq(Bytes[1_u8])
    cluster.active_preset_handle.should eq(Bytes[1_u8])
  end
end
