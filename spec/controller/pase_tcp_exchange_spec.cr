require "../spec_helper"
require "../../src/matter/controller/pairing/pase_pairing"
require "../../src/matter/controller/im_client"
require "../../src/matter/protocol/message_handler"
require "../../src/matter/transport/tcp_enabled_transport"

describe "controller and device PASE over Matter TCP" do
  it "commissions a TCP-bound secure session through the existing handler" do
    require_udp_sockets!
    transport = Matter::Transport::TcpEnabledTransport.new(port: 0)
    handler = Matter::Protocol::MessageHandler.new(transport,
      setup_pin: 20202021_u32, discriminator: 3840_u16,
      fabric_table: Matter::FabricTable.new(Matter::Storage::Memory.new),
      iterations: 1000_u32, salt: Bytes.new(32, 0x01_u8))
    transport.start
    client = Matter::Controller::Client.new(tcp_enabled: true)
    begin
      peer = client.connect_tcp(Socket::IPAddress.new("::1", transport.port))
      session = Matter::Controller::Pairing::PasePairing.new.pair(client, peer, 20202021_u32)
      client.register_session(session, peer: peer)
      session.tcp_session?.should be_true
      handler.sessions[session.peer_session_id].tcp_session?.should be_true

      report = Matter::Controller::ImClient.new(client).read_attribute(session, peer,
        0_u16, Matter::Cluster::BasicInformation::CLUSTER_ID,
        Matter::Cluster::BasicInformation::ATTR_VENDOR_NAME)
      report.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
        .first.attribute_data.should_not be_nil
    ensure
      handler.close
      client.close
      transport.close
    end
  end
end
