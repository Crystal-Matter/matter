require "./mode_base"

module Matter
  module Cluster
    # Matter 1.6 Oven Mode (0x0049), Mode Base-derived revision 2.
    class OvenMode < Base
      cluster 0x0049, revision: 2

      enum ModeTag : UInt16
        Bake            = 0x4000
        Convection      = 0x4001
        Grill           = 0x4002
        Roast           = 0x4003
        Clean           = 0x4004
        ConvectionBake  = 0x4005
        ConvectionRoast = 0x4006
        Warming         = 0x4007
        Proofing        = 0x4008
        Steam           = 0x4009
        AirFry          = 0x400A
        AirSousVide     = 0x400B
        FrozenFood      = 0x400C
      end

      DERIVED_TAGS = ModeTag.values.map(&.value)

      attribute 0x0000, :supported_modes, Array(ModeBase::Option), default: [] of ModeBase::Option,
        fixed: true, validate: :reject_fixed_supported_modes!
      attribute 0x0001, :current_mode, UInt8, default: 0_u8,
        persist: true, validate: :validate_current_mode

      command 0x00, :change_to_mode, request: ModeBase::ChangeToModeRequest,
        response: ModeBase::ChangeToModeResponse, response_id: 0x01, access: :operate

      property on_change_to_mode : ModeBase::TransitionCallback? = nil

      @configured_current_mode : UInt8

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @supported_modes : Array(ModeBase::Option),
                     @current_mode : UInt8)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        ModeBase.validate_modes!(@supported_modes, @current_mode, DERIVED_TAGS)
        @supported_modes = copy_modes(@supported_modes)
        @configured_current_mode = @current_mode
      end

      def supported_modes : Array(ModeBase::Option)
        copy_modes(@supported_modes)
      end

      def change_to_mode(request : ModeBase::ChangeToModeRequest) : ModeBase::ChangeToModeResponse
        response = ModeBase.transition(@supported_modes, @current_mode, request.new_mode, @on_change_to_mode)
        self.current_mode = request.new_mode if response.success?
        response
      end

      private def validate_current_mode(mode : UInt8) : Nil
        ModeBase.validate_current_mode!(@supported_modes, mode)
      end

      private def reject_fixed_supported_modes!(_modes : Array(ModeBase::Option)) : Nil
        raise ArgumentError.new("Oven SupportedModes is fixed")
      end

      private def copy_modes(modes : Array(ModeBase::Option)) : Array(ModeBase::Option)
        modes.map { |mode| ModeBase::Option.new(mode.label, mode.mode, mode.mode_tags) }
      end

      private def after_restore_state : Nil
        unless @supported_modes.any?(&.mode.==(@current_mode))
          @current_mode = @configured_current_mode
        end
      end
    end
  end
end
