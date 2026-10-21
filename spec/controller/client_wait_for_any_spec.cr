require "../spec_helper"
require "../../src/matter/controller/client"

private class RoutedWaitClient < Matter::Controller::Client
  def inject(exchange_id : UInt16, message_type : UInt8) : Nil
    packet = Matter::Codec::MessageCodec::PacketHeader.new(0_u16,
      Matter::Codec::MessageCodec::SessionType::Unicast, exchange_id.to_u32)
    header = Matter::Codec::MessageCodec::PayloadHeader.new(exchange_id,
      PROTOCOL_INTERACTION_MODEL, message_type, false, false)
    @inbox.send(ReceivedMessage.new(
      Matter::Codec::MessageCodec::Message.new(packet, header, Bytes.empty),
      Socket::IPAddress.new("127.0.0.1", 5540)))
  end
end

describe Matter::Controller::Client do
  it "keeps another exchange's response while waiting for a timed response" do
    require_udp_sockets!
    client = RoutedWaitClient.new
    client.inject(2_u16, 0x05_u8)
    client.inject(1_u16, 0x01_u8)

    response = client.wait_for_any(1_u16, RoutedWaitClient::PROTOCOL_INTERACTION_MODEL,
      [0x07_u8, 0x01_u8], 1.second)
    response.try(&.message.payload_header.message_type).should eq(0x01_u8)
    other = client.wait_for(2_u16, RoutedWaitClient::PROTOCOL_INTERACTION_MODEL, 0x05_u8, 1.second)
    other.try(&.message.payload_header.exchange_id).should eq(2_u16)
  ensure
    client.try(&.close)
  end

  it "delivers crossed responses to simultaneous exchange waiters" do
    require_udp_sockets!
    client = RoutedWaitClient.new
    results = Channel(UInt16).new(2)
    spawn do
      received = client.wait_for(1_u16, RoutedWaitClient::PROTOCOL_INTERACTION_MODEL, 0x07_u8, 1.second)
      results.send(received.try(&.message.payload_header.exchange_id) || 0_u16)
    end
    spawn do
      received = client.wait_for(2_u16, RoutedWaitClient::PROTOCOL_INTERACTION_MODEL, 0x09_u8, 1.second)
      results.send(received.try(&.message.payload_header.exchange_id) || 0_u16)
    end
    client.inject(2_u16, 0x09_u8)
    client.inject(1_u16, 0x07_u8)

    [results.receive, results.receive].sort.should eq([1_u16, 2_u16])
  ensure
    client.try(&.close)
  end
end
