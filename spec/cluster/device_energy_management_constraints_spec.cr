require "../spec_helper"
require "../../src/matter/cluster/device_energy_management"

private alias ConDEM = Matter::Cluster::DeviceEnergyManagement
private alias ConStatus = Matter::InteractionModel::Status
private alias ConCode = Matter::InteractionModel::StatusCode

private def constraint_dem : ConDEM
  build(ConDEM, esa_type: ConDEM::ESAType::WaterHeating,
    can_generate: false, abs_min_power: 0_i64, abs_max_power: 5_000_i64,
    feature_map: ConDEM::Feature::PowerForecastReporting |
                 ConDEM::Feature::ConstraintBasedAdjustment)
end

private def constraint_now : UInt32
  (Time.utc.to_unix - ConDEM::MATTER_EPOCH_UNIX_SECONDS).to_u32
end

private def constraint_forecast(start : UInt32, id : UInt32 = 1_u32,
                                nominal : Int64 = 2_000_i64) : ConDEM::Forecast
  slot = ConDEM::Slot.new(600_u32, 3_600_u32, 1_200_u32, 0_u32, 1_200_u32,
    nominal_power: nominal, min_power: 0_i64, max_power: 5_000_i64,
    nominal_energy: nominal * 1_200_i64 // 3_600_i64)
  ConDEM::Forecast.new(id, nil, start, start + 1_200_u32,
    false, [slot], ConDEM::ForecastUpdateReason::InternalOptimization)
end

private def constraint_request(start : UInt32, duration : UInt32 = 1_200_u32,
                               nominal : Int64 = 2_500_i64) : ConDEM::RequestConstraintBasedForecast
  ConDEM::RequestConstraintBasedForecast.new(
    [ConDEM::Constraint.new(start, duration, nominal, 900_i64)],
    ConDEM::AdjustmentCause::LocalOptimization)
end

describe "Matter 1.6 Device Energy Management CON" do
  it "advertises only PFR+CON and decodes typed constraint fields" do
    cluster = constraint_dem
    cluster.feature_map.should eq(ConDEM::Feature::PowerForecastReporting |
                                  ConDEM::Feature::ConstraintBasedAdjustment)
    cluster.commands.map(&.id.id).should eq([
      ConDEM::CMD_REQUEST_CONSTRAINT_BASED_FORECAST,
      ConDEM::CMD_CANCEL_REQUEST,
    ])
    request = constraint_request(constraint_now + 3_600_u32)
    parsed = ConDEM::RequestConstraintBasedForecast.from_tlv(request.to_tlv(nil))
    parsed.constraints.first.nominal_power.should eq(2_500_i64)
    parsed.constraints.first.maximum_energy.should eq(900_i64)
  end

  it "rejects past, long, out-of-range and overlapping constraints before host approval" do
    cluster = constraint_dem
    now = constraint_now
    cluster.report_forecast(constraint_forecast(now + 7_200_u32))
    calls = 0
    cluster.on_constraint_based_forecast do |_request, _fabric|
      calls += 1
      ConDEM::ForecastDecision.new(ConStatus.invalid_in_state)
    end
    cluster.on_cancel_forecast_adjustment { |_fabric| ConStatus.success }
    [
      constraint_request(now - 1_u32),
      constraint_request(now + 3_600_u32, 86_401_u32),
      constraint_request(now + 3_600_u32, 1_200_u32, 5_001_i64),
    ].each do |request|
      expect_status(invoke(cluster, ConDEM::CMD_REQUEST_CONSTRAINT_BASED_FORECAST,
        request), ConCode::ConstraintError)
    end
    overlap = ConDEM::RequestConstraintBasedForecast.new([
      ConDEM::Constraint.new(now + 3_600_u32, 1_200_u32, 2_500_i64, 900_i64),
      ConDEM::Constraint.new(now + 4_000_u32, 1_200_u32, 2_000_i64, 600_i64),
    ], ConDEM::AdjustmentCause::LocalOptimization)
    expect_status(invoke(cluster, ConDEM::CMD_REQUEST_CONSTRAINT_BASED_FORECAST,
      overlap), ConCode::ConstraintError)
    too_many = Array.new(11) do |index|
      ConDEM::Constraint.new(now + 3_600_u32 + index.to_u32 * 1_200_u32,
        1_200_u32, 2_000_i64, 600_i64)
    end
    expect_status(invoke(cluster, ConDEM::CMD_REQUEST_CONSTRAINT_BASED_FORECAST,
      ConDEM::RequestConstraintBasedForecast.new(too_many,
        ConDEM::AdjustmentCause::LocalOptimization)), ConCode::ConstraintError)
    calls.should eq(0)
    expect_status(invoke(cluster, ConDEM::CMD_REQUEST_CONSTRAINT_BASED_FORECAST,
      constraint_request(now + 3_600_u32, 86_400_u32)), ConCode::InvalidInState)
    calls.should eq(1)
  end

  it "publishes host-approved schedule with a new ID and cancels to the original" do
    cluster = constraint_dem
    now = constraint_now
    original_start = now + 7_200_u32
    constrained_start = now + 3_600_u32
    cluster.report_forecast(constraint_forecast(original_start))
    fabrics = [] of UInt8?
    changed = [] of UInt32
    cluster.on_attribute_changed = ->(_ep : UInt16, _cl : UInt32, id : UInt32) { changed << id; nil }
    cluster.on_constraint_based_forecast do |_request, fabric|
      fabrics << fabric
      ConDEM::ForecastDecision.new(ConStatus.success,
        constraint_forecast(constrained_start, nominal: 2_500_i64))
    end
    cluster.on_cancel_forecast_adjustment do |fabric|
      fabrics << fabric
      ConStatus.success
    end
    expect_success(invoke(cluster, ConDEM::CMD_REQUEST_CONSTRAINT_BASED_FORECAST,
      constraint_request(constrained_start), is_case_session: true,
      fabric_index: 3_u8))
    cluster.forecast.try(&.forecast_id).should eq(2_u32)
    cluster.forecast.try(&.start_time).should eq(constrained_start)
    cluster.forecast.try(&.forecast_update_reason).should eq(
      ConDEM::ForecastUpdateReason::LocalOptimization)
    changed.should eq([ConDEM::ATTR_FORECAST])
    expect_success(invoke(cluster, ConDEM::CMD_CANCEL_REQUEST,
      is_case_session: true, fabric_index: 3_u8))
    cluster.forecast.try(&.forecast_id).should eq(3_u32)
    cluster.forecast.try(&.start_time).should eq(original_start)
    fabrics.should eq([3_u8, 3_u8])
  end

  it "restores an active constrained forecast on opt-out despite host refusal" do
    cluster = constraint_dem
    now = constraint_now
    cluster.report_forecast(constraint_forecast(now + 7_200_u32))
    cluster.on_constraint_based_forecast do |_request, _fabric|
      ConDEM::ForecastDecision.new(ConStatus.success,
        constraint_forecast(now + 3_600_u32, nominal: 2_500_i64))
    end
    cluster.on_cancel_forecast_adjustment { |_fabric| raise "synthetic refusal" }
    expect_success(invoke(cluster, ConDEM::CMD_REQUEST_CONSTRAINT_BASED_FORECAST,
      constraint_request(now + 3_600_u32)))
    cluster.report_opt_out_state(ConDEM::OptOutState::LocalOptOut)
    cluster.forecast.try(&.forecast_id).should eq(3_u32)
    cluster.forecast.try(&.start_time).should eq(now + 7_200_u32)
  end

  it "can publish a constrained forecast from a nullable baseline and cancel to null" do
    cluster = constraint_dem
    now = constraint_now
    cluster.forecast.should be_nil
    cluster.on_constraint_based_forecast do |_request, _fabric|
      ConDEM::ForecastDecision.new(ConStatus.success,
        constraint_forecast(now + 3_600_u32, nominal: 2_500_i64))
    end
    cluster.on_cancel_forecast_adjustment { |_fabric| ConStatus.success }
    expect_success(invoke(cluster, ConDEM::CMD_REQUEST_CONSTRAINT_BASED_FORECAST,
      constraint_request(now + 3_600_u32)))
    cluster.forecast.try(&.forecast_id).should eq(1_u32)
    expect_success(invoke(cluster, ConDEM::CMD_CANCEL_REQUEST))
    cluster.forecast.should be_nil
  end
end
