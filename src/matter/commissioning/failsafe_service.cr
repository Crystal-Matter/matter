require "log"
require "./failsafe_context"
require "./outcome"
require "./rollback_targets"

module Matter
  module Commissioning
    # The failsafe state machine `Cluster::GeneralCommissioning` fronts:
    # ArmFailSafe, CommissioningComplete, expiry and rollback.
    #
    # The service owns the `FailsafeContext` and every decision about it; the
    # cluster owns the attributes the decisions are visible in (breadcrumb,
    # regulatory config) and applies them through the callbacks below.
    #
    # Matter Core Spec §11.10 - General Commissioning Cluster
    class FailsafeService
      Log = ::Log.for("matter.commissioning.failsafe_service")

      # Maximum cumulative failsafe duration reported and enforced by default
      DEFAULT_MAX_CUMULATIVE_SECONDS = FailsafeContext::DEFAULT_MAX_CUMULATIVE_SECONDS

      # The armed context, or nil when no commissioning session is in progress
      getter context : FailsafeContext?

      # Fabric of the administrator that armed the current failsafe (nil for PASE)
      getter admin_fabric_index : UInt8?

      # Sticky until the next fresh fail-safe: a backend restore failure means
      # expiry could not guarantee the prior network configuration.
      getter? network_rollback_failed : Bool = false

      # Hard limit on a single ArmFailSafe request and on the cumulative timer
      property max_cumulative_seconds : UInt16

      # Whether a commissioning window is open: a PASE commissioner may take a
      # failsafe over from another administrator only while one is
      property? commissioning_window_open : Bool = false

      # Terms & Conditions feature state
      property? terms_conditions_required : Bool = false
      property? terms_conditions_accepted : Bool = false

      # The optional TC feature supplies version/map validation and maintains
      # temporal acceptance until the fail-safe succeeds or expires.
      property on_terms_conditions_validate : Proc(ErrorCode?)?
      property on_terms_conditions_commit : Proc(Nil)?
      property on_terms_conditions_revert : Proc(Nil)?

      # Invoked when a new failsafe context is armed, so that per-failsafe state
      # elsewhere (the pending credentials of `CredentialService`) is reset
      property on_failsafe_armed : Proc(Nil)?
      property on_failsafe_expired : Proc(Nil)?
      property on_failsafe_success : Proc(Nil)?

      # Invoked before a host or command arms, re-arms, or disarms a failsafe.
      # The separate timer hook covers device-side arming without a commissioner.
      property on_before_arm : Proc(UInt16, UInt8?, Bool, Nil)?
      property on_before_arm_timer : Proc(UInt16, Nil)?
      property on_before_state_change : Proc(Nil)?

      # The device's reentrant protocol mutex, installed before transport starts.
      property protocol_lock : Mutex? = nil

      # Invoked with the breadcrumb the commissioner's progress moved to
      property on_breadcrumb_changed : Proc(UInt64, Nil)?

      def initialize(
        @targets : RollbackTargets,
        @max_cumulative_seconds : UInt16 = DEFAULT_MAX_CUMULATIVE_SECONDS,
      )
      end

      # Whether the failsafe timer is currently running
      def armed? : Bool
        @context.try(&.armed?) || false
      end

      # When the primary failsafe timer will expire, if it is armed
      def expiry_time : Time?
        if remaining = @context.try(&.primary_time_remaining)
          Time.utc + remaining
        end
      end

      # Handle ArmFailSafe (0x00)
      #
      # Arms, re-arms or (with a zero expiry) disarms the failsafe timer, which
      # rolls back every commissioning change if it is left to expire.
      #
      # @param expiry_length_seconds Primary timer duration (0 disarms)
      # @param breadcrumb Progress value the commissioner is tracking
      # @param session_fabric_index Fabric of the requesting session (nil for PASE)
      # @param pase_session Whether the request arrived on a PASE session
      def arm(
        expiry_length_seconds : UInt16,
        breadcrumb : UInt64,
        session_fabric_index : UInt8?,
        pase_session : Bool,
      ) : Outcome
        protocol_lock = @protocol_lock
        protocol_lock.try(&.lock)
        @on_before_arm.try(&.call(expiry_length_seconds, session_fabric_index, pase_session))
        Log.info { "ArmFailSafe: expiry=#{expiry_length_seconds}s, breadcrumb=#{breadcrumb}, fabric=#{session_fabric_index || "PASE"}" }

        if expiry_length_seconds > 0 && expiry_length_seconds > @max_cumulative_seconds
          return Outcome.new(
            ErrorCode::ValueOutsideRange,
            "ExpiryLengthSeconds exceeds max (#{@max_cumulative_seconds}s)"
          )
        end

        # Reserve an open commissioning window for a PASE commissioner.
        # A CASE administrator cannot arm a fresh fail-safe during the window.
        if @context.nil? && commissioning_window_open? && !pase_session
          return Outcome.new(ErrorCode::BusyWithOtherAdmin, "Commissioning window reserved for PASE")
        end

        # An armed fail-safe belongs to its accessing fabric. Once AddNOC
        # records the new fabric, that fabric may continue the PASE context.
        if context = @context
          unless context.matches_fabric?(session_fabric_index)
            return Outcome.new(ErrorCode::BusyWithOtherAdmin, "Another admin is currently commissioning")
          end
        end

        # A zero expiry abandons commissioning and rolls back pending state.
        if expiry_length_seconds == 0
          Log.info { "Expiring failsafe on zero expiry" } if @context
          expire
          return Outcome.new
        end

        if context = @context
          begin
            context.arm(expiry_length_seconds, @max_cumulative_seconds)
            context.breadcrumb = breadcrumb
            self.breadcrumb = breadcrumb

            Log.info { "Re-armed failsafe" }
          rescue ex
            Log.error(exception: ex) do
              "Failed to re-arm failsafe (expiry_length_seconds=#{expiry_length_seconds} " \
              "max_cumulative_seconds=#{@max_cumulative_seconds} breadcrumb=#{breadcrumb} " \
              "session_fabric_index=#{session_fabric_index.inspect} " \
              "commissioning_window_open=#{commissioning_window_open?} pase_session=#{pase_session})"
            end
            return Outcome.new(
              ErrorCode::BusyWithOtherAdmin,
              "Cannot re-arm: #{ex.message}"
            )
          end
        else
          context = FailsafeContext.new(
            associated_fabric_index: session_fabric_index,
            breadcrumb: breadcrumb,
            expiry_callback: -> { handle_expiry }
          )
          @context = context
          @network_rollback_failed = false
          context.arm(expiry_length_seconds, @max_cumulative_seconds)
          @admin_fabric_index = session_fabric_index
          self.breadcrumb = breadcrumb

          # Per-failsafe state held elsewhere starts again with this context.
          @on_failsafe_armed.try &.call

          Log.info { "Armed new failsafe" }
        end

        Outcome.new
      ensure
        protocol_lock.try(&.unlock)
      end

      # Handle CommissioningComplete (0x04)
      #
      # Ends the commissioning session: the failsafe is disarmed without a
      # rollback, the breadcrumb is cleared and the commissioning window closes.
      #
      # @param session_fabric_index Fabric of the requesting session
      # @param case_session Whether the request arrived on a CASE session (required)
      def complete(session_fabric_index : UInt8?, case_session : Bool) : Outcome
        protocol_lock = @protocol_lock
        protocol_lock.try(&.lock)
        @on_before_state_change.try(&.call)
        Log.info { "CommissioningComplete: fabric=#{session_fabric_index}" }

        unless case_session
          return Outcome.new(
            ErrorCode::InvalidAuthentication,
            "CommissioningComplete requires CASE session"
          )
        end

        context = @context
        unless context && context.armed?
          return Outcome.new(ErrorCode::NoFailSafe, "No active failsafe context")
        end

        unless context.matches_fabric?(session_fabric_index)
          return Outcome.new(
            ErrorCode::InvalidAuthentication,
            "Fabric mismatch: expected #{context.associated_fabric_index}, got #{session_fabric_index}"
          )
        end

        if terms_conditions_required? && !terms_conditions_accepted?
          return Outcome.new(
            ErrorCode::RequiredTCNotAccepted,
            "Terms and Conditions not accepted"
          )
        end

        if error = @on_terms_conditions_validate.try(&.call)
          return Outcome.new(error, "Terms and Conditions acknowledgements not satisfied")
        end

        Log.info { "Commissioning completed successfully" }
        @targets.commit_network_state if context.network_state_snapshot
        # Commit credential storage before dropping the fail-safe context.
        # A storage failure must leave a live context that can still expire
        # and roll back; only a durable commit may be acknowledged.
        @on_failsafe_success.try(&.call)
        @on_terms_conditions_commit.try(&.call)
        @targets.close_commissioning_window
        self.breadcrumb = 0_u64
        context.disarm
        @context = nil
        @admin_fabric_index = nil

        Outcome.new
      ensure
        protocol_lock.try(&.unlock)
      end

      # Arm the timer outside of an ArmFailSafe request, creating a PASE context
      # if none is armed. Used by tests and by device-side flows that need the
      # failsafe running without a commissioner.
      def arm_timer(expiry_seconds : UInt16) : Nil
        protocol_lock = @protocol_lock
        protocol_lock.try(&.lock)
        @on_before_arm_timer.try(&.call(expiry_seconds))
        context = @context || begin
          created = FailsafeContext.new(
            associated_fabric_index: nil,
            breadcrumb: 0_u64,
            expiry_callback: -> { handle_expiry }
          )
          @context = created
          created
        end

        context.arm(expiry_seconds, @max_cumulative_seconds)
      ensure
        protocol_lock.try(&.unlock)
      end

      # Disarm and drop the context without rolling anything back
      def disarm : Nil
        protocol_lock = @protocol_lock
        protocol_lock.try(&.lock)
        @on_before_state_change.try(&.call)
        if context = @context
          context.disarm
          @context = nil
          @admin_fabric_index = nil
          @on_terms_conditions_revert.try(&.call)
        end
      ensure
        protocol_lock.try(&.unlock)
      end

      # Record that AddNOC added a fabric during this failsafe, which is what
      # lets CommissioningComplete arrive on a CASE session of the new fabric.
      def record_added_fabric(fabric_index : UInt8) : Nil
        protocol_lock = @protocol_lock
        protocol_lock.try(&.lock)
        @on_before_state_change.try(&.call)
        if context = @context
          context.record_added_fabric(fabric_index)
          @admin_fabric_index = fabric_index
          Log.info { "Recorded added fabric #{fabric_index} in failsafe context" }
        else
          Log.warn { "No failsafe context to record added fabric #{fabric_index}" }
        end
      ensure
        protocol_lock.try(&.unlock)
      end

      # Snapshot the regulatory configuration before SetRegulatoryConfig changes
      # it, so that an expiring failsafe can put it back
      def record_regulatory_config(location_type : UInt8, country_code : String) : Nil
        protocol_lock = @protocol_lock
        protocol_lock.try(&.lock)
        @on_before_state_change.try(&.call)
        if (context = @context) && context.armed?
          context.record_regulatory_config(location_type, country_code)
        end
      ensure
        protocol_lock.try(&.unlock)
      end

      # Expire the failsafe immediately, rolling back provisional state.
      def expire : Nil
        protocol_lock = @protocol_lock
        protocol_lock.try(&.lock)
        @on_before_state_change.try(&.call)
        if context = @context
          context.disarm
          handle_expiry
        end
      ensure
        protocol_lock.try(&.unlock)
      end

      # Roll back every commissioning change made under the expired context
      private def handle_expiry : Nil
        protocol_lock = @protocol_lock
        protocol_lock.try(&.lock)
        @on_before_state_change.try(&.call)
        Log.warn { "Failsafe expired - performing rollback" }

        if context = @context
          @network_rollback_failed = !context.rollback(@targets)
          @context = nil
          @admin_fabric_index = nil
        end

        @on_terms_conditions_revert.try(&.call)
        @on_failsafe_expired.try(&.call)

        @commissioning_window_open = false
        self.breadcrumb = 0_u64
      ensure
        protocol_lock.try(&.unlock)
      end

      private def breadcrumb=(value : UInt64) : Nil
        @on_breadcrumb_changed.try &.call(value)
      end
    end
  end
end
