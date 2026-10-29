require "./electrical_measurement"

module Matter
  module Cluster
    # Matter 1.6 Electrical Power Measurement (0x0090). Values use the wire
    # units in the XML: mV, mA, mW, mVAR, mVA and mHz.
    class ElectricalPowerMeasurement < Base
      cluster 0x0090, revision: 3

      feature :direct_current, bit: 0
      feature :alternating_current, bit: 1
      feature :polyphase_power, bit: 2
      feature :harmonics, bit: 3
      feature :power_quality, bit: 4

      MAX_MEASUREMENT_TYPES = 32
      MAX_HARMONICS         = 25

      alias Accuracy = ElectricalMeasurement::Accuracy
      alias MeasurementType = ElectricalMeasurement::MeasurementType

      enum PowerMode : UInt8
        Unknown = 0
        DC      = 1
        AC      = 2
      end

      struct HarmonicMeasurement
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property order : UInt8
        @[TLV::Field(tag: 1, optional: false)]
        property measurement : Int64?

        def initialize(@order : UInt8, @measurement : Int64? = nil)
          raise ArgumentError.new("harmonic order must be positive") if @order == 0
          if value = @measurement
            ElectricalMeasurement.validate_range!(value, value)
          end
        end
      end

      struct MeasurementRange
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property measurement_type : MeasurementType
        @[TLV::Field(tag: 1)]
        property min : Int64
        @[TLV::Field(tag: 2)]
        property max : Int64
        @[TLV::Field(tag: 3, optional: true)]
        property start_timestamp : UInt32?
        @[TLV::Field(tag: 4, optional: true)]
        property end_timestamp : UInt32?
        @[TLV::Field(tag: 5, optional: true)]
        property min_timestamp : UInt32?
        @[TLV::Field(tag: 6, optional: true)]
        property max_timestamp : UInt32?
        @[TLV::Field(tag: 7, optional: true)]
        property start_systime : UInt64?
        @[TLV::Field(tag: 8, optional: true)]
        property end_systime : UInt64?
        @[TLV::Field(tag: 9, optional: true)]
        property min_systime : UInt64?
        @[TLV::Field(tag: 10, optional: true)]
        property max_systime : UInt64?

        def initialize(@measurement_type : MeasurementType, @min : Int64, @max : Int64,
                       @start_timestamp : UInt32? = nil, @end_timestamp : UInt32? = nil,
                       @min_timestamp : UInt32? = nil, @max_timestamp : UInt32? = nil,
                       @start_systime : UInt64? = nil, @end_systime : UInt64? = nil,
                       @min_systime : UInt64? = nil, @max_systime : UInt64? = nil)
          ElectricalMeasurement.validate_range!(@min, @max)
          validate_times!
        end

        private def validate_times! : Nil
          if ending = @end_timestamp
            raise ArgumentError.new("end_timestamp requires start_timestamp and min/max timestamps") unless @start_timestamp && @min_timestamp && @max_timestamp
            raise ArgumentError.new("end_timestamp must follow start_timestamp") if ending <= @start_timestamp.as(UInt32)
            raise ArgumentError.new("max_timestamp must follow min_timestamp") if @max_timestamp.as(UInt32) <= @min_timestamp.as(UInt32)
          elsif @start_timestamp || @min_timestamp || @max_timestamp
            raise ArgumentError.new("timestamp range requires end_timestamp")
          end
          if ending = @end_systime
            raise ArgumentError.new("end_systime requires start_systime and min/max systimes") unless @start_systime && @min_systime && @max_systime
            raise ArgumentError.new("end_systime must follow start_systime") if ending <= @start_systime.as(UInt64)
            raise ArgumentError.new("max_systime must follow min_systime") if @max_systime.as(UInt64) <= @min_systime.as(UInt64)
          elsif @start_systime || @min_systime || @max_systime
            raise ArgumentError.new("systime range requires end_systime")
          end
        end
      end

      struct MeasurementPeriodRangesEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property ranges : Array(MeasurementRange)

        def initialize(@ranges : Array(MeasurementRange))
        end
      end

      attribute 0x0000, :power_mode, PowerMode, default: PowerMode::Unknown
      attribute 0x0001, :number_of_measurement_types, UInt8, computed: true, fixed: true
      attribute 0x0002, :accuracy, Array(Accuracy), computed: true, fixed: true
      attribute 0x0003, :ranges, Array(MeasurementRange), default: [] of MeasurementRange, optional: true,
        validate: :validate_ranges!, copy_on_assign: true, copy_on_read: true
      attribute 0x0004, :voltage, Int64, nullable: true, optional: true
      attribute 0x0005, :active_current, Int64, nullable: true, optional: true
      attribute 0x0006, :reactive_current, Int64, nullable: true, optional: true, requires: :alternating_current
      attribute 0x0007, :apparent_current, Int64, nullable: true, optional: true, requires: :alternating_current
      attribute 0x0008, :active_power, Int64, nullable: true
      attribute 0x0009, :reactive_power, Int64, nullable: true, optional: true, requires: :alternating_current
      attribute 0x000A, :apparent_power, Int64, nullable: true, optional: true, requires: :alternating_current
      attribute 0x000B, :rms_voltage, Int64, nullable: true, optional: true, requires: :alternating_current
      attribute 0x000C, :rms_current, Int64, nullable: true, optional: true, requires: :alternating_current
      attribute 0x000D, :rms_power, Int64, nullable: true, optional: true, requires: :alternating_current
      attribute 0x000E, :frequency, Int64, nullable: true, optional: true, requires: :alternating_current
      attribute 0x000F, :harmonic_currents, Array(HarmonicMeasurement), nullable: true, requires: :harmonics
      attribute 0x0010, :harmonic_phases, Array(HarmonicMeasurement), nullable: true, requires: :power_quality
      attribute 0x0011, :power_factor, Int64, nullable: true, optional: true, requires: :alternating_current,
        min: -10_000, max: 10_000
      attribute 0x0012, :neutral_current, Int64, nullable: true, optional: true, requires: :polyphase_power

      event 0x00, :measurement_period_ranges, priority: :info, payload: MeasurementPeriodRangesEvent

      @accuracy : Array(Accuracy)

      def initialize(endpoint_id : DataType::EndpointNumber, *, @feature_map : Feature,
                     @power_mode : PowerMode, accuracy : Array(Accuracy),
                     @active_power : Int64? = nil)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        validate_features!
        raise ArgumentError.new("accuracy must contain 1..#{MAX_MEASUREMENT_TYPES} types") unless 1 <= accuracy.size <= MAX_MEASUREMENT_TYPES
        types = accuracy.map(&.measurement_type)
        raise ArgumentError.new("accuracy types must be unique") unless types.uniq.size == types.size
        raise ArgumentError.new("accuracy must include ActivePower") unless types.includes?(MeasurementType::ActivePower)
        if value = @active_power
          ElectricalMeasurement.validate_range!(value, value)
        end
        @accuracy = accuracy.dup
      end

      def number_of_measurement_types : UInt8
        @accuracy.size.to_u8
      end

      def accuracy : Array(Accuracy)
        @accuracy.dup
      end

      # The host calls this at the end of each measurement period. The event
      # carries the Ranges attribute as it stands after publishing that period.
      def complete_measurement_period(new_ranges : Array(MeasurementRange)) : Nil
        raise ArgumentError.new("completed measurement period needs at least one range") if new_ranges.empty?
        self.ranges = new_ranges
        emit_measurement_period_ranges(MeasurementPeriodRangesEvent.new(ranges))
      end

      # Compatibility API: an empty list resets Ranges without completing a
      # period. A nonempty list completes a period and emits its event.
      def update_ranges(new_ranges : Array(MeasurementRange)) : Nil
        if new_ranges.empty?
          self.ranges = new_ranges
          return
        end
        complete_measurement_period(new_ranges)
      end

      private def validate_ranges!(new_ranges : Array(MeasurementRange)) : Nil
        raise ArgumentError.new("too many measurement ranges") if new_ranges.size > @accuracy.size
        types = @accuracy.map(&.measurement_type)
        raise ArgumentError.new("range has no matching accuracy type") unless new_ranges.all? { |range| types.includes?(range.measurement_type) }
        raise ArgumentError.new("measurement range types must be unique") unless new_ranges.map(&.measurement_type).uniq!.size == new_ranges.size
      end

      private def validate_features! : Nil
        raise ArgumentError.new("DC or AC feature is required") unless @feature_map.direct_current? || @feature_map.alternating_current?
        ac_only = Feature::PolyphasePower | Feature::Harmonics | Feature::PowerQuality
        if (@feature_map & ac_only) != Feature::None && !@feature_map.alternating_current?
          raise ArgumentError.new("polyphase, harmonics and power quality require AC")
        end
        raise ArgumentError.new("DC mode requires DC feature") if @power_mode.dc? && !@feature_map.direct_current?
        raise ArgumentError.new("AC mode requires AC feature") if @power_mode.ac? && !@feature_map.alternating_current?
      end
    end
  end
end
