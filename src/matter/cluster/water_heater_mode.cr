require "./mode_base"

module Matter
  module Cluster
    # Matter 1.6 Water Heater Mode, derived from Mode Base revision 2.
    class WaterHeaterMode < Base
      cluster 0x009E, revision: 1

      MIN_MODE_TAGS    =  1
      MAX_MODE_TAGS    =  8
      MAX_LABEL_BYTES  = 64
      MAX_STATUS_BYTES = 64

      enum Tag : UInt16
        Auto      = 0x0000
        Quick     = 0x0001
        Quiet     = 0x0002
        LowNoise  = 0x0003
        LowEnergy = 0x0004
        Vacation  = 0x0005
        Min       = 0x0006
        Max       = 0x0007
        Night     = 0x0008
        Day       = 0x0009
        Off       = 0x4000
        Manual    = 0x4001
        Timed     = 0x4002
      end

      enum ModeStatus : UInt8
        Success         = 0x00
        UnsupportedMode = 0x01
        GenericFailure  = 0x02
        InvalidInMode   = 0x03
      end

      struct ModeTag
        include TLV::Serializable

        @[TLV::Field(tag: 0, optional: true)]
        getter mfg_code : UInt16?

        @[TLV::Field(tag: 1)]
        getter value : UInt16

        def initialize(@value : UInt16, @mfg_code : UInt16? = nil)
        end

        def initialize(value : Tag)
          @value = value.value
          @mfg_code = nil
        end
      end

      struct ModeOption
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter label : String

        @[TLV::Field(tag: 1)]
        getter mode : UInt8

        @[TLV::Field(tag: 2)]
        getter mode_tags : Array(ModeTag)

        def initialize(@label : String, @mode : UInt8, @mode_tags : Array(ModeTag))
          raise ArgumentError.new("mode label exceeds 64 bytes") if @label.bytesize > MAX_LABEL_BYTES
          unless (MIN_MODE_TAGS..MAX_MODE_TAGS).includes?(@mode_tags.size)
            raise ArgumentError.new("mode requires 1 to 8 tags")
          end
          unless @mode_tags.any? { |tag| tag.mfg_code.nil? }
            raise ArgumentError.new("mode requires a standard tag")
          end
          primary = {Tag::Off.value, Tag::Manual.value, Tag::Timed.value}
          if @mode_tags.count { |tag| tag.mfg_code.nil? && primary.includes?(tag.value) } > 1
            raise ArgumentError.new("Off, Manual, and Timed tags cannot share a mode")
          end
          @mode_tags = @mode_tags.dup
        end

        def mode_tags : Array(ModeTag)
          @mode_tags.dup
        end
      end

      struct ChangeToModeRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter new_mode : UInt8

        def initialize(@new_mode : UInt8)
        end
      end

      struct ChangeToModeResponse
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter status : ModeStatus

        @[TLV::Field(tag: 1, optional: true)]
        getter status_text : String?

        def initialize(@status : ModeStatus, @status_text : String? = nil)
          raise ArgumentError.new("status text exceeds 64 bytes") if @status_text.try(&.bytesize).try { |size| size > MAX_STATUS_BYTES }
          if @status.unsupported_mode?
            @status_text = ""
          elsif !@status.success? && @status_text.nil?
            raise ArgumentError.new("failed mode transition requires status text")
          end
        end
      end

      attribute 0x0000, :supported_modes, Array(ModeOption),
        default: [] of ModeOption, fixed: true, validate: :reject_fixed_modes!
      attribute 0x0001, :current_mode, UInt8, default: 0_u8, persist: true,
        validate: :validate_current_mode!

      command 0x00, :change_to_mode, request: ChangeToModeRequest,
        response: ChangeToModeResponse, response_id: 0x01, access: :operate

      @change_callback : Proc(UInt8, ChangeToModeResponse)?

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @supported_modes : Array(ModeOption), @current_mode : UInt8)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        shared_options = @supported_modes.map do |option|
          tags = option.mode_tags.map { |tag| ModeBase::Tag.new(tag.value, tag.mfg_code) }
          ModeBase::Option.new(option.label, option.mode, tags)
        end
        ModeBase.validate_modes!(shared_options, @current_mode,
          [Tag::Off.value, Tag::Manual.value, Tag::Timed.value])
        {Tag::Off, Tag::Manual}.each do |required|
          unless @supported_modes.any? { |mode| mode.mode_tags.any? { |tag| tag.mfg_code.nil? && tag.value == required.value } }
            raise ArgumentError.new("SupportedModes requires #{required} tag")
          end
        end
        @supported_modes = @supported_modes.dup
        @configured_current_mode = @current_mode
      end

      def supported_modes : Array(ModeOption)
        @supported_modes.dup
      end

      def on_change_to_mode(&block : UInt8 -> ChangeToModeResponse) : Nil
        @change_callback = block
      end

      def change_to_mode(request : ChangeToModeRequest) : ChangeToModeResponse
        unless mode_supported?(request.new_mode)
          return ChangeToModeResponse.new(ModeStatus::UnsupportedMode)
        end
        return ChangeToModeResponse.new(ModeStatus::Success) if request.new_mode == @current_mode
        callback = @change_callback
        return ChangeToModeResponse.new(ModeStatus::GenericFailure, "Mode handler unavailable") unless callback
        response = callback.call(request.new_mode)
        self.current_mode = request.new_mode if response.status.success?
        response
      end

      # A local appliance controller may switch modes without an IM command.
      def report_current_mode(mode : UInt8) : Nil
        self.current_mode = mode
      end

      private def mode_supported?(mode : UInt8) : Bool
        @supported_modes.any? { |option| option.mode == mode }
      end

      private def validate_current_mode!(mode : UInt8) : Nil
        raise ArgumentError.new("CurrentMode is absent from SupportedModes") unless mode_supported?(mode)
      end

      private def after_restore_state : Nil
        @current_mode = @configured_current_mode unless mode_supported?(@current_mode)
      end

      private def reject_fixed_modes!(_modes) : Nil
        raise ArgumentError.new("SupportedModes is fixed")
      end
    end
  end
end
