require "../spec_helper"
require "../../src/matter/cluster/device_energy_management"

private alias ForecastDEM = Matter::Cluster::DeviceEnergyManagement

private def forecast_dem(feature : ForecastDEM::Feature) : ForecastDEM
  build(ForecastDEM, esa_type: ForecastDEM::ESAType::WashingMachine,
    can_generate: false, abs_min_power: 0_i64, abs_max_power: 5_000_i64,
    feature_map: feature)
end

private def power_forecast(id : UInt32 = 1_u32) : ForecastDEM::Forecast
  slot = ForecastDEM::Slot.new(60_u32, 300_u32, 120_u32, 0_u32, 120_u32,
    nominal_power: 2_000_i64, min_power: 1_000_i64,
    max_power: 3_000_i64, nominal_energy: 67_i64)
  ForecastDEM::Forecast.new(id, nil, 1_000_u32, 1_120_u32, false,
    [slot], ForecastDEM::ForecastUpdateReason::InternalOptimization)
end

describe "Matter 1.6 Device Energy Management forecast reporting" do
  it "advertises a PFR-only profile with the nullable Forecast attribute" do
    cluster = forecast_dem(ForecastDEM::Feature::PowerForecastReporting)
    cluster.feature_map.should eq(ForecastDEM::Feature::PowerForecastReporting)
    ids = cluster.attributes.map(&.id.id)
    ids.should contain(ForecastDEM::ATTR_FORECAST)
    ids.should_not contain(ForecastDEM::ATTR_POWER_ADJUSTMENT_CAPABILITY)
    ids.should_not contain(ForecastDEM::ATTR_OPT_OUT_STATE)
    cluster.commands.should be_empty
    cluster.events.should be_empty
    cluster.forecast.should be_nil
    encoded = power_forecast.to_tlv(nil)
    encoded.value.as(TLV::Structure)[1_u8].value.should be_nil
    ForecastDEM::Forecast.from_tlv(encoded).slots.first.nominal_power.should eq(2_000_i64)
  end

  it "advertises SFR with manufacturer state and rejects mixed forecast slot schemas" do
    cluster = forecast_dem(ForecastDEM::Feature::StateForecastReporting)
    slot = ForecastDEM::Slot.new(60_u32, 300_u32, 120_u32, 0_u32, 120_u32,
      manufacturer_esa_state: 7_u16)
    forecast = ForecastDEM::Forecast.new(1_u32, nil, 1_000_u32, 1_120_u32,
      false, [slot], ForecastDEM::ForecastUpdateReason::InternalOptimization)
    cluster.report_forecast(forecast)
    cluster.forecast.try(&.slots.first.manufacturer_esa_state).should eq(7_u16)
    ForecastDEM::Forecast.from_tlv(forecast.to_tlv(nil)).slots.first.nominal_power.should be_nil
    expect_raises(ArgumentError) { forecast_dem(ForecastDEM::Feature::None) }
    expect_raises(ArgumentError) do
      forecast_dem(ForecastDEM::Feature::PowerForecastReporting | ForecastDEM::Feature::StateForecastReporting)
    end
    expect_raises(ArgumentError) { cluster.report_forecast(power_forecast) }
  end

  it "validates slots, forecast timing, active index, and host power limits" do
    cluster = forecast_dem(ForecastDEM::Feature::PowerForecastReporting)
    expect_raises(ArgumentError) do
      cluster.report_forecast(ForecastDEM::Forecast.new(1_u32, nil, 1_000_u32, 900_u32,
        false, power_forecast.slots, ForecastDEM::ForecastUpdateReason::InternalOptimization))
    end
    expect_raises(ArgumentError) do
      cluster.report_forecast(ForecastDEM::Forecast.new(1_u32, 1_u16, 1_000_u32, 1_120_u32,
        false, power_forecast.slots, ForecastDEM::ForecastUpdateReason::InternalOptimization))
    end
    expect_raises(ArgumentError) do
      cluster.report_forecast(ForecastDEM::Forecast.new(1_u32, nil, 1_000_u32, 1_120_u32,
        false, ([] of ForecastDEM::Slot), ForecastDEM::ForecastUpdateReason::InternalOptimization))
    end
    expect_raises(ArgumentError) do
      slot = ForecastDEM::Slot.new(60_u32, 300_u32, 120_u32, 0_u32, 120_u32,
        nominal_power: 6_000_i64, min_power: 1_000_i64,
        max_power: 6_000_i64, nominal_energy: 67_i64)
      cluster.report_forecast(ForecastDEM::Forecast.new(1_u32, nil, 1_000_u32, 1_120_u32,
        false, [slot], ForecastDEM::ForecastUpdateReason::InternalOptimization))
    end
  end

  it "keeps advertised forecast power within nameplate limits as they change" do
    cluster = forecast_dem(ForecastDEM::Feature::PowerForecastReporting)
    cluster.report_forecast(power_forecast)
    expect_raises(ArgumentError) { cluster.report_abs_power_limits(0_i64, 1_500_i64) }
    cluster.abs_max_power.should eq(5_000_i64)
    cluster.forecast.try(&.slots.first.max_power).should eq(3_000_i64)
  end

  it "copies host and reader slot lists and increments forecast IDs on updates" do
    cluster = forecast_dem(ForecastDEM::Feature::PowerForecastReporting)
    forecast = power_forecast
    cluster.report_forecast(forecast)
    forecast.slots.clear
    cluster.forecast.try(&.slots.size).should eq(1)
    cluster.forecast.try(&.slots.clear)
    cluster.forecast.try(&.slots.size).should eq(1)
    expect_raises(ArgumentError) { cluster.report_forecast(power_forecast(1_u32)) }
    cluster.report_forecast(power_forecast(2_u32))
    cluster.forecast.try(&.forecast_id).should eq(2_u32)
  end

  it "reports null transitions immediately and keeps slot progress out of subscriptions" do
    cluster = forecast_dem(ForecastDEM::Feature::PowerForecastReporting)
    changed = [] of UInt32
    cluster.on_attribute_changed = ->(_ep : UInt16, _cl : UInt32, id : UInt32) { changed << id; nil }
    cluster.report_forecast(power_forecast)
    cluster.report_slot_progress(0_u16, 15_u32, 105_u32)
    cluster.forecast.try(&.slots.first.elapsed_slot_time).should eq(15_u32)
    cluster.forecast.try(&.slots.first.remaining_slot_time).should eq(105_u32)
    changed.should eq([ForecastDEM::ATTR_FORECAST])
    cluster.report_forecast(power_forecast(2_u32))
    changed.should eq([ForecastDEM::ATTR_FORECAST])
    cluster.report_forecast(nil)
    changed.should eq([ForecastDEM::ATTR_FORECAST, ForecastDEM::ATTR_FORECAST])
    cluster.save_state.should be_nil
    forecast_dem(ForecastDEM::Feature::PowerForecastReporting).forecast.should be_nil
  end
end
