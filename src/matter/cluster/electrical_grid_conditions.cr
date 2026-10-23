require "./cluster"

module Matter
  module Cluster
    # Matter 1.6 Electrical Grid Conditions (0x00A0). A grid provider can
    # publish current carbon intensity and, with FORE, an ordered forecast.
    class ElectricalGridConditions < Base
      cluster 0x00A0, revision: 1

      feature :forecasting, bit: 0

      MAX_FORECAST_PERIODS = 56
      SUPPORTED_FEATURES   = Feature::Forecasting.value

      enum ThreeLevel : UInt8
        Low    = 0
        Medium = 1
        High   = 2
      end

      struct Condition
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter period_start : UInt32

        @[TLV::Field(tag: 1, optional: false)]
        getter period_end : UInt32?

        @[TLV::Field(tag: 2)]
        getter grid_carbon_intensity : Int16

        @[TLV::Field(tag: 3)]
        getter grid_carbon_level : ThreeLevel

        @[TLV::Field(tag: 4)]
        getter local_carbon_intensity : Int16

        @[TLV::Field(tag: 5)]
        getter local_carbon_level : ThreeLevel

        def initialize(@period_start : UInt32, @period_end : UInt32?,
                       @grid_carbon_intensity : Int16, @grid_carbon_level : ThreeLevel,
                       @local_carbon_intensity : Int16, @local_carbon_level : ThreeLevel)
        end
      end

      struct CurrentConditionsChangedEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0, optional: false)]
        getter current_conditions : Condition?

        def initialize(@current_conditions : Condition?)
        end
      end

      attribute 0x0000, :local_generation_available, Bool, nullable: true,
        writable: true, write_access: :operate,
        validate: :validate_local_generation_available!
      attribute 0x0001, :current_conditions, Condition, nullable: true,
        validate: :validate_current_conditions!, on_change: :report_current_conditions_change
      attribute 0x0002, :forecast_conditions, Array(Condition), default: [] of Condition,
        requires: :forecasting, copy_on_assign: true,
        validate: :validate_forecast_conditions!

      before_write :local_generation_available do |available|
        if available == false && !carbon_values_match_without_generation?
          InteractionModel::Status.constraint_error
        end
      end

      event 0x00, :current_conditions_changed, priority: :info,
        payload: CurrentConditionsChangedEvent

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @feature_map : Feature = Feature::None,
                     local_generation_available : Bool? = nil,
                     current_conditions : Condition? = nil,
                     forecast_conditions : Array(Condition) = [] of Condition)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        raise ArgumentError.new("unknown Electrical Grid Conditions feature bits") if (@feature_map.value & ~SUPPORTED_FEATURES) != 0
        if !@feature_map.forecasting? && !forecast_conditions.empty?
          raise ArgumentError.new("ForecastConditions requires FORE")
        end

        @local_generation_available = local_generation_available
        @current_conditions = current_conditions
        @forecast_conditions = forecast_conditions.dup
        validate_current_conditions!(@current_conditions)
        validate_forecast_conditions!(@forecast_conditions)
      end

      # Keep host callers from changing the advertised list without validation
      # and a data-version update.
      def forecast_conditions : Array(Condition)
        @forecast_conditions.dup
      end

      private def validate_local_generation_available!(available : Bool?) : Nil
        if available == false && !carbon_values_match_without_generation?
          raise ArgumentError.new("local carbon conditions must match grid when local generation is absent")
        end
      end

      private def validate_current_conditions!(condition : Condition?) : Nil
        validate_condition!(condition) if condition
      end

      private def validate_forecast_conditions!(conditions : Array(Condition)) : Nil
        raise ArgumentError.new("forecast requires FORE") if !@feature_map.forecasting? && !conditions.empty?
        raise ArgumentError.new("forecast exceeds 56 periods") if conditions.size > MAX_FORECAST_PERIODS

        conditions.each_with_index do |condition, index|
          validate_condition!(condition)
          next if index.zero?
          previous_end = conditions[index - 1].period_end
          if previous_end.nil? || condition.period_start <= previous_end
            raise ArgumentError.new("forecast periods must be ordered and nonoverlapping")
          end
        end
      end

      private def validate_condition!(condition : Condition) : Nil
        if (period_end = condition.period_end) && period_end <= condition.period_start
          raise ArgumentError.new("PeriodEnd must exceed PeriodStart")
        end
        if @local_generation_available == false && !carbon_values_match?(condition)
          raise ArgumentError.new("local carbon conditions must match grid when local generation is absent")
        end
      end

      private def carbon_values_match_without_generation? : Bool
        (!@current_conditions || carbon_values_match?(@current_conditions.as(Condition))) &&
          @forecast_conditions.all? { |condition| carbon_values_match?(condition) }
      end

      private def carbon_values_match?(condition : Condition) : Bool
        condition.local_carbon_intensity == condition.grid_carbon_intensity &&
          condition.local_carbon_level == condition.grid_carbon_level
      end

      private def report_current_conditions_change(value : Condition?) : Nil
        emit_current_conditions_changed(CurrentConditionsChangedEvent.new(value))
      end
    end
  end
end
