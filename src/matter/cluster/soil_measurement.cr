require "./electrical_measurement"

module Matter
  module Cluster
    # Matter 1.6 Soil Measurement (0x0430), with percentage readings and a
    # fixed MeasurementAccuracyStruct describing the sensor's measurable range.
    class SoilMeasurement < Base
      cluster 0x0430, revision: 1

      alias Accuracy = ElectricalMeasurement::Accuracy
      alias AccuracyRange = ElectricalMeasurement::AccuracyRange
      alias MeasurementType = ElectricalMeasurement::MeasurementType

      MIN_SOIL_MOISTURE =    0_i64
      MAX_SOIL_MOISTURE =  100_i64
      MAX_MINIMUM       =   99_i64
      MAX_PERCENT_ERROR = 1000_u16 # 10.00 percent, in hundredths of a percent

      attribute 0x0000, :soil_moisture_measurement_limits, Accuracy,
        computed: true, fixed: true
      attribute 0x0001, :soil_moisture_measured_value, UInt8,
        nullable: true, validate: :validate_soil_moisture!

      def initialize(endpoint_id : DataType::EndpointNumber, *, accuracy : Accuracy,
                     measured_value : UInt8? = nil)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        validate_accuracy!(accuracy)
        @minimum = accuracy.min_measured_value
        @maximum = accuracy.max_measured_value
        @percent_max = accuracy.accuracy_ranges.first.percent_max.as(UInt16)
        @soil_moisture_measured_value = measured_value
        validate_soil_moisture!(@soil_moisture_measured_value)
      end

      # Return a fresh structure so a caller cannot mutate the fixed limits by
      # appending to the nested AccuracyRanges array.
      def soil_moisture_measurement_limits : Accuracy
        range = AccuracyRange.new(@minimum, @maximum, percent_max: @percent_max)
        Accuracy.new(MeasurementType::SoilMoisture, true, @minimum, @maximum, [range])
      end

      # Publishes a sensor sample, or nil while the sensor has no reading.
      def update_soil_moisture(value : UInt8?) : Nil
        self.soil_moisture_measured_value = value
      end

      private def validate_accuracy!(accuracy : Accuracy) : Nil
        unless accuracy.measurement_type == MeasurementType::SoilMoisture && accuracy.measured?
          raise ArgumentError.new("soil accuracy must describe measured SoilMoisture")
        end
        minimum = accuracy.min_measured_value
        maximum = accuracy.max_measured_value
        unless MIN_SOIL_MOISTURE <= minimum <= MAX_MINIMUM && minimum < maximum <= MAX_SOIL_MOISTURE
          raise ArgumentError.new("soil accuracy limits must satisfy 0 <= min < max <= 100")
        end
        unless accuracy.accuracy_ranges.size == 1
          raise ArgumentError.new("soil accuracy requires one full-span range")
        end
        range = accuracy.accuracy_ranges.first
        unless range.range_min == minimum && range.range_max == maximum
          raise ArgumentError.new("soil accuracy range must cover the full measurable range")
        end
        percent_max = range.percent_max
        unless percent_max && percent_max <= MAX_PERCENT_ERROR &&
               range.percent_min.nil? && range.percent_typical.nil? &&
               range.fixed_max.nil? && range.fixed_min.nil? && range.fixed_typical.nil?
          raise ArgumentError.new("soil accuracy requires only PercentMax <= 10.00 percent")
        end
      end

      private def validate_soil_moisture!(value : UInt8?) : Nil
        return unless value
        unless @minimum <= value <= @maximum
          raise ArgumentError.new("soil moisture #{value} is outside measurable range [#{@minimum}, #{@maximum}]")
        end
      end
    end
  end
end
