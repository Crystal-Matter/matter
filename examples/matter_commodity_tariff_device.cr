require "./support/console"
require "./support/main"

# Synthetic daily price calendar on an Aggregator endpoint. A production
# provider publishes its own calendar and refreshes projections on clock edges.
module MatterCommodityTariff
  EXAMPLE_PRODUCT_ID = 0x0700_u16

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
      cluster Tariff, feature_map: Tariff::Feature::Pricing | Tariff::Feature::FriendlyCredit,
        as: :friendly_credit_tariff
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
          Tariff::Currency.new(36_u16, 2_u8), Tariff::BlockMode::NoBlock)
        entries = [Tariff::DayEntry.new(1_u32, 0_u16), Tariff::DayEntry.new(2_u32, 720_u16)]
        pattern = Tariff::DayPattern.new(1_u32, Tariff::ALL_WEEKDAYS, [1_u32, 2_u32])
        calendar = Tariff::CalendarPeriod.new(0_u32, [1_u32])
        components = [
          Tariff::TariffComponent.new(1_u32, nil, nil,
            "Friendly entry", friendly_credit: true),
          Tariff::TariffComponent.new(2_u32,
            Tariff::TariffPrice.new(Tariff::TariffPriceType::Standard, 25_i64), nil,
            "Friendly exit", friendly_credit: false),
        ]
        periods = [
          Tariff::TariffPeriod.new("Friendly entry", [1_u32], [1_u32]),
          Tariff::TariffPeriod.new("Friendly exit", [2_u32], [2_u32]),
        ]
        friendly_credit_tariff.publish(Tariff::Publication.new(info, Tariff::TariffUnit::KWh,
          0_u32, entries, [pattern], [calendar], [] of Tariff::Day,
          components, periods), at: 100_u32)
      end
      spawn do
        loop do
          sleep 60.seconds
          now = (Time.utc.to_unix - Tariff::MATTER_EPOCH_UNIX).to_u32
          commodity_tariff.refresh_at(now)
          friendly_credit_tariff.refresh_at(now)
        end
      end
      super
    end

    protected def on_started : Nil
      super
      if path = ENV["MATTER_COMMODITY_TARIFF_HOOK_PATH"]?
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
            friendly_credit_tariff.refresh_at(nonce.split(':')[1].to_u32)
            File.write("#{path}.ack", nonce)
          end
        end
        sleep 100.milliseconds
      end
    end
  end
end

Examples.main("Crystal Tariff Provider") { MatterCommodityTariff::Device.new }
