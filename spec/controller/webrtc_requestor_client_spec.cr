require "../spec_helper"
require "../../src/matter/controller/webrtc_requestor_client"

private alias Signaling = Matter::Controller::WebrtcRequestorClient

private class RequestorImFake
  record Call, endpoint : UInt16, cluster : UInt32, command : UInt32, fields : Bytes
  getter calls = [] of Call
  property returned_command : UInt32? = nil
  property returned_status = Matter::InteractionModel::StatusCode::Success

  def invoke(_session : Matter::Session::SecureContext, _peer : Socket::IPAddress,
             endpoint_id : UInt16, cluster_id : UInt32, command_id : UInt32,
             fields : Bytes) : Matter::InteractionModel::InvokeResponseMessage
    @calls << Call.new(endpoint_id, cluster_id, command_id, fields.dup)
    path = Matter::InteractionModel::CommandPath.new(endpoint_id, cluster_id,
      @returned_command || command_id)
    status = Matter::InteractionModel::CommandStatusIB.new(path,
      Matter::InteractionModel::StatusIB.new(@returned_status.value))
    Matter::InteractionModel::InvokeResponseMessage.new(
      invoke_responses: [Matter::InteractionModel::InvokeResponseIB.new(command_status: status)])
  end
end

private def signaling_session(peer_node_id : UInt64 = 0x1234_u64,
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

private def signaling_peer : Socket::IPAddress
  Socket::IPAddress.new("127.0.0.1", 5540)
end

describe Matter::Controller::WebrtcRequestorClient do
  it "emits mandatory nullable ICE candidate fields as TLV Null" do
    candidate = Signaling::IceCandidate.new("candidate:1")
    wire = TLV::Any.from_slice(candidate.to_slice)
    wire[1_u8].header.element_type.should eq(TLV::ElementType::Null)
    wire[2_u8].header.element_type.should eq(TLV::ElementType::Null)
    Signaling::IceCandidate.from_slice(candidate.to_slice).sdp_mid.should be_nil
    expect_raises(TLV::DeserializationError) do
      Signaling::IceCandidate.from_slice(Bytes[0x15, 0x2C, 0x00, 0x01, 0x78, 0x18])
    end
  end

  it "encodes Offer, Answer, ICECandidates, and End on Requestor 0x0554" do
    im = RequestorImFake.new
    client = Signaling.new(im)
    session = signaling_session
    binding = client.bind(session, 2_u16, 7_u16)
    server = Signaling::IceServer.new(["stun:example.test"])
    candidate = Signaling::IceCandidate.new("candidate:1", "0", 0_u16)
    client.offer(binding, session, signaling_peer, "v=0", ice_servers: [server], ice_transport_policy: "all")
    client.answer(binding, session, signaling_peer, "v=0 answer")
    client.ice_candidates(binding, session, signaling_peer, [candidate])
    client.end_session(binding, session, signaling_peer, Signaling::EndReason::UserHangup)
    im.calls.map(&.command).should eq([0_u32, 1_u32, 2_u32, 3_u32])
    im.calls.all? { |call| call.cluster == Signaling::CLUSTER_ID && call.endpoint == 2_u16 }.should be_true
    Signaling::OfferRequest.from_slice(im.calls[0].fields).session_id.should eq(7_u16)
    Signaling::OfferRequest.from_slice(im.calls[0].fields).ice_servers.should eq([server])
    Signaling::EndRequest.from_slice(im.calls[3].fields).reason.should eq(Signaling::EndReason::UserHangup)
  end

  it "rejects unauthenticated and cross-fabric or cross-peer signaling before Invoke" do
    im = RequestorImFake.new
    client = Signaling.new(im)
    expect_raises(Matter::SessionError) { client.bind(signaling_session(case_session: false), 2_u16, 7_u16) }
    binding = client.bind(signaling_session, 2_u16, 7_u16)
    expect_raises(Matter::SessionError) { client.offer(binding, signaling_session(fabric_index: 2_u8), signaling_peer, "v=0") }
    expect_raises(Matter::SessionError) { client.offer(binding, signaling_session(peer_node_id: 0x5678_u64), signaling_peer, "v=0") }
    im.calls.should be_empty
  end

  it "rejects malformed status paths and failed commands" do
    im = RequestorImFake.new
    client = Signaling.new(im)
    session = signaling_session
    binding = client.bind(session, 2_u16, 7_u16)
    im.returned_command = 99_u32
    expect_raises(Matter::ProtocolError) { client.offer(binding, session, signaling_peer, "v=0") }
    im.returned_command = nil
    im.returned_status = Matter::InteractionModel::StatusCode::Failure
    expect_raises(Matter::ClusterError) { client.offer(binding, session, signaling_peer, "v=0") }
  end

  it "enforces ICE candidate and ICE server bounds" do
    im = RequestorImFake.new
    client = Signaling.new(im)
    session = signaling_session
    binding = client.bind(session, 2_u16, 7_u16)
    expect_raises(Matter::ConfigurationError) { client.ice_candidates(binding, session, signaling_peer, [] of Signaling::IceCandidate) }
    expect_raises(Matter::ConfigurationError) { client.offer(binding, session, signaling_peer, "v=0", ice_servers: Array.new(11) { Signaling::IceServer.new(["stun:a"]) }) }
    im.calls.should be_empty
  end
end
