require "../spec_helper"
require "../../src/matter/camera"

private alias Provider = Matter::Cluster::WebRtcTransportProvider
private alias CameraAv = Matter::Cluster::CameraAvStreamManagement
private alias RequestorClient = Matter::Controller::WebrtcRequestorClient
private alias Sink = Matter::Camera::RequestorSignalingSink

private class CameraSignalingImFake
  record Call, endpoint : UInt16, cluster : UInt32, command : UInt32, fields : Bytes
  getter calls = [] of Call
  property returned_status = Matter::InteractionModel::StatusCode::Success

  def invoke(_session : Matter::Session::SecureContext, _peer : Socket::IPAddress,
             endpoint_id : UInt16, cluster_id : UInt32, command_id : UInt32,
             fields : Bytes) : Matter::InteractionModel::InvokeResponseMessage
    @calls << Call.new(endpoint_id, cluster_id, command_id, fields.dup)
    path = Matter::InteractionModel::CommandPath.new(endpoint_id, cluster_id, command_id)
    status = Matter::InteractionModel::CommandStatusIB.new(path,
      Matter::InteractionModel::StatusIB.new(@returned_status.value))
    Matter::InteractionModel::InvokeResponseMessage.new(
      invoke_responses: [Matter::InteractionModel::InvokeResponseIB.new(command_status: status)])
  end
end

private class CameraSinkPeer < Provider::Peer
  def solicit_offer(session : Provider::Session, request : Provider::SolicitOfferRequest) : Matter::InteractionModel::Status
    Matter::InteractionModel::Status.success
  end

  def accept_offer(session : Provider::Session, request : Provider::ProvideOfferRequest) : Matter::InteractionModel::Status
    Matter::InteractionModel::Status.success
  end

  def accept_answer(session : Provider::Session, sdp : String) : Matter::InteractionModel::Status
    Matter::InteractionModel::Status.success
  end

  def add_ice_candidates(session : Provider::Session, candidates : Array(Provider::IceCandidate)) : Matter::InteractionModel::Status
    Matter::InteractionModel::Status.success
  end

  def end_session(session : Provider::Session, reason : Provider::EndReason) : Nil
  end
end

private def camera_sink_provider : Tuple(Provider, CameraAv)
  capabilities = CameraAv::AudioCapabilities.new(1_u8,
    [CameraAv::AudioCodec::Opus], [48_000_u32], [16_u8])
  camera = build(CameraAv,
    microphone_capabilities: capabilities,
    supported_stream_usages: [Provider::StreamUsage::LiveView],
    max_content_buffer_size: 65_536_u32, max_network_bandwidth: 128_000_u32)
  {Provider.new(camera.endpoint_id, camera, CameraSinkPeer.new), camera}
end

private def camera_signaling_session(peer_node_id : UInt64 = 0x1234_u64,
                                     fabric_index : UInt8 = 1_u8,
                                     case_session : Bool = true) : Matter::Session::SecureContext
  Matter::Session::SecureContext.new(
    session_id: 0x100_u16, peer_session_id: 0x101_u16,
    session_type: Matter::Session::SessionType::Unicast,
    encryption_key: Bytes.new(16, 0x11_u8),
    decryption_key: Bytes.new(16, 0x22_u8),
    peer_node_id: Matter::DataType::NodeId.new(peer_node_id),
    case_session: case_session, fabric_index: fabric_index)
end

private def camera_provider_session : Provider::Session
  Provider::Session.new(7_u16, 0x1234_u64, 2_u16,
    Provider::StreamUsage::LiveView, [1_u16], nil, 1_u8)
end

describe Matter::Camera::RequestorSignalingSink do
  it "sends Offer, Answer, ICE, and End to the authenticated Requestor endpoint" do
    im = CameraSignalingImFake.new
    destination = Sink::Destination.new(camera_signaling_session,
      Socket::IPAddress.new("127.0.0.1", 5540))
    sink = Sink.new(camera_sink_provider.first, RequestorClient.new(im),
      ->(_fabric : UInt8, _node : UInt64) : Sink::Destination? { destination })
    camera = camera_provider_session
    ice_server = Provider::IceServer.new(["stun:example.test"])
    candidate = Provider::IceCandidate.new("candidate:1", nil, nil)

    sink.offer(camera, "v=0 offer", [ice_server], "all")
    sink.answer(camera, "v=0 answer")
    sink.ice_candidates(camera, [candidate])
    sink.end_session(camera, Provider::EndReason::UserHangup)

    im.calls.map(&.command).should eq([0_u32, 1_u32, 2_u32, 3_u32])
    im.calls.all? { |call| call.endpoint == camera.peer_endpoint_id && call.cluster == 0x0554_u32 }.should be_true
    RequestorClient::OfferRequest.from_slice(im.calls[0].fields).session_id.should eq(camera.id)
    RequestorClient::IceCandidatesRequest.from_slice(im.calls[2].fields).ice_candidates.first.sdp_mid.should be_nil
  end

  it "rejects a resolver that supplies another fabric, peer, or session type" do
    im = CameraSignalingImFake.new
    camera = camera_provider_session
    [
      camera_signaling_session(fabric_index: 2_u8),
      camera_signaling_session(peer_node_id: 0x5678_u64),
      camera_signaling_session(case_session: false),
    ].each do |session|
      wrong = Sink::Destination.new(session, Socket::IPAddress.new("127.0.0.1", 5540))
      sink = Sink.new(camera_sink_provider.first, RequestorClient.new(im),
        ->(_fabric : UInt8, _node : UInt64) : Sink::Destination? { wrong })
      expect_raises(Matter::SessionError) { sink.offer(camera, "v=0 offer") }
    end
    im.calls.should be_empty
  end

  it "removes the exact Provider session when outbound Requestor signaling fails" do
    provider, camera = camera_sink_provider
    camera.on_audio_allocate { |_request, _id| Matter::InteractionModel::Status.success }
    stream = camera.audio_stream_allocate(
      CameraAv::AudioStreamAllocateRequest.new(
        Provider::StreamUsage::LiveView,
        CameraAv::AudioCodec::Opus,
        1_u8, 48_000_u32, 64_000_u32, 16_u8))
      .as(CameraAv::AudioStreamAllocateResponse)
    provider.request_peer_node_id = 0x1234_u64
    request = Provider::ProvideOfferRequest.new(nil, "v=0", Provider::StreamUsage::LiveView,
      2_u16, audio_streams: [stream.audio_stream_id])
    invoke(provider, Provider::CMD_PROVIDE_OFFER, request,
      is_case_session: true, fabric_index: 1_u8).should be_a(Matter::Cluster::CommandResponse)
    session = provider.current_sessions(1_u8).as(Array(Provider::Session)).first

    im = CameraSignalingImFake.new
    im.returned_status = Matter::InteractionModel::StatusCode::Failure
    destination = Sink::Destination.new(camera_signaling_session,
      Socket::IPAddress.new("127.0.0.1", 5540))
    sink = Sink.new(provider, RequestorClient.new(im),
      ->(_fabric : UInt8, _node : UInt64) : Sink::Destination? { destination })

    expect_raises(Matter::ClusterError) { sink.offer(session, "v=0 offer") }
    provider.current_sessions(1_u8).as(Array(Provider::Session)).should be_empty
  end
end
