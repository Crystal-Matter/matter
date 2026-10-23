require "../datatype/commodity"
require "./cluster"

module Matter
  module Cluster
    # Matter 1.6 Commodity Metering (0x0B07), revision 1. A host publishes a
    # complete reading; all four nullable attributes are null when unavailable.
    class CommodityMetering < Base
      cluster 0x0B07, revision: 1

      alias TariffUnit = DataType::TariffUnit

      MAX_TARIFF_COMPONENT_IDS = 128

      struct MeteredQuantity
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        @tariff_component_ids : Array(UInt32)

        @[TLV::Field(tag: 1)]
        getter quantity : Int64

        def initialize(tariff_component_ids : Array(UInt32), @quantity : Int64)
          raise ArgumentError.new("TariffComponentIDs exceeds 128") if tariff_component_ids.size > MAX_TARIFF_COMPONENT_IDS
          @tariff_component_ids = tariff_component_ids.dup
        end

        def tariff_component_ids : Array(UInt32)
          @tariff_component_ids.dup
        end
      end

      attribute 0x0000, :metered_quantity, Array(MeteredQuantity), nullable: true, computed: true
      attribute 0x0001, :metered_quantity_timestamp, UInt32, nullable: true, computed: true
      attribute 0x0002, :tariff_unit, TariffUnit, nullable: true, computed: true
      attribute 0x0003, :maximum_metered_quantities, UInt16, nullable: true, computed: true

      @metered_quantity : Array(MeteredQuantity)?
      @metered_quantity_timestamp : UInt32?
      @tariff_unit : TariffUnit?
      @maximum_metered_quantities : UInt16?

      def initialize(endpoint_id : DataType::EndpointNumber, *,
                     metered_quantity : Array(MeteredQuantity)? = nil,
                     @metered_quantity_timestamp : UInt32? = nil,
                     @tariff_unit : TariffUnit? = nil,
                     @maximum_metered_quantities : UInt16? = nil)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        validate_reading!(metered_quantity, @metered_quantity_timestamp,
          @tariff_unit, @maximum_metered_quantities)
        @metered_quantity = metered_quantity.try(&.dup)
      end

      def metered_quantity : Array(MeteredQuantity)?
        @metered_quantity.try(&.dup)
      end

      def metered_quantity_timestamp : UInt32?
        @metered_quantity_timestamp
      end

      def tariff_unit : TariffUnit?
        @tariff_unit
      end

      def maximum_metered_quantities : UInt16?
        @maximum_metered_quantities
      end

      # Reject the whole update before changing any attribute. A duplicate
      # reading does not advance the data version or notify subscribers.
      def publish(quantities : Array(MeteredQuantity), timestamp : UInt32,
                  unit : TariffUnit, maximum : UInt16) : Nil
        validate_reading!(quantities, timestamp, unit, maximum)
        fresh = quantities.dup
        return if @metered_quantity == fresh && @metered_quantity_timestamp == timestamp &&
                  @tariff_unit == unit && @maximum_metered_quantities == maximum

        old_quantities = @metered_quantity
        old_timestamp = @metered_quantity_timestamp
        old_unit = @tariff_unit
        old_maximum = @maximum_metered_quantities
        @metered_quantity = fresh
        @metered_quantity_timestamp = timestamp
        @tariff_unit = unit
        @maximum_metered_quantities = maximum
        increment_version_and_notify(ATTR_METERED_QUANTITY) if old_quantities != fresh
        increment_version_and_notify(ATTR_METERED_QUANTITY_TIMESTAMP) if old_timestamp != timestamp
        increment_version_and_notify(ATTR_TARIFF_UNIT) if old_unit != unit
        increment_version_and_notify(ATTR_MAXIMUM_METERED_QUANTITIES) if old_maximum != maximum
      end

      # When the meter has no valid reading, all four attributes become null.
      def clear_reading : Nil
        return if @metered_quantity.nil?
        @metered_quantity = nil
        @metered_quantity_timestamp = nil
        @tariff_unit = nil
        @maximum_metered_quantities = nil
        increment_version_and_notify(ATTR_METERED_QUANTITY)
        increment_version_and_notify(ATTR_METERED_QUANTITY_TIMESTAMP)
        increment_version_and_notify(ATTR_TARIFF_UNIT)
        increment_version_and_notify(ATTR_MAXIMUM_METERED_QUANTITIES)
      end

      private def validate_reading!(quantities : Array(MeteredQuantity)?, timestamp : UInt32?,
                                    unit : TariffUnit?, maximum : UInt16?) : Nil
        present = {!quantities.nil?, !timestamp.nil?, !unit.nil?, !maximum.nil?}
        raise ArgumentError.new("Commodity Metering requires a complete reading") unless present.none? || present.all?
        return unless quantities && maximum
        raise ArgumentError.new("MaximumMeteredQuantities must be at least one") if maximum.zero?
        raise ArgumentError.new("MeteredQuantity exceeds MaximumMeteredQuantities") if quantities.size > maximum
      end
    end
  end
end
