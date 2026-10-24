require "./cluster"

module Matter
  module Cluster
    # Matter 1.6 Closure Control (0x0104), revision 1. The host admits motion
    # and reports physical completion; commands never pretend hardware moved.
    class ClosureControl < Base
      cluster 0x0104, revision: 1

      feature :positioning, bit: 0
      feature :motion_latching, bit: 1
      feature :instantaneous, bit: 2
      feature :speed, bit: 3
      feature :ventilation, bit: 4
      feature :pedestrian, bit: 5
      feature :calibration, bit: 6
      feature :protection, bit: 7
      feature :manually_operable, bit: 8

      SUPPORTED_FEATURES    = (1_u32 << 9) - 1_u32
      MAX_ERRORS            =          10
      MAX_COUNTDOWN_SECONDS = 259_200_u32
      REMOTE_LATCHING       =     0x01_u8
      REMOTE_UNLATCHING     =     0x02_u8
      LATCH_CONTROL_MASK    = REMOTE_LATCHING | REMOTE_UNLATCHING

      enum MainState : UInt8
        Stopped          = 0
        Moving           = 1
        WaitingForMotion = 2
        Error            = 3
        Calibrating      = 4
        Protected        = 5
        Disengaged       = 6
        SetupRequired    = 7
      end

      enum ClosureError : UInt8
        PhysicallyBlocked    = 0
        BlockedBySensor      = 1
        TemperatureLimited   = 2
        MaintenanceRequired  = 3
        InternalInterference = 4
      end

      enum CurrentPosition : UInt8
        FullyClosed          = 0
        FullyOpened          = 1
        PartiallyOpened      = 2
        OpenedForPedestrian  = 3
        OpenedForVentilation = 4
        OpenedAtSignature    = 5
      end

      enum TargetPosition : UInt8
        MoveToFullyClosed         = 0
        MoveToFullyOpen           = 1
        MoveToPedestrianPosition  = 2
        MoveToVentilationPosition = 3
        MoveToSignaturePosition   = 4
      end

      enum Speed : UInt8
        Auto   = 0
        Low    = 1
        Medium = 2
        High   = 3
      end

      struct CurrentState
        include TLV::Serializable

        @[TLV::Field(tag: 0, optional: true)]
        getter position : CurrentPosition?

        @[TLV::Field(tag: 1, optional: true)]
        getter latch : Bool?

        @[TLV::Field(tag: 2, optional: true)]
        getter speed : Speed?

        @[TLV::Field(tag: 3, optional: false)]
        getter secure_state : Bool?

        def initialize(@position : CurrentPosition? = nil, @latch : Bool? = nil,
                       @speed : Speed? = nil, @secure_state : Bool? = nil)
        end
      end

      struct TargetState
        include TLV::Serializable

        @[TLV::Field(tag: 0, optional: true)]
        getter position : TargetPosition?

        @[TLV::Field(tag: 1, optional: true)]
        getter latch : Bool?

        @[TLV::Field(tag: 2, optional: true)]
        getter speed : Speed?

        def initialize(@position : TargetPosition? = nil, @latch : Bool? = nil,
                       @speed : Speed? = nil)
        end
      end

      struct MoveToRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0, optional: true)]
        getter position : TargetPosition?

        @[TLV::Field(tag: 1, optional: true)]
        getter latch : Bool?

        @[TLV::Field(tag: 2, optional: true)]
        getter speed : Speed?

        def initialize(@position : TargetPosition? = nil, @latch : Bool? = nil,
                       @speed : Speed? = nil)
        end
      end

      struct OperationalErrorEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter error_state : Array(ClosureError)

        def initialize(@error_state : Array(ClosureError))
        end
      end

      struct EngageStateChangedEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter? engage_value : Bool

        def initialize(@engage_value : Bool)
        end
      end

      struct SecureStateChangedEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter? secure_value : Bool

        def initialize(@secure_value : Bool)
        end
      end

      attribute 0x0000, :countdown_time, UInt32, nullable: true, optional: true,
        requires: [{positioning: true, instantaneous: false}],
        validate: :validate_countdown!
      attribute 0x0001, :main_state, MainState, default: MainState::Stopped
      attribute 0x0002, :current_error_list, Array(ClosureError),
        default: [] of ClosureError, copy_on_assign: true, validate: :validate_errors!
      attribute 0x0003, :overall_current_state, CurrentState, nullable: true
      attribute 0x0004, :overall_target_state, TargetState, nullable: true
      attribute 0x0005, :latch_control_modes, UInt8, default: 0_u8,
        fixed: true, requires: :motion_latching, validate: :validate_latch_modes!

      command 0x00, :stop, access: :operate, requires: {instantaneous: false}
      command 0x01, :move_to, request: MoveToRequest, access: :operate, timed: true
      command 0x02, :calibrate, access: :manage, timed: true, requires: :calibration

      event 0x00, :operational_error, priority: :critical, payload: OperationalErrorEvent
      event 0x01, :movement_completed, priority: :info, requires: {instantaneous: false}
      event 0x02, :engage_state_changed, priority: :info, payload: EngageStateChangedEvent,
        requires: :manually_operable
      event 0x03, :secure_state_changed, priority: :info, payload: SecureStateChangedEvent

      @move_callback : Proc(MoveToRequest, Bool)?
      @stop_callback : Proc(Nil)?
      @calibrate_callback : Proc(Bool)?

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @feature_map : Feature = Feature::Positioning,
                     @latch_control_modes : UInt8 = 0_u8,
                     @main_state : MainState = MainState::Stopped,
                     @overall_current_state : CurrentState? = nil,
                     @overall_target_state : TargetState? = nil,
                     @current_error_list : Array(ClosureError) = [] of ClosureError,
                     @countdown_time : UInt32? = nil)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        validate_configuration!
      end

      def on_move_to(&block : MoveToRequest -> Bool) : Nil
        @move_callback = block
      end

      def on_stop(&block : -> Nil) : Nil
        @stop_callback = block
      end

      def on_calibrate(&block : -> Bool) : Nil
        @calibrate_callback = block
      end

      def stop : InteractionModel::Status
        @stop_callback.try(&.call)
        if {MainState::Moving, MainState::WaitingForMotion, MainState::Calibrating}.includes?(@main_state)
          self.main_state = MainState::Stopped
        end
        InteractionModel::Status.success
      end

      def move_to(request : MoveToRequest) : InteractionModel::Status
        return InteractionModel::Status.constraint_error if request.position.nil? && request.latch.nil? && request.speed.nil?
        if @feature_map.positioning?
          return InteractionModel::Status.constraint_error if request.position == TargetPosition::MoveToPedestrianPosition && !@feature_map.pedestrian?
          return InteractionModel::Status.constraint_error if request.position == TargetPosition::MoveToVentilationPosition && !@feature_map.ventilation?
        end
        unless request.latch.nil?
          if @feature_map.motion_latching?
            mode = request.latch == true ? REMOTE_LATCHING : REMOTE_UNLATCHING
            return InteractionModel::Status.invalid_in_state if (@latch_control_modes & mode).zero?
          end
        end
        return InteractionModel::Status.invalid_in_state if {MainState::Error, MainState::Protected, MainState::Disengaged, MainState::SetupRequired}.includes?(@main_state)
        target = @overall_target_state
        position = @feature_map.positioning? ? (request.position || target.try(&.position)) : nil
        latch = @feature_map.motion_latching? ? (request.latch.nil? ? target.try(&.latch) : request.latch) : nil
        speed = @feature_map.speed? ? (request.speed || Speed::Auto) : nil
        active_request = (@feature_map.positioning? && !request.position.nil?) ||
                         (@feature_map.motion_latching? && !request.latch.nil?) ||
                         (@feature_map.speed? && !request.speed.nil?)
        return InteractionModel::Status.success unless active_request
        callback = @move_callback || return InteractionModel::Status.invalid_in_state
        return InteractionModel::Status.invalid_in_state unless callback.call(request)
        self.overall_target_state = TargetState.new(position, latch, speed)
        self.main_state = MainState::Moving unless @feature_map.instantaneous?
        InteractionModel::Status.success
      end

      def calibrate : InteractionModel::Status
        callback = @calibrate_callback || return InteractionModel::Status.invalid_in_state
        return InteractionModel::Status.invalid_in_state unless callback.call
        self.main_state = MainState::Calibrating
        InteractionModel::Status.success
      end

      # Host reports real actuator state after observing it, including manual operation.
      def report_state(state : CurrentState, main_state : MainState = MainState::Stopped) : Nil
        validate_state!(state)
        validate_main_state!(main_state)
        previous = @overall_current_state
        self.overall_current_state = state
        self.main_state = main_state
        if previous && previous.secure_state != state.secure_state && !state.secure_state.nil?
          emit_secure_state_changed(SecureStateChangedEvent.new(state.secure_state.as(Bool)))
        end
        if !@feature_map.instantaneous? && main_state.stopped? && previous && previous.position != state.position
          emit_movement_completed
        end
      end

      def report_errors(errors : Array(ClosureError)) : Nil
        validate_errors!(errors)
        self.current_error_list = errors.dup
        emit_operational_error(OperationalErrorEvent.new(errors.dup)) unless errors.empty?
      end

      # A manually operable closure reports engagement independently of motion.
      def report_engaged(engaged : Bool) : Nil
        raise ConfigurationError.new("ManuallyOperable feature is absent") unless @feature_map.manually_operable?
        changed = @main_state.disengaged? == engaged
        self.main_state = engaged ? MainState::Stopped : MainState::Disengaged
        emit_engage_state_changed(EngageStateChangedEvent.new(engaged)) if changed
      end

      private def validate_configuration! : Nil
        raise ArgumentError.new("unsupported Closure Control feature") unless (@feature_map.value & ~SUPPORTED_FEATURES).zero?
        raise ArgumentError.new("Positioning or MotionLatching required") unless @feature_map.positioning? || @feature_map.motion_latching?
        raise ArgumentError.new("Speed requires Positioning without Instantaneous") if @feature_map.speed? && (!@feature_map.positioning? || @feature_map.instantaneous?)
        raise ArgumentError.new("Ventilation, Pedestrian and Calibration require Positioning") if (@feature_map.ventilation? || @feature_map.pedestrian? || @feature_map.calibration?) && !@feature_map.positioning?
        validate_latch_modes!(@latch_control_modes)
        validate_countdown!(@countdown_time)
        validate_errors!(@current_error_list)
        validate_main_state!(@main_state)
        if state = @overall_current_state
          validate_state!(state)
        end
        if target = @overall_target_state
          validate_target!(target)
        end
      end

      private def validate_main_state!(state : MainState) : Nil
        raise ArgumentError.new("Calibrating requires Calibration") if state.calibrating? && !@feature_map.calibration?
        raise ArgumentError.new("Protected requires Protection") if state.protected? && !@feature_map.protection?
        raise ArgumentError.new("Disengaged requires ManuallyOperable") if state.disengaged? && !@feature_map.manually_operable?
      end

      private def validate_state!(state : CurrentState) : Nil
        raise ArgumentError.new("Position field requires Positioning") if state.position && !@feature_map.positioning?
        raise ArgumentError.new("Pedestrian position requires Pedestrian") if state.position == CurrentPosition::OpenedForPedestrian && !@feature_map.pedestrian?
        raise ArgumentError.new("Ventilation position requires Ventilation") if state.position == CurrentPosition::OpenedForVentilation && !@feature_map.ventilation?
        raise ArgumentError.new("Latch field requires MotionLatching") if !state.latch.nil? && !@feature_map.motion_latching?
        raise ArgumentError.new("Speed field requires Speed") if state.speed && !@feature_map.speed?
      end

      private def validate_target!(state : TargetState) : Nil
        raise ArgumentError.new("Target position requires Positioning") if state.position && !@feature_map.positioning?
        raise ArgumentError.new("Pedestrian target requires Pedestrian") if state.position == TargetPosition::MoveToPedestrianPosition && !@feature_map.pedestrian?
        raise ArgumentError.new("Ventilation target requires Ventilation") if state.position == TargetPosition::MoveToVentilationPosition && !@feature_map.ventilation?
        raise ArgumentError.new("Target latch requires MotionLatching") if !state.latch.nil? && !@feature_map.motion_latching?
        raise ArgumentError.new("Target speed requires Speed") if state.speed && !@feature_map.speed?
      end

      private def validate_countdown!(seconds : UInt32?) : Nil
        raise ArgumentError.new("CountdownTime exceeds 259200") if seconds && seconds > MAX_COUNTDOWN_SECONDS
      end

      private def validate_errors!(errors : Array(ClosureError)) : Nil
        raise ArgumentError.new("CurrentErrorList exceeds 10") if errors.size > MAX_ERRORS
        raise ArgumentError.new("CurrentErrorList contains duplicates") unless errors.uniq.size == errors.size
      end

      private def validate_latch_modes!(modes : UInt8) : Nil
        raise ArgumentError.new("unknown LatchControlModes bits") unless (modes & ~LATCH_CONTROL_MASK).zero?
        raise ArgumentError.new("LatchControlModes requires MotionLatching") if modes != 0 && !@feature_map.motion_latching?
      end
    end
  end
end
