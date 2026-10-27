require "./support/console"
require "./support/main"

# Synthetic washer with a host-owned, pausable active heat cycle.
module MatterPausableWasher
  DEVICE_ENDPOINT_ID = 1_u16

  alias Energy = Matter::Cluster::DeviceEnergyManagement
  alias Status = Matter::InteractionModel::Status

  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Synthetic Pausable Washer",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: rand(Examples::RANDOM_PRODUCT_ID_RANGE),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_pausable_washer_storage.yml"

    endpoint DEVICE_ENDPOINT_ID, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Energy, esa_type: Energy::ESAType::WashingMachine,
        can_generate: false, abs_min_power: 0_i64, abs_max_power: 4_000_i64,
        feature_map: Energy::Feature::PowerForecastReporting | Energy::Feature::Pausable
    end

    protected def before_start : Nil
      energy = node.get_cluster!(DEVICE_ENDPOINT_ID, Energy)
      now = (Time.utc.to_unix - 946_684_800_i64).to_u32
      energy.report_forecast(Energy::Forecast.new(1_u32, 0_u16,
        now - 60_u32, now + 1_140_u32, true, [
        Energy::Slot.new(600_u32, 1_800_u32, 1_200_u32, 60_u32, 1_140_u32,
          nominal_power: 2_500_i64, min_power: 2_000_i64,
          max_power: 3_000_i64, nominal_energy: 833_i64,
          slot_is_pausable: true, min_pause_duration: 1_u32,
          max_pause_duration: 60_u32),
      ], Energy::ForecastUpdateReason::InternalOptimization))
      energy.on_pause { |_request, _fabric| Status.success }
      energy.on_resume { |_fabric| Status.success }
      super
    end
  end
end

Examples.main("Synthetic Pausable Washer") { MatterPausableWasher::Device.new }
