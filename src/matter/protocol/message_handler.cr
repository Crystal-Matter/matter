require "../cluster/basic_information"
require "../cluster/general_diagnostics"
require "../cluster/general_commissioning"
require "../cluster/operational_credentials"
require "../cluster/commissioner_control"
require "../cluster/diagnostic_logs"
require "../cluster/group_key_management"
require "../cluster/groupcast"
require "../cluster/low_power"
require "../cluster/scenes_management"
require "../codec/message_codec"
require "../fabric_table"
require "../node"
require "../session/context"
require "../session/secure_message"
require "../session/group_secure_packet"
require "../transport/group_multicast"
require "../transport/tcp_enabled_transport"
require "../transport/udp_transport"
require "./interaction_router"
require "./bdx/responder"
require "./bdx/initiator"
require "./message_type"
require "./mrp_cache"
require "./persistence"
require "./response_sender"
require "./secure_channel"
require "./session_registry"
require "./subscription_manager"

module Matter
  module Protocol
    # The node's front door: it decrypts an inbound message, classifies its
    # counter, replays a cached response to a retransmission, and hands what is
    # left to the protocol that owns it - `SecureChannel` for PASE and CASE,
    # `InteractionRouter` for reads, writes, invokes and subscriptions.
    #
    # It also assembles those collaborators around one `SessionRegistry`, whose
    # lock every one of them runs under, and keeps the accessors the device and
    # the clusters reach for.
    class MessageHandler
      Log = ::Log.for("matter.protocol.message_handler")

      # PBKDF parameters advertised during PASE unless a commissioning window
      # supplies its own.
      DEFAULT_PBKDF_ITERATIONS =   1000_u32
      PBKDF_SALT_LENGTH        =         32
      DEFAULT_PRODUCT_ID       = 0x8001_u16

      getter transport : Transport::PacketTransport
      getter bdx : Bdx::Responder
      getter bdx_initiator : Bdx::Initiator

      # Network receive must remain free while a cluster handler performs a
      # controller exchange through the same socket. One worker preserves the
      # device's inbound message ordering.
      INBOUND_QUEUE_LIMIT           = 256
      BDX_QUEUE_LIMIT               =  16
      BDX_WORKER_LIMIT              = Bdx::Responder::MAX_ACTIVE_TRANSFERS
      BDX_SHUTDOWN_GRACE            = 100.milliseconds
      UNSENT_INVOKE_RETRY_WINDOW    = 10.seconds
      MAX_UNSENT_INVOKE_RETRIES     = 64
      DEFERRED_LOG_RESPONSE_TIMEOUT = 5.minutes
      @inbound_messages : Channel(Tuple(Codec::MessageCodec::Message, Socket::IPAddress))
      @inbound_done : Channel(Nil)

      private record BdxTask, message : Codec::MessageCodec::Message,
        peer : Socket::IPAddress, session : Session::SecureContext,
        opcode : Bdx::Wire::Opcode
      private record BdxAbort, session : Session::SecureContext, exchange_id : UInt16
      private alias BdxWork = BdxTask | BdxAbort
      private record UnsentInvokeRetry, session : Session::SecureContext,
        exchange_id : UInt16, payload : Bytes, expires_at : Time::Instant
      @unsent_invoke_retries = {} of Tuple(UInt64, UInt32) => UnsentInvokeRetry
      private record DeferredLogResponse, prepared : InteractionRouter::PreparedInvoke,
        expires_at : Time::Instant
      @deferred_log_responses = {} of Tuple(UInt64, UInt16) => DeferredLogResponse
      private record DeferredBdxBlock,
        accept : Codec::MessageCodec::Message,
        peer : Socket::IPAddress,
        session : Session::SecureContext,
        message : Bdx::Transfer::Message
      @deferred_bdx_blocks = {} of Tuple(UInt64, UInt16) => DeferredBdxBlock

      private class BdxLane
        getter session : Session::SecureContext
        getter tasks : Channel(BdxTask)
        getter aborts : Channel(BdxAbort)
        property queued : Int32 = 0

        def initialize(@session : Session::SecureContext)
          @tasks = Channel(BdxTask).new(BDX_QUEUE_LIMIT)
          @aborts = Channel(BdxAbort).new(BDX_WORKER_LIMIT)
        end
      end

      @bdx_lanes : Hash(UInt16, BdxLane)
      @bdx_worker_count : Int32
      @bdx_worker_done : Channel(Nil)
      @bdx_housekeeping_stop : Channel(Nil)
      @bdx_housekeeping_done : Channel(Nil)
      @bdx_cleanup_signal : Channel(Nil)
      @bdx_cleanup : Array(Session::SecureContext)
      @bdx_active_sessions : Hash(UInt16, Session::SecureContext)
      @bdx_closing : Bool

      # Sessions, subscriptions and the lock every protocol fiber shares.
      getter registry : SessionRegistry

      # The subscription handshakes and report fan-out.
      getter subscriptions : SubscriptionManager

      # Encrypts and sends everything the node puts on the wire.
      getter sender : ResponseSender

      # The data model this handler serves: endpoints, their clusters and the
      # flat index the Interaction Model resolves paths against.
      getter node : Node

      getter fabric_table : FabricTable
      getter discriminator : UInt16
      getter operational_credentials_cluster : Cluster::OperationalCredentials?
      getter persistence : Persistence::Base?

      @im_stats_mutex : Mutex = Mutex.new
      @im_messages_sent : UInt32 = 0_u32
      @im_messages_received : UInt32 = 0_u32

      property vendor_id : UInt16
      property product_id : UInt16

      # Commissioning callback - called when a fabric is successfully added (AddNOC complete)
      # The device should use this to switch from commissioning to operational mDNS advertisement
      property on_commissioned : Proc(Fabric, Nil)?

      # The session and subscription state, and the callbacks the device hooks
      # into, live in the registry; these delegate so the rest of the library
      # and the specs address one object.
      delegate sessions, active_subscriptions, to: @registry
      delegate next_subscription_id, :next_subscription_id=, to: @registry
      delegate max_sessions, :max_sessions=, to: @registry
      delegate subscription_grace_period, :subscription_grace_period=, to: @registry
      delegate transport_retry_window, :transport_retry_window=, to: @registry
      delegate on_session_established, :on_session_established=, to: @registry
      delegate on_session_removed, :on_session_removed=, to: @registry
      delegate on_subscription_established, :on_subscription_established=, to: @registry
      delegate on_subscription_removed, :on_subscription_removed=, to: @registry
      delegate delete_session, persist_all_sessions, to: @registry
      delegate process_pending_cleanups, process_expired_subscriptions, to: @registry
      delegate cancel_cleanup_on_traffic, mark_transport_failure, mark_case_resumption_failed, to: @registry
      delegate renew_subscription, find_matching_subscription, to: @registry

      # The PASE parameters a commissioning window configures, and the fabric
      # lookup CASE falls back on.
      delegate configure_pase_server, configure_pase_pin, reset_pase_server, to: @secure_channel
      delegate on_get_fabric, :on_get_fabric=, to: @secure_channel

      def configure_local_mrp(idle_interval_ms : UInt32?, active_interval_ms : UInt32?,
                              active_threshold_ms : UInt16? = nil) : Nil
        @secure_channel.configure_local_mrp(idle_interval_ms, active_interval_ms,
          active_threshold_ms)
      end

      def initialize(
        @transport : Transport::PacketTransport,
        setup_pin : UInt32,
        @discriminator : UInt16,
        @fabric_table : FabricTable,
        iterations : UInt32 = DEFAULT_PBKDF_ITERATIONS,
        salt : Bytes = Random::Secure.random_bytes(PBKDF_SALT_LENGTH),
        @vendor_id : UInt16 = Fabric::DEFAULT_VENDOR_ID,
        @product_id : UInt16 = DEFAULT_PRODUCT_ID,
        max_sessions : UInt16 = SessionRegistry::DEFAULT_MAX_SESSIONS,
        subscription_grace_period : Time::Span = SessionRegistry::DEFAULT_SUBSCRIPTION_GRACE_PERIOD,
        transport_retry_window : Time::Span = SessionRegistry::DEFAULT_TRANSPORT_RETRY_WINDOW,
        @persistence : Persistence::Base? = nil,
      )
        @mrp_cache = MrpCache.new(@transport)
        @registry = SessionRegistry.new(
          mrp_cache: @mrp_cache,
          persistence: @persistence,
          max_sessions: max_sessions,
          subscription_grace_period: subscription_grace_period,
          transport_retry_window: transport_retry_window
        )
        @tcp_disconnect_observer_id = nil.as(Int32?)
        @on_commissioned = nil
        @operational_credentials_cluster = nil

        # Initialize clusters
        journal = if persistence = @persistence
                    store = persistence.as(Persistence::Base)
                    next_number = store.restore_next_event_number || EventJournal::FIRST_EVENT_NUMBER
                    EventJournal.new(->(number : UInt64) { store.persist_next_event_number(number) }, next_number)
                  else
                    EventJournal.new
                  end
        @node = Node.new(journal)
        initialize_clusters

        @sender = ResponseSender.new(@transport, @mrp_cache)
        @sender.on_im_message_sent = -> { record_im_message_sent }
        @bdx = Bdx::Responder.new
        @bdx_initiator = Bdx::Initiator.new(@sender)
        @bdx_lanes = {} of UInt16 => BdxLane
        @bdx_worker_count = 0
        @bdx_worker_done = Channel(Nil).new(1)
        @bdx_housekeeping_stop = Channel(Nil).new
        @bdx_housekeeping_done = Channel(Nil).new(1)
        @bdx_cleanup_signal = Channel(Nil).new(1)
        @bdx_cleanup = [] of Session::SecureContext
        @bdx_active_sessions = {} of UInt16 => Session::SecureContext
        @bdx_closing = false
        @registry.add_session_cleanup_hook(->(id : UInt16) { queue_bdx_session_cleanup(id) })
        @registry.add_session_cleanup_hook(->(id : UInt16) { @bdx_initiator.forget_session(id) })
        @registry.add_sweep_hook(-> { @bdx_initiator.sweep })
        @registry.add_session_cleanup_hook(->(id : UInt16) { forget_deferred_log_responses(id) })
        @registry.add_sweep_hook(-> { expire_deferred_log_responses })
        @registry.add_sweep_hook(-> { @unsent_invoke_retries.reject! { |_, retry| retry.expires_at < Time.instant } })
        @subscriptions = SubscriptionManager.new(@registry, @node, @sender)
        @registry.add_session_cleanup_hook(->(id : UInt16) { @subscriptions.forget_invoke_session(id) })
        @registry.add_sweep_hook(-> { @subscriptions.tick })
        @secure_channel = SecureChannel.new(@fabric_table, @registry, @sender, setup_pin, iterations, salt)
        @router = InteractionRouter.new(@registry, @node, @subscriptions, @sender)
        @router.on_invoke_request_accepted = ->(session_identity : UInt64, exchange_id : UInt16) do
          # A newer authenticated Invoke on this live exchange supersedes any
          # prior unsent response. Its delayed MRP retransmission must not run
          # cluster commands or displace the new chunk ladder.
          @unsent_invoke_retries.reject! do |key, retry_entry|
            key[0] == session_identity && retry_entry.exchange_id == exchange_id
          end
          abandon_deferred_log_response(session_identity, exchange_id)
          abandon_deferred_bdx_block(session_identity, exchange_id)
        end
        @router.on_invoke_response_prepared = ->(prepared : InteractionRouter::PreparedInvoke) do
          defer_log_response(prepared)
        end
        @router.on_invoke_response_sent = ->(session_identity : UInt64, exchange_id : UInt16) do
          start_pending_commissions(session_identity, exchange_id)
          start_pending_sleeps(session_identity, exchange_id)
          start_pending_camera_signaling(session_identity, exchange_id)
          @bdx_initiator.start_pending(session_identity, exchange_id)
          flush_deferred_bdx_block(session_identity, exchange_id)
        end
        @router.on_invoke_response_failed = ->(session : Session::SecureContext, request : Codec::MessageCodec::Message) do
          session_identity = session.object_id.to_u64
          exchange_id = request.payload_header.exchange_id
          @bdx_initiator.discard_pending(session_identity, exchange_id)
          if discard_pending_commissions(session_identity, exchange_id) &&
             sole_commission_node_invoke?(request.payload)
            now = Time.instant
            @unsent_invoke_retries.reject! { |_, retry| retry.expires_at < now }
            if @unsent_invoke_retries.size >= MAX_UNSENT_INVOKE_RETRIES
              oldest = @unsent_invoke_retries.min_by? { |_, retry| retry.expires_at }
              @unsent_invoke_retries.delete(oldest[0]) if oldest
            end
            @unsent_invoke_retries[{session_identity, request.packet_header.message_id}] =
              UnsentInvokeRetry.new(session, exchange_id, request.payload.dup,
                now + UNSENT_INVOKE_RETRY_WINDOW)
          end
          discard_pending_sleeps(session_identity, exchange_id)
          discard_pending_camera_signaling(session_identity, exchange_id)
          abandon_deferred_bdx_block(session_identity, exchange_id)
        end
        @router.on_invoke_response_abandoned = ->(session_identity : UInt64, exchange_id : UInt16) do
          @bdx_initiator.discard_pending(session_identity, exchange_id)
          discard_pending_commissions(session_identity, exchange_id)
          discard_pending_sleeps(session_identity, exchange_id)
          discard_pending_camera_signaling(session_identity, exchange_id)
          abandon_deferred_bdx_block(session_identity, exchange_id)
        end
        @group_packets = Session::GroupSecurePacket.new([] of Session::GroupSecurePacket::Key)

        @inbound_messages = Channel(Tuple(Codec::MessageCodec::Message, Socket::IPAddress)).new(INBOUND_QUEUE_LIMIT)
        @inbound_done = Channel(Nil).new(1)
        spawn do
          while entry = @inbound_messages.receive?
            handle_message(entry[0], entry[1], background_bdx: true)
          end
        ensure
          @inbound_done.send(nil)
        end

        spawn do
          loop do
            select
            when @bdx_housekeeping_stop.receive?
              break
            when @bdx_cleanup_signal.receive?
            when timeout(SessionRegistry::SWEEP_INTERVAL)
            end
            process_bdx_cleanup
            @bdx.sweep
          end
        ensure
          @bdx_housekeeping_done.send(nil)
        end

        # Set ourselves as the message handler
        @transport.on_message = ->(msg : Codec::MessageCodec::Message, peer : Socket::IPAddress) do
          payload = msg.payload.dup
          header_bytes = msg.header_bytes.try(&.dup)
          detached = Codec::MessageCodec::Message.new(msg.packet_header, msg.payload_header, payload, header_bytes)
          @inbound_messages.send({detached, peer})
      rescue Channel::ClosedError
          # A transport receive fiber can finish a packet while the handler is closing.
        end
        @transport.on_group_packet = ->(wire : Bytes, peer : Socket::IPAddress) do
          handle_group_packet(wire, peer)
        end
        if tcp = @transport.as?(Transport::TcpEnabledTransport)
          @tcp_disconnect_observer_id = tcp.add_connection_closed_observer do |peer|
            @registry.delete_tcp_route_sessions(peer)
          end
        end

        # Restore persisted protocol state (CASE sessions + subscriptions)
        if persistence = @persistence
          begin
            persistence.restore(@registry, @fabric_table)
            # A legacy store may have subscription cursors but no durable
            # journal counter. Start above the largest restored cursor so new
            # events remain visible and event numbers never move backwards.
            if cursor = @registry.active_subscriptions.values.max_of?(&.last_event_number)
              @node.event_journal.advance_next_event_number(cursor + 1_u64)
            end
          rescue ex
            Log.error(exception: ex) { "Failed to restore protocol persistence (persistence=#{persistence.class})" }
          end
        end

        @registry.start
      end

      # Stops the registry background sweep. The transport is closed by its
      # owner; this releases what the handler itself started.
      def close : Nil
        if id = @tcp_disconnect_observer_id
          @transport.as(Transport::TcpEnabledTransport).remove_connection_closed_observer(id)
          @tcp_disconnect_observer_id = nil
        end
        unless @inbound_messages.closed?
          @inbound_messages.close
          @inbound_done.receive
        end
        close_bdx = @registry.synchronize do
          if !@bdx_closing
            @bdx_closing = true
            @bdx_lanes.each_value { |lane| lane.tasks.close unless lane.tasks.closed? }
            @bdx_lanes.clear
            true
          else
            false
          end
        end
        if close_bdx
          @bdx_housekeeping_stop.close
          finished = Channel(Nil).new(1)
          spawn do
            await_bdx_workers
            finish_bdx_shutdown
            finished.send(nil)
          end
          select
          when finished.receive
          when timeout(BDX_SHUTDOWN_GRACE)
          end
        end
        @registry.synchronize do
          @bdx_initiator.close
          @deferred_log_responses.clear
          @deferred_bdx_blocks.clear
        end
        @registry.close
      end

      # The cluster supplies the authenticated command context. Resolve the
      # actual CASE session here rather than trusting a request field alone.
      def queue_bdx_transfer(session_id : UInt16, fabric_index : UInt8,
                             peer_node_id : UInt64, peer : Socket::IPAddress,
                             designator : Bytes, content : Bytes,
                             origin_exchange_id : UInt16) : Bool
        @registry.synchronize do
          session = @registry.sessions[session_id]?
          return false unless session && session.case_session? &&
                              session.fabric_index == fabric_index &&
                              session.peer_node_id.try(&.id) == peer_node_id
          @bdx_initiator.queue(session, peer, designator, content, origin_exchange_id)
        end
      end

      def queue_diagnostic_log_transfer(session_id : UInt16, fabric_index : UInt8,
                                        peer_node_id : UInt64, peer : Socket::IPAddress,
                                        designator : Bytes, content : Bytes,
                                        origin_exchange_id : UInt16) : Cluster::DiagnosticLogs::TransferStartResult
        @registry.synchronize do
          session = @registry.sessions[session_id]?
          unless session && session.case_session? &&
                 session.fabric_index == fabric_index &&
                 session.peer_node_id.try(&.id) == peer_node_id
            return Cluster::DiagnosticLogs::TransferStartResult::Unavailable
          end
          return Cluster::DiagnosticLogs::TransferStartResult::Busy if @bdx_initiator.busy?
          if @bdx_initiator.queue(session, peer, designator, content, origin_exchange_id)
            Cluster::DiagnosticLogs::TransferStartResult::Queued
          else
            Cluster::DiagnosticLogs::TransferStartResult::Unavailable
          end
        end
      end

      private def defer_log_response(prepared : InteractionRouter::PreparedInvoke) : Bool
        session = prepared.session
        origin_exchange_id = prepared.original_msg.payload_header.exchange_id
        return false unless @bdx_initiator.pending_for?(session, origin_exchange_id)

        # Validate the whole response before opening a second exchange. While
        # BDX negotiates, a standalone ACK answers retransmitted Invokes.
        IMHandler.encode_chunked_invoke_response(prepared.responses,
          suppress_response: prepared.suppress_response,
          max_payload_size: @sender.im_payload_limit(session, prepared.peer),
          request_paths: prepared.request_paths)
        @sender.send_encrypted_ack(prepared.original_msg, prepared.peer, session,
          cache_for_mrp: true)
        exchange_id = @bdx_initiator.start_pending_for(session, origin_exchange_id) ||
                      raise Matter::ProtocolError.new("Queued Diagnostic Logs transfer disappeared")
        key = {session.object_id.to_u64, exchange_id}
        @deferred_log_responses[key] = DeferredLogResponse.new(prepared,
          Time.instant + DEFERRED_LOG_RESPONSE_TIMEOUT)
        true
      rescue ex
        @bdx_initiator.discard_pending(session.object_id.to_u64, origin_exchange_id)
        Log.warn(exception: ex) { "Could not initiate deferred Diagnostic Logs transfer" }
        @router.send_prepared_invoke(denied_log_response(prepared))
        true
      end

      private def denied_log_response(prepared : InteractionRouter::PreparedInvoke) : InteractionRouter::PreparedInvoke
        replaced = false
        responses = prepared.responses.map do |response|
          data = response.command_data
          if data && data.command_path.cluster == Cluster::DiagnosticLogs::CLUSTER_ID &&
             data.command_path.command == Cluster::DiagnosticLogs::CMD_RETRIEVE_LOGS_REQUEST_RESPONSE &&
             !replaced && (fields = data.command_fields)
            payload = Cluster::DiagnosticLogs::RetrieveLogsResponse.from_tlv(fields)
            if payload.status.success? && payload.log_content.empty?
              replaced = true
              denied = Cluster::DiagnosticLogs::RetrieveLogsResponse.new(
                Cluster::DiagnosticLogs::LogsStatus::Denied, Bytes.empty)
              next InteractionModel::InvokeResponseIB.new(command_data: InteractionModel::CommandDataIBTlv.new(
                data.command_path, denied.to_tlv(nil)))
            end
          end
          response
        end
        InteractionRouter::PreparedInvoke.new(prepared.original_msg, prepared.peer,
          prepared.session, responses, prepared.suppress_response, prepared.request_paths)
      end

      private def take_deferred_log_response(session : Session::SecureContext,
                                             exchange_id : UInt16) : DeferredLogResponse?
        @deferred_log_responses.delete({session.object_id.to_u64, exchange_id})
      end

      private def abandon_deferred_log_response(session_identity : UInt64,
                                                invoke_exchange_id : UInt16) : Nil
        @deferred_log_responses.reject! do |key, deferred|
          plan = deferred.prepared
          next false unless key[0] == session_identity &&
                            plan.original_msg.payload_header.exchange_id == invoke_exchange_id
          @bdx_initiator.abort(plan.session.session_id, key[1])
          true
        end
      end

      private def forget_deferred_log_responses(session_id : UInt16) : Nil
        @deferred_log_responses.reject! { |_, deferred| deferred.prepared.session.session_id == session_id }
        @deferred_bdx_blocks.reject! { |_, deferred| deferred.session.session_id == session_id }
      end

      private def flush_deferred_bdx_block(session_identity : UInt64,
                                           invoke_exchange_id : UInt16) : Nil
        pending = @deferred_bdx_blocks.delete({session_identity, invoke_exchange_id})
        return unless pending
        return unless @registry.sessions[pending.session.session_id]?.same?(pending.session)
        @sender.send_bdx_response(pending.accept, pending.peer, pending.session,
          pending.message.opcode.value, pending.message.to_slice)
      rescue ex
        @bdx_initiator.abort(pending.session.session_id, pending.accept.payload_header.exchange_id) if pending
        Log.warn(exception: ex) { "Failed to send Diagnostic Logs BDX block after InvokeResponse" }
      end

      private def abandon_deferred_bdx_block(session_identity : UInt64,
                                             invoke_exchange_id : UInt16) : Nil
        if pending = @deferred_bdx_blocks.delete({session_identity, invoke_exchange_id})
          @bdx_initiator.abort(pending.session.session_id, pending.accept.payload_header.exchange_id)
        end
      end

      private def abandon_deferred_bdx_exchange(session : Session::SecureContext,
                                                bdx_exchange_id : UInt16) : Nil
        @deferred_bdx_blocks.reject! do |_, pending|
          pending.session.same?(session) &&
            pending.accept.payload_header.exchange_id == bdx_exchange_id
        end
      end

      private def expire_deferred_log_responses(now : Time::Instant = Time.instant) : Nil
        @deferred_log_responses.reject! do |key, deferred|
          next false if deferred.expires_at > now
          @bdx_initiator.abort(deferred.prepared.session.session_id, key[1])
          if @registry.sessions[deferred.prepared.session.session_id]?.same?(deferred.prepared.session)
            @router.send_prepared_invoke(denied_log_response(deferred.prepared))
          end
          true
        end
      end

      private def commissioner_controls : Array(Cluster::CommissionerControl)
        @node.clusters.values.compact_map(&.as?(Cluster::CommissionerControl))
      end

      private def camera_providers : Array(Cluster::WebRtcTransportProvider)
        @node.clusters.values.compact_map(&.as?(Cluster::WebRtcTransportProvider))
      end

      private def start_pending_camera_signaling(session_identity : UInt64, exchange_id : UInt16) : Nil
        camera_providers.each do |provider|
          provider.take_pending_signaling(session_identity, exchange_id).each do |task|
            spawn do
              @registry.synchronize { nil }
              task.call
            rescue ex
              Log.error(exception: ex) { "Deferred Camera signaling failed" }
            end
          end
        end
      end

      private def discard_pending_camera_signaling(session_identity : UInt64, exchange_id : UInt16) : Nil
        camera_providers.each(&.discard_pending_signaling(session_identity, exchange_id))
      end

      private def start_pending_commissions(session_identity : UInt64, exchange_id : UInt16) : Nil
        commissioner_controls.each do |control|
          control.take_pending_commissions(session_identity, exchange_id).each do |commission|
            spawn do
              # The router's callback runs under the protocol lock. Wait for
              # that InvokeRequest to release it before performing controller IO.
              @registry.synchronize { nil }
              commission.call
            rescue ex
              Log.error(exception: ex) { "Deferred reverse commissioning failed" }
            end
          end
        end
      end

      private def discard_pending_commissions(session_identity : UInt64, exchange_id : UInt16) : Bool
        discarded = false
        commissioner_controls.each do |control|
          discarded = control.discard_pending_commissions(session_identity, exchange_id) || discarded
        end
        discarded
      end

      # Re-execution is safe only when CommissionNode was the sole command.
      # Another command in the InvokeRequest may have succeeded before send.
      private def sole_commission_node_invoke?(payload : Bytes) : Bool
        request = IMHandler.parse_invoke_request(payload)
        return false unless request && request.invoke_requests.size == 1
        path = request.invoke_requests.first.command_path
        path.cluster == Cluster::CommissionerControl::CLUSTER_ID &&
          path.command == Cluster::CommissionerControl::CMD_COMMISSION_NODE
      end

      private def start_pending_sleeps(session_identity : UInt64, exchange_id : UInt16) : Nil
        @node.clusters.values.each do |cluster|
          next unless low_power = cluster.as?(Cluster::LowPower)
          next unless transition = low_power.take_pending_sleep(session_identity, exchange_id)
          spawn do
            # The response was transmitted, but the router still holds the
            # protocol lock. Let it finish before the platform enters sleep.
            @registry.synchronize { nil }
            transition.call
          rescue ex
            Log.error(exception: ex) { "Deferred Low Power transition failed" }
          end
        end
      end

      private def discard_pending_sleeps(session_identity : UInt64, exchange_id : UInt16) : Nil
        @node.clusters.values.each do |cluster|
          cluster.as?(Cluster::LowPower).try(&.discard_pending_sleep(session_identity, exchange_id))
        end
      end

      # The clusters of the node, keyed by `{endpoint, cluster}`.
      #
      # Inserting into this hash registers a cluster without an endpoint; it is
      # the escape hatch the protocol specs use. Devices build endpoints
      # through `node` instead.
      def clusters : Hash(Tuple(UInt16, UInt32), Cluster::Base)
        @node.clusters
      end

      # A snapshot for the revision-3 GeneralDiagnostics DeviceLoadStatus
      # attribute. Subscription state is read under the registry's lock, and
      # packet counters are protected against concurrent sender fibers.
      def device_load_status(fabric_index : UInt8?) : Cluster::GeneralDiagnostics::DeviceLoadStruct
        subscriptions = @registry.subscription_load(fabric_index)
        @im_stats_mutex.synchronize do
          Cluster::GeneralDiagnostics::DeviceLoadStruct.new(
            subscriptions.current,
            subscriptions.current_for_fabric,
            subscriptions.total,
            @im_messages_sent,
            @im_messages_received
          )
        end
      end

      private def record_im_message_sent : Nil
        @im_stats_mutex.synchronize do
          @im_messages_sent = @im_messages_sent &+ 1_u32 unless @im_messages_sent == UInt32::MAX
        end
      end

      private def record_im_message_received : Nil
        @im_stats_mutex.synchronize do
          @im_messages_received = @im_messages_received &+ 1_u32 unless @im_messages_received == UInt32::MAX
        end
      end

      # Initialize device clusters (called during construction)
      #
      # These are placeholders that let a bare handler answer a read before a
      # device has been built on top of it; `Matter::Device` replaces the root
      # endpoint wholesale with the real clusters. The endpoint carries no
      # device type, so it is not held to the Root Node conformance a device
      # must satisfy.
      private def initialize_clusters : Nil
        # Endpoint 0 - Root Node endpoint (required)
        endpoint_0 = DataType::EndpointNumber.new(Node::ROOT_ENDPOINT_ID)
        root = Endpoint.new(endpoint_0)

        # Basic Information cluster (0x0028) - required on endpoint 0
        # Use the device's vendor_id and product_id to ensure consistency
        # with DAC certificates and Certification Declaration
        root.add_cluster(Cluster::BasicInformation.new(
          endpoint_id: endpoint_0,
          vendor_name: "Crystal Matter",
          vendor_id: @vendor_id,
          product_name: "Matter Device",
          product_id: @product_id
        ))

        # General Commissioning cluster (0x0030) - required on endpoint 0
        root.add_cluster(Cluster::GeneralCommissioning.new(endpoint_0))

        # Operational Credentials cluster (0x003E) - required on endpoint 0 for commissioning
        # NOTE: We do NOT call set_attestation_from_manager here because:
        # 1. The device application should set up its own attestation credentials
        # 2. Calling it here AND in the device causes double DAC keypair generation
        # 3. The device example overwrites these clusters anyway
        # The device application must call set_attestation_from_manager or set_attestation_credentials
        operational_creds = Cluster::OperationalCredentials.new(@fabric_table, endpoint_0)

        # Set up session_lookup callback so the cluster can get attestation challenge from sessions
        # This is CRITICAL for attestation signature verification - per Matter spec,
        # attestation signature must be over (attestation_elements || attestation_challenge)
        operational_creds.session_lookup = ->(session_id : UInt64) : Bytes? do
          # Look up session by ID and return its attestation challenge
          session = @registry.sessions[session_id.to_u16]?
          if session
            Log.trace { "session_lookup: session_id=#{session_id} found, returning attestation_challenge" }
            session.attestation_challenge
          else
            Log.trace { "session_lookup: session_id=#{session_id} not found" }
            nil
          end
        end

        # Set up on_fabric_added callback to forward to on_commissioned
        # This allows the device to switch from commissioning to operational mDNS advertisement
        operational_creds.on_fabric_added = ->(fabric : Fabric) do
          Log.info { "Fabric added: fabric_id=#{fabric.fabric_id}, node_id=#{fabric.node_id}, compressed_fabric_id=#{fabric.compressed_fabric_id.hexstring.upcase}" }
          if callback = @on_commissioned
            callback.call(fabric)
          end
        end

        root.add_cluster(operational_creds)
        @operational_credentials_cluster = operational_creds

        # The Descriptor cluster (0x001D), required on every endpoint per the
        # Matter spec, is injected and populated by `Node#add_endpoint`.
        @node.add_endpoint(root)

        Log.debug { "MessageHandler initialized with #{clusters.size} default clusters (device may add more)" }
      end

      # Wire up attribute change notification callbacks for all clusters
      # This should be called after all clusters have been added to the clusters hash
      # It enables automatic subscription updates when attributes change
      def setup_cluster_notifications
        if group_keys = @node.get_cluster(Cluster::GroupKeyManagement)
          @node.clusters.each_value do |cluster|
            next unless groups = cluster.as?(Cluster::Groups)
            groups.on_group_added = ->(group_id : UInt16, endpoint_id : UInt16, name : String, fabric_index : UInt8) do
              group_keys.add_group(group_id, endpoint_id, name, fabric_index)
            end
            groups.on_group_removed = ->(group_id : UInt16, endpoint_id : UInt16, fabric_index : UInt8) do
              group_keys.remove_group(group_id, endpoint_id, fabric_index)
            end
          end
        end
        @node.on_attribute_changed = ->(ep : UInt16, cl : UInt32, attr : UInt32) do
          @subscriptions.notify(ep, cl, attr)
          if cl == Cluster::GroupKeyManagement::CLUSTER_ID &&
             (attr == Cluster::GroupKeyManagement::ATTR_GROUP_TABLE || attr == Cluster::GroupKeyManagement::ATTR_GROUP_KEY_MAP)
            refresh_group_memberships
          end
        end
        @node.on_event_emitted = ->(_record : EventJournal::Record) do
          @subscriptions.notify_events
        end
        Log.debug { "Set up attribute change and event notifications for #{clusters.size} cluster(s)" }

        emit_start_up_event
      end

      # Journals BasicInformation's StartUp event. The node is fully built by
      # the time notifications are wired, so this is where it boots.
      private def emit_start_up_event : Nil
        basic = @node.get_cluster(Cluster::BasicInformation)
        return unless basic

        basic.emit_start_up_event(basic.software_version)
      end

      # Reports one changed attribute to every subscription watching it.
      def notify_subscriptions(endpoint_id : UInt16, cluster_id : UInt32, attribute_id : UInt32) : Nil
        @subscriptions.notify(endpoint_id, cluster_id, attribute_id)
      end

      # Reports a batch of changed attributes, one ReportData per subscription.
      def notify_subscriptions_batched(attributes : Array(Tuple(UInt16, UInt32, UInt32))) : Nil
        @subscriptions.notify_batched(attributes)
      end

      # Decrypts and classifies under the registry lock so replay counters and
      # encrypted responses stay ordered. BDX responder callbacks and stream IO
      # run after releasing that lock. The transport worker queues them so a
      # blocked application stream cannot stall another secure session.
      def handle_message(msg : Codec::MessageCodec::Message, peer : Socket::IPAddress,
                         background_bdx : Bool = false) : Nil
        work = @registry.synchronize do
          session = nil
          session_id = msg.packet_header.session_id

          if session_id != 0
            Log.trace { "Message is encrypted (session_id=#{session_id}), decrypting" }

            session = @registry.sessions[session_id]?
            unless session
              Log.warn { "Dropping encrypted message: no session found (session_id=#{session_id})" }
              return
            end

            unless session.accepts_peer?(peer)
              Log.warn { "Dropping encrypted message on another transport or TCP connection (session_id=#{session_id})" }
              return
            end

            message_counter = msg.packet_header.message_id
            authenticated_retry = nil.as(Codec::MessageCodec::Message?)
            case session.check_peer_message_counter(message_counter)
            when Transport::MessageCounter::CheckResult::Duplicate
              # The peer retransmitted; answer from the cache rather than
              # re-running cluster logic.
              return if @mrp_cache.resend?(session_id, message_counter, peer)
              retry_key = {session.object_id.to_u64, message_counter}
              if retry_entry = @unsent_invoke_retries[retry_key]?
                if retry_entry.session.same?(session) && Time.instant <= retry_entry.expires_at
                  begin
                    candidate = decrypt_message(msg, session)
                    header = candidate.payload_header
                    if header.protocol_id == ProtocolId::InteractionModel.value &&
                       header.message_type == InteractionModel::MessageType::InvokeRequest.value &&
                       header.exchange_id == retry_entry.exchange_id && candidate.payload == retry_entry.payload
                      authenticated_retry = candidate
                      @unsent_invoke_retries.delete(retry_key)
                    end
                  rescue ex
                    Log.debug(exception: ex) { "Invalid retransmission of unsent Commissioner Control response" }
                  end
                else
                  @unsent_invoke_retries.delete(retry_key)
                end
              end
              unless authenticated_retry
                Log.trace { "Dropping duplicate message with no cached response: session_id=#{session_id}, counter=#{message_counter}" }
                return
              end
            when Transport::MessageCounter::CheckResult::Stale
              Log.trace { "Dropping stale message outside the receive window: session_id=#{session_id}, counter=#{message_counter}" }
              return
            end

            msg = authenticated_retry || decrypt_message(msg, session)
            @transport.mark_mrp_peer_active(peer, session_id)
            if ack = msg.payload_header.acknowledged_message_id
              @transport.acknowledge_reliable(session_id,
                msg.payload_header.exchange_id, ack)
            end
            @registry.cancel_cleanup_on_traffic(session_id)
          end

          Log.debug { "Received message: protocol=0x#{msg.payload_header.protocol_id.to_s(16)}, type=0x#{msg.payload_header.message_type.to_s(16)}" }
          route(msg, peer, session)
        end
        return unless work

        if background_bdx
          enqueue_bdx_work(work)
        else
          process_bdx_work(work)
        end
      rescue ex
        Log.debug(exception: ex) do
          "Error handling message: peer=#{peer.address}:#{peer.port} session_id=#{msg.packet_header.session_id} " \
          "msg_id=#{msg.packet_header.message_id} protocol=0x#{msg.payload_header.protocol_id.to_s(16)} " \
          "type=0x#{msg.payload_header.message_type.to_s(16)} exchange=#{msg.payload_header.exchange_id} " \
          "payload_bytes=#{msg.payload.size}"
        end
      end

      # One bounded lane per CASE session preserves that peer's exchange order
      # while independent sessions can run their application IO concurrently.
      private def enqueue_bdx_work(task : BdxTask) : Nil
        @registry.synchronize do
          return if @bdx_closing || !@registry.sessions[task.session.session_id]?.same?(task.session)
          if lane = bdx_lane_for(task.session)
            select
            when lane.tasks.send(task)
              lane.queued += 1
              return
            else
            end
          end
          @sender.send_bdx_status(task.message, task.peer, task.session,
            Bdx::Transfer::StatusCode::ResponderBusy)
        end
      rescue Channel::ClosedError
        # The handler is shutting down.
      end

      private def enqueue_bdx_work(abort : BdxAbort) : Nil
        @registry.synchronize do
          if lane = @bdx_lanes[abort.session.session_id]?
            return unless lane.session.same?(abort.session)
            select
            when lane.aborts.send(abort)
            else
            end
          end
        end
      end

      # Caller holds the registry lock so lane admission and capacity remain
      # atomic with the authenticated session lookup.
      private def bdx_lane_for(session : Session::SecureContext) : BdxLane?
        if lane = @bdx_lanes[session.session_id]?
          return lane if lane.session.same?(session)
          @bdx_lanes.delete(session.session_id)
          lane.tasks.close unless lane.tasks.closed?
        end
        return if @bdx_worker_count >= BDX_WORKER_LIMIT
        lane = BdxLane.new(session)
        @bdx_lanes[session.session_id] = lane
        @bdx_worker_count += 1
        spawn { run_bdx_lane(lane) }
        lane
      end

      private def run_bdx_lane(lane : BdxLane) : Nil
        loop do
          select
          when task = lane.tasks.receive?
            break unless task
            begin
              process_bdx_work(task)
            rescue ex
              Log.warn(exception: ex) { "Failed processing queued BDX work" }
            ensure
              @registry.synchronize { lane.queued -= 1 }
            end
          when abort = lane.aborts.receive?
            process_bdx_work(abort) if abort
          when timeout(SessionRegistry::SWEEP_INTERVAL)
          end
          retire_bdx_lane_if_idle(lane)
        end
      ensure
        @registry.synchronize do
          @bdx_worker_count -= 1
          @bdx_lanes.delete(lane.session.session_id) if @bdx_lanes[lane.session.session_id]?.same?(lane)
        end
        select
        when @bdx_worker_done.send(nil)
        else
        end
      end

      private def retire_bdx_lane_if_idle(lane : BdxLane) : Nil
        active = @bdx.active_for_session?(lane.session)
        @registry.synchronize do
          if lane.queued == 0 && !active && @bdx_lanes[lane.session.session_id]?.same?(lane)
            @bdx_lanes.delete(lane.session.session_id)
            lane.tasks.close unless lane.tasks.closed?
          end
        end
      end

      private def process_bdx_work(abort : BdxAbort) : Nil
        @bdx.abort(abort.session, abort.exchange_id)
      end

      private def process_bdx_work(task : BdxTask) : Nil
        return if task.session.fabric_index.try { |index| @fabric_table.quarantined?(index) }
        return unless @registry.synchronize do
                        !@bdx_closing && @registry.sessions[task.session.session_id]?.same?(task.session)
                      end
        step = @bdx.receive(task.session, task.message.payload_header.exchange_id,
          task.opcode, task.message.payload)
        active = @bdx.active_for_session?(task.session)

        live = false
        @registry.synchronize do
          session_id = task.session.session_id
          if !@bdx_closing && @registry.sessions[session_id]?.same?(task.session)
            live = true
            if active
              @bdx_active_sessions[session_id] = task.session
            else
              @bdx_active_sessions.delete(session_id)
            end
            if status = step.status
              @sender.send_bdx_status(task.message, task.peer, task.session, status)
            elsif message = step.message
              @sender.send_bdx_response(task.message, task.peer, task.session,
                message.opcode.value, message.to_slice)
              if follow_up = step.follow_up
                @sender.send_bdx_response(task.message, task.peer, task.session,
                  follow_up.opcode.value, follow_up.to_slice, append_to_cache: true)
              end
            else
              @sender.send_encrypted_ack(task.message, task.peer, task.session, cache_for_mrp: true)
            end
          else
            @bdx_active_sessions.delete(session_id)
          end
        end
        @bdx.forget_session(task.session) unless live
      end

      # Called by SessionRegistry while its lock is held. Only record a
      # session whose responder has live streams; closing an application IO
      # may block and is delegated to the separate BDX worker.
      private def queue_bdx_session_cleanup(session_id : UInt16) : Nil
        lane = @bdx_lanes.delete(session_id)
        lane.try { |worker| worker.tasks.close unless worker.tasks.closed? }
        session = lane.try(&.session) || @bdx_active_sessions[session_id]?
        @bdx_active_sessions.delete(session_id)
        if session
          @bdx_cleanup << session
          select
          when @bdx_cleanup_signal.send(nil)
          else
          end
        end
      end

      private def process_bdx_cleanup : Nil
        sessions = @registry.synchronize do
          pending = @bdx_cleanup
          @bdx_cleanup = [] of Session::SecureContext
          pending
        end
        sessions.each do |session|
          @bdx.forget_session(session)
        end
      end

      private def finish_bdx_shutdown : Nil
        process_bdx_cleanup
        @bdx.close
      end

      private def await_bdx_workers : Nil
        until @registry.synchronize { @bdx_worker_count == 0 }
          @bdx_worker_done.receive
        end
        @bdx_housekeeping_done.receive
      end

      # Authenticated Group packets bypass unicast session lookup and never
      # enter the ordinary IM router, which assumes a CASE/PASE session.
      def handle_group_packet(wire : Bytes, peer : Socket::IPAddress) : Nil
        @registry.synchronize do
          keys = group_candidate_keys
          return if keys.empty? && @node.get_cluster(Cluster::Groupcast).nil?
          @group_packets.keys = keys
          decoded = @group_packets.decode(wire)
          if decoded.message.payload_header.protocol_id == ProtocolId::InteractionModel.value
            record_im_message_received
          end
          if group_keys = @node.get_cluster(Cluster::GroupKeyManagement)
            GroupInteractionRouter.new(@node.clusters, group_keys).handle(decoded)
          end
          if groupcast = @node.get_cluster(Cluster::Groupcast)
            if group_id = decoded.message.packet_header.destination_group_id
              groupcast.record_group_message(decoded.fabric_index, group_id.id,
                Cluster::Groupcast::GroupcastTestResultEnum::Success)
            end
          end
        end
      rescue ex : Session::GroupSecurePacket::NoAvailableKey
        @node.get_cluster(Cluster::Groupcast).try(&.record_group_message(ex.fabric_index,
          ex.group_id, Cluster::Groupcast::GroupcastTestResultEnum::NoAvailableKey))
        Log.debug(exception: ex) { "Dropping group packet from #{peer}" }
      rescue ex : Session::GroupSecurePacket::FailedAuth
        @node.get_cluster(Cluster::Groupcast).try(&.record_group_message(nil, nil,
          Cluster::Groupcast::GroupcastTestResultEnum::FailedAuth))
        Log.debug(exception: ex) { "Dropping group packet from #{peer}" }
      rescue ex : Session::GroupSecurePacket::Replay
        @node.get_cluster(Cluster::Groupcast).try(&.record_group_message(ex.fabric_index,
          ex.group_id, Cluster::Groupcast::GroupcastTestResultEnum::MessageReplay))
        Log.debug(exception: ex) { "Dropping group packet from #{peer}" }
      rescue ex
        @node.get_cluster(Cluster::Groupcast).try(&.record_group_message(nil, nil,
          Cluster::Groupcast::GroupcastTestResultEnum::GeneralError))
        Log.debug(exception: ex) { "Dropping group packet from #{peer}" }
      end

      def refresh_group_memberships : Nil
        group_keys = @node.get_cluster(Cluster::GroupKeyManagement)
        return unless group_keys
        addresses = @fabric_table.all_fabrics.flat_map do |fabric|
          groupcast_memberships = @node.get_cluster(Cluster::Groupcast).try(&.membership(fabric.fabric_index)) ||
                                  [] of Cluster::Groupcast::MembershipStruct
          addresses_for_fabric = [] of Socket::IPAddress
          groupcast_memberships.each do |member|
            next if member.endpoints.empty?
            address = if member.mcast_addr_policy.per_group?
                        Transport::GroupMulticast.address(fabric.fabric_id, member.group_id, @transport.port)
                      else
                        Transport::GroupMulticast.iana_address(@transport.port)
                      end
            addresses_for_fabric << address
          end
          groupcast_ids = groupcast_memberships.map(&.group_id)
          mapped = group_keys.operational_group_key_map(fabric.fabric_index).map(&.group_id)
          group_keys.operational_group_table(fabric.fabric_index).each do |group|
            next unless mapped.includes?(group.group_id)
            next if groupcast_ids.includes?(group.group_id)
            addresses_for_fabric << Transport::GroupMulticast.address(fabric.fabric_id,
              group.group_id, @transport.port)
          end
          addresses_for_fabric
        end
        @transport.group_memberships = addresses.uniq
      rescue ex
        Log.warn(exception: ex) { "Failed to update group multicast memberships" }
      end

      # Remove every group credential and membership associated with a fabric
      # before its local index can be reused by a new commissioner.
      def forget_group_fabric(fabric_index : UInt8) : Nil
        @group_packets.forget_fabric_reception(fabric_index)
        @node.get_cluster(Cluster::Groupcast).try(&.remove_fabric(fabric_index))
        @node.get_cluster(Cluster::GroupKeyManagement).try(&.remove_fabric(fabric_index))
        @node.clusters.each_value do |cluster|
          cluster.as?(Cluster::Groups).try(&.remove_fabric(fabric_index))
          cluster.as?(Cluster::ScenesManagement).try(&.remove_fabric(fabric_index))
        end
        refresh_group_memberships
      end

      private def group_candidate_keys : Array(Session::GroupSecurePacket::Key)
        group_keys = @node.get_cluster(Cluster::GroupKeyManagement)
        return [] of Session::GroupSecurePacket::Key unless group_keys
        result = [] of Session::GroupSecurePacket::Key
        @fabric_table.all_fabrics.each do |fabric|
          group_keys.operational_group_key_map(fabric.fabric_index).each do |mapping|
            next if mapping.group_key_set_id == Cluster::GroupKeyManagement::IPK_KEY_SET_ID
            key_set = group_keys.get_key_set(mapping.group_key_set_id, fabric.fabric_index)
            next unless key_set
            {
              {key_set.epoch_key0, key_set.epoch_start_time0},
              {key_set.epoch_key1, key_set.epoch_start_time1},
              {key_set.epoch_key2, key_set.epoch_start_time2},
            }.each do |epoch, start_time|
              next unless epoch && start_time && start_time != UInt64::MAX
              operational = Session::GroupSecurePacket.derive_operational_key(epoch, fabric.compressed_fabric_id)
              result << Session::GroupSecurePacket::Key.new(fabric.fabric_index, mapping.group_id, operational)
            end
          end
        end
        result
      end

      # Hands a decrypted message to the protocol that owns it.
      private def route(
        msg : Codec::MessageCodec::Message,
        peer : Socket::IPAddress,
        session : Session::SecureContext?,
      ) : BdxWork?
        case msg.payload_header.protocol_id
        when ProtocolId::SecureChannel.value
          if session && msg.payload_header.message_type == SecureChannelMessageType::StatusReport.value
            begin
              report = Session::Pase::Definitions::StatusReport.from_bytes(msg.payload)
              if report.protocol_id == ProtocolId::Bdx.value && report.vendor_id == Codec::MessageCodec::COMMON_VENDOR_ID
                deferred = take_deferred_log_response(session, msg.payload_header.exchange_id)
                @bdx_initiator.abort(session.session_id, msg.payload_header.exchange_id)
                abandon_deferred_bdx_exchange(session, msg.payload_header.exchange_id)
                @sender.send_encrypted_ack(msg, peer, session, cache_for_mrp: true) if msg.payload_header.requires_acknowledge?
                @router.send_prepared_invoke(denied_log_response(deferred.prepared)) if deferred
                return BdxAbort.new(session, msg.payload_header.exchange_id)
              end
            rescue ex : IO::EOFError
              Log.debug(exception: ex) { "Malformed encrypted status report on BDX exchange" }
            end
          end
          handle_secure_channel(msg, peer)
        when ProtocolId::InteractionModel.value
          unless session
            Log.warn { "Dropping IM message: no session found (session_id=#{msg.packet_header.session_id})" }
            return
          end
          if session.fabric_index.try { |index| @fabric_table.quarantined?(index) }
            Log.warn { "Dropping IM message on quarantined fabric" }
            return
          end

          record_im_message_received
          @router.handle(msg, peer, session)
        when ProtocolId::Bdx.value
          unless session && session.case_session?
            Log.warn { "Dropping BDX message without CASE session" }
            return
          end
          return if session.fabric_index.try { |index| @fabric_table.quarantined?(index) }
          unless msg.payload_header.requires_acknowledge?
            @sender.send_bdx_status(msg, peer, session, Bdx::Transfer::StatusCode::BadMessageContents)
            return
          end
          opcode = Bdx::Wire::Opcode.from_value?(msg.payload_header.message_type)
          unless opcode
            @sender.send_bdx_status(msg, peer, session, Bdx::Transfer::StatusCode::BadMessageContents)
            return
          end
          if @bdx_initiator.handles?(session.session_id, msg.payload_header.exchange_id)
            status, response = @bdx_initiator.receive(session, msg.payload_header.exchange_id, opcode,
              msg.payload, msg.payload_header.initiator_message?)
            if !status && opcode.send_accept?
              if deferred = take_deferred_log_response(session, msg.payload_header.exchange_id)
                if response
                  original = deferred.prepared.original_msg
                  origin = {session.object_id.to_u64, original.payload_header.exchange_id}
                  @deferred_bdx_blocks[origin] = DeferredBdxBlock.new(msg, peer, session, response)
                end
                @sender.send_encrypted_ack(msg, peer, session, cache_for_mrp: true)
                @router.send_prepared_invoke(deferred.prepared)
                return
              end
            end
            if status
              @sender.send_bdx_status(msg, peer, session, status)
              abandon_deferred_bdx_exchange(session, msg.payload_header.exchange_id)
              if deferred = take_deferred_log_response(session, msg.payload_header.exchange_id)
                @router.send_prepared_invoke(denied_log_response(deferred.prepared))
              end
            elsif response
              @sender.send_bdx_response(msg, peer, session, response.opcode.value,
                response.to_slice)
            else
              @sender.send_encrypted_ack(msg, peer, session, cache_for_mrp: true)
            end
            return
          end
          BdxTask.new(msg, peer, session, opcode)
        else
          Log.warn { "Unsupported protocol: 0x#{msg.payload_header.protocol_id.to_s(16)}" }
        end
      end

      # Decrypt an encrypted message and re-parse the payload header
      private def decrypt_message(
        msg : Codec::MessageCodec::Message,
        session : Session::SecureContext,
      ) : Codec::MessageCodec::Message
        decrypted = Session::SecureMessage.decode(session,
          Codec::MessageCodec::Packet.new(msg.packet_header, msg.payload, msg.header_bytes))

        # Some controllers (notably iOS) may omit or otherwise vary the peer identity
        # we can extract during CASE establishment; however encrypted packet headers
        # may still carry the source NodeId. Populate it so ACL checks have a stable
        # subject for CASE interactions.
        if session.case_session?
          if session.peer_node_id.nil?
            if source = msg.packet_header.source_node_id
              session.peer_node_id = source
              Log.debug { "Populated CASE peer_node_id from packet header: 0x#{source.id.to_s(16)} (session_id=#{session.session_id})" }
            end
          end

          if session.peer_subject_ids.empty?
            if peer = session.peer_node_id
              session.peer_subject_ids = [peer.id]
            end
          end
        end

        decrypted
      end

      # Routes a Secure Channel message: the handshakes belong to the secure
      # channel, a bare acknowledgement to the subscription chunk ladder.
      private def handle_secure_channel(msg : Codec::MessageCodec::Message, peer : Socket::IPAddress) : Nil
        if msg.payload_header.message_type == SecureChannelMessageType::StandaloneAck.value
          handle_standalone_ack(msg)
          return
        end

        unless @secure_channel.handle(msg, peer)
          Log.warn { "Unsupported Secure Channel message type: 0x#{msg.payload_header.message_type.to_s(16)}" }
        end
      end

      private def handle_standalone_ack(msg : Codec::MessageCodec::Message) : Nil
        Log.debug { "Received StandaloneAck" }
        if ack_msg_id = msg.payload_header.acknowledged_message_id
          Log.debug { "  Acknowledging message ID: #{ack_msg_id}" }
        end

        # iOS acknowledges priming/read chunks with a bare MRP ACK. Active
        # subscription update ladders require an IM StatusResponse.
        @subscriptions.advance(msg.payload_header.exchange_id, msg)
      end
    end
  end
end
