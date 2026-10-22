require "./cluster"

module Matter
  module Cluster
    # Matter 1.6 Temperature Control server. A host decides whether a requested
    # setpoint can be applied to the physical appliance before the visible state
    # changes. It does not report the appliance's measured temperature.
    class TemperatureControl < Base
      cluster 0x0056, revision: 1

      feature :temperature_number, bit: 0
      feature :temperature_level, bit: 1
      feature :temperature_step, bit: 2
      conflicts :temperature_number, :temperature_level

      MIN_PHYSICAL_TEMPERATURE = -27_315_i16
      MAX_PHYSICAL_TEMPERATURE =  32_767_i16
      MAX_TEMPERATURE_LEVELS   =          32
      MAX_LEVEL_LABEL_BYTES    =          16

      struct SetTemperatureRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0, optional: true)]
        property target_temperature : Int16?

        @[TLV::Field(tag: 1, optional: true)]
        property target_temperature_level : UInt8?

        def initialize(@target_temperature : Int16? = nil,
                       @target_temperature_level : UInt8? = nil)
        end
      end

      attribute 0x0000, :temperature_setpoint, Int16,
        default: 2000_i16, persist: true, requires: :temperature_number
      attribute 0x0001, :min_temperature, Int16,
        default: 1500_i16, fixed: true, requires: :temperature_number
      attribute 0x0002, :max_temperature, Int16,
        default: 3500_i16, fixed: true, requires: :temperature_number
      attribute 0x0003, :step, Int16, nullable: true,
        fixed: true, requires: :temperature_step
      attribute 0x0004, :selected_temperature_level, UInt8,
        default: 0_u8, persist: true, requires: :temperature_level, max: 31
      attribute 0x0005, :supported_temperature_levels, Array(String),
        default: [] of String, fixed: true, requires: :temperature_level

      command 0x00, :set_temperature, request: SetTemperatureRequest,
        access: :operate, handler: :handle_set_temperature

      @set_temperature_callback : Proc(Int16?, UInt8?, InteractionModel::Status)?

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @feature_map : Feature = Feature::TemperatureNumber,
                     @temperature_setpoint : Int16 = 2000_i16,
                     @min_temperature : Int16 = 1500_i16,
                     @max_temperature : Int16 = 3500_i16,
                     @step : Int16? = nil,
                     @selected_temperature_level : UInt8 = 0_u8,
                     @supported_temperature_levels : Array(String) = [] of String)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        unless @feature_map.temperature_number? || @feature_map.temperature_level?
          raise ArgumentError.new("Temperature Control requires TemperatureNumber or TemperatureLevel")
        end
        if @feature_map.temperature_step? && !@feature_map.temperature_number?
          raise ArgumentError.new("TemperatureStep requires TemperatureNumber")
        end
        if @feature_map.temperature_number?
          validate_number_configuration!
          raise ArgumentError.new("numeric temperature control cannot advertise level labels") unless @supported_temperature_levels.empty?
        else
          raise ArgumentError.new("TemperatureStep is absent in level mode") if @step
          validate_level_configuration!
        end
        @supported_temperature_levels = @supported_temperature_levels.dup
      end

      # Called with the numeric target or level index, with the other argument
      # nil. Returning Success means the appliance accepted the new setting.
      # Other statuses leave cluster state untouched; a missing host refuses it.
      def on_set_temperature(&block : Int16?, UInt8? -> InteractionModel::Status) : Nil
        @set_temperature_callback = block
      end

      def handle_set_temperature(request : SetTemperatureRequest) : InteractionModel::Status
        if @feature_map.temperature_number?
          return InteractionModel::Status.invalid_command if request.target_temperature_level
          target = request.target_temperature
          return InteractionModel::Status.invalid_command unless target
          return InteractionModel::Status.constraint_error unless valid_temperature?(target)
          return InteractionModel::Status.invalid_in_state unless callback = @set_temperature_callback
          status = callback.call(target, nil)
          self.temperature_setpoint = target if status.success?
          status
        else
          return InteractionModel::Status.invalid_command if request.target_temperature
          target = request.target_temperature_level
          return InteractionModel::Status.invalid_command unless target
          return InteractionModel::Status.constraint_error unless valid_level?(target)
          return InteractionModel::Status.invalid_in_state unless callback = @set_temperature_callback
          status = callback.call(nil, target)
          self.selected_temperature_level = target if status.success?
          status
        end
      end

      # The host can also report a change made through a local physical control.
      def update_temperature_setpoint(target : Int16) : InteractionModel::Status
        return InteractionModel::Status.invalid_in_state unless @feature_map.temperature_number?
        return InteractionModel::Status.constraint_error unless valid_temperature?(target)
        self.temperature_setpoint = target
        InteractionModel::Status.success
      end

      def update_selected_temperature_level(target : UInt8) : InteractionModel::Status
        return InteractionModel::Status.invalid_in_state unless @feature_map.temperature_level?
        return InteractionModel::Status.constraint_error unless valid_level?(target)
        self.selected_temperature_level = target
        InteractionModel::Status.success
      end

      private def valid_temperature?(target : Int16) : Bool
        return false unless (@min_temperature..@max_temperature).includes?(target)
        return true unless @feature_map.temperature_step?
        ((target.to_i32 - @min_temperature.to_i32) % @step.as(Int16).to_i32).zero?
      end

      private def valid_level?(target : UInt8) : Bool
        target < @supported_temperature_levels.size
      end

      private def validate_number_configuration! : Nil
        unless @min_temperature >= MIN_PHYSICAL_TEMPERATURE &&
               @max_temperature <= MAX_PHYSICAL_TEMPERATURE &&
               @max_temperature > @min_temperature
          raise ArgumentError.new("numeric temperature range is invalid")
        end
        if @feature_map.temperature_step?
          step = @step || raise ArgumentError.new("TemperatureStep requires a step value")
          if step <= 0 || step.to_i32 > @max_temperature.to_i32 - @min_temperature.to_i32 ||
             (@max_temperature.to_i32 - @min_temperature.to_i32) % step.to_i32 != 0
            raise ArgumentError.new("step must divide the temperature range")
          end
        elsif @step
          raise ArgumentError.new("step requires TemperatureStep feature")
        end
        unless valid_temperature?(@temperature_setpoint)
          raise ArgumentError.new("temperature setpoint is outside the supported grid")
        end
      end

      private def validate_level_configuration! : Nil
        levels = @supported_temperature_levels
        if levels.empty? || levels.size > MAX_TEMPERATURE_LEVELS || levels.uniq.size != levels.size
          raise ArgumentError.new("temperature level labels must contain 1 to 32 unique entries")
        end
        if levels.any? { |label| label.empty? || label.bytesize > MAX_LEVEL_LABEL_BYTES }
          raise ArgumentError.new("temperature level label must contain 1 to 16 bytes")
        end
        unless valid_level?(@selected_temperature_level)
          raise ArgumentError.new("selected temperature level is not advertised")
        end
      end

      private def after_restore_state : Nil
        if @feature_map.temperature_number?
          self.temperature_setpoint = @min_temperature unless valid_temperature?(@temperature_setpoint)
        elsif !valid_level?(@selected_temperature_level)
          self.selected_temperature_level = 0_u8
        end
      end
    end
  end
end
