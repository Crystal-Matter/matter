require "../spec_helper"

private alias EvseV2x = Matter::Cluster::EnergyEvse
private alias EvseV2xStatus = Matter::InteractionModel::StatusCode

private def v2x_evse : EvseV2x
  cluster = build(EvseV2x, circuit_capacity: 32_000_i64,
    feature_map: EvseV2x::Feature::ChargingPreferences | EvseV2x::Feature::V2x)
  cluster.on_enable_discharging = ->(_until : UInt32?, _maximum : Int64) {
    Matter::InteractionModel::Status.success
  }
  cluster.on_disable = -> { Matter::InteractionModel::Status.success }
  cluster
end

describe EvseV2x do
  it "exposes the complete V2X command and attribute surface only when enabled" do
    base = build(EvseV2x, circuit_capacity: 32_000_i64)
    accepted_command_ids(base).should_not contain(0x03_u32)
    read_status(base, 0x0004_u32).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAttribute)
    read_status(base, 0x0008_u32).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAttribute)
    read_status(base, 0x0043_u32).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAttribute)

    v2x = v2x_evse
    accepted_command_ids(v2x).should contain(0x03_u32)
    read(v2x, 0x0004_u32).should eq(0_u32)
    read(v2x, 0x0008_u32).should eq(0_i64)
    read(v2x, 0x0043_u32).should be_nil
    metadata = v2x.get_command_metadata(EvseV2x::CMD_ENABLE_DISCHARGING).as(Matter::Cluster::CommandMetadata)
    metadata.timed?.should be_true
    metadata.access.should eq(
      Matter::InteractionModel::EntryPrivilege::Operate)
  end

  it "encodes a nullable discharging grant and enforces current limits without a partial state change" do
    EvseV2x::EnableDischargingRequest.new(nil, 10_000_i64).to_tlv(nil).as_structure.keys.should eq([0_u8, 1_u8])
    cluster = v2x_evse
    maximum_seen = nil.as(Int64?)
    cluster.on_enable_discharging = ->(_until : UInt32?, maximum : Int64) do
      maximum_seen = maximum
      Matter::InteractionModel::Status.success
    end
    expect_status(invoke(cluster, EvseV2x::CMD_ENABLE_DISCHARGING,
      EvseV2x::EnableDischargingRequest.new(nil, -1_i64)), EvseV2xStatus::ConstraintError)
    maximum_seen.should be_nil
    cluster.supply_state.should eq(EvseV2x::SupplyState::Disabled)
    expect_success(invoke(cluster, EvseV2x::CMD_ENABLE_DISCHARGING,
      EvseV2x::EnableDischargingRequest.new(nil, 40_000_i64)))
    maximum_seen.should eq(32_000_i64)
    cluster.maximum_discharge_current.should eq(32_000_i64)
    cluster.supply_state.should eq(EvseV2x::SupplyState::DischargingEnabled)
    cluster.discharging_enabled_until.should be_nil
    cluster.on_enable_charging = ->(_until : UInt32?, _minimum : Int64, _maximum : Int64) {
      Matter::InteractionModel::Status.success
    }
    expect_success(invoke(cluster, EvseV2x::CMD_ENABLE_CHARGING,
      EvseV2x::EnableChargingRequest.new(nil, 6_000_i64, 10_000_i64)))
    cluster.supply_state.should eq(EvseV2x::SupplyState::Enabled)
    expect_success(invoke(cluster, EvseV2x::CMD_DISABLE))
    cluster.discharging_enabled_until.should eq(0_u32)
    cluster.supply_state.should eq(EvseV2x::SupplyState::Disabled)
  end

  it "lets the host refuse a discharging grant before any state changes" do
    cluster = v2x_evse
    cluster.on_enable_discharging = ->(_until : UInt32?, _maximum : Int64) {
      Matter::InteractionModel::Status.failure
    }
    expect_status(invoke(cluster, EvseV2x::CMD_ENABLE_DISCHARGING,
      EvseV2x::EnableDischargingRequest.new(nil, 10_000_i64)), EvseV2xStatus::Failure)
    cluster.supply_state.should eq(EvseV2x::SupplyState::Disabled)
    cluster.maximum_discharge_current.should eq(0_i64)
  end

  it "expires a durable finite discharging grant on restart" do
    now = Time.utc(2026, 1, 1)
    clock = -> { now }
    timer = ->(_delay : Time::Span, _callback : Proc(Nil)) { nil }
    cluster = build(EvseV2x, circuit_capacity: 32_000_i64,
      feature_map: EvseV2x::Feature::ChargingPreferences | EvseV2x::Feature::V2x,
      clock: clock, expiry_timer: timer)
    cluster.on_enable_discharging = ->(_until : UInt32?, _maximum : Int64) {
      Matter::InteractionModel::Status.success
    }
    deadline = (now.to_unix - EvseV2x::MATTER_EPOCH_UNIX + 10).to_u32
    expect_success(invoke(cluster, EvseV2x::CMD_ENABLE_DISCHARGING,
      EvseV2x::EnableDischargingRequest.new(deadline, 10_000_i64)))
    document = cluster.save_state.as(Matter::Storage::Document)
    now += 11.seconds
    restored = build(EvseV2x, circuit_capacity: 32_000_i64,
      feature_map: EvseV2x::Feature::ChargingPreferences | EvseV2x::Feature::V2x,
      clock: clock, expiry_timer: timer)
    restored.on_disable = -> { Matter::InteractionModel::Status.success }
    restored.restore_state(document)
    restored.supply_state.should eq(EvseV2x::SupplyState::Disabled)
    restored.discharging_enabled_until.should eq(0_u32)
    restored.maximum_discharge_current.should eq(0_i64)
  end

  it "keeps independent charge and discharge grants through their different deadlines" do
    now = Time.utc(2026, 1, 1)
    callbacks = [] of Proc(Nil)
    clock = -> { now }
    timer = ->(_delay : Time::Span, callback : Proc(Nil)) do
      callbacks << callback
      nil
    end
    cluster = build(EvseV2x, circuit_capacity: 32_000_i64,
      feature_map: EvseV2x::Feature::ChargingPreferences | EvseV2x::Feature::V2x,
      clock: clock, expiry_timer: timer)
    cluster.on_enable_charging = ->(_until : UInt32?, _minimum : Int64, _maximum : Int64) {
      Matter::InteractionModel::Status.success
    }
    cluster.on_enable_discharging = ->(_until : UInt32?, _maximum : Int64) {
      Matter::InteractionModel::Status.success
    }
    cluster.on_disable = -> { Matter::InteractionModel::Status.success }
    charge_deadline = (now.to_unix - EvseV2x::MATTER_EPOCH_UNIX + 15).to_u32
    discharge_deadline = charge_deadline - 10_u32
    expect_success(invoke(cluster, EvseV2x::CMD_ENABLE_CHARGING,
      EvseV2x::EnableChargingRequest.new(charge_deadline, 6_000_i64, 40_000_i64)))
    expect_success(invoke(cluster, EvseV2x::CMD_ENABLE_DISCHARGING,
      EvseV2x::EnableDischargingRequest.new(discharge_deadline, 40_000_i64)))
    cluster.supply_state.should eq(EvseV2x::SupplyState::Enabled)
    cluster.maximum_charge_current.should eq(32_000_i64)
    cluster.maximum_discharge_current.should eq(32_000_i64)
    started = nil.as(TLV::Any?)
    cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, id : UInt32, _priority : Matter::InteractionModel::EventPriority, payload : TLV::Any, _fabric : UInt8?) do
      started = payload if id == EvseV2x::EVENT_ENERGY_TRANSFER_STARTED
      nil
    end
    cluster.report_ev_connected(11_u32)
    cluster.report_transfer_started
    started.as(TLV::Any).as_structure[2_u8].value.should eq(32_000_i64)
    started.as(TLV::Any).as_structure[3_u8].value.should eq(32_000_i64)
    cluster.report_transfer_stopped(EvseV2x::EnergyTransferStoppedReason::EvStopped, 0_i64)
    now += 6.seconds
    callbacks.last.call
    cluster.supply_state.should eq(EvseV2x::SupplyState::ChargingEnabled)
    cluster.charging_enabled_until.should eq(charge_deadline)
    cluster.discharging_enabled_until.should eq(0_u32)
    cluster.maximum_discharge_current.should eq(0_i64)
    now += 10.seconds
    callbacks.last.call
    cluster.supply_state.should eq(EvseV2x::SupplyState::Disabled)
    cluster.charging_enabled_until.should eq(0_u32)
    cluster.minimum_charge_current.should eq(0_i64)
    cluster.maximum_charge_current.should eq(0_i64)
  end

  it "reports V2X session counters and every conditional event field" do
    cluster = v2x_evse
    events = [] of Tuple(UInt32, TLV::Any)
    cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, id : UInt32, _priority : Matter::InteractionModel::EventPriority, payload : TLV::Any, _fabric : UInt8?) do
      events << {id, payload}
      nil
    end
    expect_success(invoke(cluster, EvseV2x::CMD_ENABLE_DISCHARGING,
      EvseV2x::EnableDischargingRequest.new(nil, 12_000_i64)))
    cluster.report_ev_connected(7_u32)
    cluster.report_discharge_started
    cluster.update_session(30_u32, 0_i64, 5_000_i64)
    cluster.report_discharge_stopped(EvseV2x::EnergyTransferStoppedReason::EvStopped, 2_000_i64)
    cluster.session_energy_discharged.should eq(5_000_i64)
    cluster.report_ev_disconnected(40_u32)
    events.find!(&.[0].==(EvseV2x::EVENT_ENERGY_TRANSFER_STARTED))[1]
      .as_structure[3_u8].value.should eq(12_000_i64)
    events.find!(&.[0].==(EvseV2x::EVENT_ENERGY_TRANSFER_STOPPED))[1]
      .as_structure[5_u8].value.should eq(2_000_i64)
    events.find!(&.[0].==(EvseV2x::EVENT_EV_NOT_DETECTED))[1]
      .as_structure[4_u8].value.should eq(5_000_i64)
    cluster.session_energy_discharged.should be_nil
  end

  it "reports zero discharge current when a V2X EVSE is charging" do
    cluster = v2x_evse
    cluster.on_enable_charging = ->(_until : UInt32?, _minimum : Int64, _maximum : Int64) {
      Matter::InteractionModel::Status.success
    }
    started = nil.as(TLV::Any?)
    cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, id : UInt32, _priority : Matter::InteractionModel::EventPriority, payload : TLV::Any, _fabric : UInt8?) do
      started = payload if id == EvseV2x::EVENT_ENERGY_TRANSFER_STARTED
      nil
    end
    expect_success(invoke(cluster, EvseV2x::CMD_ENABLE_CHARGING,
      EvseV2x::EnableChargingRequest.new(nil, 6_000_i64, 10_000_i64)))
    cluster.report_ev_connected(9_u32)
    cluster.report_transfer_started
    started.as(TLV::Any).as_structure[3_u8].value.should eq(0_i64)
  end
end
