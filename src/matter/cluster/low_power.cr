require "./cluster"

module Matter
  module Cluster
    # Opt-in Matter 1.6 Low Power server (0x0508). The host decides whether
    # sleep is possible during Invoke, then transitions after the response.
    class LowPower < Base
      cluster 0x0508, revision: 1

      command 0x00, :sleep, access: :operate

      MAX_PENDING_SLEEPS = 64

      @accept_sleep : Proc(InteractionModel::Status)?
      @enter_sleep : Proc(Nil)?
      @pending_sleeps = {} of Tuple(UInt64, UInt16) => Proc(Nil)
      @sleep_mutex = Mutex.new

      # Admission runs synchronously and returns the command status. It must
      # not begin physical sleep or perform other irreversible side effects.
      # The physical transition runs only after InvokeResponse is transmitted.
      def configure_host(accept : -> InteractionModel::Status, sleep : -> Nil) : Nil
        @accept_sleep = accept
        @enter_sleep = sleep
      end

      def sleep : InteractionModel::Status
        accept = @accept_sleep || return InteractionModel::Status.invalid_in_state
        transition = @enter_sleep || return InteractionModel::Status.invalid_in_state
        session_identity = request_session_identity || return InteractionModel::Status.invalid_in_state
        exchange_id = request_exchange_id || return InteractionModel::Status.invalid_in_state
        key = {session_identity, exchange_id}
        queue_full = @sleep_mutex.synchronize do
          @pending_sleeps.has_key?(key) || @pending_sleeps.size >= MAX_PENDING_SLEEPS
        end
        return InteractionModel::Status.busy if queue_full
        status = accept.call
        return status unless status.status == InteractionModel::StatusCode::Success
        @sleep_mutex.synchronize do
          return InteractionModel::Status.busy if @pending_sleeps.has_key?(key) ||
                                                  @pending_sleeps.size >= MAX_PENDING_SLEEPS
          @pending_sleeps[key] = transition
        end
        status
      end

      # These methods are called by the protocol response handoff, not by the
      # host. A failed or suppressed response releases no physical work.
      def take_pending_sleep(session_identity : UInt64, exchange_id : UInt16) : Proc(Nil)?
        @sleep_mutex.synchronize { @pending_sleeps.delete({session_identity, exchange_id}) }
      end

      def discard_pending_sleep(session_identity : UInt64, exchange_id : UInt16) : Nil
        @sleep_mutex.synchronize { @pending_sleeps.delete({session_identity, exchange_id}) }
      end
    end
  end
end
