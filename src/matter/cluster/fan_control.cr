require "./cluster"

module Matter
  module Cluster
    # Fan Control Cluster (0x0202)
    #
    # Provides an interface to control the speed of a fan, including basic fan mode
    # control and percentage-based speed settings.
    #
    # Features:
    # - MultiSpeed (SPD): Multi-speed fan control with discrete speed levels
    # - Auto (AUTO): Automatic mode support
    # - Rocking (RCK): Rocking movement support
    # - Wind (WND): Wind emulation support
    # - Step (STEP): Step command support for incremental speed changes
    # - AirflowDirection (DIR): Airflow direction attribute
    #
    # Specification: Matter 1.6 Fan Control cluster
    class FanControl < Base
      cluster 0x0202, revision: 6

      feature :multi_speed, bit: 0       # SPD - Multi-speed fan control
      feature :auto, bit: 1              # AUTO - Automatic mode support
      feature :rocking, bit: 2           # RCK - Rocking movement support
      feature :wind, bit: 3              # WND - Wind emulation support
      feature :step, bit: 4              # STEP - Step command support
      feature :airflow_direction, bit: 5 # DIR - Airflow direction attribute

      # Bounds of the percent attributes
      PERCENT_OFF       =   0_u8
      PERCENT_LOWEST_ON =   1_u8
      PERCENT_MAX       = 100_u8

      # SpeedMax is a count of 1 to 100 speed steps.
      SPEED_MAX_MIN =   1_u8
      SPEED_MAX_MAX = 100_u8

      # Fan mode values
      enum FanMode : UInt8
        Off    = 0
        Low    = 1
        Medium = 2
        High   = 3
        On     = 4 # Deprecated but still supported for legacy compatibility
        Auto   = 5
        Smart  = 6 # Deprecated but still supported for legacy compatibility
      end

      # Fan mode sequence values (indicates which modes are supported)
      enum FanModeSequence : UInt8
        OffLowMedHigh     = 0 # Fan supports: Off, Low, Medium, High
        OffLowHigh        = 1 # Fan supports: Off, Low, High
        OffLowMedHighAuto = 2 # Fan supports: Off, Low, Medium, High, Auto
        OffLowHighAuto    = 3 # Fan supports: Off, Low, High, Auto
        OffHighAuto       = 4 # Fan supports: Off, High, Auto
        OffHigh           = 5 # Fan supports: Off, High
      end

      # Step direction for Step command
      enum StepDirection : UInt8
        Increase = 0
        Decrease = 1
      end

      struct StepRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property direction : StepDirection

        @[TLV::Field(tag: 1, optional: true)]
        property wrap : Bool?

        @[TLV::Field(tag: 2, optional: true)]
        property lowest_off : Bool?

        def initialize(@direction : StepDirection, @wrap : Bool? = nil, @lowest_off : Bool? = nil)
        end
      end

      # Rock support bitmap
      @[Flags]
      enum RockSupport : UInt8
        RockLeftRight = 0x01
        RockUpDown    = 0x02
        RockRound     = 0x04
      end

      # Wind support bitmap
      @[Flags]
      enum WindSupport : UInt8
        SleepWind   = 0x01
        NaturalWind = 0x02
      end

      # Airflow direction values
      enum AirflowDirectionEnum : UInt8
        Forward = 0
        Reverse = 1
      end

      attribute 0x0000, :fan_mode, FanMode, default: FanMode::Off, writable: true, write_access: :operate
      attribute 0x0001, :fan_mode_sequence, FanModeSequence, default: FanModeSequence::OffLowMedHigh, fixed: true
      attribute 0x0002, :percent_setting, UInt8, default: PERCENT_OFF, nullable: true, writable: true, write_access: :operate, persist: false, max: PERCENT_MAX
      attribute 0x0003, :percent_current, UInt8, default: PERCENT_OFF, max: PERCENT_MAX
      attribute 0x0004, :speed_max, UInt8, default: SPEED_MAX_MAX, fixed: true, min: SPEED_MAX_MIN, max: SPEED_MAX_MAX, requires: :multi_speed
      attribute 0x0005, :speed_setting, UInt8, default: PERCENT_OFF, nullable: true, writable: true, write_access: :operate, persist: false, requires: :multi_speed
      attribute 0x0006, :speed_current, UInt8, default: PERCENT_OFF, requires: :multi_speed
      attribute 0x0007, :rock_support, RockSupport, default: RockSupport::None, fixed: true, requires: :rocking
      attribute 0x0008, :rock_setting, RockSupport, default: RockSupport::None, writable: true, write_access: :operate, persist: false, requires: :rocking
      attribute 0x0009, :wind_support, WindSupport, default: WindSupport::None, fixed: true, requires: :wind
      attribute 0x000A, :wind_setting, WindSupport, default: WindSupport::None, writable: true, write_access: :operate, persist: false, requires: :wind
      attribute 0x000B, :airflow_direction, AirflowDirectionEnum, default: AirflowDirectionEnum::Forward, writable: true, write_access: :operate, persist: false, requires: :airflow_direction

      command 0x00, :step, request: StepRequest, requires: :step

      # Percent per Step command
      property step_percent : UInt8

      # MultiSpeed remains the default for existing applications. Explicit
      # feature maps can omit it and then Speed* attributes stay off the wire.
      def initialize(endpoint_id : DataType::EndpointNumber,
                     @feature_map : Feature = Feature::MultiSpeed,
                     @fan_mode : FanMode = FanMode::Off,
                     @fan_mode_sequence : FanModeSequence = FanModeSequence::OffLowMedHigh,
                     @percent_setting : UInt8? = PERCENT_OFF,
                     @percent_current : UInt8 = PERCENT_OFF,
                     # MultiSpeed feature
                     @speed_max : UInt8 = SPEED_MAX_MAX,
                     @speed_setting : UInt8? = PERCENT_OFF,
                     @speed_current : UInt8 = PERCENT_OFF,
                     # Rocking feature
                     @rock_support : RockSupport = RockSupport::None,
                     @rock_setting : RockSupport = RockSupport::None,
                     # Wind feature
                     @wind_support : WindSupport = WindSupport::None,
                     @wind_setting : WindSupport = WindSupport::None,
                     # AirflowDirection feature
                     @airflow_direction : AirflowDirectionEnum = AirflowDirectionEnum::Forward,
                     # Step command step size (percent per step)
                     @step_percent : UInt8 = 25_u8)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))

        if setting = @percent_setting
          raise ArgumentError.new("percent_setting must be between 0 and 100") if setting > PERCENT_MAX
        end
        raise ArgumentError.new("percent_current must be between 0 and 100") if @percent_current > PERCENT_MAX

        raise ArgumentError.new("speed_max must be at least 1") if @speed_max < SPEED_MAX_MIN
        raise ArgumentError.new("speed_max must be at most 100") if @speed_max > SPEED_MAX_MAX
        if setting = @speed_setting
          raise ArgumentError.new("speed_setting must be <= speed_max") if setting > @speed_max
        end
        raise ArgumentError.new("speed_current must be <= speed_max") if @speed_current > @speed_max

        auto_sequence = @fan_mode_sequence.in?(FanModeSequence::OffLowMedHighAuto,
          FanModeSequence::OffLowHighAuto, FanModeSequence::OffHighAuto)
        if @feature_map.auto? != auto_sequence
          raise ArgumentError.new("Auto feature must match FanModeSequence")
        end

        unless mode_supported?(@fan_mode, @fan_mode_sequence)
          raise ArgumentError.new("FanMode #{@fan_mode} not supported by FanModeSequence #{@fan_mode_sequence}")
        end

        if @feature_map.rocking?
          raise ArgumentError.new("rock_support must include at least one mode") if @rock_support.none?
          unless (@rock_setting & ~@rock_support).none?
            raise ArgumentError.new("rock_setting contains unsupported modes")
          end
        end

        if @feature_map.wind?
          raise ArgumentError.new("wind_support must include at least one mode") if @wind_support.none?
          unless (@wind_setting & ~@wind_support).none?
            raise ArgumentError.new("wind_setting contains unsupported modes")
          end
        end
      end

      # ------------------------------------------------------------------------
      # Write hooks
      #
      # The dependent attributes are brought in line before the written one is
      # assigned, so its change callback observes a consistent cluster.
      # ------------------------------------------------------------------------

      before_write :fan_mode do |mode|
        InteractionModel::Status.constraint_error unless mode_supported?(mode, @fan_mode_sequence)
      end

      after_write :fan_mode do
        if @fan_mode.off?
          sync_from_percent(PERCENT_OFF)
          self.percent_setting = PERCENT_OFF
        end
      end

      before_write :percent_setting do |percent|
        sync_from_percent(percent) if percent
      end

      before_write :speed_setting do |speed|
        return InteractionModel::Status.constraint_error if speed && speed > @speed_max
        sync_from_speed(speed) if speed
      end

      before_write :rock_setting do |setting|
        InteractionModel::Status.constraint_error unless (setting & ~@rock_support).none?
      end

      before_write :wind_setting do |setting|
        InteractionModel::Status.constraint_error unless (setting & ~@wind_support).none?
      end

      # ------------------------------------------------------------------------
      # Commands
      # ------------------------------------------------------------------------

      # Steps PercentSetting by `step_percent`, wrapping around the range when
      # asked; `lowest_off` decides whether the bottom of the range is Off.
      def step(request : StepRequest) : InteractionModel::Status
        wrap = request.wrap || false
        lowest_off = request.lowest_off.nil? ? true : request.lowest_off
        lowest = lowest_off ? PERCENT_OFF : PERCENT_LOWEST_ON
        current = @percent_current

        target = case request.direction
                 in .increase?
                   if current >= PERCENT_MAX
                     wrap ? lowest : current
                   else
                     Math.min(current.to_u16 + @step_percent, PERCENT_MAX.to_u16).to_u8
                   end
                 in .decrease?
                   if current == PERCENT_OFF || (lowest_off && current <= @step_percent)
                     wrap ? PERCENT_MAX : lowest
                   else
                     current > @step_percent ? current - @step_percent : lowest
                   end
                 end

        sync_from_percent(target)
        self.percent_setting = target
        InteractionModel::Status.success
      end

      # ------------------------------------------------------------------------
      # Public Interface
      # ------------------------------------------------------------------------

      # Update the current fan speed percentage (read-only attribute updated by implementation)
      def update_percent_current(percent : UInt8) : Nil
        raise ArgumentError.new("percent_current must be between 0 and 100") if percent > PERCENT_MAX
        self.percent_current = percent
      end

      # Called with the previous and the new value whenever PercentSetting changes
      def on_percent_changed(&block : UInt8?, UInt8? -> Nil) : Nil
        on_percent_setting_changed(&block)
      end

      # Called with the previous and the new value whenever SpeedSetting changes
      def on_speed_changed(&block : UInt8?, UInt8? -> Nil) : Nil
        on_speed_setting_changed(&block)
      end

      # ------------------------------------------------------------------------
      # Helpers
      # ------------------------------------------------------------------------

      # Brings FanMode, PercentCurrent and the speed attributes in line with a
      # new PercentSetting.
      private def sync_from_percent(percent : UInt8) : Nil
        sync_fan_mode(percent)
        speed = percent_to_speed(percent)
        self.speed_setting = speed
        self.speed_current = speed
        self.percent_current = percent
      end

      # Brings FanMode, SpeedCurrent and the percent attributes in line with a
      # new SpeedSetting.
      private def sync_from_speed(speed : UInt8) : Nil
        percent = speed_to_percent(speed)
        sync_fan_mode(percent)
        self.speed_current = speed
        self.percent_setting = percent
        self.percent_current = percent
      end

      # Off at zero percent; otherwise the sequence's lowest running mode
      # replaces Off.
      private def sync_fan_mode(percent : UInt8) : Nil
        if percent == PERCENT_OFF
          self.fan_mode = FanMode::Off
        elsif @fan_mode.off?
          self.fan_mode = default_on_mode(@fan_mode_sequence)
        end
      end

      # Check if a fan mode is supported by the given sequence
      private def mode_supported?(mode : FanMode, sequence : FanModeSequence) : Bool
        # Off is always supported
        return true if mode == FanMode::Off

        # Deprecated modes (On, Smart) are allowed for backward compatibility
        return true if mode.in?(FanMode::On, FanMode::Smart)

        case sequence
        in .off_low_med_high?
          mode.in?(FanMode::Low, FanMode::Medium, FanMode::High)
        in .off_low_high?
          mode.in?(FanMode::Low, FanMode::High)
        in .off_low_med_high_auto?
          mode.in?(FanMode::Low, FanMode::Medium, FanMode::High, FanMode::Auto)
        in .off_low_high_auto?
          mode.in?(FanMode::Low, FanMode::High, FanMode::Auto)
        in .off_high_auto?
          mode.in?(FanMode::High, FanMode::Auto)
        in .off_high?
          mode == FanMode::High
        end
      end

      # Convert percent (0-100) to speed (0-speed_max)
      private def percent_to_speed(percent : UInt8) : UInt8
        (percent.to_f / PERCENT_MAX * @speed_max).round.to_u8
      end

      # Convert speed (0-speed_max) to percent (0-100)
      private def speed_to_percent(speed : UInt8) : UInt8
        (speed.to_f / @speed_max * PERCENT_MAX).round.to_u8
      end

      # Get default "on" mode for a given sequence
      private def default_on_mode(sequence : FanModeSequence) : FanMode
        case sequence
        in .off_low_med_high?, .off_low_high?, .off_low_med_high_auto?, .off_low_high_auto?
          FanMode::Low
        in .off_high_auto?, .off_high?
          FanMode::High
        end
      end
    end
  end
end
