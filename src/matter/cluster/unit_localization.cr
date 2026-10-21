require "./cluster"

module Matter
  module Cluster
    # Temperature units a node can present to a user.
    class UnitLocalization < Base
      cluster 0x002D, revision: 2

      MIN_TEMPERATURE_UNITS = 2
      MAX_TEMPERATURE_UNITS = 3

      feature :temperature_unit, bit: 0

      enum TempUnit : UInt8
        Fahrenheit = 0
        Celsius    = 1
        Kelvin     = 2
      end

      attribute 0x0000, :temperature_unit, TempUnit, default: TempUnit::Celsius,
        writable: true, write_access: :manage, requires: :temperature_unit, persist: true
      attribute 0x0001, :supported_temperature_units, Array(TempUnit),
        default: [] of TempUnit, fixed: true, requires: :temperature_unit

      before_write :temperature_unit do |unit|
        InteractionModel::Status.constraint_error unless @supported_temperature_units.includes?(unit)
      end

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @feature_map : Feature = Feature::None,
                     @temperature_unit : TempUnit = TempUnit::Celsius,
                     @supported_temperature_units : Array(TempUnit) = [] of TempUnit)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        return unless @feature_map.temperature_unit?

        unless (MIN_TEMPERATURE_UNITS..MAX_TEMPERATURE_UNITS).includes?(@supported_temperature_units.size)
          raise ArgumentError.new("supported_temperature_units must contain 2 to 3 entries")
        end
        unless @supported_temperature_units.uniq.size == @supported_temperature_units.size
          raise ArgumentError.new("supported_temperature_units must not contain duplicates")
        end
        unless @supported_temperature_units.includes?(@temperature_unit)
          raise ArgumentError.new("temperature_unit must be in supported_temperature_units")
        end
        @supported_temperature_units = @supported_temperature_units.dup
      end
    end
  end
end
