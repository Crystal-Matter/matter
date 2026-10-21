require "../spec_helper"
require "../../src/matter/controller/im_client"
require "../../src/matter/cluster/on_off"
require "../../src/matter/protocol/message_handler"

private class TimedInteractionClient < Matter::Controller::Client
  record Sent, message_type : UInt8, exchange_id : UInt16, payload : Bytes

  getter sent = [] of Sent
  property timed_status : Matter::InteractionModel::StatusCode? = nil
  property? drop_timed_status : Bool = false
  property timed_status_delay : Time::Span = 0.seconds

  @message_counter = 1_u32

  def initialize(@handler : Matter::Protocol::MessageHandler,
                 @capture : Matter::Spec::CaptureTransport,
                 @device_session : Matter::Session::SecureContext,
                 @peer : Socket::IPAddress)
    super()
  end

  def send_encrypted_request(session : Matter::Session::SecureContext,
                             peer : Socket::IPAddress, protocol_id : UInt16,
                             message_type : UInt8, payload : Bytes | Slice(UInt8),
                             exchange_id : UInt16 = next_exchange_id,
                             initiator_message : Bool = true,
                             requires_ack : Bool = true,
                             acknowledged_message_id : UInt32? = nil) : UInt16
    @sent << Sent.new(message_type, exchange_id, payload.to_slice.dup)
    @handler.handle_message(Matter::Spec::ProtocolMessages.from_peer(
      @device_session, message_type, payload.to_slice, @message_counter, exchange_id,
      protocol_id: protocol_id, requires_acknowledge: requires_ack), peer)
    @message_counter &+= 1_u32
    exchange_id
  end

  def wait_for(exchange_id : UInt16, protocol_id : UInt16, message_type : UInt8,
               timeout : Time::Span) : ReceivedMessage?
    timed_status = message_type == Matter::InteractionModel::MessageType::StatusResponse.value
    return if timed_status && drop_timed_status?
    response = wait_for_any(exchange_id, protocol_id, [message_type], timeout)
    sleep @timed_status_delay if timed_status && response
    response
  end

  def wait_for_any(exchange_id : UInt16, protocol_id : UInt16,
                   message_types : Array(UInt8), timeout : Time::Span) : ReceivedMessage?
    if message_types.includes?(Matter::InteractionModel::MessageType::StatusResponse.value)
      if status = @timed_status
        packet = Matter::Codec::MessageCodec::PacketHeader.new(@device_session.session_id,
          Matter::Codec::MessageCodec::SessionType::Unicast, 1_u32)
        header = Matter::Codec::MessageCodec::PayloadHeader.new(exchange_id, protocol_id,
          Matter::InteractionModel::MessageType::StatusResponse.value, false, false)
        response = Matter::Codec::MessageCodec::Message.new(packet, header,
          Matter::InteractionModel::StatusResponseMessage.new(status.value).to_slice)
        return ReceivedMessage.new(response, @peer)
      end
    end

    while sent = @capture.sent_packets.shift?
      message = decode(sent[0])
      next unless message.payload_header.exchange_id == exchange_id
      next unless message.payload_header.protocol_id == protocol_id
      next unless message_types.includes?(message.payload_header.message_type)
      return ReceivedMessage.new(message, sent[1])
    end
    nil
  end

  private def decode(bytes : Bytes) : Matter::Codec::MessageCodec::Message
    packet = Matter::Codec::MessageCodec::Base.decode_packet(bytes)
    header_bytes = bytes[0, bytes.size - packet.payload.size]
    nonce = Matter::Session::SecureMessage.build_nonce(
      @device_session.local_node_id.as(Matter::DataType::NodeId).id,
      packet.header.message_id,
      header_bytes[Matter::Codec::MessageCodec::SECURITY_FLAGS_OFFSET])
    plaintext = Matter::Crypto::StandardCrypto.new.decrypt(
      @device_session.encryption_key, packet.payload, nonce, header_bytes)
    Matter::Codec::MessageCodec::Base.decode_payload(
      Matter::Codec::MessageCodec::Packet.new(packet.header, plaintext))
  end
end

private record TimedInteractionFixture,
  client : TimedInteractionClient,
  handler : Matter::Protocol::MessageHandler,
  session : Matter::Session::SecureContext,
  peer : Socket::IPAddress,
  basic : Matter::Cluster::BasicInformation,
  on_off : Matter::Cluster::OnOff

private def timed_interaction_fixture : TimedInteractionFixture
  capture = Matter::Spec::CaptureTransport.new_for_spec
  handler = Matter::Protocol::MessageHandler.new(capture, 20202021_u32, 3840_u16,
    Matter::FabricTable.new(Matter::Storage::Memory.new))
  endpoint = Matter::Endpoint.new(endpoint(1))
  on_off = build(Matter::Cluster::OnOff)
  endpoint.add_cluster(on_off)
  handler.node.add_endpoint(endpoint)
  basic = handler.node.get_cluster(Matter::Cluster::BasicInformation).as(Matter::Cluster::BasicInformation)
  session = Matter::Spec::ProtocolMessages.case_session(1_u16)
  handler.sessions[session.session_id] = session
  peer = Socket::IPAddress.new("127.0.0.1", 5540)
  client = TimedInteractionClient.new(handler, capture, session, peer)
  TimedInteractionFixture.new(client, handler, session, peer, basic, on_off)
end

describe Matter::Controller::ImClient do
  it "writes over the same timed exchange only after the device acknowledges TimedRequest" do
    fixture = timed_interaction_fixture
    im = Matter::Controller::ImClient.new(fixture.client)
    response = im.write_attribute(fixture.session, fixture.peer, 0_u16,
      Matter::Cluster::BasicInformation::CLUSTER_ID,
      Matter::Cluster::BasicInformation::ATTR_NODE_LABEL,
      "Timed label".to_tlv.to_slice, timed_request: true)

    response.write_responses.first.status.status.should eq(Matter::InteractionModel::StatusCode::Success.value)
    fixture.basic.node_label.should eq("Timed label")
    fixture.client.sent.map(&.message_type).should eq([
      Matter::InteractionModel::MessageType::TimedRequest.value,
      Matter::InteractionModel::MessageType::WriteRequest.value,
    ])
    fixture.client.sent[0].exchange_id.should eq(fixture.client.sent[1].exchange_id)
    timed = Matter::InteractionModel::TimedRequestMessage.from_slice(fixture.client.sent.first.payload)
    timed.timeout.should eq(10_000_u16)
  ensure
    fixture.try(&.client.close)
    fixture.try(&.handler.close)
  end

  it "invokes a command over the same timed exchange" do
    fixture = timed_interaction_fixture
    im = Matter::Controller::ImClient.new(fixture.client)
    im.invoke(fixture.session, fixture.peer, 1_u16,
      Matter::Cluster::OnOff::CLUSTER_ID, Matter::Cluster::OnOff::CMD_ON,
      timed_request: true, timed_request_timeout: 2.seconds)

    fixture.on_off.on_off?.should be_true
    fixture.client.sent.map(&.message_type).should eq([
      Matter::InteractionModel::MessageType::TimedRequest.value,
      Matter::InteractionModel::MessageType::InvokeRequest.value,
    ])
    fixture.client.sent[0].exchange_id.should eq(fixture.client.sent[1].exchange_id)
    Matter::InteractionModel::TimedRequestMessage.from_slice(fixture.client.sent.first.payload).timeout.should eq(2_000_u16)
  ensure
    fixture.try(&.client.close)
    fixture.try(&.handler.close)
  end

  it "does not send the write when the TimedRequest status is an error" do
    fixture = timed_interaction_fixture
    fixture.client.timed_status = Matter::InteractionModel::StatusCode::Busy
    im = Matter::Controller::ImClient.new(fixture.client)

    expect_raises(Matter::ProtocolError, /Busy/) do
      im.write_attribute(fixture.session, fixture.peer, 0_u16,
        Matter::Cluster::BasicInformation::CLUSTER_ID,
        Matter::Cluster::BasicInformation::ATTR_NODE_LABEL,
        "Rejected".to_tlv.to_slice, timed_request: true)
    end
    fixture.client.sent.map(&.message_type).should eq([Matter::InteractionModel::MessageType::TimedRequest.value])
    fixture.basic.node_label.should_not eq("Rejected")
  ensure
    fixture.try(&.client.close)
    fixture.try(&.handler.close)
  end

  it "does not send the invoke when the TimedRequest status times out" do
    fixture = timed_interaction_fixture
    fixture.client.drop_timed_status = true
    im = Matter::Controller::ImClient.new(fixture.client)

    expect_raises(Matter::TimeoutError, /TimedRequest/) do
      im.invoke(fixture.session, fixture.peer, 1_u16,
        Matter::Cluster::OnOff::CLUSTER_ID, Matter::Cluster::OnOff::CMD_ON,
        timed_request: true)
    end
    fixture.client.sent.map(&.message_type).should eq([Matter::InteractionModel::MessageType::TimedRequest.value])
    fixture.on_off.on_off?.should be_false
  ensure
    fixture.try(&.client.close)
    fixture.try(&.handler.close)
  end

  it "rejects a timed window outside the UInt16 millisecond wire range before sending" do
    fixture = timed_interaction_fixture
    im = Matter::Controller::ImClient.new(fixture.client)

    expect_raises(Matter::ConfigurationError, /TimedRequest window/) do
      im.invoke(fixture.session, fixture.peer, 1_u16,
        Matter::Cluster::OnOff::CLUSTER_ID, Matter::Cluster::OnOff::CMD_ON,
        timed_request: true, timed_request_timeout: 66.seconds)
    end
    fixture.client.sent.should be_empty
  ensure
    fixture.try(&.client.close)
    fixture.try(&.handler.close)
  end

  it "reports the device's expired timed write as a protocol timeout" do
    fixture = timed_interaction_fixture
    fixture.client.timed_status_delay = 10.milliseconds
    im = Matter::Controller::ImClient.new(fixture.client)

    expect_raises(Matter::TimeoutError, /timed WriteRequest expired/) do
      im.write_attribute(fixture.session, fixture.peer, 0_u16,
        Matter::Cluster::BasicInformation::CLUSTER_ID,
        Matter::Cluster::BasicInformation::ATTR_NODE_LABEL,
        "Too late".to_tlv.to_slice,
        timed_request: true, timed_request_timeout: 1.millisecond)
    end
    fixture.client.sent.map(&.message_type).should eq([
      Matter::InteractionModel::MessageType::TimedRequest.value,
      Matter::InteractionModel::MessageType::WriteRequest.value,
    ])
    fixture.basic.node_label.should_not eq("Too late")
  ensure
    fixture.try(&.client.close)
    fixture.try(&.handler.close)
  end
end
