require "../../spec_helper"
require "../../../src/matter/session/case/case"

describe "CASE session resumption wire and keys" do
  it "round-trips Sigma2Resume with the Matter 1.6 context tags" do
    message = Matter::Session::Case::Definitions::Sigma2Resume.new(
      resumption_id: Bytes.new(16, 0x21_u8),
      resume_mic: Bytes.new(16, 0x42_u8),
      responder_session_id: 0x1234_u16,
      responder_session_params: Matter::Session::Case::Definitions::SessionParameter.new(
        session_idle_interval: 5000_u32))

    decoded = Matter::Session::Case::Definitions::Sigma2Resume.from_slice(message.to_slice)
    decoded.resumption_id.should eq(message.resumption_id)
    decoded.resume_mic.should eq(message.resume_mic)
    decoded.responder_session_id.should eq(0x1234_u16)
    decoded.responder_session_params.try(&.session_idle_interval).should eq(5000_u32)
  end

  it "derives both resume MICs and session keys from independent HKDF/CCM vectors" do
    crypto = Matter::Crypto::StandardCrypto.new
    shared_secret = Bytes.new(32) { |index| (index + 1).to_u8 }
    initiator_random = Bytes.new(32) { |index| (index + 32).to_u8 }
    old_id = Bytes.new(16) { |index| (index + 64).to_u8 }
    new_id = Bytes.new(16) { |index| (index + 80).to_u8 }

    resume1 = Matter::Session::Case.resume1_mic(crypto, shared_secret, initiator_random, old_id)
    resume1.hexstring.should eq("e98e49ec0f8681501cb41d3764c0d9e7")
    Matter::Session::Case.valid_resume1_mic?(crypto, shared_secret, initiator_random, old_id, resume1).should be_true
    tampered = resume1.dup
    tampered[0] ^= 0x01_u8
    Matter::Session::Case.valid_resume1_mic?(crypto, shared_secret, initiator_random, old_id, tampered).should be_false

    resume2 = Matter::Session::Case.resume2_mic(crypto, shared_secret, initiator_random, new_id)
    resume2.hexstring.should eq("4b9b19700d2f87a751614a0721eee44e")
    Matter::Session::Case.valid_resume2_mic?(crypto, shared_secret, initiator_random, new_id, resume2).should be_true

    salt = initiator_random + old_id
    keys = Matter::Session::Case.derive_session_keys(crypto, shared_secret, salt,
      Matter::Session::Case::Role::Initiator)
    keys[:encryption].hexstring.should eq("f93a32a672e8413a8bdbaa10343d5aef")
    keys[:decryption].hexstring.should eq("cef275b5dcdf161df58a964e11ef625b")
    keys[:attestation_challenge].hexstring.should eq("bdd6a8cd912168ae68b7d5f45f6de220")
  end
end
