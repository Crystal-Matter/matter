require "./closure_control"

module Matter
  module Cluster
    # Matter 1.6 Closure Dimension (0x0105), revision 1. Positions are
    # percent100ths: integer 1 on the wire represents 0.01 percent.
    class ClosureDimension < Base
      cluster 0x0105, revision: 1

      feature :positioning, bit: 0
      feature :motion_latching, bit: 1
      feature :unit, bit: 2
      feature :limitation, bit: 3
      feature :speed, bit: 4
      feature :translation, bit: 5
      feature :rotation, bit: 6
      feature :modulation, bit: 7

      SUPPORTED_FEATURES = (1_u32 << 8) - 1_u32
      MAX_POSITION       = 10_000_u16
      REMOTE_LATCHING    =    0x01_u8
      REMOTE_UNLATCHING  =    0x02_u8
      LATCH_CONTROL_MASK = REMOTE_LATCHING | REMOTE_UNLATCHING

      alias Speed = ClosureControl::Speed

      enum StepDirection : UInt8
        Decrease = 0
        Increase = 1
      end

      enum ClosureUnit : UInt8
        Millimeter = 0
        Degree     = 1
      end

      enum TranslationDirection : UInt8
        Downward           =  0
        Upward             =  1
        VerticalMask       =  2
        VerticalSymmetry   =  3
        Leftward           =  4
        Rightward          =  5
        HorizontalMask     =  6
        HorizontalSymmetry =  7
        Forward            =  8
        Backward           =  9
        DepthMask          = 10
        DepthSymmetry      = 11
      end

      enum RotationAxis : UInt8
        Left                 =  0
        CenteredVertical     =  1
        LeftAndRight         =  2
        Right                =  3
        Top                  =  4
        CenteredHorizontal   =  5
        TopAndBottom         =  6
        Bottom               =  7
        LeftBarrier          =  8
        LeftAndRightBarriers =  9
        RightBarrier         = 10
      end

      enum Overflow : UInt8
        NoOverflow    =  0
        Inside        =  1
        Outside       =  2
        TopInside     =  3
        TopOutside    =  4
        BottomInside  =  5
        BottomOutside =  6
        LeftInside    =  7
        LeftOutside   =  8
        RightInside   =  9
        RightOutside  = 10
      end

      enum ModulationType : UInt8
        SlatsOrientation = 0
        SlatsOpenwork    = 1
        StripesAlignment = 2
        Opacity          = 3
        Ventilation      = 4
      end

      struct State
        include TLV::Serializable

        @[TLV::Field(tag: 0, optional: true)]
        getter position : UInt16?

        @[TLV::Field(tag: 1, optional: true)]
        getter latch : Bool?

        @[TLV::Field(tag: 2, optional: true)]
        getter speed : Speed?

        def initialize(@position : UInt16? = nil, @latch : Bool? = nil, @speed : Speed? = nil)
        end
      end

      struct StateWire
        include TLV::Serializable

        @[TLV::Field(tag: 0, optional: true)]
        getter position : TLV::FieldState(UInt16)

        @[TLV::Field(tag: 1, optional: true)]
        getter latch : TLV::FieldState(Bool)

        @[TLV::Field(tag: 2, optional: true)]
        getter speed : Speed?

        def initialize(@position : TLV::FieldState(UInt16), @latch : TLV::FieldState(Bool), @speed : Speed?)
        end
      end

      struct PercentRange
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter min : UInt16

        @[TLV::Field(tag: 1)]
        getter max : UInt16

        def initialize(@min : UInt16, @max : UInt16)
          raise ArgumentError.new("invalid closure limit range") if @min > @max || @max > MAX_POSITION
        end
      end

      struct UnitRange
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter min : Int16

        @[TLV::Field(tag: 1)]
        getter max : Int16

        def initialize(@min : Int16, @max : Int16)
          raise ArgumentError.new("invalid closure unit range") if @min > @max
        end
      end

      struct SetTargetRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0, optional: true)]
        getter position : UInt16?

        @[TLV::Field(tag: 1, optional: true)]
        getter latch : Bool?

        @[TLV::Field(tag: 2, optional: true)]
        getter speed : Speed?

        def initialize(@position : UInt16? = nil, @latch : Bool? = nil, @speed : Speed? = nil)
        end
      end

      struct StepRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter direction : StepDirection

        @[TLV::Field(tag: 1)]
        getter number_of_steps : UInt16

        @[TLV::Field(tag: 2, optional: true)]
        getter speed : Speed?

        def initialize(@direction : StepDirection, @number_of_steps : UInt16, @speed : Speed? = nil)
        end
      end

      attribute 0x0000, :current_state, State, nullable: true
      attribute 0x0001, :target_state, State, nullable: true
      attribute 0x0002, :resolution, UInt16, default: 1_u16,
        fixed: true, requires: :positioning, validate: :validate_resolution!
      attribute 0x0003, :step_value, UInt16, default: 1_u16,
        fixed: true, requires: :positioning, validate: :validate_step_value!
      attribute 0x0004, :unit, ClosureUnit, default: ClosureUnit::Millimeter,
        fixed: true, requires: :unit
      attribute 0x0005, :unit_range, UnitRange, nullable: true, requires: :unit
      attribute 0x0006, :limit_range, PercentRange,
        default: PercentRange.new(0_u16, MAX_POSITION), requires: :limitation,
        validate: :validate_limit_range!
      attribute 0x0007, :translation_direction, TranslationDirection,
        default: TranslationDirection::Upward, fixed: true, requires: :translation
      attribute 0x0008, :rotation_axis, RotationAxis,
        default: RotationAxis::Left, fixed: true, requires: :rotation
      attribute 0x0009, :overflow, Overflow,
        default: Overflow::NoOverflow, fixed: true, requires: :rotation
      attribute 0x000A, :modulation_type, ModulationType,
        default: ModulationType::SlatsOrientation, fixed: true, requires: :modulation
      attribute 0x000B, :latch_control_modes, UInt8,
        default: 0_u8, fixed: true, requires: :motion_latching

      command 0x00, :set_target, request: SetTargetRequest, access: :operate, timed: true
      command 0x01, :step, request: StepRequest, access: :operate, timed: true,
        requires: :positioning

      @set_target_callback : Proc(SetTargetRequest, Bool)?

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @feature_map : Feature = Feature::Positioning | Feature::Translation,
                     @resolution : UInt16 = 1_u16,
                     @step_value : UInt16 = 1_u16,
                     @latch_control_modes : UInt8 = 0_u8,
                     @unit : ClosureUnit = ClosureUnit::Millimeter,
                     @unit_range : UnitRange? = nil,
                     @limit_range : PercentRange = PercentRange.new(0_u16, MAX_POSITION),
                     @translation_direction : TranslationDirection = TranslationDirection::Upward,
                     @rotation_axis : RotationAxis = RotationAxis::Left,
                     @overflow : Overflow = Overflow::NoOverflow,
                     @modulation_type : ModulationType = ModulationType::SlatsOrientation,
                     @current_state : State? = nil,
                     @target_state : State? = nil)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        validate_configuration!
      end

      def on_set_target(&block : SetTargetRequest -> Bool) : Nil
        @set_target_callback = block
      end

      def read_attribute(attribute_id : UInt32, fabric_index : UInt8? = nil) : InteractionModel::Status | TLV::Any
        value = super
        return value unless value.is_a?(TLV::Any)
        state = case attribute_id
                when ATTR_CURRENT_STATE then @current_state
                when ATTR_TARGET_STATE  then @target_state
                end
        return value unless state
        tlv(StateWire.new(
          nullable_feature_field(state.position, @feature_map.positioning?),
          nullable_feature_field(state.latch, @feature_map.motion_latching?), state.speed))
      end

      # ameba:disable Naming/AccessorMethodName
      def set_target(request : SetTargetRequest) : InteractionModel::Status
        return InteractionModel::Status.constraint_error if request.position.nil? && request.latch.nil? && request.speed.nil?
        if position = request.position
          return InteractionModel::Status.constraint_error if @feature_map.positioning? && position > MAX_POSITION
        end
        unless request.latch.nil?
          if @feature_map.motion_latching?
            mode = request.latch == true ? REMOTE_LATCHING : REMOTE_UNLATCHING
            return InteractionModel::Status.invalid_in_state if (@latch_control_modes & mode).zero?
          end
        end
        previous = @target_state
        position = @feature_map.positioning? ? (request.position || previous.try(&.position)) : nil
        if position
          position = quantize(position)
          if @feature_map.limitation?
            position = position.clamp(@limit_range.min, @limit_range.max)
          end
        end
        latch = @feature_map.motion_latching? ? (request.latch.nil? ? previous.try(&.latch) : request.latch) : nil
        speed = @feature_map.speed? ? (request.speed || Speed::Auto) : nil
        active_request = (@feature_map.positioning? && !request.position.nil?) ||
                         (@feature_map.motion_latching? && !request.latch.nil?) ||
                         (@feature_map.speed? && !request.speed.nil?)
        return InteractionModel::Status.success unless active_request
        callback = @set_target_callback || return InteractionModel::Status.invalid_in_state
        normalized = SetTargetRequest.new(position, latch, speed)
        return InteractionModel::Status.invalid_in_state unless callback.call(normalized)
        self.target_state = State.new(position, latch, speed)
        InteractionModel::Status.success
      end

      def step(request : StepRequest) : InteractionModel::Status
        return InteractionModel::Status.constraint_error if request.number_of_steps.zero?
        base = @target_state.try(&.position) || @current_state.try(&.position)
        return InteractionModel::Status.invalid_in_state unless base
        delta = request.number_of_steps.to_u32 * @step_value.to_u32
        next_position = request.direction.increase? ? base.to_i64 + delta.to_i64 : base.to_i64 - delta.to_i64
        next_position = next_position.clamp(0_i64, MAX_POSITION.to_i64).to_u16
        set_target(SetTargetRequest.new(next_position, nil, request.speed))
      end

      # Host reports physical motion separately from a command's accepted target.
      def report_state(state : State) : Nil
        validate_state!(state)
        self.current_state = state
      end

      private def quantize(position : UInt16) : UInt16
        rounded = (position.to_u32 + @resolution.to_u32 // 2) // @resolution.to_u32 * @resolution.to_u32
        rounded.clamp(0_u32, (MAX_POSITION // @resolution * @resolution).to_u32).to_u16
      end

      private def nullable_feature_field(value : T?, enabled : Bool) : TLV::FieldState(T) forall T
        return TLV::FieldState(T).absent unless enabled
        value.nil? ? TLV::FieldState(T).null : TLV::FieldState(T).value(value)
      end

      private def validate_configuration! : Nil
        raise ArgumentError.new("unsupported Closure Dimension feature") unless (@feature_map.value & ~SUPPORTED_FEATURES).zero?
        raise ArgumentError.new("Positioning or MotionLatching required") unless @feature_map.positioning? || @feature_map.motion_latching?
        dependent = @feature_map.unit? || @feature_map.limitation? || @feature_map.speed? || @feature_map.translation? || @feature_map.rotation? || @feature_map.modulation?
        raise ArgumentError.new("Closure Dimension optional features require Positioning") if dependent && !@feature_map.positioning?
        motion_types = [@feature_map.translation?, @feature_map.rotation?, @feature_map.modulation?].count(true)
        raise ArgumentError.new("Positioning requires exactly one motion type") if @feature_map.positioning? && motion_types != 1
        raise ArgumentError.new("UnitRange requires Unit feature") if @unit_range && !@feature_map.unit?
        validate_resolution!(@resolution)
        validate_step_value!(@step_value)
        validate_limit_range!(@limit_range)
        raise ArgumentError.new("unknown latch modes") unless (@latch_control_modes & ~LATCH_CONTROL_MASK).zero?
        raise ArgumentError.new("LatchControlModes requires MotionLatching") if @latch_control_modes != 0 && !@feature_map.motion_latching?
        if state = @current_state
          validate_state!(state)
        end
        if state = @target_state
          validate_state!(state)
        end
      end

      private def validate_resolution!(value : UInt16) : Nil
        raise ArgumentError.new("Resolution must be 1..10000 encoded units") if value.zero? || value > MAX_POSITION
      end

      private def validate_step_value!(value : UInt16) : Nil
        raise ArgumentError.new("StepValue must be a positive multiple of Resolution") if value.zero? || value > MAX_POSITION || value % @resolution != 0
      end

      private def validate_limit_range!(value : PercentRange) : Nil
        return unless @feature_map.limitation?
        if value.min % @resolution != 0 || value.max % @resolution != 0
          raise ArgumentError.new("LimitRange bounds must be multiples of Resolution")
        end
      end

      private def validate_state!(state : State) : Nil
        if position = state.position
          raise ArgumentError.new("invalid Position") unless @feature_map.positioning? && position <= MAX_POSITION && position % @resolution == 0
        end
        raise ArgumentError.new("Latch requires MotionLatching") if !state.latch.nil? && !@feature_map.motion_latching?
        raise ArgumentError.new("Speed requires Speed feature") if state.speed && !@feature_map.speed?
      end
    end
  end
end
