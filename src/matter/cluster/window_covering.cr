require "./cluster"

module Matter
  module Cluster
    # Window Covering Cluster Implementation (0x0102)
    #
    # Provides control for various types of window coverings such as blinds,
    # shades, curtains, etc.
    #
    # Matter Specification: Core 1.6 § 5.3 - Window Covering Cluster
    #
    # Features:
    # - Lift (LF): Supports lift/lower position control
    # - Tilt (TL): Supports tilt control
    # - PositionAwareLift (PA_LF): Supports precise lift positioning
    # - PositionAwareTilt (PA_TL): Supports precise tilt positioning
    class WindowCovering < Base
      cluster 0x0102, revision: 8

      feature :lift, bit: 0                # LF - Lift/lower control
      feature :tilt, bit: 1                # TL - Tilt control
      feature :position_aware_lift, bit: 2 # PA_LF - Precise lift positioning
      feature :position_aware_tilt, bit: 4 # PA_TL - Precise tilt positioning

      SUPPORTED_FEATURES = Feature::Lift | Feature::Tilt | Feature::PositionAwareLift | Feature::PositionAwareTilt

      # Fully open and fully closed in the percent100ths attributes
      OPEN_POSITION_PERCENT100THS =      0_u16
      MAX_POSITION_PERCENT100THS  = 10_000_u16

      # WindowCoveringType enum
      enum CoveringType : UInt8
        Rollershade               =   0
        Rollershade2Motor         =   1
        RollershadeExterior       =   2
        RollershadeExterior2Motor =   3
        Drapery                   =   4
        Awning                    =   5
        Shutter                   =   6
        TiltBlindTiltOnly         =   7
        TiltBlindLiftAndTilt      =   8
        ProjectorScreen           =   9
        Unknown                   = 255
      end

      # EndProductType enum
      enum EndProductType : UInt8
        RollerShade               =   0
        RomanShade                =   1
        BalloonShade              =   2
        WovenWood                 =   3
        PleatedShade              =   4
        CellularShade             =   5
        LayeredShade              =   6
        LayeredShade2D            =   7
        SheerShade                =   8
        TiltOnlyInteriorBlind     =   9
        InteriorBlind             =  10
        VerticalBlindStripCurtain =  11
        InteriorVenetianBlind     =  12
        ExteriorVenetianBlind     =  13
        LateralLeftCurtain        =  14
        LateralRightCurtain       =  15
        CentralCurtain            =  16
        RollerShutter             =  17
        ExteriorVerticalScreen    =  18
        AwningTerracePatio        =  19
        AwningVerticalScreen      =  20
        TiltOnlyPergola           =  21
        SwingingShutter           =  22
        SlidingShutter            =  23
        Unknown                   = 255
      end

      # OperationalStatus bitmap
      @[Flags]
      enum OperationalStatus : UInt8
        GlobalOpening = 0x01
        GlobalClosing = 0x02
        LiftOpening   = 0x04
        LiftClosing   = 0x08
        TiltOpening   = 0x10
        TiltClosing   = 0x20
      end

      enum MovementStatus : UInt8
        Stopped = 0
        Opening = 1
        Closing = 2
      end

      STATUS_FIELD_MASK = 0x03_u8
      LIFT_STATUS_SHIFT =       2
      TILT_STATUS_SHIFT =       4

      # ConfigStatus bitmap
      @[Flags]
      enum ConfigStatus : UInt8
        Operational           = 0x01
        OnlineReserved        = 0x02
        LiftMovementReversed  = 0x04
        LiftPositionAware     = 0x08
        TiltPositionAware     = 0x10
        LiftEncoderControlled = 0x20
        TiltEncoderControlled = 0x40
      end

      # Mode bitmap
      @[Flags]
      enum Mode : UInt8
        MotorDirectionReversed = 0x01
        CalibrationMode        = 0x02
        MaintenanceMode        = 0x04
        LedFeedback            = 0x08
      end

      struct GoToLiftPercentageRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property lift_percent100ths_value : UInt16

        def initialize(@lift_percent100ths_value : UInt16)
        end
      end

      struct GoToTiltPercentageRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property tilt_percent100ths_value : UInt16

        def initialize(@tilt_percent100ths_value : UInt16)
        end
      end

      # Requested physical targets. A nil axis is not part of this command.
      struct MotionRequest
        getter lift_target : UInt16?
        getter tilt_target : UInt16?

        def initialize(@lift_target : UInt16? = nil, @tilt_target : UInt16? = nil)
        end
      end

      @move_callback : Proc(MotionRequest, InteractionModel::Status)?
      @stop_callback : Proc(InteractionModel::Status)?

      attribute 0x0000, :type, CoveringType, default: CoveringType::Rollershade, fixed: true
      attribute 0x0005, :number_of_actuations_lift, UInt16, default: 0_u16, persist: true, optional: true, requires: :lift
      attribute 0x0006, :number_of_actuations_tilt, UInt16, default: 0_u16, persist: true, optional: true, requires: :tilt
      attribute 0x0007, :config_status, ConfigStatus, default: ConfigStatus::Operational, persist: true
      attribute 0x0008, :current_position_lift_percentage, UInt8, nullable: true, optional: true, persist: true, requires: {lift: true, position_aware_lift: true}
      attribute 0x0009, :current_position_tilt_percentage, UInt8, nullable: true, optional: true, persist: true, requires: {tilt: true, position_aware_tilt: true}
      attribute 0x000A, :operational_status, OperationalStatus, default: OperationalStatus::None
      attribute 0x000B, :target_position_lift_percent100ths, UInt16, nullable: true, max: MAX_POSITION_PERCENT100THS, requires: {lift: true, position_aware_lift: true}
      attribute 0x000C, :target_position_tilt_percent100ths, UInt16, nullable: true, max: MAX_POSITION_PERCENT100THS, requires: {tilt: true, position_aware_tilt: true}
      attribute 0x000D, :end_product_type, EndProductType, default: EndProductType::RollerShade, fixed: true
      attribute 0x000E, :current_position_lift_percent100ths, UInt16, nullable: true, persist: true,
        max: MAX_POSITION_PERCENT100THS, requires: {lift: true, position_aware_lift: true}, on_change: :sync_lift_percentage
      attribute 0x000F, :current_position_tilt_percent100ths, UInt16, nullable: true, persist: true,
        max: MAX_POSITION_PERCENT100THS, requires: {tilt: true, position_aware_tilt: true}, on_change: :sync_tilt_percentage
      attribute 0x0017, :mode, Mode, default: Mode::None, writable: true, write_access: :manage,
        on_change: :sync_mode_config_status
      attribute 0x001A, :safety_status, UInt16, default: 0_u16, optional: true

      command 0x00, :up_or_open
      command 0x01, :down_or_close
      command 0x02, :stop_motion
      command 0x05, :go_to_lift_percentage, request: GoToLiftPercentageRequest, requires: {lift: true, position_aware_lift: true}
      command 0x08, :go_to_tilt_percentage, request: GoToTiltPercentageRequest, requires: {tilt: true, position_aware_tilt: true}

      def initialize(
        endpoint_id : DataType::EndpointNumber,
        @feature_map : Feature = Feature::Lift | Feature::PositionAwareLift,
        covering_type : CoveringType = CoveringType::Rollershade,
        @end_product_type : EndProductType = EndProductType::RollerShade,
      )
        raise ArgumentError.new("WindowCovering has unsupported feature bits") if (@feature_map.value & ~SUPPORTED_FEATURES.value) != 0
        raise ArgumentError.new("WindowCovering requires Lift or Tilt") unless @feature_map.lift? || @feature_map.tilt?
        if @feature_map.position_aware_lift? && !@feature_map.lift?
          raise ArgumentError.new("PositionAwareLift requires Lift")
        end
        if @feature_map.position_aware_tilt? && !@feature_map.tilt?
          raise ArgumentError.new("PositionAwareTilt requires Tilt")
        end

        @type = covering_type
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))

        @config_status |= ConfigStatus::LiftPositionAware if @feature_map.lift? && @feature_map.position_aware_lift?
        @config_status |= ConfigStatus::TiltPositionAware if @feature_map.tilt? && @feature_map.position_aware_tilt?
      end

      # ------------------------------------------------------------------------
      # Commands admit physical motion through the host before changing targets.
      # ------------------------------------------------------------------------

      def on_move(&block : MotionRequest -> InteractionModel::Status) : Nil
        @move_callback = block
      end

      def on_stop(&block : -> InteractionModel::Status) : Nil
        @stop_callback = block
      end

      def up_or_open : InteractionModel::Status
        lock_status = motion_lock_status
        return lock_status if lock_status
        move_to(OPEN_POSITION_PERCENT100THS, MovementStatus::Opening)
      end

      def down_or_close : InteractionModel::Status
        lock_status = motion_lock_status
        return lock_status if lock_status
        move_to(MAX_POSITION_PERCENT100THS, MovementStatus::Closing)
      end

      def stop_motion : InteractionModel::Status
        lock_status = motion_lock_status
        return lock_status if lock_status
        return InteractionModel::Status.success unless motion_in_progress?
        callback = @stop_callback || return InteractionModel::Status.invalid_in_state
        status = callback.call
        return status unless status.success?
        self.target_position_lift_percent100ths = current_position_lift_percent100ths if @feature_map.position_aware_lift?
        self.target_position_tilt_percent100ths = current_position_tilt_percent100ths if @feature_map.position_aware_tilt?
        self.operational_status = OperationalStatus::None
        InteractionModel::Status.success
      end

      def go_to_lift_percentage(request : GoToLiftPercentageRequest) : InteractionModel::Status
        lock_status = motion_lock_status
        return lock_status if lock_status
        percentage = request.lift_percent100ths_value
        return InteractionModel::Status.constraint_error if percentage > MAX_POSITION_PERCENT100THS

        move_lift_to(percentage)
      end

      def go_to_tilt_percentage(request : GoToTiltPercentageRequest) : InteractionModel::Status
        lock_status = motion_lock_status
        return lock_status if lock_status
        percentage = request.tilt_percent100ths_value
        return InteractionModel::Status.constraint_error if percentage > MAX_POSITION_PERCENT100THS

        status = admit_motion(MotionRequest.new(tilt_target: percentage))
        return status unless status.success?
        self.target_position_tilt_percent100ths = percentage
        set_movement_status(lift_movement_status,
          movement_toward(current_position_tilt_percent100ths, percentage))
        settle_reached_targets
        InteractionModel::Status.success
      end

      private def move_to(percentage : UInt16, direction : MovementStatus) : InteractionModel::Status
        status = admit_motion(MotionRequest.new(
          lift_target: @feature_map.lift? ? percentage : nil,
          tilt_target: @feature_map.tilt? ? percentage : nil))
        return status unless status.success?
        self.target_position_lift_percent100ths = percentage if @feature_map.position_aware_lift?
        self.target_position_tilt_percent100ths = percentage if @feature_map.position_aware_tilt?
        set_movement_status(
          @feature_map.lift? ? direction : MovementStatus::Stopped,
          @feature_map.tilt? ? direction : MovementStatus::Stopped)
        settle_reached_targets
        InteractionModel::Status.success
      end

      private def motion_lock_status : InteractionModel::Status?
        return InteractionModel::Status.busy if @mode.maintenance_mode?
        return InteractionModel::Status.failure if @mode.calibration_mode?
        nil
      end

      private def motion_in_progress? : Bool
        return true unless operational_status == OperationalStatus::None
        if @feature_map.position_aware_lift?
          if target = target_position_lift_percent100ths
            return true if target != current_position_lift_percent100ths
          end
        end
        if @feature_map.position_aware_tilt?
          if target = target_position_tilt_percent100ths
            return true if target != current_position_tilt_percent100ths
          end
        end
        false
      end

      private def sync_lift_percentage(position : UInt16?) : Nil
        self.current_position_lift_percentage = position.try { |value| (value // 100).to_u8 }
        target = target_position_lift_percent100ths
        return unless position && target && position == target
        return if lift_movement_status.stopped?

        set_movement_status(MovementStatus::Stopped, tilt_movement_status)
      end

      private def sync_tilt_percentage(position : UInt16?) : Nil
        self.current_position_tilt_percentage = position.try { |value| (value // 100).to_u8 }
        target = target_position_tilt_percent100ths
        return unless position && target && position == target
        return if tilt_movement_status.stopped?

        set_movement_status(lift_movement_status, MovementStatus::Stopped)
      end

      private def sync_mode_config_status(mode : Mode) : Nil
        status = @config_status
        if mode.maintenance_mode? || mode.calibration_mode?
          status &= ~ConfigStatus::Operational
        else
          status |= ConfigStatus::Operational
        end
        if mode.motor_direction_reversed?
          status |= ConfigStatus::LiftMovementReversed
        else
          status &= ~ConfigStatus::LiftMovementReversed
        end
        self.config_status = status
      end

      private def after_restore_state : Nil
        sync_mode_config_status(@mode)
        sync_lift_percentage(@current_position_lift_percent100ths)
        sync_tilt_percentage(@current_position_tilt_percent100ths)
      end

      private def move_lift_to(percentage : UInt16) : InteractionModel::Status
        status = admit_motion(MotionRequest.new(lift_target: percentage))
        return status unless status.success?
        self.target_position_lift_percent100ths = percentage if @feature_map.position_aware_lift?
        set_movement_status(movement_toward(current_position_lift_percent100ths, percentage),
          tilt_movement_status)
        settle_reached_targets
        InteractionModel::Status.success
      end

      private def settle_reached_targets : Nil
        if @feature_map.position_aware_lift? && !lift_movement_status.stopped?
          if target = target_position_lift_percent100ths
            if current_position_lift_percent100ths == target
              set_movement_status(MovementStatus::Stopped, tilt_movement_status)
            end
          end
        end
        if @feature_map.position_aware_tilt? && !tilt_movement_status.stopped?
          if target = target_position_tilt_percent100ths
            if current_position_tilt_percent100ths == target
              set_movement_status(lift_movement_status, MovementStatus::Stopped)
            end
          end
        end
      end

      private def admit_motion(request : MotionRequest) : InteractionModel::Status
        callback = @move_callback || return InteractionModel::Status.invalid_in_state
        callback.call(request)
      end

      private def movement_toward(current : UInt16?, target : UInt16) : MovementStatus
        return MovementStatus::Stopped unless current
        return MovementStatus::Closing if current < target
        return MovementStatus::Opening if current > target

        MovementStatus::Stopped
      end

      private def lift_movement_status : MovementStatus
        MovementStatus.new((operational_status.value >> LIFT_STATUS_SHIFT) & STATUS_FIELD_MASK)
      end

      private def tilt_movement_status : MovementStatus
        MovementStatus.new((operational_status.value >> TILT_STATUS_SHIFT) & STATUS_FIELD_MASK)
      end

      private def set_movement_status(lift : MovementStatus, tilt : MovementStatus) : Nil
        global = lift.stopped? ? tilt : lift
        encoded = global.value | (lift.value << LIFT_STATUS_SHIFT) | (tilt.value << TILT_STATUS_SHIFT)
        self.operational_status = OperationalStatus.new(encoded.to_u8)
      end
    end
  end
end
