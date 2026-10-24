require "./cluster"
require "../storage/record"

module Matter
  module Cluster
    # Matter 1.6 Camera AV Settings User Level Management server.
    # This implementation exposes the MechanicalPan feature only. The host
    # starts the actuator in the callback and reports its measured position.
    class CameraAvSettingsUserLevelManagement < Base
      cluster 0x0552, revision: 1

      feature :mechanical_pan, bit: 1

      PAN_MIN_LIMIT = -180_i16
      PAN_MAX_LIMIT =  180_i16
      ZERO_PAN      =    0_i16

      enum PhysicalMovement : UInt8
        Idle   = 0
        Moving = 1
      end

      struct MPTZPosition
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        getter pan : Int16

        def initialize(@pan : Int16)
        end
      end

      struct MPTZSetPositionRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0, optional: true)]
        getter pan : Int16?

        def initialize(@pan : Int16? = nil)
        end
      end

      struct MPTZRelativeMoveRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0, optional: true)]
        getter pan_delta : Int16?

        def initialize(@pan_delta : Int16? = nil)
        end
      end

      attribute 0x0000, :mptz_position, MPTZPosition,
        default: MPTZPosition.new(ZERO_PAN), persist: true,
        requires: :mechanical_pan, validate: :validate_position!
      attribute 0x0007, :pan_min, Int16, default: PAN_MIN_LIMIT,
        requires: :mechanical_pan, validate: :validate_pan_min!
      attribute 0x0008, :pan_max, Int16, default: PAN_MAX_LIMIT,
        requires: :mechanical_pan, validate: :validate_pan_max!
      attribute 0x0009, :movement_state, PhysicalMovement,
        default: PhysicalMovement::Idle, requires: :mechanical_pan

      command 0x00, :mptz_set_position, request: MPTZSetPositionRequest,
        access: :operate, requires: :mechanical_pan
      command 0x01, :mptz_relative_move, request: MPTZRelativeMoveRequest,
        access: :operate, requires: :mechanical_pan

      @on_pan_move : Proc(Int16, InteractionModel::Status)?

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @pan_min : Int16 = PAN_MIN_LIMIT,
                     @pan_max : Int16 = PAN_MAX_LIMIT,
                     initial_pan : Int16 = ZERO_PAN,
                     @feature_map : Feature = Feature::MechanicalPan)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        unless @feature_map == Feature::MechanicalPan
          raise ArgumentError.new("only MechanicalPan is implemented")
        end
        unless (PAN_MIN_LIMIT..ZERO_PAN).includes?(@pan_min) &&
               (1_i16..PAN_MAX_LIMIT).includes?(@pan_max)
          raise ArgumentError.new("pan limits must be -180..0 and 1..180")
        end
        validate_pan!(initial_pan)
        @mptz_position = MPTZPosition.new(initial_pan)
      end

      # The callback starts physical movement to target and returns the
      # command status. Report completion with #report_pan_position.
      def on_pan_move(&block : Int16 -> InteractionModel::Status) : Nil
        @on_pan_move = block
      end

      def mptz_set_position(request : MPTZSetPositionRequest) : InteractionModel::Status
        pan = request.pan
        return InteractionModel::Status.constraint_error unless pan
        move_pan(pan)
      end

      def mptz_relative_move(request : MPTZRelativeMoveRequest) : InteractionModel::Status
        delta = request.pan_delta
        return InteractionModel::Status.constraint_error unless delta
        maximum_delta = @pan_max.to_i32 - @pan_min.to_i32
        return InteractionModel::Status.constraint_error if delta.to_i32.abs > maximum_delta
        target = @mptz_position.pan.to_i32 + delta.to_i32
        return InteractionModel::Status.constraint_error unless (@pan_min.to_i32..@pan_max.to_i32).includes?(target)
        move_pan(target.to_i16)
      end

      # Call when the actuator has measured a new position. The final report
      # is persisted and resets MovementState to Idle.
      def report_pan_position(pan : Int16, moving : Bool = false) : Nil
        validate_pan!(pan)
        self.mptz_position = MPTZPosition.new(pan)
        self.movement_state = moving ? PhysicalMovement::Moving : PhysicalMovement::Idle
      end

      private def move_pan(target : Int16) : InteractionModel::Status
        return InteractionModel::Status.constraint_error unless valid_pan?(target)
        actuator = @on_pan_move
        return InteractionModel::Status.invalid_in_state unless actuator
        self.movement_state = PhysicalMovement::Moving
        status = actuator.call(target)
        self.movement_state = PhysicalMovement::Idle unless status.success?
        status
      rescue ex
        self.movement_state = PhysicalMovement::Idle
        raise ex
      end

      private def valid_pan?(pan : Int16) : Bool
        (@pan_min..@pan_max).includes?(pan)
      end

      private def validate_pan!(pan : Int16) : Nil
        raise ArgumentError.new("pan position is outside PanMin/PanMax") unless valid_pan?(pan)
      end

      private def validate_position!(position : MPTZPosition) : Nil
        validate_pan!(position.pan)
      end

      private def validate_pan_min!(value : Int16) : Nil
        unless (PAN_MIN_LIMIT..ZERO_PAN).includes?(value) && value <= @mptz_position.pan
          raise ArgumentError.new("PanMin must be -180..0 and include MPTZPosition")
        end
      end

      private def validate_pan_max!(value : Int16) : Nil
        unless (1_i16..PAN_MAX_LIMIT).includes?(value) && value >= @mptz_position.pan
          raise ArgumentError.new("PanMax must be 1..180 and include MPTZPosition")
        end
      end

      private def after_restore_state : Nil
        self.mptz_position = MPTZPosition.new(ZERO_PAN) unless valid_pan?(@mptz_position.pan)
        self.movement_state = PhysicalMovement::Idle
      end
    end
  end
end
