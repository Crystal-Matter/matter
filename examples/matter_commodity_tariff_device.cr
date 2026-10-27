require "./support/console"
require "./support/main"

# Synthetic daily price calendar on an Aggregator endpoint. A production
# provider publishes its own calendar and refreshes projections on clock edges.
module MatterCommodityTariff
  EXAMPLE_PRODUCT_ID = 0x0700_u16

  alias Tariff = Matter::Cluster::CommodityTariff

  class Device < Matter::Device
    include Examples::Console

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
      spawn do
        loop do
          sleep 60.seconds
          now = (Time.utc.to_unix - Tariff::MATTER_EPOCH_UNIX).to_u32
          commodity_tariff.refresh_at(now)
        end
      end
      super
    end
  end
end

Examples.main("Crystal Tariff Provider") { MatterCommodityTariff::Device.new }
