require "../spec_helper"

private alias Provider = Matter::Cluster::WebRtcTransportProvider

private struct MissingOfferSessionId
  include TLV::Serializable

  @[TLV::Field(tag: 1)]
  getter sdp : String

  def initialize(@sdp : String)
  end
end

private struct MissingCandidateFields
  include TLV::Serializable

  @[TLV::Field(tag: 0)]
  getter candidate : String

  def initialize(@candidate : String)
  end
end

describe "Matter 1.6 WebRTC Provider mandatory nullable TLV" do
  it "encodes explicit Null for ProvideOffer's mandatory nullable session ID" do
    request = Provider::ProvideOfferRequest.new(nil, "v=0")
    wire = TLV::Any.from_slice(request.to_slice).as_structure
    wire.keys.should contain(0_u8)
    wire[0_u8].value.should be_nil
    Provider::ProvideOfferRequest.from_slice(request.to_slice).web_rtc_session_id.should be_nil
  end

  it "rejects an absent ProvideOffer session ID" do
    expect_raises(TLV::DeserializationError) do
      Provider::ProvideOfferRequest.from_slice(MissingOfferSessionId.new("v=0").to_slice)
    end
  end

  it "encodes explicit Null for both mandatory nullable ICE candidate fields" do
    candidate = Provider::IceCandidate.new("candidate:1")
    wire = TLV::Any.from_slice(candidate.to_slice).as_structure
    wire.keys.should contain(1_u8)
    wire.keys.should contain(2_u8)
    wire[1_u8].value.should be_nil
    wire[2_u8].value.should be_nil
    decoded = Provider::IceCandidate.from_slice(candidate.to_slice)
    decoded.sdp_mid.should be_nil
    decoded.sdp_m_line_index.should be_nil
  end

  it "rejects absent ICE candidate SDPMid and SDPMLineIndex" do
    expect_raises(TLV::DeserializationError) do
      Provider::IceCandidate.from_slice(MissingCandidateFields.new("candidate:1").to_slice)
    end
  end
end
