require "log"

require "../interaction_model/paths"
require "../session/context"
require "./mrp_cache"
require "./persistence"
require "./subscription"

module Matter
  module Protocol
    # The node's secure sessions and active subscriptions, and the one lock
    # that guards them.
    #
    # Everything that touches session or subscription state runs inside
    # `#synchronize`: inbound message handling, the background sweep, and
    # subscription reports raised from cluster callbacks on arbitrary fibers.
    # The mutex is reentrant because the collaborators call back into the
    # registry while already holding it.
    class SessionRegistry
      Log = ::Log.for("matter.protocol.session_registry")

      # Maximum concurrent secure sessions before the oldest are evicted.
      DEFAULT_MAX_SESSIONS = 32_u16

      # How long a session outlives its last subscription before removal.
      DEFAULT_SUBSCRIPTION_GRACE_PERIOD = 30.seconds

      # How long a session survives a transport failure before removal.
      DEFAULT_TRANSPORT_RETRY_WINDOW = 4.seconds

      # How long a session survives a failed CASE resumption.
      CASE_RESUMPTION_GRACE_PERIOD = 5.seconds

      # How often the background sweep looks for expired state.
      SWEEP_INTERVAL = 1.second

      # How often the sweep writes session message counters back to storage.
      SESSION_PERSIST_INTERVAL = 30.seconds

      # Why a session is queued for deferred removal.
      enum CleanupReason
        Superseded           # A newer session from the same peer replaced it
        SubscriptionExpired  # Its last subscription expired
        TransportFailure     # The transport reported the peer unreachable
        CaseResumptionFailed # CASE resumption was attempted and failed
      end

      # A session queued for removal once its grace period expires.
      #
      # A superseding session does not evict the old one immediately: an
      # in-flight exchange may still be answered on it, and its subscriptions
      # may still need migrating.
      class PendingCleanup
        property session_id : UInt16
        property cleanup_at : Time
        property reason : CleanupReason
        property? cancel_on_traffic : Bool

        def initialize(
          @session_id,
          grace_period : Time::Span = DEFAULT_SUBSCRIPTION_GRACE_PERIOD,
          @reason : CleanupReason = CleanupReason::Superseded,
          @cancel_on_traffic : Bool = false,
        )
          @cleanup_at = Time.utc + grace_period
        end

        def ready? : Bool
          Time.utc >= @cleanup_at
        end
      end

      # Secure sessions keyed by our own session id.
      getter sessions : Hash(UInt16, Session::SecureContext) = {} of UInt16 => Session::SecureContext

      # Subscriptions receiving reports, keyed by subscription id.
      getter active_subscriptions : Hash(UInt32, ActiveSubscription) = {} of UInt32 => ActiveSubscription

      # Counts successful subscription establishments since this process
      # started, including subscriptions restored into an active session.
      @total_subscriptions_established : UInt32 = 0_u32

      record SubscriptionLoad, current : UInt16, current_for_fabric : UInt16, total : UInt32

      # Sessions queued for deferred removal.
      getter pending_cleanups : Array(PendingCleanup) = [] of PendingCleanup

      # The id the next subscription will be given.
      property next_subscription_id : UInt32 = 1_u32

      property max_sessions : UInt16
      property subscription_grace_period : Time::Span
      property transport_retry_window : Time::Span

      # Storage hooks; `nil` keeps every session and subscription in memory only.
      property persistence : Persistence::Base?

      # Called when a session is established (CASE or PASE).
      property on_session_established : Proc(Session::SecureContext, Nil)?

      # Called when a session is removed, for whatever reason.
      property on_session_removed : Proc(UInt16, Nil)?

      # Called when a subscription becomes active.
      property on_subscription_established : Proc(ActiveSubscription, Nil)?

      # Called when a subscription is removed (expired, renewed or with its session).
      property on_subscription_removed : Proc(UInt32, Nil)?

      @session_cleanup_hooks = [] of Proc(UInt16, Nil)
      @sweep_hooks = [] of Proc(Nil)

      @mutex : Mutex = Mutex.new(:reentrant)
      @stop : Channel(Nil) = Channel(Nil).new
      @running : Bool = false

      def initialize(
        @mrp_cache : MrpCache,
        @persistence : Persistence::Base? = nil,
        @max_sessions : UInt16 = DEFAULT_MAX_SESSIONS,
        @subscription_grace_period : Time::Span = DEFAULT_SUBSCRIPTION_GRACE_PERIOD,
        @transport_retry_window : Time::Span = DEFAULT_TRANSPORT_RETRY_WINDOW,
      )
      end

      # Runs *block* holding the registry lock.
      #
      # This is the node's one protocol lock: inbound message handling, the
      # sweep fiber and subscription reports all take it, so a report raised
      # from a cluster callback can never interleave with a message being
      # handled.
      def synchronize(&)
        @mutex.synchronize { yield }
      end

      # Shared by device services that need to serialize a complete direct
      # host mutation with inbound protocol requests and recovery decisions.
      def protocol_mutex : Mutex
        @mutex
      end

      # Internal protocol users can release exchange state when a secure
      # session disappears without replacing the application's event callback.
      def add_session_cleanup_hook(callback : Proc(UInt16, Nil)) : Nil
        @mutex.synchronize { @session_cleanup_hooks << callback }
      end

      def add_sweep_hook(callback : Proc(Nil)) : Nil
        @mutex.synchronize { @sweep_hooks << callback }
      end

      # Starts the background sweep that expires subscriptions, runs deferred
      # session cleanups and persists session counters. Idempotent.
      def start : Nil
        @mutex.synchronize do
          return if @running
          @running = true
          @stop = Channel(Nil).new
        end
        spawn { sweep_loop }
      end

      # Stops the background sweep. Idempotent.
      def close : Nil
        stop = nil
        @mutex.synchronize do
          return unless @running
          @running = false
          stop = @stop
        end
        stop.try(&.close)
      end

      # Whether the background sweep is running.
      def running? : Bool
        @mutex.synchronize { @running }
      end

      # The session with this id, if any.
      def session(session_id : UInt16) : Session::SecureContext?
        @mutex.synchronize { @sessions[session_id]? }
      end

      # Registers a freshly established session.
      #
      # Makes room for it, stores it, then persists and announces it. Normally
      # this also migrates subscriptions from sessions it supersedes. Keep an
      # in-flight exchange on the earlier peer session alive when a verified
      # controller CASE session is adopted by this device listener.
      def establish_session(session : Session::SecureContext, preserve_existing : Bool = false) : Nil
        @mutex.synchronize do
          if @sessions.has_key?(session.session_id)
            raise Matter::ProtocolError.new("Secure session ID #{session.session_id} is already in use")
          end
          enforce_session_limit
          @sessions[session.session_id] = session

          # After storing, so the cleanup sees the new session as the replacement.
          cleanup_superseded_sessions(session) unless preserve_existing

          persist(&.session_established(self, session))
          @on_session_established.try(&.call(session))
        end
      end

      # Removes a session and its subscriptions. Returns whether it existed.
      def delete_session(session_id : UInt16) : Bool
        @mutex.synchronize do
          existed = @sessions.has_key?(session_id)
          remove_session_and_subscriptions(session_id)
          @on_session_removed.try(&.call(session_id)) if existed
          existed
        end
      end

      # A closed TCP route cannot be reused, so release every secure session
      # bound to its local token together with its subscriptions.
      def delete_tcp_route_sessions(peer : Socket::IPAddress) : Nil
        @mutex.synchronize do
          @sessions.values
            .select { |session| session.tcp_session? && session.tcp_peer == peer }
            .each do |session|
              remove_session_and_subscriptions(session.session_id)
              @on_session_removed.try(&.call(session.session_id))
            end
        end
      end

      # Registers a subscription that has completed its handshake.
      def add_subscription(subscription : ActiveSubscription) : Nil
        @mutex.synchronize do
          count_subscription_established unless @active_subscriptions.has_key?(subscription.subscription_id)
          @active_subscriptions[subscription.subscription_id] = subscription
          Log.info { "Subscription #{subscription.subscription_id} is now active (watching #{subscription.attribute_paths.size} path(s))" }

          persist(&.subscription_established(self, subscription))
          @on_subscription_established.try(&.call(subscription))
        end
      end

      # Restored subscriptions resume reporting immediately but must not be
      # written back to persistence or invoke an application callback again.
      def restore_subscription(subscription : ActiveSubscription) : Nil
        @mutex.synchronize do
          count_subscription_established unless @active_subscriptions.has_key?(subscription.subscription_id)
          @active_subscriptions[subscription.subscription_id] = subscription
        end
      end

      def subscription_load(fabric_index : UInt8?) : SubscriptionLoad
        @mutex.synchronize do
          current = {@active_subscriptions.size, UInt16::MAX.to_i}.min.to_u16
          for_fabric = 0_u16
          if fabric_index
            count_for_fabric = @active_subscriptions.values.count do |subscription|
              subscription.session.fabric_index == fabric_index
            end
            for_fabric = count_for_fabric.clamp(0, UInt16::MAX.to_i).to_u16
          end
          SubscriptionLoad.new(current, for_fabric, @total_subscriptions_established)
        end
      end

      # KeepSubscriptions=false replaces every active subscription from this
      # CASE node on this fabric, even when the node has established a new
      # secure session since the original subscription.
      def remove_subscriptions_for_subscriber(fabric_index : UInt8, peer_node_id : UInt64) : Nil
        @mutex.synchronize do
          @active_subscriptions.values.select do |subscription|
            owner = subscription.session
            owner.case_session? && owner.fabric_index == fabric_index && owner.peer_node_id.try(&.id) == peer_node_id
          end.each do |subscription|
            @active_subscriptions.delete(subscription.subscription_id)
            forget_subscription(subscription.subscription_id)
          end
        end
      end

      # Terminates a publisher-side subscription after the subscriber rejects
      # a ReportData transaction. Persist the removal just as for expiry.
      def remove_subscription(subscription_id : UInt32) : Nil
        @mutex.synchronize do
          if @active_subscriptions.delete(subscription_id)
            forget_subscription(subscription_id)
          end
        end
      end

      # Claims the next subscription id.
      def allocate_subscription_id : UInt32
        @mutex.synchronize do
          subscription_id = @next_subscription_id
          @next_subscription_id += 1
          subscription_id
        end
      end

      # Replaces *old_subscription_id* with *new_subscription*, as when a
      # controller re-subscribes to paths it already watches.
      def renew_subscription(old_subscription_id : UInt32, new_subscription : ActiveSubscription) : Nil
        @mutex.synchronize do
          if @active_subscriptions.delete(old_subscription_id)
            Log.info { "Renewed subscription #{old_subscription_id} -> #{new_subscription.subscription_id}" }
            forget_subscription(old_subscription_id)
          end

          count_subscription_established
          @active_subscriptions[new_subscription.subscription_id] = new_subscription
        end
      end

      private def count_subscription_established : Nil
        @total_subscriptions_established = @total_subscriptions_established &+ 1_u32 unless @total_subscriptions_established == UInt32::MAX
      end

      # An existing subscription of *session_id* that overlaps *paths* on
      # endpoint and cluster.
      def find_matching_subscription(session_id : UInt16, paths : Array(InteractionModel::AttributePath)) : ActiveSubscription?
        @mutex.synchronize do
          @active_subscriptions.values.find do |subscription|
            next false unless subscription.session.session_id == session_id

            paths.any? do |new_path|
              subscription.attribute_paths.any? do |existing_path|
                new_path.endpoint == existing_path.endpoint && new_path.cluster == existing_path.cluster
              end
            end
          end
        end
      end

      # Drops subscriptions that have gone past their maximum interval and
      # queues their now-idle sessions for removal. Returns the count dropped.
      def process_expired_subscriptions(now : Time = Time.utc) : Int32
        @mutex.synchronize do
          expired = @active_subscriptions.values.select(&.expired?(now))

          expired.each do |subscription|
            session_id = subscription.session.session_id
            Log.info { "Subscription #{subscription.subscription_id} expired (session #{session_id})" }

            @active_subscriptions.delete(subscription.subscription_id)
            forget_subscription(subscription.subscription_id)

            next if session_has_subscriptions?(session_id)

            # Idle session: let traffic save it, otherwise reclaim it.
            schedule_cleanup(
              session_id,
              @subscription_grace_period,
              CleanupReason::SubscriptionExpired,
              cancel_on_traffic: true
            )
          end

          expired.size
        end
      end

      # Runs the deferred removals whose grace period has expired, migrating
      # subscriptions to a superseding session where one exists. Returns the
      # number of sessions cleaned up.
      def process_pending_cleanups : Int32
        @mutex.synchronize do
          ready = @pending_cleanups.select(&.ready?)

          ready.each do |pending|
            @pending_cleanups.delete(pending)
            Log.info { "Processing pending cleanup for session #{pending.session_id} (reason: #{pending.reason})" }
            evict_session(pending.session_id)
          end

          ready.size
        end
      end

      # Cancels a deferred removal when traffic proves the peer is still there.
      def cancel_cleanup_on_traffic(session_id : UInt16) : Bool
        @mutex.synchronize do
          canceled = false
          @pending_cleanups.reject! do |pending|
            next false unless pending.session_id == session_id && pending.cancel_on_traffic?

            Log.info { "Canceling pending cleanup for session #{session_id} - traffic detected" }
            canceled = true
            true
          end
          canceled
        end
      end

      # Queues a session for removal after the transport gave up on its peer.
      def mark_transport_failure(session_id : UInt16) : Nil
        @mutex.synchronize do
          return unless @sessions.has_key?(session_id)

          if schedule_cleanup(session_id, @transport_retry_window, CleanupReason::TransportFailure, cancel_on_traffic: true)
            Log.warn { "Transport failure for session #{session_id} - scheduling cleanup after #{@transport_retry_window}" }
          end
        end
      end

      # Queues a session for removal after CASE resumption failed on it. The
      # peer will establish a new session if it still wants one, so traffic
      # does not cancel this.
      def mark_case_resumption_failed(session_id : UInt16) : Nil
        @mutex.synchronize do
          return unless @sessions.has_key?(session_id)

          if schedule_cleanup(session_id, CASE_RESUMPTION_GRACE_PERIOD, CleanupReason::CaseResumptionFailed, cancel_on_traffic: false)
            Log.warn { "CASE resumption failed for session #{session_id} - scheduling cleanup" }
          end
        end
      end

      # Writes every CASE session back to storage, so message counters survive
      # a restart. Called by the sweep and before a graceful shutdown.
      def persist_all_sessions : Nil
        store = @persistence
        return unless store

        @mutex.synchronize do
          persisted = 0
          @sessions.each_value do |session|
            next unless session.case_session?

            begin
              store.session_updated(self, session)
              persisted += 1
            rescue ex
              Log.error(exception: ex) do
                "Failed to persist session #{session.session_id} " \
                "(fabric_index=#{session.fabric_index.inspect} peer_node_id=#{session.peer_node_id.try(&.id).inspect} " \
                "peer_session_id=#{session.peer_session_id})"
              end
            end
          end
          Log.debug { "Persisted #{persisted} CASE session(s)" } if persisted > 0
        end
      end

      # ----------------------------------------------------------------------
      # Background sweep
      # ----------------------------------------------------------------------

      private def sweep_loop : Nil
        stop = @stop
        since_persist = Time::Span.zero

        loop do
          select
          when stop.receive?
            break
          when timeout(SWEEP_INTERVAL)
          end
          break unless running?

          @mutex.synchronize { @sweep_hooks.each(&.call) }
          process_expired_subscriptions
          process_pending_cleanups

          since_persist += SWEEP_INTERVAL
          if since_persist >= SESSION_PERSIST_INTERVAL
            persist_all_sessions
            since_persist = Time::Span.zero
          end
        rescue ex
          # A failing sweep must not leave sessions and subscriptions to pile up.
          Log.error(exception: ex) do
            "Session sweep failed (sessions=#{@sessions.size} subscriptions=#{@active_subscriptions.size} " \
            "pending_cleanups=#{@pending_cleanups.size})"
          end
        end
      end

      # ----------------------------------------------------------------------
      # Supersession
      # ----------------------------------------------------------------------

      # The CASE sessions *new_session* replaces: same fabric, same peer node,
      # established earlier.
      #
      # Matter 4.13.2.5: a node SHOULD close the session a new one supersedes.
      # Session ids can wrap, so age decides, not ordering.
      private def find_superseded_sessions(new_session : Session::SecureContext) : Array(Session::SecureContext)
        new_peer_node = new_session.peer_node_id
        new_fabric = new_session.fabric_index
        return [] of Session::SecureContext unless new_session.case_session? && new_fabric && new_peer_node

        @sessions.values.select do |session|
          next false unless session.case_session?
          next false unless session.fabric_index == new_fabric
          next false if session.session_id == new_session.session_id

          peer_node = session.peer_node_id
          next false unless peer_node

          peer_node.id == new_peer_node.id && session.creation_time < new_session.creation_time
        end
      end

      # The newest session that can take over from *old_session_id*.
      private def find_superseding_session(old_session_id : UInt16) : Session::SecureContext?
        old_session = @sessions[old_session_id]?
        return unless old_session
        return unless old_session.case_session?

        old_fabric = old_session.fabric_index
        old_peer_node = old_session.peer_node_id
        return unless old_fabric && old_peer_node

        @sessions.values.select do |session|
          next false unless session.case_session?
          next false unless session.fabric_index == old_fabric
          next false if session.session_id == old_session_id

          peer_node = session.peer_node_id
          next false unless peer_node

          peer_node.id == old_peer_node.id && session.creation_time > old_session.creation_time
        end.max_by?(&.creation_time)
      end

      # Migrates subscriptions off every session *new_session* supersedes, then
      # removes those sessions.
      private def cleanup_superseded_sessions(new_session : Session::SecureContext) : Nil
        superseded = find_superseded_sessions(new_session)
        return if superseded.empty?

        Log.info { "Found #{superseded.size} superseded session(s) to clean up" }

        superseded.each do |old_session|
          migrate_subscriptions(old_session.session_id, new_session)
          remove_session_only(old_session.session_id)
        end
      end

      # Repoints the subscriptions of *old_session_id* at *new_session* so a
      # controller re-establishing CASE keeps its reports.
      private def migrate_subscriptions(old_session_id : UInt16, new_session : Session::SecureContext) : Nil
        migrating = @active_subscriptions.values.select { |subscription| subscription.session.session_id == old_session_id }

        if migrating.empty?
          Log.info { "No subscriptions to migrate from session #{old_session_id}" }
          return
        end

        Log.info { "Migrating #{migrating.size} subscription(s) from session #{old_session_id} to session #{new_session.session_id}" }

        migrating.each do |subscription|
          subscription.session = new_session
          Log.info { "Migrated subscription #{subscription.subscription_id} to new session #{new_session.session_id}" }
          persist(&.subscription_established(self, subscription))
        end
      end

      # ----------------------------------------------------------------------
      # Removal
      # ----------------------------------------------------------------------

      # Removes *session_id*, migrating its subscriptions to a superseding
      # session if one exists, and announces the removal.
      private def evict_session(session_id : UInt16) : Nil
        superseding = session_has_subscriptions?(session_id) ? find_superseding_session(session_id) : nil

        if superseding
          Log.info { "Found superseding session #{superseding.session_id} for cleanup of #{session_id}" }
          migrate_subscriptions(session_id, superseding)
          remove_session_only(session_id)
        else
          remove_session_and_subscriptions(session_id)
        end

        @on_session_removed.try(&.call(session_id))
      end

      # Removes a session, leaving its subscriptions alone (they were migrated).
      private def remove_session_only(session_id : UInt16) : Nil
        @mrp_cache.clear_session(session_id)
        @pending_cleanups.reject! { |pending| pending.session_id == session_id }

        session = @sessions.delete(session_id)
        return unless session

        @session_cleanup_hooks.each(&.call(session_id))

        persist(&.session_removed(self, session_id))
        Log.info { "Removed session #{session_id} (fabric=#{session.fabric_index}, peer=#{session.peer_node_id.try(&.id)})" }
      end

      private def remove_session_and_subscriptions(session_id : UInt16) : Nil
        @active_subscriptions.values
          .select { |subscription| subscription.session.session_id == session_id }
          .each do |subscription|
            @active_subscriptions.delete(subscription.subscription_id)
            forget_subscription(subscription.subscription_id)
            Log.info { "Removed subscription #{subscription.subscription_id} (from session #{session_id})" }
          end

        remove_session_only(session_id)
      end

      # Persists and announces the removal of a subscription already dropped
      # from the table.
      private def forget_subscription(subscription_id : UInt32) : Nil
        persist(&.subscription_removed(self, subscription_id))
        @on_subscription_removed.try(&.call(subscription_id))
      end

      private def session_has_subscriptions?(session_id : UInt16) : Bool
        @active_subscriptions.each_value.any? { |subscription| subscription.session.session_id == session_id }
      end

      # Queues a deferred removal unless one is already queued for the session.
      # Returns whether it was queued.
      private def schedule_cleanup(
        session_id : UInt16,
        grace_period : Time::Span,
        reason : CleanupReason,
        cancel_on_traffic : Bool,
      ) : Bool
        return false if @pending_cleanups.any? { |pending| pending.session_id == session_id }

        @pending_cleanups << PendingCleanup.new(session_id, grace_period, reason, cancel_on_traffic: cancel_on_traffic)
        true
      end

      # Evicts sessions until a new one fits, oldest first and PASE before CASE.
      private def enforce_session_limit : Nil
        return if @sessions.size < @max_sessions

        candidates = @sessions.values.sort_by! do |session|
          {session.case_session? ? 1 : 0, session.creation_time}
        end

        while @sessions.size >= @max_sessions && !candidates.empty?
          session = candidates.shift
          Log.info { "Evicting oldest session #{session.session_id} to stay under limit of #{@max_sessions}" }
          evict_session(session.session_id)
        end
      end

      # Runs a persistence hook, logging rather than raising: losing a write
      # must not abort session handling.
      private def persist(& : Persistence::Base ->) : Nil
        store = @persistence
        return unless store

        yield store
      rescue ex
        Log.error(exception: ex) { "Persistence hook failed" }
      end
    end
  end
end
