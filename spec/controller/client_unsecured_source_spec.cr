require "../spec_helper"
require "../../src/matter/controller/client"
require "../support/capture_transport"

describe Matter::Controller::Client do
  it "sends a default ephemeral source Node ID on unsecured requests" do
    transport = Matter::Spec::CaptureTransport.new_for_spec
    client = Matter::Controller::Client.new(transport: transport)
    peer = Socket::IPAddress.new("::1", 5533)

    client.send_unsecured_request(peer, 0_u16, 0x20_u8, Bytes.empty, requires_ack: false)

    packet = Matter::Codec::MessageCodec::Base.decode_packet(transport.sent_packets.last[0])
    source = packet.header.source_node_id.as(Matter::DataType::NodeId).id
    source.should be >= Matter::DataType::NodeId::OPERATIONAL_MINIMUM
    source.should be <= Matter::DataType::NodeId::OPERATIONAL_MAXIMUM
    packet.header.destination_node_id.should be_nil
  ensure
    client.try(&.close)
    transport.try(&.close)
  end

  it "preserves an explicit unsecured source Node ID" do
    transport = Matter::Spec::CaptureTransport.new_for_spec
    source_id = 0xA101_u64
    client = Matter::Controller::Client.new(transport: transport, unsecured_source_node_id: source_id)
    peer = Socket::IPAddress.new("::1", 5533)

    client.send_unsecured_request(peer, 0_u16, 0x20_u8, Bytes.empty, requires_ack: false)

    packet = Matter::Codec::MessageCodec::Base.decode_packet(transport.sent_packets.last[0])
    packet.header.source_node_id.as(Matter::DataType::NodeId).id.should eq(source_id)
    packet.header.destination_node_id.should be_nil
  ensure
    client.try(&.close)
    transport.try(&.close)
  end
end
