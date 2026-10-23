require "./support/console"
require "./support/main"

# Synthetic washer-dryer combo. A production host would use its active cycle
# and load sensors to choose supported options and accept or reject writes.
module MatterLaundryCombo
  alias Energy = Matter::Cluster::DeviceEnergyManagement
  alias Dryer = Matter::Cluster::LaundryDryerControls
  alias Washer = Matter::Cluster::LaundryWasherControls
  alias Status = Matter::InteractionModel::Status

  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Synthetic Washer-Dryer Combo",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: rand(0x0001_u16..0xFFFF_u16),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_laundry_combo_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Energy, esa_type: Energy::ESAType::WashingMachine,
        can_generate: false, abs_min_power: 0_i64, abs_max_power: 4_000_i64,
        feature_map: Energy::Feature::PowerForecastReporting
      cluster Dryer,
        supported_dryness_levels: [Dryer::DrynessLevel::Low, Dryer::DrynessLevel::Normal, Dryer::DrynessLevel::Extra],
        selected_dryness_level: Dryer::DrynessLevel::Normal
      cluster Washer,
        feature_map: Washer::Feature::Spin | Washer::Feature::Rinse,
        spin_speeds: ["Gentle", "Standard", "Fast"],
        spin_speed_current: 1_u8,
        supported_rinses: [Washer::NumberOfRinses::None, Washer::NumberOfRinses::Normal, Washer::NumberOfRinses::Extra],
        number_of_rinses: Washer::NumberOfRinses::Normal
    end

    protected def before_start : Nil
      energy = node.get_cluster!(1_u16, Energy)
      # The host's planned heat and spin stages are an indicative forecast;
      # physical timing and power estimates remain application-owned.
      start_time = (Time.utc.to_unix - 946_684_800_i64).to_u32
      energy.report_forecast(Energy::Forecast.new(1_u32, nil,
        start_time, start_time + 300_u32, false, [
        Energy::Slot.new(120_u32, 240_u32, 180_u32, 0_u32, 180_u32,
          nominal_power: 2_500_i64, min_power: 2_000_i64,
          max_power: 3_000_i64, nominal_energy: 125_i64),
        Energy::Slot.new(60_u32, 180_u32, 120_u32, 0_u32, 120_u32,
          nominal_power: 800_i64, min_power: 400_i64,
          max_power: 1_000_i64, nominal_energy: 27_i64),
      ], Energy::ForecastUpdateReason::InternalOptimization))
      dryer = node.get_cluster!(1_u16, Dryer)
      # This load cannot use low dryness because the fabric is too heavy.
      dryer.on_select_dryness { |level| level == Dryer::DrynessLevel::Low ? Status.invalid_in_state : Status.success }
      washer = node.get_cluster!(1_u16, Washer)
      # Fast spin is unavailable while the current load is unbalanced.
      washer.on_select_spin_speed { |index| index == 2_u8 ? Status.invalid_in_state : Status.success }
      washer.on_select_rinses { |_rinses| Status.success }
      super
    end
  end
end

Examples.main("Synthetic Washer-Dryer Combo") { MatterLaundryCombo::Device.new }
