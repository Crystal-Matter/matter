require "../spec_helper"
require "../../src/matter/controller"
require "../../src/matter/protocol/message_handler"
require "../../src/matter/transport/btp_message_transport"

private class InMemoryGattFragmentChannel < Matter::Transport::GattFragmentChannel
  getter written_frames = [] of Bytes
  property other : InMemoryGattFragmentChannel?
  @incoming = Channel(Bytes).new(256)

  def write(frame : Bytes) : Nil
    @written_frames << frame.dup
    other = @other || raise Matter::TransportError.new("GATT channel is not connected")
    other.deliver(frame.dup)
  end

  def read(timeout_span : Time::Span) : Bytes?
    select
    when frame = @incoming.receive
      frame
    when timeout(timeout_span)
      nil
    end
  rescue Channel::ClosedError
    nil
  end

  def close : Nil
    @incoming.close unless @incoming.closed?
  end

  def closed? : Bool
    @incoming.closed?
  end

  protected def deliver(frame : Bytes) : Nil
    @incoming.send(frame)
  end
end

describe "Matter BLE packet channel" do
  it "carries controller PASE and an encrypted IM read over fragmented in-memory GATT" do
    central_link = InMemoryGattFragmentChannel.new
    peripheral_link = InMemoryGattFragmentChannel.new
    central_link.other = peripheral_link
    peripheral_link.other = central_link

    peer = Matter::Transport::BtpMessageTransport::PEER
    central = Matter::Transport::BtpMessageTransport.new(central_link,
      Matter::Transport::BtpSession::Role::Central, 20, 6)
    peripheral = Matter::Transport::BtpMessageTransport.new(peripheral_link,
      Matter::Transport::BtpSession::Role::Peripheral, 20, 6)
    table = Matter::FabricTable.new(Matter::Storage::Memory.new)
    handler = Matter::Protocol::MessageHandler.new(peripheral, 20202021_u32,
      3840_u16, table, iterations: 1000_u32, salt: Bytes.new(32, 0x01_u8))
    peripheral.start
    central.start
    client = Matter::Controller::Client.new(transport: central)

    session = Matter::Controller::Pairing::PasePairing.new.pair(client, peer, 20202021_u32)
    client.register_session(session)
    report = Matter::Controller::ImClient.new(client).read_attribute(session, peer,
      0_u16, Matter::Cluster::BasicInformation::CLUSTER_ID,
      Matter::Cluster::BasicInformation::ATTR_VENDOR_NAME)
    report.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data.should_not be_nil
    central_link.written_frames.size.should be > 4
    peripheral_link.written_frames.size.should be > 4

    # A receive fiber may dispatch its final packet while the handler closes.
    handler.close
    late_message = Matter::Codec::MessageCodec::Message.new(
      Matter::Codec::MessageCodec::PacketHeader.new(
        session_id: 0_u16,
        session_type: Matter::Codec::MessageCodec::SessionType::Unicast,
        message_id: 1_u32),
      Matter::Codec::MessageCodec::PayloadHeader.new(
        exchange_id: 1_u16, protocol_id: 0_u16, message_type: 0_u8,
        initiator_message: true, requires_acknowledge: false),
      Bytes.empty)
    peripheral.on_message.should_not be_nil
    peripheral.on_message.try(&.call(late_message, peer))
  ensure
    client.try(&.close)
    handler.try(&.close)
    central.try(&.close)
    peripheral.try(&.close)
  end
end
