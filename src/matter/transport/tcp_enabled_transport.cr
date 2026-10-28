require "socket"
require "log"

require "../codec/message_codec"
require "../error"
require "./tcp_frame_codec"
require "./udp_transport"

module Matter
  module Transport
    # An opt-in TCP listener and connection pool sharing one device/controller
    # message handler with UDP. TCP peers are represented by ephemeral, local
    # route tokens: IPv6 addresses with port zero. They are never used as
    # network destinations, and a closed token never falls back to UDP.
    class TcpEnabledTransport < UDPTransport
      Log = ::Log.for("matter.transport.tcp_enabled_transport")

      # The Matter SDK's default large packet buffer is 64,000 bytes and its
      # TCP frame includes four more bytes. Leave headroom for builds with
      # slightly smaller reserves and bound allocations before authentication.
      MAX_TCP_PACKET_SIZE         = 63_000
      APPLICATION_MESSAGE_LIMIT   = MAX_TCP_PACKET_SIZE
      DEFAULT_MAX_TCP_CONNECTIONS = 16
      EPHEMERAL_BIND_ATTEMPTS     = 16
      READ_TIMEOUT                = 10.seconds
      FRAME_TIMEOUT               = 10.seconds
      IDLE_TIMEOUT                = 5.minutes
      CONNECT_TIMEOUT             = 5.seconds
      WRITE_TIMEOUT               = 5.seconds
      READ_BUFFER_SIZE            = 4096
      TOKEN_PORT                  = UDPTransport::TCP_ROUTE_PORT

      private class Connection
        getter socket : TCPSocket
        getter token : Socket::IPAddress
        getter write_mutex : Mutex

        def initialize(@socket : TCPSocket, @token : Socket::IPAddress)
          @write_mutex = Mutex.new
        end
      end

      getter max_tcp_connections : Int32

      @tcp_server : TCPServer?
      @tcp_connections : Hash(Socket::IPAddress, Connection)
      @tcp_mutex : Mutex
      @tcp_running : Bool
      @tcp_token_nonce : Bytes
      @next_tcp_route_id : UInt64
      @connection_closed_observers : Hash(Int32, Proc(Socket::IPAddress, Nil))
      @next_connection_closed_observer_id : Int32
      @ephemeral_port : Bool

      def initialize(port : Int32 = MATTER_PORT,
                     @max_tcp_connections : Int32 = DEFAULT_MAX_TCP_CONNECTIONS)
        unless @max_tcp_connections.in?(1..DEFAULT_MAX_TCP_CONNECTIONS)
          raise Matter::ConfigurationError.new("Matter TCP connection limit is out of range")
        end
        @tcp_server = nil
        @tcp_connections = {} of Socket::IPAddress => Connection
        @tcp_mutex = Mutex.new
        @tcp_running = false
        @tcp_token_nonce = Random::Secure.random_bytes(6)
        @next_tcp_route_id = 0_u64
        @connection_closed_observers = {} of Int32 => Proc(Socket::IPAddress, Nil)
        @next_connection_closed_observer_id = 0
        @ephemeral_port = port == 0
        super(port: port)
      end

      # Shared transports can serve a device and several controllers. Each
      # owner removes only the secure sessions bound to the closed route.
      def add_connection_closed_observer(&block : Socket::IPAddress -> Nil) : Int32
        @tcp_mutex.synchronize do
          @next_connection_closed_observer_id += 1
          id = @next_connection_closed_observer_id
          @connection_closed_observers[id] = block
          id
        end
      end

      def remove_connection_closed_observer(id : Int32) : Nil
        @tcp_mutex.synchronize { @connection_closed_observers.delete(id) }
      end

      def start : Nil
        return if @tcp_running

        server = begin
          listen_tcp(port)
        rescue ex : Socket::BindError
          raise ex unless @ephemeral_port
          reserve_ephemeral_port_pair
        end
        begin
          @tcp_server = server
          super
          @tcp_running = true
          spawn { accept_loop(server) }
        rescue ex
          server.close unless server.closed?
          @tcp_server = nil
          raise ex
        end
      end

      protected def listen_tcp(port : Int32) : TCPServer
        server = TCPServer.new(Socket::Family::INET6)
        begin
          server.ipv6_only = false
          server.reuse_address = true
          server.bind("::", port)
          server.listen(@max_tcp_connections)
          server
        rescue ex
          server.close unless server.closed?
          raise ex
        end
      end

      private def reserve_ephemeral_port_pair : TCPServer
        EPHEMERAL_BIND_ATTEMPTS.times do
          # TCP and UDP ephemeral allocations can have different exclusions.
          # Select the UDP port first, then try to bind TCP to that port.
          rebind_ephemeral_port(0)
          return listen_tcp(port)
        rescue Socket::BindError
          next
        end
        raise Matter::TransportError.new("Could not allocate a shared ephemeral UDP/TCP port")
      end

      def stop : Nil
        stop_tcp
        super
      end

      def close : Nil
        stop_tcp
        super
      end

      # Open one explicitly requested TCP path. The returned token must be
      # passed as the peer to CASE and subsequent interactions on this path.
      def connect_tcp(peer : Socket::IPAddress) : Socket::IPAddress
        raise Matter::TransportError.new("Matter TCP transport is not running") unless @tcp_running
        raise Matter::TransportError.new("Matter TCP connection pool is full") if tcp_connection_count >= @max_tcp_connections
        raise Matter::ConfigurationError.new("Matter TCP cannot connect to a route token") if peer.port == TOKEN_PORT

        socket = TCPSocket.new(peer.address, peer.port, connect_timeout: CONNECT_TIMEOUT.total_seconds)
        register_connection(socket)
      rescue ex : Matter::Error
        raise ex
      rescue ex
        raise Matter::TransportError.new("Matter TCP connection failed", cause: ex)
      end

      def disconnect_tcp(peer : Socket::IPAddress) : Nil
        connection, observers = @tcp_mutex.synchronize do
          {@tcp_connections.delete(peer), @connection_closed_observers.values.to_a}
        end
        return unless connection

        connection.socket.close unless connection.socket.closed?
        unless observers.empty?
          spawn do
            observers.each do |observer|
              observer.call(peer)
            rescue ex
              Log.error(exception: ex) { "TCP connection cleanup callback failed" }
            end
          end
        end
      end

      def tcp_peer?(peer : Socket::IPAddress) : Bool
        return false unless peer.port == TOKEN_PORT
        @tcp_mutex.synchronize { @tcp_connections.has_key?(peer) }
      end

      def tcp_connection_count : Int32
        @tcp_mutex.synchronize { @tcp_connections.size }
      end

      def send_reliable_raw(data : Bytes | Slice(UInt8), peer_address : Socket::IPAddress,
                            session_id : UInt16, exchange_id : UInt16,
                            message_counter : UInt32) : Nil
        if peer_address.port == TOKEN_PORT
          transmit(data, peer_address)
        else
          super
        end
      end

      def cache_unsecured_response(original : Codec::MessageCodec::Message,
                                   peer : Socket::IPAddress, response : Bytes) : Nil
        super unless peer.port == TOKEN_PORT
      end

      protected def transmit(data : Bytes | Slice(UInt8), peer_address : Socket::IPAddress) : Nil
        unless peer_address.port == TOKEN_PORT
          super
          return
        end
        connection = @tcp_mutex.synchronize { @tcp_connections[peer_address]? }
        raise Matter::TransportError.new("Matter TCP connection is closed") unless connection
        if data.size > MAX_TCP_PACKET_SIZE
          raise Matter::ProtocolError.new("Matter TCP packet exceeds large payload limit")
        end
        frame = TcpFrameCodec.encode(data.to_slice, MAX_TCP_PACKET_SIZE)
        connection.write_mutex.synchronize do
          raise Matter::TransportError.new("Matter TCP connection is closed") if connection.socket.closed?
          connection.socket.write(frame)
        end
      rescue ex : IO::Error
        disconnect_tcp(peer_address)
        raise Matter::TransportError.new("Matter TCP send failed", cause: ex)
      end

      private def stop_tcp : Nil
        @tcp_running = false
        if server = @tcp_server
          server.close unless server.closed?
          @tcp_server = nil
        end
        tokens = @tcp_mutex.synchronize { @tcp_connections.keys.to_a }
        tokens.each { |token| disconnect_tcp(token) }
      end

      private def accept_loop(server : TCPServer) : Nil
        while @tcp_running
          socket = server.accept?
          break unless socket
          begin
            register_connection(socket)
          rescue ex
            socket.close unless socket.closed?
            Log.debug(exception: ex) { "Rejected Matter TCP connection" }
          end
        end
      rescue ex : IO::Error
        Log.debug(exception: ex) { "Matter TCP listener stopped" } if @tcp_running
      end

      private def register_connection(socket : TCPSocket) : Socket::IPAddress
        token = nil.as(Socket::IPAddress?)
        token = @tcp_mutex.synchronize do
          raise Matter::TransportError.new("Matter TCP transport is not running") unless @tcp_running
          if @tcp_connections.size >= @max_tcp_connections
            raise Matter::TransportError.new("Matter TCP connection pool is full")
          end
          route = new_token
          @tcp_connections[route] = Connection.new(socket, route)
          route
        end
        socket.read_timeout = READ_TIMEOUT
        socket.write_timeout = WRITE_TIMEOUT
        socket.tcp_nodelay = true
        spawn { read_loop(socket, token) }
        token
      rescue ex
        @tcp_mutex.synchronize { @tcp_connections.delete(token) } if token
        socket.close unless socket.closed?
        raise ex
      end

      # Port zero cannot match an accepted UDP packet. A process nonce and
      # monotonic ID make every route unique, even after disconnect/reconnect.
      private def new_token : Socket::IPAddress
        if @next_tcp_route_id == UInt64::MAX
          raise Matter::TransportError.new("Matter TCP route token space exhausted")
        end
        @next_tcp_route_id += 1_u64
        nonce = @tcp_token_nonce.hexstring
        id = @next_tcp_route_id.to_s(16).rjust(16, '0')
        groups = (0...3).map { |index| nonce[index * 4, 4] }
        groups.concat((0...4).map { |index| id[index * 4, 4] })
        Socket::IPAddress.new("fd00:#{groups.join(":")}", TOKEN_PORT)
      end

      private def read_loop(socket : TCPSocket, token : Socket::IPAddress) : Nil
        codec = TcpFrameCodec.new(MAX_TCP_PACKET_SIZE)
        buffer = Bytes.new(READ_BUFFER_SIZE)
        last_activity = Time.instant
        frame_started_at : Time::Instant? = nil
        while @tcp_running && !socket.closed?
          begin
            bytes_read = socket.read(buffer)
            break if bytes_read == 0
            now = Time.instant
            last_activity = now
            frame_started_at ||= now
            messages = codec.feed(buffer[0, bytes_read])
            messages.each do |wire|
              dispatch_tcp_packet(wire, token)
            end
            frame_started_at = if codec.incomplete?
                                 messages.empty? ? frame_started_at : now
                               end
            if started = frame_started_at
              raise Matter::ProtocolError.new("Matter TCP frame timed out") if now - started > FRAME_TIMEOUT
            end
          rescue IO::TimeoutError
            now = Time.instant
            break if codec.incomplete? || now - last_activity >= IDLE_TIMEOUT
          end
        end
      rescue ex : Matter::Error
        Log.debug(exception: ex) { "Closed malformed Matter TCP connection" }
      rescue ex : IO::Error
        Log.debug(exception: ex) { "Matter TCP connection closed" }
      ensure
        disconnect_tcp(token)
      end

      private def dispatch_tcp_packet(wire : Bytes, token : Socket::IPAddress) : Nil
        raise Matter::ProtocolError.new("Matter TCP packet is truncated") if wire.size < MIN_PACKET_SIZE
        if wire.size > MAX_TCP_PACKET_SIZE
          raise Matter::ProtocolError.new("Matter TCP packet exceeds large payload limit")
        end
        packet = Codec::MessageCodec::Base.decode_packet(wire)
        if packet.header.session_type == Codec::MessageCodec::SessionType::Group
          raise Matter::ProtocolError.new("Matter group packets cannot use TCP")
        end
        message = if packet.header.session_id == Codec::MessageCodec::UNSECURED_SESSION_ID
                    Codec::MessageCodec::Base.decode_payload(packet)
                  else
                    dummy = Codec::MessageCodec::PayloadHeader.encrypted_placeholder
                    Codec::MessageCodec::Message.new(packet.header, dummy,
                      packet.payload, packet.header_bytes)
                  end
        dispatch_message(message, token)
      end
    end
  end
end
