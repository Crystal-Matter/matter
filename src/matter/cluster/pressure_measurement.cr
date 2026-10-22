require "./cluster"

module Matter
  module Cluster
    # Pressure Measurement Cluster (0x0403)
    #
    # Provides an interface to pressure measurement functionality,
    # including configuration and provision of notifications of pressure measurements.
    #
    # Pressure values are expressed in tenths of kilopascals (0.1 kPa):
    #   MeasuredValue = 10 x Pressure [kPa]
    #
    # For example, 1013 represents 101.3 kPa (standard atmospheric pressure).
    #
    # Specification: Matter 1.6 § 2.4
    class PressureMeasurement < Base
      cluster 0x0403, revision: 5

      feature :extended, bit: 0

      # Pressure limits (in 0.1 kPa)
      # Range: Int16 covers -3276.7 kPa to +3276.6 kPa
      MIN_PRESSURE = Int16::MIN
      MAX_PRESSURE = Int16::MAX

      # MinMeasuredValue must leave room for a larger MaxMeasuredValue
      MAX_MIN_MEASURED_VALUE = MAX_PRESSURE - 1

      # Largest tolerance the specification allows (in 0.1 kPa)
      MAX_TOLERANCE = 2048_u16

      # -128 is reserved by the Scale constraint.
      MIN_SCALE = -127_i8

      # Tenths of a kilopascal per kilopascal
      DECI_PER_UNIT = 10.0

      # 1 kPa = 7.50062 mmHg
      MMHG_PER_KPA = 7.50062

      # 1 kPa = 0.2953 inHg
      INHG_PER_KPA = 0.2953

      attribute 0x0000, :measured_value, Int16, nullable: true,
        validate: :validate_measured_value!
      attribute 0x0001, :min_measured_value, Int16, nullable: true,
        fixed: true, max: MAX_MIN_MEASURED_VALUE
      attribute 0x0002, :max_measured_value, Int16, nullable: true,
        fixed: true
      attribute 0x0003, :tolerance, UInt16, default: 0_u16,
        optional: true, fixed: true, max: MAX_TOLERANCE,
        present_if: :tolerance_supported?

      attribute 0x0010, :scaled_value, Int16, nullable: true,
        requires: :extended, validate: :validate_scaled_value!
      attribute 0x0011, :min_scaled_value, Int16, nullable: true,
        fixed: true, max: MAX_MIN_MEASURED_VALUE, requires: :extended
      attribute 0x0012, :max_scaled_value, Int16, nullable: true,
        fixed: true, requires: :extended
      attribute 0x0013, :scaled_tolerance, UInt16, default: 0_u16,
        optional: true, fixed: true, max: MAX_TOLERANCE,
        requires: :extended, present_if: :scaled_tolerance_supported?
      attribute 0x0014, :scale, Int8, default: 0_i8,
        fixed: true, min: MIN_SCALE, requires: :extended

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @measured_value : Int16? = nil,
                     @min_measured_value : Int16? = nil,
                     @max_measured_value : Int16? = nil,
                     tolerance : UInt16? = nil,
                     @feature_map : Feature = Feature::None,
                     @scaled_value : Int16? = nil,
                     @min_scaled_value : Int16? = nil,
                     @max_scaled_value : Int16? = nil,
                     scaled_tolerance : UInt16? = nil,
                     @scale : Int8 = 0_i8)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))

        unless @feature_map.extended?
          if @scaled_value || @min_scaled_value || @max_scaled_value || scaled_tolerance || @scale != 0_i8
            raise ArgumentError.new("scaled attributes require the Extended feature")
          end
        end

        if min = @min_measured_value
          raise ArgumentError.new("min_measured_value must be <= #{MAX_MIN_MEASURED_VALUE}") if min > MAX_MIN_MEASURED_VALUE
        end

        if (min = @min_measured_value) && (max = @max_measured_value)
          raise ArgumentError.new("min_measured_value must be < max_measured_value") if min >= max
        end

        if measured = @measured_value
          raise ArgumentError.new("measured_value must be >= min_measured_value") if below_minimum?(measured)
          raise ArgumentError.new("measured_value must be <= max_measured_value") if above_maximum?(measured)
        end

        @tolerance_supported = !tolerance.nil?
        @tolerance = tolerance || 0_u16
        if tolerance
          raise ArgumentError.new("tolerance must be <= #{MAX_TOLERANCE}") if tolerance > MAX_TOLERANCE
        end

        if min = @min_scaled_value
          raise ArgumentError.new("min_scaled_value must be <= #{MAX_MIN_MEASURED_VALUE}") if min > MAX_MIN_MEASURED_VALUE
        end
        if (min = @min_scaled_value) && (max = @max_scaled_value)
          raise ArgumentError.new("min_scaled_value must be < max_scaled_value") if min >= max
        end
        if scaled = @scaled_value
          raise ArgumentError.new("scaled_value must be between min and max") unless scaled_measurable?(scaled)
        end
        @scaled_tolerance_supported = !scaled_tolerance.nil?
        @scaled_tolerance = scaled_tolerance || 0_u16
        if scaled_tolerance
          raise ArgumentError.new("scaled_tolerance must be <= #{MAX_TOLERANCE}") if scaled_tolerance > MAX_TOLERANCE
        end
        raise ArgumentError.new("scale must be >= #{MIN_SCALE}") if @scale < MIN_SCALE
      end

      def tolerance_supported? : Bool
        @tolerance_supported
      end

      def scaled_tolerance_supported? : Bool
        @scaled_tolerance_supported
      end

      # Tolerance is optional: unsupported until the device reports one.
      # Reports a new reading (nil when unknown); `measured_value=` with a
      # device-facing name that enforces the measurable range.
      def update_pressure(value : Int16?) : Nil
        self.measured_value = value
      end

      # Reports a reading in the units selected by Scale, or nil when unknown.
      def update_scaled_pressure(value : Int16?) : Nil
        raise ArgumentError.new("scaled attributes require the Extended feature") unless @feature_map.extended?
        self.scaled_value = value
      end

      # Called with the previous and the new value whenever MeasuredValue changes
      def on_pressure_changed(&block : Int16?, Int16? -> Nil) : Nil
        on_measured_value_changed(&block)
      end

      private def below_minimum?(value : Int16) : Bool
        (min = @min_measured_value) ? value < min : false
      end

      private def above_maximum?(value : Int16) : Bool
        (max = @max_measured_value) ? value > max : false
      end

      private def validate_measured_value!(value : Int16?) : Nil
        if value
          raise ArgumentError.new("Pressure #{value} is below minimum measurable value #{@min_measured_value}") if below_minimum?(value)
          raise ArgumentError.new("Pressure #{value} is above maximum measurable value #{@max_measured_value}") if above_maximum?(value)
        end
      end

      private def scaled_measurable?(value : Int16) : Bool
        return false if (min = @min_scaled_value) && value < min
        return false if (max = @max_scaled_value) && value > max
        true
      end

      private def validate_scaled_value!(value : Int16?) : Nil
        raise ArgumentError.new("scaled attributes require the Extended feature") unless @feature_map.extended?
        if value && !scaled_measurable?(value)
          raise ArgumentError.new("Scaled pressure #{value} is outside measurable range [#{@min_scaled_value}, #{@max_scaled_value}]")
        end
      end

      # Helper methods for pressure conversion

      # Convert from 0.1 kPa to kPa (Float)
      def self.to_kilopascals(value : Int16) : Float64
        value / DECI_PER_UNIT
      end

      # Convert from kPa (Float) to 0.1 kPa (Int16)
      def self.from_kilopascals(value : Float64) : Int16
        (value * DECI_PER_UNIT).round.to_i16
      end

      # Convert from 0.1 kPa to hPa/mbar (Float)
      # 1 kPa = 10 hPa = 10 mbar, so 0.1 kPa = 1 hPa
      def self.to_hectopascals(value : Int16) : Float64
        value.to_f
      end

      # Convert from hPa/mbar (Float) to 0.1 kPa (Int16)
      def self.from_hectopascals(value : Float64) : Int16
        value.round.to_i16
      end

      # Convert from 0.1 kPa to mmHg (Float)
      def self.to_mmhg(value : Int16) : Float64
        to_kilopascals(value) * MMHG_PER_KPA
      end

      # Convert from mmHg (Float) to 0.1 kPa (Int16)
      def self.from_mmhg(value : Float64) : Int16
        from_kilopascals(value / MMHG_PER_KPA)
      end

      # Convert from 0.1 kPa to inches of mercury (Float)
      def self.to_inhg(value : Int16) : Float64
        to_kilopascals(value) * INHG_PER_KPA
      end

      # Convert from inches of mercury (Float) to 0.1 kPa (Int16)
      def self.from_inhg(value : Float64) : Int16
        from_kilopascals(value / INHG_PER_KPA)
      end
    end
  end
end
