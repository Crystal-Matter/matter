require "tlv"

module Matter
  module DataType
    # Shared energy-tariff values used by Commodity Price, Tariff, and Metering.
    enum TariffUnit : UInt8
      KWh  = 0
      KVAh = 1
    end

    enum TariffPriceType : UInt8
      Standard        = 0
      Critical        = 1
      Virtual         = 2
      Incentive       = 3
      IncentiveSignal = 4
    end

    struct Currency
      include TLV::Serializable

      MAX_CODE = 999_u16

      @[TLV::Field(tag: 0)]
      getter currency : UInt16

      @[TLV::Field(tag: 1)]
      getter decimal_points : UInt8

      def initialize(@currency : UInt16, @decimal_points : UInt8)
        raise ArgumentError.new("currency code must be at most 999") if @currency > MAX_CODE
      end
    end
  end
end
