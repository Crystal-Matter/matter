require "./cluster"

module Matter
  module Cluster
    # Opt-in Matter 1.6 Low Power server (0x0508). The host owns the physical
    # transition to sleep and must arrange it after the command response.
    class LowPower < Base
      cluster 0x0508, revision: 1

      command 0x00, :sleep, access: :operate

      @sleep_callback : Proc(InteractionModel::Status)?

      # The callback should schedule a physical low-power transition after the
      # interaction-model response is sent. Return a non-success status when
      # the platform cannot accept the request. Without a callback, Sleep
      # cannot be accepted.
      def on_sleep(&block : -> InteractionModel::Status) : Nil
        @sleep_callback = block
      end

      def sleep : InteractionModel::Status
        return InteractionModel::Status.invalid_in_state unless callback = @sleep_callback
        callback.call
      end
    end
  end
end
