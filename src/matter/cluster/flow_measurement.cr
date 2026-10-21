require "./cluster"

module Matter
  module Cluster
    # Liquid flow readings in the units defined by Matter Flow Measurement.
    class FlowMeasurement < Base
      cluster 0x0404, revision: 5

      MAX_MIN_MEASURED_VALUE = 65533_u16
      MAX_TOLERANCE          =  2048_u16

      attribute 0x0000, :measured_value, UInt16, nullable: true
      attribute 0x0001, :min_measured_value, UInt16,
        nullable: true, fixed: true, max: MAX_MIN_MEASURED_VALUE
      attribute 0x0002, :max_measured_value, UInt16,
        nullable: true, fixed: true
      attribute 0x0003, :tolerance, UInt16,
        nullable: true, optional: true, fixed: true,
        max: MAX_TOLERANCE, present_if: :tolerance

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @measured_value : UInt16? = nil,
                     @min_measured_value : UInt16? = nil,
                     @max_measured_value : UInt16? = nil,
                     @tolerance : UInt16? = nil)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        if (min = @min_measured_value) && min > MAX_MIN_MEASURED_VALUE
          raise ArgumentError.new("min_measured_value must be <= #{MAX_MIN_MEASURED_VALUE}")
        end
        if (min = @min_measured_value) && (max = @max_measured_value) && min >= max
          raise ArgumentError.new("max_measured_value must be greater than min_measured_value")
        end
        if measured = @measured_value
          raise ArgumentError.new("measured_value is outside measurable range") unless measurable?(measured)
        end
        if (tolerance = @tolerance) && tolerance > MAX_TOLERANCE
          raise ArgumentError.new("tolerance must be <= #{MAX_TOLERANCE}")
        end
      end

      # Reports the sensor's current reading, or nil while no reading exists.
      def update_flow(value : UInt16?) : Nil
        if value && !measurable?(value)
          raise ArgumentError.new("Flow #{value} is outside measurable range")
        end
        self.measured_value = value
      end

      private def measurable?(value : UInt16) : Bool
        if min = @min_measured_value
          return false if value < min
        end
        if max = @max_measured_value
          return false if value > max
        end
        true
      end
    end
  end
end
