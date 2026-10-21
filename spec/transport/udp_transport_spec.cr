require "../spec_helper"
require "../../src/matter/transport/udp_transport"

describe Matter::Transport::UDPTransport do
  before_each do
    require_udp_sockets!
  end

  describe "#initialize" do
    it "creates transport on default port" do
      transport = Matter::Transport::UDPTransport.new
      transport.port.should eq(Matter::Transport::UDPTransport::MATTER_PORT)
      transport.close
    end

    it "creates transport on custom port" do
      transport = Matter::Transport::UDPTransport.new(port: 15540)
      transport.port.should eq(15540)
      transport.close
    end

    it "supports ephemeral ports" do
      transport = Matter::Transport::UDPTransport.new(port: 0)
      transport.port.should_not eq(0)
      transport.port.should be > 0
      transport.close
    end

    it "initializes message counter" do
      transport = Matter::Transport::UDPTransport.new(port: 15541)
      transport.message_counter.should_not be_nil
      transport.close
    end

    it "initializes exchange manager" do
      transport = Matter::Transport::UDPTransport.new(port: 15542)
      transport.exchange_manager.should_not be_nil
      transport.close
    end
  end

  describe "message counter integration" do
    it "assigns message IDs automatically" do
      transport = Matter::Transport::UDPTransport.new(port: 15543)

      # No source or destination node IDs, so flags is just version bits

      packet_header = Matter::Codec::MessageCodec::PacketHeader.new(
        session_id: 100_u16,
        session_type: Matter::Codec::MessageCodec::SessionType::Unicast,
        message_id: 0_u32, # Zero - should be assigned
        privacy_enhancements: false,
        control_message: false,
        message_extensions: false,
      )

      payload_header = Matter::Codec::MessageCodec::PayloadHeader.new(
        exchange_id: 1_u16,
        protocol_id: 0_u16,
        message_type: 1_u8,
        initiator_message: true,
        requires_acknowledge: false
      )

      message = Matter::Codec::MessageCodec::Message.new(
        packet_header: packet_header,
        payload_header: payload_header,
        payload: Bytes.new(0)
      )

      peer_address = Socket::IPAddress.new("::1", 5540)

      # Message counter should start at 0
      initial_counter = transport.message_counter.counter

      transport.send_message(message, peer_address)

      # Counter should have incremented
      transport.message_counter.counter.should eq(initial_counter + 1)

      transport.close
    end

    it "increments counter for each message sent" do
      transport = Matter::Transport::UDPTransport.new(port: 15544)
      peer_address = Socket::IPAddress.new("::1", 5540)

      initial_counter = transport.message_counter.counter

      # Send 3 messages
      3.times do |i|
        # No source or destination node IDs, so flags is just version bits

        packet_header = Matter::Codec::MessageCodec::PacketHeader.new(
          session_id: 100_u16,
          session_type: Matter::Codec::MessageCodec::SessionType::Unicast,
          message_id: 0_u32,
          privacy_enhancements: false,
          control_message: false,
          message_extensions: false,
        )

        payload_header = Matter::Codec::MessageCodec::PayloadHeader.new(
          exchange_id: 1_u16,
          protocol_id: 0_u16,
          message_type: 1_u8,
          initiator_message: true,
          requires_acknowledge: false
        )

        message = Matter::Codec::MessageCodec::Message.new(
          packet_header: packet_header,
          payload_header: payload_header,
          payload: Bytes[i.to_u8]
        )

        transport.send_message(message, peer_address)
      end

      transport.message_counter.counter.should eq(initial_counter + 3)

      transport.close
    end
  end

  describe "#send_request" do
    it "creates new exchange and sends message" do
      transport = Matter::Transport::UDPTransport.new(port: 15545)
      peer_address = Socket::IPAddress.new("::1", 5540)

      exchange = transport.send_request(
        protocol_id: 0_u16,
        message_type: 1_u8,
        payload: Bytes[0x01, 0x02],
        session_id: 100_u16,
        peer_address: peer_address,
        requires_ack: false
      )

      exchange.should_not be_nil
      exchange.initiator?.should be_true
      exchange.protocol_id.should eq(0_u16)
      exchange.peer_address.should eq(peer_address)

      transport.close
    end

    it "increments message counter" do
      transport = Matter::Transport::UDPTransport.new(port: 15546)
      peer_address = Socket::IPAddress.new("::1", 5540)

      initial_counter = transport.message_counter.counter

      transport.send_request(
        protocol_id: 0_u16,
        message_type: 1_u8,
        payload: Bytes[0x01],
        session_id: 100_u16,
        peer_address: peer_address,
        requires_ack: false
      )

      transport.message_counter.counter.should eq(initial_counter + 1)

      transport.close
    end
  end

  describe "exchange management" do
    it "creates exchanges for requests" do
      transport = Matter::Transport::UDPTransport.new(port: 15547)
      peer_address = Socket::IPAddress.new("::1", 5540)

      initial_count = transport.exchange_manager.active_count

      transport.send_request(
        protocol_id: 0_u16,
        message_type: 1_u8,
        payload: Bytes[0x01],
        session_id: 100_u16,
        peer_address: peer_address,
        requires_ack: false
      )

      transport.exchange_manager.active_count.should eq(initial_count + 1)

      transport.close
    end

    it "stores pending messages for retransmission" do
      transport = Matter::Transport::UDPTransport.new(port: 15548)
      peer_address = Socket::IPAddress.new("::1", 5540)

      exchange = transport.send_request(
        protocol_id: 0_u16,
        message_type: 1_u8,
        payload: Bytes[0x01],
        session_id: 100_u16,
        peer_address: peer_address,
        requires_ack: true # Requires ACK - will be stored for retransmission
      )

      exchange.should_not be_nil

      transport.close
    end
  end

  describe "#send_raw" do
    it "sends raw bytes" do
      transport = Matter::Transport::UDPTransport.new(port: 15549)
      peer_address = Socket::IPAddress.new("::1", 5540)

      data = Bytes[0x01, 0x02, 0x03, 0x04]

      # Should not raise
      transport.send_raw(data, peer_address)

      transport.close
    end
  end

  describe "#close" do
    it "closes the socket" do
      transport = Matter::Transport::UDPTransport.new(port: 15550)

      transport.close

      transport.socket.closed?.should be_true
    end

    it "can be called multiple times safely" do
      transport = Matter::Transport::UDPTransport.new(port: 15551)

      transport.close
      transport.close # Should not raise

      transport.socket.closed?.should be_true
    end
  end
end

require "../../src/matter/controller/client"

class AuthenticationBoundaryTransport < Matter::Transport::UDPTransport
  def receive_for_spec(data : Bytes, peer : Socket::IPAddress)
    handle_received_data(data, peer)
  end

  def unsecured_counter_count_for_spec : Int32
    @unsecured_counters.size
  end
end

describe Matter::Transport::UDPTransport do
  it "routes a shared controller exchange before the device and keeps the listener open" do
    transport = AuthenticationBoundaryTransport.new(port: 0)
    received_by_device = [] of UInt16
    transport.on_message = ->(message : Matter::Codec::MessageCodec::Message, _peer : Socket::IPAddress) {
      received_by_device << message.payload_header.exchange_id
      nil
    }
    client = Matter::Controller::Client.new(transport: transport)
    peer = Socket::IPAddress.new("127.0.0.1", transport.port)
    mapped_peer = Socket::IPAddress.new("::ffff:127.0.0.1", transport.port)
    exchange_id = client.send_unsecured_request(peer, 0_u16, 1_u8, Bytes.empty, requires_ack: false)

    response_header = Matter::Codec::MessageCodec::PayloadHeader.new(
      exchange_id: exchange_id, protocol_id: 0_u16, message_type: 2_u8,
      initiator_message: false, requires_acknowledge: false)
    response_packet = Matter::Codec::MessageCodec::PacketHeader.new(
      session_id: 0_u16, session_type: Matter::Codec::MessageCodec::SessionType::Unicast,
      message_id: 1_u32)
    response = Matter::Codec::MessageCodec::Base.encode_message(response_packet, response_header, Bytes.empty)
    transport.receive_for_spec(response, mapped_peer)

    client.wait_for(exchange_id, 0_u16, 2_u8, 100.milliseconds).should_not be_nil
    received_by_device.should be_empty

    client.close
    transport.socket.closed?.should be_false
    next_response_packet = Matter::Codec::MessageCodec::PacketHeader.new(
      session_id: 0_u16, session_type: Matter::Codec::MessageCodec::SessionType::Unicast,
      message_id: 2_u32)
    next_response = Matter::Codec::MessageCodec::Base.encode_message(next_response_packet, response_header, Bytes.empty)
    transport.receive_for_spec(next_response, mapped_peer)
    received_by_device.should eq([exchange_id])
  ensure
    client.try(&.close)
    transport.try(&.close)
  end

  it "accepts a fresh unsecured counter from the same Node ID on another UDP socket" do
    transport = AuthenticationBoundaryTransport.new(port: 0)
    received = [] of UInt32
    transport.on_message = ->(message : Matter::Codec::MessageCodec::Message, _peer : Socket::IPAddress) {
      received << message.packet_header.message_id
      nil
    }
    payload_header = Matter::Codec::MessageCodec::PayloadHeader.new(
      exchange_id: 1_u16, protocol_id: 0_u16, message_type: 1_u8,
      initiator_message: true, requires_acknowledge: false)
    [
      {1000_u32, Socket::IPAddress.new("::1", 50001)},
      {1_u32, Socket::IPAddress.new("::1", 50002)},
      {1_u32, Socket::IPAddress.new("::1", 50002)},
    ].each do |counter, peer|
      packet_header = Matter::Codec::MessageCodec::PacketHeader.new(
        session_id: 0_u16, session_type: Matter::Codec::MessageCodec::SessionType::Unicast,
        message_id: counter, source_node_id: Matter::DataType::NodeId.new(10_u64))
      bytes = Matter::Codec::MessageCodec::Base.encode_message(packet_header, payload_header, Bytes.empty)
      transport.receive_for_spec(bytes, peer)
    end
    received.should eq([1000_u32, 1_u32])
  ensure
    transport.try(&.close)
  end

  it "bounds unsecured replay windows from distinct UDP sockets" do
    transport = AuthenticationBoundaryTransport.new(port: 0)
    transport.on_message = ->(_message : Matter::Codec::MessageCodec::Message, _peer : Socket::IPAddress) { nil }
    payload_header = Matter::Codec::MessageCodec::PayloadHeader.new(
      exchange_id: 1_u16, protocol_id: 0_u16, message_type: 1_u8,
      initiator_message: true, requires_acknowledge: false)
    packet_header = Matter::Codec::MessageCodec::PacketHeader.new(
      session_id: 0_u16, session_type: Matter::Codec::MessageCodec::SessionType::Unicast,
      message_id: 1_u32, source_node_id: Matter::DataType::NodeId.new(10_u64))
    bytes = Matter::Codec::MessageCodec::Base.encode_message(packet_header, payload_header, Bytes.empty)
    (1..(Matter::Transport::UDPTransport::UNSECURED_COUNTER_LIMIT + 1)).each do |port|
      transport.receive_for_spec(bytes, Socket::IPAddress.new("::1", port))
    end
    transport.unsecured_counter_count_for_spec.should eq(Matter::Transport::UDPTransport::UNSECURED_COUNTER_LIMIT)
  ensure
    transport.try(&.close)
  end

  it "forwards secure packets and their exact headers before deciding replay state" do
    transport = AuthenticationBoundaryTransport.new(port: 0)
    received = [] of Matter::Codec::MessageCodec::Message
    transport.on_message = ->(message : Matter::Codec::MessageCodec::Message, _peer : Socket::IPAddress) { received << message; nil }
    peer = Socket::IPAddress.new("::1", 5540)
    # A forged high counter must not suppress a later genuine low counter in UDP.
    [1000_u32, 1_u32].each do |counter|
      header = Matter::Codec::MessageCodec::PacketHeader.new(
        session_id: 1_u16, session_type: Matter::Codec::MessageCodec::SessionType::Unicast,
        message_id: counter, source_node_id: Matter::DataType::NodeId.new(10_u64))
      bytes = Matter::Codec::MessageCodec::Base.encode_packet(Matter::Codec::MessageCodec::Packet.new(header, Bytes.new(16)))
      transport.receive_for_spec(bytes, peer)
    end
    received.map(&.packet_header.message_id).should eq([1000_u32, 1_u32])
    received.each do |message|
      message.header_bytes.should eq(Matter::Codec::MessageCodec::Base.encode_packet_header(message.packet_header))
    end
  ensure
    transport.try(&.close)
  end
end
