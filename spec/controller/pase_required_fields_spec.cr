require "../spec_helper"
require "../../src/matter/controller"

private class CapturePaseRequestClient < Matter::Controller::Client
  getter pbkdf_payload : Bytes?

  def send_unsecured_request(peer : Socket::IPAddress, protocol_id : UInt16,
                             message_type : UInt8, payload : Bytes | Slice(UInt8),
                             requires_ack : Bool = true) : UInt16
    @pbkdf_payload = payload.to_slice.dup
    raise Matter::ProtocolError.new("captured PBKDFParamRequest")
  end
end

describe Matter::Controller::Pairing::PasePairing do
  it "sends all mandatory PBKDFParamRequest fields to a strict Matter peer" do
    client = CapturePaseRequestClient.new
    peer = Socket::IPAddress.new("::1", 5540)
    expect_raises(Matter::ProtocolError, /captured PBKDFParamRequest/) do
      Matter::Controller::Pairing::PasePairing.new.pair(client, peer, 20202021_u32)
    end
    payload = client.pbkdf_payload.as(Bytes)
    request = Matter::Session::Pase::Definitions::PbkdfParamRequest.from_slice(payload)
    request.initiator_random.as(Bytes).size.should eq(32)
    request.initiator_session_id.should_not be_nil
    request.passcode_id.should eq(0_u16)
    request.has_pbkdf_parameters.should be_false
  ensure
    client.try(&.close)
  end
end
