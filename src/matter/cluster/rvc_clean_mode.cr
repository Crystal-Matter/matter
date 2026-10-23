require "./rvc_run_mode"

module Matter
  module Cluster
    # Matter 1.6 RVC Clean Mode, derived from Mode Base revision 2.
    class RvcCleanMode < Base
      cluster 0x0055, revision: 5

      feature :direct_mode_change, bit: 20

      enum ModeTag : UInt16
        DeepClean     = 0x4000
        Vacuum        = 0x4001
        Mop           = 0x4002
        VacuumThenMop = 0x4003
      end

      enum ModeStatus : UInt8
        CleaningInProgress = 0x40
      end

      DERIVED_TAGS         = ModeTag.values.map(&.value)
      INVALID_IN_MODE_TEXT = "Clean mode change while active is unavailable"

      attribute 0x0000, :supported_modes, Array(ModeBase::Option),
        default: [] of ModeBase::Option, fixed: true, validate: :reject_fixed_supported_modes!
      attribute 0x0001, :current_mode, UInt8, default: 0_u8,
        persist: true, validate: :validate_current_mode

      command 0x00, :change_to_mode, request: ModeBase::ChangeToModeRequest,
        response: ModeBase::ChangeToModeResponse, response_id: 0x01, access: :operate

      property on_change_to_mode : ModeBase::TransitionCallback? = nil

      @configured_current_mode : UInt8

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @run_mode : RvcRunMode,
                     @supported_modes : Array(ModeBase::Option),
                     @current_mode : UInt8,
                     @feature_map : Feature = Feature::None)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        ModeBase.validate_modes!(@supported_modes, @current_mode, DERIVED_TAGS)
        unless @supported_modes.any? { |mode| has_tag?(mode, ModeTag::Vacuum) || has_tag?(mode, ModeTag::Mop) }
          raise ArgumentError.new("RVC Clean SupportedModes requires Vacuum or Mop")
        end
        @supported_modes = ModeBase.copy_modes(@supported_modes)
        @configured_current_mode = @current_mode
      end

      def supported_modes : Array(ModeBase::Option)
        ModeBase.copy_modes(@supported_modes)
      end

      def change_to_mode(request : ModeBase::ChangeToModeRequest) : ModeBase::ChangeToModeResponse
        return ModeBase::ChangeToModeResponse.new(ModeBase::ModeChangeStatus::UnsupportedMode) unless @supported_modes.any?(&.mode.==(request.new_mode))
        if request.new_mode != @current_mode && !@run_mode.idle? && !@feature_map.direct_mode_change?
          return ModeBase::ChangeToModeResponse.new(ModeBase::ModeChangeStatus::InvalidInMode, INVALID_IN_MODE_TEXT)
        end
        response = ModeBase.transition(@supported_modes, @current_mode, request.new_mode, @on_change_to_mode)
        self.current_mode = request.new_mode if response.success?
        response
      end

      private def has_tag?(mode : ModeBase::Option, tag : ModeTag) : Bool
        mode.mode_tags.any? { |entry| entry.mfg_code.nil? && entry.value == tag.value }
      end

      private def validate_current_mode(mode : UInt8) : Nil
        ModeBase.validate_current_mode!(@supported_modes, mode)
      end

      private def reject_fixed_supported_modes!(_modes : Array(ModeBase::Option)) : Nil
        raise ArgumentError.new("RVC Clean SupportedModes is fixed")
      end

      private def after_restore_state : Nil
        @current_mode = @configured_current_mode unless @supported_modes.any?(&.mode.==(@current_mode))
      end
    end
  end
end
