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

private def video_web_rtc_fixture
  camera = build(CameraAv,
    supported_stream_usages: [CameraAv::StreamUsage::LiveView],
    max_content_buffer_size: 65_536_u32, max_network_bandwidth: 2_000_000_u32,
    video_sensor_params: CameraAv::VideoSensorParams.new(1920_u16, 1080_u16, 30_u16),
    min_viewport_resolution: CameraAv::VideoResolution.new(160_u16, 90_u16),
    rate_distortion_trade_off_points: [CameraAv::RateDistortionPoint.new(CameraAv::VideoCodec::H264,
      CameraAv::VideoResolution.new(640_u16, 360_u16), 200_000_u32)],
    max_concurrent_encoders: 1_u8, max_encoded_pixel_rate: 62_208_000_u32,
    feature_map: CameraAv::Feature::Video | CameraAv::Feature::Privacy)
  camera.on_video_allocate { |_request, _id| Status.success }
  camera.on_video_deallocate { |_id| Status.success }
  request = CameraAv::VideoStreamAllocateRequest.new(CameraAv::StreamUsage::LiveView,
    CameraAv::VideoCodec::H264, 15_u16, 30_u16,
    CameraAv::VideoResolution.new(320_u16, 180_u16),
    CameraAv::VideoResolution.new(1280_u16, 720_u16),
    200_000_u32, 1_000_000_u32, 30_u16)
  stream = camera.video_stream_allocate(request).as(CameraAv::VideoStreamAllocateResponse)
  peer = TestWebRtcPeer.new
  provider = TestWebRtcProvider.new(camera.endpoint_id, camera, peer)
  {provider, camera, peer, stream.video_stream_id, request}
end

private def invoke_provider(provider : Provider, command : UInt32, request : TLV::Serializable,
                            fabric : UInt8 = 1_u8, node : UInt64 = 100_u64,
                            case_session : Bool = true)
  provider.request_peer_node_id = node
  invoke(provider, command, request, is_case_session: case_session, fabric_index: fabric)
end

describe Provider do
  it "assigns an allocated audio stream for a legacy null SolicitOffer ID" do
    provider, _camera, peer, audio_id = web_rtc_fixture
    request = Provider::SolicitOfferRequest.new(CameraAv::StreamUsage::LiveView,
      22_u16, audio_stream_id: TLV::FieldState(UInt16).null)
    decoded = Provider::SolicitOfferRequest.from_slice(request.to_slice)
    decoded.audio_stream_id_state.null?.should be_true
    decoded.video_stream_id_state.absent?.should be_true

    response = invoke_provider(provider, Provider::CMD_SOLICIT_OFFER, decoded)
      .as(Matter::Cluster::CommandResponse)
    parsed = Provider::SolicitOfferResponse.from_tlv(response.response.as(TLV::Any))
    parsed.audio_stream_id.should eq(audio_id)
    parsed.video_stream_id_state.absent?.should be_true
    provider.current_sessions(1_u8).as(Array(Provider::Session)).first.audio_streams.should eq([audio_id])
    peer.solicitations.should eq([parsed.web_rtc_session_id])
  end

  it "assigns an allocated video stream for a legacy null ProvideOffer ID" do
    provider, _camera, peer, video_id, _request = video_web_rtc_fixture
    request = Provider::ProvideOfferRequest.new(nil, "v=0", CameraAv::StreamUsage::LiveView,
      22_u16, video_stream_id: TLV::FieldState(UInt16).null)
    decoded = Provider::ProvideOfferRequest.from_slice(request.to_slice)
    decoded.video_stream_id_state.null?.should be_true
    decoded.audio_stream_id_state.absent?.should be_true

    response = invoke_provider(provider, Provider::CMD_PROVIDE_OFFER, decoded)
      .as(Matter::Cluster::CommandResponse)
    parsed = Provider::ProvideOfferResponse.from_tlv(response.response.as(TLV::Any))
    parsed.video_stream_id.should eq(video_id)
    parsed.audio_stream_id_state.absent?.should be_true
    provider.current_sessions(1_u8).as(Array(Provider::Session)).first.video_streams.should eq([video_id])
    peer.offers.should eq(["v=0"])
  end

  it "fails automatic assignment before creating a session when no stream is allocated" do
    provider, camera, peer, audio_id = web_rtc_fixture
    camera.audio_stream_deallocate(CameraAv::AudioStreamDeallocateRequest.new(audio_id))
      .success?.should be_true
    request = Provider::ProvideOfferRequest.new(nil, "v=0", CameraAv::StreamUsage::LiveView,
      22_u16, audio_stream_id: TLV::FieldState(UInt16).null)
    invoke_provider(provider, Provider::CMD_PROVIDE_OFFER, request)
      .as(Status).status.should eq(StatusCode::ResourceExhausted)
    provider.current_sessions(1_u8).as(Array(Provider::Session)).should be_empty
    peer.offers.should be_empty
  end

  it "rejects a legacy null stream change on an existing session" do
    provider, _camera, peer, audio_id = web_rtc_fixture
    initial = Provider::ProvideOfferRequest.new(nil, "v=0", CameraAv::StreamUsage::LiveView,
      22_u16, audio_streams: [audio_id])
    response = invoke_provider(provider, Provider::CMD_PROVIDE_OFFER, initial)
      .as(Matter::Cluster::CommandResponse)
    session_id = Provider::ProvideOfferResponse.from_tlv(response.response.as(TLV::Any)).web_rtc_session_id
    revision = Provider::ProvideOfferRequest.new(session_id, "v=1",
      audio_stream_id: TLV::FieldState(UInt16).null)
    invoke_provider(provider, Provider::CMD_PROVIDE_OFFER, revision)
      .as(Status).status.should eq(StatusCode::ConstraintError)
    peer.offers.should eq(["v=0"])
    provider.current_sessions(1_u8).as(Array(Provider::Session)).size.should eq(1)
  end

  it "returns the requested legacy video ID in SolicitOfferResponse" do
    provider, _camera, _peer, video_id, _request = video_web_rtc_fixture
    solicitation = Provider::SolicitOfferRequest.new(CameraAv::StreamUsage::LiveView,
      22_u16, video_stream_id: video_id)
    response = invoke_provider(provider, Provider::CMD_SOLICIT_OFFER, solicitation)
      .as(Matter::Cluster::CommandResponse).response.as(TLV::Any).as_structure
    response[2_u8].value.should eq(video_id)
    response.keys.should_not contain(3_u8)
  end

  it "returns the requested legacy video ID in ProvideOfferResponse" do
    provider, _camera, _peer, video_id, _request = video_web_rtc_fixture
    offer = Provider::ProvideOfferRequest.new(nil, "v=0", CameraAv::StreamUsage::LiveView,
      22_u16, video_stream_id: video_id)
    response = invoke_provider(provider, Provider::CMD_PROVIDE_OFFER, offer)
      .as(Matter::Cluster::CommandResponse).response.as(TLV::Any).as_structure
    response[1_u8].value.should eq(video_id)
    response.keys.should_not contain(2_u8)
  end

  it "retains conditional legacy audio response fields" do
    provider, _camera, _peer, audio_id = web_rtc_fixture
    solicitation = Provider::SolicitOfferRequest.new(CameraAv::StreamUsage::LiveView,
      22_u16, audio_stream_id: audio_id)
    solicited = invoke_provider(provider, Provider::CMD_SOLICIT_OFFER, solicitation)
      .as(Matter::Cluster::CommandResponse).response.as(TLV::Any).as_structure
    solicited[3_u8].value.should eq(audio_id)
    solicited.keys.should_not contain(2_u8)

    offer = Provider::ProvideOfferRequest.new(nil, "v=0", CameraAv::StreamUsage::LiveView,
      22_u16, audio_stream_id: audio_id)
    provided = invoke_provider(provider, Provider::CMD_PROVIDE_OFFER, offer)
      .as(Matter::Cluster::CommandResponse).response.as(TLV::Any).as_structure
    provided[2_u8].value.should eq(audio_id)
    provided.keys.should_not contain(1_u8)
  end

  it "omits legacy response fields when a later offer does not carry them" do
    provider, _camera, _peer, audio_id = web_rtc_fixture
    solicitation = Provider::SolicitOfferRequest.new(CameraAv::StreamUsage::LiveView,
      22_u16, audio_stream_id: audio_id)
    solicited = invoke_provider(provider, Provider::CMD_SOLICIT_OFFER, solicitation)
      .as(Matter::Cluster::CommandResponse)
    id = Provider::SolicitOfferResponse.from_tlv(solicited.response.as(TLV::Any)).web_rtc_session_id

    later_offer = Provider::ProvideOfferRequest.new(id, "v=0")
    response = invoke_provider(provider, Provider::CMD_PROVIDE_OFFER, later_offer)
      .as(Matter::Cluster::CommandResponse).response.as(TLV::Any).as_structure
    response.keys.should_not contain(1_u8)
    response.keys.should_not contain(2_u8)
  end

  it "reports the automatically selected legacy video ID but omits absent audio IDs" do
    provider, _camera, _peer, video_id, _request = video_web_rtc_fixture
    solicitation = Provider::SolicitOfferRequest.new(CameraAv::StreamUsage::LiveView,
      22_u16, video_stream_id: TLV::FieldState(UInt16).null, video_streams: [video_id])
    decoded_solicitation = Provider::SolicitOfferRequest.from_slice(solicitation.to_slice)
    decoded_solicitation.video_stream_id_state.null?.should be_true
    decoded_solicitation.audio_stream_id_state.absent?.should be_true
    solicited = invoke_provider(provider, Provider::CMD_SOLICIT_OFFER, solicitation)
      .as(Matter::Cluster::CommandResponse).response.as(TLV::Any).as_structure
    solicited.keys.should contain(2_u8)
    solicited[2_u8].value.should eq(video_id)
    solicited.keys.should_not contain(3_u8)

    offer = Provider::ProvideOfferRequest.new(nil, "v=0", CameraAv::StreamUsage::LiveView,
      22_u16, video_stream_id: TLV::FieldState(UInt16).null, video_streams: [video_id])
    decoded_offer = Provider::ProvideOfferRequest.from_slice(offer.to_slice)
    decoded_offer.video_stream_id_state.null?.should be_true
    decoded_offer.audio_stream_id_state.absent?.should be_true
    provided = invoke_provider(provider, Provider::CMD_PROVIDE_OFFER, offer)
      .as(Matter::Cluster::CommandResponse).response.as(TLV::Any).as_structure
    provided.keys.should contain(1_u8)
    provided[1_u8].value.should eq(video_id)
    provided.keys.should_not contain(2_u8)
  end

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
    provider.expire_after(Provider::OFFER_TIMEOUT - 5.seconds)
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

  it "lets the media host end only the matching fabric and peer session" do
    provider, _camera, peer, stream_id = web_rtc_fixture
    offer = Provider::ProvideOfferRequest.new(nil, "v=0", CameraAv::StreamUsage::LiveView,
      22_u16, audio_streams: [stream_id])
    first = invoke_provider(provider, Provider::CMD_PROVIDE_OFFER, offer)
      .as(Matter::Cluster::CommandResponse)
    first_id = Provider::ProvideOfferResponse.from_tlv(first.response.as(TLV::Any)).web_rtc_session_id
    second = invoke_provider(provider, Provider::CMD_PROVIDE_OFFER, offer, fabric: 2_u8, node: 200_u64)
      .as(Matter::Cluster::CommandResponse)
    second_id = Provider::ProvideOfferResponse.from_tlv(second.response.as(TLV::Any)).web_rtc_session_id

    provider.end_host_session(2_u8, 100_u64, first_id).should be_false
    provider.end_host_session(1_u8, 200_u64, first_id).should be_false
    provider.current_sessions(1_u8).as(Array(Provider::Session)).size.should eq(1)
    provider.current_sessions(2_u8).as(Array(Provider::Session)).size.should eq(1)
    provider.end_host_session(1_u8, 100_u64, first_id, Provider::EndReason::IceFailed).should be_true
    provider.end_host_session(1_u8, 100_u64, first_id).should be_false
    peer.endings.should eq([Provider::EndReason::IceFailed])
    provider.current_sessions(1_u8).as(Array(Provider::Session)).should be_empty
    provider.current_sessions(2_u8).as(Array(Provider::Session)).map(&.id).should eq([second_id])
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

  it "negotiates a CASE-owned H.264 video-only session and ends it for video privacy" do
    provider, camera, peer, video_id, _request = video_web_rtc_fixture
    offer = Provider::ProvideOfferRequest.new(nil, "v=0\r\n", CameraAv::StreamUsage::LiveView,
      22_u16, video_streams: [video_id])
    invoke_provider(provider, Provider::CMD_PROVIDE_OFFER, offer, case_session: false)
      .as(Status).status.should eq(StatusCode::UnsupportedAccess)
    response = invoke_provider(provider, Provider::CMD_PROVIDE_OFFER, offer)
      .as(Matter::Cluster::CommandResponse)
    id = Provider::ProvideOfferResponse.from_tlv(response.response.as(TLV::Any)).web_rtc_session_id
    session = provider.current_sessions(1_u8).as(Array(Provider::Session)).first
    session.video_streams.should eq([video_id])
    session.video_stream_id.should eq(video_id)
    session.audio_streams.should be_nil
    session.audio_stream_id.should be_nil
    wire = Provider::Session.from_tlv(read_tlv(provider, Provider::ATTR_CURRENT_SESSIONS, 1_u8).as_list.first)
    wire.video_streams.should eq([video_id])
    wire.video_stream_id.should eq(video_id)
    wire.audio_streams.should be_nil

    answer = Provider::ProvideAnswerRequest.new(id, "v=0\r\n")
    invoke_provider(provider, Provider::CMD_PROVIDE_ANSWER, answer, node: 101_u64)
      .as(Status).status.should eq(StatusCode::NotFound)
    invoke_provider(provider, Provider::CMD_PROVIDE_ANSWER, answer, fabric: 2_u8)
      .as(Status).status.should eq(StatusCode::NotFound)
    invoke_provider(provider, Provider::CMD_PROVIDE_ANSWER, answer).as(Status).success?.should be_true
    candidate = Provider::IceCandidate.new("candidate:1 1 UDP 1 127.0.0.1 1234 typ host", "0", 0_u16)
    invoke_provider(provider, Provider::CMD_PROVIDE_ICE_CANDIDATES,
      Provider::ProvideIceCandidatesRequest.new(id, [candidate]), node: 101_u64)
      .as(Status).status.should eq(StatusCode::NotFound)
    invoke_provider(provider, Provider::CMD_PROVIDE_ICE_CANDIDATES,
      Provider::ProvideIceCandidatesRequest.new(id, [candidate])).as(Status).success?.should be_true
    peer.answers.should eq(["v=0\r\n"])
    peer.candidates.should eq([candidate])

    camera.microphone_muted = true
    provider.current_sessions(1_u8).as(Array(Provider::Session)).size.should eq(1)
    camera.soft_livestream_privacy_mode_enabled = true
    peer.endings.should eq([Provider::EndReason::PrivacyMode])
    provider.current_sessions(1_u8).as(Array(Provider::Session)).should be_empty
  end

  it "rejects invalid video stream selections and ends sessions on final video release" do
    provider, camera, peer, video_id, request = video_web_rtc_fixture
    invalid = [
      Provider::ProvideOfferRequest.new(nil, "v=0", CameraAv::StreamUsage::LiveView,
        22_u16, video_streams: [video_id, video_id]),
      Provider::ProvideOfferRequest.new(nil, "v=0", CameraAv::StreamUsage::LiveView,
        22_u16, video_streams: [] of UInt16),
      Provider::ProvideOfferRequest.new(nil, "v=0", CameraAv::StreamUsage::LiveView,
        22_u16, video_streams: [99_u16]),
      Provider::ProvideOfferRequest.new(nil, "v=0", CameraAv::StreamUsage::Recording,
        22_u16, video_streams: [video_id]),
    ]
    invalid.each do |offer|
      invoke_provider(provider, Provider::CMD_PROVIDE_OFFER, offer)
        .as(Status).status.should eq(StatusCode::ConstraintError)
    end
    peer.offers.should be_empty

    camera.video_stream_allocate(request).as(CameraAv::VideoStreamAllocateResponse).video_stream_id.should eq(video_id)
    offer = Provider::ProvideOfferRequest.new(nil, "v=0", CameraAv::StreamUsage::LiveView,
      22_u16, video_stream_id: video_id)
    response = invoke_provider(provider, Provider::CMD_PROVIDE_OFFER, offer)
      .as(Matter::Cluster::CommandResponse)
    id = Provider::ProvideOfferResponse.from_tlv(response.response.as(TLV::Any)).web_rtc_session_id
    provider.current_sessions(1_u8).as(Array(Provider::Session)).first.video_streams.should eq([video_id])
    camera.video_stream_deallocate(CameraAv::VideoStreamDeallocateRequest.new(video_id))
      .success?.should be_true
    provider.current_sessions(1_u8).as(Array(Provider::Session)).size.should eq(1)
    camera.video_stream_deallocate(CameraAv::VideoStreamDeallocateRequest.new(video_id))
      .success?.should be_true
    peer.endings.should eq([Provider::EndReason::OutOfResources])
    provider.current_sessions(1_u8).as(Array(Provider::Session)).should be_empty
    invoke_provider(provider, Provider::CMD_PROVIDE_ANSWER,
      Provider::ProvideAnswerRequest.new(id, "v=0")).as(Status).status.should eq(StatusCode::NotFound)
  end

  it "solicits a deferred H.264 video-only offer and validates candidates" do
    provider, _camera, peer, video_id, _request = video_web_rtc_fixture
    solicitation = Provider::SolicitOfferRequest.new(CameraAv::StreamUsage::LiveView,
      22_u16, video_streams: [video_id])
    response = invoke_provider(provider, Provider::CMD_SOLICIT_OFFER, solicitation)
      .as(Matter::Cluster::CommandResponse)
    id = Provider::SolicitOfferResponse.from_tlv(response.response.as(TLV::Any)).web_rtc_session_id
    peer.solicitations.should eq([id])
    provider.current_sessions(1_u8).as(Array(Provider::Session)).first.video_streams.should eq([video_id])
    invoke_provider(provider, Provider::CMD_PROVIDE_ICE_CANDIDATES,
      Provider::ProvideIceCandidatesRequest.new(id, [] of Provider::IceCandidate))
      .as(Status).status.should eq(StatusCode::ConstraintError)
    invoke_provider(provider, Provider::CMD_PROVIDE_ICE_CANDIDATES,
      Provider::ProvideIceCandidatesRequest.new(id, [Provider::IceCandidate.new("candidate", "", nil)]))
      .as(Status).status.should eq(StatusCode::ConstraintError)
    peer.candidates.should be_empty
    deferred_offer = Provider::ProvideOfferRequest.new(id, "v=0")
    invoke_provider(provider, Provider::CMD_PROVIDE_OFFER, deferred_offer)
      .should be_a(Matter::Cluster::CommandResponse)
    peer.offers.should eq(["v=0"])
  end
end
