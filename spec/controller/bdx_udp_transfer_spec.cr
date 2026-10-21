require "../spec_helper"
require "../../src/matter/controller/bdx_client"
require "../../src/matter/protocol/message_handler"

private alias BdxUdp = Matter::Protocol::Bdx
private BDX_UDP_TEST_TIMEOUT = 30.seconds

describe "BDX over encrypted UDP" do
  it "streams in both directions through real CASE packet encryption and MRP" do
    require_udp_sockets!
    transport = Matter::Transport::UDPTransport.new(port: 0)
    handler = Matter::Protocol::MessageHandler.new(transport,
      setup_pin: 20202021_u32, discriminator: 3840_u16,
      fabric_table: Matter::FabricTable.new(Matter::Storage::Memory.new))
    device_session = Matter::Session::SecureContext.new(
      session_id: 101_u16, peer_session_id: 102_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16, 0x11_u8),
      decryption_key: Bytes.new(16, 0x22_u8),
      local_node_id: Matter::DataType::NodeId.new(0x111_u64),
      peer_node_id: Matter::DataType::NodeId.new(0x222_u64),
      case_session: true, fabric_index: 1_u8)
    handler.sessions[device_session.session_id] = device_session

    contents = Bytes.new(3073) { |index| (index % 251).to_u8 }
    upload_sink = IO::Memory.new
    handler.bdx.on_download = ->(_session : Matter::Session::SecureContext, init : BdxUdp::Wire::Init) do
      init.file_designator == "download".to_slice ? BdxUdp::Responder::Source.new(IO::Memory.new(contents), contents.size.to_u64).as(BdxUdp::Responder::Source?) : nil
    end
    handler.bdx.on_upload = ->(_session : Matter::Session::SecureContext, init : BdxUdp::Wire::Init) do
      init.file_designator == "upload".to_slice ? upload_sink.as(IO) : nil
    end
    transport.start

    controller = Matter::Controller::Client.new(port: 0)
    controller_session = Matter::Session::SecureContext.new(
      session_id: 102_u16, peer_session_id: 101_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16, 0x22_u8),
      decryption_key: Bytes.new(16, 0x11_u8),
      local_node_id: Matter::DataType::NodeId.new(0x222_u64),
      peer_node_id: Matter::DataType::NodeId.new(0x111_u64),
      case_session: true, fabric_index: 1_u8)
    controller.register_session(controller_session)
    peer = Socket::IPAddress.new("127.0.0.1", transport.port)
    # Live UDP handshakes can be delayed by other spec fibers on loaded CI
    # hosts. Keep a test bound while allowing more than five seconds for Accept.
    bdx = Matter::Controller::BdxClient.new(controller, BDX_UDP_TEST_TIMEOUT)

    begin
      download_sink = IO::Memory.new
      bdx.download(controller_session, peer, "download".to_slice,
        download_sink, max_bytes: 4096_u64, block_size: 512_u16).should eq(contents.size.to_u64)
      download_sink.to_slice.should eq(contents)

      bdx.upload(controller_session, peer, "upload".to_slice,
        IO::Memory.new(contents), contents.size.to_u64,
        block_size: 512_u16).should eq(contents.size.to_u64)
      upload_sink.to_slice.should eq(contents)
      handler.bdx.active_count.should eq(0)
    ensure
      controller.close
      handler.close
      transport.close
    end
  end
end
