require "../spec_helper"

describe "Matter 1.6 standard cluster coverage" do
  it "models a latching switch with bounded positions and a typed event" do
    switch = build(Matter::Cluster::Switch, number_of_positions: 3_u8,
      feature_map: Matter::Cluster::Switch::Feature::LatchingSwitch)
    switch.cluster_id.id.should eq(0x003B_u32)
    switch.current_position.should eq(0_u8)
    switch.get_event_metadata(Matter::Cluster::Switch::EVENT_SWITCH_LATCHED).should_not be_nil
    payloads = [] of TLV::Any
    switch.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, _event : UInt32, _priority : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) do
      payloads << data
      nil
    end
    switch.latch(2_u8)
    switch.current_position.should eq(2_u8)
    Matter::Cluster::Switch::PositionEvent.from_tlv(payloads.first).position.should eq(2_u8)
    expect_raises(ArgumentError, /position/) { switch.latch(3_u8) }
  end

  it "rejects incompatible switch features and gates multi-press state" do
    expect_raises(ArgumentError) do
      build(Matter::Cluster::Switch, number_of_positions: 2_u8,
        feature_map: Matter::Cluster::Switch::Feature::LatchingSwitch |
                     Matter::Cluster::Switch::Feature::MomentarySwitch)
    end
    expect_raises(ArgumentError, /requires release/) do
      build(Matter::Cluster::Switch, number_of_positions: 2_u8,
        feature_map: Matter::Cluster::Switch::Feature::MomentarySwitch |
                     Matter::Cluster::Switch::Feature::MomentarySwitchMultiPress)
    end
    momentary = build(Matter::Cluster::Switch, number_of_positions: 2_u8,
      feature_map: Matter::Cluster::Switch::Feature::MomentarySwitch)
    read_status(momentary, Matter::Cluster::Switch::ATTR_MULTI_PRESS_MAX).status
      .should eq(Matter::InteractionModel::StatusCode::UnsupportedAttribute)
  end

  it "bounds switch multi-press counts and exposes its feature events" do
    switch = build(Matter::Cluster::Switch, number_of_positions: 2_u8,
      multi_press_max: 3_u8,
      feature_map: Matter::Cluster::Switch::Feature::MomentarySwitch |
                   Matter::Cluster::Switch::Feature::MomentarySwitchRelease |
                   Matter::Cluster::Switch::Feature::MomentarySwitchMultiPress)
    switch.get_event_metadata(Matter::Cluster::Switch::EVENT_MULTI_PRESS_COMPLETE).should_not be_nil
    switch.multi_press_complete(1_u8, 3_u8)
    expect_raises(ArgumentError, /press/) { switch.multi_press_complete(1_u8, 4_u8) }
  end

  it "changes only to advertised ModeSelect options and validates TLV command input" do
    modes = [
      Matter::Cluster::ModeSelect::ModeOption.new("Eco", 1_u8),
      Matter::Cluster::ModeSelect::ModeOption.new("Boost", 2_u8),
    ]
    cluster = build(Matter::Cluster::ModeSelect, description: "Fan mode",
      supported_modes: modes, current_mode: 1_u8)
    cluster.cluster_id.id.should eq(0x0050_u32)
    read_tlv(cluster, Matter::Cluster::ModeSelect::ATTR_SUPPORTED_MODES).as_list.size.should eq(2)
    expect_success(invoke(cluster, Matter::Cluster::ModeSelect::CMD_CHANGE_TO_MODE,
      Matter::Cluster::ModeSelect::ChangeToModeRequest.new(2_u8)))
    cluster.current_mode.should eq(2_u8)
    expect_status(invoke(cluster, Matter::Cluster::ModeSelect::CMD_CHANGE_TO_MODE,
      Matter::Cluster::ModeSelect::ChangeToModeRequest.new(3_u8)),
      Matter::InteractionModel::StatusCode::InvalidCommand)
  end

  it "bounds ModeSelect labels and semantic tags and checks feature-gated OnMode" do
    tag = Matter::Cluster::ModeSelect::SemanticTag.new(0_u16, 1_u16)
    expect_raises(ArgumentError, /label/) do
      Matter::Cluster::ModeSelect::ModeOption.new("x" * 65, 1_u8)
    end
    modes = [Matter::Cluster::ModeSelect::ModeOption.new("Eco", 1_u8, [tag])]
    cluster = build(Matter::Cluster::ModeSelect, description: "Fan mode",
      supported_modes: modes, current_mode: 1_u8)
    read_status(cluster, Matter::Cluster::ModeSelect::ATTR_ON_MODE).status
      .should eq(Matter::InteractionModel::StatusCode::UnsupportedAttribute)
    expect_raises(ArgumentError, /duplicate/) do
      build(Matter::Cluster::ModeSelect, description: "Fan mode",
        supported_modes: modes + modes, current_mode: 1_u8)
    end
  end

  it "opens and closes a valve with bounded level and typed state" do
    valve = build(Matter::Cluster::ValveConfigurationControl,
      feature_map: Matter::Cluster::ValveConfigurationControl::Feature::Level)
    valve.cluster_id.id.should eq(0x0081_u32)
    states = [] of Matter::Cluster::ValveConfigurationControl::ValveState
    valve.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, event : UInt32, _priority : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) do
      if event == Matter::Cluster::ValveConfigurationControl::EVENT_VALVE_STATE_CHANGED
        states << Matter::Cluster::ValveConfigurationControl::ValveStateChangedEvent.from_tlv(data).valve_state
      end
      nil
    end
    expect_success(invoke(valve, Matter::Cluster::ValveConfigurationControl::CMD_OPEN,
      Matter::Cluster::ValveConfigurationControl::OpenRequest.new(target_level: 60_u8)))
    valve.current_state.should eq(Matter::Cluster::ValveConfigurationControl::ValveState::Open)
    valve.current_level.should eq(60_u8)
    expect_success(invoke(valve, Matter::Cluster::ValveConfigurationControl::CMD_CLOSE))
    valve.current_state.should eq(Matter::Cluster::ValveConfigurationControl::ValveState::Closed)
    valve.current_level.should eq(0_u8)
    states.should eq([Matter::Cluster::ValveConfigurationControl::ValveState::Open,
                      Matter::Cluster::ValveConfigurationControl::ValveState::Closed])
  end

  it "rejects malformed valve open targets and gates level/time attributes" do
    valve = build(Matter::Cluster::ValveConfigurationControl)
    read_status(valve, Matter::Cluster::ValveConfigurationControl::ATTR_CURRENT_LEVEL).status
      .should eq(Matter::InteractionModel::StatusCode::UnsupportedAttribute)
    read_status(valve, Matter::Cluster::ValveConfigurationControl::ATTR_AUTO_CLOSE_TIME).status
      .should eq(Matter::InteractionModel::StatusCode::UnsupportedAttribute)
    expect_status(invoke(valve, Matter::Cluster::ValveConfigurationControl::CMD_OPEN,
      Matter::Cluster::ValveConfigurationControl::OpenRequest.new(target_level: 50_u8)),
      Matter::InteractionModel::StatusCode::ConstraintError)
    expect_status(invoke(valve, Matter::Cluster::ValveConfigurationControl::CMD_OPEN,
      Matter::Cluster::ValveConfigurationControl::OpenRequest.new(open_duration: 0_u32)),
      Matter::InteractionModel::StatusCode::ConstraintError)
  end

  it "uses the valve default duration and supports nullable operate writes" do
    valve = build(Matter::Cluster::ValveConfigurationControl,
      default_open_duration: 30_u32)
    expect_success(invoke(valve, Matter::Cluster::ValveConfigurationControl::CMD_OPEN,
      Matter::Cluster::ValveConfigurationControl::OpenRequest.new))
    valve.open_duration.should eq(30_u32)
    write(valve, Matter::Cluster::ValveConfigurationControl::ATTR_DEFAULT_OPEN_DURATION,
      0_u32).status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    write(valve, Matter::Cluster::ValveConfigurationControl::ATTR_DEFAULT_OPEN_DURATION,
      20_u32).status.should eq(Matter::InteractionModel::StatusCode::Success)
  end

  it "reports a known Matter UTC auto-close time for a timed valve opening" do
    valve = build(Matter::Cluster::ValveConfigurationControl,
      feature_map: Matter::Cluster::ValveConfigurationControl::Feature::TimeSync)
    valve.utc_time_micros = -> { 10_000_000_u64 }
    expect_success(invoke(valve, Matter::Cluster::ValveConfigurationControl::CMD_OPEN,
      Matter::Cluster::ValveConfigurationControl::OpenRequest.new(open_duration: 5_u32)))
    valve.auto_close_time.should eq(15_000_000_u64)
    valve.close
    valve.auto_close_time.should be_nil
  end

  it "auto-closes a timed valve opening" do
    valve = build(Matter::Cluster::ValveConfigurationControl)
    expect_success(invoke(valve, Matter::Cluster::ValveConfigurationControl::CMD_OPEN,
      Matter::Cluster::ValveConfigurationControl::OpenRequest.new(open_duration: 1_u32)))
    sleep 1.2.seconds
    valve.current_state.should eq(Matter::Cluster::ValveConfigurationControl::ValveState::Closed)
    valve.remaining_duration.should be_nil
  end
end
