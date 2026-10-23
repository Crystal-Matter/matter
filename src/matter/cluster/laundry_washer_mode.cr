require "./mode_base"

module Matter
  module Cluster
    # Matter 1.6 Laundry Washer Mode, Mode Base-derived revision 3.
    class LaundryWasherMode < Base
      cluster 0x0051, revision: 3

      enum ModeTag : UInt16
        Normal   = 0x4000
        Delicate = 0x4001
        Heavy    = 0x4002
        Whites   = 0x4003
      end

      DERIVED_TAGS = [ModeTag::Normal.value, ModeTag::Delicate.value, ModeTag::Heavy.value, ModeTag::Whites.value]

      attribute 0x0000, :supported_modes, Array(ModeBase::Option), default: [] of ModeBase::Option, fixed: true
      attribute 0x0001, :current_mode, UInt8, default: 0_u8, persist: true, validate: :validate_current_mode

      command 0x00, :change_to_mode, request: ModeBase::ChangeToModeRequest,
        response: ModeBase::ChangeToModeResponse, response_id: 0x01, access: :operate

      property on_change_to_mode : ModeBase::TransitionCallback? = nil

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @supported_modes : Array(ModeBase::Option),
                     @current_mode : UInt8)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        ModeBase.validate_modes!(@supported_modes, @current_mode, DERIVED_TAGS)
        @supported_modes = @supported_modes.dup
      end

      def change_to_mode(request : ModeBase::ChangeToModeRequest) : ModeBase::ChangeToModeResponse
        response = ModeBase.transition(@supported_modes, @current_mode, request.new_mode, @on_change_to_mode)
        self.current_mode = request.new_mode if response.success?
        response
      end

      private def validate_current_mode(mode : UInt8) : Nil
        ModeBase.validate_current_mode!(@supported_modes, mode)
      end
    end
  end
end
