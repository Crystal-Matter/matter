require "./cluster"

module Matter
  module Cluster
    # Matter 1.6 Mode Select: an enumerated operating mode advertised by a device.
    class ModeSelect < Base
      cluster 0x0050, revision: 2

      feature :on_off, bit: 0

      MAX_DESCRIPTION_BYTES =  64
      MAX_MODE_LABEL_BYTES  =  64
      MAX_SEMANTIC_TAGS     =  64
      MAX_SUPPORTED_MODES   = 255

      struct SemanticTag
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property mfg_code : UInt16

        @[TLV::Field(tag: 1)]
        property value : UInt16

        def initialize(@mfg_code : UInt16, @value : UInt16)
        end
      end

      struct ModeOption
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property label : String

        @[TLV::Field(tag: 1)]
        property mode : UInt8

        @[TLV::Field(tag: 2)]
        property semantic_tags : Array(SemanticTag)

        def initialize(@label : String, @mode : UInt8,
                       @semantic_tags : Array(SemanticTag) = [] of SemanticTag)
          if @label.empty? || @label.bytesize > MAX_MODE_LABEL_BYTES
            raise ArgumentError.new("mode label must contain 1 to #{MAX_MODE_LABEL_BYTES} bytes")
          end
          if @semantic_tags.size > MAX_SEMANTIC_TAGS
            raise ArgumentError.new("mode option supports at most #{MAX_SEMANTIC_TAGS} semantic tags")
          end
          @semantic_tags = @semantic_tags.dup
        end
      end

      struct ChangeToModeRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property new_mode : UInt8

        def initialize(@new_mode : UInt8)
        end
      end

      attribute 0x0000, :description, String, default: "", fixed: true,
        max_length: MAX_DESCRIPTION_BYTES
      attribute 0x0001, :standard_namespace, UInt16, nullable: true, fixed: true
      attribute 0x0002, :supported_modes, Array(ModeOption),
        default: [] of ModeOption, fixed: true
      attribute 0x0003, :current_mode, UInt8, default: 0_u8, persist: true
      attribute 0x0004, :start_up_mode, UInt8, nullable: true, optional: true,
        writable: true, write_access: :operate
      attribute 0x0005, :on_mode, UInt8, nullable: true, writable: true,
        write_access: :operate, requires: :on_off

      before_write :start_up_mode do |mode|
        InteractionModel::Status.constraint_error if mode && !mode_supported?(mode)
      end

      before_write :on_mode do |mode|
        InteractionModel::Status.constraint_error if mode && !mode_supported?(mode)
      end

      command 0x00, :change_to_mode, request: ChangeToModeRequest, access: :operate

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @description : String,
                     @supported_modes : Array(ModeOption),
                     @current_mode : UInt8,
                     @feature_map : Feature = Feature::None,
                     @standard_namespace : UInt16? = nil,
                     @start_up_mode : UInt8? = nil,
                     @on_mode : UInt8? = nil)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        if @description.bytesize > MAX_DESCRIPTION_BYTES
          raise ArgumentError.new("mode description exceeds #{MAX_DESCRIPTION_BYTES} bytes")
        end
        if @supported_modes.empty? || @supported_modes.size > MAX_SUPPORTED_MODES
          raise ArgumentError.new("supported_modes must contain 1 to #{MAX_SUPPORTED_MODES} entries")
        end
        modes = @supported_modes.map(&.mode)
        raise ArgumentError.new("supported_modes contains duplicate mode ids") if modes.uniq.size != modes.size
        raise ArgumentError.new("current_mode is not advertised") unless mode_supported?(@current_mode)
        if (start_up = @start_up_mode) && !mode_supported?(start_up)
          raise ArgumentError.new("start_up_mode is not advertised")
        end
        if (on = @on_mode) && !mode_supported?(on)
          raise ArgumentError.new("on_mode is not advertised")
        end
        raise ArgumentError.new("on_mode requires OnOff feature") if @on_mode && !@feature_map.on_off?
        @supported_modes = @supported_modes.dup
      end

      def change_to_mode(request : ChangeToModeRequest) : InteractionModel::Status
        return InteractionModel::Status.invalid_command unless mode_supported?(request.new_mode)
        self.current_mode = request.new_mode
        InteractionModel::Status.success
      end

      # Apply the mode requested for a power-up after persisted state is restored.
      # An OnOff StartUpOnOff=On setting takes precedence when OnMode is set;
      # an OTA restart otherwise retains the previous CurrentMode.
      def apply_startup_mode(ota_restart : Bool = false, on_mode_override : Bool = false) : Nil
        if on_mode_override && @feature_map.on_off? && (mode = @on_mode)
          self.current_mode = mode
        elsif !ota_restart && (mode = @start_up_mode)
          self.current_mode = mode
        end
      end

      private def mode_supported?(mode : UInt8) : Bool
        @supported_modes.any? { |option| option.mode == mode }
      end
    end
  end
end
