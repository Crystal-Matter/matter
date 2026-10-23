require "../spec_helper"

private alias Commodity = Matter::Cluster::CommodityPrice
private alias CommodityStatus = Matter::InteractionModel::StatusCode

private def price_period(start : UInt32, finish : UInt32? = nil, price : Int64? = 100_i64,
                         level : Int16? = nil, components : Array(Commodity::Component) = [] of Commodity::Component) : Commodity::Period
  Commodity::Period.new(start, finish, price, level, nil, components)
end

describe Commodity do
  it "exposes revision 4, nullable mandatory attributes, and FORE gating" do
    basic = build(Commodity, tariff_unit: Commodity::TariffUnit::KWh)
    basic.cluster_id.id.should eq(0x0095_u32)
    basic.cluster_revision.should eq(4_u16)
    read(basic, Commodity::ATTR_CURRENCY).should be_nil
    read(basic, Commodity::ATTR_CURRENT_PRICE).should be_nil
    read_status(basic, Commodity::ATTR_PRICE_FORECAST).status.should eq(CommodityStatus::UnsupportedAttribute)
    forecast = build(Commodity, tariff_unit: Commodity::TariffUnit::KWh,
      feature_map: Commodity::Feature::Forecasting)
    read_tlv(forecast, Commodity::ATTR_PRICE_FORECAST).as_list.should be_empty
  end

  it "encodes global currency and typed price components with standard tags" do
    currency = Commodity::Currency.new(840_u16, 2_u8)
    currency.to_tlv(nil).as_structure.keys.should eq([0_u8, 1_u8])
    component = Commodity::Component.new(40_i64, Commodity::TariffPriceType::Standard, "Generation", 7_u32)
    component.to_tlv(nil).as_structure.keys.should eq([0_u8, 1_u8, 2_u8, 3_u8])
    period = Commodity::Period.new(100_u32, 200_u32, 100_i64, nil, "Flat", [component])
    period.to_tlv(nil).as_structure.keys.should eq([0_u8, 1_u8, 2_u8, 4_u8, 5_u8])
    Commodity::Period.from_tlv(period.to_tlv(nil)).period_end.should eq(200_u32)
    level_only = Commodity::Period.new(100_u32, nil, nil, 3_i16)
    level_only.to_tlv(nil).as_structure.keys.should eq([0_u8, 1_u8, 3_u8])
    Commodity::Period.from_tlv(level_only.to_tlv(nil)).components.should be_empty
  end

  it "validates price choice, interval, description, component sum, and forecast order" do
    expect_raises(ArgumentError) { Commodity::Currency.new(1000_u16, 2_u8) }
    expect_raises(ArgumentError) { build(Commodity, tariff_unit: Commodity::TariffUnit::KWh, current_price: price_period(100_u32, 200_u32, nil)) }
    expect_raises(ArgumentError) { build(Commodity, tariff_unit: Commodity::TariffUnit::KWh, current_price: price_period(100_u32, 100_u32)) }
    expect_raises(ArgumentError) do
      build(Commodity, tariff_unit: Commodity::TariffUnit::KWh,
        current_price: Commodity::Period.new(100_u32, nil, 100_i64, nil, "x" * 33))
    end
    component = Commodity::Component.new(40_i64, Commodity::TariffPriceType::Standard)
    expect_raises(ArgumentError) do
      build(Commodity, tariff_unit: Commodity::TariffUnit::KWh,
        current_price: price_period(100_u32, 200_u32, components: [component]))
    end
    expect_raises(ArgumentError) do
      build(Commodity, tariff_unit: Commodity::TariffUnit::KWh,
        feature_map: Commodity::Feature::Forecasting,
        price_forecast: [price_period(100_u32, 200_u32), price_period(199_u32, 300_u32)])
    end
    contiguous = build(Commodity, tariff_unit: Commodity::TariffUnit::KWh,
      feature_map: Commodity::Feature::Forecasting,
      price_forecast: [price_period(100_u32, 200_u32), price_period(200_u32, 300_u32)])
    contiguous.price_forecast.size.should eq(2)
    expect_raises(ArgumentError) do
      build(Commodity, tariff_unit: Commodity::TariffUnit::KWh,
        feature_map: Commodity::Feature::Forecasting,
        price_forecast: Array.new(57) { |index| price_period((index * 2).to_u32, (index * 2 + 1).to_u32) })
    end
  end

  it "isolates nested component and forecast arrays from host mutation" do
    component = Commodity::Component.new(100_i64, Commodity::TariffPriceType::Standard)
    source = [component]
    period = Commodity::Period.new(100_u32, 200_u32, 100_i64, nil, nil, source)
    source.clear
    period.components.size.should eq(1)
    period.components.clear
    period.components.size.should eq(1)

    forecast = [period]
    cluster = build(Commodity, tariff_unit: Commodity::TariffUnit::KWh,
      feature_map: Commodity::Feature::Forecasting, current_price: period,
      price_forecast: forecast)
    forecast.clear
    cluster.price_forecast.size.should eq(1)
    cluster.price_forecast.clear
    cluster.price_forecast.size.should eq(1)
    cluster.current_price.as(Commodity::Period).components.clear
    cluster.current_price.as(Commodity::Period).components.size.should eq(1)
  end

  it "filters detailed responses and gates forecast commands" do
    component = Commodity::Component.new(100_i64, Commodity::TariffPriceType::Standard, "Generation")
    period = Commodity::Period.new(100_u32, nil, 100_i64, nil, "Plan", [component])
    basic = build(Commodity, tariff_unit: Commodity::TariffUnit::KWh, current_price: period)
    basic.get_detailed_price(Commodity::GetDetailedPriceRequest.new(0_u8)).current_price.as(Commodity::Period).description.should be_nil
    detailed = basic.get_detailed_price(Commodity::GetDetailedPriceRequest.new(3_u8)).current_price.as(Commodity::Period)
    detailed.description.should eq("Plan")
    detailed.components.size.should eq(1)
    expect_raises(ArgumentError) { basic.get_detailed_price(Commodity::GetDetailedPriceRequest.new(4_u8)) }
    accepted_command_ids(basic).should contain(Commodity::CMD_GET_DETAILED_PRICE)
    accepted_command_ids(basic).should_not contain(Commodity::CMD_GET_DETAILED_FORECAST)
    expect_raises(ArgumentError) { basic.get_detailed_forecast(Commodity::GetDetailedForecastRequest.new(0_u8)) }

    forecast = build(Commodity, tariff_unit: Commodity::TariffUnit::KWh,
      feature_map: Commodity::Feature::Forecasting, price_forecast: [period])
    forecast.get_detailed_forecast(Commodity::GetDetailedForecastRequest.new(2_u8)).price_forecast.first.components.size.should eq(1)
  end

  it "emits PriceChange on current price changes" do
    cluster = build(Commodity, tariff_unit: Commodity::TariffUnit::KWh)
    events = [] of TLV::Any
    cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, event : UInt32, _priority : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) do
      event.should eq(Commodity::EVENT_PRICE_CHANGE)
      events << data
      nil
    end
    period = price_period(100_u32, 200_u32)
    cluster.current_price = period
    cluster.current_price = period
    cluster.current_price = nil
    events.size.should eq(2)
    Commodity::PriceChangeEvent.from_tlv(events.first).current_price.should eq(period)
    Commodity::PriceChangeEvent.from_tlv(events.last).current_price.should be_nil
  end
end
