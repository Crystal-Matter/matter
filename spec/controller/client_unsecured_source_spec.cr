require "../spec_helper"
require "../../src/matter/controller/client"
require "../../src/matter/controller/datastore_propagator"
require "../support/capture_transport"
require "../support/counter_store_fixture"

private class CaseCounterCapture < Matter::Spec::CaptureTransport
  def receive_for_spec(data : Bytes, peer : Socket::IPAddress) : Nil
    handle_received_data(data, peer)
  end
end

private def receive_case_reply(transport : CaseCounterCapture, peer : Socket::IPAddress,
                               exchange_id : UInt16, counter : UInt32,
                               message_type : Matter::Protocol::SecureChannelMessageType) : Nil
  header = Matter::Codec::MessageCodec::PacketHeader.new(
    session_id: Matter::Codec::MessageCodec::UNSECURED_SESSION_ID,
    session_type: Matter::Codec::MessageCodec::SessionType::Unicast,
    message_id: counter,
    source_node_id: Matter::DataType::NodeId.new(0x3333_u64),
    destination_node_id: Matter::DataType::NodeId.new(0x2222_u64))
  payload = Matter::Codec::MessageCodec::PayloadHeader.new(
    exchange_id: exchange_id,
    protocol_id: Matter::Protocol::ProtocolId::SecureChannel.value,
    message_type: message_type.value,
    initiator_message: false,
    requires_acknowledge: true)
  transport.receive_for_spec(Matter::Codec::MessageCodec::Base.encode_message(header, payload, Bytes.empty), peer)
end

describe Matter::Controller::Client do
  it "rejects a fixed-source lease from volatile storage" do
    store = Matter::Controller::StateStore.new(Matter::Storage::Memory.new)
    expect_raises(Matter::ConfigurationError, /requires durable storage/) do
      store.counter_lease(0x2222_u64)
    end
  end

  it "rejects an unleased fixed source and a source mismatch before opening a transport" do
    fixture = Matter::Spec::CounterStoreFixture.new
    store = fixture.store
    expect_raises(Matter::ConfigurationError, /requires a StateStore counter lease/) do
      Matter::Controller::Client.new(unsecured_source_node_id: 0x2222_u64)
    end
    expect_raises(Matter::ConfigurationError, /does not match/) do
      Matter::Controller::Client.new(unsecured_source_node_id: 0x3333_u64,
        counter_lease: store.counter_lease(0x2222_u64))
    end
  ensure
    fixture.try(&.close)
  end

  it "rejects a shared transport with a different counter owner" do
    transport = Matter::Spec::CaptureTransport.new_for_spec
    fixture = Matter::Spec::CounterStoreFixture.new
    store = fixture.store
    expect_raises(Matter::ConfigurationError, /same StateStore/) do
      Matter::Controller::Client.new(transport: transport,
        counter_lease: store.counter_lease(0x2222_u64))
    end
  ensure
    transport.try(&.close)
    fixture.try(&.close)
  end

  it "rejects a shared message counter leased by another StateStore" do
    first_fixture = Matter::Spec::CounterStoreFixture.new
    second_fixture = Matter::Spec::CounterStoreFixture.new
    outgoing = Matter::Transport::MessageCounter.new
    first_fixture.store.bind_transport_counter(outgoing)
    expect_raises(Matter::ConfigurationError, /same StateStore/) do
      Matter::Controller::Client.new(counter_lease: second_fixture.store.counter_lease(0x2222_u64),
        shared_message_counter: outgoing)
    end
  ensure
    second_fixture.try(&.close)
    first_fixture.try(&.close)
  end

  it "allows only one standalone Client for a fixed source until close" do
    fixture = Matter::Spec::CounterStoreFixture.new
    store = fixture.store
    source = 0x2222_u64
    first = Matter::Controller::Client.new(counter_lease: store.counter_lease(source))
    first_reserved = store.load.unsecured_message_counter
    expect_raises(Matter::ConfigurationError, /already owns/) do
      Matter::Controller::Client.new(counter_lease: store.counter_lease(source))
    end
    store.load.unsecured_message_counter.should eq(first_reserved)
    first.close
    second = Matter::Controller::Client.new(counter_lease: store.counter_lease(source))
    store.load.unsecured_message_counter.should be > first_reserved
  ensure
    second.try(&.close)
    first.try(&.close)
    fixture.try(&.close)
  end

  it "shares one durable counter across independent outbound transports and restart" do
    fixture = Matter::Spec::CounterStoreFixture.new
    store = fixture.store
    source = 0x2222_u64
    outgoing = Matter::Transport::MessageCounter.new
    store.bind_transport_counter(outgoing, 2_u32)
    first = Matter::Controller::Client.new(counter_lease: store.counter_lease(source),
      shared_message_counter: outgoing)
    second = Matter::Controller::Client.new(counter_lease: store.counter_lease(source),
      shared_message_counter: outgoing)
    first.transport.should_not eq(second.transport)
    first.transport.message_counter.should eq(second.transport.message_counter)
    peer = Socket::IPAddress.new("::1", 5533)
    protocol = Matter::Protocol::ProtocolId::SecureChannel.value
    message_type = Matter::Protocol::SecureChannelMessageType::CaseSigma1.value
    first.send_unsecured_request(peer, protocol, message_type, Bytes.empty, requires_ack: false)
    first_id = outgoing.counter
    second.send_unsecured_request(peer, protocol, message_type, Bytes.empty, requires_ack: false)
    second_id = outgoing.counter
    first.send_unsecured_request(peer, protocol, message_type, Bytes.empty, requires_ack: false)
    third_id = outgoing.counter
    [first_id, second_id, third_id].should eq([1_u32, 2_u32, 3_u32])
    store.load.unsecured_message_counter.should eq(4_u32)
    second.close
    first.close
    store.backend.close

    restarted = Matter::Controller::StateStore.new(Matter::Storage::YamlFile.new(fixture.path))
    resumed = Matter::Transport::MessageCounter.new
    restarted.bind_transport_counter(resumed, 2_u32)
    third = Matter::Controller::Client.new(counter_lease: restarted.counter_lease(source),
      shared_message_counter: resumed)
    third.send_unsecured_request(peer, protocol, message_type, Bytes.empty, requires_ack: false)
    resumed.counter.should eq(5_u32)
    restarted.load.unsecured_message_counter.should eq(6_u32)
  ensure
    third.try(&.close)
    restarted.try(&.backend.close)
    second.try(&.close)
    first.try(&.close)
    fixture.try(&.close)
  end

  it "reserves secure session IDs across sibling Clients on one transport" do
    transport = Matter::Spec::CaptureTransport.new_for_spec
    first = Matter::Controller::Client.new(transport: transport)
    second = Matter::Controller::Client.new(transport: transport)
    session_id = 7_u16
    first.allocate_session_id("CASE") { session_id }.should eq(session_id)
    second.session_id_available?(session_id).should be_false
    second.allocate_session_id("CASE") { session_id &+ 1_u16 }.should eq(8_u16)
    second.release_session_id_reservation(8_u16)
    session = Matter::Session::SecureContext.new(session_id, 8_u16,
      Matter::Session::SessionType::Unicast, Bytes.new(16), Bytes.new(16))
    first.register_session(session)
    second.session_id_available?(session_id).should be_false
    expect_raises(Matter::ProtocolError, /already in use/) do
      second.register_session(session)
    end
    first.close
    second.session_id_available?(session_id).should be_true
  ensure
    second.try(&.close)
    first.try(&.close)
    transport.try(&.close)
  end

  it "cannot send another fixed-source packet after a nonrenewable lease is spent" do
    fixture = Matter::Spec::CounterStoreFixture.new
    store = fixture.store
    client = Matter::Controller::Client.new(counter_lease: store.counter_lease(0x2222_u64,
      1_u32, renewable: false))
    peer = Socket::IPAddress.new("::1", 5533)
    protocol = Matter::Protocol::ProtocolId::SecureChannel.value
    message_type = Matter::Protocol::SecureChannelMessageType::CaseSigma1.value

    client.send_unsecured_request(peer, protocol, message_type, Bytes.empty, requires_ack: false)
    expect_raises(Matter::SessionError, /exhausted/) do
      client.send_unsecured_request(peer, protocol, message_type, Bytes.empty, requires_ack: false)
    end
    store.load.unsecured_message_counter.should eq(1_u32)
  ensure
    client.try(&.close)
    fixture.try(&.close)
  end

  it "accounts for CASE replies' automatic unsecured ACKs within a reserved range" do
    transport = CaseCounterCapture.new_for_spec
    fixture = Matter::Spec::CounterStoreFixture.new
    store = fixture.store
    state = store.load
    state.unsecured_message_counter = UInt32::MAX - 2_u32
    store.save(state)
    store.bind_transport_counter(transport.message_counter,
      Matter::Controller::DatastorePropagator::CASE_UNSECURED_MESSAGES_PER_CANDIDATE)
    client = Matter::Controller::Client.new(transport: transport,
      counter_lease: store.counter_lease(0x2222_u64))
    peer = Socket::IPAddress.new("127.0.0.1", 5540)
    protocol_id = Matter::Protocol::ProtocolId::SecureChannel.value
    sigma1 = Matter::Protocol::SecureChannelMessageType::CaseSigma1.value
    sigma3 = Matter::Protocol::SecureChannelMessageType::CaseSigma3.value

    exchange_id = client.send_unsecured_request(peer, protocol_id, sigma1, Bytes.empty)
    receive_case_reply(transport, peer, exchange_id, 1_u32,
      Matter::Protocol::SecureChannelMessageType::CaseSigma2)
    Matter::Transport::UDPTransport::MRP_MAX_RETRANSMISSIONS.times do
      receive_case_reply(transport, peer, exchange_id, 1_u32,
        Matter::Protocol::SecureChannelMessageType::CaseSigma2)
    end
    client.send_unsecured_on_exchange(peer, exchange_id, protocol_id, sigma3, Bytes.empty)
    receive_case_reply(transport, peer, exchange_id, 2_u32,
      Matter::Protocol::SecureChannelMessageType::StatusReport)
    Matter::Transport::UDPTransport::MRP_MAX_RETRANSMISSIONS.times do
      receive_case_reply(transport, peer, exchange_id, 2_u32,
        Matter::Protocol::SecureChannelMessageType::StatusReport)
    end

    sent_counters = transport.sent_packets.map { |packet| Matter::Codec::MessageCodec::Base.decode_packet(packet[0]).header.message_id }
    sent_counters.should eq([UInt32::MAX - 1_u32, UInt32::MAX] + (0_u32..9_u32).to_a)
    client.send_unsecured_on_exchange(peer, exchange_id, protocol_id, sigma3, Bytes.empty)
    transport.sent_packets.last[0].should_not be_empty
  ensure
    client.try(&.close)
    transport.try(&.close)
    fixture.try(&.close)
  end

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
    fixture = Matter::Spec::CounterStoreFixture.new
    store = fixture.store
    store.bind_transport_counter(transport.message_counter)
    client = Matter::Controller::Client.new(transport: transport,
      counter_lease: store.counter_lease(source_id))
    peer = Socket::IPAddress.new("::1", 5533)

    client.send_unsecured_request(peer, 0_u16, 0x20_u8, Bytes.empty, requires_ack: false)

    packet = Matter::Codec::MessageCodec::Base.decode_packet(transport.sent_packets.last[0])
    packet.header.source_node_id.as(Matter::DataType::NodeId).id.should eq(source_id)
    packet.header.destination_node_id.should be_nil
  ensure
    client.try(&.close)
    transport.try(&.close)
    fixture.try(&.close)
  end
end
