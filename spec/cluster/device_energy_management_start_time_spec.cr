require "../spec_helper"
require "../../src/matter/cluster/device_energy_management"

private alias StartDEM = Matter::Cluster::DeviceEnergyManagement
private alias StartStatus = Matter::InteractionModel::Status
private alias StartCode = Matter::InteractionModel::StatusCode

private def start_dem : StartDEM
  build(StartDEM, esa_type: StartDEM::ESAType::WashingMachine,
    can_generate: false, abs_min_power: 0_i64, abs_max_power: 5_000_i64,
    feature_map: StartDEM::Feature::PowerForecastReporting | StartDEM::Feature::StartTimeAdjustment)
end

private def matter_now : UInt32
  (Time.utc.to_unix - 946_684_800_i64).to_u32
end

private def start_forecast(now : UInt32 = matter_now) : StartDEM::Forecast
  slot = StartDEM::Slot.new(600_u32, 1_800_u32, 1_200_u32, 0_u32, 1_200_u32,
    nominal_power: 2_000_i64, min_power: 1_000_i64,
    max_power: 3_000_i64, nominal_energy: 667_i64)
  StartDEM::Forecast.new(1_u32, nil, now + 3_600_u32, now + 4_800_u32,
    false, [slot], StartDEM::ForecastUpdateReason::InternalOptimization,
    earliest_start_time: now + 600_u32, latest_end_time: now + 7_200_u32)
end

private def start_request(time : UInt32, cause = StartDEM::AdjustmentCause::LocalOptimization)
  StartDEM::StartTimeAdjustRequest.new(time, cause)
end

describe "Matter 1.6 Device Energy Management STA" do
  it "advertises PFR+STA with both required forecast window fields and commands" do
    cluster = start_dem
    cluster.feature_map.should eq(StartDEM::Feature::PowerForecastReporting | StartDEM::Feature::StartTimeAdjustment)
    cluster.attributes.map(&.id.id).should contain(StartDEM::ATTR_OPT_OUT_STATE)
    cluster.commands.map(&.id.id).should eq([
      StartDEM::CMD_START_TIME_ADJUST_REQUEST, StartDEM::CMD_CANCEL_REQUEST,
    ])
    forecast = start_forecast
    cluster.report_forecast(forecast)
    encoded = forecast.to_tlv(nil).value.as(TLV::Structure)
    encoded[4_u8].value.should eq(forecast.earliest_start_time)
    encoded[5_u8].value.should eq(forecast.latest_end_time)
    StartDEM::StartTimeAdjustRequest.from_tlv(
      start_request(forecast.start_time + 60_u32).to_tlv(nil)
    ).requested_start_time.should eq(forecast.start_time + 60_u32)
    expect_raises(ArgumentError) do
      build(StartDEM, esa_type: StartDEM::ESAType::WashingMachine,
        can_generate: false, abs_min_power: 0_i64, abs_max_power: 5_000_i64,
        feature_map: StartDEM::Feature::StartTimeAdjustment)
    end
  end

  it "encodes a null EarliestStartTime under STA and keeps the field absent without STA" do
    now = matter_now
    forecast = start_forecast(now)
    nullable = StartDEM::Forecast.new(forecast.forecast_id, nil,
      forecast.start_time, forecast.end_time, false, forecast.slots,
      forecast.forecast_update_reason, latest_end_time: forecast.latest_end_time)
    nullable.latest_end_time.should_not be_nil
    cluster = start_dem
    cluster.report_forecast(nullable)
    encoded = nullable.to_tlv(nil).value.as(TLV::Structure)
    encoded[4_u8].value.should be_nil
    encoded.has_key?(5_u8).should be_true
    cluster.read_attribute(StartDEM::ATTR_FORECAST).as(TLV::Any)
      .as_structure[4_u8].value.should be_nil
    roundtrip = StartDEM::Forecast.from_tlv(nullable.to_tlv(nil))
    roundtrip.to_tlv(nil).value.as(TLV::Structure)[4_u8].value.should be_nil
    base = StartDEM::Forecast.new(forecast.forecast_id, nil,
      forecast.start_time, forecast.end_time, false, forecast.slots,
      forecast.forecast_update_reason)
    base.to_tlv(nil).value.as(TLV::Structure).has_key?(4_u8).should be_false
  end

  it "shifts a future forecast only after host approval and reports immediately" do
    now = matter_now
    cluster = start_dem
    cluster.report_forecast(start_forecast(now))
    changed = [] of UInt32
    cluster.on_attribute_changed = ->(_ep : UInt16, _cl : UInt32, id : UInt32) { changed << id; nil }
    seen = [] of UInt8?
    cluster.on_start_time_adjust do |_request, fabric|
      seen << fabric
      StartStatus.success
    end
    cluster.on_cancel_forecast_adjustment { |_fabric| StartStatus.success }
    expect_success(invoke(cluster, StartDEM::CMD_START_TIME_ADJUST_REQUEST,
      start_request(now + 4_200_u32), is_case_session: true, fabric_index: 3_u8))
    seen.should eq([3_u8])
    cluster.forecast.try(&.start_time).should eq(now + 4_200_u32)
    cluster.forecast.try(&.end_time).should eq(now + 5_400_u32)
    cluster.forecast.try(&.forecast_id).should eq(2_u32)
    cluster.forecast.try(&.forecast_update_reason).should eq(
      StartDEM::ForecastUpdateReason::LocalOptimization)
    changed.should eq([StartDEM::ATTR_FORECAST])
  end

  it "rejects requests outside time bounds, opt-out, and host denial without changing state" do
    now = matter_now
    cluster = start_dem
    cluster.report_forecast(start_forecast(now))
    calls = 0
    cluster.on_start_time_adjust do |_request, _fabric|
      calls += 1
      StartStatus.invalid_in_state
    end
    cluster.on_cancel_forecast_adjustment { |_fabric| StartStatus.success }
    expect_status(invoke(cluster, StartDEM::CMD_START_TIME_ADJUST_REQUEST,
      start_request(now - 1_u32)), StartCode::ConstraintError)
    expect_status(invoke(cluster, StartDEM::CMD_START_TIME_ADJUST_REQUEST,
      start_request(now + 500_u32)), StartCode::ConstraintError)
    expect_status(invoke(cluster, StartDEM::CMD_START_TIME_ADJUST_REQUEST,
      start_request(now + 6_100_u32)), StartCode::ConstraintError)
    calls.should eq(0)
    # An earlier start is within the advertised window; let the host decide.
    expect_status(invoke(cluster, StartDEM::CMD_START_TIME_ADJUST_REQUEST,
      start_request(now + 2_500_u32)), StartCode::InvalidInState)
    expect_status(invoke(cluster, StartDEM::CMD_START_TIME_ADJUST_REQUEST,
      start_request(now + 4_200_u32)), StartCode::InvalidInState)
    calls.should eq(2)
    cluster.forecast.try(&.forecast_id).should eq(1_u32)
    cluster.report_opt_out_state(StartDEM::OptOutState::LocalOptOut)
    expect_status(invoke(cluster, StartDEM::CMD_START_TIME_ADJUST_REQUEST,
      start_request(now + 4_200_u32)), StartCode::InvalidInState)
    calls.should eq(2)
  end

  it "cancels a host-approved shift and restores the original schedule" do
    now = matter_now
    cluster = start_dem
    cluster.report_forecast(start_forecast(now))
    cluster.on_start_time_adjust { |_request, _fabric| StartStatus.success }
    cancelled = [] of UInt8?
    cluster.on_cancel_forecast_adjustment do |fabric|
      cancelled << fabric
      StartStatus.success
    end
    expect_success(invoke(cluster, StartDEM::CMD_START_TIME_ADJUST_REQUEST,
      start_request(now + 4_200_u32), is_case_session: true, fabric_index: 2_u8))
    expect_success(invoke(cluster, StartDEM::CMD_CANCEL_REQUEST,
      is_case_session: true, fabric_index: 2_u8))
    cancelled.should eq([2_u8])
    cluster.forecast.try(&.start_time).should eq(now + 3_600_u32)
    cluster.forecast.try(&.forecast_id).should eq(3_u32)
    cluster.forecast.try(&.forecast_update_reason).should eq(
      StartDEM::ForecastUpdateReason::InternalOptimization)
    expect_success(invoke(cluster, StartDEM::CMD_CANCEL_REQUEST))
    cancelled.should eq([2_u8])
  end
end
