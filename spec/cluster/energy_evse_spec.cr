require "../spec_helper"

private alias Evse = Matter::Cluster::EnergyEvse
private alias EvseStatus = Matter::InteractionModel::StatusCode

private def evse : Evse
  cluster = build(Evse, circuit_capacity: 32_000_i64)
  cluster.on_enable_charging = ->(_until : UInt32?, _minimum : Int64, _maximum : Int64) do
    Matter::InteractionModel::Status.success
  end
  cluster.on_disable = -> { Matter::InteractionModel::Status.success }
  cluster
end

private def target_schedule(days : UInt8, minute : UInt16, energy : Int64) : Evse::ChargingTargetSchedule
  Evse::ChargingTargetSchedule.new(days, [Evse::ChargingTarget.new(minute, energy)])
end

describe Evse do
  it "advertises revision 4 and only the mandatory charging preferences feature" do
    cluster = evse
    cluster.cluster_id.id.should eq(0x0099_u32)
    cluster.cluster_revision.should eq(4_u16)
    cluster.feature_map.should eq(Evse::Feature::ChargingPreferences)
    read(cluster, Evse::ATTR_STATE).should be_nil
    read(cluster, Evse::ATTR_SUPPLY_STATE).should eq(Evse::SupplyState::Disabled.value)
    read(cluster, Evse::ATTR_FAULT_STATE).should eq(Evse::FaultState::NoError.value)
    read(cluster, Evse::ATTR_CHARGING_ENABLED_UNTIL).should eq(0_u32)
    read(cluster, Evse::ATTR_CIRCUIT_CAPACITY).should eq(32_000_i64)
    read(cluster, Evse::ATTR_SESSION_ID).should be_nil
    read_status(cluster, 0x0004_u32).status.should eq(EvseStatus::UnsupportedAttribute)
    read_status(cluster, 0x0030_u32).status.should eq(EvseStatus::UnsupportedAttribute)
    read_status(cluster, 0x0031_u32).status.should eq(EvseStatus::UnsupportedAttribute)
    accepted_command_ids(cluster).should eq([
      Evse::CMD_DISABLE, Evse::CMD_ENABLE_CHARGING,
      Evse::CMD_SET_TARGETS, Evse::CMD_GET_TARGETS, Evse::CMD_CLEAR_TARGETS,
    ])
    generated_command_ids(cluster).should eq([Evse::CMD_GET_TARGETS_RESPONSE])
    cluster.events.map(&.id.id).should eq([
      Evse::EVENT_EV_CONNECTED, Evse::EVENT_EV_NOT_DETECTED,
      Evse::EVENT_ENERGY_TRANSFER_STARTED, Evse::EVENT_ENERGY_TRANSFER_STOPPED,
      Evse::EVENT_FAULT,
    ])
  end

  it "encodes nullable command fields and mandatory target structures at their canonical TLV tags" do
    Evse::EnableChargingRequest.new(nil, 6_000_i64, 16_000_i64).to_tlv(nil).as_structure.keys.should eq([0_u8, 1_u8, 2_u8])
    target = Evse::ChargingTarget.new(1_200_u16, 12_000_i64)
    target.to_tlv(nil).as_structure.keys.should eq([0_u8, 2_u8])
    schedule = target_schedule(0x02_u8, 1_200_u16, 12_000_i64)
    schedule.to_tlv(nil).as_structure.keys.should eq([0_u8, 1_u8])
    Evse::ChargingTargetSchedule.from_tlv(schedule.to_tlv(nil)).charging_targets.first.added_energy.should eq(12_000_i64)
  end

  it "enables charging, caps current to circuit capacity, and persists permission" do
    cluster = evse
    applied_maximum = nil.as(Int64?)
    cluster.on_enable_charging = ->(_until : UInt32?, _minimum : Int64, maximum : Int64) do
      applied_maximum = maximum
      Matter::InteractionModel::Status.success
    end
    expect_status(invoke(cluster, Evse::CMD_ENABLE_CHARGING,
      Evse::EnableChargingRequest.new(nil, 6_000_i64, 40_000_i64)), EvseStatus::Success)
    applied_maximum.should eq(32_000_i64)
    cluster.supply_state.should eq(Evse::SupplyState::ChargingEnabled)
    cluster.maximum_charge_current.should eq(32_000_i64)
    cluster.charging_enabled_until.should be_nil
    expect_raises(ArgumentError) { cluster.circuit_capacity = 16_000_i64 }
    restored = build(Evse, circuit_capacity: 16_000_i64)
    restored.on_disable = -> { Matter::InteractionModel::Status.success }
    restored.restore_state(cluster.save_state.as(Matter::Storage::Document))
    restored.circuit_capacity.should eq(32_000_i64)
    restored.supply_state.should eq(Evse::SupplyState::ChargingEnabled)
    restored.maximum_charge_current.should eq(32_000_i64)
    restored.charging_enabled_until.should be_nil
    expect_status(invoke(restored, Evse::CMD_DISABLE), EvseStatus::Success)
    restored.supply_state.should eq(Evse::SupplyState::Disabled)
    restored.charging_enabled_until.should eq(0_u32)
    restored.circuit_capacity = 16_000_i64
    restored.maximum_charge_current.should eq(0_i64)
  end

  it "disables the physical relay when EnableCharging has an expired deadline" do
    cluster = evse
    enable_calls = 0
    disable_calls = 0
    cluster.on_enable_charging = ->(_until : UInt32?, _minimum : Int64, _maximum : Int64) do
      enable_calls += 1
      Matter::InteractionModel::Status.success
    end
    cluster.on_disable = -> do
      disable_calls += 1
      Matter::InteractionModel::Status.success
    end
    expect_success(invoke(cluster, Evse::CMD_ENABLE_CHARGING,
      Evse::EnableChargingRequest.new(nil, 6_000_i64, 16_000_i64)))
    expect_success(invoke(cluster, Evse::CMD_ENABLE_CHARGING,
      Evse::EnableChargingRequest.new(0_u32, 6_000_i64, 16_000_i64)))
    enable_calls.should eq(1)
    disable_calls.should eq(1)
    cluster.supply_state.should eq(Evse::SupplyState::Disabled)
    cluster.charging_enabled_until.should eq(0_u32)
  end

  it "keeps charging enabled when the expired-deadline disable callback fails" do
    cluster = evse
    expect_success(invoke(cluster, Evse::CMD_ENABLE_CHARGING,
      Evse::EnableChargingRequest.new(nil, 6_000_i64, 16_000_i64)))
    cluster.on_disable = -> { Matter::InteractionModel::Status.failure }
    expect_status(invoke(cluster, Evse::CMD_ENABLE_CHARGING,
      Evse::EnableChargingRequest.new(0_u32, 6_000_i64, 16_000_i64)), EvseStatus::Failure)
    cluster.supply_state.should eq(Evse::SupplyState::ChargingEnabled)
    cluster.charging_enabled_until.should be_nil
  end

  it "accepts an expired deadline while faulted without clearing the fault" do
    cluster = evse
    cluster.report_fault(Evse::FaultState::Other)
    expect_success(invoke(cluster, Evse::CMD_ENABLE_CHARGING,
      Evse::EnableChargingRequest.new(0_u32, 6_000_i64, 16_000_i64)))
    cluster.supply_state.should eq(Evse::SupplyState::DisabledError)
    cluster.fault_state.should eq(Evse::FaultState::Other)
  end

  it "rejects unsafe charge ranges without changing attributes" do
    cluster = evse
    expect_status(invoke(cluster, Evse::CMD_ENABLE_CHARGING,
      Evse::EnableChargingRequest.new(nil, -1_i64, 16_000_i64)), EvseStatus::ConstraintError)
    expect_status(invoke(cluster, Evse::CMD_ENABLE_CHARGING,
      Evse::EnableChargingRequest.new(nil, 16_000_i64, 6_000_i64)), EvseStatus::ConstraintError)
    cluster.supply_state.should eq(Evse::SupplyState::Disabled)
    cluster.maximum_charge_current.should eq(0_i64)
  end

  it "expires a finite charging grant and retains the disabled state" do
    cluster = evse
    expect_success(invoke(cluster, Evse::CMD_ENABLE_CHARGING,
      Evse::EnableChargingRequest.new(UInt32::MAX, 6_000_i64, 16_000_i64)))
    cluster.supply_state.should eq(Evse::SupplyState::ChargingEnabled)
    cluster.expire_charging(UInt32::MAX)
    cluster.supply_state.should eq(Evse::SupplyState::Disabled)
    cluster.charging_enabled_until.should eq(0_u32)
    restored = evse
    restored.restore_state(cluster.save_state.as(Matter::Storage::Document))
    restored.supply_state.should eq(Evse::SupplyState::Disabled)
  end

  it "schedules automatic expiry and invalidates an older grant timer" do
    now = Time.utc(2026, 1, 1)
    callbacks = [] of Proc(Nil)
    clock = -> { now }
    timer = ->(_delay : Time::Span, callback : Proc(Nil)) do
      callbacks << callback
      nil
    end
    cluster = build(Evse, circuit_capacity: 32_000_i64, clock: clock, expiry_timer: timer)
    cluster.on_enable_charging = ->(_until : UInt32?, _minimum : Int64, _maximum : Int64) do
      Matter::InteractionModel::Status.success
    end
    cluster.on_disable = -> { Matter::InteractionModel::Status.success }
    first_deadline = (now.to_unix - Evse::MATTER_EPOCH_UNIX + 10).to_u32
    second_deadline = first_deadline + 20_u32
    expect_success(invoke(cluster, Evse::CMD_ENABLE_CHARGING,
      Evse::EnableChargingRequest.new(first_deadline, 6_000_i64, 16_000_i64)))
    expect_success(invoke(cluster, Evse::CMD_ENABLE_CHARGING,
      Evse::EnableChargingRequest.new(second_deadline, 6_000_i64, 16_000_i64)))
    now += 11.seconds
    callbacks.first.call
    cluster.supply_state.should eq(Evse::SupplyState::ChargingEnabled)
    now += 20.seconds
    callbacks.last.call
    cluster.supply_state.should eq(Evse::SupplyState::Disabled)
  end

  it "retains a finite grant across restart and expires it if restart occurs late" do
    now = Time.utc(2026, 1, 1)
    clock = -> { now }
    timer = ->(_delay : Time::Span, _callback : Proc(Nil)) { nil }
    source = build(Evse, circuit_capacity: 32_000_i64, clock: clock, expiry_timer: timer)
    source.on_enable_charging = ->(_until : UInt32?, _minimum : Int64, _maximum : Int64) do
      Matter::InteractionModel::Status.success
    end
    deadline = (now.to_unix - Evse::MATTER_EPOCH_UNIX + 100).to_u32
    expect_success(invoke(source, Evse::CMD_ENABLE_CHARGING,
      Evse::EnableChargingRequest.new(deadline, 6_000_i64, 16_000_i64)))
    document = source.save_state.as(Matter::Storage::Document)
    timely = build(Evse, circuit_capacity: 32_000_i64, clock: clock, expiry_timer: timer)
    timely.restore_state(document)
    timely.charging_enabled_until.should eq(deadline)
    timely.supply_state.should eq(Evse::SupplyState::ChargingEnabled)
    now += 101.seconds
    late = build(Evse, circuit_capacity: 32_000_i64, clock: clock, expiry_timer: timer)
    late.restore_state(document)
    late.charging_enabled_until.should eq(0_u32)
    late.supply_state.should eq(Evse::SupplyState::Disabled)
  end

  it "sets, gets, clears and persists nonoverlapping day schedules" do
    cluster = evse
    monday = target_schedule(0x02_u8, 480_u16, 12_000_i64)
    tuesday = target_schedule(0x04_u8, 600_u16, 15_000_i64)
    expect_status(invoke(cluster, Evse::CMD_SET_TARGETS,
      Evse::SetTargetsRequest.new([monday, tuesday])), EvseStatus::Success)
    response = invoke_response(cluster, Evse::CMD_GET_TARGETS, nil, Evse::GetTargetsResponse)
    response.charging_target_schedules.size.should eq(2)
    restored = evse
    restored.restore_state(cluster.save_state.as(Matter::Storage::Document))
    invoke_response(restored, Evse::CMD_GET_TARGETS, nil, Evse::GetTargetsResponse)
      .charging_target_schedules.first.day_of_week_for_sequence.should eq(0x02_u8)
    expect_status(invoke(restored, Evse::CMD_CLEAR_TARGETS), EvseStatus::Success)
    invoke_response(restored, Evse::CMD_GET_TARGETS, nil, Evse::GetTargetsResponse)
      .charging_target_schedules.should be_empty
  end

  it "rejects duplicate days and invalid targets without replacing previous schedules" do
    cluster = evse
    valid = target_schedule(0x02_u8, 480_u16, 12_000_i64)
    expect_status(invoke(cluster, Evse::CMD_SET_TARGETS, Evse::SetTargetsRequest.new([valid])), EvseStatus::Success)
    overlap = target_schedule(0x02_u8, 600_u16, 12_000_i64)
    expect_status(invoke(cluster, Evse::CMD_SET_TARGETS,
      Evse::SetTargetsRequest.new([valid, overlap])), EvseStatus::ConstraintError)
    invalid = target_schedule(0x04_u8, 1_440_u16, 12_000_i64)
    expect_status(invoke(cluster, Evse::CMD_SET_TARGETS,
      Evse::SetTargetsRequest.new([invalid])), EvseStatus::ConstraintError)
    invoke_response(cluster, Evse::CMD_GET_TARGETS, nil, Evse::GetTargetsResponse)
      .charging_target_schedules.size.should eq(1)
  end

  it "lets a host refuse a target schedule before storing it" do
    cluster = evse
    cluster.on_targets_changed = ->(_schedules : Array(Evse::ChargingTargetSchedule)) do
      Matter::InteractionModel::Status.failure
    end
    expect_status(invoke(cluster, Evse::CMD_SET_TARGETS,
      Evse::SetTargetsRequest.new([target_schedule(0x02_u8, 480_u16, 12_000_i64)])),
      EvseStatus::Failure)
    cluster.charging_target_schedules.should be_empty
  end

  it "publishes a host-computed next charge plan and rejects invalid estimates" do
    cluster = evse
    cluster.report_next_charge(100_u32, 200_u32, 12_000_i64, 100_u8)
    read(cluster, Evse::ATTR_NEXT_CHARGE_START_TIME).should eq(100_u32)
    read(cluster, Evse::ATTR_NEXT_CHARGE_TARGET_TIME).should eq(200_u32)
    read(cluster, Evse::ATTR_NEXT_CHARGE_REQUIRED_ENERGY).should eq(12_000_i64)
    read(cluster, Evse::ATTR_NEXT_CHARGE_TARGET_SOC).should eq(100_u8)
    expect_raises(ArgumentError) { cluster.report_next_charge(200_u32, 100_u32, 12_000_i64, 100_u8) }
    expect_raises(ArgumentError) { cluster.report_next_charge(100_u32, 200_u32, -1_i64, 100_u8) }
    expect_raises(ArgumentError) { cluster.report_next_charge(100_u32, 200_u32, 12_000_i64, 50_u8) }
    cluster.report_next_charge(nil, nil, nil, nil)
    read(cluster, Evse::ATTR_NEXT_CHARGE_TARGET_TIME).should be_nil
  end

  it "gates SoC telemetry, validates host reports, and leaves it unknown after restart" do
    feature = Evse::Feature::ChargingPreferences | Evse::Feature::SocReporting
    cluster = build(Evse, circuit_capacity: 32_000_i64, feature_map: feature)
    cluster.feature_map.should eq(feature)
    read(cluster, Evse::ATTR_STATE_OF_CHARGE).should be_nil
    read(cluster, Evse::ATTR_BATTERY_CAPACITY).should be_nil
    cluster.report_soc(72_u8, 60_000_000_i64)
    read(cluster, Evse::ATTR_STATE_OF_CHARGE).should eq(72_u8)
    read(cluster, Evse::ATTR_BATTERY_CAPACITY).should eq(60_000_000_i64)
    expect_raises(ArgumentError) { cluster.report_soc(101_u8, 60_000_000_i64) }
    expect_raises(ArgumentError) { cluster.report_soc(72_u8, -1_i64) }
    read(cluster, Evse::ATTR_STATE_OF_CHARGE).should eq(72_u8)
    read(cluster, Evse::ATTR_BATTERY_CAPACITY).should eq(60_000_000_i64)
    cluster.report_next_charge(nil, nil, nil, 80_u8)
    read(cluster, Evse::ATTR_NEXT_CHARGE_TARGET_SOC).should eq(80_u8)
    restored = build(Evse, circuit_capacity: 32_000_i64, feature_map: feature)
    restored.restore_state(cluster.save_state.as(Matter::Storage::Document))
    read(restored, Evse::ATTR_STATE_OF_CHARGE).should be_nil
    read(restored, Evse::ATTR_BATTERY_CAPACITY).should be_nil
    expect_raises(ArgumentError) { evse.report_soc(72_u8, 60_000_000_i64) }
    expect_raises(ArgumentError) { evse.state_of_charge = 72_u8 }
    expect_raises(ArgumentError) { evse.battery_capacity = 60_000_000_i64 }
    expect_raises(ArgumentError) { evse.feature_map = feature }
  end

  it "requires TargetSoC for every schedule target with the SoC feature" do
    feature = Evse::Feature::ChargingPreferences | Evse::Feature::SocReporting
    cluster = build(Evse, circuit_capacity: 32_000_i64, feature_map: feature)
    missing_soc = target_schedule(0x02_u8, 480_u16, 12_000_i64)
    expect_status(invoke(cluster, Evse::CMD_SET_TARGETS,
      Evse::SetTargetsRequest.new([missing_soc])), EvseStatus::InvalidCommand)
    valid_target = Evse::ChargingTarget.new(480_u16, nil, 80_u8)
    valid = Evse::ChargingTargetSchedule.new(0x02_u8, [valid_target])
    expect_status(invoke(cluster, Evse::CMD_SET_TARGETS,
      Evse::SetTargetsRequest.new([valid])), EvseStatus::Success)
    expect_status(invoke(cluster, Evse::CMD_SET_TARGETS,
      Evse::SetTargetsRequest.new([Evse::ChargingTargetSchedule.new(0x04_u8,
        [Evse::ChargingTarget.new(480_u16, 12_000_i64, 101_u8)])])), EvseStatus::ConstraintError)
    cluster.charging_target_schedules.should eq([valid])
    expect_raises(ArgumentError) { cluster.feature_map = Evse::Feature::ChargingPreferences }
    cluster.feature_map.should eq(feature)
    restored = build(Evse, circuit_capacity: 32_000_i64, feature_map: feature)
    restored.restore_state(cluster.save_state.as(Matter::Storage::Document))
    restored.charging_target_schedules.should eq([valid])
    restored.charging_target_schedules.first.charging_targets.first.to_tlv(nil).as_structure.keys.should eq([0_u8, 1_u8])
    combined = build(Evse, circuit_capacity: 32_000_i64,
      feature_map: feature | Evse::Feature::V2x)
    read(combined, Evse::ATTR_STATE_OF_CHARGE).should be_nil
    read(combined, Evse::ATTR_MAXIMUM_DISCHARGE_CURRENT).should eq(0_i64)
  end

  it "retains the at-least-one target rule without SoC Reporting" do
    cluster = evse
    soc_only = Evse::ChargingTargetSchedule.new(0x02_u8,
      [Evse::ChargingTarget.new(480_u16, nil, 100_u8)])
    expect_status(invoke(cluster, Evse::CMD_SET_TARGETS,
      Evse::SetTargetsRequest.new([soc_only])), EvseStatus::Success)
    neither = Evse::ChargingTargetSchedule.new(0x04_u8,
      [Evse::ChargingTarget.new(480_u16)])
    expect_status(invoke(cluster, Evse::CMD_SET_TARGETS,
      Evse::SetTargetsRequest.new([neither])), EvseStatus::ConstraintError)
    cluster.charging_target_schedules.should eq([soc_only])
  end

  it "lets a physical relay callback veto charging without changing permission" do
    cluster = evse
    cluster.on_enable_charging = ->(_until : UInt32?, _minimum : Int64, _maximum : Int64) do
      Matter::InteractionModel::Status.failure
    end
    expect_status(invoke(cluster, Evse::CMD_ENABLE_CHARGING,
      Evse::EnableChargingRequest.new(nil, 6_000_i64, 16_000_i64)), EvseStatus::Failure)
    cluster.supply_state.should eq(Evse::SupplyState::Disabled)
    cluster.charging_enabled_until.should eq(0_u32)
  end

  it "rejects charging without an actuator callback" do
    cluster = build(Evse, circuit_capacity: 32_000_i64)
    expect_status(invoke(cluster, Evse::CMD_ENABLE_CHARGING,
      Evse::EnableChargingRequest.new(nil, 6_000_i64, 16_000_i64)), EvseStatus::InvalidInState)
    cluster.supply_state.should eq(Evse::SupplyState::Disabled)
  end

  it "emits standard charging session events from host observations" do
    cluster = evse
    event_ids = [] of UInt32
    cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, event : UInt32, _priority : Matter::InteractionModel::EventPriority, _data : TLV::Any, _fabric : UInt8?) do
      event_ids << event
      nil
    end
    expect_success(invoke(cluster, Evse::CMD_ENABLE_CHARGING,
      Evse::EnableChargingRequest.new(nil, 6_000_i64, 16_000_i64)))
    cluster.report_ev_connected(12_u32)
    cluster.report_transfer_started
    cluster.update_session(30_u32, 5_000_i64)
    cluster.report_transfer_stopped(Evse::EnergyTransferStoppedReason::EvStopped, 1_000_i64)
    cluster.report_ev_disconnected(40_u32)
    event_ids.should eq([
      Evse::EVENT_EV_CONNECTED, Evse::EVENT_ENERGY_TRANSFER_STARTED,
      Evse::EVENT_ENERGY_TRANSFER_STOPPED, Evse::EVENT_EV_NOT_DETECTED,
    ])
    cluster.session_id.should be_nil
    cluster.state.should eq(Evse::State::NotPluggedIn)
  end

  it "locks out charging after a host fault and emits a critical fault event" do
    cluster = evse
    events = [] of Tuple(UInt32, Matter::InteractionModel::EventPriority)
    cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, event : UInt32, priority : Matter::InteractionModel::EventPriority, _data : TLV::Any, _fabric : UInt8?) do
      events << {event, priority}
      nil
    end
    cluster.report_fault(Evse::FaultState::GroundFault)
    cluster.supply_state.should eq(Evse::SupplyState::DisabledError)
    cluster.state.should eq(Evse::State::Fault)
    expect_status(invoke(cluster, Evse::CMD_ENABLE_CHARGING,
      Evse::EnableChargingRequest.new(nil, 6_000_i64, 16_000_i64)), EvseStatus::Failure)
    events.last[0].should eq(Evse::EVENT_FAULT)
    events.last[1].should eq(Matter::InteractionModel::EventPriority::Critical)
    cluster.report_fault(Evse::FaultState::NoError)
    cluster.supply_state.should eq(Evse::SupplyState::Disabled)
  end
end
