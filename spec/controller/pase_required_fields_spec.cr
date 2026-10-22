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

private class ScriptedSessionIdCrypto < Matter::Crypto::StandardCrypto
  getter random_uint16_calls = 0

  def initialize(@ids : Array(UInt16))
  end

  def random_uint16 : UInt16
    @random_uint16_calls += 1
    @ids.shift? || 0_u16
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

  it "skips zero and shared-transport session IDs before sending PBKDFParamRequest" do
    crypto = ScriptedSessionIdCrypto.new([0_u16, 42_u16, 43_u16])
    client = CapturePaseRequestClient.new(session_id_in_use: ->(id : UInt16) { id == 42_u16 })
    peer = Socket::IPAddress.new("::1", 5540)

    expect_raises(Matter::ProtocolError, /captured PBKDFParamRequest/) do
      Matter::Controller::Pairing::PasePairing.new(crypto).pair(client, peer, 20202021_u32)
    end

    request = Matter::Session::Pase::Definitions::PbkdfParamRequest.from_slice(client.pbkdf_payload.as(Bytes))
    request.initiator_session_id.should eq(43_u16)
    crypto.random_uint16_calls.should eq(3)
  ensure
    client.try(&.close)
  end

  it "skips a controller session ID already registered by a previous pairing" do
    crypto = ScriptedSessionIdCrypto.new([42_u16, 43_u16])
    client = CapturePaseRequestClient.new
    existing = Matter::Session::SecureContext.new(
      session_id: 42_u16, peer_session_id: 99_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16), decryption_key: Bytes.new(16))
    client.register_session(existing)
    peer = Socket::IPAddress.new("::1", 5540)

    expect_raises(Matter::ProtocolError, /captured PBKDFParamRequest/) do
      Matter::Controller::Pairing::PasePairing.new(crypto).pair(client, peer, 20202021_u32)
    end

    request = Matter::Session::Pase::Definitions::PbkdfParamRequest.from_slice(client.pbkdf_payload.as(Bytes))
    request.initiator_session_id.should eq(43_u16)
    crypto.random_uint16_calls.should eq(2)
  ensure
    client.try(&.close)
  end

  it "fails before sending when no usable session ID is drawn within the allocation bound" do
    crypto = ScriptedSessionIdCrypto.new([] of UInt16)
    client = CapturePaseRequestClient.new
    peer = Socket::IPAddress.new("::1", 5540)

    expect_raises(Matter::ProtocolError, /Could not allocate an unused PASE session ID/) do
      Matter::Controller::Pairing::PasePairing.new(crypto).pair(client, peer, 20202021_u32)
    end

    client.pbkdf_payload.should be_nil
    crypto.random_uint16_calls.should eq(Matter::Controller::Client::SESSION_ID_ALLOCATION_ATTEMPTS)
  ensure
    client.try(&.close)
  end
end
