require "../spec_helper"

private alias SuggestionThermostat = Matter::Cluster::Thermostat

describe "Thermostat Suggestions wire preparation" do
  it "round trips the provisional Matter 1.6 structure and commands" do
    handle = Bytes[0x01_u8, 0x02_u8]
    suggestion = SuggestionThermostat::ThermostatSuggestion.new(7_u8, handle, 123_u32, 456_u32)
    SuggestionThermostat::ThermostatSuggestion.from_tlv(suggestion.to_tlv).should eq(suggestion)
    suggestion.to_tlv.as_structure.keys.should eq([0_u8, 1_u8, 2_u8, 3_u8])

    add = SuggestionThermostat::AddThermostatSuggestionRequest.new(handle, nil, 30_u16)
    add.to_tlv.as_structure[1_u8].value.should be_nil
    SuggestionThermostat::AddThermostatSuggestionRequest.from_tlv(add.to_tlv).should eq(add)
    response = SuggestionThermostat::AddThermostatSuggestionResponse.new(7_u8)
    SuggestionThermostat::AddThermostatSuggestionResponse.from_tlv(response.to_tlv).should eq(response)
    remove = SuggestionThermostat::RemoveThermostatSuggestionRequest.new(7_u8)
    SuggestionThermostat::RemoveThermostatSuggestionRequest.from_tlv(remove.to_tlv).should eq(remove)
  end

  it "checks wire field ranges before encoding" do
    expect_raises(ArgumentError, /preset_handle/) do
      SuggestionThermostat::ThermostatSuggestion.new(1_u8, Bytes.new(17), 1_u32, 2_u32)
    end
    expect_raises(ArgumentError, /preset_handle/) do
      SuggestionThermostat::AddThermostatSuggestionRequest.new(Bytes.new(17), nil, 30_u16)
    end
    {0_u16, 29_u16, 1441_u16}.each do |minutes|
      expect_raises(ArgumentError, /expiration_in_minutes/) do
        SuggestionThermostat::AddThermostatSuggestionRequest.new(Bytes[1_u8], nil, minutes)
      end
    end
    SuggestionThermostat::AddThermostatSuggestionRequest.new(Bytes[1_u8], 123_u32, 1440_u16)
      .effective_time.should eq(123_u32)
  end

  it "keeps TSUGGEST and its command metadata closed on production instances" do
    cluster = build(SuggestionThermostat)
    cluster.feature_map.thermostat_suggestions?.should be_false
    {0x53_u32, 0x54_u32, 0x55_u32, 0x56_u32}.each do |id|
      cluster.get_attribute_metadata(id).should be_nil
    end
    {0x07_u32, 0x08_u32}.each do |id|
      cluster.get_command_metadata(id).should be_nil
    end

    features = SuggestionThermostat::Feature::Cooling | SuggestionThermostat::Feature::Heating |
               SuggestionThermostat::Feature::ThermostatSuggestions
    expect_raises(ArgumentError, /requires PRES/) { build(SuggestionThermostat, feature_map: features) }
    expect_raises(ArgumentError, /PRES wire conformance/) do
      build(SuggestionThermostat, feature_map: features | SuggestionThermostat::Feature::Presets)
    end
  end
end
