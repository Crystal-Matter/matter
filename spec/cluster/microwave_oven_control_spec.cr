require "../spec_helper"

private alias MicrowaveControl = Matter::Cluster::MicrowaveOvenControl
private alias MicrowaveMode = Matter::Cluster::MicrowaveOvenMode
private alias ModeBase = Matter::Cluster::ModeBase
private alias IMStatus = Matter::InteractionModel::Status
private alias IMCode = Matter::InteractionModel::StatusCode

private def microwave_control_mode : MicrowaveMode
  modes = [
    ModeBase::Option.new("Normal", 0_u8, [ModeBase::Tag.new(MicrowaveMode::ModeTag::Normal.value)]),
    ModeBase::Option.new("Defrost", 1_u8, [ModeBase::Tag.new(MicrowaveMode::ModeTag::Defrost.value)]),
  ]
  build(MicrowaveMode, supported_modes: modes, current_mode: 1_u8)
end

private def microwave_control(mode : MicrowaveMode = microwave_control_mode,
                              feature_map : MicrowaveControl::Feature = MicrowaveControl::Feature::PowerAsNumber,
                              min_power : UInt8? = nil, max_power : UInt8? = nil,
                              power_step : UInt8? = nil) : MicrowaveControl
  build(MicrowaveControl, mode_cluster: mode, max_cook_time: 3600_u32,
    feature_map: feature_map, min_power: min_power, max_power: max_power,
    power_step: power_step)
end

describe "Matter 1.6 Microwave Oven Control" do
  it "advertises revision one, numeric power, and the mandatory command" do
    cluster = microwave_control
    cluster.cluster_id.id.should eq(0x005F_u32)
    cluster.cluster_revision.should eq(1_u16)
    cluster.attributes.map(&.id.id).should eq([
      MicrowaveControl::ATTR_COOK_TIME,
      MicrowaveControl::ATTR_MAX_COOK_TIME,
      MicrowaveControl::ATTR_POWER_SETTING,
    ])
    cluster.commands.map(&.id.id).should eq([MicrowaveControl::CMD_SET_COOKING_PARAMETERS])
    cluster.attributes.all? { |attribute| !attribute.writable? }.should be_true
    read(cluster, MicrowaveControl::ATTR_COOK_TIME).should eq(30_u32)
    read(cluster, MicrowaveControl::ATTR_POWER_SETTING).should eq(100_u8)
    read_status(cluster, MicrowaveControl::ATTR_MIN_POWER).status.should eq(IMCode::UnsupportedAttribute)
  end

  it "encodes optional command fields with their canonical context tags" do
    request = MicrowaveControl::SetCookingParametersRequest.new(
      cook_mode: 1_u8, cook_time: 120_u32, power_setting: 50_u8, start_after_setting: true)
    request.to_tlv(nil).as_structure.keys.should eq([0_u8, 1_u8, 2_u8, 4_u8])
    MicrowaveControl::SetCookingParametersRequest.from_tlv(request.to_tlv(nil)).cook_time.should eq(120_u32)
    watt_request = MicrowaveControl::SetCookingParametersRequest.new(watt_setting_index: 1_u8)
    watt_request.to_tlv(nil).as_structure.keys.should eq([3_u8])
    MicrowaveControl::SetCookingParametersRequest.from_tlv(watt_request.to_tlv(nil)).watt_setting_index.should eq(1_u8)
  end

  it "requires a valid numeric power model and fixed cook-time bound" do
    mode = microwave_control_mode
    expect_raises(ArgumentError) { build(MicrowaveControl, mode_cluster: mode, max_cook_time: 0_u32) }
    expect_raises(ArgumentError) { build(MicrowaveControl, mode_cluster: mode, max_cook_time: 86_401_u32) }
    expect_raises(ArgumentError) { microwave_control(mode, MicrowaveControl::Feature::None) }
    expect_raises(ArgumentError) { microwave_control(mode, MicrowaveControl::Feature::PowerNumberLimits) }
    expect_raises(ArgumentError) { microwave_control(mode, MicrowaveControl::Feature.from_value(0x03_u32)) }
    limited = MicrowaveControl::Feature::PowerAsNumber | MicrowaveControl::Feature::PowerNumberLimits
    expect_raises(ArgumentError) { microwave_control(mode, limited) }
    expect_raises(ArgumentError) { microwave_control(mode, limited, 1_u8, 10_u8, 4_u8) }
    expect_raises(ArgumentError) { microwave_control(mode, limited, 10_u8, 10_u8, 1_u8) }
    without_normal = build(MicrowaveMode, supported_modes: [
      ModeBase::Option.new("Quick", 0_u8, [ModeBase::Tag.new(1_u16)]),
      ModeBase::Option.new("Defrost", 1_u8, [ModeBase::Tag.new(MicrowaveMode::ModeTag::Defrost.value)]),
    ], current_mode: 1_u8)
    expect_raises(ArgumentError) { microwave_control(without_normal) }
  end

  it "uses Normal, 30 seconds, and maximum power when fields are absent" do
    mode = microwave_control_mode
    cluster = microwave_control(mode)
    expect_status(invoke(cluster, MicrowaveControl::CMD_SET_COOKING_PARAMETERS,
      MicrowaveControl::SetCookingParametersRequest.new(cook_mode: 0_u8)), IMCode::InvalidInState)
    seen = [] of Tuple(UInt8, UInt32, UInt8, Bool)
    cluster.on_set_cooking_parameters do |selected_mode, seconds, power, start|
      seen << {selected_mode, seconds, power, start}
      IMStatus.success
    end
    expect_success(invoke(cluster, MicrowaveControl::CMD_SET_COOKING_PARAMETERS,
      MicrowaveControl::SetCookingParametersRequest.new(cook_mode: 0_u8)))
    seen.should eq([{0_u8, 30_u32, 100_u8, false}])
    expect_success(invoke(cluster, MicrowaveControl::CMD_SET_COOKING_PARAMETERS,
      MicrowaveControl::SetCookingParametersRequest.new(cook_time: 30_u32)))
    seen.last.should eq({0_u8, 30_u32, 100_u8, false})
    mode.current_mode.should eq(0_u8)
    cluster.cook_time.should eq(30_u32)
    cluster.power_setting.should eq(100_u8)
    write(cluster, MicrowaveControl::ATTR_COOK_TIME, 100_u32).status.should eq(IMCode::UnsupportedWrite)
    expect_success(invoke(cluster, MicrowaveControl::CMD_SET_COOKING_PARAMETERS,
      MicrowaveControl::SetCookingParametersRequest.new(
        cook_mode: 1_u8, cook_time: 120_u32, power_setting: 50_u8, start_after_setting: true)))
    seen.last.should eq({1_u8, 120_u32, 50_u8, true})
    mode.current_mode.should eq(1_u8)
    cluster.cook_time.should eq(120_u32)
    cluster.power_setting.should eq(50_u8)
  end

  it "validates every field before calling the host or changing state" do
    mode = microwave_control_mode
    cluster = microwave_control(mode)
    calls = 0
    cluster.on_set_cooking_parameters do |_selected_mode, _seconds, _power, _start|
      calls += 1
      IMStatus.success
    end
    expect_status(invoke(cluster, MicrowaveControl::CMD_SET_COOKING_PARAMETERS,
      MicrowaveControl::SetCookingParametersRequest.new), IMCode::InvalidCommand)
    expect_status(invoke(cluster, MicrowaveControl::CMD_SET_COOKING_PARAMETERS,
      MicrowaveControl::SetCookingParametersRequest.new(start_after_setting: true)), IMCode::InvalidCommand)
    bad = [
      MicrowaveControl::SetCookingParametersRequest.new(cook_mode: 2_u8),
      MicrowaveControl::SetCookingParametersRequest.new(cook_time: 0_u32),
      MicrowaveControl::SetCookingParametersRequest.new(cook_time: 3601_u32),
      MicrowaveControl::SetCookingParametersRequest.new(power_setting: 9_u8),
      MicrowaveControl::SetCookingParametersRequest.new(power_setting: 55_u8),
    ]
    bad.each do |request|
      expect_status(invoke(cluster, MicrowaveControl::CMD_SET_COOKING_PARAMETERS, request), IMCode::ConstraintError)
    end
    expect_status(invoke(cluster, MicrowaveControl::CMD_SET_COOKING_PARAMETERS,
      MicrowaveControl::SetCookingParametersRequest.new(watt_setting_index: 1_u8)), IMCode::InvalidCommand)
    calls.should eq(0)
    mode.current_mode.should eq(1_u8)
    cluster.cook_time.should eq(30_u32)
    cluster.power_setting.should eq(100_u8)
    cluster.on_set_cooking_parameters { |_mode, _seconds, _power, _start| IMStatus.invalid_in_state }
    expect_status(invoke(cluster, MicrowaveControl::CMD_SET_COOKING_PARAMETERS,
      MicrowaveControl::SetCookingParametersRequest.new(cook_mode: 0_u8)), IMCode::InvalidInState)
    mode.current_mode.should eq(1_u8)
  end

  it "enforces an optional min/max/step power grid" do
    limited = MicrowaveControl::Feature::PowerAsNumber | MicrowaveControl::Feature::PowerNumberLimits
    cluster = microwave_control(microwave_control_mode, limited, 20_u8, 80_u8, 20_u8)
    cluster.attributes.map(&.id.id).should contain(MicrowaveControl::ATTR_POWER_STEP)
    read(cluster, MicrowaveControl::ATTR_MIN_POWER).should eq(20_u8)
    read(cluster, MicrowaveControl::ATTR_MAX_POWER).should eq(80_u8)
    read(cluster, MicrowaveControl::ATTR_POWER_STEP).should eq(20_u8)
    cluster.power_setting.should eq(80_u8)
    cluster.on_set_cooking_parameters { |_mode, _seconds, _power, _start| IMStatus.success }
    expect_status(invoke(cluster, MicrowaveControl::CMD_SET_COOKING_PARAMETERS,
      MicrowaveControl::SetCookingParametersRequest.new(power_setting: 50_u8)), IMCode::ConstraintError)
    expect_success(invoke(cluster, MicrowaveControl::CMD_SET_COOKING_PARAMETERS,
      MicrowaveControl::SetCookingParametersRequest.new(power_setting: 40_u8)))
    cluster.power_setting.should eq(40_u8)
  end

  it "advertises AddMoreTime only when enabled and bounds the total" do
    base = microwave_control
    expect_status(invoke(base, MicrowaveControl::CMD_ADD_MORE_TIME,
      MicrowaveControl::AddMoreTimeRequest.new(1_u32)), IMCode::UnsupportedCommand)
    cluster = build(MicrowaveControl, mode_cluster: microwave_control_mode,
      max_cook_time: 60_u32, add_more_time: true)
    cluster.commands.map(&.id.id).should eq([
      MicrowaveControl::CMD_SET_COOKING_PARAMETERS,
      MicrowaveControl::CMD_ADD_MORE_TIME,
    ])
    cluster.on_add_more_time { |_seconds| IMStatus.success }
    expect_success(invoke(cluster, MicrowaveControl::CMD_ADD_MORE_TIME,
      MicrowaveControl::AddMoreTimeRequest.new(20_u32)))
    cluster.cook_time.should eq(50_u32)
    expect_status(invoke(cluster, MicrowaveControl::CMD_ADD_MORE_TIME,
      MicrowaveControl::AddMoreTimeRequest.new(11_u32)), IMCode::ConstraintError)
    expect_status(invoke(cluster, MicrowaveControl::CMD_ADD_MORE_TIME,
      MicrowaveControl::AddMoreTimeRequest.new(0_u32)), IMCode::ConstraintError)
    cluster.cook_time.should eq(50_u32)
  end
end
