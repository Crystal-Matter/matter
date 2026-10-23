require "../spec_helper"

private alias HeaterMode = Matter::Cluster::WaterHeaterMode
private alias Heater = Matter::Cluster::WaterHeaterManagement
private alias HeaterStatus = Matter::InteractionModel::Status
private alias HeaterCode = Matter::InteractionModel::StatusCode

private def heater_modes
  [
    HeaterMode::ModeOption.new("Off", 0_u8, [HeaterMode::ModeTag.new(HeaterMode::Tag::Off)]),
    HeaterMode::ModeOption.new("Manual", 1_u8, [HeaterMode::ModeTag.new(HeaterMode::Tag::Manual)]),
  ]
end

describe "Matter 1.6 Water Heater Mode" do
  it "advertises only inherited allowed Mode Base fields and typed response" do
    mode = build(HeaterMode, supported_modes: heater_modes, current_mode: 0_u8)
    mode.cluster_id.id.should eq(0x009E_u32)
    mode.cluster_revision.should eq(1_u16)
    mode.attributes.map(&.id.id).should eq([HeaterMode::ATTR_SUPPORTED_MODES, HeaterMode::ATTR_CURRENT_MODE])
    mode.commands.map(&.id.id).should eq([HeaterMode::CMD_CHANGE_TO_MODE])
    read_status(mode, 0x0002_u32).status.should eq(HeaterCode::UnsupportedAttribute)
    read_status(mode, 0x0003_u32).status.should eq(HeaterCode::UnsupportedAttribute)
    response = invoke_response(mode, HeaterMode::CMD_CHANGE_TO_MODE,
      HeaterMode::ChangeToModeRequest.new(8_u8), HeaterMode::ChangeToModeResponse)
    response.status.should eq(HeaterMode::ModeStatus::UnsupportedMode)
    response.status_text.should eq("")
  end

  it "validates required Off and Manual tags and host-controlled transitions" do
    expect_raises(ArgumentError) do
      build(HeaterMode, supported_modes: [heater_modes.first], current_mode: 0_u8)
    end
    mode = build(HeaterMode, supported_modes: heater_modes, current_mode: 0_u8)
    failed = invoke_response(mode, HeaterMode::CMD_CHANGE_TO_MODE,
      HeaterMode::ChangeToModeRequest.new(1_u8), HeaterMode::ChangeToModeResponse)
    failed.status.should eq(HeaterMode::ModeStatus::GenericFailure)
    read(mode, HeaterMode::ATTR_CURRENT_MODE).should eq(0_u8)
    mode.on_change_to_mode { |_requested| HeaterMode::ChangeToModeResponse.new(HeaterMode::ModeStatus::Success) }
    accepted = invoke_response(mode, HeaterMode::CMD_CHANGE_TO_MODE,
      HeaterMode::ChangeToModeRequest.new(1_u8), HeaterMode::ChangeToModeResponse)
    accepted.status.should eq(HeaterMode::ModeStatus::Success)
    read(mode, HeaterMode::ATTR_CURRENT_MODE).should eq(1_u8)
    saved = mode.save_state.as(Matter::Storage::Document)
    restored = build(HeaterMode, supported_modes: heater_modes, current_mode: 0_u8)
    restored.restore_state(saved)
    restored.current_mode.should eq(1_u8)
  end

  it "rejects conflicting primary tags and protects fixed mode configuration" do
    expect_raises(ArgumentError) do
      HeaterMode::ModeOption.new("Invalid", 3_u8, [
        HeaterMode::ModeTag.new(HeaterMode::Tag::Off),
        HeaterMode::ModeTag.new(HeaterMode::Tag::Manual),
      ])
    end
    mode = build(HeaterMode, supported_modes: heater_modes, current_mode: 0_u8)
    expect_raises(ArgumentError) { mode.supported_modes = [] of HeaterMode::ModeOption }
    mode.supported_modes.clear
    mode.supported_modes.size.should eq(2)
  end
end

describe "Matter 1.6 Water Heater Management" do
  it "gates energy and tank percentage fields while always advertising commands and events" do
    heater = build(Heater, heater_types: Heater::HeatSource::ImmersionElement1)
    heater.cluster_id.id.should eq(0x0094_u32)
    heater.cluster_revision.should eq(2_u16)
    heater.attributes.map(&.id.id).should eq([
      Heater::ATTR_HEATER_TYPES, Heater::ATTR_HEAT_DEMAND, Heater::ATTR_BOOST_STATE,
    ])
    heater.commands.map(&.id.id).should eq([Heater::CMD_BOOST, Heater::CMD_CANCEL_BOOST])
    heater.events.map(&.id.id).should eq([Heater::EVENT_BOOST_STARTED, Heater::EVENT_BOOST_ENDED])
    read_status(heater, Heater::ATTR_TANK_VOLUME).status.should eq(HeaterCode::UnsupportedAttribute)
    featured = build(Heater, heater_types: Heater::HeatSource::ImmersionElement1,
      feature_map: Heater::Feature::EnergyManagement | Heater::Feature::TankPercent,
      tank_volume: 100_u16, estimated_heat_required: 4_000_i64, tank_percentage: 40_u8)
    featured.attributes.map(&.id.id).should eq([
      Heater::ATTR_HEATER_TYPES, Heater::ATTR_HEAT_DEMAND, Heater::ATTR_TANK_VOLUME,
      Heater::ATTR_ESTIMATED_HEAT_REQUIRED, Heater::ATTR_TANK_PERCENTAGE, Heater::ATTR_BOOST_STATE,
    ])
  end

  it "rejects invalid heat sources, percentages, and BoostInfo fields" do
    heater = build(Heater, heater_types: Heater::HeatSource::ImmersionElement1,
      feature_map: Heater::Feature::TankPercent, tank_percentage: 25_u8)
    expect_raises(ArgumentError) { heater.report_heat_demand(Heater::HeatSource::HeatPump) }
    expect_raises(ArgumentError) { heater.report_tank_percentage(101_u8) }
    expect_status(invoke(heater, Heater::CMD_BOOST,
      Heater::BoostRequest.new(Heater::BoostInfo.new(0_u32))), HeaterCode::ConstraintError)
    expect_status(invoke(heater, Heater::CMD_BOOST,
      Heater::BoostRequest.new(Heater::BoostInfo.new(30_u32, target_reheat: 80_u8))), HeaterCode::ConstraintError)
    read(heater, Heater::ATTR_BOOST_STATE).should eq(0_u8)
  end

  it "requires host acceptance, emits revision-two events, replaces active boosts, and cancels once" do
    node = Matter::Node.new
    endpoint1 = Matter::Endpoint.new(endpoint(1))
    heater = build(Heater, heater_types: Heater::HeatSource::ImmersionElement1)
    endpoint1.add_cluster(heater)
    node.add_endpoint(endpoint1)
    request = Heater::BoostRequest.new(Heater::BoostInfo.new(30_u32))
    expect_status(invoke(heater, Heater::CMD_BOOST, request), HeaterCode::InvalidInState)
    heater.on_boost { |_info| HeaterStatus.success }
    heater.on_cancel_boost { HeaterStatus.success }
    expect_success(invoke(heater, Heater::CMD_BOOST, request))
    expect_success(invoke(heater, Heater::CMD_BOOST, request))
    read(heater, Heater::ATTR_BOOST_STATE).should eq(1_u8)
    expect_success(invoke(heater, Heater::CMD_CANCEL_BOOST))
    expect_success(invoke(heater, Heater::CMD_CANCEL_BOOST))
    read(heater, Heater::ATTR_BOOST_STATE).should eq(0_u8)
    started = node.event_journal.query([Matter::InteractionModel::EventPath.new(
      cluster: Heater::CLUSTER_ID, event: Heater::EVENT_BOOST_STARTED)])
    ended = node.event_journal.query([Matter::InteractionModel::EventPath.new(
      cluster: Heater::CLUSTER_ID, event: Heater::EVENT_BOOST_ENDED)])
    started.size.should eq(2)
    ended.size.should eq(1)
    Heater::BoostStartedEvent.from_tlv(started.first.data).boost_info.duration.should eq(30_u32)
  end

  it "ends an accepted boost at its duration through the host callback" do
    heater = build(Heater, heater_types: Heater::HeatSource::ImmersionElement1)
    cancellations = 0
    heater.on_boost { |_info| HeaterStatus.success }
    heater.on_cancel_boost do
      cancellations += 1
      HeaterStatus.success
    end
    expect_success(invoke(heater, Heater::CMD_BOOST, Heater::BoostRequest.new(Heater::BoostInfo.new(1_u32))))
    sleep 1.1.seconds
    heater.boost_state.should eq(Heater::BoostState::Inactive)
    cancellations.should eq(1)
  end

  it "ends the boost and emits BoostEnded at duration even when host cancellation fails" do
    node = Matter::Node.new
    endpoint1 = Matter::Endpoint.new(endpoint(1))
    heater = build(Heater, heater_types: Heater::HeatSource::ImmersionElement1)
    endpoint1.add_cluster(heater)
    node.add_endpoint(endpoint1)
    heater.on_boost { |_info| HeaterStatus.success }
    cancellations = 0
    heater.on_cancel_boost do
      cancellations += 1
      HeaterStatus.invalid_in_state
    end

    expect_success(invoke(heater, Heater::CMD_BOOST,
      Heater::BoostRequest.new(Heater::BoostInfo.new(1_u32))))
    sleep 1.1.seconds

    cancellations.should eq(1)
    heater.boost_state.should eq(Heater::BoostState::Inactive)
    ended = node.event_journal.query([Matter::InteractionModel::EventPath.new(
      cluster: Heater::CLUSTER_ID, event: Heater::EVENT_BOOST_ENDED)])
    ended.size.should eq(1)
  end

  it "does not let an earlier duration end a replacement boost" do
    heater = build(Heater, heater_types: Heater::HeatSource::ImmersionElement1)
    cancellations = 0
    heater.on_boost { |_info| HeaterStatus.success }
    heater.on_cancel_boost do
      cancellations += 1
      HeaterStatus.success
    end
    expect_success(invoke(heater, Heater::CMD_BOOST,
      Heater::BoostRequest.new(Heater::BoostInfo.new(1_u32))))
    sleep 0.2.seconds
    expect_success(invoke(heater, Heater::CMD_BOOST,
      Heater::BoostRequest.new(Heater::BoostInfo.new(30_u32))))
    sleep 1.second

    heater.boost_state.should eq(Heater::BoostState::Active)
    cancellations.should eq(0)
    expect_success(invoke(heater, Heater::CMD_CANCEL_BOOST))
  end

  it "ends an expired boost when the host cancellation callback raises" do
    heater = build(Heater, heater_types: Heater::HeatSource::ImmersionElement1)
    heater.on_boost { |_info| HeaterStatus.success }
    heater.on_cancel_boost { raise ArgumentError.new("host cancellation failed") }

    expect_success(invoke(heater, Heater::CMD_BOOST,
      Heater::BoostRequest.new(Heater::BoostInfo.new(1_u32))))
    sleep 1.1.seconds

    heater.boost_state.should eq(Heater::BoostState::Inactive)
  end
end
