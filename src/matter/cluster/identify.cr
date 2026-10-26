require "./cluster"

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
      cluster 0x0003, revision: 6

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
      attribute 0x0000, :identify_time, UInt16, default: 0_u16, writable: true, persist: false
      attribute 0x0001, :identify_type, IdentifyType, default: IdentifyType::None, fixed: true

      command 0x00, :identify, request: Request, access: :manage
      command 0x40, :trigger_effect, request: TriggerEffectRequest, access: :manage

      # Whether the start / stop callbacks last saw an active identification
      @identifying = false

      @on_identify_started : Proc(Nil)?
      @on_identify_stopped : Proc(Nil)?
      @on_trigger_effect : Proc(EffectIdentifier, EffectVariant, Nil)?

      def initialize(endpoint_id : DataType::EndpointNumber, @identify_type : IdentifyType = IdentifyType::None)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
      end

      # A controller may start or stop identification by writing the time too
      after_write :identify_time do
        sync_identify_callbacks
      end

      # ------------------------------------------------------------------------
      # Commands
      # ------------------------------------------------------------------------

      def identify(request : Request) : InteractionModel::Status
        self.identify_time = request.identify_time
        sync_identify_callbacks
        InteractionModel::Status.success
      end

      def trigger_effect(request : TriggerEffectRequest) : InteractionModel::Status
        @on_trigger_effect.try &.call(request.effect_identifier, request.effect_variany)
        InteractionModel::Status.success
      end

      # ------------------------------------------------------------------------
      # Public Interface
      # ------------------------------------------------------------------------

      def identifying? : Bool
        @identify_time > 0
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

      # Counts the identify time down by one second; call once a second while
      # identifying.
      def tick : Nil
        return unless identifying?
        self.identify_time = @identify_time - 1
        sync_identify_callbacks
      end

      # Fires the started / stopped callback when the identifying state
      # flipped since the last call.
      private def sync_identify_callbacks : Nil
        return if @identifying == identifying?
        @identifying = identifying?
        @identifying ? @on_identify_started.try(&.call) : @on_identify_stopped.try(&.call)
      end
    end
  end
end
