require "../spec_helper"

private alias CameraAv = Matter::Cluster::CameraAvStreamManagement
private alias Provider = Matter::Cluster::WebRtcTransportProvider
private alias Status = Matter::InteractionModel::Status
private alias StatusCode = Matter::InteractionModel::StatusCode

private class TestWebRtcPeer < Provider::Peer
  property? reject_offer : Bool = false
  getter solicitations = [] of UInt16
  getter offers = [] of String
  getter answers = [] of String
  getter candidates = [] of Provider::IceCandidate
  getter endings = [] of Provider::EndReason

  def solicit_offer(session : Provider::Session, request : Provider::SolicitOfferRequest) : Status
    @solicitations << session.id
    Status.success
  end

  def accept_offer(session : Provider::Session, request : Provider::ProvideOfferRequest) : Status
    return Status.invalid_in_state if @reject_offer
    @offers << request.sdp
    Status.success
  end

  def accept_answer(session : Provider::Session, sdp : String) : Status
    @answers << sdp
    Status.success
  end

  def add_ice_candidates(session : Provider::Session, candidates : Array(Provider::IceCandidate)) : Status
    @candidates.concat(candidates)
    Status.success
  end

  def end_session(session : Provider::Session, reason : Provider::EndReason) : Nil
    @endings << reason
  end
end

private class TestWebRtcProvider < Provider
  def expire_after(interval : Time::Span) : Nil
    expire_offers(Time.instant + interval)
  end
end

private def web_rtc_fixture
  capabilities = CameraAv::AudioCapabilities.new(1_u8, [CameraAv::AudioCodec::Opus], [48_000_u32], [16_u8])
  camera = build(CameraAv, microphone_capabilities: capabilities,
    supported_stream_usages: [CameraAv::StreamUsage::LiveView],
    max_content_buffer_size: 65_536_u32, max_network_bandwidth: 128_000_u32)
  camera.on_audio_allocate { |_request, _id| Status.success }
  camera.on_audio_deallocate { |_id| Status.success }
  stream = camera.audio_stream_allocate(CameraAv::AudioStreamAllocateRequest.new(
    CameraAv::StreamUsage::LiveView, CameraAv::AudioCodec::Opus,
    1_u8, 48_000_u32, 64_000_u32, 16_u8)).as(CameraAv::AudioStreamAllocateResponse)
  peer = TestWebRtcPeer.new
  provider = TestWebRtcProvider.new(camera.endpoint_id, camera, peer)
  {provider, camera, peer, stream.audio_stream_id}
end

private def invoke_provider(provider : Provider, command : UInt32, request : TLV::Serializable,
                            fabric : UInt8 = 1_u8, node : UInt64 = 100_u64,
                            case_session : Bool = true)
  provider.request_peer_node_id = node
  invoke(provider, command, request, is_case_session: case_session, fabric_index: fabric)
end

describe Provider do
  it "binds a peer offer, answer, ICE candidates and end to the authenticated fabric and node" do
    provider, _camera, peer, stream_id = web_rtc_fixture
    offer = Provider::ProvideOfferRequest.new(nil, "v=0\r\n", CameraAv::StreamUsage::LiveView,
      22_u16, audio_streams: [stream_id])
    response = invoke_provider(provider, Provider::CMD_PROVIDE_OFFER, offer)
      .as(Matter::Cluster::CommandResponse)
    session_id = Provider::ProvideOfferResponse.from_tlv(response.response.as(TLV::Any)).web_rtc_session_id
    peer.offers.should eq(["v=0\r\n"])
    provider.current_sessions(1_u8).as(Array(Provider::Session)).size.should eq(1)
    provider.current_sessions(2_u8).as(Array(Provider::Session)).should be_empty
    wire_session = read_tlv(provider, Provider::ATTR_CURRENT_SESSIONS, 1_u8).as_list.first
    wire_session.as_structure.keys.should contain(254_u8)
    Provider::Session.from_tlv(wire_session).audio_streams.should eq([stream_id])
    read_tlv(provider, Provider::ATTR_CURRENT_SESSIONS, 2_u8).as_list.should be_empty

    answer = Provider::ProvideAnswerRequest.new(session_id, "v=0\r\n")
    invoke_provider(provider, Provider::CMD_PROVIDE_ANSWER, answer, node: 101_u64)
      .as(Status).status.should eq(StatusCode::NotFound)
    invoke_provider(provider, Provider::CMD_PROVIDE_ANSWER, answer, fabric: 2_u8)
      .as(Status).status.should eq(StatusCode::NotFound)
    finish = Provider::EndSessionRequest.new(session_id, Provider::EndReason::UserHangup)
    invoke_provider(provider, Provider::CMD_END_SESSION, finish, fabric: 2_u8)
      .as(Status).status.should eq(StatusCode::NotFound)
    invoke_provider(provider, Provider::CMD_PROVIDE_ANSWER, answer).as(Status).success?.should be_true
    peer.answers.should eq(["v=0\r\n"])

    candidate = Provider::IceCandidate.new("candidate:1 1 UDP 1 127.0.0.1 1234 typ host", "0", 0_u16)
    ice = Provider::ProvideIceCandidatesRequest.new(session_id, [candidate])
    invoke_provider(provider, Provider::CMD_PROVIDE_ICE_CANDIDATES, ice).as(Status).success?.should be_true
    peer.candidates.should eq([candidate])
    invoke_provider(provider, Provider::CMD_END_SESSION, finish).as(Status).success?.should be_true
    peer.endings.should eq([Provider::EndReason::UserHangup])
    provider.current_sessions(1_u8).as(Array(Provider::Session)).should be_empty
  end

  it "requires authenticated CASE and an allocated same-endpoint audio stream" do
    provider, _camera, peer, stream_id = web_rtc_fixture
    offer = Provider::ProvideOfferRequest.new(nil, "v=0", CameraAv::StreamUsage::LiveView,
      22_u16, audio_streams: [stream_id])
    invoke_provider(provider, Provider::CMD_PROVIDE_OFFER, offer, case_session: false)
      .as(Status).status.should eq(StatusCode::UnsupportedAccess)
    wrong_stream = Provider::ProvideOfferRequest.new(nil, "v=0", CameraAv::StreamUsage::LiveView,
      22_u16, audio_streams: [99_u16])
    invoke_provider(provider, Provider::CMD_PROVIDE_OFFER, wrong_stream)
      .as(Status).status.should eq(StatusCode::ConstraintError)
    peer.offers.should be_empty
    provider.current_sessions(nil).as(Status).status.should eq(StatusCode::UnsupportedAccess)
  end

  it "solicits a deferred host offer and rejects unsafe ICE or duplicate streams" do
    provider, _camera, peer, stream_id = web_rtc_fixture
    request = Provider::SolicitOfferRequest.new(CameraAv::StreamUsage::LiveView,
      22_u16, audio_streams: [stream_id])
    response = invoke_provider(provider, Provider::CMD_SOLICIT_OFFER, request)
      .as(Matter::Cluster::CommandResponse)
    parsed = Provider::SolicitOfferResponse.from_tlv(response.response.as(TLV::Any))
    parsed.deferred_offer?.should be_true
    peer.solicitations.should eq([parsed.web_rtc_session_id])

    duplicate = Provider::SolicitOfferRequest.new(CameraAv::StreamUsage::LiveView,
      22_u16, audio_streams: [stream_id, stream_id])
    invoke_provider(provider, Provider::CMD_SOLICIT_OFFER, duplicate)
      .as(Status).status.should eq(StatusCode::ConstraintError)
    insecure_tls = Provider::IceServer.new(["turns:relay.example"], caid: 1_u16)
    unsupported = Provider::SolicitOfferRequest.new(CameraAv::StreamUsage::LiveView,
      22_u16, audio_streams: [stream_id], ice_servers: [insecure_tls])
    invoke_provider(provider, Provider::CMD_SOLICIT_OFFER, unsupported)
      .as(Status).status.should eq(StatusCode::ConstraintError)
  end

  it "expires a pending offer after thirty seconds" do
    provider, _camera, peer, stream_id = web_rtc_fixture
    request = Provider::SolicitOfferRequest.new(CameraAv::StreamUsage::LiveView,
      22_u16, audio_streams: [stream_id])
    response = invoke_provider(provider, Provider::CMD_SOLICIT_OFFER, request)
      .as(Matter::Cluster::CommandResponse)
    session_id = Provider::SolicitOfferResponse.from_tlv(response.response.as(TLV::Any)).web_rtc_session_id
    provider.expire_after(Provider::OFFER_TIMEOUT - 1.millisecond)
    provider.current_sessions(1_u8).as(Array(Provider::Session)).size.should eq(1)
    provider.expire_after(Provider::OFFER_TIMEOUT + 1.second)
    provider.current_sessions(1_u8).as(Array(Provider::Session)).should be_empty
    peer.endings.should eq([Provider::EndReason::InviteTimeout])
    invoke_provider(provider, Provider::CMD_PROVIDE_ANSWER,
      Provider::ProvideAnswerRequest.new(session_id, "v=0"))
      .as(Status).status.should eq(StatusCode::NotFound)
  end

  it "tears down private and removed-fabric sessions" do
    provider, camera, peer, stream_id = web_rtc_fixture
    offer = Provider::ProvideOfferRequest.new(nil, "v=0", CameraAv::StreamUsage::LiveView,
      22_u16, audio_streams: [stream_id])
    invoke_provider(provider, Provider::CMD_PROVIDE_OFFER, offer).should be_a(Matter::Cluster::CommandResponse)
    camera.microphone_muted = true
    peer.endings.should eq([Provider::EndReason::PrivacyMode])
    camera.microphone_muted = false
    invoke_provider(provider, Provider::CMD_PROVIDE_OFFER, offer).should be_a(Matter::Cluster::CommandResponse)
    provider.remove_fabric(1_u8)
    peer.endings.should eq([Provider::EndReason::PrivacyMode, Provider::EndReason::UnknownReason])
  end

  it "rolls back a host-rejected initial offer without exposing a session" do
    provider, _camera, peer, stream_id = web_rtc_fixture
    peer.reject_offer = true
    offer = Provider::ProvideOfferRequest.new(nil, "v=0", CameraAv::StreamUsage::LiveView,
      22_u16, audio_streams: [stream_id])
    invoke_provider(provider, Provider::CMD_PROVIDE_OFFER, offer)
      .as(Status).status.should eq(StatusCode::InvalidInState)
    provider.current_sessions(1_u8).as(Array(Provider::Session)).should be_empty
    peer.endings.should eq([Provider::EndReason::UnknownReason])
  end

  it "ends sessions when their host audio stream is released" do
    provider, camera, peer, stream_id = web_rtc_fixture
    offer = Provider::ProvideOfferRequest.new(nil, "v=0", CameraAv::StreamUsage::LiveView,
      22_u16, audio_streams: [stream_id])
    invoke_provider(provider, Provider::CMD_PROVIDE_OFFER, offer).should be_a(Matter::Cluster::CommandResponse)
    camera.audio_stream_deallocate(CameraAv::AudioStreamDeallocateRequest.new(stream_id))
      .success?.should be_true
    peer.endings.should eq([Provider::EndReason::OutOfResources])
    provider.current_sessions(1_u8).as(Array(Provider::Session)).should be_empty
  end
end
