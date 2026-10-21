require "./cluster"

module Matter
  module Cluster
    # Wire types shared by the Matter 1.6 electrical power and energy clusters.
    module ElectricalMeasurement
      MEASUREMENT_LIMIT = 4_611_686_018_427_387_904_i64
      PERCENT_LIMIT     =                    10_000_u16

      enum MeasurementType : UInt8
        Unspecified      =  0
        Voltage          =  1
        ActiveCurrent    =  2
        ReactiveCurrent  =  3
        ApparentCurrent  =  4
        ActivePower      =  5
        ReactivePower    =  6
        ApparentPower    =  7
        RMSVoltage       =  8
        RMSCurrent       =  9
        RMSPower         = 10
        Frequency        = 11
        PowerFactor      = 12
        NeutralCurrent   = 13
        ElectricalEnergy = 14
        ReactiveEnergy   = 15
        ApparentEnergy   = 16
      end

      struct AccuracyRange
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property range_min : Int64
        @[TLV::Field(tag: 1)]
        property range_max : Int64
        @[TLV::Field(tag: 2, optional: true)]
        property percent_max : UInt16?
        @[TLV::Field(tag: 3, optional: true)]
        property percent_min : UInt16?
        @[TLV::Field(tag: 4, optional: true)]
        property percent_typical : UInt16?
        @[TLV::Field(tag: 5, optional: true)]
        property fixed_max : UInt64?
        @[TLV::Field(tag: 6, optional: true)]
        property fixed_min : UInt64?
        @[TLV::Field(tag: 7, optional: true)]
        property fixed_typical : UInt64?

        def initialize(@range_min : Int64, @range_max : Int64,
                       @percent_max : UInt16? = nil, @percent_min : UInt16? = nil,
                       @percent_typical : UInt16? = nil, @fixed_max : UInt64? = nil,
                       @fixed_min : UInt64? = nil, @fixed_typical : UInt64? = nil)
          ElectricalMeasurement.validate_range!(@range_min, @range_max)
          raise ArgumentError.new("accuracy range needs percent_max or fixed_max") unless @percent_max || @fixed_max
          raise ArgumentError.new("percent_min requires percent_max") if @percent_min && !@percent_max
          raise ArgumentError.new("percent_typical requires percent_min") if @percent_typical && !@percent_min
          raise ArgumentError.new("fixed_min requires fixed_max") if @fixed_min && !@fixed_max
          raise ArgumentError.new("fixed_typical requires fixed_min") if @fixed_typical && !@fixed_min
          [@percent_max, @percent_min, @percent_typical].each do |percent|
            raise ArgumentError.new("accuracy percent exceeds 10000") if percent && percent > PERCENT_LIMIT
          end
          if (minimum = @percent_min) && (maximum = @percent_max)
            raise ArgumentError.new("percent_min exceeds percent_max") if minimum > maximum
          end
          if (typical = @percent_typical) && (minimum = @percent_min) && (maximum = @percent_max)
            raise ArgumentError.new("percent_typical is outside percent range") unless minimum <= typical <= maximum
          end
          if maximum = @fixed_max
            raise ArgumentError.new("fixed_max exceeds Matter range") if maximum >= MEASUREMENT_LIMIT.to_u64
            if minimum = @fixed_min
              raise ArgumentError.new("fixed_min exceeds fixed_max") if minimum > maximum
              if typical = @fixed_typical
                raise ArgumentError.new("fixed_typical is outside fixed range") unless minimum <= typical <= maximum
              end
            end
          end
        end
      end

      struct Accuracy
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property measurement_type : MeasurementType
        @[TLV::Field(tag: 1)]
        property? measured : Bool
        @[TLV::Field(tag: 2)]
        property min_measured_value : Int64
        @[TLV::Field(tag: 3)]
        property max_measured_value : Int64
        @[TLV::Field(tag: 4)]
        property accuracy_ranges : Array(AccuracyRange)

        def initialize(@measurement_type : MeasurementType, @measured : Bool,
                       @min_measured_value : Int64, @max_measured_value : Int64,
                       @accuracy_ranges : Array(AccuracyRange))
          ElectricalMeasurement.validate_range!(@min_measured_value, @max_measured_value)
          raise ArgumentError.new("accuracy_ranges must not be empty") if @accuracy_ranges.empty?
          @accuracy_ranges.each do |range|
            raise ArgumentError.new("accuracy range extends beyond measured values") if range.range_min < @min_measured_value || range.range_max > @max_measured_value
          end
          @accuracy_ranges = @accuracy_ranges.dup
        end
      end

      def self.validate_range!(minimum : Int64, maximum : Int64) : Nil
        raise ArgumentError.new("measurement range is outside Matter bounds") if minimum < -MEASUREMENT_LIMIT || maximum > MEASUREMENT_LIMIT
        raise ArgumentError.new("measurement range minimum exceeds maximum") if minimum > maximum
      end
    end
  end
end
