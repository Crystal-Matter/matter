require "./mode_base"

module Matter
  module Cluster
    # Matter 1.6 Device Energy Management Mode (0x009F), derived from Mode Base.
    class DeviceEnergyManagementMode < Base
      cluster 0x009F, revision: 2

      enum ModeTag : UInt16
        Auto               = 0x0000
        Quick              = 0x0001
        Quiet              = 0x0002
        LowNoise           = 0x0003
        LowEnergy          = 0x0004
        Vacation           = 0x0005
        Min                = 0x0006
        Max                = 0x0007
        Night              = 0x0008
        Day                = 0x0009
        NoOptimization     = 0x4000
        DeviceOptimization = 0x4001
        LocalOptimization  = 0x4002
        GridOptimization   = 0x4003
      end

      DERIVED_TAGS = [
        ModeTag::NoOptimization.value,
        ModeTag::DeviceOptimization.value,
        ModeTag::LocalOptimization.value,
        ModeTag::GridOptimization.value,
      ]

      attribute 0x0000, :supported_modes, Array(ModeBase::Option),
        default: [] of ModeBase::Option, fixed: true,
        validate: :reject_fixed_supported_modes!
      attribute 0x0001, :current_mode, UInt8, default: 0_u8,
        persist: true, validate: :validate_current_mode

      command 0x00, :change_to_mode, request: ModeBase::ChangeToModeRequest,
        response: ModeBase::ChangeToModeResponse, response_id: 0x01,
        access: :operate

      property on_change_to_mode : ModeBase::TransitionCallback? = nil

      @configured_current_mode : UInt8

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @supported_modes : Array(ModeBase::Option),
                     @current_mode : UInt8)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        ModeBase.validate_modes!(@supported_modes, @current_mode, DERIVED_TAGS)
        @supported_modes = ModeBase.copy_modes(@supported_modes)
        @configured_current_mode = @current_mode
      end

      def supported_modes : Array(ModeBase::Option)
        ModeBase.copy_modes(@supported_modes)
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
        raise ArgumentError.new("Device Energy Management SupportedModes is fixed")
      end

      private def after_restore_state : Nil
        @current_mode = @configured_current_mode unless @supported_modes.any?(&.mode.==(@current_mode))
      end
    end
  end
end
