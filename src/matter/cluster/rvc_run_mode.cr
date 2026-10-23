require "./mode_base"

module Matter
  module Cluster
    # Matter 1.6 RVC Run Mode, derived from Mode Base revision 2.
    class RvcRunMode < Base
      cluster 0x0054, revision: 4

      feature :direct_mode_change, bit: 20

      enum ModeTag : UInt16
        Idle     = 0x4000
        Cleaning = 0x4001
        Mapping  = 0x4002
      end

      enum ModeStatus : UInt8
        Stuck                 = 0x41
        DustBinMissing        = 0x42
        DustBinFull           = 0x43
        WaterTankEmpty        = 0x44
        WaterTankMissing      = 0x45
        WaterTankLidOpen      = 0x46
        MopCleaningPadMissing = 0x47
        BatteryLow            = 0x48
      end

      DERIVED_TAGS         = ModeTag.values.map(&.value)
      INVALID_IN_MODE_TEXT = "Direct run mode change is unavailable"

      attribute 0x0000, :supported_modes, Array(ModeBase::Option),
        default: [] of ModeBase::Option, fixed: true, validate: :reject_fixed_supported_modes!
      attribute 0x0001, :current_mode, UInt8, default: 0_u8,
        persist: true, validate: :validate_current_mode

      command 0x00, :change_to_mode, request: ModeBase::ChangeToModeRequest,
        response: ModeBase::ChangeToModeResponse, response_id: 0x01, access: :operate

      property on_change_to_mode : ModeBase::TransitionCallback? = nil

      @configured_current_mode : UInt8

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @supported_modes : Array(ModeBase::Option),
                     @current_mode : UInt8,
                     @feature_map : Feature = Feature::None)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        ModeBase.validate_modes!(@supported_modes, @current_mode, DERIVED_TAGS)
        validate_run_modes!(@supported_modes)
        @supported_modes = ModeBase.copy_modes(@supported_modes)
        @configured_current_mode = @current_mode
      end

      def supported_modes : Array(ModeBase::Option)
        ModeBase.copy_modes(@supported_modes)
      end

      def idle? : Bool
        mode_has_tag?(@current_mode, ModeTag::Idle)
      end

      def idle_mode : UInt8
        mode = @supported_modes.find { |option| has_tag?(option, ModeTag::Idle) }
        raise ArgumentError.new("RVC Run SupportedModes has no Idle mode") unless mode
        mode.mode
      end

      def change_to_mode(request : ModeBase::ChangeToModeRequest) : ModeBase::ChangeToModeResponse
        next_mode = @supported_modes.find(&.mode.==(request.new_mode))
        return ModeBase::ChangeToModeResponse.new(ModeBase::ModeChangeStatus::UnsupportedMode) unless next_mode
        if request.new_mode != @current_mode && !idle? && !has_tag?(next_mode, ModeTag::Idle) &&
           !@feature_map.direct_mode_change?
          return ModeBase::ChangeToModeResponse.new(ModeBase::ModeChangeStatus::InvalidInMode, INVALID_IN_MODE_TEXT)
        end
        response = ModeBase.transition(@supported_modes, @current_mode, request.new_mode, @on_change_to_mode)
        self.current_mode = request.new_mode if response.success?
        response
      end

      private def mode_has_tag?(mode_id : UInt8, tag : ModeTag) : Bool
        mode = @supported_modes.find(&.mode.==(mode_id))
        mode ? has_tag?(mode, tag) : false
      end

      private def has_tag?(mode : ModeBase::Option, tag : ModeTag) : Bool
        mode.mode_tags.any? { |entry| entry.mfg_code.nil? && entry.value == tag.value }
      end

      private def validate_run_modes!(modes : Array(ModeBase::Option)) : Nil
        unless modes.any? { |mode| has_tag?(mode, ModeTag::Idle) }
          raise ArgumentError.new("RVC Run SupportedModes requires an Idle mode")
        end
        unless modes.any? { |mode| has_tag?(mode, ModeTag::Cleaning) }
          raise ArgumentError.new("RVC Run SupportedModes requires a separate Cleaning mode")
        end
        modes.each do |mode|
          count = ModeTag.values.count { |tag| has_tag?(mode, tag) }
          raise ArgumentError.new("Idle, Cleaning, and Mapping tags are exclusive") if count > 1
        end
      end

      private def validate_current_mode(mode : UInt8) : Nil
        ModeBase.validate_current_mode!(@supported_modes, mode)
      end

      private def reject_fixed_supported_modes!(_modes : Array(ModeBase::Option)) : Nil
        raise ArgumentError.new("RVC Run SupportedModes is fixed")
      end

      private def after_restore_state : Nil
        @current_mode = @configured_current_mode unless @supported_modes.any?(&.mode.==(@current_mode))
      end
    end
  end
end
