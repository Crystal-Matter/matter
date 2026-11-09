require "./support/console"
require "./support/main"

# Synthetic daily price calendar on an Aggregator endpoint. A production
# provider publishes its own calendar and refreshes projections on clock edges.
module MatterCommodityTariff
  EXAMPLE_PRODUCT_ID = 0x0700_u16
  REFRESH_HOOK_ENV   = "MATTER_COMMODITY_TARIFF_HOOK_PATH"

  alias Tariff = Matter::Cluster::CommodityTariff

  class Device < Matter::Device
    include Examples::Console

    @hook_active = false

    identity vendor: "Spider-Gazelle", product: "Crystal Tariff Provider",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: EXAMPLE_PRODUCT_ID,
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_commodity_tariff_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Tariff, as: :commodity_tariff
    end

    endpoint 2, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Tariff, feature_map: Tariff::Feature::FriendlyCredit,
        as: :friendly_credit_tariff
    end

    endpoint 3, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Tariff, feature_map: Tariff::Feature::Pricing | Tariff::Feature::PeakPeriod,
        as: :peak_period_tariff
    end

    endpoint 4, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Tariff, feature_map: Tariff::Feature::AuxiliaryLoad,
        as: :auxiliary_load_tariff
    end

    endpoint 5, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Tariff, feature_map: Tariff::Feature::Pricing | Tariff::Feature::PowerThreshold,
        as: :power_threshold_tariff
    end

    endpoint 6, device_type: Matter::DeviceType::AGGREGATOR do
      cluster Tariff, feature_map: Tariff::Feature::Pricing | Tariff::Feature::Randomization,
        as: :randomized_tariff
    end

    protected def before_start : Nil
      unless commodity_tariff.tariff_info
        info = Tariff::TariffInformation.new("Daily energy", "Crystal Utility",
          Tariff::Currency.new(36_u16, 2_u8), Tariff::BlockMode::NoBlock)
        entry = Tariff::DayEntry.new(1_u32, 0_u16)
        pattern = Tariff::DayPattern.new(1_u32, Tariff::ALL_WEEKDAYS, [1_u32])
        calendar = Tariff::CalendarPeriod.new(0_u32, [1_u32])
        component = Tariff::TariffComponent.new(1_u32,
          Tariff::TariffPrice.new(Tariff::TariffPriceType::Standard, 25_i64), nil, "Energy")
        period = Tariff::TariffPeriod.new("Daily", [1_u32], [1_u32])
        commodity_tariff.publish(Tariff::Publication.new(info, Tariff::TariffUnit::KWh,
          0_u32, [entry], [pattern], [calendar], [] of Tariff::Day,
          [component], [period]))
      end
      unless friendly_credit_tariff.tariff_info
        info = Tariff::TariffInformation.new("Friendly credit", "Crystal Utility",
          nil, Tariff::BlockMode::NoBlock)
        entries = [Tariff::DayEntry.new(1_u32, 0_u16), Tariff::DayEntry.new(2_u32, 720_u16)]
        pattern = Tariff::DayPattern.new(1_u32, Tariff::ALL_WEEKDAYS, [1_u32, 2_u32])
        calendar = Tariff::CalendarPeriod.new(0_u32, [1_u32])
        components = [
          Tariff::TariffComponent.new(1_u32, nil, nil,
            "Friendly entry", friendly_credit: true),
          Tariff::TariffComponent.new(2_u32, nil, nil,
            "Friendly exit", friendly_credit: false),
        ]
        periods = [
          Tariff::TariffPeriod.new("Friendly entry", [1_u32], [1_u32]),
          Tariff::TariffPeriod.new("Friendly exit", [2_u32], [2_u32]),
        ]
        friendly_credit_tariff.publish(Tariff::Publication.new(info, nil,
          0_u32, entries, [pattern], [calendar], [] of Tariff::Day,
          components, periods), at: 100_u32)
      end
      unless peak_period_tariff.tariff_info
        info = Tariff::TariffInformation.new("Peak periods", "Crystal Utility",
          Tariff::Currency.new(36_u16, 2_u8), Tariff::BlockMode::NoBlock)
        entries = [Tariff::DayEntry.new(1_u32, 0_u16), Tariff::DayEntry.new(2_u32, 720_u16)]
        pattern = Tariff::DayPattern.new(1_u32, Tariff::ALL_WEEKDAYS, [1_u32, 2_u32])
        calendar = Tariff::CalendarPeriod.new(0_u32, [1_u32])
        components = [
          Tariff::TariffComponent.new(1_u32, nil, nil, "Low peak",
            peak_period: Tariff::PeakPeriod.new(Tariff::PeakPeriodSeverity::Low, 1_u16)),
          Tariff::TariffComponent.new(2_u32,
            Tariff::TariffPrice.new(Tariff::TariffPriceType::Standard, 35_i64), nil,
            "High peak", peak_period: Tariff::PeakPeriod.new(Tariff::PeakPeriodSeverity::High, 2_u16)),
        ]
        periods = [
          Tariff::TariffPeriod.new("Low peak", [1_u32], [1_u32]),
          Tariff::TariffPeriod.new("High peak", [2_u32], [2_u32]),
        ]
        peak_period_tariff.publish(Tariff::Publication.new(info, Tariff::TariffUnit::KWh,
          0_u32, entries, [pattern], [calendar], [] of Tariff::Day,
          components, periods), at: 100_u32)
      end
      unless auxiliary_load_tariff.tariff_info
        info = Tariff::TariffInformation.new("Auxiliary load", "Crystal Utility",
          nil, Tariff::BlockMode::NoBlock)
        entries = [Tariff::DayEntry.new(1_u32, 0_u16), Tariff::DayEntry.new(2_u32, 720_u16)]
        pattern = Tariff::DayPattern.new(1_u32, Tariff::ALL_WEEKDAYS, [1_u32, 2_u32])
        calendar = Tariff::CalendarPeriod.new(0_u32, [1_u32])
        components = [
          Tariff::TariffComponent.new(1_u32, nil, nil, "Switch on",
            auxiliary_load: Tariff::AuxiliaryLoadSwitchSettings.new(1_u8, Tariff::AuxiliaryLoadSetting::On)),
          Tariff::TariffComponent.new(2_u32, nil, nil,
            "Switch off", auxiliary_load: Tariff::AuxiliaryLoadSwitchSettings.new(1_u8,
            Tariff::AuxiliaryLoadSetting::Off)),
        ]
        periods = [
          Tariff::TariffPeriod.new("Switch on", [1_u32], [1_u32]),
          Tariff::TariffPeriod.new("Switch off", [2_u32], [2_u32]),
        ]
        auxiliary_load_tariff.publish(Tariff::Publication.new(info, nil,
          0_u32, entries, [pattern], [calendar], [] of Tariff::Day,
          components, periods), at: 100_u32)
      end
      unless power_threshold_tariff.tariff_info
        info = Tariff::TariffInformation.new("Power thresholds", "Crystal Utility",
          Tariff::Currency.new(36_u16, 2_u8), Tariff::BlockMode::NoBlock)
        entries = [Tariff::DayEntry.new(1_u32, 0_u16), Tariff::DayEntry.new(2_u32, 720_u16)]
        pattern = Tariff::DayPattern.new(1_u32, Tariff::ALL_WEEKDAYS, [1_u32, 2_u32])
        calendar = Tariff::CalendarPeriod.new(0_u32, [1_u32])
        components = [
          Tariff::TariffComponent.new(1_u32, nil, nil, "Contract threshold",
            power_threshold: Tariff::PowerThreshold.new(power_threshold: 2_000_i64,
              power_threshold_source: Tariff::PowerThresholdSource::Contract)),
          Tariff::TariffComponent.new(2_u32,
            Tariff::TariffPrice.new(Tariff::TariffPriceType::Standard, 35_i64), nil,
            "Apparent threshold", power_threshold: Tariff::PowerThreshold.new(apparent_power_threshold: 3_000_i64)),
        ]
        periods = [
          Tariff::TariffPeriod.new("Contract threshold", [1_u32], [1_u32]),
          Tariff::TariffPeriod.new("Apparent threshold", [2_u32], [2_u32]),
        ]
        power_threshold_tariff.publish(Tariff::Publication.new(info, Tariff::TariffUnit::KWh,
          0_u32, entries, [pattern], [calendar], [] of Tariff::Day,
          components, periods), at: 100_u32)
      end
      unless randomized_tariff.tariff_info
        info = Tariff::TariffInformation.new("Randomized tariff", "Crystal Utility",
          Tariff::Currency.new(36_u16, 2_u8), Tariff::BlockMode::NoBlock)
        entries = [
          Tariff::DayEntry.new(1_u32, 0_u16, randomization_offset: 0_i16,
            randomization_type: Tariff::DayEntryRandomizationType::None),
          Tariff::DayEntry.new(2_u32, 1_u16),
        ]
        pattern = Tariff::DayPattern.new(1_u32, Tariff::ALL_WEEKDAYS, [1_u32, 2_u32])
        calendar = Tariff::CalendarPeriod.new(0_u32, [1_u32])
        components = [
          Tariff::TariffComponent.new(1_u32,
            Tariff::TariffPrice.new(Tariff::TariffPriceType::Standard, 25_i64), nil, "Before randomization"),
          Tariff::TariffComponent.new(2_u32,
            Tariff::TariffPrice.new(Tariff::TariffPriceType::Standard, 35_i64), nil, "After randomization"),
        ]
        periods = [
          Tariff::TariffPeriod.new("Before", [1_u32], [1_u32]),
          Tariff::TariffPeriod.new("After", [2_u32], [2_u32]),
        ]
        randomized_tariff.publish(Tariff::Publication.new(info, Tariff::TariffUnit::KWh,
          0_u32, entries, [pattern], [calendar], [] of Tariff::Day,
          components, periods, default_randomization_offset: 20_i16,
          default_randomization_type: Tariff::DayEntryRandomizationType::Fixed), at: 79_u32)
      end
      # The refresh hook owns the clock when present, including across device restarts.
      unless ENV[REFRESH_HOOK_ENV]?
        spawn do
          loop do
            sleep 1.second
            now = (Time.utc.to_unix - Tariff::MATTER_EPOCH_UNIX).to_u32
            commodity_tariff.refresh_at(now)
            friendly_credit_tariff.refresh_at(now)
            peak_period_tariff.refresh_at(now)
            auxiliary_load_tariff.refresh_at(now)
            power_threshold_tariff.refresh_at(now)
            randomized_tariff.refresh_at(now)
          end
        end
      end
      super
    end

    protected def on_started : Nil
      super
      if path = ENV[REFRESH_HOOK_ENV]?
        @hook_active = true
        spawn { poll_hook(path) }
      end
    end

    protected def on_shutdown : Nil
      @hook_active = false
      super
    end

    private def poll_hook(path : String) : Nil
      while @hook_active
        if File.exists?(path)
          nonce = File.read(path).strip
          File.delete(path)
          if nonce.starts_with?("refresh:")
            at = nonce.split(':')[1].to_u32
            friendly_credit_tariff.refresh_at(at)
            peak_period_tariff.refresh_at(at)
            auxiliary_load_tariff.refresh_at(at)
            power_threshold_tariff.refresh_at(at)
            randomized_tariff.refresh_at(at)
            File.write("#{path}.ack", nonce)
          end
        end
        sleep 100.milliseconds
      end
    end
  end
end

Examples.main("Crystal Tariff Provider") { MatterCommodityTariff::Device.new }
