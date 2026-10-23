require "./support/console"
require "./support/main"

# Synthetic heater whose host accepts a bounded power and duration change.
module MatterAdjustableHeater
  alias Energy = Matter::Cluster::DeviceEnergyManagement
  alias Status = Matter::InteractionModel::Status

  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Synthetic Adjustable Heater",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: rand(0x0001_u16..0xFFFF_u16),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_adjustable_heater_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Energy, esa_type: Energy::ESAType::WaterHeating,
        can_generate: false, abs_min_power: 0_i64, abs_max_power: 5_000_i64,
        feature_map: Energy::Feature::PowerForecastReporting | Energy::Feature::ForecastAdjustment
    end

    protected def before_start : Nil
      energy = node.get_cluster!(1_u16, Energy)
      now = (Time.utc.to_unix - 946_684_800_i64).to_u32
      start_time = now + 3_600_u32
      energy.report_forecast(forecast_for(start_time, 2_000_i64, 1_200_u32))
      energy.on_modify_forecast do |request, _fabric|
        if adjustment = request.slot_adjustments.first?
          Energy::ForecastDecision.new(Status.success,
            forecast_for(start_time, adjustment.nominal_power, adjustment.duration))
        else
          Energy::ForecastDecision.new(Status.invalid_in_state)
        end
      end
      energy.on_cancel_forecast_adjustment { |_fabric| Status.success }
      super
    end

    private def forecast_for(start_time : UInt32, power : Int64, duration : UInt32) : Energy::Forecast
      slot = Energy::Slot.new(600_u32, 1_800_u32, duration, 0_u32, duration,
        nominal_power: power, min_power: 500_i64, max_power: 4_000_i64,
        nominal_energy: power * duration.to_i64 // 3_600_i64,
        min_power_adjustment: 500_i64, max_power_adjustment: 4_000_i64,
        min_duration_adjustment: 600_u32, max_duration_adjustment: 1_800_u32)
      Energy::Forecast.new(1_u32, nil, start_time, start_time + duration,
        false, [slot], Energy::ForecastUpdateReason::InternalOptimization)
    end
  end
end

Examples.main("Synthetic Adjustable Heater") { MatterAdjustableHeater::Device.new }
