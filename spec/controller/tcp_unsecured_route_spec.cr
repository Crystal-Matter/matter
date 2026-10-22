require "../spec_helper"
require "../../src/matter/controller/client"
require "../../src/matter/transport/tcp_enabled_transport"

describe "controller unsecured Matter TCP routing" do
  it "accepts a CASE-style reply only on the originating connection" do
    require_udp_sockets!
    server = Matter::Transport::TcpEnabledTransport.new(port: 0)
    received = Channel(Socket::IPAddress).new(2)
    server.on_message = ->(_msg : Matter::Codec::MessageCodec::Message, peer : Socket::IPAddress) {
      received.send(peer)
      nil
    }
    server.start
    controller = Matter::Controller::Client.new(tcp_enabled: true)
    begin
      address = Socket::IPAddress.new("::1", server.port)
      first = controller.connect_tcp(address)
      exchange = controller.send_unsecured_request(first, 0_u16, 1_u8, Bytes.empty,
        requires_ack: false)
      first_server_peer = nil.as(Socket::IPAddress?)
      select
      when first_server_peer = received.receive
      when timeout(2.seconds)
      end
      first_server_peer.should_not be_nil

      second = controller.connect_tcp(address)
      controller.send_unsecured_request(second, 0_u16, 1_u8, Bytes.empty,
        requires_ack: false)
      second_server_peer = nil.as(Socket::IPAddress?)
      select
      when second_server_peer = received.receive
      when timeout(2.seconds)
      end
      second_server_peer.should_not be_nil

      packet = Matter::Codec::MessageCodec::PacketHeader.new(
        session_id: 0_u16,
        session_type: Matter::Codec::MessageCodec::SessionType::Unicast,
        message_id: 1_u32)
      payload = Matter::Codec::MessageCodec::PayloadHeader.new(
        exchange_id: exchange, protocol_id: 0_u16, message_type: 2_u8,
        initiator_message: false, requires_acknowledge: false)
      reply = Matter::Codec::MessageCodec::Message.new(packet, payload, Bytes.empty)
      server.send_message(reply, second_server_peer.as(Socket::IPAddress))
      controller.wait_for(exchange, 0_u16, 2_u8, 100.milliseconds).should be_nil

      server.send_message(reply, first_server_peer.as(Socket::IPAddress))
      controller.wait_for(exchange, 0_u16, 2_u8, 2.seconds).should_not be_nil
    ensure
      controller.close
      server.close
    end
  end
end
