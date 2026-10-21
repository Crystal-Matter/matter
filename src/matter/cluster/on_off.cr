require "./cluster"

module Matter
  module Cluster
    # On/Off Cluster Implementation (0x0006)
    # Provides binary on/off control with optional lighting and timing features
    #
    # Features:
    # - Lighting (LT): Enables level control interaction and global scene management
    # - DeadFrontBehavior (DF): Device exhibits "dead front" when off
    # - OffOnly: Device can only be turned off (On/Toggle not supported)
    #
    # Matter Spec: Application Clusters 1.5
    class OnOff < Base
      cluster 0x0006, revision: 6

      TIMED_TICK = 100.milliseconds
      TIME_HOLD  = UInt16::MAX

      feature :lighting, bit: 0            # LT - Lighting applications
      feature :dead_front_behavior, bit: 1 # DF - Dead front behavior when off
      feature :off_only, bit: 2            # OFFONLY - Only off command supported
      conflicts :lighting, :off_only
      conflicts :dead_front_behavior, :off_only

      # StartUpOnOff enum values
      enum StartUpOnOff : UInt8
        Off    = 0
        On     = 1
        Toggle = 2
      end

      # OffWithEffect effect identifiers
      enum EffectIdentifier : UInt8
        DelayedAllOff = 0
        DyingLight    = 1
      end

      # OnWithTimedOff control bits
      @[Flags]
      enum OnOffControl : UInt8
        AcceptOnlyWhenOn = 1
      end

      struct OffWithEffectRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property effect_identifier : EffectIdentifier

        @[TLV::Field(tag: 1)]
        property effect_variant : UInt8

        def initialize(@effect_identifier : EffectIdentifier, @effect_variant : UInt8)
        end
      end

      struct OnWithTimedOffRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property on_off_control : OnOffControl

        @[TLV::Field(tag: 1)]
        property on_time : UInt16

        @[TLV::Field(tag: 2)]
        property off_wait_time : UInt16

        def initialize(@on_off_control : OnOffControl, @on_time : UInt16, @off_wait_time : UInt16)
        end
      end

      attribute 0x0000, :on_off, Bool, default: false, persist: true, scene: true, callback: :new_only
      attribute 0x4000, :global_scene_control, Bool, default: true, persist: true, requires: :lighting
      attribute 0x4001, :on_time, UInt16, default: 0_u16, writable: true, persist: false, requires: :lighting
      attribute 0x4002, :off_wait_time, UInt16, default: 0_u16, writable: true, persist: false, requires: :lighting
      attribute 0x4003, :start_up_on_off, StartUpOnOff, nullable: true, writable: true, write_access: :manage, requires: :lighting

      command 0x00, :off
      command 0x01, :on, requires: {off_only: false}
      command 0x02, :toggle, requires: {off_only: false}
      command 0x40, :off_with_effect, request: OffWithEffectRequest, requires: :lighting
      command 0x41, :on_with_recall_global_scene, requires: :lighting
      command 0x42, :on_with_timed_off, request: OnWithTimedOffRequest, requires: :lighting

      def initialize(
        endpoint_id : DataType::EndpointNumber,
        @on_off : Bool = false,
        @feature_map : Feature = Feature::None,
      )
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        @next_timed_tick = nil
        @timed_fiber_running = false
      end

      @next_timed_tick : Time::Instant?
      @timed_fiber_running : Bool

      # ------------------------------------------------------------------------
      # Commands
      # ------------------------------------------------------------------------

      def off : InteractionModel::Status
        self.on_off = false
        if feature_map.lighting?
          self.global_scene_control = false
          self.on_time = 0_u16
          if @off_wait_time > 0 && @off_wait_time != TIME_HOLD
            @next_timed_tick ||= Time.instant + TIMED_TICK
            start_timed_fiber
          else
            @next_timed_tick = nil
          end
        end
        InteractionModel::Status.success
      end

      def on : InteractionModel::Status
        self.on_off = true
        if feature_map.lighting?
          self.global_scene_control = true
          if @on_time == 0
            self.off_wait_time = 0_u16
            @next_timed_tick = nil
          end
        end
        InteractionModel::Status.success
      end

      def toggle : InteractionModel::Status
        @on_off ? off : on
      end

      # Effects are not rendered; the device turns off immediately.
      def off_with_effect(request : OffWithEffectRequest) : InteractionModel::Status
        off
      end

      def on_with_recall_global_scene : InteractionModel::Status
        on
      end

      # OnTime and OffWaitTime count down in tenths of a second. A later timed
      # command can extend the on period; during delayed off it may only
      # shorten the guard period.
      def on_with_timed_off(request : OnWithTimedOffRequest) : InteractionModel::Status
        return InteractionModel::Status.success if request.on_off_control.accept_only_when_on? && !@on_off

        if @off_wait_time > 0 && !@on_off
          self.off_wait_time = {@off_wait_time, request.off_wait_time}.min
          if @off_wait_time == 0 || @off_wait_time == TIME_HOLD
            @next_timed_tick = nil
          else
            @next_timed_tick ||= Time.instant + TIMED_TICK
            start_timed_fiber
          end
          return InteractionModel::Status.success
        end

        self.on_time = {@on_time, request.on_time}.max
        self.off_wait_time = request.off_wait_time
        on
        if @on_time > 0 && @on_time != TIME_HOLD
          @next_timed_tick ||= Time.instant + TIMED_TICK
          start_timed_fiber
        end
        InteractionModel::Status.success
      end

      # Runs elapsed timer ticks. The public form permits deterministic
      # platform clocks and tests; the cluster also schedules its own fiber.
      def advance_timed_state(now : Time::Instant = Time.instant) : Nil
        while tick = @next_timed_tick
          break if now < tick

          if @on_off
            if @on_time == TIME_HOLD
              @next_timed_tick = nil
              break
            end
            self.on_time = @on_time - 1_u16 if @on_time > 0
            if @on_time == 0
              self.off_wait_time = 0_u16
              self.on_off = false
              @next_timed_tick = nil
              break
            end
          else
            if @off_wait_time == TIME_HOLD || @off_wait_time == 0
              @next_timed_tick = nil
              break
            end
            self.off_wait_time = @off_wait_time - 1_u16
            if @off_wait_time == 0
              @next_timed_tick = nil
              break
            end
          end

          @next_timed_tick = tick + TIMED_TICK
        end
      end

      private def start_timed_fiber : Nil
        return if @timed_fiber_running
        @timed_fiber_running = true
        spawn do
          while tick = @next_timed_tick
            remaining = tick - Time.instant
            sleep remaining if remaining > 0.seconds
            advance_timed_state
          end
        ensure
          @timed_fiber_running = false
        end
      end

      # ------------------------------------------------------------------------
      # Public Interface
      # ------------------------------------------------------------------------

      def on? : Bool
        @on_off
      end

      def off? : Bool
        !@on_off
      end

      def on=(state : Bool) : Bool
        state ? on : off
        state
      end

      # Called with the new state whenever OnOff changes
      def on_state_changed(&block : Bool -> Nil) : Nil
        on_on_off_changed(&block)
      end

      # ------------------------------------------------------------------------
      # ScenesManagement extension field sets
      # ------------------------------------------------------------------------
      def store_scene_extension_field_set : ScenesManagement::ExtensionFieldSet?
        ScenesManagement::ExtensionFieldSet.new(
          cluster_id: CLUSTER_ID,
          attribute_list: [
            {ATTR_ON_OFF, TLV::Any.new(@on_off)},
          ]
        )
      end

      # Scenes map bool attributes to ValueUnsigned8; only 1 represents true.
      # Other values map to false for the non-nullable OnOff attribute.
      SCENE_BOOLEAN_TRUE = 1_u8

      def apply_scene_extension_field_set(field_set : ScenesManagement::ExtensionFieldSet) : Bool
        return false unless field_set.cluster_id == CLUSTER_ID

        field_set.attribute_value_list.each do |attribute_id, value|
          next unless attribute_id == ATTR_ON_OFF

          case parsed = value.value
          when Bool
            parsed ? on : off
            return true
          when UInt8
            parsed == SCENE_BOOLEAN_TRUE ? on : off
            return true
          end
        end

        false
      end
    end
  end
end
