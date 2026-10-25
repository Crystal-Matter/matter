require "../spec_helper"

private alias Requestor = Matter::Cluster::WebRtcTransportRequestor
private alias IMCode = Matter::InteractionModel::StatusCode

private class RequestorPeer < Requestor::Peer
  getter calls = [] of String
  property response = Matter::InteractionModel::Status.success

  def offer(session : Requestor::Session, request : Requestor::OfferRequest) : Matter::InteractionModel::Status
    @calls << "offer:#{session.id}:#{request.sdp}"
    @response
  end

  def answer(session : Requestor::Session, request : Requestor::AnswerRequest) : Matter::InteractionModel::Status
    @calls << "answer:#{session.id}:#{request.sdp}"
    @response
  end

  def ice_candidates(session : Requestor::Session, request : Requestor::IceCandidatesRequest) : Matter::InteractionModel::Status
    @calls << "ice:#{session.id}:#{request.ice_candidates.size}"
    @response
  end

  def end_session(session : Requestor::Session, request : Requestor::EndRequest) : Matter::InteractionModel::Status
    @calls << "end:#{session.id}:#{request.reason}"
    @response
  end
end

private def requestor_session(fabric : UInt8, peer : UInt64, id : UInt16 = 7_u16)
  Requestor::Session.new(id: id, peer_node_id: peer, peer_endpoint_id: 1_u16,
    stream_usage: Requestor::StreamUsage::LiveView, metadata_enabled: false,
    fabric_index: fabric, video_streams: [1_u16])
end

describe Requestor do
  it "declares revision two, admin fabric-sensitive sessions, and four operate commands" do
    peer = RequestorPeer.new
    cluster = Requestor.new(endpoint(1), peer)
    cluster.cluster_id.id.should eq(0x0554_u32)
    cluster.cluster_revision.should eq(2_u16)
    cluster.get_attribute_metadata(Requestor::ATTR_CURRENT_SESSIONS).as(Matter::Cluster::AttributeMetadata).fabric_scoped?.should be_true
    cluster.get_attribute_metadata(Requestor::ATTR_CURRENT_SESSIONS).as(Matter::Cluster::AttributeMetadata).access
      .should eq(Matter::InteractionModel::EntryPrivilege::Administer)
    accepted_command_ids(cluster).should eq([Requestor::CMD_OFFER, Requestor::CMD_ANSWER,
                                             Requestor::CMD_ICE_CANDIDATES, Requestor::CMD_END])
    read_tlv(cluster, Requestor::ATTR_CURRENT_SESSIONS, 1_u8).as_list.should be_empty
  end

  it "filters CurrentSessions by fabric and copies host-owned session data" do
    cluster = Requestor.new(endpoint(1), RequestorPeer.new)
    cluster.upsert_session(requestor_session(1_u8, 10_u64)).status.should eq(IMCode::Success)
    cluster.upsert_session(requestor_session(2_u8, 20_u64)).status.should eq(IMCode::Success)
    cluster.current_sessions(1_u8).as(Array(Requestor::Session)).map(&.peer_node_id).should eq([10_u64])
    cluster.current_sessions(2_u8).as(Array(Requestor::Session)).map(&.peer_node_id).should eq([20_u64])
    cluster.request_fabric_filtered = false
    cluster.current_sessions(1_u8).as(Array(Requestor::Session)).size.should eq(2)
    cluster.remove_fabric(1_u8)
    cluster.current_sessions(2_u8).as(Array(Requestor::Session)).map(&.peer_node_id).should eq([20_u64])
  end

  it "routes only a matching CASE fabric and peer to the host" do
    peer = RequestorPeer.new
    cluster = Requestor.new(endpoint(1), peer)
    cluster.upsert_session(requestor_session(1_u8, 10_u64))
    offer = Requestor::OfferRequest.new(7_u16, "v=0")
    expect_status(invoke(cluster, Requestor::CMD_OFFER, offer), IMCode::UnsupportedAccess)
    cluster.request_peer_node_id = 20_u64
    expect_status(invoke(cluster, Requestor::CMD_OFFER, offer,
      is_case_session: true, fabric_index: 1_u8), IMCode::NotFound)
    cluster.request_peer_node_id = 10_u64
    expect_status(invoke(cluster, Requestor::CMD_OFFER, offer,
      is_case_session: true, fabric_index: 2_u8), IMCode::NotFound)
    expect_status(invoke(cluster, Requestor::CMD_OFFER, offer,
      is_case_session: true, fabric_index: 1_u8), IMCode::Success)
    expect_status(invoke(cluster, Requestor::CMD_ANSWER, Requestor::AnswerRequest.new(7_u16, "v=0"),
      is_case_session: true, fabric_index: 1_u8), IMCode::Success)
    candidates = [Requestor::IceCandidate.new("candidate", nil, nil)]
    expect_status(invoke(cluster, Requestor::CMD_ICE_CANDIDATES,
      Requestor::IceCandidatesRequest.new(7_u16, candidates),
      is_case_session: true, fabric_index: 1_u8), IMCode::Success)
    expect_status(invoke(cluster, Requestor::CMD_END,
      Requestor::EndRequest.new(7_u16, Requestor::EndReason::UserHangup),
      is_case_session: true, fabric_index: 1_u8), IMCode::Success)
    peer.calls.should eq(["offer:7:v=0", "answer:7:v=0", "ice:7:1", "end:7:2"])
    cluster.current_sessions(1_u8).as(Array(Requestor::Session)).should be_empty
  end

  it "rejects invalid ICE and SDP data before asking the host" do
    peer = RequestorPeer.new
    cluster = Requestor.new(endpoint(1), peer)
    cluster.upsert_session(requestor_session(1_u8, 10_u64))
    cluster.request_peer_node_id = 10_u64
    expect_status(invoke(cluster, Requestor::CMD_OFFER, Requestor::OfferRequest.new(7_u16, ""),
      is_case_session: true, fabric_index: 1_u8), IMCode::ConstraintError)
    expect_status(invoke(cluster, Requestor::CMD_ICE_CANDIDATES,
      Requestor::IceCandidatesRequest.new(7_u16, [] of Requestor::IceCandidate),
      is_case_session: true, fabric_index: 1_u8), IMCode::ConstraintError)
    bad = [Requestor::IceCandidate.new("candidate", "", nil)]
    expect_status(invoke(cluster, Requestor::CMD_ICE_CANDIDATES,
      Requestor::IceCandidatesRequest.new(7_u16, bad),
      is_case_session: true, fabric_index: 1_u8), IMCode::ConstraintError)
    peer.calls.should be_empty
  end

  it "rejects an unknown End reason and releases a session even when the host declines End" do
    peer = RequestorPeer.new
    cluster = Requestor.new(endpoint(1), peer)
    cluster.upsert_session(requestor_session(1_u8, 10_u64))
    cluster.request_peer_node_id = 10_u64
    expect_status(invoke(cluster, Requestor::CMD_END, Requestor::EndRequest.new(7_u16, 255_u8),
      is_case_session: true, fabric_index: 1_u8), IMCode::ConstraintError)
    peer.calls.should be_empty
    peer.response = Matter::InteractionModel::Status.invalid_in_state
    expect_status(invoke(cluster, Requestor::CMD_END,
      Requestor::EndRequest.new(7_u16, Requestor::EndReason::UserHangup),
      is_case_session: true, fabric_index: 1_u8), IMCode::InvalidInState)
    cluster.current_sessions(1_u8).as(Array(Requestor::Session)).should be_empty
  end

  it "keys same-ID sessions by peer, validates host registrations, and removes one tuple" do
    cluster = Requestor.new(endpoint(1), RequestorPeer.new)
    cluster.upsert_session(requestor_session(1_u8, 10_u64)).status.should eq(IMCode::Success)
    cluster.upsert_session(requestor_session(1_u8, 20_u64)).status.should eq(IMCode::Success)
    cluster.current_sessions(1_u8).as(Array(Requestor::Session)).map(&.peer_node_id).should eq([10_u64, 20_u64])
    cluster.upsert_session(requestor_session(1_u8, 10_u64)).status.should eq(IMCode::Success)
    cluster.current_sessions(1_u8).as(Array(Requestor::Session)).size.should eq(2)
    cluster.upsert_session(requestor_session(0_u8, 30_u64)).status.should eq(IMCode::ConstraintError)
    cluster.upsert_session(requestor_session(1_u8, 0_u64)).status.should eq(IMCode::ConstraintError)
    cluster.upsert_session(Requestor::Session.new(id: 8_u16, peer_node_id: 30_u64,
      peer_endpoint_id: 1_u16, stream_usage: Requestor::StreamUsage::LiveView,
      metadata_enabled: false, fabric_index: 1_u8)).status.should eq(IMCode::ConstraintError)
    cluster.remove_session(1_u8, 10_u64, 7_u16).should be_true
    cluster.current_sessions(1_u8).as(Array(Requestor::Session)).map(&.peer_node_id).should eq([20_u64])
  end
end
