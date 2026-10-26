require "log"
require "./failsafe_timer"
require "./rollback_targets"

module Matter
  module Commissioning
    # FailsafeContext manages commissioning state and coordinates rollback on failure
    #
    # The failsafe context is created when ArmFailSafe is invoked and tracks all
    # commissioning state changes (fabric operations, network config, etc.) so that
    # they can be rolled back if the failsafe timer expires.
    #
    # Matter Core Spec §11.10.7 - General Commissioning Cluster
    # Matter Core Spec §5.5 - Commissioning Flows
    class FailsafeContext
      Log = ::Log.for("matter.commissioning.failsafe_context")

      # Default maximum cumulative failsafe duration (Matter spec maximum)
      DEFAULT_MAX_CUMULATIVE_SECONDS = 900_u16

      # Fabric index associated with this context (nil for PASE/initial commissioning)
      property associated_fabric_index : UInt8?

      # Breadcrumb value for progress tracking
      property breadcrumb : UInt64

      # Maximum cumulative failsafe timeout (hard limit)
      property max_cumulative_seconds : UInt16

      # Network commissioning state snapshot (for rollback)
      property network_state_snapshot : Hash(String, String)?

      # Whether a new fabric was added during this context
      property added_fabric_index : UInt8?

      # Regulatory config snapshot (for rollback)
      property regulatory_config_snapshot : Tuple(UInt8, String)? # (location_type, country_code)

      @timer : FailsafeTimer?
      @expiry_callback : Proc(Nil)

      # Create a new failsafe context
      #
      # @param fabric_index Fabric index for CASE sessions (nil for PASE)
      # @param breadcrumb Progress tracking value
      # @param expiry_callback Callback invoked when failsafe expires (performs rollback)
      def initialize(
        @associated_fabric_index : UInt8?,
        @breadcrumb : UInt64,
        @expiry_callback : Proc(Nil),
      )
        @max_cumulative_seconds = DEFAULT_MAX_CUMULATIVE_SECONDS
        @network_state_snapshot = nil
        @added_fabric_index = nil
        @regulatory_config_snapshot = nil
        @timer = nil

        Log.info { "Created failsafe context: fabric=#{@associated_fabric_index || "PASE"}, breadcrumb=#{breadcrumb}" }
      end

      # Arm the failsafe timer with specified durations
      #
      # @param expiry_length Primary timer duration in seconds (0 = disarm)
      # @param max_cumulative Maximum cumulative duration in seconds
      def arm(expiry_length : UInt16, max_cumulative : UInt16) : Nil
        if expiry_length == 0
          # Disarm the failsafe
          disarm
          return
        end

        # If timer already exists, re-arm it
        if timer = @timer
          timer.re_arm(@associated_fabric_index, expiry_length)
          Log.info { "Re-armed failsafe: primary=#{expiry_length}s" }
          return
        end

        # Create new timer
        @max_cumulative_seconds = max_cumulative
        @timer = FailsafeTimer.new(
          fabric_index: @associated_fabric_index,
          expiry_length: expiry_length,
          max_cumulative: max_cumulative,
          expiry_callback: @expiry_callback
        )

        Log.info { "Armed failsafe: primary=#{expiry_length}s, cumulative=#{max_cumulative}s" }
      end

      # Disarm the failsafe timer (mark as completed without triggering rollback)
      def disarm : Nil
        if timer = @timer
          timer.complete
          @timer = nil
          Log.info { "Disarmed failsafe" }
        end
      end

      # Check if the failsafe timer is currently armed
      def armed? : Bool
        if timer = @timer
          timer.running?
        else
          false
        end
      end

      # Get time remaining on primary timer
      def primary_time_remaining : Time::Span?
        @timer.try(&.primary_time_remaining)
      end

      # Get time remaining on cumulative timer
      def cumulative_time_remaining : Time::Span?
        @timer.try(&.cumulative_time_remaining)
      end

      # Validate that fabric index matches this context
      #
      # @param fabric_index Fabric index to validate
      # @return true if matches, false otherwise
      #
      # AddNOC transfers ownership explicitly through record_added_fabric.
      def matches_fabric?(fabric_index : UInt8?) : Bool
        @associated_fabric_index == fabric_index
      end

      # Record that a new fabric was added during commissioning
      #
      # This will be rolled back if failsafe expires.
      def record_added_fabric(fabric_index : UInt8) : Nil
        @added_fabric_index = fabric_index
        # Update associated fabric index to the new fabric
        @associated_fabric_index = fabric_index
        @timer.try &.associated_fabric_index=(fabric_index)
        Log.info { "Recorded added fabric: #{fabric_index}" }
      end

      # Record network commissioning state for rollback
      #
      # @param state Snapshot of network configuration
      def record_network_state(state : Hash(String, String)) : Nil
        @network_state_snapshot = state
        Log.debug { "Recorded network state snapshot" }
      end

      # Record regulatory config state for rollback
      #
      # @param location_type Current regulatory location type (as UInt8)
      # @param country_code Current country code (2-character string)
      def record_regulatory_config(location_type : UInt8, country_code : String) : Nil
        # Only record the first snapshot (don't overwrite on subsequent changes)
        if @regulatory_config_snapshot.nil?
          @regulatory_config_snapshot = {location_type, country_code}
          Log.debug { "Recorded regulatory config snapshot: location=#{location_type}, country=#{country_code}" }
        end
      end

      # Perform complete rollback of all commissioning state
      #
      # This implements the rollback sequence from the Matter spec. The steps this
      # context cannot perform itself are named below: the credentials it never
      # sees (fabrics, NOCs, CSR state) belong to `CredentialService`, and the
      # PASE sessions belong to the protocol layer.
      #
      # 1. Revoke added fabric (if AddNOC was used) - caller, via `added_fabric_index`
      # 2. Revert UpdateNOC changes - caller
      # 3. Restore network commissioning state
      # 4. Clear PASE sessions - protocol layer
      # 5. Reset breadcrumb to 0
      # 6. Close commissioning windows
      # 7. Reset regulatory config
      # 8. Clean up temporary state
      #
      # @param targets The live state to restore (nil leaves steps 3, 6 and 7 to the caller)
      def rollback(targets : RollbackTargets? = nil) : Nil
        Log.warn { "Performing failsafe rollback" }

        # Step 3: Restore network commissioning state
        if (snapshot = @network_state_snapshot) && (target = targets)
          begin
            target.restore_network_state(snapshot)
            Log.info { "Restored network commissioning state" }
          rescue ex
            Log.error(exception: ex) { "Failed to restore network state (snapshot=#{snapshot.inspect})" }
          end
        end

        # Step 5: Reset breadcrumb to 0
        @breadcrumb = 0_u64
        Log.debug { "Reset breadcrumb to 0" }

        # Step 6: Close commissioning windows
        if target = targets
          begin
            target.close_commissioning_window
            Log.info { "Closed commissioning window" }
          rescue ex
            Log.error(exception: ex) { "Failed to close commissioning window (target=#{target.class})" }
          end
        end

        # Step 7: Reset regulatory config
        if (snapshot = @regulatory_config_snapshot) && (target = targets)
          begin
            location_type, country_code = snapshot
            target.restore_regulatory_config(location_type, country_code)
            Log.info { "Restored regulatory config: location=#{location_type}, country=#{country_code}" }
          rescue ex
            location_type, country_code = snapshot
            Log.error(exception: ex) { "Failed to restore regulatory config (location=#{location_type} country=#{country_code})" }
          end
        end

        # Step 8: Clean up temporary state
        @network_state_snapshot = nil
        @added_fabric_index = nil
        @regulatory_config_snapshot = nil
        Log.debug { "Cleaned up temporary state" }

        Log.warn { "Rollback completed" }
      end

      # Close and cleanup the failsafe context
      #
      # Should be called when context is destroyed.
      def close : Nil
        if timer = @timer
          timer.close
          @timer = nil
        end
        Log.debug { "Closed failsafe context" }
      end
    end
  end
end
