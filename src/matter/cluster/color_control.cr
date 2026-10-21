require "./cluster"
require "./color_control/types"

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

      MOVEMENT_TICK = 100.milliseconds

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
        @movement_fiber_running = false
      end

      private enum MovementKind
        Hue
        Saturation
        Xy
        ColorTemperature
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
      @movement_fiber_running : Bool

      # ------------------------------------------------------------------------
      # Commands
      # ------------------------------------------------------------------------

      def move_to_hue(request : MoveToHueRequest) : InteractionModel::Status
        stop_movement
        move_to_hue(request.hue)
      end

      def move_hue(request : MoveHueRequest) : InteractionModel::Status
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
        stop_movement
        case request.step_mode
        in .up?
          move_to_hue(((@current_hue.to_u16 + request.step_size) % HUE_MODULUS).to_u8)
        in .down?
          move_to_hue(((@current_hue.to_i16 - request.step_size) % HUE_MODULUS).to_u8)
        end
      end

      def move_to_saturation(request : MoveToSaturationRequest) : InteractionModel::Status
        stop_movement
        move_to_saturation(request.saturation)
      end

      def move_saturation(request : MoveSaturationRequest) : InteractionModel::Status
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
        stop_movement
        case request.step_mode
        in .up?
          move_to_saturation(Math.min(@current_saturation.to_u16 + request.step_size, SATURATION_MAXIMUM).to_u8)
        in .down?
          move_to_saturation(Math.max(@current_saturation.to_i16 - request.step_size, 0_i16).to_u8)
        end
      end

      def move_to_hue_and_saturation(request : MoveToHueAndSaturationRequest) : InteractionModel::Status
        stop_movement
        self.current_hue = request.hue
        self.current_saturation = request.saturation
        self.enhanced_current_hue = request.hue.to_u16 << ENHANCED_HUE_SHIFT
        color_changed(ColorMode::CurrentHueAndCurrentSaturation, EnhancedColorMode::CurrentHueAndCurrentSaturation)
      end

      def move_to_color(request : MoveToColorRequest) : InteractionModel::Status
        stop_movement
        move_to_color(request.x, request.y)
      end

      def move_color(request : MoveColorRequest) : InteractionModel::Status
        return stop_movement if request.x == 0 && request.y == 0
        start_movement(MovementKind::Xy, request.x.to_i, request.y.to_i, 0, CHROMATICITY_MAX.to_i)
      end

      def step_color(request : StepColorRequest) : InteractionModel::Status
        stop_movement
        move_to_color(step_chromaticity(@current_x, request.x), step_chromaticity(@current_y, request.y))
      end

      def move_to_color_temperature(request : MoveToColorTemperatureRequest) : InteractionModel::Status
        stop_movement
        move_to_color_temperature(request.color_temperature_mireds)
      end

      def move_color_temperature(request : MoveColorTemperatureRequest) : InteractionModel::Status
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
        stop_movement
        case request.step_mode
        in .up?
          move_to_color_temperature(Math.min(@color_temperature_mireds.to_u32 + request.step_size, @color_temp_physical_max_mireds.to_u32).to_u16)
        in .down?
          move_to_color_temperature(Math.max(@color_temperature_mireds.to_i32 - request.step_size, @color_temp_physical_min_mireds.to_i32).to_u16)
        end
      end

      def enhanced_move_to_hue(request : EnhancedMoveToHueRequest) : InteractionModel::Status
        stop_movement
        move_to_enhanced_hue(request.enhanced_hue)
      end

      def enhanced_move_hue(request : EnhancedMoveHueRequest) : InteractionModel::Status
        InteractionModel::Status.success
      end

      def enhanced_step_hue(request : EnhancedStepHueRequest) : InteractionModel::Status
        stop_movement
        case request.step_mode
        in .up?
          move_to_enhanced_hue(((@enhanced_current_hue.to_u32 + request.step_size) % ENHANCED_HUE_MODULUS).to_u16)
        in .down?
          move_to_enhanced_hue(((@enhanced_current_hue.to_i32 - request.step_size) % ENHANCED_HUE_MODULUS).to_u16)
        end
      end

      def enhanced_move_to_hue_and_saturation(request : EnhancedMoveToHueAndSaturationRequest) : InteractionModel::Status
        stop_movement
        self.enhanced_current_hue = request.enhanced_hue
        self.current_hue = (request.enhanced_hue >> ENHANCED_HUE_SHIFT).to_u8
        self.current_saturation = request.saturation
        color_changed(ColorMode::CurrentHueAndCurrentSaturation, EnhancedColorMode::EnhancedCurrentHueAndCurrentSaturation)
      end

      # The loop is not run; the request is accepted
      def color_loop_set(request : ColorLoopSetRequest) : InteractionModel::Status
        self.remaining_time = NO_TRANSITION
        InteractionModel::Status.success
      end

      def stop_move_step(request : StopMoveStepRequest) : InteractionModel::Status
        stop_movement
      end

      # Advances a continuous move using a monotonic clock. Public for
      # deterministic platform clocks and tests; a fiber advances it normally.
      def advance_movement(now : Time::Instant = Time.instant) : Nil
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

      private def movement_limit_reached?(value : Int32, rate : Int32, minimum : Int32, maximum : Int32) : Bool
        rate == 0 || (rate > 0 && value >= maximum) || (rate < 0 && value <= minimum)
      end

      private def start_movement(kind : MovementKind, rate_x : Int32, rate_y : Int32,
                                 minimum : Int32, maximum : Int32) : InteractionModel::Status
        advance_movement
        origin_x = case kind
                   in .hue?               then @current_hue.to_i
                   in .saturation?        then @current_saturation.to_i
                   in .xy?                then @current_x.to_i
                   in .color_temperature? then @color_temperature_mireds.to_i
                   end
        origin_y = kind.xy? ? @current_y.to_i : 0
        @movement = Movement.new(kind, Time.instant, origin_x, origin_y,
          rate_x, rate_y, minimum, maximum)
        start_movement_fiber
        InteractionModel::Status.success
      end

      private def stop_movement : InteractionModel::Status
        advance_movement
        @movement = nil
        self.remaining_time = NO_TRANSITION
        InteractionModel::Status.success
      end

      private def start_movement_fiber : Nil
        return if @movement_fiber_running
        @movement_fiber_running = true
        spawn do
          while @movement
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
        self.remaining_time = NO_TRANSITION
        @on_color_changed.try &.call
        InteractionModel::Status.success
      end

      private def step_chromaticity(current : UInt16, step : Int16) : UInt16
        (current.to_i32 + step).clamp(UInt16::MIN.to_i32, UInt16::MAX.to_i32).to_u16
      end
    end
  end
end
