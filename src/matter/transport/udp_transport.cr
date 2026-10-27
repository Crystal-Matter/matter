require "socket"
require "log"
require "../codec/message_codec"
require "../protocol/message_type"
require "./message_counter"
require "./exchange"
require "./packet_transport"

module Matter
  module Transport
    # UDP transport layer for Matter protocol
    #
    # Handles:
    # - Sending and receiving Matter messages over UDP
    # - Message deduplication
    # - Exchange management (request/response correlation) and acknowledgement
    #
    # Uses a single dual-stack IPv6 socket that accepts both IPv4 and IPv6 connections.
    class UDPTransport < PacketTransport
      Log = ::Log.for("matter.transport.udp_transport")

      # Matter default port
      MATTER_PORT        = 5540
      IPV4_MAPPED_PREFIX = "::ffff:"
      TCP_ROUTE_PORT     = 0

      # How long the receive loop waits for a datagram before looping.
      RECEIVE_TIMEOUT = 100.milliseconds

      # How often idle exchanges are swept out of the exchange table.
      EXCHANGE_SWEEP_INTERVAL = 30.seconds

      # Matter's maximum UDP payload.
      MAX_DATAGRAM_SIZE = 1280

      # Secure Channel MRP Standalone Acknowledgement (Matter spec 4.10).
      STANDALONE_ACK_MESSAGE_TYPE = Protocol::SecureChannelMessageType::StandaloneAck.value

      # The shortest well-formed packet: flags, session id, security flags and
      # message counter.
      MIN_PACKET_SIZE = 8

      # Matter 1.6 Core §4.13.1 defaults. Keep at most four copies after the
      # original send, as the official SDK does.
      MRP_IDLE_RETRY_INTERVAL   = 500.milliseconds
      MRP_ACTIVE_RETRY_INTERVAL = 300.milliseconds
      MRP_ACTIVE_THRESHOLD      = 4.seconds
      MRP_MAX_RETRANSMISSIONS   = 4
      MRP_SWEEP_INTERVAL        = 25.milliseconds
      MRP_BACKOFF_MARGIN        =  1.1
      MRP_BACKOFF_BASE          =  1.6
      MRP_BACKOFF_JITTER        = 0.25
      MRP_PENDING_LIMIT         =  256
      MRP_UNSECURED_CONFIG_TTL  = 10.minutes

      private class PendingReliableMessage
        getter packet : Bytes
        getter peer : Socket::IPAddress
        getter session_id : UInt16
        getter exchange_id : UInt16
        getter message_counter : UInt32
        property retransmissions : Int32
        property next_at : Time::Instant

        def initialize(@packet, @peer, @session_id, @exchange_id, @message_counter,
                       @next_at, @retransmissions = 0)
        end
      end

      @pending_reliable : Hash(Tuple(UInt16, UInt16, UInt32), PendingReliableMessage)
      @mrp_peer_parameters : Hash(Tuple(UInt16, Socket::IPAddress), Tuple(Time::Span, Time::Span, Time::Span))
      @mrp_unsecured_configured_at : Hash(Socket::IPAddress, Time::Instant)
      @mrp_peer_last_active : Hash(Tuple(UInt16, Socket::IPAddress), Time::Instant)
      @reliable_mutex : Mutex
      @reliable_fiber : Fiber?

      UNSECURED_COUNTER_LIMIT          = 1024
      UNSECURED_COUNTER_TTL            = 5.minutes
      UNSECURED_COUNTER_SWEEP_INTERVAL = 1.minute
      UNSECURED_REPLAY_LIMIT           = 512
      UNSECURED_REPLAY_TTL             = 1.minute

      private class UnsecuredReplayEntry
        getter request : Bytes
        getter created_at : Time::Instant
        property response : Bytes?

        def initialize(@request : Bytes, @created_at : Time::Instant,
                       @response : Bytes? = nil)
        end
      end

      getter socket : UDPSocket

      # Unsecured counters belong to a sender's UDP socket. Independent
      # controller transports may use the same Node ID with fresh counters.
      @unsecured_counters : Hash(Tuple(UInt64?, Socket::IPAddress), Tuple(MessageCounter, Time::Instant))
      @unsecured_replay : Hash(Tuple(UInt64?, Socket::IPAddress, UInt32), UnsecuredReplayEntry)
      @last_unsecured_counter_sweep : Time::Instant

      # Callback for received messages
      # Signature: (message : Codec::MessageCodec::Message, peer_address : Socket::IPAddress) -> Nil

      # A controller sharing this socket may claim its own CASE exchange or
      # secure session before the device's default handler sees the packet.
      @message_observers : Hash(Int32, Proc(Codec::MessageCodec::Message, Socket::IPAddress, Bool))
      @observer_mutex : Mutex
      @next_observer_id : Int32

      def add_message_observer(&block : Codec::MessageCodec::Message, Socket::IPAddress -> Bool) : Int32
        @observer_mutex.synchronize do
          @next_observer_id += 1
          @message_observers[@next_observer_id] = block
          @next_observer_id
        end
      end

      def remove_message_observer(id : Int32) : Nil
        @observer_mutex.synchronize { @message_observers.delete(id) }
      end

      @joined_groups = Set(Socket::IPAddress).new

      # Keep multicast memberships aligned with the device's GroupTable.
      def group_memberships=(addresses : Array(Socket::IPAddress)) : Nil
        desired = addresses.to_set
        (@joined_groups - desired).each do |address|
          @socket.leave_group(address)
          @joined_groups.delete(address)
        end
        (desired - @joined_groups).each do |address|
          @socket.join_group(address)
          @joined_groups.add(address)
          Log.info { "Joined Matter group multicast #{address.address}" }
        end
      end

      @running : Bool
      @receive_fiber : Fiber?
      @last_exchange_sweep : Time = Time.utc

      getter port : Int32
      getter message_counter : MessageCounter
      getter exchange_manager : ExchangeManager

      def initialize(@port : Int32 = MATTER_PORT)
        # Create dual-stack IPv6 socket (accepts both IPv4 and IPv6)
        @socket = UDPSocket.new(Socket::Family::INET6)
        @socket.ipv6_only = false
        @socket.reuse_address = true
        @socket.reuse_port = true
        @socket.bind("::", @port)
        @socket.read_timeout = RECEIVE_TIMEOUT

        # Support ephemeral ports: update @port with actual bound port
        @port = @socket.local_address.port if @port == 0

        @message_counter = MessageCounter.new
        @unsecured_counters = Hash(Tuple(UInt64?, Socket::IPAddress), Tuple(MessageCounter, Time::Instant)).new
        @unsecured_replay = {} of Tuple(UInt64?, Socket::IPAddress, UInt32) => UnsecuredReplayEntry
        @last_unsecured_counter_sweep = Time.instant
        @exchange_manager = ExchangeManager.new
        @message_observers = {} of Int32 => Proc(Codec::MessageCodec::Message, Socket::IPAddress, Bool)
        @observer_mutex = Mutex.new
        @next_observer_id = 0
        @pending_reliable = {} of Tuple(UInt16, UInt16, UInt32) => PendingReliableMessage
        @mrp_peer_parameters = {} of Tuple(UInt16, Socket::IPAddress) => Tuple(Time::Span, Time::Span, Time::Span)
        @mrp_unsecured_configured_at = {} of Socket::IPAddress => Time::Instant
        @mrp_peer_last_active = {} of Tuple(UInt16, Socket::IPAddress) => Time::Instant
        @reliable_mutex = Mutex.new
        @reliable_fiber = nil
        @running = false
        @receive_fiber = nil
        Log.info { "UDP transport bound: [::]:#{@port} (dual-stack)" }
      end

      # TCP-enabled transports can discover that an ephemeral UDP port is
      # already occupied by a TCP listener before their own listener starts.
      # Rebind before the receive loop runs, keeping the old socket until the
      # replacement and its multicast memberships are ready.
      protected def rebind_ephemeral_port(port : Int32) : Nil
        raise Matter::ConfigurationError.new("Cannot rebind a running UDP transport") if @running

        replacement = UDPSocket.new(Socket::Family::INET6)
        begin
          replacement.ipv6_only = false
          replacement.reuse_address = true
          replacement.reuse_port = true
          replacement.bind("::", port)
          replacement.read_timeout = RECEIVE_TIMEOUT
          @joined_groups.each { |address| replacement.join_group(address) }
        rescue ex
          replacement.close unless replacement.closed?
          raise ex
        end

        previous = @socket
        @socket = replacement
        @port = replacement.local_address.port
        previous.close unless previous.closed?
        Log.info { "UDP transport rebound: [::]:#{@port} (dual-stack)" }
      end

      # Start receiving messages in background
      def start : Nil
        return if @running

        @running = true
        @receive_fiber = spawn { receive_loop }
        @reliable_fiber = spawn { reliable_loop }
      end

      # Stop receiving messages
      def stop : Nil
        @running = false
        # Give fiber time to exit on next loop iteration
        sleep 200.milliseconds if @receive_fiber
        @receive_fiber = nil
        @reliable_fiber = nil
        clear_reliable
      end

      # Close transport and release resources
      def close : Nil
        stop
        @socket.close unless @socket.closed?
      end

      # Send a Matter message
      def send_message(
        message : Codec::MessageCodec::Message,
        peer_address : Socket::IPAddress,
      ) : Bytes
        # Update message ID if not set
        if message.packet_header.message_id == 0
          updated_header = Codec::MessageCodec::PacketHeader.new(
            session_id: message.packet_header.session_id,
            session_type: message.packet_header.session_type,
            message_id: @message_counter.next,
            privacy_enhancements: message.packet_header.privacy_enhancements?,
            control_message: message.packet_header.control_message?,
            message_extensions: message.packet_header.message_extensions?,
            source_node_id: message.packet_header.source_node_id,
            destination_node_id: message.packet_header.destination_node_id,
            destination_group_id: message.packet_header.destination_group_id
          )

          message = Codec::MessageCodec::Message.new(
            packet_header: updated_header,
            payload_header: message.payload_header,
            payload: message.payload
          )
        end

        # Encode and send
        data = Codec::MessageCodec::Base.encode_message(message.packet_header, message.payload_header, message.payload)

        Log.trace do
          "Sending UDP packet: bytes=#{data.size} peer=#{peer_address.address}:#{peer_address.port} " \
          "protocol=0x#{message.payload_header.protocol_id.to_s(16)} " \
          "type=0x#{message.payload_header.message_type.to_s(16)} msg_id=#{message.packet_header.message_id}"
        end

        if message.payload_header.requires_acknowledge?
          send_reliable_raw(data, peer_address, message.packet_header.session_id,
            message.payload_header.exchange_id, message.packet_header.message_id)
        else
          transmit(data, peer_address)
        end
        data
      end

      # Secure Channel replies are keyed to the exact unsecured request bytes
      # already accepted from this sender. A retransmission may replay only
      # that packet, never re-enter the PASE or CASE handshake.
      def cache_unsecured_response(original : Codec::MessageCodec::Message,
                                   peer : Socket::IPAddress, response : Bytes) : Nil
        return unless original.packet_header.session_id == Codec::MessageCodec::UNSECURED_SESSION_ID

        key = {original.packet_header.source_node_id.try(&.id), peer,
               original.packet_header.message_id}
        if entry = @unsecured_replay[key]?
          entry.response = response.dup
        end
      end

      # Send an already encoded packet.
      def send_raw(data : Bytes | Slice(UInt8), peer_address : Socket::IPAddress) : Nil
        transmit(data, peer_address)
      end

      # Retain the already encoded datagram. Reusing its exact ciphertext and
      # counter is essential: a retransmission is the same Matter message.
      def send_reliable_raw(data : Bytes | Slice(UInt8), peer_address : Socket::IPAddress,
                            session_id : UInt16, exchange_id : UInt16,
                            message_counter : UInt32) : Nil
        key = {session_id, exchange_id, message_counter}
        packet = data.to_slice.dup
        @reliable_mutex.synchronize do
          if @pending_reliable.size >= MRP_PENDING_LIMIT && !@pending_reliable.has_key?(key)
            raise Matter::TransportError.new("MRP retransmission table is full")
          end
          now = Time.instant
          peer_key = {session_id, canonical_peer(peer_address)}
          base = mrp_base_interval(peer_key, now)
          @pending_reliable[key] = PendingReliableMessage.new(packet, peer_address,
            session_id, exchange_id, message_counter, now + mrp_backoff(base, 0))
        end
        begin
          transmit(packet, peer_address)
        rescue ex
          @reliable_mutex.synchronize { @pending_reliable.delete(key) }
          raise ex
        end
      end

      # Call only after a secure message's AEAD is authenticated. The unsecured
      # path calls this after its payload is decoded.
      def acknowledge_reliable(session_id : UInt16, exchange_id : UInt16,
                               message_counter : UInt32,
                               peer : Socket::IPAddress? = nil) : Bool
        @reliable_mutex.synchronize do
          key = {session_id, exchange_id, message_counter}
          pending = @pending_reliable[key]?
          return false unless pending
          return false if peer && canonical_peer(pending.peer) != canonical_peer(peer)
          if @pending_reliable.delete(key)
            @mrp_peer_last_active[{session_id, canonical_peer(pending.peer)}] = Time.instant
            true
          else
            false
          end
        end
      end

      def pending_reliable_count : Int32
        @reliable_mutex.synchronize { @pending_reliable.size }
      end

      def clear_reliable_session(session_id : UInt16) : Nil
        @reliable_mutex.synchronize do
          @pending_reliable.reject! { |(pending_session_id, _, _), _| pending_session_id == session_id }
          @mrp_peer_parameters.reject! { |(stored_session_id, _), _| stored_session_id == session_id }
          @mrp_unsecured_configured_at.clear if session_id == Codec::MessageCodec::UNSECURED_SESSION_ID
          @mrp_peer_last_active.reject! { |(stored_session_id, _), _| stored_session_id == session_id }
        end
      end

      def configure_mrp_peer(peer : Socket::IPAddress, session_id : UInt16,
                             idle_interval_ms : UInt32? = nil,
                             active_interval_ms : UInt32? = nil,
                             active_threshold_ms : UInt16? = nil) : Nil
        idle = idle_interval_ms && idle_interval_ms > 0 ? idle_interval_ms.milliseconds : MRP_IDLE_RETRY_INTERVAL
        active = active_interval_ms && active_interval_ms > 0 ? active_interval_ms.milliseconds : MRP_ACTIVE_RETRY_INTERVAL
        threshold = active_threshold_ms && active_threshold_ms > 0 ? active_threshold_ms.milliseconds : MRP_ACTIVE_THRESHOLD
        @reliable_mutex.synchronize do
          canonical = canonical_peer(peer)
          @mrp_peer_parameters[{session_id, canonical}] = {idle, active, threshold}
          @mrp_unsecured_configured_at[canonical] = Time.instant if session_id == Codec::MessageCodec::UNSECURED_SESSION_ID
        end
      end

      def mark_mrp_peer_active(peer : Socket::IPAddress, session_id : UInt16) : Nil
        @reliable_mutex.synchronize do
          peer_key = {session_id, canonical_peer(peer)}
          @mrp_peer_last_active[peer_key] = Time.instant
        end
      end

      # Public to permit deterministic clock-based tests without sleeping.
      def retransmit_due(now : Time::Instant = Time.instant) : Nil
        @reliable_mutex.synchronize do
          @mrp_unsecured_configured_at.reject! do |peer, configured_at|
            pending_for_peer = @pending_reliable.values.any? do |pending|
              pending.session_id == Codec::MessageCodec::UNSECURED_SESSION_ID && canonical_peer(pending.peer) == peer
            end
            if now - configured_at > MRP_UNSECURED_CONFIG_TTL && !pending_for_peer
              @mrp_peer_parameters.delete({Codec::MessageCodec::UNSECURED_SESSION_ID, peer})
              true
            else
              false
            end
          end
          @mrp_peer_last_active.reject! { |peer_key, last_activity| now - last_activity > (@mrp_peer_parameters[peer_key]?.try(&.[2]) || MRP_ACTIVE_THRESHOLD) }
          @pending_reliable.reject! do |_key, pending|
            next false if pending.next_at > now
            if pending.retransmissions >= MRP_MAX_RETRANSMISSIONS
              true
            else
              pending.retransmissions += 1
              peer_key = {pending.session_id, canonical_peer(pending.peer)}
              pending.next_at = now + mrp_backoff(mrp_base_interval(peer_key, now), pending.retransmissions)
              begin
                transmit(pending.packet, pending.peer)
              rescue ex
                Log.debug(exception: ex) { "MRP retransmission failed for session #{pending.session_id}, counter #{pending.message_counter}" }
              end
              false
            end
          end
        end
      end

      protected def initialize_reliable_messages : Nil
        @pending_reliable = {} of Tuple(UInt16, UInt16, UInt32) => PendingReliableMessage
        @mrp_peer_parameters = {} of Tuple(UInt16, Socket::IPAddress) => Tuple(Time::Span, Time::Span, Time::Span)
        @mrp_unsecured_configured_at = {} of Socket::IPAddress => Time::Instant
        @mrp_peer_last_active = {} of Tuple(UInt16, Socket::IPAddress) => Time::Instant
        @reliable_mutex = Mutex.new
        @reliable_fiber = nil
      end

      protected def initialize_unsecured_replay : Nil
        @unsecured_replay = {} of Tuple(UInt64?, Socket::IPAddress, UInt32) => UnsecuredReplayEntry
      end

      protected def clear_reliable : Nil
        @reliable_mutex.synchronize do
          @pending_reliable.clear
          @mrp_peer_parameters.clear
          @mrp_unsecured_configured_at.clear
          @mrp_peer_last_active.clear
        end
      end

      private def reliable_loop : Nil
        while @running
          sleep MRP_SWEEP_INTERVAL
          retransmit_due if @running
        end
      rescue ex
        Log.error(exception: ex) { "MRP retransmission loop stopped" }
      end

      private def mrp_backoff(base_interval : Time::Span, retransmissions : Int32) : Time::Span
        exponent = {retransmissions - 1, 0}.max
        millis = base_interval.total_milliseconds *
                 MRP_BACKOFF_MARGIN * (MRP_BACKOFF_BASE ** exponent) *
                 (1.0 + Random.rand * MRP_BACKOFF_JITTER)
        millis.milliseconds
      end

      private def mrp_base_interval(peer_key : Tuple(UInt16, Socket::IPAddress),
                                    now : Time::Instant) : Time::Span
        intervals = @mrp_peer_parameters[peer_key]?
        threshold = intervals.try(&.[2]) || MRP_ACTIVE_THRESHOLD
        active = @mrp_peer_last_active[peer_key]?.try { |last| now - last <= threshold } || false
        if active
          intervals.try(&.[1]) || MRP_ACTIVE_RETRY_INTERVAL
        else
          intervals.try(&.[0]) || MRP_IDLE_RETRY_INTERVAL
        end
      end

      # The one place bytes leave the process. Specs override this to capture
      # what would have gone out rather than bind a socket.
      protected def transmit(data : Bytes | Slice(UInt8), peer_address : Socket::IPAddress) : Nil
        if data.size > MAX_DATAGRAM_SIZE
          raise Matter::ProtocolError.new("Matter UDP packet exceeds datagram limit")
        end
        # The transport owns an AF_INET6 dual-stack socket. Darwin rejects an
        # AF_INET destination on that socket even with IPV6_V6ONLY disabled;
        # send IPv4 destinations through their mapped IPv6 representation.
        destination = if peer_address.family == Socket::Family::INET
                        Socket::IPAddress.new("::ffff:#{peer_address.address}", peer_address.port)
                      else
                        peer_address
                      end
        @socket.send(data, destination)
      end

      private def canonical_peer(peer : Socket::IPAddress) : Socket::IPAddress
        address = peer.address
        return peer unless address.starts_with?(IPV4_MAPPED_PREFIX)

        Socket::IPAddress.new(address[IPV4_MAPPED_PREFIX.size..], peer.port)
      end

      # Create and send a message on a new exchange
      def send_request(
        protocol_id : UInt16,
        message_type : UInt8,
        payload : Bytes | Slice(UInt8),
        session_id : UInt16,
        peer_address : Socket::IPAddress,
        peer_node_id : DataType::NodeId? = nil,
        source_node_id : DataType::NodeId? = nil,
        requires_ack : Bool = true,
      ) : Exchange
        # Create new exchange
        exchange = @exchange_manager.create_exchange(
          protocol_id: protocol_id,
          session_id: session_id,
          peer_address: peer_address,
          peer_node_id: peer_node_id,
          initial_message_type: message_type
        )

        # Build message
        packet_header = Codec::MessageCodec::PacketHeader.new(
          session_id: session_id,
          session_type: Codec::MessageCodec::SessionType::Unicast,
          message_id: 0_u32, # Will be set by send_message
          privacy_enhancements: false,
          control_message: false,
          message_extensions: false,
          source_node_id: source_node_id,
          destination_node_id: peer_node_id
        )

        payload_header = Codec::MessageCodec::PayloadHeader.new(
          exchange_id: exchange.exchange_id,
          protocol_id: protocol_id,
          message_type: message_type,
          initiator_message: true,
          requires_acknowledge: requires_ack
        )

        message = Codec::MessageCodec::Message.new(
          packet_header: packet_header,
          payload_header: payload_header,
          payload: payload.to_slice
        )

        send_message(message, peer_address)
        exchange
      end

      private def receive_loop : Nil
        Log.debug { "UDP receive loop started (port=#{@port})" }
        buffer = Bytes.new(MAX_DATAGRAM_SIZE)
        packet_count = 0
        peer_address : Socket::IPAddress? = nil
        bytes_read = 0
        @last_exchange_sweep = Time.utc

        while @running
          begin
            sweep_exchanges_if_due
            bytes_read, peer_address = @socket.receive(buffer)
            next if bytes_read == 0

            packet_count += 1
            Log.trace { "Received UDP packet ##{packet_count}: bytes=#{bytes_read} peer=#{peer_address.address}:#{peer_address.port}" }

            handle_received_data(buffer[0, bytes_read], peer_address)
          rescue IO::TimeoutError
            # Normal - just continue
          rescue ex : Exception
            # Keep the receive loop running; a bad datagram is not an outage.
            peer = peer_address ? "#{peer_address.address}:#{peer_address.port}" : "unknown"
            Log.debug(exception: ex) { "Transport receive error (peer=#{peer} bytes=#{bytes_read})" }
          end
        end

        Log.debug { "UDP receive loop stopped" }
      end

      # Reclaims idle exchanges. The receive loop wakes every
      # `RECEIVE_TIMEOUT`, which is where the sweep gets its ticks: nothing
      # else drives the exchange table, so without this it only ever grows.
      private def sweep_exchanges_if_due : Nil
        now = Time.utc
        return if now - @last_exchange_sweep < EXCHANGE_SWEEP_INTERVAL

        @last_exchange_sweep = now
        @exchange_manager.cleanup_stale_exchanges(now)
      end

      private def handle_received_data(data : Bytes, peer_address : Socket::IPAddress) : Nil
        # Port zero is reserved for in-memory TCP route tokens. A network UDP
        # packet must never enter a TCP-bound CASE session under that identity.
        if peer_address.port == TCP_ROUTE_PORT
          Log.debug { "Ignoring UDP packet with source port zero" }
          return
        end
        if data.size < MIN_PACKET_SIZE
          Log.warn { "Packet too small (#{data.size} bytes, minimum #{MIN_PACKET_SIZE}); ignoring malformed packet" }
          return
        end

        if (data[Codec::MessageCodec::SECURITY_FLAGS_OFFSET] & Codec::MessageCodec::SecurityFlag::SessionTypeMask.value) == Codec::MessageCodec::SessionType::Group.value
          Log.debug { "Received group packet: bytes=#{data.size} peer=#{peer_address}" }
          @on_group_packet.try(&.call(data.dup, peer_address))
          return
        end

        Log.trace { "Decoding packet: bytes=#{data.size} peer=#{peer_address.address}:#{peer_address.port}" }

        # For encrypted messages, dump packet header bytes to debug source_node_id parsing
        if data.size > MIN_PACKET_SIZE
          session_id_offset = Codec::MessageCodec::SESSION_ID_OFFSET
          session_id_bytes = data[session_id_offset, 2]
          session_id = IO::ByteFormat::LittleEndian.decode(UInt16, session_id_bytes)

          if session_id != Codec::MessageCodec::UNSECURED_SESSION_ID
            flags = data[Codec::MessageCodec::FLAGS_OFFSET]
            Log.trace do
              "Encrypted packet header: first24=#{data[0, [24, data.size].min].hexstring} " \
              "flags=#{Hex.u8(flags)} " \
              "has_source_node_id=#{(flags & Codec::MessageCodec::PacketHeaderFlag::HasSourceNodeId.value) != 0} has_dest_node_id=#{(flags & Codec::MessageCodec::PacketHeaderFlag::HasDestNodeId.value) != 0} " \
              "session_id=#{session_id}"
            end
          end
        end

        # Decode packet
        packet = Codec::MessageCodec::Base.decode_packet(data)
        Log.trace do
          "Packet decoded: session_id=#{packet.header.session_id} message_id=#{packet.header.message_id} " \
          "source_node_id=#{packet.header.source_node_id.inspect} dest_node_id=#{packet.header.destination_node_id.inspect}"
        end

        # Check for duplicate messages
        session_id = packet.header.session_id
        # An ICD Check-In carries its own authenticated, durable counter inside
        # its AES-CCM payload. Its unsecured packet counter can restart at a
        # lower random value on the same UDP socket when the device reboots.
        # Decode the payload header first so only this message bypasses the
        # ordinary unsecured packet replay window; IcdClient validates the
        # inner counter after trial decryption.
        unsecured_message = session_id == Codec::MessageCodec::UNSECURED_SESSION_ID ? Codec::MessageCodec::Base.decode_payload(packet) : nil
        icd_check_in = if decoded = unsecured_message
                         decoded.payload_header.protocol_id == Protocol::ProtocolId::SecureChannel.value &&
                           decoded.payload_header.message_type == Protocol::SecureChannelMessageType::IcdCheckIn.value &&
                           decoded.payload_header.initiator_message?
                       else
                         false
                       end
        # A restarted CASE responder may likewise reset its unsecured packet
        # counter. Consider its responses only for our active, peer-scoped CASE
        # exchange; the pairing layer authenticates Sigma2 or its resume MIC
        # before establishing a session.
        case_response = if decoded = unsecured_message
                          header = decoded.payload_header
                          if header.protocol_id == Protocol::ProtocolId::SecureChannel.value &&
                             !header.initiator_message? &&
                             {Protocol::SecureChannelMessageType::CaseSigma2.value,
                              Protocol::SecureChannelMessageType::CaseSigma2Resume.value,
                              Protocol::SecureChannelMessageType::StatusReport.value}.includes?(header.message_type)
                            exchange = @exchange_manager.get_exchange(header.exchange_id, Codec::MessageCodec::UNSECURED_SESSION_ID, peer_address, true)
                            exchange && exchange.protocol_id == Protocol::ProtocolId::SecureChannel.value &&
                              exchange.initial_message_type == Protocol::SecureChannelMessageType::CaseSigma1.value &&
                              !exchange.stale?
                          else
                            false
                          end
                        else
                          false
                        end
        if session_id == Codec::MessageCodec::UNSECURED_SESSION_ID && !icd_check_in
          # A new transport can reuse its Node ID while starting a fresh counter.
          # Keep replay windows separate for each source socket, including when
          # the packet omits a source Node ID.
          source_node_id = packet.header.source_node_id.try(&.id)
          source_key = {source_node_id, peer_address}
          now = Time.instant
          sweep_unsecured_counters(now, source_key)
          counter = @unsecured_counters[source_key]?.try(&.[0]) || MessageCounter.new
          replay_key = {source_node_id, peer_address, packet.header.message_id}
          case counter.check(packet.header.message_id)
          when MessageCounter::CheckResult::Duplicate
            if case_response
              if entry = @unsecured_replay[replay_key]?
                if entry.request == data
                  replay_unsecured_duplicate(packet, data, peer_address, replay_key)
                  return
                end
              end
            else
              replay_unsecured_duplicate(packet, data, peer_address, replay_key)
              return
            end
          when MessageCounter::CheckResult::Stale
            if case_response
              if entry = @unsecured_replay[replay_key]?
                if entry.request == data
                  replay_unsecured_duplicate(packet, data, peer_address, replay_key)
                  return
                end
              end
            else
              return
            end
          end
          @unsecured_counters[source_key] = {counter, now}
          @unsecured_replay[replay_key] = UnsecuredReplayEntry.new(data.dup, now)
          prune_unsecured_replay(now)
        end

        # For encrypted messages (session_id != 0), do NOT decode the payload yet
        # The payload is encrypted and needs to be decrypted first by the message handler
        # For unencrypted messages (session_id == 0), decode the payload normally
        message = if decoded = unsecured_message
                    Log.trace { "Message decoded: protocol=0x#{decoded.payload_header.protocol_id.to_s(16)}, type=0x#{decoded.payload_header.message_type.to_s(16)}" }
                    decoded
                  else
                    # Encrypted message - create Message with raw encrypted payload
                    # The payload_header will be decoded AFTER decryption by the message handler
                    Log.trace do
                      "Encrypted message detected: session_id=#{session_id} payload_bytes=#{packet.payload.size} " \
                      "payload_hex=#{packet.payload.hexstring}"
                    end

                    # Create a dummy payload header - it will be ignored and replaced after decryption
                    dummy_payload_header = Codec::MessageCodec::PayloadHeader.new(
                      exchange_id: 0_u16,
                      protocol_id: 0_u16,
                      message_type: 0_u8,
                      initiator_message: false,
                      requires_acknowledge: false
                    )

                    Codec::MessageCodec::Message.new(
                      packet_header: packet.header,
                      payload_header: dummy_payload_header,
                      payload: packet.payload,
                      header_bytes: packet.header_bytes
                    )
                  end

        # For encrypted messages, skip exchange management - the message handler will do this after decryption
        # For unencrypted messages, handle exchanges and acknowledgments here
        if session_id == Codec::MessageCodec::UNSECURED_SESSION_ID
          mark_mrp_peer_active(peer_address, Codec::MessageCodec::UNSECURED_SESSION_ID)
          # Get or create exchange
          exchange = @exchange_manager.get_or_create_exchange(
            exchange_id: message.payload_header.exchange_id,
            protocol_id: message.payload_header.protocol_id,
            session_id: packet.header.session_id,
            peer_address: peer_address,
            peer_node_id: packet.header.source_node_id,
            initiator: !message.payload_header.initiator_message?
          )

          # Send acknowledgment if required
          if message.payload_header.requires_acknowledge?
            Log.trace { "Sending acknowledgment for message #{packet.header.message_id}" }
            send_acknowledgment(message, peer_address, exchange)
          end
          if ack = message.payload_header.acknowledged_message_id
            acknowledge_reliable(Codec::MessageCodec::UNSECURED_SESSION_ID, message.payload_header.exchange_id, ack, peer_address)
          end
        end

        dispatch_message(message, peer_address)
      rescue ex : Exception
        # Decode / processing errors for a single datagram
        Log.debug(exception: ex) { "Error handling received data (peer=#{peer_address.address}:#{peer_address.port} bytes=#{data.size})" }
      end

      # Give a controller sharing this listener first refusal. Copy the
      # observer set before calling out so an observer may unregister itself.
      # TCP subclasses use the same dispatch path without UDP's MRP state.
      protected def dispatch_message(message : Codec::MessageCodec::Message,
                                     peer_address : Socket::IPAddress) : Nil
        observers = @observer_mutex.synchronize { @message_observers.values.to_a }
        return if observers.any?(&.call(message, peer_address))

        # Deliver to application
        if callback = @on_message
          Log.trace { "Dispatching on_message callback" }
          callback.call(message, peer_address)
        else
          Log.warn { "No on_message callback registered" }
        end
      end

      private def sweep_unsecured_counters(now : Time::Instant,
                                           incoming_key : Tuple(UInt64?, Socket::IPAddress)) : Nil
        new_sender_at_limit = !@unsecured_counters.has_key?(incoming_key) &&
                              @unsecured_counters.size >= UNSECURED_COUNTER_LIMIT
        return unless new_sender_at_limit || now - @last_unsecured_counter_sweep >= UNSECURED_COUNTER_SWEEP_INTERVAL

        @last_unsecured_counter_sweep = now
        @unsecured_counters.reject! do |_key, entry|
          now - entry[1] >= UNSECURED_COUNTER_TTL
        end
        if new_sender_at_limit && @unsecured_counters.size >= UNSECURED_COUNTER_LIMIT
          oldest_key = @unsecured_counters.min_by { |_key, entry| entry[1] }[0]
          @unsecured_counters.delete(oldest_key)
        end
      end

      private def replay_unsecured_duplicate(packet : Codec::MessageCodec::Packet,
                                             data : Bytes, peer : Socket::IPAddress,
                                             key : Tuple(UInt64?, Socket::IPAddress, UInt32)) : Nil
        entry = @unsecured_replay[key]?
        return unless entry && entry.request == data
        if Time.instant - entry.created_at > UNSECURED_REPLAY_TTL
          @unsecured_replay.delete(key)
          return
        end

        message = Codec::MessageCodec::Base.decode_payload(packet)
        if message.payload_header.requires_acknowledge?
          exchange = @exchange_manager.get_or_create_exchange(
            exchange_id: message.payload_header.exchange_id,
            protocol_id: message.payload_header.protocol_id,
            session_id: Codec::MessageCodec::UNSECURED_SESSION_ID,
            peer_address: peer,
            peer_node_id: packet.header.source_node_id,
            initiator: !message.payload_header.initiator_message?)
          send_acknowledgment(message, peer, exchange)
        end
        if response = entry.response
          transmit(response, peer)
        end
      end

      private def prune_unsecured_replay(now : Time::Instant) : Nil
        @unsecured_replay.reject! { |_, entry| now - entry.created_at > UNSECURED_REPLAY_TTL }
        while @unsecured_replay.size > UNSECURED_REPLAY_LIMIT
          oldest = @unsecured_replay.min_by { |_, entry| entry.created_at }[0]
          @unsecured_replay.delete(oldest)
        end
      end

      private def send_acknowledgment(
        original_message : Codec::MessageCodec::Message,
        peer_address : Socket::IPAddress,
        exchange : Exchange,
      ) : Nil
        # Build ACK message (empty payload)
        packet_header = Codec::MessageCodec::PacketHeader.new(
          session_id: original_message.packet_header.session_id,
          session_type: original_message.packet_header.session_type,
          message_id: 0_u32, # Will be set by send_message
          privacy_enhancements: false,
          control_message: false,
          message_extensions: false,
          source_node_id: original_message.packet_header.destination_node_id,
          destination_node_id: original_message.packet_header.source_node_id
        )

        payload_header = Codec::MessageCodec::PayloadHeader.new(
          exchange_id: exchange.exchange_id,
          protocol_id: original_message.payload_header.protocol_id,
          message_type: STANDALONE_ACK_MESSAGE_TYPE,
          initiator_message: !original_message.payload_header.initiator_message?,
          requires_acknowledge: false,
          acknowledged_message_id: original_message.packet_header.message_id
        )

        ack_message = Codec::MessageCodec::Message.new(
          packet_header: packet_header,
          payload_header: payload_header,
          payload: Bytes.new(0)
        )

        send_message(ack_message, peer_address)
      end
    end
  end
end
