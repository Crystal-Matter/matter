require "../spec_helper"
require "../../src/matter/controller/bdx_client"
require "../../src/matter/protocol/message_handler"
require "../../src/matter/transport/tcp_enabled_transport"

private alias BdxTcp = Matter::Protocol::Bdx

# A complete encrypted BDX exchange exercises TCP framing, connection routing,
# and the existing device/controller handler without an external commissioner.
describe "BDX over encrypted Matter TCP" do
  it "streams blocks on a connection-bound CASE session without UDP MRP" do
    require_udp_sockets!
    transport = Matter::Transport::TcpEnabledTransport.new(port: 0)
    handler = Matter::Protocol::MessageHandler.new(transport,
      setup_pin: 20202021_u32, discriminator: 3840_u16,
      fabric_table: Matter::FabricTable.new(Matter::Storage::Memory.new))
    contents = Bytes.new(1537) { |index| (index % 251).to_u8 }
    handler.bdx.on_download = ->(_session : Matter::Session::SecureContext, init : BdxTcp::Wire::Init) do
      init.file_designator == "download".to_slice ? BdxTcp::Responder::Source.new(IO::Memory.new(contents), contents.size.to_u64).as(BdxTcp::Responder::Source?) : nil
    end
    transport.start

    controller = Matter::Controller::Client.new(tcp_enabled: true)
    peer = controller.connect_tcp(Socket::IPAddress.new("::1", transport.port))
    device_session = Matter::Session::SecureContext.new(
      session_id: 101_u16, peer_session_id: 102_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16, 0x11_u8),
      decryption_key: Bytes.new(16, 0x22_u8),
      local_node_id: Matter::DataType::NodeId.new(0x111_u64),
      peer_node_id: Matter::DataType::NodeId.new(0x222_u64),
      case_session: true, fabric_index: 1_u8)
    controller_session = Matter::Session::SecureContext.new(
      session_id: 102_u16, peer_session_id: 101_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16, 0x22_u8),
      decryption_key: Bytes.new(16, 0x11_u8),
      local_node_id: Matter::DataType::NodeId.new(0x222_u64),
      peer_node_id: Matter::DataType::NodeId.new(0x111_u64),
      case_session: true, fabric_index: 1_u8)
    controller.register_session(controller_session, peer: peer)
    routes = Channel(Socket::IPAddress).new(1)
    observer_id = transport.add_message_observer do |_msg, route|
      routes.send(route)
      true
    end
    # An unsecured packet exposes the server's connection token before
    # application traffic, just as CASE Sigma1 does in a real handshake.
    controller.send_unsecured_request(peer, 0_u16, 0_u8, Bytes.empty,
      requires_ack: false)
    device_peer = nil.as(Socket::IPAddress?)
    select
    when device_peer = routes.receive
    when timeout(2.seconds)
    end
    device_peer.should_not be_nil
    transport.remove_message_observer(observer_id)
    device_session.bind_tcp_peer(device_peer.as(Socket::IPAddress))
    handler.registry.synchronize do
      handler.sessions[device_session.session_id] = device_session
    end
    bdx = Matter::Controller::BdxClient.new(controller, 30.seconds)

    begin
      sink = IO::Memory.new
      bdx.download(controller_session, peer, "download".to_slice,
        sink, max_bytes: 2048_u64, block_size: 512_u16).should eq(contents.size.to_u64)
      sink.to_slice.should eq(contents)
      controller.transport.as(Matter::Transport::TcpEnabledTransport).pending_reliable_count.should eq(0)
      transport.pending_reliable_count.should eq(0)
    ensure
      handler.close
      controller.close
      transport.close
    end
  end
end
