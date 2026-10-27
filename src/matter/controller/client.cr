require "log"
require "socket"

require "../codec/message_codec"
require "../crypto/crypto"
require "../datatype/node_id"
require "../session/context"
require "../session/secure_message"
require "../transport/udp_transport"
require "../transport/tcp_enabled_transport"
require "../interaction_model/tlv_messages"
require "../protocol/message_type"

module Matter
  module Controller
    class Client
      Log = ::Log.for("matter.controller.client")

      PROTOCOL_SECURE_CHANNEL    = Protocol::ProtocolId::SecureChannel.value
      PROTOCOL_INTERACTION_MODEL = Protocol::ProtocolId::InteractionModel.value
      UNSECURED_SESSION_ID       = Codec::MessageCodec::UNSECURED_SESSION_ID
      IPV4_MAPPED_PREFIX         = "::ffff:"

      MSG_STANDALONE_ACK       = 0x10_u8
      MSG_STATUS_RESPONSE      = 0x01_u8
      MSG_SUBSCRIBE_RESPONSE   = 0x04_u8
      MSG_REPORT_DATA          = 0x05_u8
      MAX_CACHED_ACKS          = Transport::MessageCounter::WINDOW_SIZE
      MAX_DEFERRED_MESSAGES    = 256
      MAX_CLOSED_SUBSCRIPTIONS = 256
      DEFERRED_CHECK_INTERVAL  = 10.milliseconds
      # A bounded rejection limit for random candidates, not a wire protocol value.
      SESSION_ID_ALLOCATION_ATTEMPTS = 32

      record ReceivedMessage, message : Codec::MessageCodec::Message, peer : Socket::IPAddress

      getter transport : Transport::PacketTransport
      getter crypto : Crypto::CryptoBase

      @sessions = {} of UInt16 => Session::SecureContext
      @ack_packets = {} of {UInt16, UInt32} => Bytes
      @inbox : Channel(ReceivedMessage)
      @deferred_messages : Array(ReceivedMessage)
      @deferred_mutex : Mutex
      @subscription_mutex : Mutex
      @receive_mutex : Mutex
      @subscription_ids : Hash(UInt16, Set(UInt32))
      @closed_subscription_ids : Hash(UInt16, Array(UInt32))
      @pending_subscription_exchanges : Set(Tuple(UInt16, UInt16))
      @next_exchange_id : UInt16
      @unsecured_source_node_id : DataType::NodeId?
      @owns_transport : Bool
      @transport_observer_id : Int32?
      @tcp_disconnect_observer_id : Int32?
      @owned_unsecured_exchanges : Set(Tuple(UInt16, Socket::IPAddress))
      @session_id_in_use : Proc(UInt16, Bool)?

      def initialize(
        port : Int32 = 0,
        @crypto : Crypto::CryptoBase = Crypto::StandardCrypto.new,
        unsecured_source_node_id : UInt64? = nil,
        initial_unsecured_message_counter : UInt32? = nil,
        transport : Transport::PacketTransport? = nil,
        tcp_enabled : Bool = false,
        @session_id_in_use : Proc(UInt16, Bool)? = nil,
      )
        @owns_transport = transport.nil?
        @transport = transport || (tcp_enabled ? Transport::TcpEnabledTransport.new(port: port) : Transport::UDPTransport.new(port: port))
        @transport_observer_id = nil
        @tcp_disconnect_observer_id = nil
        @owned_unsecured_exchanges = Set(Tuple(UInt16, Socket::IPAddress)).new
        @unsecured_source_node_id = unsecured_source_node_id ? DataType::NodeId.new(unsecured_source_node_id) : DataType::NodeId.random_operational

        # Avoid re-using old unsecured message IDs across process restarts: peers may
        # keep a dedupe window for unsecured traffic (session_id=0), which can cause
        # commissioning/CASE handshakes to be ignored as duplicates/stale.
        if @owns_transport
          if initial = initial_unsecured_message_counter
            @transport.message_counter.reset(initial)
          else
            @transport.message_counter.reset(Random::Secure.rand(UInt32))
          end
        elsif initial_unsecured_message_counter
          raise Matter::ConfigurationError.new("Cannot reset a shared transport message counter")
        end
        @inbox = Channel(ReceivedMessage).new(256)
        @deferred_messages = [] of ReceivedMessage
        @deferred_mutex = Mutex.new
        @subscription_mutex = Mutex.new
        @receive_mutex = Mutex.new
        @subscription_ids = Hash(UInt16, Set(UInt32)).new
        @closed_subscription_ids = Hash(UInt16, Array(UInt32)).new
        @pending_subscription_exchanges = Set(Tuple(UInt16, UInt16)).new
        @next_exchange_id = Random.rand(UInt16).to_u16

        if tcp = @transport.as?(Transport::TcpEnabledTransport)
          @tcp_disconnect_observer_id = tcp.add_connection_closed_observer do |peer|
            closed_sessions = @sessions.values.select { |session| session.tcp_session? && session.tcp_peer == peer }
            closed_sessions.each { |session| @sessions.delete(session.session_id) }
            ids = closed_sessions.map(&.session_id).to_set
            @subscription_mutex.synchronize do
              ids.each do |id|
                @subscription_ids.delete(id)
                @closed_subscription_ids.delete(id)
              end
              @pending_subscription_exchanges.reject! { |id, _| ids.includes?(id) }
            end
            @ack_packets.reject! { |(session_id, _), _| ids.includes?(session_id) }
            @deferred_mutex.synchronize { @deferred_messages.reject! { |message| message.peer == peer } }
            @owned_unsecured_exchanges.reject! { |entry| entry[1] == peer }
          end
        end

        if @owns_transport
          @transport.on_message = ->(msg : Codec::MessageCodec::Message, peer : Socket::IPAddress) { handle_transport_message(msg, peer) }
          @transport.start
        else
          @transport_observer_id = @transport.add_message_observer do |msg, peer|
            if owns_incoming?(msg, peer)
              handle_transport_message(msg, peer)
              true
            else
              false
            end
          end
        end
      end

      def close : Nil
        if id = @tcp_disconnect_observer_id
          @transport.as(Transport::TcpEnabledTransport).remove_connection_closed_observer(id)
          @tcp_disconnect_observer_id = nil
        end
        if id = @transport_observer_id
          @transport.remove_message_observer(id)
          @transport_observer_id = nil
        end
        @transport.close if @owns_transport
        @subscription_mutex.synchronize do
          @subscription_ids.clear
          @closed_subscription_ids.clear
          @pending_subscription_exchanges.clear
        end
      end

      def register_session(session : Session::SecureContext,
                           peer : Socket::IPAddress? = nil) : Nil
        unless session_id_available?(session.session_id)
          raise Matter::ProtocolError.new("Controller session ID #{session.session_id} is already in use")
        end
        if peer && peer.port == Transport::TcpEnabledTransport::TOKEN_PORT
          unless @transport.tcp_peer?(peer)
            raise Matter::TransportError.new("Matter TCP connection is closed")
          end
          session.bind_tcp_peer(peer)
        end
        @sessions[session.session_id] = session
        if peer
          @transport.configure_mrp_peer(peer, session.session_id,
            session.peer_mrp_idle_interval_ms, session.peer_mrp_active_interval_ms,
            session.peer_mrp_active_threshold_ms)
          @transport.mark_mrp_peer_active(peer, session.session_id)
        end
      end

      def connect_tcp(peer : Socket::IPAddress) : Socket::IPAddress
        transport = @transport.as?(Transport::TcpEnabledTransport) ||
                    raise Matter::ConfigurationError.new("Controller TCP transport is not enabled")
        transport.connect_tcp(peer)
      end

      def session_id_available?(session_id : UInt16) : Bool
        session_id != UNSECURED_SESSION_ID && !@sessions.has_key?(session_id) && !(@session_id_in_use.try(&.call(session_id)) || false)
      end

      # Session IDs must be available both locally and to another controller
      # using the same transport. Check before advertising one on the wire.
      def allocate_session_id(protocol : String, &candidate : -> UInt16) : UInt16
        SESSION_ID_ALLOCATION_ATTEMPTS.times do
          id = candidate.call
          return id if session_id_available?(id)
        end
        raise Matter::ProtocolError.new("Could not allocate an unused #{protocol} session ID")
      end

      def session?(session_id : UInt16) : Session::SecureContext?
        @sessions[session_id]?
      end

      def next_exchange_id : UInt16
        id = @next_exchange_id
        @next_exchange_id = @next_exchange_id &+ 1
        id
      end

      # Send an unsecured (session_id=0) request and return the exchange id.
      def send_unsecured_request(
        peer : Socket::IPAddress,
        protocol_id : UInt16,
        message_type : UInt8,
        payload : Bytes | Slice(UInt8),
        requires_ack : Bool = true,
      ) : UInt16
        exchange = @transport.exchange_manager.create_exchange(
          protocol_id: protocol_id, session_id: UNSECURED_SESSION_ID, peer_address: peer,
          initial_message_type: message_type)
        @owned_unsecured_exchanges.add({exchange.exchange_id, canonical_peer(peer)})
        send_unsecured_on_exchange(peer, exchange.exchange_id, protocol_id,
          message_type, payload, requires_ack: requires_ack)
        exchange.exchange_id
      end

      private def owns_incoming?(msg : Codec::MessageCodec::Message, peer : Socket::IPAddress) : Bool
        if msg.packet_header.session_id == UNSECURED_SESSION_ID
          !msg.payload_header.initiator_message? &&
            @owned_unsecured_exchanges.includes?({msg.payload_header.exchange_id, canonical_peer(peer)})
        else
          @sessions.has_key?(msg.packet_header.session_id)
        end
      end

      private def canonical_peer(peer : Socket::IPAddress) : Socket::IPAddress
        address = peer.address
        return peer unless address.starts_with?(IPV4_MAPPED_PREFIX)

        Socket::IPAddress.new(address[IPV4_MAPPED_PREFIX.size..], peer.port)
      end

      # Send an unsecured (session_id=0) message on an existing exchange.
      def send_unsecured_on_exchange(
        peer : Socket::IPAddress,
        exchange_id : UInt16,
        protocol_id : UInt16,
        message_type : UInt8,
        payload : Bytes | Slice(UInt8),
        initiator_message : Bool = true,
        requires_ack : Bool = true,
        acknowledged_message_id : UInt32? = nil,
      ) : Nil
        unless @transport.exchange_manager.get_exchange(exchange_id, UNSECURED_SESSION_ID, peer, initiator_message)
          raise Matter::ProtocolError.new("unknown exchange_id=#{exchange_id}")
        end

        packet_header = Codec::MessageCodec::PacketHeader.new(
          session_id: UNSECURED_SESSION_ID,
          session_type: Codec::MessageCodec::SessionType::Unicast,
          message_id: 0_u32, # assigned by UDPTransport
          privacy_enhancements: false,
          control_message: false,
          message_extensions: false,
          source_node_id: @unsecured_source_node_id,
          destination_node_id: nil
        )

        payload_header = Codec::MessageCodec::PayloadHeader.new(
          exchange_id: exchange_id,
          protocol_id: protocol_id,
          message_type: message_type,
          initiator_message: initiator_message,
          requires_acknowledge: requires_ack,
          acknowledged_message_id: acknowledged_message_id
        )

        message = Codec::MessageCodec::Message.new(
          packet_header: packet_header,
          payload_header: payload_header,
          payload: payload.to_slice
        )

        @transport.send_message(message, peer)
      end

      # Send an encrypted request on an existing secure session.
      def send_encrypted_request(
        session : Session::SecureContext,
        peer : Socket::IPAddress,
        protocol_id : UInt16,
        message_type : UInt8,
        payload : Bytes | Slice(UInt8),
        exchange_id : UInt16 = next_exchange_id,
        initiator_message : Bool = true,
        requires_ack : Bool = true,
        acknowledged_message_id : UInt32? = nil,
      ) : UInt16
        unless session.accepts_peer?(peer)
          raise Matter::TransportError.new("Secure session belongs to another transport or TCP connection")
        end
        payload_header = Codec::MessageCodec::PayloadHeader.new(
          exchange_id: exchange_id,
          protocol_id: protocol_id,
          message_type: message_type,
          initiator_message: initiator_message,
          requires_acknowledge: requires_ack,
          acknowledged_message_id: acknowledged_message_id
        )

        udp_packet, counter = Session::SecureMessage.encode(session, payload_header, payload.to_slice,
          source_node_id: session.local_node_id, destination_node_id: session.peer_node_id, crypto: @crypto)
        if requires_ack
          @transport.send_reliable_raw(udp_packet, peer, session.session_id,
            exchange_id, counter)
        else
          @transport.send_raw(udp_packet, peer)
        end

        exchange_id
      end

      # Wait for the next message matching exchange/protocol/type.
      def wait_for(
        exchange_id : UInt16,
        protocol_id : UInt16,
        message_type : UInt8,
        timeout : Time::Span,
      ) : ReceivedMessage?
        wait_for_any(exchange_id, protocol_id, [message_type], timeout)
      end

      # Wait for one of several valid responses to an exchange. A device may
      # answer a timed Write/Invoke with StatusResponse instead of its normal
      # response when the timed window expires. Messages for other exchanges
      # are retained for their own waiters, with a bounded backlog.
      def wait_for_any(
        exchange_id : UInt16,
        protocol_id : UInt16,
        message_types : Array(UInt8),
        timeout : Time::Span,
      ) : ReceivedMessage?
        pairs = message_types.map { |type| {protocol_id, type} }
        wait_for_exchange_message(exchange_id, pairs, timeout)
      end

      # Wait for one of several protocol/opcode pairs on an exchange. BDX
      # transfer replies use protocol 0x0002, while failures arrive as Secure
      # Channel StatusReport on that same exchange.
      def wait_for_exchange_message(
        exchange_id : UInt16,
        message_types : Array(Tuple(UInt16, UInt8)),
        timeout : Time::Span,
      ) : ReceivedMessage?
        deadline = Time.instant + timeout

        loop do
          if deferred = take_deferred do |rec|
               matches_exchange?(rec, exchange_id, message_types)
             end
            return deferred
          end

          remaining = deadline - Time.instant
          return if remaining <= 0.seconds

          if rec = receive_unfiltered_from_inbox({remaining, DEFERRED_CHECK_INTERVAL}.min)
            return rec if matches_exchange?(rec, exchange_id, message_types)
            defer(rec) unless standalone_ack?(rec)
          end
        end
      end

      def register_subscription(session_id : UInt16, subscription_id : UInt32) : Nil
        @subscription_mutex.synchronize do
          (@subscription_ids[session_id] ||= Set(UInt32).new).add(subscription_id)
          @closed_subscription_ids[session_id]?.try(&.delete(subscription_id))
        end
      end

      def begin_subscription_handshake(session_id : UInt16, exchange_id : UInt16) : Nil
        @subscription_mutex.synchronize { @pending_subscription_exchanges.add({session_id, exchange_id}) }
      end

      def end_subscription_handshake(session_id : UInt16, exchange_id : UInt16) : Nil
        @subscription_mutex.synchronize { @pending_subscription_exchanges.delete({session_id, exchange_id}) }
      end

      def unregister_subscription(session_id : UInt16, subscription_id : UInt32) : Nil
        @subscription_mutex.synchronize do
          if ids = @subscription_ids[session_id]?
            ids.delete(subscription_id)
            @subscription_ids.delete(session_id) if ids.empty?
          end
          closed = @closed_subscription_ids[session_id] ||= [] of UInt32
          closed.delete(subscription_id)
          closed.shift if closed.size >= MAX_CLOSED_SUBSCRIPTIONS
          closed << subscription_id
        end
        @deferred_mutex.synchronize do
          @deferred_messages.reject! { |received| received.message.packet_header.session_id == session_id && report_subscription_id(received.message) == subscription_id }
        end
      end

      # One receive owner services all waiters. A notification is delivered
      # only to the subscription with its authenticated session and ID;
      # messages for reads, invokes, or other subscriptions remain queued.
      def wait_for_subscription_message(session_id : UInt16, subscription_id : UInt32?,
                                        handshake_exchange_id : UInt16?,
                                        timeout_span : Time::Span) : ReceivedMessage?
        deadline = Time.instant + timeout_span
        loop do
          if deferred = take_deferred do |rec|
               matches_subscription?(rec, session_id, subscription_id, handshake_exchange_id)
             end
            return deferred
          end
          remaining = deadline - Time.instant
          return if remaining <= 0.seconds
          if rec = receive_unfiltered_from_inbox({remaining, DEFERRED_CHECK_INTERVAL}.min)
            return rec if matches_subscription?(rec, session_id, subscription_id, handshake_exchange_id)
            defer(rec) unless standalone_ack?(rec)
          end
        end
      end

      # Receive the next decrypted message without an exchange filter. Use
      # only when no other receiver owns the client: this may consume an
      # unrelated interaction. Subscription and exchange consumers use their
      # filtered wait methods.
      def receive_message(timeout_span : Time::Span) : ReceivedMessage?
        if deferred = take_deferred { true }
          return deferred
        end
        receive_unfiltered_from_inbox(timeout_span)
      end

      protected def receive_unfiltered_from_inbox(timeout_span : Time::Span) : ReceivedMessage?
        deadline = Time.instant + timeout_span
        @receive_mutex.synchronize do
          loop do
            remaining = deadline - Time.instant
            return if remaining <= 0.seconds
            select
            when rec = @inbox.receive
              ack_encrypted_if_needed(rec)
              next if reply_to_closed_subscription_report?(rec)
              return rec
            when timeout(remaining)
              return
            end
          end
        end
      end

      private def matches_subscription?(rec : ReceivedMessage, session_id : UInt16,
                                        subscription_id : UInt32?, handshake_exchange_id : UInt16?) : Bool
        message = rec.message
        return false unless message.packet_header.session_id == session_id &&
                            message.payload_header.protocol_id == PROTOCOL_INTERACTION_MODEL
        header = message.payload_header
        if exchange_id = handshake_exchange_id
          return header.exchange_id == exchange_id &&
            {MSG_REPORT_DATA, MSG_SUBSCRIBE_RESPONSE, MSG_STATUS_RESPONSE}.includes?(header.message_type)
        end
        return false unless header.message_type == MSG_REPORT_DATA
        id = report_subscription_id(message)
        return false unless id
        return true if id == subscription_id
        # Preserve the existing error for an unexpected ID, while allowing
        # another registered subscription to receive its own report.
        @subscription_mutex.synchronize do
          !(@subscription_ids[session_id]?.try(&.includes?(id)) || false)
        end
      end

      private def report_subscription_id(message : Codec::MessageCodec::Message) : UInt32?
        return unless message.payload_header.protocol_id == PROTOCOL_INTERACTION_MODEL &&
                      message.payload_header.message_type == MSG_REPORT_DATA
        InteractionModel::ReportDataMessage.from_slice(message.payload.to_slice).subscription_id
      rescue ex
        Log.debug(exception: ex) { "Could not decode controller ReportData subscription ID" }
        nil
      end

      private def matches_exchange?(rec : ReceivedMessage, exchange_id : UInt16,
                                    message_types : Array(Tuple(UInt16, UInt8))) : Bool
        header = rec.message.payload_header
        header.exchange_id == exchange_id &&
          message_types.any? { |protocol, type| header.protocol_id == protocol && header.message_type == type }
      end

      private def standalone_ack?(rec : ReceivedMessage) : Bool
        header = rec.message.payload_header
        header.protocol_id == PROTOCOL_SECURE_CHANNEL && header.message_type == MSG_STANDALONE_ACK
      end

      private def take_deferred(&block : ReceivedMessage -> Bool) : ReceivedMessage?
        @deferred_mutex.synchronize do
          if index = @deferred_messages.index { |rec| block.call(rec) }
            @deferred_messages.delete_at(index)
          end
        end
      end

      private def defer(rec : ReceivedMessage) : Nil
        @deferred_mutex.synchronize do
          if @deferred_messages.size >= MAX_DEFERRED_MESSAGES
            dropped = @deferred_messages.shift
            Log.warn do
              "Dropping oldest deferred controller message " \
              "(exchange=#{dropped.message.payload_header.exchange_id}, protocol=#{dropped.message.payload_header.protocol_id})"
            end
          end
          @deferred_messages << rec
        end
      end

      private def handle_transport_message(msg : Codec::MessageCodec::Message, peer : Socket::IPAddress) : Nil
        if msg.packet_header.session_id == UNSECURED_SESSION_ID
          # Before CASE/PASE authenticates a session, replies on TCP must
          # match the exact connection that opened the unsecured exchange.
          if peer.port == Transport::TcpEnabledTransport::TOKEN_PORT && !owns_incoming?(msg, peer)
            Log.debug { "Dropping unsecured TCP message on another exchange or connection" }
            return
          end
          @inbox.send(ReceivedMessage.new(msg, peer))
          return
        end

        session = @sessions[msg.packet_header.session_id]?
        unless session
          Log.debug { "Dropping encrypted message: no session found (session_id=#{msg.packet_header.session_id}, peer=#{peer})" }
          return
        end

        unless session.accepts_peer?(peer)
          Log.debug { "Dropping encrypted message on another transport or TCP connection (session_id=#{session.session_id})" }
          return
        end

        case session.check_peer_message_counter(msg.packet_header.message_id)
        when Transport::MessageCounter::CheckResult::Duplicate
          if ack = @ack_packets[{session.session_id, msg.packet_header.message_id}]?
            @transport.send_raw(ack, peer)
          end
          return
        when Transport::MessageCounter::CheckResult::Stale
          return
        end
        decrypted_message = decrypt_message(session, msg)
        @transport.mark_mrp_peer_active(peer, session.session_id)
        if ack = decrypted_message.payload_header.acknowledged_message_id
          @transport.acknowledge_reliable(session.session_id,
            decrypted_message.payload_header.exchange_id, ack)
        end
        received = ReceivedMessage.new(decrypted_message, peer)
        return if reply_to_closed_subscription_report?(received)
        @inbox.send(received)
      rescue ex
        Log.error(exception: ex) { "Controller: failed handling inbound message (peer=#{peer} session_id=#{msg.packet_header.session_id} data_hex=#{msg.payload.hexstring})" }
      end

      private def closed_subscription_report?(session_id : UInt16,
                                              message : Codec::MessageCodec::Message) : Bool
        id = report_subscription_id(message)
        return false unless id
        @subscription_mutex.synchronize do
          return false if @pending_subscription_exchanges.includes?({session_id, message.payload_header.exchange_id})
          @closed_subscription_ids[session_id]?.try(&.includes?(id)) || false
        end
      end

      private def reply_to_closed_subscription_report?(received : ReceivedMessage) : Bool
        message = received.message
        session_id = message.packet_header.session_id
        return false unless closed_subscription_report?(session_id, message)
        session = @sessions[session_id]?
        return true unless session
        send_encrypted_request(session, received.peer, PROTOCOL_INTERACTION_MODEL,
          MSG_STATUS_RESPONSE,
          InteractionModel::StatusResponseMessage.new(
            InteractionModel::StatusCode::InvalidSubscription.value).to_slice,
          exchange_id: message.payload_header.exchange_id,
          initiator_message: !message.payload_header.initiator_message?,
          acknowledged_message_id: message.packet_header.message_id)
        true
      end

      private def decrypt_message(session : Session::SecureContext, msg : Codec::MessageCodec::Message) : Codec::MessageCodec::Message
        Session::SecureMessage.decode(session,
          Codec::MessageCodec::Packet.new(msg.packet_header, msg.payload, msg.header_bytes), @crypto)
      end

      private def ack_encrypted_if_needed(rec : ReceivedMessage) : Nil
        msg = rec.message
        return unless msg.payload_header.requires_acknowledge?
        return if msg.packet_header.session_id == UNSECURED_SESSION_ID
        # ReportData uses the Interaction Model StatusResponse ladder. Sending
        # an MRP ACK here as well would advance a chunked publisher twice.
        return if msg.payload_header.protocol_id == PROTOCOL_INTERACTION_MODEL &&
                  msg.payload_header.message_type == MSG_REPORT_DATA

        session = @sessions[msg.packet_header.session_id]?
        return unless session

        send_standalone_ack(session, rec.peer, msg)
      end

      private def send_standalone_ack(
        session : Session::SecureContext,
        peer : Socket::IPAddress,
        original : Codec::MessageCodec::Message,
      ) : Nil
        payload_header = Codec::MessageCodec::PayloadHeader.new(
          exchange_id: original.payload_header.exchange_id,
          protocol_id: PROTOCOL_SECURE_CHANNEL,
          message_type: MSG_STANDALONE_ACK,
          initiator_message: !original.payload_header.initiator_message?,
          requires_acknowledge: false,
          acknowledged_message_id: original.packet_header.message_id
        )

        udp_packet, _ = Session::SecureMessage.encode(session, payload_header, Bytes.empty,
          source_node_id: session.local_node_id, destination_node_id: session.peer_node_id, crypto: @crypto)
        @ack_packets.shift if @ack_packets.size >= MAX_CACHED_ACKS
        @ack_packets[{session.session_id, original.packet_header.message_id}] = udp_packet
        @transport.send_raw(udp_packet, peer)
      end
    end
  end
end
