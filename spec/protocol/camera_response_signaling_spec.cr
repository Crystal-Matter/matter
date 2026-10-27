require "../spec_helper"
require "../../src/matter/protocol/message_handler"
require "../../src/matter/camera"

private alias CameraAv = Matter::Cluster::CameraAvStreamManagement
private alias Provider = Matter::Cluster::WebRtcTransportProvider
private alias Requestor = Matter::Controller::WebrtcRequestorClient
private alias Sink = Matter::Camera::RequestorSignalingSink
private CAMERA_PEER = Socket::IPAddress.new("127.0.0.1", 5540)

private class CameraResponseTransport < Matter::Spec::CaptureTransport
  property fail_on_send : Int32? = nil

  protected def transmit(data : Bytes | Slice(UInt8), peer_address : Socket::IPAddress) : Nil
    if @fail_on_send == sent_packets.size + 1
      @fail_on_send = nil
      raise IO::Error.new("synthetic Camera response send failure")
    end
    super
  end
end

private class CameraOutboundIm
  getter commands = [] of UInt32
  getter notifications = Channel(UInt32).new(64)

  def invoke(_session : Matter::Session::SecureContext, _peer : Socket::IPAddress,
             endpoint_id : UInt16, cluster_id : UInt32, command_id : UInt32,
             _fields : Bytes) : Matter::InteractionModel::InvokeResponseMessage
    @commands << command_id
    @notifications.send(command_id)
    path = Matter::InteractionModel::CommandPath.new(endpoint_id, cluster_id, command_id)
    status = Matter::InteractionModel::CommandStatusIB.new(path,
      Matter::InteractionModel::StatusIB.new(Matter::InteractionModel::StatusCode::Success.value))
    Matter::InteractionModel::InvokeResponseMessage.new(
      invoke_responses: [Matter::InteractionModel::InvokeResponseIB.new(command_status: status)])
  end
end

private alias CameraSink = Sink(CameraOutboundIm)

private class CameraDeferredPeer < Provider::Peer
  property provider : Provider? = nil
  property sink : CameraSink? = nil

  def solicit_offer(session : Provider::Session, request : Provider::SolicitOfferRequest) : Matter::InteractionModel::Status
    provider = @provider || return Matter::InteractionModel::Status.invalid_in_state
    sink = @sink || return Matter::InteractionModel::Status.invalid_in_state
    return Matter::InteractionModel::Status.invalid_in_state unless provider.defer_signaling(session) { sink.offer(session, "v=0 offer") }
    Matter::InteractionModel::Status.success
  end

  def accept_offer(session : Provider::Session, request : Provider::ProvideOfferRequest) : Matter::InteractionModel::Status
    provider = @provider || return Matter::InteractionModel::Status.invalid_in_state
    sink = @sink || return Matter::InteractionModel::Status.invalid_in_state
    return Matter::InteractionModel::Status.invalid_in_state unless provider.defer_signaling(session) { sink.answer(session, "v=0 answer") }
    Matter::InteractionModel::Status.success
  end

  def accept_answer(session : Provider::Session, sdp : String) : Matter::InteractionModel::Status
    provider = @provider || return Matter::InteractionModel::Status.invalid_in_state
    sink = @sink || return Matter::InteractionModel::Status.invalid_in_state
    return Matter::InteractionModel::Status.invalid_in_state unless provider.defer_signaling(session) do
                                                                      sink.ice_candidates(session, [Provider::IceCandidate.new("candidate:1", nil, nil)])
                                                                    end
    Matter::InteractionModel::Status.success
  end

  def add_ice_candidates(session : Provider::Session, candidates : Array(Provider::IceCandidate)) : Matter::InteractionModel::Status
    Matter::InteractionModel::Status.success
  end

  def end_session(session : Provider::Session, reason : Provider::EndReason) : Nil
  end
end

private def camera_response_fixture
  transport = CameraResponseTransport.new_for_spec
  handler = Matter::Protocol::MessageHandler.new(transport,
    setup_pin: 20202021_u32, discriminator: 3840_u16,
    fabric_table: Matter::FabricTable.new(Matter::Storage::Memory.new))
  handler.clusters.delete({0_u16, Matter::Cluster::AccessControl::CLUSTER_ID})
  session = Matter::Spec::ProtocolMessages.case_session(341_u16)
  handler.sessions[session.session_id] = session
  endpoint = Matter::DataType::EndpointNumber.new(1_u16)
  av = CameraAv.new(endpoint,
    microphone_capabilities: CameraAv::AudioCapabilities.new(1_u8,
      [CameraAv::AudioCodec::Opus], [48_000_u32], [16_u8]),
    supported_stream_usages: [CameraAv::StreamUsage::LiveView],
    max_content_buffer_size: 65_536_u32, max_network_bandwidth: 128_000_u32,
    feature_map: CameraAv::Feature::Audio)
  av.on_audio_allocate { |_request, _id| Matter::InteractionModel::Status.success }
  av.on_audio_deallocate { |_id| Matter::InteractionModel::Status.success }
  audio = av.audio_stream_allocate(CameraAv::AudioStreamAllocateRequest.new(
    CameraAv::StreamUsage::LiveView, CameraAv::AudioCodec::Opus,
    1_u8, 48_000_u32, 64_000_u32, 16_u8)).as(CameraAv::AudioStreamAllocateResponse)
  peer = CameraDeferredPeer.new
  provider = Provider.new(endpoint, av, peer)
  peer.provider = provider
  outbound = CameraOutboundIm.new
  destination = CameraSink::Destination.new(session, CAMERA_PEER)
  peer.sink = Sink.new(provider, Requestor.new(outbound),
    ->(_fabric : UInt8, _node : UInt64) : CameraSink::Destination? { destination })
  handler.clusters[{1_u16, Provider::CLUSTER_ID}] = provider
  {handler, transport, session, provider, peer, outbound, audio.audio_stream_id}
end

private def camera_invoke(handler : Matter::Protocol::MessageHandler,
                          session : Matter::Session::SecureContext,
                          commands : Array(Matter::InteractionModel::CommandDataIBTlv),
                          counter : UInt32, exchange : UInt16) : Nil
  request = Matter::InteractionModel::InvokeRequestMessage.new(commands)
  encrypted = Matter::Spec::ProtocolMessages.from_peer(session,
    Matter::InteractionModel::MessageType::InvokeRequest.value,
    request.to_slice, counter, exchange)
  handler.handle_message(encrypted, CAMERA_PEER)
end

private def camera_command(command : UInt32, fields : TLV::Serializable) : Matter::InteractionModel::CommandDataIBTlv
  path = Matter::InteractionModel::CommandPath.new(1_u16, Provider::CLUSTER_ID, command)
  Matter::InteractionModel::CommandDataIBTlv.new(path, TLV::Any.from_slice(fields.to_slice))
end

private def camera_response(packet : Bytes,
                            session : Matter::Session::SecureContext) : Matter::InteractionModel::InvokeResponseMessage
  decoded = Matter::Codec::MessageCodec::Base.decode_packet(packet)
  header_bytes = packet[0, packet.size - decoded.payload.size]
  nonce = Matter::Session::SecureMessage.build_nonce(
    session.local_node_id.as(Matter::DataType::NodeId).id,
    decoded.header.message_id,
    header_bytes[Matter::Codec::MessageCodec::SECURITY_FLAGS_OFFSET])
  plaintext = Matter::Crypto::StandardCrypto.new.decrypt(
    session.encryption_key, decoded.payload, nonce, header_bytes)
  payload = Matter::Codec::MessageCodec::Base.decode_payload(
    Matter::Codec::MessageCodec::Packet.new(decoded.header, plaintext)).payload
  Matter::InteractionModel::InvokeResponseMessage.from_slice(payload)
end

private def camera_expect_command(outbound : CameraOutboundIm, command : UInt32) : Nil
  select
  when actual = outbound.notifications.receive
    actual.should eq(command)
  when timeout(1.second)
    fail "Camera Requestor command #{command} was not dispatched"
  end
end

private def camera_expect_no_command(outbound : CameraOutboundIm) : Nil
  select
  when command = outbound.notifications.receive
    fail "Camera Requestor command #{command} was dispatched before the response completed"
  when timeout(20.milliseconds)
  end
end

describe "Camera signaling response handoff" do
  it "sends outbound Answer only after the encrypted Provider response and drops it on send failure" do
    handler, transport, session, provider, _peer, outbound, audio_id = camera_response_fixture
    request = Provider::ProvideOfferRequest.new(nil, "v=0", CameraAv::StreamUsage::LiveView,
      2_u16, audio_streams: [audio_id])
    transport.fail_on_send = 1
    camera_invoke(handler, session, [camera_command(Provider::CMD_PROVIDE_OFFER, request)], 1_u32, 55_u16)
    camera_expect_no_command(outbound)
    provider.take_pending_signaling(session.object_id.to_u64, 55_u16).should be_empty
    handler.close
  end

  it "dispatches Offer, Answer, and ICE only after their encrypted Provider responses" do
    handler, transport, session, provider, _peer, outbound, audio_id = camera_response_fixture
    solicitation = Provider::SolicitOfferRequest.new(CameraAv::StreamUsage::LiveView,
      2_u16, audio_streams: [audio_id])
    camera_invoke(handler, session, [camera_command(Provider::CMD_SOLICIT_OFFER, solicitation)], 1_u32, 56_u16)
    transport.sent_packets.size.should eq(1)
    camera_expect_command(outbound, Requestor::CMD_OFFER)
    provider_session = provider.current_sessions(1_u8).as(Array(Provider::Session)).first

    offer = Provider::ProvideOfferRequest.new(provider_session.id, "v=0")
    camera_invoke(handler, session, [camera_command(Provider::CMD_PROVIDE_OFFER, offer)], 2_u32, 57_u16)
    transport.sent_packets.size.should eq(2)
    camera_expect_command(outbound, Requestor::CMD_ANSWER)

    answer = Provider::ProvideAnswerRequest.new(provider_session.id, "v=0")
    camera_invoke(handler, session, [camera_command(Provider::CMD_PROVIDE_ANSWER, answer)], 3_u32, 58_u16)
    transport.sent_packets.size.should eq(3)
    camera_expect_command(outbound, Requestor::CMD_ICE_CANDIDATES)
    handler.close
  end

  it "does not dispatch after the Provider session or fabric is removed" do
    handler, _transport, session, provider, _peer, outbound, audio_id = camera_response_fixture
    solicitation = Provider::SolicitOfferRequest.new(CameraAv::StreamUsage::LiveView,
      2_u16, audio_streams: [audio_id])
    camera_invoke(handler, session, [camera_command(Provider::CMD_SOLICIT_OFFER, solicitation)], 1_u32, 59_u16)
    camera_expect_command(outbound, Requestor::CMD_OFFER)
    provider_session = provider.current_sessions(1_u8).as(Array(Provider::Session)).first
    provider.remove_fabric(1_u8)
    provider.current_sessions(1_u8).as(Array(Provider::Session)).should be_empty
    provider.take_pending_signaling(session.object_id.to_u64, 59_u16).should be_empty
    provider.defer_signaling(provider_session) { fail "removed session dispatched" }.should be_false
    handler.close
  end

  it "holds every outbound Answer until the final encrypted InvokeResponse chunk" do
    handler, transport, session, provider, _peer, outbound, audio_id = camera_response_fixture
    offer = Provider::ProvideOfferRequest.new(nil, "v=0", CameraAv::StreamUsage::LiveView,
      2_u16, audio_streams: [audio_id])
    camera_invoke(handler, session, [camera_command(Provider::CMD_PROVIDE_OFFER, offer)], 1_u32, 54_u16)
    camera_expect_command(outbound, Requestor::CMD_ANSWER)
    id = provider.current_sessions(1_u8).as(Array(Provider::Session)).first.id
    answer = Provider::ProvideAnswerRequest.new(id, "v=0")
    commands = Array.new(80) { camera_command(Provider::CMD_PROVIDE_ANSWER, answer) }
    camera_invoke(handler, session, commands, 2_u32, 60_u16)
    first = camera_response(transport.sent_packets.last[0], session)
    first.more_chunked_messages.should be_true
    camera_expect_no_command(outbound)

    counter = 3_u32
    while camera_response(transport.sent_packets.last[0], session).more_chunked_messages == true
      handler.handle_message(Matter::Spec::ProtocolMessages.status_response(session, counter, 60_u16), CAMERA_PEER)
      counter += 1_u32
      counter.should be <= 10_u32
    end
    80.times { camera_expect_command(outbound, Requestor::CMD_ICE_CANDIDATES) }
    handler.close
  end

  it "discards every queued Answer when a later encrypted InvokeResponse chunk fails" do
    handler, transport, session, provider, _peer, outbound, audio_id = camera_response_fixture
    offer = Provider::ProvideOfferRequest.new(nil, "v=0", CameraAv::StreamUsage::LiveView,
      2_u16, audio_streams: [audio_id])
    camera_invoke(handler, session, [camera_command(Provider::CMD_PROVIDE_OFFER, offer)], 1_u32, 54_u16)
    camera_expect_command(outbound, Requestor::CMD_ANSWER)
    id = provider.current_sessions(1_u8).as(Array(Provider::Session)).first.id
    answer = Provider::ProvideAnswerRequest.new(id, "v=0")
    commands = Array.new(80) { camera_command(Provider::CMD_PROVIDE_ANSWER, answer) }
    camera_invoke(handler, session, commands, 2_u32, 61_u16)
    camera_response(transport.sent_packets.last[0], session).more_chunked_messages.should be_true
    transport.fail_on_send = transport.sent_packets.size + 1
    handler.handle_message(Matter::Spec::ProtocolMessages.status_response(session, 3_u32, 61_u16), CAMERA_PEER)
    camera_expect_no_command(outbound)
    provider.take_pending_signaling(session.object_id.to_u64, 61_u16).should be_empty
    handler.close
  end

  it "discards queued signaling when a chunk is rejected or its fabric is removed" do
    handler, transport, session, provider, _peer, outbound, audio_id = camera_response_fixture
    offer = Provider::ProvideOfferRequest.new(nil, "v=0", CameraAv::StreamUsage::LiveView,
      2_u16, audio_streams: [audio_id])
    camera_invoke(handler, session, [camera_command(Provider::CMD_PROVIDE_OFFER, offer)], 1_u32, 54_u16)
    camera_expect_command(outbound, Requestor::CMD_ANSWER)
    id = provider.current_sessions(1_u8).as(Array(Provider::Session)).first.id
    answer = Provider::ProvideAnswerRequest.new(id, "v=0")
    commands = Array.new(80) { camera_command(Provider::CMD_PROVIDE_ANSWER, answer) }

    camera_invoke(handler, session, commands, 2_u32, 62_u16)
    camera_response(transport.sent_packets.last[0], session).more_chunked_messages.should be_true
    handler.handle_message(Matter::Spec::ProtocolMessages.status_response(session, 3_u32, 62_u16,
      Matter::InteractionModel::StatusCode::Failure.value), CAMERA_PEER)
    camera_expect_no_command(outbound)
    provider.take_pending_signaling(session.object_id.to_u64, 62_u16).should be_empty

    camera_invoke(handler, session, commands, 4_u32, 63_u16)
    camera_response(transport.sent_packets.last[0], session).more_chunked_messages.should be_true
    provider.remove_fabric(1_u8)
    handler.handle_message(Matter::Spec::ProtocolMessages.status_response(session, 5_u32, 63_u16), CAMERA_PEER)
    camera_expect_no_command(outbound)
    handler.close
  end

  it "does not send Requestor signaling through a different CASE fabric" do
    handler, _transport, session, provider, peer, outbound, audio_id = camera_response_fixture
    wrong = Matter::Session::SecureContext.new(
      session_id: 342_u16, peer_session_id: 343_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16, 0x11_u8), decryption_key: Bytes.new(16, 0x22_u8),
      peer_node_id: Matter::DataType::NodeId.new(0x2222_u64),
      case_session: true, fabric_index: 2_u8)
    destination = CameraSink::Destination.new(wrong, CAMERA_PEER)
    peer.sink = Sink.new(provider, Requestor.new(outbound),
      ->(_fabric : UInt8, _node : UInt64) : CameraSink::Destination? { destination })
    offer = Provider::ProvideOfferRequest.new(nil, "v=0", CameraAv::StreamUsage::LiveView,
      2_u16, audio_streams: [audio_id])
    camera_invoke(handler, session, [camera_command(Provider::CMD_PROVIDE_OFFER, offer)], 1_u32, 64_u16)
    camera_expect_no_command(outbound)
    provider.current_sessions(1_u8).as(Array(Provider::Session)).should be_empty
    handler.close
  end
end
