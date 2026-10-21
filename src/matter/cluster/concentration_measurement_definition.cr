require "./cluster"

module Matter
  module Cluster
    # Matter 1.6 Concentration Measurement revision 5 shared server model.
    # Each derived cluster declares its own wire ID and mandatory medium attribute.
    module ConcentrationMeasurementDefinition
      macro included
        feature :numeric_measurement, bit: 0 # MEA - Numeric measurement
        feature :level_indication, bit: 1    # LEV - Level indication
        feature :medium_level, bit: 2        # MED - Medium level
        feature :critical_level, bit: 3      # CRI - Critical level
        feature :peak_measurement, bit: 4    # PEA - Peak measurement
        feature :average_measurement, bit: 5 # AVG - Average measurement

        # Longest peak / average window the specification allows (seconds, 7 days)
        MAX_WINDOW = 604_800_u32

        # Measurement unit values
        enum MeasurementUnit : UInt8
          Ppm  = 0 # Parts per Million (10^6)
          Ppb  = 1 # Parts per Billion (10^9)
          Ppt  = 2 # Parts per Trillion (10^12)
          Mgm3 = 3 # Milligram per m³
          Ugm3 = 4 # Microgram per m³
          Ngm3 = 5 # Nanogram per m³
          Pm3  = 6 # Particles per m³
          Bqm3 = 7 # Becquerel per m³
        end

        # Level value for coarse indication
        enum LevelValue : UInt8
          Unknown  = 0 # Level is unknown
          Low      = 1 # Level is considered Low
          Medium   = 2 # Level is considered Medium
          High     = 3 # Level is considered High
          Critical = 4 # Level is considered Critical
        end

        # Measurement medium
        enum MeasurementMedium : UInt8
          Air   = 0 # Measurement is being made in Air
          Water = 1 # Measurement is being made in Water
          Soil  = 2 # Measurement is being made in Soil
        end

        attribute 0x0000, :measured_value, Float32, nullable: true, requires: :numeric_measurement
        attribute 0x0001, :min_measured_value, Float32, nullable: true, fixed: true, requires: :numeric_measurement
        attribute 0x0002, :max_measured_value, Float32, nullable: true, fixed: true, requires: :numeric_measurement
        attribute 0x0003, :peak_measured_value, Float32, nullable: true, requires: :peak_measurement
        attribute 0x0004, :peak_measured_value_window, UInt32, default: 0_u32, max: MAX_WINDOW, requires: :peak_measurement
        attribute 0x0005, :average_measured_value, Float32, nullable: true, requires: :average_measurement
        attribute 0x0006, :average_measured_value_window, UInt32, default: 0_u32, max: MAX_WINDOW, requires: :average_measurement
        attribute 0x0007, :uncertainty, Float32, nullable: true, optional: true, fixed: true, requires: :numeric_measurement, present_if: :uncertainty
        attribute 0x0008, :measurement_unit, MeasurementUnit, default: MeasurementUnit::Ppm, fixed: true, requires: :numeric_measurement
        attribute 0x000A, :level_value, LevelValue, default: LevelValue::Unknown, requires: :level_indication

        # The FeatureMap follows the configured capabilities. Numeric readings
        # may be null; a unit enables MEA, and a window enables PEA or AVG.
        # LEV includes support for the optional Medium and Critical levels.
        def initialize(endpoint_id : DataType::EndpointNumber,
                       @measurement_medium : MeasurementMedium = MeasurementMedium::Air,
                       @measured_value : Float32? = nil,
                       @min_measured_value : Float32? = nil,
                       @max_measured_value : Float32? = nil,
                       @uncertainty : Float32? = nil,
                       measurement_unit : MeasurementUnit? = nil,
                       level_value : LevelValue? = nil,
                       @peak_measured_value : Float32? = nil,
                       peak_measured_value_window : UInt32? = nil,
                       @average_measured_value : Float32? = nil,
                       average_measured_value_window : UInt32? = nil)
          super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))

          if measurement_unit.nil? && {@measured_value, @min_measured_value, @max_measured_value, @uncertainty}.any? { |value| !value.nil? }
            raise ArgumentError.new("NumericMeasurement feature requires measurement_unit")
          end
          raise ArgumentError.new("PeakMeasurement feature requires peak_measured_value_window") if @peak_measured_value && peak_measured_value_window.nil?
          raise ArgumentError.new("AverageMeasurement feature requires average_measured_value_window") if @average_measured_value && average_measured_value_window.nil?
          if (peak_measured_value_window || average_measured_value_window) && measurement_unit.nil?
            raise ArgumentError.new("PeakMeasurement and AverageMeasurement require NumericMeasurement")
          end

          if window = peak_measured_value_window
            raise ArgumentError.new("peak_measured_value_window must be <= #{MAX_WINDOW} seconds") if window > MAX_WINDOW
            @peak_measured_value_window = window
          end
          if window = average_measured_value_window
            raise ArgumentError.new("average_measured_value_window must be <= #{MAX_WINDOW} seconds") if window > MAX_WINDOW
            @average_measured_value_window = window
          end

          unless measurement_unit || level_value
            raise ArgumentError.new("At least one feature (NumericMeasurement or LevelIndication) must be enabled")
          end

          features = Feature::None
          if measurement_unit
            @measurement_unit = measurement_unit
            features |= Feature::NumericMeasurement
          end
          if level_value
            @level_value = level_value
            features |= Feature::LevelIndication | Feature::MediumLevel | Feature::CriticalLevel
          end
          features |= Feature::PeakMeasurement unless peak_measured_value_window.nil?
          features |= Feature::AverageMeasurement unless average_measured_value_window.nil?
          @feature_map = features
          validate_measurement_bounds!
        end

        # Uncertainty is optional: unsupported until the device reports one.

        # Reports a new reading; ignored unless NumericMeasurement is enabled
        def update_measured_value(value : Float32?) : Nil
          return unless numeric_measurement_enabled?
          validate_reading!(value) if value
          self.measured_value = value
        end

        # Reports a new level; ignored unless LevelIndication is enabled
        def update_level_value(value : LevelValue) : Nil
          return unless level_indication_enabled?
          self.level_value = value
        end

        # Reports a new peak; ignored unless PeakMeasurement is enabled
        def update_peak_measured_value(value : Float32?) : Nil
          return unless peak_measurement_enabled?
          validate_reading!(value) if value
          self.peak_measured_value = value
        end

        # Reports a new average; ignored unless AverageMeasurement is enabled
        def update_average_measured_value(value : Float32?) : Nil
          return unless average_measurement_enabled?
          validate_reading!(value) if value
          self.average_measured_value = value
        end

        private def validate_measurement_bounds! : Nil
          return unless numeric_measurement_enabled?
          [@min_measured_value, @max_measured_value].each do |bound|
            raise ArgumentError.new("measurement bounds must be finite") if bound && !bound.finite?
          end
          if (minimum = @min_measured_value) && (maximum = @max_measured_value) && minimum > maximum
            raise ArgumentError.new("min_measured_value must be <= max_measured_value")
          end
          [@measured_value, @peak_measured_value, @average_measured_value].each do |reading|
            validate_reading!(reading) if reading
          end
          if (uncertainty = @uncertainty) && (!uncertainty.finite? || uncertainty < 0.0_f32)
            raise ArgumentError.new("uncertainty must be non-negative")
          end
        end

        private def validate_reading!(value : Float32) : Nil
          raise ArgumentError.new("measurement must be finite") unless value.finite?
          if (minimum = @min_measured_value) && value < minimum
            raise ArgumentError.new("measurement is below min_measured_value")
          end
          if (maximum = @max_measured_value) && value > maximum
            raise ArgumentError.new("measurement is above max_measured_value")
          end
        end

        def numeric_measurement_enabled? : Bool
          @feature_map.numeric_measurement?
        end

        def level_indication_enabled? : Bool
          @feature_map.level_indication?
        end

        def peak_measurement_enabled? : Bool
          @feature_map.peak_measurement?
        end

        def average_measurement_enabled? : Bool
          @feature_map.average_measurement?
        end
      end
    end
  end
end
