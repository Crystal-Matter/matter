require "./electrical_measurement"

module Matter
  module Cluster
    # Matter 1.6 Electrical Energy Measurement (0x0091). Applications supply
    # cumulative or periodic mWh readings; this cluster encodes attributes and
    # emits the required measurement events for the advertised feature set.
    class ElectricalEnergyMeasurement < Base
      cluster 0x0091, revision: 2

      feature :imported_energy, bit: 0
      feature :exported_energy, bit: 1
      feature :cumulative_energy, bit: 2
      feature :periodic_energy, bit: 3
      feature :apparent_energy, bit: 4
      feature :reactive_energy, bit: 5

      alias Accuracy = ElectricalMeasurement::Accuracy
      alias MeasurementType = ElectricalMeasurement::MeasurementType

      struct EnergyMeasurement
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property energy : Int64
        @[TLV::Field(tag: 1, optional: true)]
        property start_timestamp : UInt32?
        @[TLV::Field(tag: 2, optional: true)]
        property end_timestamp : UInt32?
        @[TLV::Field(tag: 3, optional: true)]
        property start_systime : UInt64?
        @[TLV::Field(tag: 4, optional: true)]
        property end_systime : UInt64?
        @[TLV::Field(tag: 5, optional: true)]
        property apparent_energy : Int64?
        @[TLV::Field(tag: 6, optional: true)]
        property reactive_energy : Int64?

        def initialize(@energy : Int64, @start_timestamp : UInt32? = nil,
                       @end_timestamp : UInt32? = nil, @start_systime : UInt64? = nil,
                       @end_systime : UInt64? = nil, @apparent_energy : Int64? = nil,
                       @reactive_energy : Int64? = nil)
          [@energy, @apparent_energy, @reactive_energy].each do |value|
            if value && (value < 0 || value > ElectricalMeasurement::MEASUREMENT_LIMIT)
              raise ArgumentError.new("energy is outside Matter bounds")
            end
          end
          if ending = @end_timestamp
            raise ArgumentError.new("end_timestamp requires start_timestamp") unless @start_timestamp
            raise ArgumentError.new("end_timestamp must follow start_timestamp") if ending <= @start_timestamp.as(UInt32)
          end
          if ending = @end_systime
            raise ArgumentError.new("end_systime requires start_systime") unless @start_systime
            raise ArgumentError.new("end_systime must follow start_systime") if ending <= @start_systime.as(UInt64)
          end
        end
      end

      struct CumulativeEnergyMeasuredEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0, optional: true)]
        property energy_imported : EnergyMeasurement?
        @[TLV::Field(tag: 1, optional: true)]
        property energy_exported : EnergyMeasurement?

        def initialize(@energy_imported : EnergyMeasurement? = nil,
                       @energy_exported : EnergyMeasurement? = nil)
        end
      end

      struct PeriodicEnergyMeasuredEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0, optional: true)]
        property energy_imported : EnergyMeasurement?
        @[TLV::Field(tag: 1, optional: true)]
        property energy_exported : EnergyMeasurement?

        def initialize(@energy_imported : EnergyMeasurement? = nil,
                       @energy_exported : EnergyMeasurement? = nil)
        end
      end

      attribute 0x0000, :accuracy, Accuracy, computed: true, fixed: true
      attribute 0x0001, :cumulative_energy_imported, EnergyMeasurement, nullable: true,
        requires: {imported_energy: true, cumulative_energy: true}
      attribute 0x0002, :cumulative_energy_exported, EnergyMeasurement, nullable: true,
        requires: {exported_energy: true, cumulative_energy: true}
      attribute 0x0003, :periodic_energy_imported, EnergyMeasurement, nullable: true,
        requires: {imported_energy: true, periodic_energy: true}
      attribute 0x0004, :periodic_energy_exported, EnergyMeasurement, nullable: true,
        requires: {exported_energy: true, periodic_energy: true}

      event 0x00, :cumulative_energy_measured, priority: :info,
        requires: :cumulative_energy, payload: CumulativeEnergyMeasuredEvent
      event 0x01, :periodic_energy_measured, priority: :info,
        requires: :periodic_energy, payload: PeriodicEnergyMeasuredEvent

      @accuracy : Accuracy

      def initialize(endpoint_id : DataType::EndpointNumber, *, @feature_map : Feature,
                     @accuracy : Accuracy)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        validate_features!
        raise ArgumentError.new("accuracy must describe ElectricalEnergy") unless @accuracy.measurement_type.electrical_energy?
      end

      def accuracy : Accuracy
        @accuracy
      end

      # A measurement event includes every energy direction required by this
      # instance's features. Attributes may remain null before the first report.
      def record_cumulative(*, imported : EnergyMeasurement? = nil,
                            exported : EnergyMeasurement? = nil) : Nil
        raise ArgumentError.new("CumulativeEnergy feature is required") unless @feature_map.cumulative_energy?
        validate_readings!(imported, exported)
        self.cumulative_energy_imported = imported if @feature_map.imported_energy?
        self.cumulative_energy_exported = exported if @feature_map.exported_energy?
        emit_cumulative_energy_measured(CumulativeEnergyMeasuredEvent.new(imported, exported))
      end

      def record_periodic(*, imported : EnergyMeasurement? = nil,
                          exported : EnergyMeasurement? = nil) : Nil
        raise ArgumentError.new("PeriodicEnergy feature is required") unless @feature_map.periodic_energy?
        validate_readings!(imported, exported)
        self.periodic_energy_imported = imported if @feature_map.imported_energy?
        self.periodic_energy_exported = exported if @feature_map.exported_energy?
        emit_periodic_energy_measured(PeriodicEnergyMeasuredEvent.new(imported, exported))
      end

      private def validate_features! : Nil
        unless @feature_map.imported_energy? || @feature_map.exported_energy?
          raise ArgumentError.new("ImportedEnergy or ExportedEnergy feature is required")
        end
        unless @feature_map.cumulative_energy? || @feature_map.periodic_energy?
          raise ArgumentError.new("CumulativeEnergy or PeriodicEnergy feature is required")
        end
      end

      private def validate_readings!(imported : EnergyMeasurement?, exported : EnergyMeasurement?) : Nil
        if @feature_map.imported_energy?
          raise ArgumentError.new("imported measurement is required") unless imported
        elsif imported
          raise ArgumentError.new("ImportedEnergy feature is absent")
        end
        if @feature_map.exported_energy?
          raise ArgumentError.new("exported measurement is required") unless exported
        elsif exported
          raise ArgumentError.new("ExportedEnergy feature is absent")
        end
        [imported, exported].each do |reading|
          next unless reading
          if @feature_map.apparent_energy?
            raise ArgumentError.new("apparent energy measurement is required") unless reading.apparent_energy
          elsif reading.apparent_energy
            raise ArgumentError.new("ApparentEnergy feature is absent")
          end
          if @feature_map.reactive_energy?
            raise ArgumentError.new("reactive energy measurement is required") unless reading.reactive_energy
          elsif reading.reactive_energy
            raise ArgumentError.new("ReactiveEnergy feature is absent")
          end
        end
      end
    end
  end
end
