require "./cluster"

module Matter
  module Cluster
    # Illuminance Measurement Cluster (0x0400)
    #
    # Provides an interface to illuminance measurement functionality,
    # including configuration and provision of notifications of illuminance measurements.
    #
    # Illuminance values are expressed using a logarithmic scale:
    #   MeasuredValue = 10,000 x log10(illuminance) + 1
    # where illuminance is in lux (lx).
    #
    # Special values:
    # - 0 indicates illuminance too low to measure
    # - null indicates invalid measurement
    # - Range: 1 lx to 3.576 Mlx (MeasuredValue: 1 to 0xFFFE)
    #
    # Specification: Matter 1.6 Illuminance Measurement (revision 5)
    class IlluminanceMeasurement < Base
      cluster 0x0400, revision: 5

      # Illuminance value limits
      MIN_ILLUMINANCE =     0_u16 # Too low to measure
      MAX_ILLUMINANCE = 65534_u16 # 0xFFFE

      # MinMeasuredValue must be measurable and leave room for MaxMeasuredValue
      MIN_MEASURED_VALUE_RANGE = 1_u16..(MAX_ILLUMINANCE - 1)

      # Largest tolerance the specification allows
      MAX_TOLERANCE = 2048_u16

      # Scale of the logarithmic encoding: MeasuredValue = LOG_SCALE x log10(lux) + LOG_OFFSET
      LOG_SCALE  = 10_000.0
      LOG_OFFSET =      1.0

      # Brightest illuminance the encoding can represent (lux)
      MAX_LUX = 3_576_000.0

      # Light sensor types
      enum LightSensorType : UInt8
        Photodiode = 0
        CMOS       = 1
      end

      # Value of 0 indicates too low to measure
      attribute 0x0000, :measured_value, UInt16, nullable: true, min: MIN_ILLUMINANCE, max: MAX_ILLUMINANCE
      attribute 0x0001, :min_measured_value, UInt16, nullable: true, fixed: true, min: MIN_MEASURED_VALUE_RANGE.begin, max: MIN_MEASURED_VALUE_RANGE.end
      attribute 0x0002, :max_measured_value, UInt16, nullable: true, fixed: true, max: MAX_ILLUMINANCE
      # Nil disables the optional attribute; when present, Tolerance is always a number on the wire.
      attribute 0x0003, :tolerance, UInt16, nullable: true, fixed: true, optional: true, max: MAX_TOLERANCE, present_if: :tolerance
      attribute 0x0004, :light_sensor_type, LightSensorType, nullable: true, fixed: true, optional: true, present_if: :light_sensor_type

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @measured_value : UInt16? = nil,
                     @min_measured_value : UInt16? = nil,
                     @max_measured_value : UInt16? = nil,
                     @tolerance : UInt16? = nil,
                     @light_sensor_type : LightSensorType? = nil)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))

        if min = @min_measured_value
          raise ArgumentError.new("min_measured_value must be between #{MIN_MEASURED_VALUE_RANGE.begin} and #{MIN_MEASURED_VALUE_RANGE.end}") unless MIN_MEASURED_VALUE_RANGE.includes?(min)
        end

        if max = @max_measured_value
          raise ArgumentError.new("max_measured_value must be <= #{MAX_ILLUMINANCE}") if max > MAX_ILLUMINANCE
        end

        if (min = @min_measured_value) && (max = @max_measured_value)
          raise ArgumentError.new("max_measured_value must be at least min_measured_value + 1") if max <= min
        end

        if measured = @measured_value
          raise ArgumentError.new("measured_value must be <= #{MAX_ILLUMINANCE}") if measured > MAX_ILLUMINANCE
          raise ArgumentError.new("measured_value must be >= min_measured_value") if below_minimum?(measured)
          raise ArgumentError.new("measured_value must be <= max_measured_value") if above_maximum?(measured)
        end

        if tolerance = @tolerance
          raise ArgumentError.new("tolerance must be <= #{MAX_TOLERANCE}") if tolerance > MAX_TOLERANCE
        end
      end

      # Tolerance and LightSensorType are optional: unsupported until configured.
      # Reports a new reading (nil when unknown, 0 when too low to measure);
      # `measured_value=` with a device-facing name that enforces the
      # measurable range.
      def update_illuminance(value : UInt16?) : Nil
        if value
          raise ArgumentError.new("Illuminance #{value} is above maximum #{MAX_ILLUMINANCE}") if value > MAX_ILLUMINANCE
          raise ArgumentError.new("Illuminance #{value} is below minimum measurable value #{@min_measured_value}") if below_minimum?(value)
          raise ArgumentError.new("Illuminance #{value} is above maximum measurable value #{@max_measured_value}") if above_maximum?(value)
        end
        self.measured_value = value
      end

      # Called with the previous and the new value whenever MeasuredValue changes
      def on_illuminance_changed(&block : UInt16?, UInt16? -> Nil) : Nil
        on_measured_value_changed(&block)
      end

      # 0 (too low to measure) is always valid
      private def below_minimum?(value : UInt16) : Bool
        return false if value == MIN_ILLUMINANCE
        (min = @min_measured_value) ? value < min : false
      end

      private def above_maximum?(value : UInt16) : Bool
        (max = @max_measured_value) ? value > max : false
      end

      # Helper methods for illuminance conversion

      # Convert from measured value to lux (illuminance)
      # Formula: illuminance = 10^((MeasuredValue - 1) / 10000)
      def self.to_lux(measured_value : UInt16) : Float64
        return 0.0 if measured_value == MIN_ILLUMINANCE # Too low to measure
        10.0 ** ((measured_value - LOG_OFFSET) / LOG_SCALE)
      end

      # Convert from lux (illuminance) to measured value
      # Formula: MeasuredValue = 10,000 x log10(illuminance) + 1
      # Valid range: 1 lx to 3.576 Mlx
      def self.from_lux(lux : Float64) : UInt16
        return MIN_ILLUMINANCE if lux < 1.0 # Too low to measure
        raise ArgumentError.new("Illuminance must be <= 3,576,000 lux") if lux > MAX_LUX

        (LOG_SCALE * Math.log10(lux) + LOG_OFFSET).round.to_u16.clamp(MIN_MEASURED_VALUE_RANGE.begin, MAX_ILLUMINANCE)
      end
    end
  end
end
