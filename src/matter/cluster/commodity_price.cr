require "../datatype/commodity"
require "./cluster"

module Matter
  module Cluster
    # Matter 1.6 Commodity Price (0x0095), revision 4.
    class CommodityPrice < Base
      cluster 0x0095, revision: 4

      feature :forecasting, bit: 0

      alias Currency = DataType::Currency
      alias TariffUnit = DataType::TariffUnit
      alias TariffPriceType = DataType::TariffPriceType

      MAX_FORECAST_PERIODS =      56
      MAX_COMPONENTS       =      10
      MAX_DESCRIPTION_SIZE =      32
      DETAIL_DESCRIPTION   = 0x01_u8
      DETAIL_COMPONENTS    = 0x02_u8
      DETAIL_MASK          = DETAIL_DESCRIPTION | DETAIL_COMPONENTS
      SUPPORTED_FEATURES   = Feature::Forecasting.value

      struct Component
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter price : Int64

        @[TLV::Field(tag: 1)]
        getter source : TariffPriceType

        @[TLV::Field(tag: 2, optional: true)]
        getter description : String?

        @[TLV::Field(tag: 3, optional: true)]
        getter tariff_component_id : UInt32?

        def initialize(@price : Int64, @source : TariffPriceType,
                       @description : String? = nil, @tariff_component_id : UInt32? = nil)
        end
      end

      struct Period
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter period_start : UInt32

        @[TLV::Field(tag: 1, optional: false)]
        getter period_end : UInt32?

        @[TLV::Field(tag: 2, optional: true)]
        getter price : Int64?

        @[TLV::Field(tag: 3, optional: true)]
        getter price_level : Int16?

        @[TLV::Field(tag: 4, optional: true)]
        getter description : String?

        @[TLV::Field(tag: 5)]
        getter components : Array(Component)

        def initialize(@period_start : UInt32, @period_end : UInt32?,
                       @price : Int64? = nil, @price_level : Int16? = nil,
                       @description : String? = nil,
                       components : Array(Component) = [] of Component)
          @components = components.dup
        end

        def components : Array(Component)
          @components.dup
        end
      end

      struct GetDetailedPriceRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter details : UInt8

        def initialize(@details : UInt8)
        end
      end

      struct GetDetailedPriceResponse
        include TLV::Serializable

        @[TLV::Field(tag: 0, optional: false)]
        getter current_price : Period?

        def initialize(@current_price : Period?)
        end
      end

      struct GetDetailedForecastRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter details : UInt8

        def initialize(@details : UInt8)
        end
      end

      struct GetDetailedForecastResponse
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter price_forecast : Array(Period)

        def initialize(@price_forecast : Array(Period))
        end
      end

      struct PriceChangeEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0, optional: false)]
        getter current_price : Period?

        def initialize(@current_price : Period?)
        end
      end

      attribute 0x0000, :tariff_unit, TariffUnit, default: TariffUnit::KWh
      attribute 0x0001, :currency, Currency, nullable: true,
        validate: :validate_currency!
      attribute 0x0002, :current_price, Period, nullable: true,
        validate: :validate_current_price!, on_change: :report_price_change
      attribute 0x0003, :price_forecast, Array(Period), default: [] of Period,
        requires: :forecasting, copy_on_assign: true,
        validate: :validate_price_forecast!

      command 0x00, :get_detailed_price, request: GetDetailedPriceRequest,
        response: GetDetailedPriceResponse, response_id: 0x01, access: :operate
      command 0x02, :get_detailed_forecast, request: GetDetailedForecastRequest,
        response: GetDetailedForecastResponse, response_id: 0x03,
        access: :operate, requires: :forecasting

      event 0x00, :price_change, priority: :info, payload: PriceChangeEvent

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @tariff_unit : TariffUnit,
                     @feature_map : Feature = Feature::None,
                     @currency : Currency? = nil,
                     @current_price : Period? = nil,
                     @price_forecast : Array(Period) = [] of Period)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        raise ArgumentError.new("unknown Commodity Price feature bits") if (@feature_map.value & ~SUPPORTED_FEATURES) != 0
        raise ArgumentError.new("PriceForecast requires FORE") if !@feature_map.forecasting? && !@price_forecast.empty?
        validate_currency!(@currency)
        validate_current_price!(@current_price)
        validate_price_forecast!(@price_forecast)
        @price_forecast = copy_periods(@price_forecast)
      end

      def price_forecast : Array(Period)
        copy_periods(@price_forecast)
      end

      def get_detailed_price(request : GetDetailedPriceRequest) : GetDetailedPriceResponse
        validate_details!(request.details)
        GetDetailedPriceResponse.new(@current_price.try { |period| detail_period(period, request.details) })
      end

      def get_detailed_forecast(request : GetDetailedForecastRequest) : GetDetailedForecastResponse
        raise ArgumentError.new("GetDetailedForecast requires FORE") unless @feature_map.forecasting?
        validate_details!(request.details)
        GetDetailedForecastResponse.new(@price_forecast.map { |period| detail_period(period, request.details) })
      end

      private def validate_currency!(currency : Currency?) : Nil
        if currency && currency.currency > Currency::MAX_CODE
          raise ArgumentError.new("currency code must be at most 999")
        end
      end

      private def validate_current_price!(period : Period?) : Nil
        validate_period!(period) if period
      end

      private def validate_price_forecast!(periods : Array(Period)) : Nil
        raise ArgumentError.new("PriceForecast requires FORE") if !@feature_map.forecasting? && !periods.empty?
        raise ArgumentError.new("PriceForecast exceeds 56 periods") if periods.size > MAX_FORECAST_PERIODS
        periods.each_with_index do |period, index|
          validate_period!(period)
          next if index.zero?
          previous_end = periods[index - 1].period_end
          if previous_end.nil? || period.period_start < previous_end
            raise ArgumentError.new("PriceForecast periods must be ordered and nonoverlapping")
          end
        end
      end

      private def validate_period!(period : Period) : Nil
        if (period_end = period.period_end) && period_end <= period.period_start
          raise ArgumentError.new("PeriodEnd must exceed PeriodStart")
        end
        if period.price.nil? && period.price_level.nil?
          raise ArgumentError.new("CommodityPrice requires Price or PriceLevel")
        end
        validate_description!(period.description)
        raise ArgumentError.new("CommodityPrice has too many components") if period.components.size > MAX_COMPONENTS
        if !period.components.empty? && period.price.nil?
          raise ArgumentError.new("Components require Price")
        end
        period.components.each { |component| validate_description!(component.description) }
        if !period.components.empty? && period.components.sum(&.price) != period.price
          raise ArgumentError.new("Components must sum to Price")
        end
      end

      private def validate_description!(description : String?) : Nil
        if description && description.bytesize > MAX_DESCRIPTION_SIZE
          raise ArgumentError.new("Commodity Price description exceeds 32 bytes")
        end
      end

      private def validate_details!(details : UInt8) : Nil
        raise ArgumentError.new("unknown Commodity Price detail bits") if (details & ~DETAIL_MASK) != 0
      end

      private def detail_period(period : Period, details : UInt8) : Period
        Period.new(period.period_start, period.period_end, period.price, period.price_level,
          (details & DETAIL_DESCRIPTION) != 0 ? period.description : nil,
          (details & DETAIL_COMPONENTS) != 0 ? period.components.dup : [] of Component)
      end

      private def copy_periods(periods : Array(Period)) : Array(Period)
        periods.map do |period|
          Period.new(period.period_start, period.period_end, period.price, period.price_level,
            period.description, period.components.dup)
        end
      end

      private def report_price_change(period : Period?) : Nil
        emit_price_change(PriceChangeEvent.new(period))
      end
    end
  end
end
