require "./microwave_oven_mode"

module Matter
  module Cluster
    # Matter 1.6 Microwave Oven Control (0x005F). The host applies physical
    # settings, then the cluster publishes the accepted settings and mode.
    class MicrowaveOvenControl < Base
      cluster 0x005F, revision: 1

      feature :power_as_number, bit: 0
      feature :power_number_limits, bit: 2

      MIN_COOK_TIME      =      1_u32
      MAX_COOK_TIME      = 86_400_u32
      DEFAULT_COOK_TIME  =     30_u32
      DEFAULT_MIN_POWER  =      10_u8
      DEFAULT_MAX_POWER  =     100_u8
      DEFAULT_POWER_STEP =      10_u8
      SUPPORTED_FEATURES = Feature::PowerAsNumber.value | Feature::PowerNumberLimits.value

      struct SetCookingParametersRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0, optional: true)]
        property cook_mode : UInt8?

        @[TLV::Field(tag: 1, optional: true)]
        property cook_time : UInt32?

        @[TLV::Field(tag: 2, optional: true)]
        property power_setting : UInt8?

        @[TLV::Field(tag: 3, optional: true)]
        property watt_setting_index : UInt8?

        @[TLV::Field(tag: 4, optional: true)]
        property start_after_setting : Bool?

        def initialize(@cook_mode : UInt8? = nil, @cook_time : UInt32? = nil,
                       @power_setting : UInt8? = nil, @watt_setting_index : UInt8? = nil,
                       @start_after_setting : Bool? = nil)
        end
      end

      struct AddMoreTimeRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property time_to_add : UInt32

        def initialize(@time_to_add : UInt32)
        end
      end

      attribute 0x0000, :cook_time, UInt32, default: DEFAULT_COOK_TIME,
        persist: true, validate: :validate_cook_time!
      attribute 0x0001, :max_cook_time, UInt32, default: MAX_COOK_TIME,
        fixed: true, validate: :reject_fixed_max_cook_time!
      attribute 0x0002, :power_setting, UInt8, default: DEFAULT_MAX_POWER,
        persist: true, requires: :power_as_number, validate: :validate_power_setting!
      attribute 0x0003, :min_power, UInt8, default: DEFAULT_MIN_POWER,
        fixed: true, requires: :power_number_limits, validate: :reject_fixed_power_limit!
      attribute 0x0004, :max_power, UInt8, default: DEFAULT_MAX_POWER,
        fixed: true, requires: :power_number_limits, validate: :reject_fixed_power_limit!
      attribute 0x0005, :power_step, UInt8, default: DEFAULT_POWER_STEP,
        fixed: true, requires: :power_number_limits, validate: :reject_fixed_power_limit!

      command 0x00, :set_cooking_parameters, request: SetCookingParametersRequest,
        access: :operate, handler: :handle_set_cooking_parameters
      command 0x01, :add_more_time, request: AddMoreTimeRequest,
        access: :operate, handler: :handle_add_more_time,
        optional: true, present_if: :add_more_time_supported?

      @mode_cluster : MicrowaveOvenMode
      @normal_mode : UInt8
      @add_more_time_supported : Bool
      @on_set_cooking_parameters : Proc(UInt8, UInt32, UInt8, Bool, InteractionModel::Status)? = nil
      @on_add_more_time : Proc(UInt32, InteractionModel::Status)? = nil

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @mode_cluster : MicrowaveOvenMode,
                     @max_cook_time : UInt32,
                     @feature_map : Feature = Feature::PowerAsNumber,
                     min_power : UInt8? = nil, max_power : UInt8? = nil,
                     power_step : UInt8? = nil,
                     add_more_time : Bool = false,
                     cook_time : UInt32? = nil,
                     power_setting : UInt8? = nil)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        @add_more_time_supported = add_more_time
        raise ArgumentError.new("Microwave Oven Mode must share this endpoint") unless @mode_cluster.endpoint_id == endpoint_id
        normal = @mode_cluster.supported_modes.find do |option|
          option.mode_tags.any? { |tag| tag.mfg_code.nil? && tag.value == MicrowaveOvenMode::ModeTag::Normal.value }
        end
        @normal_mode = normal.try(&.mode) || raise ArgumentError.new("Microwave Oven Mode requires a Normal mode")
        unless @feature_map.power_as_number?
          raise ArgumentError.new("Microwave Oven Control requires PowerAsNumber")
        end
        unless (@feature_map.value & ~SUPPORTED_FEATURES).zero?
          raise ArgumentError.new("Microwave Oven Control has unsupported features")
        end
        unless (MIN_COOK_TIME..MAX_COOK_TIME).includes?(@max_cook_time)
          raise ArgumentError.new("MaxCookTime is outside the Matter 1.6 range")
        end

        has_limits = @feature_map.power_number_limits?
        if has_limits
          @min_power = min_power || raise ArgumentError.new("PowerNumberLimits requires MinPower")
          @max_power = max_power || raise ArgumentError.new("PowerNumberLimits requires MaxPower")
          @power_step = power_step || raise ArgumentError.new("PowerNumberLimits requires PowerStep")
          validate_power_grid!
        else
          if min_power || max_power || power_step
            raise ArgumentError.new("power limits require PowerNumberLimits")
          end
          @min_power = DEFAULT_MIN_POWER
          @max_power = DEFAULT_MAX_POWER
          @power_step = DEFAULT_POWER_STEP
        end
        @cook_time = cook_time || Math.min(DEFAULT_COOK_TIME, @max_cook_time)
        @power_setting = power_setting || @max_power
        validate_cook_time!(@cook_time)
        validate_power_setting!(@power_setting)
      end

      # The callback applies all requested physical settings. A refusal keeps
      # every exposed setting and the coupled Mode cluster unchanged.
      def on_set_cooking_parameters(&block : UInt8, UInt32, UInt8, Bool -> InteractionModel::Status) : Nil
        @on_set_cooking_parameters = block
      end

      def on_add_more_time(&block : UInt32 -> InteractionModel::Status) : Nil
        @on_add_more_time = block
      end

      def handle_set_cooking_parameters(request : SetCookingParametersRequest) : InteractionModel::Status
        return InteractionModel::Status.invalid_command if request.cook_mode.nil? &&
                                                           request.cook_time.nil? && request.power_setting.nil? && request.watt_setting_index.nil?
        return InteractionModel::Status.invalid_command unless request.watt_setting_index.nil?
        mode = request.cook_mode || @normal_mode
        seconds = request.cook_time || DEFAULT_COOK_TIME
        power = request.power_setting || @max_power
        start = request.start_after_setting || false
        return InteractionModel::Status.constraint_error unless supported_mode?(mode)
        return InteractionModel::Status.constraint_error unless valid_cook_time?(seconds)
        return InteractionModel::Status.constraint_error unless valid_power_setting?(power)
        return InteractionModel::Status.invalid_in_state unless callback = @on_set_cooking_parameters
        status = callback.call(mode, seconds, power, start)
        return status unless status.success?
        @mode_cluster.current_mode = mode
        self.cook_time = seconds
        self.power_setting = power
        status
      end

      def handle_add_more_time(request : AddMoreTimeRequest) : InteractionModel::Status
        return InteractionModel::Status.invalid_command unless @add_more_time_supported
        additional = request.time_to_add
        return InteractionModel::Status.constraint_error if additional < MIN_COOK_TIME
        total = @cook_time.to_u64 + additional.to_u64
        return InteractionModel::Status.constraint_error if total > @max_cook_time
        return InteractionModel::Status.invalid_in_state unless callback = @on_add_more_time
        status = callback.call(additional)
        self.cook_time = total.to_u32 if status.success?
        status
      end

      private def add_more_time_supported?(_id : UInt32) : Bool
        @add_more_time_supported
      end

      private def supported_mode?(mode : UInt8) : Bool
        @mode_cluster.supported_modes.any?(&.mode.==(mode))
      end

      private def valid_cook_time?(seconds : UInt32) : Bool
        (MIN_COOK_TIME..@max_cook_time).includes?(seconds)
      end

      private def valid_power_setting?(power : UInt8) : Bool
        (@min_power..@max_power).includes?(power) &&
          ((power.to_i32 - @min_power.to_i32) % @power_step.to_i32).zero?
      end

      private def validate_cook_time!(seconds : UInt32) : Nil
        raise ArgumentError.new("CookTime exceeds MaxCookTime") unless valid_cook_time?(seconds)
      end

      private def validate_power_setting!(power : UInt8) : Nil
        raise ArgumentError.new("PowerSetting is outside the supported grid") unless valid_power_setting?(power)
      end

      private def validate_power_grid! : Nil
        unless @min_power.in?(1_u8..99_u8) && @max_power.in?(2_u8..100_u8) &&
               @max_power > @min_power && @power_step.in?(1_u8..@max_power) &&
               ((@max_power.to_i32 - @min_power.to_i32) % @power_step.to_i32).zero?
          raise ArgumentError.new("power limits must define a divisible grid")
        end
      end

      private def reject_fixed_max_cook_time!(_seconds : UInt32) : Nil
        raise ArgumentError.new("MaxCookTime is fixed")
      end

      private def reject_fixed_power_limit!(_power : UInt8) : Nil
        raise ArgumentError.new("power limits are fixed")
      end

      private def after_restore_state : Nil
        @cook_time = Math.min(DEFAULT_COOK_TIME, @max_cook_time) unless valid_cook_time?(@cook_time)
        @power_setting = @max_power unless valid_power_setting?(@power_setting)
      end
    end
  end
end
