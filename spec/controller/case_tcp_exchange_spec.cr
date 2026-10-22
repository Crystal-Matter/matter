require "../spec_helper"
require "../../src/matter/controller/pairing/case_pairing"
require "../../src/matter/controller/im_client"
require "../../src/matter/protocol/message_handler"
require "../../src/matter/transport/tcp_enabled_transport"

describe "controller and device CASE over Matter TCP" do
  it "authenticates on one TCP connection and reads an attribute without MRP" do
    require_udp_sockets!
    crypto = Matter::Crypto::StandardCrypto.new
    authority = TestCertificateAuthority.new
    fabric_id = 0x1234_u64
    device_node = 0x4321_u64
    controller_node = 0x2222_u64
    ipk = Bytes.new(16, 0x44_u8)
    device_key = crypto.create_key_pair
    controller_key = crypto.create_key_pair
    root_cert = authority.root_certificate
    device_noc = authority.issue(fabric_id, device_node, device_key.public_key)
    controller_noc = authority.issue(fabric_id, controller_node, controller_key.public_key)
    device_fabric = Matter::Fabric.new(fabric_id, 1_u8, device_node,
      authority.root_public_key, device_noc, device_key, ipk, root_cert: root_cert)
    controller_fabric = Matter::Controller::FabricInfo.new(fabric_id, controller_node,
      ipk, root_cert, authority.root_public_key, controller_noc,
      controller_key.private_key)
    table = Matter::FabricTable.new(Matter::Storage::Memory.new)
    table.add_fabric(device_fabric).should be_true

    device_transport = Matter::Transport::TcpEnabledTransport.new(port: 0)
    handler = Matter::Protocol::MessageHandler.new(device_transport,
      setup_pin: 20202021_u32, discriminator: 3840_u16,
      fabric_table: table)
    device_transport.start
    controller = Matter::Controller::Client.new(tcp_enabled: true)
    begin
      peer = controller.connect_tcp(Socket::IPAddress.new("::1", device_transport.port))
      session = Matter::Controller::Pairing::CasePairing.new.pair(
        controller, peer, controller_fabric, device_node)
      session.tcp_session?.should be_true
      session.accepts_peer?(peer).should be_true
      device_session = handler.sessions[session.peer_session_id]
      device_session.tcp_session?.should be_true
      device_session.tcp_peer.should_not be_nil

      report = Matter::Controller::ImClient.new(controller).read_attribute(session, peer,
        0_u16, Matter::Cluster::BasicInformation::CLUSTER_ID,
        Matter::Cluster::BasicInformation::ATTR_VENDOR_NAME)
      report.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
        .first.attribute_data.should_not be_nil
      controller.transport.as(Matter::Transport::TcpEnabledTransport).pending_reliable_count.should eq(0)
      device_transport.pending_reliable_count.should eq(0)

      expect_raises(Matter::TransportError) do
        controller.send_encrypted_request(session,
          Socket::IPAddress.new("::1", device_transport.port), 0x0001_u16,
          0x02_u8, Bytes.empty)
      end
      other_connection = controller.connect_tcp(Socket::IPAddress.new("::1", device_transport.port))
      expect_raises(Matter::TransportError) do
        controller.send_encrypted_request(session, other_connection, 0x0001_u16,
          0x02_u8, Bytes.empty)
      end

      # Closing one connection must release its CASE session on both peers;
      # otherwise repeated reconnects consume the device registry's slots.
      controller.transport.as(Matter::Transport::TcpEnabledTransport).disconnect_tcp(peer)
      deadline = Time.instant + 2.seconds
      while (controller.session?(session.session_id) || handler.sessions.has_key?(session.peer_session_id)) && Time.instant < deadline
        sleep 10.milliseconds
      end
      controller.session?(session.session_id).should be_nil
      handler.sessions.has_key?(session.peer_session_id).should be_false
    ensure
      handler.close
      controller.close
      device_transport.close
    end
  end
end
