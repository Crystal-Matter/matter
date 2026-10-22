require "../spec_helper"

private alias TemperatureControl = Matter::Cluster::TemperatureControl
private alias IMStatus = Matter::InteractionModel::Status
private alias IMCode = Matter::InteractionModel::StatusCode

private def numeric_control(step : Int16? = nil) : TemperatureControl
  features = TemperatureControl::Feature::TemperatureNumber
  features |= TemperatureControl::Feature::TemperatureStep if step
  build(TemperatureControl, feature_map: features,
    min_temperature: 1500_i16, max_temperature: 3500_i16,
    temperature_setpoint: 2000_i16, step: step)
end

private def level_control : TemperatureControl
  build(TemperatureControl, feature_map: TemperatureControl::Feature::TemperatureLevel,
    supported_temperature_levels: ["Cold", "Warm", "Hot"], selected_temperature_level: 1_u8)
end

describe TemperatureControl do
  it "advertises the revision-one TN and STEP model with only read-only conditional attributes" do
    cluster = numeric_control(50_i16)
    cluster.cluster_id.id.should eq(0x0056_u32)
    cluster.cluster_revision.should eq(1_u16)
    cluster.attributes.map(&.id.id).should eq([
      TemperatureControl::ATTR_TEMPERATURE_SETPOINT,
      TemperatureControl::ATTR_MIN_TEMPERATURE,
      TemperatureControl::ATTR_MAX_TEMPERATURE,
      TemperatureControl::ATTR_STEP,
    ])
    cluster.commands.map(&.id.id).should eq([TemperatureControl::CMD_SET_TEMPERATURE])
    cluster.events.should be_empty
    cluster.attributes.all? { |metadata| !metadata.writable? }.should be_true
    read_status(cluster, TemperatureControl::ATTR_SELECTED_TEMPERATURE_LEVEL).status.should eq(IMCode::UnsupportedAttribute)
    read(cluster, TemperatureControl::ATTR_STEP).should eq(50_i16)
  end

  it "advertises the TL model without numeric attributes" do
    cluster = level_control
    cluster.attributes.map(&.id.id).should eq([
      TemperatureControl::ATTR_SELECTED_TEMPERATURE_LEVEL,
      TemperatureControl::ATTR_SUPPORTED_TEMPERATURE_LEVELS,
    ])
    read_status(cluster, TemperatureControl::ATTR_TEMPERATURE_SETPOINT).status.should eq(IMCode::UnsupportedAttribute)
    read(cluster, TemperatureControl::ATTR_SELECTED_TEMPERATURE_LEVEL).should eq(1_u8)
    read_tlv(cluster, TemperatureControl::ATTR_SUPPORTED_TEMPERATURE_LEVELS).as_list.map(&.value.as(String)).should eq(["Cold", "Warm", "Hot"])
  end

  it "encodes feature-conditional command fields on canonical tags" do
    number = TemperatureControl::SetTemperatureRequest.new(target_temperature: 2050_i16)
    number.to_tlv(nil).as_structure.keys.should eq([0_u8])
    TemperatureControl::SetTemperatureRequest.from_tlv(number.to_tlv(nil)).target_temperature.should eq(2050_i16)
    level = TemperatureControl::SetTemperatureRequest.new(target_temperature_level: 2_u8)
    level.to_tlv(nil).as_structure.keys.should eq([1_u8])
  end

  it "rejects invalid feature combinations and numeric configuration" do
    expect_raises(ArgumentError) { build(TemperatureControl, feature_map: TemperatureControl::Feature::None) }
    expect_raises(ArgumentError) do
      build(TemperatureControl, feature_map: TemperatureControl::Feature::TemperatureNumber | TemperatureControl::Feature::TemperatureLevel)
    end
    expect_raises(ArgumentError) { build(TemperatureControl, feature_map: TemperatureControl::Feature::TemperatureStep) }
    expect_raises(ArgumentError) { numeric_control(0_i16) }
    expect_raises(ArgumentError) { numeric_control(60_i16) }
    expect_raises(ArgumentError) do
      build(TemperatureControl, min_temperature: 2000_i16, max_temperature: 2000_i16)
    end
    expect_raises(ArgumentError) do
      build(TemperatureControl, min_temperature: 1500_i16, max_temperature: 3500_i16,
        temperature_setpoint: 1000_i16)
    end
  end

  it "rejects invalid named levels" do
    feature = TemperatureControl::Feature::TemperatureLevel
    expect_raises(ArgumentError) { build(TemperatureControl, feature_map: feature, supported_temperature_levels: [] of String) }
    expect_raises(ArgumentError) { build(TemperatureControl, feature_map: feature, supported_temperature_levels: ["Cold", "Cold"]) }
    expect_raises(ArgumentError) { build(TemperatureControl, feature_map: feature, supported_temperature_levels: ["a" * 17]) }
    expect_raises(ArgumentError) { build(TemperatureControl, feature_map: feature, supported_temperature_levels: ["Cold"], selected_temperature_level: 1_u8) }
    expect_raises(ArgumentError) { build(TemperatureControl, feature_map: feature, supported_temperature_levels: Array.new(33, &.to_s)) }
  end

  it "requires a host and changes a numeric setpoint only after acceptance" do
    cluster = numeric_control(50_i16)
    request = TemperatureControl::SetTemperatureRequest.new(target_temperature: 2050_i16)
    expect_status(invoke(cluster, TemperatureControl::CMD_SET_TEMPERATURE, request), IMCode::InvalidInState)
    cluster.on_set_temperature { |_number, _level| IMStatus.invalid_in_state }
    expect_status(invoke(cluster, TemperatureControl::CMD_SET_TEMPERATURE, request), IMCode::InvalidInState)
    cluster.temperature_setpoint.should eq(2000_i16)
    cluster.on_set_temperature { |number, level| number.should eq(2050_i16); level.should be_nil; IMStatus.success }
    changed = capture_changes(cluster) do
      expect_success(invoke(cluster, TemperatureControl::CMD_SET_TEMPERATURE, request))
    end
    changed.map(&.attribute).should eq([TemperatureControl::ATTR_TEMPERATURE_SETPOINT])
    cluster.temperature_setpoint.should eq(2050_i16)
    write(cluster, TemperatureControl::ATTR_TEMPERATURE_SETPOINT, 2100_i16).status.should eq(IMCode::UnsupportedWrite)
  end

  it "rejects absent, irrelevant, out-of-range and misaligned command fields without calling the host" do
    cluster = numeric_control(50_i16)
    calls = 0
    cluster.on_set_temperature { |_number, _level| calls += 1; IMStatus.success }
    requests = [
      TemperatureControl::SetTemperatureRequest.new,
      TemperatureControl::SetTemperatureRequest.new(target_temperature_level: 1_u8),
      TemperatureControl::SetTemperatureRequest.new(target_temperature: 1499_i16),
      TemperatureControl::SetTemperatureRequest.new(target_temperature: 3501_i16),
      TemperatureControl::SetTemperatureRequest.new(target_temperature: 2025_i16),
      TemperatureControl::SetTemperatureRequest.new(target_temperature: 2050_i16, target_temperature_level: 1_u8),
    ]
    requests.each do |request|
      status = invoke(cluster, TemperatureControl::CMD_SET_TEMPERATURE, request).as(IMStatus).status
      [IMCode::InvalidCommand, IMCode::ConstraintError].should contain(status)
    end
    calls.should eq(0)
    cluster.temperature_setpoint.should eq(2000_i16)
  end

  it "selects named levels through the same host path and persists the index" do
    cluster = level_control
    seen = [] of UInt8
    cluster.on_set_temperature do |number, level|
      number.should be_nil
      seen << level.as(UInt8)
      IMStatus.success
    end
    expect_status(invoke(cluster, TemperatureControl::CMD_SET_TEMPERATURE,
      TemperatureControl::SetTemperatureRequest.new(target_temperature_level: 3_u8)), IMCode::ConstraintError)
    expect_success(invoke(cluster, TemperatureControl::CMD_SET_TEMPERATURE,
      TemperatureControl::SetTemperatureRequest.new(target_temperature_level: 2_u8)))
    seen.should eq([2_u8])
    restored = level_control
    restored.restore_state(cluster.save_state.as(Matter::Storage::Document))
    restored.selected_temperature_level.should eq(2_u8)
  end

  it "persists the accepted numeric setpoint and ignores state from a different feature map" do
    cluster = numeric_control(50_i16)
    cluster.on_set_temperature { |_number, _level| IMStatus.success }
    expect_success(invoke(cluster, TemperatureControl::CMD_SET_TEMPERATURE,
      TemperatureControl::SetTemperatureRequest.new(target_temperature: 2150_i16)))
    restored = numeric_control(50_i16)
    restored.restore_state(cluster.save_state.as(Matter::Storage::Document))
    restored.temperature_setpoint.should eq(2150_i16)
    level = level_control
    level.restore_state(cluster.save_state.as(Matter::Storage::Document))
    level.selected_temperature_level.should eq(1_u8)
  end

  it "lets the host report physical control changes without accepting invalid values" do
    number = numeric_control(50_i16)
    version_delta(number) do
      number.update_temperature_setpoint(2100_i16).status.should eq(IMCode::Success)
    end.should eq(1)
    number.temperature_setpoint.should eq(2100_i16)
    number.update_temperature_setpoint(2125_i16).status.should eq(IMCode::ConstraintError)
    level = level_control
    level.update_selected_temperature_level(0_u8).status.should eq(IMCode::Success)
    level.selected_temperature_level.should eq(0_u8)
    level.update_selected_temperature_level(3_u8).status.should eq(IMCode::ConstraintError)
    number.update_selected_temperature_level(0_u8).status.should eq(IMCode::InvalidInState)
    level.update_temperature_setpoint(2000_i16).status.should eq(IMCode::InvalidInState)
  end
end
