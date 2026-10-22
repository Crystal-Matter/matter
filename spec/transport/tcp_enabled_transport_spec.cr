require "../spec_helper"
require "../../src/matter/transport/tcp_enabled_transport"
require "../../src/matter/protocol/response_sender"
require "../../src/matter/protocol/session_registry"

private alias TcpTransport = Matter::Transport::TcpEnabledTransport
private alias Codec = Matter::Codec::MessageCodec

private class TcpTransportForUdpBoundarySpec < TcpTransport
  def receive_udp_for_spec(data : Bytes, peer : Socket::IPAddress) : Nil
    handle_received_data(data, peer)
  end

  def write_timeout_for_spec(peer : Socket::IPAddress) : Time::Span?
    @tcp_connections[peer].socket.write_timeout
  end
end

private def tcp_test_message(exchange_id : UInt16, message_id : UInt32 = 1_u32) : Codec::Message
  packet = Codec::PacketHeader.new(
    session_id: 0_u16, session_type: Codec::SessionType::Unicast,
    message_id: message_id)
  payload = Codec::PayloadHeader.new(
    exchange_id: exchange_id, protocol_id: 0_u16,
    message_type: 1_u8, initiator_message: true,
    requires_acknowledge: false)
  Codec::Message.new(packet, payload, Bytes[0xaa, 0xbb])
end

describe TcpTransport do
  before_each { require_udp_sockets! }

  it "grants the large IM budget only to a live connection-bound secure session" do
    server = TcpTransport.new(port: 0)
    client = TcpTransport.new(port: 0)
    server.start
    client.start
    begin
      peer = client.connect_tcp(Socket::IPAddress.new("::1", server.port))
      session = Matter::Session::SecureContext.new(
        session_id: 1_u16, peer_session_id: 2_u16,
        session_type: Matter::Session::SessionType::Unicast,
        encryption_key: Bytes.new(16, 1_u8), decryption_key: Bytes.new(16, 2_u8))
      sender = Matter::Protocol::ResponseSender.new(client, Matter::Protocol::MrpCache.new(client))
      sender.im_payload_limit(session, peer).should eq(Matter::Protocol::IMHandler::MAX_REPORT_PAYLOAD_SIZE)
      session.bind_tcp_peer(peer)
      sender.im_payload_limit(session, peer).should eq(Matter::Protocol::IMHandler::MAX_TCP_REPORT_PAYLOAD_SIZE)
      sender.im_payload_limit(session, Socket::IPAddress.new("::1", server.port))
        .should eq(Matter::Protocol::IMHandler::MAX_REPORT_PAYLOAD_SIZE)
      client.disconnect_tcp(peer)
      sender.im_payload_limit(session, peer).should eq(Matter::Protocol::IMHandler::MAX_REPORT_PAYLOAD_SIZE)
    ensure
      client.close
      server.close
    end
  end

  it "routes framed Matter packets and replies through a live TCP connection token" do
    server = TcpTransport.new(port: 0)
    client = TcpTransportForUdpBoundarySpec.new(port: 0)
    incoming = Channel(Tuple(Codec::Message, Socket::IPAddress)).new(1)
    returned = Channel(Codec::Message).new(1)
    server.on_message = ->(msg : Codec::Message, peer : Socket::IPAddress) {
      incoming.send({msg, peer})
      nil
    }
    client.on_message = ->(msg : Codec::Message, _peer : Socket::IPAddress) {
      returned.send(msg)
      nil
    }
    server.start
    client.start

    begin
      peer = client.connect_tcp(Socket::IPAddress.new("::1", server.port))
      peer.port.should eq(0)
      client.tcp_peer?(peer).should be_true
      client.write_timeout_for_spec(peer).should eq(TcpTransport::WRITE_TIMEOUT)
      expect_raises(Matter::ProtocolError) do
        client.send_raw(Bytes.new(TcpTransport::MAX_TCP_PACKET_SIZE + 1, 0_u8), peer)
      end
      client.send_message(tcp_test_message(7_u16), peer)

      received = nil.as(Tuple(Codec::Message, Socket::IPAddress)?)
      select
      when received = incoming.receive
      when timeout(2.seconds)
      end
      received.should_not be_nil
      request, reply_peer = received.as(Tuple(Codec::Message, Socket::IPAddress))
      request.payload.should eq(Bytes[0xaa, 0xbb])
      reply_peer.port.should eq(0)
      server.tcp_peer?(reply_peer).should be_true
      server.send_message(tcp_test_message(7_u16, 2_u32), reply_peer)

      response = nil.as(Codec::Message?)
      select
      when response = returned.receive
      when timeout(2.seconds)
      end
      response.should_not be_nil
      response.as(Codec::Message).packet_header.message_id.should eq(2_u32)

      client.disconnect_tcp(peer)
      expect_raises(Matter::TransportError) { client.send_raw(Bytes[1], peer) }
      next_peer = client.connect_tcp(Socket::IPAddress.new("::1", server.port))
      next_peer.should_not eq(peer)
      client.disconnect_tcp(next_peer)
    ensure
      client.close
      server.close
    end
  end

  it "keeps regular UDP delivery available when TCP is enabled" do
    transport = TcpTransport.new(port: 0)
    incoming = Channel(Codec::Message).new(1)
    transport.on_message = ->(msg : Codec::Message, _peer : Socket::IPAddress) {
      incoming.send(msg)
      nil
    }
    transport.start
    sender = UDPSocket.new(Socket::Family::INET6)
    begin
      packet = tcp_test_message(8_u16)
      wire = Codec::Base.encode_message(packet.packet_header, packet.payload_header, packet.payload)
      sender.send(wire, Socket::IPAddress.new("::1", transport.port))
      received = nil.as(Codec::Message?)
      select
      when received = incoming.receive
      when timeout(2.seconds)
      end
      received.should_not be_nil
      received.as(Codec::Message).payload_header.exchange_id.should eq(8_u16)
    ensure
      sender.close
      transport.close
    end
  end

  it "rejects invalid limits before opening a socket" do
    expect_raises(Matter::ConfigurationError) do
      TcpTransport.new(port: 0, max_tcp_connections: 0)
    end
    expect_raises(Matter::ConfigurationError) do
      TcpTransport.new(port: 0, max_tcp_connections: TcpTransport::DEFAULT_MAX_TCP_CONNECTIONS + 1)
    end
  end

  it "closes an oversized frame before allocating its body" do
    server = TcpTransport.new(port: 0)
    server.start
    socket = TCPSocket.new("::1", server.port)
    begin
      deadline = Time.instant + 2.seconds
      until server.tcp_connection_count == 1 || Time.instant >= deadline
        sleep 10.milliseconds
      end
      server.tcp_connection_count.should eq(1)
      oversized = Bytes.new(Matter::Transport::TcpFrameCodec::LENGTH_PREFIX_SIZE)
      IO::ByteFormat::LittleEndian.encode((TcpTransport::MAX_TCP_PACKET_SIZE + 1).to_u32, oversized)
      socket.write(oversized)
      deadline = Time.instant + 2.seconds
      until server.tcp_connection_count == 0 || Time.instant >= deadline
        sleep 10.milliseconds
      end
      server.tcp_connection_count.should eq(0)
    ensure
      socket.close
      server.close
    end
  end

  it "notifies route owners once when the remote peer closes the TCP stream" do
    server = TcpTransport.new(port: 0)
    closed = Channel(Socket::IPAddress).new(2)
    server.add_connection_closed_observer { |peer| closed.send(peer) }
    server.start
    socket = TCPSocket.new("::1", server.port)
    begin
      deadline = Time.instant + 2.seconds
      until server.tcp_connection_count == 1 || Time.instant >= deadline
        sleep 10.milliseconds
      end
      server.tcp_connection_count.should eq(1)
      socket.close

      peer = nil.as(Socket::IPAddress?)
      select
      when peer = closed.receive
      when timeout(2.seconds)
      end
      peer.should_not be_nil
      server.tcp_peer?(peer.as(Socket::IPAddress)).should be_false
      server.disconnect_tcp(peer.as(Socket::IPAddress))
      duplicate = false
      select
      when closed.receive
        duplicate = true
      when timeout(20.milliseconds)
      end
      duplicate.should be_false
    ensure
      socket.close unless socket.closed?
      server.close
    end
  end

  it "does not wait for registry cleanup while disconnecting a blocked route" do
    server = TcpTransport.new(port: 0)
    client = TcpTransport.new(port: 0)
    server.start
    client.start
    begin
      peer = client.connect_tcp(Socket::IPAddress.new("::1", server.port))
      registry = Matter::Protocol::SessionRegistry.new(Matter::Protocol::MrpCache.new(client))
      session = Matter::Session::SecureContext.new(
        session_id: 99_u16, peer_session_id: 100_u16,
        session_type: Matter::Session::SessionType::Unicast,
        encryption_key: Bytes.new(16, 1_u8), decryption_key: Bytes.new(16, 2_u8))
      session.bind_tcp_peer(peer)
      registry.establish_session(session)
      client.add_connection_closed_observer { |_route| registry.delete_session(session.session_id); nil }

      disconnected = Channel(Nil).new(1)
      completed = false
      registry.synchronize do
        spawn do
          client.disconnect_tcp(peer)
          disconnected.send(nil)
        end
        select
        when disconnected.receive
          completed = true
        when timeout(200.milliseconds)
        end
      end
      completed.should be_true

      deadline = Time.instant + 2.seconds
      while registry.session(session.session_id) && Time.instant < deadline
        sleep 10.milliseconds
      end
      registry.session(session.session_id).should be_nil
    ensure
      client.close
      server.close
    end
  end

  it "receives a framed Matter packet larger than the UDP MTU" do
    server = TcpTransport.new(port: 0)
    client = TcpTransport.new(port: 0)
    incoming = Channel(Codec::Message).new(1)
    server.on_message = ->(msg : Codec::Message, _peer : Socket::IPAddress) {
      incoming.send(msg)
      nil
    }
    server.start
    client.start
    begin
      peer = client.connect_tcp(Socket::IPAddress.new("::1", server.port))
      original = tcp_test_message(25_u16)
      large = Codec::Message.new(original.packet_header, original.payload_header,
        Bytes.new(4096, 0xa5_u8))
      client.send_message(large, peer)
      received = nil.as(Codec::Message?)
      select
      when received = incoming.receive
      when timeout(2.seconds)
      end
      received.should_not be_nil
      received.as(Codec::Message).payload.should eq(large.payload)
    ensure
      client.close
      server.close
    end
  end

  it "never accepts a UDP datagram under a TCP route-token identity" do
    transport = TcpTransportForUdpBoundarySpec.new(port: 0)
    called = false
    transport.on_message = ->(_msg : Codec::Message, _peer : Socket::IPAddress) {
      called = true
      nil
    }
    message = tcp_test_message(9_u16)
    wire = Codec::Base.encode_message(message.packet_header, message.payload_header, message.payload)
    transport.receive_udp_for_spec(wire, Socket::IPAddress.new("fd00::1", 0))
    called.should be_false
  ensure
    transport.try(&.close)
  end
end
