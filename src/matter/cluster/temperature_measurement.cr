require "./cluster"

module Matter
  module Cluster
    # Temperature Measurement Cluster (0x0402)
    #
    # Provides an interface to temperature measurement functionality,
    # including configuration and provision of notifications of temperature measurements.
    #
    # Temperature values are expressed in hundredths of degrees Celsius (0.01°C).
    # For example, 2550 represents 25.50°C.
    #
    # Specification: Matter 1.6 § 2.3
    class TemperatureMeasurement < Base
      cluster 0x0402, revision: 6

      # Temperature limits (in 0.01°C)
      MIN_TEMPERATURE = -27315_i16 # -273.15°C (absolute zero)
      MAX_TEMPERATURE =  32767_i16 # 327.67°C

      # Largest tolerance the specification allows (in 0.01°C)
      MAX_TOLERANCE = 2048_u16

      # Hundredths of a degree per degree
      CENTI_PER_UNIT = 100.0

      attribute 0x0000, :measured_value, Int16, nullable: true,
        validate: :validate_measured_value!
      attribute 0x0001, :min_measured_value, Int16, nullable: true,
        fixed: true, min: MIN_TEMPERATURE, max: MAX_TEMPERATURE - 1,
        validate: :reject_fixed_attribute_change!
      attribute 0x0002, :max_measured_value, Int16, nullable: true,
        fixed: true, validate: :reject_fixed_attribute_change!
      attribute 0x0003, :tolerance, UInt16, default: 0_u16,
        optional: true, fixed: true, max: MAX_TOLERANCE,
        present_if: :tolerance_supported?, validate: :reject_fixed_attribute_change!

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @measured_value : Int16? = nil,
                     @min_measured_value : Int16? = nil,
                     @max_measured_value : Int16? = nil,
                     tolerance : UInt16? = nil)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))

        if min = @min_measured_value
          raise ArgumentError.new("min_measured_value must be >= #{MIN_TEMPERATURE}") if min < MIN_TEMPERATURE
          raise ArgumentError.new("min_measured_value must be <= #{MAX_TEMPERATURE - 1}") if min >= MAX_TEMPERATURE
        end
        if max = @max_measured_value
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

      # Reports a new reading (nil when unknown). Both this method and direct
      # host assignments validate the bounds before changing visible state.
      def update_temperature(value : Int16?) : Nil
        self.measured_value = value
      end

      # Called with the previous and the new value whenever MeasuredValue changes
      def on_temperature_changed(&block : Int16?, Int16? -> Nil) : Nil
        on_measured_value_changed(&block)
      end

      private def reject_fixed_attribute_change!(_value) : Nil
        raise ArgumentError.new("fixed temperature attributes cannot change after construction")
      end

      private def measurable?(value : Int16) : Bool
        return false if value < MIN_TEMPERATURE
        return false if (min = @min_measured_value) && value < min
        return false if (max = @max_measured_value) && value > max
        true
      end

      private def validate_measured_value!(value : Int16?) : Nil
        if value && !measurable?(value)
          raise ArgumentError.new("Temperature #{value} is outside measurable range [#{@min_measured_value}, #{@max_measured_value}]")
        end
      end

      # Helper methods for temperature conversion

      # Convert from 0.01°C to Celsius (Float)
      def self.to_celsius(value : Int16) : Float64
        value / CENTI_PER_UNIT
      end

      # Convert from Celsius (Float) to 0.01°C (Int16)
      def self.from_celsius(value : Float64) : Int16
        (value * CENTI_PER_UNIT).round.to_i16
      end

      # Convert from 0.01°C to Fahrenheit (Float)
      def self.to_fahrenheit(value : Int16) : Float64
        to_celsius(value) * 9.0 / 5.0 + 32.0
      end

      # Convert from Fahrenheit (Float) to 0.01°C (Int16)
      def self.from_fahrenheit(value : Float64) : Int16
        from_celsius((value - 32.0) * 5.0 / 9.0)
      end
    end
  end
end
