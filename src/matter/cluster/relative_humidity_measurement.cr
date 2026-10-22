require "./cluster"

module Matter
  module Cluster
    # Relative Humidity Measurement Cluster (0x0405)
    #
    # Provides an interface to water content measurement functionality.
    # The measurement is reportable and may be configured for reporting.
    #
    # Humidity values are expressed in hundredths of percent (0.01%).
    # For example, 5500 represents 55.00% relative humidity.
    #
    # Specification: Matter 1.6 § 2.6
    class RelativeHumidityMeasurement < Base
      cluster 0x0405, revision: 5

      # Humidity limits (in 0.01%)
      MIN_HUMIDITY =     0_u16 # 0.00%
      MAX_HUMIDITY = 10000_u16 # 100.00%

      # MinMeasuredValue must leave room for a larger MaxMeasuredValue
      MAX_MIN_MEASURED_VALUE = MAX_HUMIDITY - 1

      # Largest tolerance the specification allows (in 0.01%)
      MAX_TOLERANCE = 2048_u16

      # Hundredths of a percent per percent
      CENTI_PER_UNIT = 100.0

      attribute 0x0000, :measured_value, UInt16, nullable: true,
        min: MIN_HUMIDITY, max: MAX_HUMIDITY, validate: :validate_measured_value!
      attribute 0x0001, :min_measured_value, UInt16, nullable: true,
        fixed: true, min: MIN_HUMIDITY, max: MAX_MIN_MEASURED_VALUE,
        validate: :reject_fixed_attribute_change!
      attribute 0x0002, :max_measured_value, UInt16, nullable: true,
        fixed: true, max: MAX_HUMIDITY,
        validate: :reject_fixed_attribute_change!
      attribute 0x0003, :tolerance, UInt16, default: 0_u16,
        optional: true, fixed: true, max: MAX_TOLERANCE,
        present_if: :tolerance_supported?, validate: :reject_fixed_attribute_change!

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @measured_value : UInt16? = nil,
                     @min_measured_value : UInt16? = nil,
                     @max_measured_value : UInt16? = nil,
                     tolerance : UInt16? = nil)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))

        if min = @min_measured_value
          raise ArgumentError.new("min_measured_value must be <= #{MAX_MIN_MEASURED_VALUE}") if min > MAX_MIN_MEASURED_VALUE
        end
        if max = @max_measured_value
          raise ArgumentError.new("max_measured_value must be <= #{MAX_HUMIDITY}") if max > MAX_HUMIDITY
          if (min = @min_measured_value) && max <= min
            raise ArgumentError.new("min_measured_value must be < max_measured_value")
          end
        end

        if measured_value = @measured_value
          raise ArgumentError.new("measured_value must be between min and max") unless measurable?(measured_value)
        end

        @tolerance_supported = !tolerance.nil?
        @tolerance = tolerance || 0_u16
        if tolerance
          raise ArgumentError.new("tolerance must be <= #{MAX_TOLERANCE}") if tolerance > MAX_TOLERANCE
        end
      end

      def tolerance_supported? : Bool
        @tolerance_supported
      end

      # Tolerance is optional: unsupported unless configured by the device.
      # Reports a new reading (nil when unknown); `measured_value=` with a
      # device-facing name that enforces the measurable range.
      def update_humidity(value : UInt16?) : Nil
        self.measured_value = value
      end

      # Called with the previous and the new value whenever MeasuredValue changes
      def on_humidity_changed(&block : UInt16?, UInt16? -> Nil) : Nil
        on_measured_value_changed(&block)
      end

      private def measurable?(value : UInt16) : Bool
        return false if value > MAX_HUMIDITY
        return false if (min = @min_measured_value) && value < min
        return false if (max = @max_measured_value) && value > max
        true
      end

      private def validate_measured_value!(value : UInt16?) : Nil
        if value && !measurable?(value)
          raise ArgumentError.new("Humidity #{value} is outside measurable range [#{@min_measured_value}, #{@max_measured_value}]")
        end
      end

      private def reject_fixed_attribute_change!(_value) : Nil
        raise ArgumentError.new("fixed humidity attributes cannot change after construction")
      end

      # Helper methods for humidity conversion

      # Convert from 0.01% to percent (Float)
      def self.to_percent(value : UInt16) : Float64
        value / CENTI_PER_UNIT
      end

      # Convert from percent (Float) to 0.01% (UInt16)
      def self.from_percent(value : Float64) : UInt16
        raise ArgumentError.new("Humidity percent must be between 0 and 100") if value < 0.0 || value > 100.0
        (value * CENTI_PER_UNIT).round.to_u16
      end
    end
  end
end
