require "../cluster/basic_information"
require "../cluster/general_commissioning"
require "../cluster/operational_credentials"
require "../cluster/group_key_management"
require "../codec/message_codec"
require "../fabric_table"
require "../node"
require "../session/context"
require "../session/secure_message"
require "../session/group_secure_packet"
require "../transport/group_multicast"
require "../transport/udp_transport"
require "./interaction_router"
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
      DEFAULT_PBKDF_ITERATIONS = 1000_u32
      PBKDF_SALT_LENGTH        =       32

      getter transport : Transport::UDPTransport

      # Network receive must remain free while a cluster handler performs a
      # controller exchange through the same socket. One worker preserves the
      # device's inbound message ordering.
      INBOUND_QUEUE_LIMIT = 256
      @inbound_messages : Channel(Tuple(Codec::MessageCodec::Message, Socket::IPAddress))
      @inbound_done : Channel(Nil)

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

      def initialize(
        @transport : Transport::UDPTransport,
        setup_pin : UInt32,
        @discriminator : UInt16,
        @fabric_table : FabricTable,
        iterations : UInt32 = DEFAULT_PBKDF_ITERATIONS,
        salt : Bytes = Random::Secure.random_bytes(PBKDF_SALT_LENGTH),
        @vendor_id : UInt16 = 0xFFF1_u16,
        @product_id : UInt16 = 0x8001_u16,
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
        @on_commissioned = nil
        @operational_credentials_cluster = nil

        # Initialize clusters
        @node = Node.new
        initialize_clusters

        @sender = ResponseSender.new(@transport, @mrp_cache)
        @subscriptions = SubscriptionManager.new(@registry, @node, @sender)
        @secure_channel = SecureChannel.new(@fabric_table, @registry, @sender, setup_pin, iterations, salt)
        @router = InteractionRouter.new(@registry, @node, @subscriptions, @sender)
        @group_packets = Session::GroupSecurePacket.new([] of Session::GroupSecurePacket::Key)

        @inbound_messages = Channel(Tuple(Codec::MessageCodec::Message, Socket::IPAddress)).new(INBOUND_QUEUE_LIMIT)
        @inbound_done = Channel(Nil).new(1)
        spawn do
          while entry = @inbound_messages.receive?
            handle_message(entry[0], entry[1])
          end
        ensure
          @inbound_done.send(nil)
        end

        # Set ourselves as the message handler
        @transport.on_message = ->(msg : Codec::MessageCodec::Message, peer : Socket::IPAddress) do
          payload = msg.payload.dup
          header_bytes = msg.header_bytes.try(&.dup)
          detached = Codec::MessageCodec::Message.new(msg.packet_header, msg.payload_header, payload, header_bytes)
          @inbound_messages.send({detached, peer})
        end
        @transport.on_group_packet = ->(wire : Bytes, peer : Socket::IPAddress) do
          handle_group_packet(wire, peer)
        end

        # Restore persisted protocol state (CASE sessions + subscriptions)
        if persistence = @persistence
          begin
            persistence.restore(@registry, @fabric_table)
          rescue ex
            Log.error(exception: ex) { "Failed to restore protocol persistence (persistence=#{persistence.class})" }
          end
        end

        @registry.start
      end

      # Stops the registry background sweep. The transport is closed by its
      # owner; this releases what the handler itself started.
      def close : Nil
        unless @inbound_messages.closed?
          @inbound_messages.close
          @inbound_done.receive
        end
        @registry.close
      end

      # The clusters of the node, keyed by `{endpoint, cluster}`.
      #
      # Inserting into this hash registers a cluster without an endpoint; it is
      # the escape hatch the protocol specs use. Devices build endpoints
      # through `node` instead.
      def clusters : Hash(Tuple(UInt16, UInt32), Cluster::Base)
        @node.clusters
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
        endpoint_0 = DataType::EndpointNumber.new(0_u16)
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

      # Decrypts, classifies and routes one inbound message.
      #
      # Runs under the registry lock: controllers send messages back to back,
      # and subscription reports are raised from other fibers entirely.
      def handle_message(msg : Codec::MessageCodec::Message, peer : Socket::IPAddress) : Nil
        @registry.synchronize do
          session = nil
          session_id = msg.packet_header.session_id

          if session_id != 0
            Log.trace { "Message is encrypted (session_id=#{session_id}), decrypting" }

            session = @registry.sessions[session_id]?
            unless session
              Log.warn { "Dropping encrypted message: no session found (session_id=#{session_id})" }
              return
            end

            message_counter = msg.packet_header.message_id
            case session.check_peer_message_counter(message_counter)
            when Transport::MessageCounter::CheckResult::Duplicate
              # The peer retransmitted; answer from the cache rather than
              # re-running cluster logic.
              unless @mrp_cache.resend?(session_id, message_counter, peer)
                Log.trace { "Dropping duplicate message with no cached response: session_id=#{session_id}, counter=#{message_counter}" }
              end
              return
            when Transport::MessageCounter::CheckResult::Stale
              Log.trace { "Dropping stale message outside the receive window: session_id=#{session_id}, counter=#{message_counter}" }
              return
            end

            msg = decrypt_message(msg, session)
            if ack = msg.payload_header.acknowledged_message_id
              @transport.acknowledge_reliable(session_id,
                msg.payload_header.exchange_id, ack)
            end
            @registry.cancel_cleanup_on_traffic(session_id)
          end

          Log.debug { "Received message: protocol=0x#{msg.payload_header.protocol_id.to_s(16)}, type=0x#{msg.payload_header.message_type.to_s(16)}" }
          route(msg, peer, session)
        end
      rescue ex
        Log.debug(exception: ex) do
          "Error handling message: peer=#{peer.address}:#{peer.port} session_id=#{msg.packet_header.session_id} " \
          "msg_id=#{msg.packet_header.message_id} protocol=0x#{msg.payload_header.protocol_id.to_s(16)} " \
          "type=0x#{msg.payload_header.message_type.to_s(16)} exchange=#{msg.payload_header.exchange_id} " \
          "payload_bytes=#{msg.payload.size}"
        end
      end

      # Authenticated Group packets bypass unicast session lookup and never
      # enter the ordinary IM router, which assumes a CASE/PASE session.
      def handle_group_packet(wire : Bytes, peer : Socket::IPAddress) : Nil
        @registry.synchronize do
          keys = group_candidate_keys
          return if keys.empty?
          @group_packets.keys = keys
          decoded = @group_packets.decode(wire)
          if group_keys = @node.get_cluster(Cluster::GroupKeyManagement)
            GroupInteractionRouter.new(@node.clusters, group_keys).handle(decoded)
          end
        end
      rescue ex
        Log.debug(exception: ex) { "Dropping group packet from #{peer}" }
      end

      def refresh_group_memberships : Nil
        group_keys = @node.get_cluster(Cluster::GroupKeyManagement)
        return unless group_keys
        addresses = @fabric_table.all_fabrics.flat_map do |fabric|
          mapped = group_keys.group_key_map(fabric.fabric_index).map(&.group_id)
          group_keys.group_table(fabric.fabric_index).select { |group| mapped.includes?(group.group_id) }.map do |group|
            Transport::GroupMulticast.address(fabric.fabric_id, group.group_id, @transport.port)
          end
        end
        @transport.group_memberships = addresses.uniq
      rescue ex
        Log.warn(exception: ex) { "Failed to update group multicast memberships" }
      end

      # Remove every group credential and membership associated with a fabric
      # before its local index can be reused by a new commissioner.
      def forget_group_fabric(fabric_index : UInt8) : Nil
        @node.get_cluster(Cluster::GroupKeyManagement).try(&.remove_fabric(fabric_index))
        @node.clusters.each_value do |cluster|
          cluster.as?(Cluster::Groups).try(&.remove_fabric(fabric_index))
        end
        refresh_group_memberships
      end

      private def group_candidate_keys : Array(Session::GroupSecurePacket::Key)
        group_keys = @node.get_cluster(Cluster::GroupKeyManagement)
        return [] of Session::GroupSecurePacket::Key unless group_keys
        result = [] of Session::GroupSecurePacket::Key
        @fabric_table.all_fabrics.each do |fabric|
          group_keys.group_key_map(fabric.fabric_index).each do |mapping|
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
      ) : Nil
        case msg.payload_header.protocol_id
        when ProtocolId::SecureChannel.value
          handle_secure_channel(msg, peer)
        when ProtocolId::InteractionModel.value
          unless session
            Log.warn { "Dropping IM message: no session found (session_id=#{msg.packet_header.session_id})" }
            return
          end

          @router.handle(msg, peer, session)
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

        # iOS acknowledges intermediate ReportData chunks with a bare MRP ACK
        # rather than a StatusResponse; both drive the same ladder.
        @subscriptions.advance(msg.payload_header.exchange_id, msg)
      end
    end
  end
end
