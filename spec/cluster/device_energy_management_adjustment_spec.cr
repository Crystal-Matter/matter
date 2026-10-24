require "../spec_helper"
require "../../src/matter/cluster/device_energy_management"

private alias AdjustDEM = Matter::Cluster::DeviceEnergyManagement
private alias AdjustStatus = Matter::InteractionModel::Status
private alias AdjustCode = Matter::InteractionModel::StatusCode

private def adjust_dem : AdjustDEM
  build(AdjustDEM, esa_type: AdjustDEM::ESAType::WaterHeating,
    can_generate: false, abs_min_power: 0_i64, abs_max_power: 5_000_i64,
    feature_map: AdjustDEM::Feature::PowerForecastReporting |
                 AdjustDEM::Feature::ForecastAdjustment)
end

private def adjustable_slot(nominal : Int64 = 2_000_i64,
                            duration : UInt32 = 1_200_u32) : AdjustDEM::Slot
  AdjustDEM::Slot.new(600_u32, 1_800_u32, duration, 0_u32, duration,
    nominal_power: nominal, min_power: 1_000_i64, max_power: 3_000_i64,
    nominal_energy: 667_i64, min_power_adjustment: 500_i64,
    max_power_adjustment: 4_000_i64,
    min_duration_adjustment: 600_u32, max_duration_adjustment: 1_800_u32)
end

private def adjustable_forecast(id : UInt32 = 1_u32,
                                nominal : Int64 = 2_000_i64,
                                duration : UInt32 = 1_200_u32) : AdjustDEM::Forecast
  AdjustDEM::Forecast.new(id, nil, 1_000_u32, 1_000_u32 + duration,
    false, [adjustable_slot(nominal, duration)],
    AdjustDEM::ForecastUpdateReason::InternalOptimization)
end

private def modify_request(id : UInt32 = 1_u32,
                           power : Int64 = 2_500_i64,
                           duration : UInt32 = 1_500_u32)
  AdjustDEM::ModifyForecastRequest.new(id,
    [AdjustDEM::SlotAdjustment.new(0_u8, power, duration)],
    AdjustDEM::AdjustmentCause::LocalOptimization)
end

describe "Matter 1.6 Device Energy Management FA" do
  it "advertises PFR+FA with required adjustment fields and typed commands" do
    cluster = adjust_dem
    cluster.feature_map.should eq(AdjustDEM::Feature::PowerForecastReporting |
                                  AdjustDEM::Feature::ForecastAdjustment)
    cluster.commands.map(&.id.id).should eq([
      AdjustDEM::CMD_MODIFY_FORECAST_REQUEST, AdjustDEM::CMD_CANCEL_REQUEST,
    ])
    cluster.report_forecast(adjustable_forecast)
    slot = cluster.forecast.try(&.slots.first) || raise "missing slot"
    slot.min_power_adjustment.should eq(500_i64)
    slot.max_duration_adjustment.should eq(1_800_u32)
    encoded = slot.to_tlv(nil).value.as(TLV::Structure)
    encoded[14_u8].value.should eq(500_i64)
    encoded[17_u8].value.should eq(1_800_u32)
    AdjustDEM::ModifyForecastRequest.from_tlv(modify_request.to_tlv(nil))
      .slot_adjustments.first.slot_index.should eq(0_u8)
  end

  it "rejects stale IDs and out-of-range slot adjustments before host approval" do
    cluster = adjust_dem
    cluster.report_forecast(adjustable_forecast)
    calls = 0
    cluster.on_modify_forecast do |_request, _fabric|
      calls += 1
      AdjustDEM::ForecastDecision.new(AdjustStatus.invalid_in_state)
    end
    cluster.on_cancel_forecast_adjustment { |_fabric| AdjustStatus.success }
    expect_status(invoke(cluster, AdjustDEM::CMD_MODIFY_FORECAST_REQUEST,
      modify_request(0_u32)), AdjustCode::InvalidInState)
    expect_status(invoke(cluster, AdjustDEM::CMD_MODIFY_FORECAST_REQUEST,
      modify_request(1_u32, 4_001_i64)), AdjustCode::ConstraintError)
    expect_status(invoke(cluster, AdjustDEM::CMD_MODIFY_FORECAST_REQUEST,
      modify_request(1_u32, 2_500_i64, 1_801_u32)), AdjustCode::ConstraintError)
    expect_status(invoke(cluster, AdjustDEM::CMD_MODIFY_FORECAST_REQUEST,
      AdjustDEM::ModifyForecastRequest.new(1_u32,
        [AdjustDEM::SlotAdjustment.new(1_u8, 2_500_i64, 1_500_u32)],
        AdjustDEM::AdjustmentCause::LocalOptimization)), AdjustCode::ConstraintError)
    calls.should eq(0)
    expect_status(invoke(cluster, AdjustDEM::CMD_MODIFY_FORECAST_REQUEST,
      modify_request), AdjustCode::InvalidInState)
    calls.should eq(1)
    cluster.forecast.try(&.forecast_id).should eq(1_u32)
  end

  it "commits host-approved changes with a new ID, fabric identity and immediate report" do
    cluster = adjust_dem
    cluster.report_forecast(adjustable_forecast)
    changed = [] of UInt32
    cluster.on_attribute_changed = ->(_ep : UInt16, _cl : UInt32, id : UInt32) { changed << id; nil }
    fabrics = [] of UInt8?
    cluster.on_modify_forecast do |_request, fabric|
      fabrics << fabric
      AdjustDEM::ForecastDecision.new(AdjustStatus.success,
        adjustable_forecast(1_u32, 2_500_i64, 1_500_u32))
    end
    cluster.on_cancel_forecast_adjustment do |fabric|
      fabrics << fabric
      AdjustStatus.success
    end
    expect_success(invoke(cluster, AdjustDEM::CMD_MODIFY_FORECAST_REQUEST,
      modify_request, is_case_session: true, fabric_index: 2_u8))
    cluster.forecast.try(&.forecast_id).should eq(2_u32)
    cluster.forecast.try(&.slots.first.nominal_power).should eq(2_500_i64)
    cluster.forecast.try(&.forecast_update_reason).should eq(
      AdjustDEM::ForecastUpdateReason::LocalOptimization)
    changed.should eq([AdjustDEM::ATTR_FORECAST])
    expect_success(invoke(cluster, AdjustDEM::CMD_CANCEL_REQUEST,
      is_case_session: true, fabric_index: 2_u8))
    cluster.forecast.try(&.forecast_id).should eq(3_u32)
    cluster.forecast.try(&.slots.first.nominal_power).should eq(2_000_i64)
    fabrics.should eq([2_u8, 2_u8])
  end

  it "does not publish a successful host decision without a replacement forecast" do
    cluster = adjust_dem
    cluster.report_forecast(adjustable_forecast)
    cluster.on_modify_forecast do |_request, _fabric|
      AdjustDEM::ForecastDecision.new(AdjustStatus.success)
    end
    cluster.on_cancel_forecast_adjustment { |_fabric| AdjustStatus.success }
    expect_status(invoke(cluster, AdjustDEM::CMD_MODIFY_FORECAST_REQUEST,
      modify_request), AdjustCode::InvalidInState)
    cluster.forecast.try(&.forecast_id).should eq(1_u32)
    cluster.forecast.try(&.slots.first.nominal_power).should eq(2_000_i64)
  end

  it "ends an active change on conflicting opt-out even if host cancellation fails" do
    cluster = adjust_dem
    cluster.report_forecast(adjustable_forecast)
    cluster.on_modify_forecast do |_request, _fabric|
      AdjustDEM::ForecastDecision.new(AdjustStatus.success,
        adjustable_forecast(1_u32, 2_500_i64, 1_500_u32))
    end
    cluster.on_cancel_forecast_adjustment { |_fabric| raise "synthetic refusal" }
    expect_success(invoke(cluster, AdjustDEM::CMD_MODIFY_FORECAST_REQUEST, modify_request))
    cluster.report_opt_out_state(AdjustDEM::OptOutState::LocalOptOut)
    cluster.forecast.try(&.forecast_id).should eq(3_u32)
    cluster.forecast.try(&.slots.first.nominal_power).should eq(2_000_i64)
  end
end
