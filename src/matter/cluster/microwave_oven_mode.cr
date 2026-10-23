require "./mode_base"

module Matter
  module Cluster
    # Matter 1.6 Microwave Oven Mode (0x005E). The appliance changes mode
    # through Microwave Oven Control; ChangeToMode is disallowed here.
    class MicrowaveOvenMode < Base
      cluster 0x005E, revision: 2

      enum ModeTag : UInt16
        Normal  = 0x4000
        Defrost = 0x4001
      end

      DERIVED_TAGS = ModeTag.values.map(&.value)

      attribute 0x0000, :supported_modes, Array(ModeBase::Option),
        default: [] of ModeBase::Option, fixed: true,
        validate: :reject_fixed_supported_modes!
      attribute 0x0001, :current_mode, UInt8, default: 0_u8,
        persist: true, validate: :validate_current_mode

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

      private def validate_current_mode(mode : UInt8) : Nil
        ModeBase.validate_current_mode!(@supported_modes, mode)
      end

      private def reject_fixed_supported_modes!(_modes : Array(ModeBase::Option)) : Nil
        raise ArgumentError.new("Microwave Oven SupportedModes is fixed")
      end

      private def after_restore_state : Nil
        @current_mode = @configured_current_mode unless @supported_modes.any?(&.mode.==(@current_mode))
      end
    end
  end
end
