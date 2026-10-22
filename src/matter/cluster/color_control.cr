require "./cluster"
require "./color_control/types"
require "./on_off"

module Matter
  module Cluster
    # Color Control Cluster Implementation (0x0300)
    #
    # Provides color control functionality for RGB and tunable white lights.
    # Supports multiple color modes: Hue/Saturation, XY, and Color Temperature.
    #
    # Features:
    # - HueSaturation (HS): Hue/saturation color specification
    # - EnhancedHue (EHUE): Enhanced 16-bit hue precision
    # - ColorLoop (CL): Color loop functionality
    # - XY: XY color space specification
    # - ColorTemperature (CT): Color temperature control
    #
    # Matter Spec: Application 3.2
    class ColorControl < Base
      cluster 0x0300, revision: 7

      MOVEMENT_TICK  = 100.milliseconds
      EXECUTE_IF_OFF = 1_u8

      feature :hue_saturation, bit: 0    # HS - Hue/saturation color specification
      feature :enhanced_hue, bit: 1      # EHUE - Enhanced 16-bit hue precision
      feature :color_loop, bit: 2        # CL - Color loop functionality
      feature :xy, bit: 3                # XY - XY color space specification
      feature :color_temperature, bit: 4 # CT - Color temperature control

      HUE_MODULUS          =     255
      SATURATION_MAXIMUM   = 254_u16
      ENHANCED_HUE_MODULUS =  65_536
      ENHANCED_HUE_SHIFT   =       8

      # Hue, saturation and xy chromaticity leave the top of their range unused
      HUE_MAXIMUM       =        254_u8
      CHROMATICITY_MAX  =    65_279_u16
      NO_TRANSITION     =         0_u16
      MIREDS_PER_KELVIN = 1_000_000_u32

      # Defaults for a tunable white light (mireds)
      DEFAULT_COLOR_TEMPERATURE_MIREDS = 250_u16 # 4000K
      DEFAULT_PHYSICAL_MIN_MIREDS      = 147_u16 # ~6800K
      DEFAULT_PHYSICAL_MAX_MIREDS      = 500_u16 # ~2000K
      PHYSICAL_MIN_MIREDS_LOWER_BOUND  =   1_u16

      # Color loop defaults from the specification
      DEFAULT_COLOR_LOOP_TIME       =     25_u16
      DEFAULT_COLOR_LOOP_START_HUE  = 0x2300_u16
      COLOR_LOOP_DIRECTION_DECREASE =       0_u8
      COLOR_LOOP_UPDATE_ACTION      =    0x01_u8
      COLOR_LOOP_UPDATE_DIRECTION   =    0x02_u8
      COLOR_LOOP_UPDATE_TIME        =    0x04_u8
      COLOR_LOOP_UPDATE_START_HUE   =    0x08_u8

      attribute 0x0000, :current_hue, UInt8, default: 0_u8, persist: true, scene: true, max: HUE_MAXIMUM, requires: :hue_saturation
      attribute 0x0001, :current_saturation, UInt8, default: 0_u8, persist: true, scene: true, max: HUE_MAXIMUM, requires: :hue_saturation
      attribute 0x0002, :remaining_time, UInt16, default: NO_TRANSITION, optional: true
      attribute 0x0003, :current_x, UInt16, default: 0_u16, persist: true, scene: true, max: CHROMATICITY_MAX, requires: :xy
      attribute 0x0004, :current_y, UInt16, default: 0_u16, persist: true, scene: true, max: CHROMATICITY_MAX, requires: :xy
      attribute 0x0007, :color_temperature_mireds, UInt16, default: DEFAULT_COLOR_TEMPERATURE_MIREDS, persist: true, scene: true, requires: :color_temperature
      attribute 0x0008, :color_mode, ColorMode, default: ColorMode::CurrentHueAndCurrentSaturation, persist: true
      attribute 0x000F, :options, UInt8, default: 0_u8, writable: true
      attribute 0x0010, :number_of_primaries, UInt8, nullable: true, fixed: true
      attribute 0x4000, :enhanced_current_hue, UInt16, default: 0_u16, persist: true, scene: true, requires: :enhanced_hue
      attribute 0x4001, :enhanced_color_mode, EnhancedColorMode, default: EnhancedColorMode::CurrentHueAndCurrentSaturation, persist: true, scene: true
      attribute 0x4002, :color_loop_active, Bool, default: false, persist: true, scene: true, requires: :color_loop
      attribute 0x4003, :color_loop_direction, UInt8, default: COLOR_LOOP_DIRECTION_DECREASE, persist: true, scene: true, requires: :color_loop
      attribute 0x4004, :color_loop_time, UInt16, default: DEFAULT_COLOR_LOOP_TIME, persist: true, scene: true, requires: :color_loop
      attribute 0x4005, :color_loop_start_enhanced_hue, UInt16, default: DEFAULT_COLOR_LOOP_START_HUE, requires: :color_loop
      attribute 0x4006, :color_loop_stored_enhanced_hue, UInt16, default: 0_u16, requires: :color_loop
      attribute 0x400A, :color_capabilities, UInt16, default: 0_u16
      attribute 0x400B, :color_temp_physical_min_mireds, UInt16, default: DEFAULT_PHYSICAL_MIN_MIREDS, min: PHYSICAL_MIN_MIREDS_LOWER_BOUND, max: CHROMATICITY_MAX, requires: :color_temperature
      attribute 0x400C, :color_temp_physical_max_mireds, UInt16, default: DEFAULT_PHYSICAL_MAX_MIREDS, max: CHROMATICITY_MAX, requires: :color_temperature
      attribute 0x400D, :couple_color_temp_to_level_min_mireds, UInt16, nullable: true, optional: true, requires: :color_temperature
      attribute 0x4010, :start_up_color_temperature_mireds, UInt16, nullable: true, writable: true, optional: true, min: PHYSICAL_MIN_MIREDS_LOWER_BOUND, max: CHROMATICITY_MAX, requires: :color_temperature

      command 0x00, :move_to_hue, request: MoveToHueRequest, requires: :hue_saturation
      command 0x01, :move_hue, request: MoveHueRequest, requires: :hue_saturation
      command 0x02, :step_hue, request: StepHueRequest, requires: :hue_saturation
      command 0x03, :move_to_saturation, request: MoveToSaturationRequest, requires: :hue_saturation
      command 0x04, :move_saturation, request: MoveSaturationRequest, requires: :hue_saturation
      command 0x05, :step_saturation, request: StepSaturationRequest, requires: :hue_saturation
      command 0x06, :move_to_hue_and_saturation, request: MoveToHueAndSaturationRequest, requires: :hue_saturation
      command 0x07, :move_to_color, request: MoveToColorRequest, requires: :xy
      command 0x08, :move_color, request: MoveColorRequest, requires: :xy
      command 0x09, :step_color, request: StepColorRequest, requires: :xy
      command 0x0A, :move_to_color_temperature, request: MoveToColorTemperatureRequest, requires: :color_temperature
      command 0x40, :enhanced_move_to_hue, request: EnhancedMoveToHueRequest, requires: :enhanced_hue
      command 0x41, :enhanced_move_hue, request: EnhancedMoveHueRequest, requires: :enhanced_hue
      command 0x42, :enhanced_step_hue, request: EnhancedStepHueRequest, requires: :enhanced_hue
      command 0x43, :enhanced_move_to_hue_and_saturation, request: EnhancedMoveToHueAndSaturationRequest, requires: :enhanced_hue
      command 0x44, :color_loop_set, request: ColorLoopSetRequest, requires: :color_loop
      command 0x47, :stop_move_step, request: StopMoveStepRequest, requires: [:hue_saturation, :xy, :color_temperature]
      command 0x4B, :move_color_temperature, request: MoveColorTemperatureRequest, requires: :color_temperature
      command 0x4C, :step_color_temperature, request: StepColorTemperatureRequest, requires: :color_temperature

      # Fired after any colour attribute changes
      @on_color_changed : Proc(Nil)?

      def initialize(
        endpoint_id : DataType::EndpointNumber,
        @feature_map : Feature = Feature::HueSaturation | Feature::Xy | Feature::ColorTemperature,
        @current_hue : UInt8 = 0_u8,
        @current_saturation : UInt8 = 0_u8,
        @current_x : UInt16 = 0_u16,
        @current_y : UInt16 = 0_u16,
        @color_temperature_mireds : UInt16 = DEFAULT_COLOR_TEMPERATURE_MIREDS,
        @color_temp_physical_min_mireds : UInt16 = DEFAULT_PHYSICAL_MIN_MIREDS,
        @color_temp_physical_max_mireds : UInt16 = DEFAULT_PHYSICAL_MAX_MIREDS,
        @color_mode : ColorMode = ColorMode::CurrentHueAndCurrentSaturation,
        @options : UInt8 = 0_u8,
      )
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))

        @enhanced_current_hue = @current_hue.to_u16 << ENHANCED_HUE_SHIFT
        # ColorCapabilities mirrors the feature map bit for bit
        @color_capabilities = @feature_map.value.to_u16
        @movement = nil
        @transition = nil
        @movement_fiber_running = false
        @on_off_cluster = nil
      end

      private enum MovementKind
        Hue
        HueSaturation
        EnhancedHue
        EnhancedHueSaturation
        ColorLoop
        Saturation
        Xy
        ColorTemperature
      end

      private class TimedTransition
        getter kind : MovementKind
        getter started_at : Time::Instant
        property last_advanced_at : Time::Instant
        getter origin_x : Int32
        getter origin_y : Int32
        getter delta_x : Int32
        getter delta_y : Int32
        getter target_x : Int32
        getter target_y : Int32
        getter duration : UInt16

        def initialize(@kind : MovementKind, @started_at : Time::Instant,
                       @origin_x : Int32, @origin_y : Int32,
                       @delta_x : Int32, @delta_y : Int32,
                       @target_x : Int32, @target_y : Int32, @duration : UInt16)
          @last_advanced_at = @started_at
        end
      end

      private class Movement
        getter kind : MovementKind
        getter started_at : Time::Instant
        property last_advanced_at : Time::Instant
        getter origin_x : Int32
        getter origin_y : Int32
        getter rate_x : Int32
        getter rate_y : Int32
        getter min_x : Int32
        getter max_x : Int32

        def initialize(@kind : MovementKind, @started_at : Time::Instant,
                       @origin_x : Int32, @origin_y : Int32,
                       @rate_x : Int32, @rate_y : Int32,
                       @min_x : Int32, @max_x : Int32)
          @last_advanced_at = @started_at
        end
      end

      @movement : Movement?
      @transition : TimedTransition?
      @movement_fiber_running : Bool
      @on_off_cluster : OnOff?

      # The endpoint links a sibling OnOff cluster regardless of add order.
      def bind_on_off(cluster : OnOff?) : Nil
        @on_off_cluster = cluster
      end

      # ------------------------------------------------------------------------
      # Commands
      # ------------------------------------------------------------------------

      def move_to_hue(request : MoveToHueRequest) : InteractionModel::Status
        return InteractionModel::Status.constraint_error if request.hue > HUE_MAXIMUM || request.transition_time == UInt16::MAX
        return InteractionModel::Status.success unless execute_if_off?(request.mask, request.override)
        start_transition(MovementKind::Hue, request.hue.to_i, 0, request.transition_time, request.direction)
      end

      def move_hue(request : MoveHueRequest) : InteractionModel::Status
        return InteractionModel::Status.success unless execute_if_off?(request.mask, request.override)
        case request.move_mode
        when .stop?
          stop_movement
        when .up?, .down?
          return InteractionModel::Status.invalid_command if request.rate == 0
          rate = request.move_mode.up? ? request.rate.to_i : -request.rate.to_i
          start_movement(MovementKind::Hue, rate, 0, 0, HUE_MAXIMUM.to_i)
        else
          InteractionModel::Status.invalid_command
        end
      end

      def step_hue(request : StepHueRequest) : InteractionModel::Status
        return InteractionModel::Status.success unless execute_if_off?(request.mask, request.override)
        advance_movement
        case request.step_mode
        in .up?
          target = (@current_hue.to_i + request.step_size) % HUE_MODULUS
          start_transition(MovementKind::Hue, target, 0, request.transition_time.to_u16, Direction::Up)
        in .down?
          target = (@current_hue.to_i - request.step_size) % HUE_MODULUS
          start_transition(MovementKind::Hue, target, 0, request.transition_time.to_u16, Direction::Down)
        end
      end

      def move_to_saturation(request : MoveToSaturationRequest) : InteractionModel::Status
        return InteractionModel::Status.constraint_error if request.saturation > SATURATION_MAXIMUM || request.transition_time == UInt16::MAX
        return InteractionModel::Status.success unless execute_if_off?(request.mask, request.override)
        start_transition(MovementKind::Saturation, request.saturation.to_i, 0, request.transition_time)
      end

      def move_saturation(request : MoveSaturationRequest) : InteractionModel::Status
        return InteractionModel::Status.success unless execute_if_off?(request.mask, request.override)
        case request.move_mode
        when .stop?
          stop_movement
        when .up?, .down?
          return InteractionModel::Status.invalid_command if request.rate == 0
          rate = request.move_mode.up? ? request.rate.to_i : -request.rate.to_i
          start_movement(MovementKind::Saturation, rate, 0, 0, HUE_MAXIMUM.to_i)
        else
          InteractionModel::Status.invalid_command
        end
      end

      def step_saturation(request : StepSaturationRequest) : InteractionModel::Status
        return InteractionModel::Status.success unless execute_if_off?(request.mask, request.override)
        advance_movement
        case request.step_mode
        in .up?
          target = Math.min(@current_saturation.to_u16 + request.step_size, SATURATION_MAXIMUM).to_i
          start_transition(MovementKind::Saturation, target, 0, request.transition_time.to_u16)
        in .down?
          target = Math.max(@current_saturation.to_i16 - request.step_size, 0_i16).to_i
          start_transition(MovementKind::Saturation, target, 0, request.transition_time.to_u16)
        end
      end

      def move_to_hue_and_saturation(request : MoveToHueAndSaturationRequest) : InteractionModel::Status
        return InteractionModel::Status.constraint_error if request.hue > HUE_MAXIMUM || request.saturation > SATURATION_MAXIMUM || request.transition_time == UInt16::MAX
        return InteractionModel::Status.success unless execute_if_off?(request.mask, request.override)
        start_transition(MovementKind::HueSaturation, request.hue.to_i, request.saturation.to_i, request.transition_time)
      end

      def move_to_color(request : MoveToColorRequest) : InteractionModel::Status
        return InteractionModel::Status.constraint_error if request.x > CHROMATICITY_MAX || request.y > CHROMATICITY_MAX || request.transition_time == UInt16::MAX
        return InteractionModel::Status.success unless execute_if_off?(request.mask, request.override)
        start_transition(MovementKind::Xy, request.x.to_i, request.y.to_i, request.transition_time)
      end

      def move_color(request : MoveColorRequest) : InteractionModel::Status
        return InteractionModel::Status.success unless execute_if_off?(request.mask, request.override)
        return stop_movement if request.x == 0 && request.y == 0
        start_movement(MovementKind::Xy, request.x.to_i, request.y.to_i, 0, CHROMATICITY_MAX.to_i)
      end

      def step_color(request : StepColorRequest) : InteractionModel::Status
        return InteractionModel::Status.constraint_error if request.transition_time == UInt16::MAX
        return InteractionModel::Status.success unless execute_if_off?(request.mask, request.override)
        advance_movement
        start_transition(MovementKind::Xy,
          step_chromaticity(@current_x, request.x).to_i,
          step_chromaticity(@current_y, request.y).to_i, request.transition_time)
      end

      def move_to_color_temperature(request : MoveToColorTemperatureRequest) : InteractionModel::Status
        return InteractionModel::Status.constraint_error if request.color_temperature_mireds > CHROMATICITY_MAX || request.transition_time == UInt16::MAX
        return InteractionModel::Status.success unless execute_if_off?(request.mask, request.override)
        start_transition(MovementKind::ColorTemperature, request.color_temperature_mireds.to_i, 0, request.transition_time)
      end

      def move_color_temperature(request : MoveColorTemperatureRequest) : InteractionModel::Status
        return InteractionModel::Status.success unless execute_if_off?(request.mask, request.override)
        return stop_movement if request.move_mode.stop?
        return InteractionModel::Status.invalid_command if request.rate == 0

        minimum = request.color_temperature_minimum_mireds == 0 ? @color_temp_physical_min_mireds : request.color_temperature_minimum_mireds.clamp(@color_temp_physical_min_mireds, @color_temp_physical_max_mireds)
        maximum = request.color_temperature_maximum_mireds == 0 ? @color_temp_physical_max_mireds : request.color_temperature_maximum_mireds.clamp(@color_temp_physical_min_mireds, @color_temp_physical_max_mireds)
        return InteractionModel::Status.constraint_error if minimum > maximum

        case request.move_mode
        when .up?, .down?
          rate = request.move_mode.up? ? request.rate.to_i : -request.rate.to_i
          start_movement(MovementKind::ColorTemperature, rate, 0, minimum.to_i, maximum.to_i)
        else
          InteractionModel::Status.invalid_command
        end
      end

      def step_color_temperature(request : StepColorTemperatureRequest) : InteractionModel::Status
        return InteractionModel::Status.constraint_error if request.transition_time == UInt16::MAX
        minimum = request.color_temperature_minimum_mireds == 0 ? @color_temp_physical_min_mireds : request.color_temperature_minimum_mireds.clamp(@color_temp_physical_min_mireds, @color_temp_physical_max_mireds)
        maximum = request.color_temperature_maximum_mireds == 0 ? @color_temp_physical_max_mireds : request.color_temperature_maximum_mireds.clamp(@color_temp_physical_min_mireds, @color_temp_physical_max_mireds)
        return InteractionModel::Status.constraint_error if minimum > maximum
        return InteractionModel::Status.success unless execute_if_off?(request.mask, request.override)
        advance_movement
        case request.step_mode
        in .up?
          target = (@color_temperature_mireds.to_u32 + request.step_size).clamp(minimum.to_u32, maximum.to_u32).to_i
          start_transition(MovementKind::ColorTemperature, target, 0, request.transition_time)
        in .down?
          target = (@color_temperature_mireds.to_i32 - request.step_size).clamp(minimum.to_i32, maximum.to_i32).to_i
          start_transition(MovementKind::ColorTemperature, target, 0, request.transition_time)
        end
      end

      def enhanced_move_to_hue(request : EnhancedMoveToHueRequest) : InteractionModel::Status
        return InteractionModel::Status.constraint_error if request.transition_time == UInt16::MAX
        return InteractionModel::Status.success unless execute_if_off?(request.mask, request.override)
        start_transition(MovementKind::EnhancedHue, request.enhanced_hue.to_i, 0, request.transition_time, request.direction)
      end

      def enhanced_move_hue(request : EnhancedMoveHueRequest) : InteractionModel::Status
        return InteractionModel::Status.success unless execute_if_off?(request.mask, request.override)
        case request.move_mode
        when .stop?
          stop_movement
        when .up?, .down?
          return InteractionModel::Status.invalid_command if request.rate == 0
          rate = request.move_mode.up? ? request.rate.to_i : -request.rate.to_i
          start_movement(MovementKind::EnhancedHue, rate, 0, 0, ENHANCED_HUE_MODULUS - 1)
        else
          InteractionModel::Status.invalid_command
        end
      end

      def enhanced_step_hue(request : EnhancedStepHueRequest) : InteractionModel::Status
        return InteractionModel::Status.constraint_error if request.transition_time == UInt16::MAX
        return InteractionModel::Status.success unless execute_if_off?(request.mask, request.override)
        advance_movement
        case request.step_mode
        in .up?
          target = (@enhanced_current_hue.to_i + request.step_size) % ENHANCED_HUE_MODULUS
          start_transition(MovementKind::EnhancedHue, target, 0, request.transition_time, Direction::Up)
        in .down?
          target = (@enhanced_current_hue.to_i - request.step_size) % ENHANCED_HUE_MODULUS
          start_transition(MovementKind::EnhancedHue, target, 0, request.transition_time, Direction::Down)
        end
      end

      def enhanced_move_to_hue_and_saturation(request : EnhancedMoveToHueAndSaturationRequest) : InteractionModel::Status
        return InteractionModel::Status.constraint_error if request.saturation > SATURATION_MAXIMUM || request.transition_time == UInt16::MAX
        return InteractionModel::Status.success unless execute_if_off?(request.mask, request.override)
        start_transition(MovementKind::EnhancedHueSaturation, request.enhanced_hue.to_i, request.saturation.to_i, request.transition_time)
      end

      def color_loop_set(request : ColorLoopSetRequest) : InteractionModel::Status
        return InteractionModel::Status.success unless execute_if_off?(request.mask, request.override)

        flags = request.update_flag
        update_direction = (flags & COLOR_LOOP_UPDATE_DIRECTION) != 0
        update_time = (flags & COLOR_LOOP_UPDATE_TIME) != 0
        update_action = (flags & COLOR_LOOP_UPDATE_ACTION) != 0
        will_activate = update_action && !request.action.de_activate_the_color_loop?
        will_reconfigure = !update_action && color_loop_active? && (update_direction || update_time)
        effective_time = update_time ? request.time : @color_loop_time
        return InteractionModel::Status.invalid_command if (will_activate || will_reconfigure) && effective_time == 0

        advance_movement if color_loop_active?
        self.color_loop_direction = request.direction.value if update_direction
        self.color_loop_time = request.time if update_time
        self.color_loop_start_enhanced_hue = request.start_hue if (flags & COLOR_LOOP_UPDATE_START_HUE) != 0

        if update_action
          case request.action
          when .de_activate_the_color_loop?
            if color_loop_active?
              stop_movement
              move_to_enhanced_hue(@color_loop_stored_enhanced_hue)
            end
          when .activate_the_color_loop_from_the_value_in_the_color_loop_start_enhanced_hue_field?,
               .activate_the_color_loop_from_the_value_of_the_enhanced_current_hue_attribute?
            stop_movement
            self.color_loop_stored_enhanced_hue = @enhanced_current_hue
            self.color_loop_active = true
            if request.action.activate_the_color_loop_from_the_value_in_the_color_loop_start_enhanced_hue_field?
              move_to_enhanced_hue(@color_loop_start_enhanced_hue)
            end
            start_color_loop
          end
        elsif color_loop_active? && (update_direction || update_time)
          start_color_loop
        end
        InteractionModel::Status.success
      end

      def stop_move_step(request : StopMoveStepRequest) : InteractionModel::Status
        return InteractionModel::Status.success unless execute_if_off?(request.mask, request.override)
        return InteractionModel::Status.success if color_loop_active?
        stop_movement
      end

      private def execute_if_off?(mask : UInt8, override : UInt8) : Bool
        on_off = @on_off_cluster
        return true unless on_off && on_off.off?

        effective_options = (@options & ~mask) | (override & mask)
        (effective_options & EXECUTE_IF_OFF) != 0
      end

      # Advances a continuous move using a monotonic clock. Public for
      # deterministic platform clocks and tests; a fiber advances it normally.
      def advance_movement(now : Time::Instant = Time.instant) : Nil
        if transition = @transition
          advance_transition(transition, now)
          return
        end
        movement = @movement
        return unless movement
        return if now <= movement.last_advanced_at

        movement.last_advanced_at = now
        elapsed = (now - movement.started_at).total_seconds
        x = movement.origin_x + (movement.rate_x * elapsed).trunc.to_i
        y = movement.origin_y + (movement.rate_y * elapsed).trunc.to_i

        case movement.kind
        when .hue?
          hue = ((x % HUE_MODULUS) + HUE_MODULUS) % HUE_MODULUS
          move_to_hue(hue.to_u8)
        when .enhanced_hue?
          enhanced_hue = ((x % ENHANCED_HUE_MODULUS) + ENHANCED_HUE_MODULUS) % ENHANCED_HUE_MODULUS
          move_to_enhanced_hue(enhanced_hue.to_u16)
        when .color_loop?
          phase = elapsed % @color_loop_time.to_f64
          progress = (ENHANCED_HUE_MODULUS * phase / @color_loop_time).trunc.to_i
          enhanced_hue = (movement.origin_x + movement.rate_x * progress) % ENHANCED_HUE_MODULUS
          move_to_enhanced_hue(((enhanced_hue + ENHANCED_HUE_MODULUS) % ENHANCED_HUE_MODULUS).to_u16)
        when .saturation?
          level = x.clamp(movement.min_x, movement.max_x)
          move_to_saturation(level.to_u8)
          @movement = nil if movement_limit_reached?(level, movement.rate_x, movement.min_x, movement.max_x)
        when .xy?
          new_x = x.clamp(movement.min_x, movement.max_x)
          new_y = y.clamp(movement.min_x, movement.max_x)
          move_to_color(new_x.to_u16, new_y.to_u16)
          if movement_limit_reached?(new_x, movement.rate_x, movement.min_x, movement.max_x) &&
             movement_limit_reached?(new_y, movement.rate_y, movement.min_x, movement.max_x)
            @movement = nil
          end
        when .color_temperature?
          mireds = x.clamp(movement.min_x, movement.max_x)
          move_to_color_temperature(mireds.to_u16)
          @movement = nil if movement_limit_reached?(mireds, movement.rate_x, movement.min_x, movement.max_x)
        end
        self.remaining_time = NO_TRANSITION unless @movement
      end

      # Timed commands share the same monotonic movement scheduler as continuous
      # commands. Their duration is in deciseconds, as encoded on the wire.
      private def start_transition(kind : MovementKind, requested_x : Int32, requested_y : Int32,
                                   duration : UInt16, direction : Direction = Direction::ShortestDistance) : InteractionModel::Status
        return InteractionModel::Status.constraint_error if duration == UInt16::MAX
        stop_movement
        origin_x, origin_y, target_x, target_y = transition_endpoints(kind, requested_x, requested_y)
        select_color_mode(kind)
        delta_x = if kind.hue? || kind.hue_saturation?
                    hue_delta(origin_x, target_x, direction, HUE_MODULUS)
                  elsif kind.enhanced_hue? || kind.enhanced_hue_saturation?
                    hue_delta(origin_x, target_x, direction, ENHANCED_HUE_MODULUS)
                  else
                    target_x - origin_x
                  end
        delta_y = target_y - origin_y
        if duration == NO_TRANSITION || (delta_x == 0 && delta_y == 0)
          apply_transition_value(kind, target_x, target_y)
          return InteractionModel::Status.success
        end

        self.color_loop_active = false if color_loop_active?
        @transition = TimedTransition.new(kind, Time.instant, origin_x, origin_y,
          delta_x, delta_y, target_x, target_y, duration)
        self.remaining_time = duration
        start_movement_fiber
        InteractionModel::Status.success
      end

      private def transition_endpoints(kind : MovementKind, requested_x : Int32, requested_y : Int32) : {Int32, Int32, Int32, Int32}
        case kind
        when .hue?, .hue_saturation?
          {@current_hue.to_i, @current_saturation.to_i,
           requested_x.clamp(0, HUE_MAXIMUM.to_i), requested_y.clamp(0, SATURATION_MAXIMUM.to_i)}
        when .enhanced_hue?, .enhanced_hue_saturation?
          {@enhanced_current_hue.to_i, @current_saturation.to_i,
           requested_x.clamp(0, ENHANCED_HUE_MODULUS - 1), requested_y.clamp(0, SATURATION_MAXIMUM.to_i)}
        when .saturation?
          {@current_saturation.to_i, 0, requested_x.clamp(0, SATURATION_MAXIMUM.to_i), 0}
        when .xy?
          {@current_x.to_i, @current_y.to_i,
           requested_x.clamp(0, CHROMATICITY_MAX.to_i), requested_y.clamp(0, CHROMATICITY_MAX.to_i)}
        when .color_temperature?
          {@color_temperature_mireds.to_i, 0,
           requested_x.clamp(@color_temp_physical_min_mireds.to_i, @color_temp_physical_max_mireds.to_i), 0}
        when .color_loop?
          {@enhanced_current_hue.to_i, 0, requested_x, 0}
        else
          {0, 0, requested_x, requested_y}
        end
      end

      private def hue_delta(origin : Int32, target : Int32, direction : Direction, modulus : Int32) : Int32
        upward = (target - origin + modulus) % modulus
        return 0 if upward == 0
        downward = upward - modulus
        case direction
        in .up?                then upward
        in .down?              then downward
        in .shortest_distance? then upward <= -downward ? upward : downward
        in .longest_distance?  then upward > -downward ? upward : downward
        end
      end

      private def advance_transition(transition : TimedTransition, now : Time::Instant) : Nil
        return if now <= transition.last_advanced_at
        transition.last_advanced_at = now
        elapsed_deciseconds = (now - transition.started_at).total_seconds * 10

        progress = (elapsed_deciseconds / transition.duration).clamp(0.0, 1.0)
        completed = progress >= 1.0
        x = completed ? transition.target_x : transition.origin_x + (transition.delta_x * progress).trunc.to_i
        y = completed ? transition.target_y : transition.origin_y + (transition.delta_y * progress).trunc.to_i
        apply_transition_value(transition.kind, x, y)
        return unless @transition == transition
        if completed
          @transition = nil
          self.remaining_time = NO_TRANSITION
        else
          self.remaining_time = (transition.duration - elapsed_deciseconds).ceil.to_u16
        end
      end

      private def apply_transition_value(kind : MovementKind, x : Int32, y : Int32) : InteractionModel::Status
        case kind
        when .hue?
          move_to_hue((((x % HUE_MODULUS) + HUE_MODULUS) % HUE_MODULUS).to_u8)
        when .enhanced_hue?
          move_to_enhanced_hue((((x % ENHANCED_HUE_MODULUS) + ENHANCED_HUE_MODULUS) % ENHANCED_HUE_MODULUS).to_u16)
        when .hue_saturation?
          hue = (((x % HUE_MODULUS) + HUE_MODULUS) % HUE_MODULUS).to_u8
          return InteractionModel::Status.success if @current_hue == hue && @current_saturation == y &&
                                                     @color_mode == ColorMode::CurrentHueAndCurrentSaturation &&
                                                     @enhanced_color_mode == EnhancedColorMode::CurrentHueAndCurrentSaturation
          self.current_hue = hue
          self.enhanced_current_hue = @current_hue.to_u16 << ENHANCED_HUE_SHIFT
          self.current_saturation = y.to_u8
          color_changed(ColorMode::CurrentHueAndCurrentSaturation, EnhancedColorMode::CurrentHueAndCurrentSaturation)
        when .enhanced_hue_saturation?
          hue = (((x % ENHANCED_HUE_MODULUS) + ENHANCED_HUE_MODULUS) % ENHANCED_HUE_MODULUS).to_u16
          return InteractionModel::Status.success if @enhanced_current_hue == hue && @current_saturation == y &&
                                                     @color_mode == ColorMode::CurrentHueAndCurrentSaturation &&
                                                     @enhanced_color_mode == EnhancedColorMode::EnhancedCurrentHueAndCurrentSaturation
          self.enhanced_current_hue = hue
          self.current_hue = (@enhanced_current_hue >> ENHANCED_HUE_SHIFT).to_u8
          self.current_saturation = y.to_u8
          color_changed(ColorMode::CurrentHueAndCurrentSaturation, EnhancedColorMode::EnhancedCurrentHueAndCurrentSaturation)
        when .saturation?
          move_to_saturation(x.to_u8)
        when .xy?
          move_to_color(x.to_u16, y.to_u16)
        when .color_temperature?
          move_to_color_temperature(x.to_u16)
        when .color_loop?
          move_to_enhanced_hue(x.to_u16)
        else
          InteractionModel::Status.success
        end
      end

      private def movement_limit_reached?(value : Int32, rate : Int32, minimum : Int32, maximum : Int32) : Bool
        rate == 0 || (rate > 0 && value >= maximum) || (rate < 0 && value <= minimum)
      end

      private def start_movement(kind : MovementKind, rate_x : Int32, rate_y : Int32,
                                 minimum : Int32, maximum : Int32) : InteractionModel::Status
        advance_movement
        @transition = nil
        self.remaining_time = NO_TRANSITION
        origin_x = case kind
                   in .hue?                        then @current_hue.to_i
                   in .hue_saturation?             then @current_hue.to_i
                   in .enhanced_hue?, .color_loop? then @enhanced_current_hue.to_i
                   in .enhanced_hue_saturation?    then @enhanced_current_hue.to_i
                   in .saturation?                 then @current_saturation.to_i
                   in .xy?                         then @current_x.to_i
                   in .color_temperature?          then @color_temperature_mireds.to_i
                   end
        origin_y = kind.xy? ? @current_y.to_i : 0
        self.color_loop_active = false if !kind.color_loop? && color_loop_active?
        @movement = Movement.new(kind, Time.instant, origin_x, origin_y,
          rate_x, rate_y, minimum, maximum)
        select_color_mode(kind)
        start_movement_fiber
        InteractionModel::Status.success
      end

      private def select_color_mode(kind : MovementKind) : Nil
        mode = case kind
               when .xy?                then ColorMode::CurrentXAndCurrentY
               when .color_temperature? then ColorMode::ColorTemperatureMireds
               else                          ColorMode::CurrentHueAndCurrentSaturation
               end
        enhanced_mode = case kind
                        when .xy?                then EnhancedColorMode::CurrentXAndCurrentY
                        when .color_temperature? then EnhancedColorMode::ColorTemperatureMireds
                        when .enhanced_hue?, .enhanced_hue_saturation?, .color_loop?
                          EnhancedColorMode::EnhancedCurrentHueAndCurrentSaturation
                        else EnhancedColorMode::CurrentHueAndCurrentSaturation
                        end
        color_changed(mode, enhanced_mode) unless @color_mode == mode && @enhanced_color_mode == enhanced_mode
        nil
      end

      private def stop_movement : InteractionModel::Status
        advance_movement
        self.color_loop_active = false if @movement.try(&.kind.color_loop?)
        @movement = nil
        @transition = nil
        self.remaining_time = NO_TRANSITION
        InteractionModel::Status.success
      end

      private def start_color_loop : Nil
        direction = @color_loop_direction == COLOR_LOOP_DIRECTION_DECREASE ? -1 : 1
        start_movement(MovementKind::ColorLoop, direction, 0, 0, ENHANCED_HUE_MODULUS - 1)
        nil
      end

      private def start_movement_fiber : Nil
        return if @movement_fiber_running
        @movement_fiber_running = true
        spawn do
          while @movement || @transition
            sleep MOVEMENT_TICK
            advance_movement
          end
        ensure
          @movement_fiber_running = false
        end
      end

      # ------------------------------------------------------------------------
      # Public Interface
      # ------------------------------------------------------------------------

      def on_color_changed(&block : -> Nil) : Nil
        @on_color_changed = block
      end

      def color_temperature_kelvin : UInt32
        MIREDS_PER_KELVIN // @color_temperature_mireds
      end

      def color_temperature_kelvin=(kelvin : UInt32) : InteractionModel::Status
        move_to_color_temperature((MIREDS_PER_KELVIN // kelvin).to_u16)
      end

      # ------------------------------------------------------------------------
      # Colour changes
      # ------------------------------------------------------------------------

      private def move_to_hue(hue : UInt8) : InteractionModel::Status
        return InteractionModel::Status.success if @current_hue == hue

        self.current_hue = hue
        self.enhanced_current_hue = hue.to_u16 << ENHANCED_HUE_SHIFT
        color_changed(ColorMode::CurrentHueAndCurrentSaturation, EnhancedColorMode::CurrentHueAndCurrentSaturation)
      end

      private def move_to_saturation(saturation : UInt8) : InteractionModel::Status
        return InteractionModel::Status.success if @current_saturation == saturation

        self.current_saturation = saturation
        color_changed(ColorMode::CurrentHueAndCurrentSaturation, EnhancedColorMode::CurrentHueAndCurrentSaturation)
      end

      private def move_to_color(x : UInt16, y : UInt16) : InteractionModel::Status
        return InteractionModel::Status.success if @current_x == x && @current_y == y

        self.current_x = x
        self.current_y = y
        color_changed(ColorMode::CurrentXAndCurrentY, EnhancedColorMode::CurrentXAndCurrentY)
      end

      private def move_to_color_temperature(mireds : UInt16) : InteractionModel::Status
        return InteractionModel::Status.success if @color_temperature_mireds == mireds

        self.color_temperature_mireds = mireds.clamp(@color_temp_physical_min_mireds, @color_temp_physical_max_mireds)
        color_changed(ColorMode::ColorTemperatureMireds, EnhancedColorMode::ColorTemperatureMireds)
      end

      private def move_to_enhanced_hue(enhanced_hue : UInt16) : InteractionModel::Status
        return InteractionModel::Status.success if @enhanced_current_hue == enhanced_hue

        self.enhanced_current_hue = enhanced_hue
        self.current_hue = (enhanced_hue >> ENHANCED_HUE_SHIFT).to_u8
        color_changed(ColorMode::CurrentHueAndCurrentSaturation, EnhancedColorMode::EnhancedCurrentHueAndCurrentSaturation)
      end

      # Records the mode the colour was last set in and notifies the device
      private def color_changed(mode : ColorMode, enhanced_mode : EnhancedColorMode) : InteractionModel::Status
        self.color_mode = mode
        self.enhanced_color_mode = enhanced_mode
        self.remaining_time = NO_TRANSITION unless @transition
        @on_color_changed.try &.call
        InteractionModel::Status.success
      end

      private def step_chromaticity(current : UInt16, step : Int16) : UInt16
        (current.to_i32 + step).clamp(0, CHROMATICITY_MAX.to_i).to_u16
      end
    end
  end
end
