require "./cluster"
require "deque"
require "log"

module Matter
  module Cluster
    # Identify Cluster Implementation (0x0003)
    #
    # Provides an interface for a device to identify itself to a user
    # (e.g., by flashing a light, sounding a beep, displaying a message).
    #
    # Commonly required on many device types for commissioning and user interaction.
    #
    # Matter Spec: Application 1.2
    class Identify < Base
      Log           = ::Log.for("matter.cluster.identify")
      cluster 0x0003, revision: 6
      IDENTIFY_TICK = 1.second

      private enum Notification
        VersionChanged
        AttributeChanged
        Started
        Stopped
      end

      # Identify Type enum - indicates how the device identifies itself
      enum IdentifyType : UInt8
        None         = 0 # No identification method
        VisibleLight = 1 # Visible light (e.g., bulb flashes)
        VisibleLED   = 2 # Visible LED indicator
        AudibleBeep  = 3 # Audible beep/tone
        Display      = 4 # Display message
        Actuator     = 5 # Physical actuator (e.g., lock/unlock, open/close)
      end

      enum EffectIdentifier : UInt8
        # e.g., Light is turned on/off once.
        Blink = 0

        # e.g., Light is turned on/off over 1 second and repeated 15 times.
        Breathe = 1

        # e.g., Colored light turns green for 1 second; non-colored light flashes twice.
        Okay = 2

        # e.g., Colored light turns orange for 8 seconds; non-colored light switches to the maximum brightness for
        # 0.5s and then minimum brightness for 7.5s.
        ChannelChange = 11

        # Complete the current effect sequence before terminating. e.g., if in the middle of a breathe effect (as
        # above), first complete the current 1s breathe effect and then terminate the effect.
        FinishEffect = 254

        # Terminate the effect as soon as possible.
        StopEffect = 255
      end

      enum EffectVariant : UInt8
        Default = 0
      end

      # Input to the Identify identify command
      struct Request
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property identify_time : UInt16

        def initialize(@identify_time : UInt16)
        end
      end

      # Input to the Identify triggerEffect command
      struct TriggerEffectRequest
        include TLV::Serializable

        # This field specifies the identify effect to use. All values of the EffectIdentifier shall be supported.
        # Implementors may deviate from the example light effects in the table below, but they SHOULD indicate during
        # testing how they handle each effect.
        #
        # This field shall contain one of the non-reserved values listed below.
        #
        # Table 3. Values of the EffectIdentifier Field of the TriggerEffect Command
        @[TLV::Field(tag: 0)]
        property effect_identifier : EffectIdentifier

        # This field is used to indicate which variant of the effect, indicated in the EffectIdentifier field, SHOULD
        # be triggered. If a device does not support the given variant, it shall use the default variant. This field
        # shall contain one of the values listed below:
        #
        # Table 4. Values of the EffectVariant Field of the TriggerEffect Command
        @[TLV::Field(tag: 1)]
        property effect_variany : EffectVariant

        def initialize(@effect_identifier : EffectIdentifier, @effect_variany : EffectVariant)
        end
      end

      # This command is generated in response to receiving an IdentifyQuery command, see IdentifyQuery Command, in the
      # case that the device is currently identifying itself.
      struct IdentifyQueryResponse
        include TLV::Serializable

        # This field contains the current value of the IdentifyTime attribute, and specifies the length of time, in
        # seconds, that the device will continue to identify itself.
        @[TLV::Field(tag: 0)]
        property timeout : UInt16
      end

      # Remaining identify time in seconds; volatile, so not persisted
      attribute 0x0000, :identify_time, UInt16, computed: true, writable: true, write_access: :operate
      attribute 0x0001, :identify_type, IdentifyType, default: IdentifyType::None, fixed: true

      command 0x00, :identify, request: Request, access: :manage
      command 0x40, :trigger_effect, request: TriggerEffectRequest, access: :manage

      # Whether the start / stop callbacks last saw an active identification
      @identifying = false
      @identify_time = 0_u16
      @next_identify_tick : Time::Instant? = nil
      @identify_timer_running = false
      @identify_closed = false
      @identify_host_active = false
      @identify_generation = 0_u64
      @identify_mutex = Mutex.new(:reentrant)
      @identify_notifications = Deque(Tuple(Notification, UInt64)).new
      @identify_draining_notifications = false

      @on_identify_started : Proc(Nil)?
      @on_identify_stopped : Proc(Nil)?
      @on_trigger_effect : Proc(EffectIdentifier, EffectVariant, Nil)?

      def initialize(endpoint_id : DataType::EndpointNumber, @identify_type : IdentifyType = IdentifyType::None)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
      end

      # ------------------------------------------------------------------------
      # Commands
      # ------------------------------------------------------------------------

      def identify(request : Request) : InteractionModel::Status
        self.identify_time = request.identify_time
        InteractionModel::Status.success
      end

      def trigger_effect(request : TriggerEffectRequest) : InteractionModel::Status
        @on_trigger_effect.try &.call(request.effect_identifier, request.effect_variany)
        InteractionModel::Status.success
      end

      # ------------------------------------------------------------------------
      # Public Interface
      # ------------------------------------------------------------------------

      def identify_time : UInt16
        changed = false
        value = @identify_mutex.synchronize do
          changed = advance_identify_time_locked(Time.instant)
          @identify_time
        end
        spawn { drain_identify_notifications } if changed
        value
      end

      def identify_time=(value : UInt16) : Nil
        @identify_mutex.synchronize do
          unless @identify_closed
            advance_identify_time_locked(Time.instant)
            # Repeated Identify commands restart the full interval even when the
            # reported value stays the same.
            @next_identify_tick = value.zero? ? nil : Time.instant + IDENTIFY_TICK
            if @identify_time != value
              @identify_time = value
              record_identify_change_locked
            end
            sync_identify_callbacks_locked
            start_identify_timer_locked unless value.zero?
          end
        end
        drain_identify_notifications
      end

      def identifying? : Bool
        changed = false
        active = @identify_mutex.synchronize do
          changed = advance_identify_time_locked(Time.instant)
          @identify_time > 0
        end
        spawn { drain_identify_notifications } if changed
        active
      end

      # Set callback for when identify starts
      def on_identify_started(&block : -> Nil)
        @on_identify_started = block
      end

      # Set callback for when identify stops
      def on_identify_stopped(&block : -> Nil)
        @on_identify_stopped = block
      end

      # Set callback for trigger effect
      def on_trigger_effect(&block : EffectIdentifier, EffectVariant -> Nil)
        @on_trigger_effect = block
      end

      # Applications may keep calling tick once a second. The monotonic clock
      # owns the countdown, so a manual call never subtracts time twice.
      def tick : Nil
        advance_identify_time
      end

      # Catch up after a delayed scheduler tick or before a read/Groups command.
      def advance_identify_time(now : Time::Instant = Time.instant) : Nil
        @identify_mutex.synchronize { advance_identify_time_locked(now) }
        drain_identify_notifications
      end

      # Stop the autonomous timer when its endpoint is removed or replaced.
      # An in-flight host start callback may finish after close returns; the
      # single notification drainer delivers its final stop afterward.
      def close : Nil
        @identify_mutex.synchronize do
          unless @identify_closed
            @identify_closed = true
            @identify_generation &+= 1
            @next_identify_tick = nil
            @identify_time = 0_u16
            @identifying = false
            @identify_notifications.clear
            if @identify_host_active
              @identify_host_active = false
              @identify_notifications << {Notification::Stopped, @identify_generation}
            end
          end
        end
        drain_identify_notifications
      end

      # Node may later reattach an Endpoint returned by remove_endpoint.
      def reopen : Nil
        @identify_mutex.synchronize { @identify_closed = false }
      end

      private def advance_identify_time_locked(now : Time::Instant) : Bool
        next_tick = @next_identify_tick
        return false unless next_tick && now >= next_tick && @identify_time > 0

        # A suspended fiber can miss many ticks. Advance the data version by
        # the elapsed seconds, but publish the final value only once.
        elapsed_ticks = (now - next_tick).total_seconds.to_i64 + 1_i64
        ticks = {elapsed_ticks, @identify_time.to_i64}.min
        @identify_time -= ticks.to_u16
        @next_identify_tick = @identify_time.zero? ? nil : next_tick + ticks.seconds
        @data_version &+= ticks.to_u32
        @identify_notifications << {Notification::VersionChanged, @identify_generation}
        @identify_notifications << {Notification::AttributeChanged, @identify_generation}
        sync_identify_callbacks_locked if @identify_time.zero?
        true
      end

      private def record_identify_change_locked : Nil
        @data_version &+= 1
        @identify_notifications << {Notification::VersionChanged, @identify_generation}
        @identify_notifications << {Notification::AttributeChanged, @identify_generation}
      end

      private def drain_identify_notifications : Nil
        should_drain = @identify_mutex.synchronize do
          if @identify_draining_notifications
            false
          else
            @identify_draining_notifications = true
            true
          end
        end
        return unless should_drain

        loop do
          event = @identify_mutex.synchronize do
            if item = @identify_notifications.shift?
              item
            else
              @identify_draining_notifications = false
              nil
            end
          end
          break unless event
          notification, generation = event

          deliver = @identify_mutex.synchronize do
            next false if generation != @identify_generation
            next false if @identify_closed && notification != Notification::Stopped
            @identify_host_active = true if notification == Notification::Started
            @identify_host_active = false if notification == Notification::Stopped
            true
          end
          next unless deliver

          begin
            case notification
            in Notification::VersionChanged
              @on_version_changed.try(&.call)
            in Notification::AttributeChanged
              notify_changed(ATTR_IDENTIFY_TIME)
            in Notification::Started
              @on_identify_started.try(&.call)
            in Notification::Stopped
              @on_identify_stopped.try(&.call)
            end
          rescue ex
            Log.error(exception: ex) { "Identify #{notification} callback failed" }
          end
        end
      rescue ex
        @identify_mutex.synchronize { @identify_draining_notifications = false }
        raise ex
      end

      private def start_identify_timer_locked : Nil
        return if @identify_timer_running
        @identify_timer_running = true
        spawn do
          loop do
            remaining = @identify_mutex.synchronize do
              if @identify_closed || (deadline = @next_identify_tick).nil?
                nil
              else
                deadline - Time.instant
              end
            end
            break unless remaining
            sleep remaining if remaining > 0.seconds
            advance_identify_time
          end
        ensure
          @identify_mutex.synchronize do
            @identify_timer_running = false
            start_identify_timer_locked if !@identify_closed && @next_identify_tick
          end
        end
      end

      # Fires the started / stopped callback when the identifying state
      # flipped since the last call.
      private def sync_identify_callbacks_locked : Nil
        active = @identify_time > 0
        return if @identifying == active
        @identifying = active
        @identify_notifications << {active ? Notification::Started : Notification::Stopped, @identify_generation}
      end
    end
  end
end
