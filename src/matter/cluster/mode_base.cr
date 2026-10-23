require "./cluster"

module Matter
  module Cluster
    # Shared wire types and Mode Base rev2 rules for derived mode clusters.
    module ModeBase
      MIN_SUPPORTED_MODES =     2
      MAX_SUPPORTED_MODES =   255
      MIN_MODE_TAGS       =     1
      MAX_MODE_TAGS       =     8
      MAX_LABEL_BYTES     =    64
      MAX_STATUS_BYTES    =    64
      LAST_GENERIC_TAG    = 9_u16
      MFG_TAG_RANGE       = 0x8000_u16..0xBFFF_u16

      enum ModeChangeStatus : UInt8
        Success         = 0
        UnsupportedMode = 1
        GenericFailure  = 2
        InvalidInMode   = 3
      end

      struct Tag
        include TLV::Serializable

        @[TLV::Field(tag: 0, optional: true)]
        property mfg_code : UInt16?

        @[TLV::Field(tag: 1)]
        property value : UInt16

        def initialize(@value : UInt16, @mfg_code : UInt16? = nil)
        end
      end

      struct Option
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property label : String

        @[TLV::Field(tag: 1)]
        property mode : UInt8

        @[TLV::Field(tag: 2)]
        property mode_tags : Array(Tag)

        def initialize(@label : String, @mode : UInt8, @mode_tags : Array(Tag))
          @mode_tags = @mode_tags.dup
        end
      end

      struct ChangeToModeRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property new_mode : UInt8

        def initialize(@new_mode : UInt8)
        end
      end

      struct ChangeToModeResponse
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property status : UInt8

        @[TLV::Field(tag: 1)]
        property status_text : String

        def initialize(@status : UInt8, @status_text : String = "")
          validate!
        end

        def initialize(status : ModeChangeStatus, @status_text : String = "")
          @status = status.value
          validate!
        end

        def success? : Bool
          @status == ModeChangeStatus::Success.value
        end

        private def validate! : Nil
          raise ArgumentError.new("StatusText exceeds #{MAX_STATUS_BYTES} bytes") if @status_text.bytesize > MAX_STATUS_BYTES
          if @status != ModeChangeStatus::Success.value && @status != ModeChangeStatus::UnsupportedMode.value && @status_text.empty?
            raise ArgumentError.new("StatusText is required for a rejected mode transition")
          end
        end
      end

      alias TransitionCallback = Proc(UInt8, UInt8, ChangeToModeResponse)

      def self.validate_modes!(options : Array(Option), current_mode : UInt8, derived_tags : Array(UInt16)) : Nil
        unless options.size.in?(MIN_SUPPORTED_MODES..MAX_SUPPORTED_MODES)
          raise ArgumentError.new("SupportedModes must contain #{MIN_SUPPORTED_MODES} to #{MAX_SUPPORTED_MODES} entries")
        end
        raise ArgumentError.new("SupportedModes contains duplicate mode values") unless options.map(&.mode).uniq!.size == options.size
        raise ArgumentError.new("SupportedModes contains duplicate labels") unless options.map(&.label).uniq!.size == options.size

        options.each_with_index do |option, index|
          raise ArgumentError.new("mode label exceeds #{MAX_LABEL_BYTES} bytes") if option.label.bytesize > MAX_LABEL_BYTES
          unless option.mode_tags.size.in?(MIN_MODE_TAGS..MAX_MODE_TAGS)
            raise ArgumentError.new("each mode requires #{MIN_MODE_TAGS} to #{MAX_MODE_TAGS} tags")
          end
          tags = option.mode_tags.map { |tag| {tag.mfg_code, tag.value} }
          raise ArgumentError.new("mode tags must be distinct") unless tags.uniq.size == tags.size
          if option.mode_tags.any? { |tag| !tag.mfg_code.nil? && !MFG_TAG_RANGE.includes?(tag.value) }
            raise ArgumentError.new("manufacturer mode tags must use values in 0x8000..0xBFFF")
          end
          if options[0...index].any? do |previous|
               previous_tags = previous.mode_tags.map { |tag| {tag.mfg_code, tag.value} }
               tags.size == previous_tags.size && tags.all? { |tag| previous_tags.includes?(tag) }
             end
            raise ArgumentError.new("mode tag sets must be distinct across SupportedModes")
          end
          unless option.mode_tags.any? { |tag| tag.mfg_code.nil? && standard_tag?(tag.value, derived_tags) }
            raise ArgumentError.new("each mode requires a standard mode tag")
          end
          if option.mode_tags.any? { |tag| tag.mfg_code.nil? && !standard_tag?(tag.value, derived_tags) }
            raise ArgumentError.new("unknown standard mode tag")
          end
        end
        validate_current_mode!(options, current_mode)
      end

      def self.validate_current_mode!(options : Array(Option), mode : UInt8) : Nil
        raise ArgumentError.new("CurrentMode is not in SupportedModes") unless options.any? { |option| option.mode == mode }
      end

      def self.transition(options : Array(Option), current_mode : UInt8, new_mode : UInt8,
                          callback : TransitionCallback?) : ChangeToModeResponse
        unless options.any? { |option| option.mode == new_mode }
          return ChangeToModeResponse.new(ModeChangeStatus::UnsupportedMode)
        end
        return ChangeToModeResponse.new(ModeChangeStatus::Success) if new_mode == current_mode

        callback.try(&.call(current_mode, new_mode)) || ChangeToModeResponse.new(ModeChangeStatus::Success)
      end

      private def self.standard_tag?(tag : UInt16, derived_tags : Array(UInt16)) : Bool
        tag <= LAST_GENERIC_TAG || derived_tags.includes?(tag)
      end
    end
  end
end
