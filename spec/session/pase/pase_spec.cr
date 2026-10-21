require "../../spec_helper"
require "../../../src/matter/session/pase/pase"

describe Matter::Session::Pase do
  describe "PbkdfParameters" do
    it "creates PBKDF parameters" do
      params = Matter::Session::Pase::PbkdfParameters.new(
        iterations: 2000,
        salt: Bytes.new(32, 1_u8)
      )

      params.iterations.should eq(2000)
      params.salt.size.should eq(32)
    end

    it "creates default parameters" do
      params = Matter::Session::Pase::PbkdfParameters.default
      params.iterations.should eq(1000)
      params.salt.size.should eq(32)
    end

    it "encodes and decodes PBKDF parameter request" do
      # Create a request
      request = Matter::Session::Pase::Definitions::PbkdfParamRequest.new

      # Encode to TLV bytes
      encoded = request.to_slice
      encoded.should be_a(Bytes)

      # Decode from TLV bytes
      decoded = Matter::Session::Pase::Definitions::PbkdfParamRequest.from_slice(encoded)
      decoded.initiator_random.should be_nil
      decoded.initiator_session_id.should be_nil
    end

    it "encodes and decodes PBKDF parameter response" do
      # Create a response with test data
      salt = Bytes.new(32, 0xAB_u8)
      initiator_random = Random::Secure.random_bytes(32)
      responder_random = Random::Secure.random_bytes(32)
      responder_session_id = 1234_u16

      response = Matter::Session::Pase::Definitions::PbkdfParamResponse.new(
        initiator_random: initiator_random,
        responder_random: responder_random,
        responder_session_id: responder_session_id,
        iterations: 1000_u32,
        salt: salt
      )

      # Encode to TLV bytes
      encoded = response.to_slice
      encoded.should be_a(Bytes)

      # Decode from TLV bytes
      decoded = Matter::Session::Pase::Definitions::PbkdfParamResponse.from_slice(encoded)
      decoded.initiator_random.should eq(initiator_random)
      decoded.responder_random.should eq(responder_random)
      decoded.responder_session_id.should eq(responder_session_id)

      # Check pbkdf_parameters
      pbkdf = decoded.pbkdf_parameters
      pbkdf.should_not be_nil
      pbkdf.as(Matter::Session::Pase::Definitions::PbkdfParametersTLV).iterations.should eq(1000_u32)
      pbkdf.as(Matter::Session::Pase::Definitions::PbkdfParametersTLV).salt.should eq(salt)
    end

    it "round-trips PBKDF parameter request and response" do
      # Commissioner creates request
      commissioner = Matter::Session::Pase::PaseCommissioner.new(pin_code: 12345678_u32)
      request_bytes = commissioner.create_pbkdf_param_request

      # Responder processes request and creates response
      params = Matter::Session::Pase::PbkdfParameters.default
      responder = Matter::Session::Pase::PaseResponder.new(
        pin_code: 12345678_u32,
        pbkdf_params: params
      )
      response_bytes = responder.process_pbkdf_param_request(request_bytes)

      # Commissioner processes response
      commissioner.process_pbkdf_param_response(response_bytes)

      # Verify parameters were correctly transmitted
      commissioner.pbkdf_params.should_not be_nil
      commissioner.pbkdf_params.as(Matter::Session::Pase::PbkdfParameters).iterations.should eq(params.iterations)
      commissioner.pbkdf_params.as(Matter::Session::Pase::PbkdfParameters).salt.should eq(params.salt)
    end
  end

  describe "PaseCommissioner" do
    it "creates a commissioner with PIN" do
      commissioner = Matter::Session::Pase::PaseCommissioner.new(
        pin_code: 12345678_u32
      )

      commissioner.pin_code.should eq(12345678_u32)
      commissioner.spake.should be_nil
      commissioner.pbkdf_params.should be_nil
    end

    it "creates PBKDF param request" do
      commissioner = Matter::Session::Pase::PaseCommissioner.new(
        pin_code: 12345678_u32
      )

      request = commissioner.create_pbkdf_param_request
      request.should be_a(Bytes)
    end

    it "processes PBKDF params and initializes SPAKE2+" do
      commissioner = Matter::Session::Pase::PaseCommissioner.new(
        pin_code: 12345678_u32
      )

      params = Matter::Session::Pase::PbkdfParameters.default
      # Create a properly encoded PBKDF parameter response
      initiator_random = Random::Secure.random_bytes(32)
      responder_random = Random::Secure.random_bytes(32)
      response = Matter::Session::Pase::Definitions::PbkdfParamResponse.new(
        initiator_random: initiator_random,
        responder_random: responder_random,
        responder_session_id: 1000_u16,
        iterations: params.iterations.to_u32,
        salt: params.salt
      )
      commissioner.process_pbkdf_param_response(response.to_slice)

      commissioner.pbkdf_params.should_not be_nil
      commissioner.spake.should_not be_nil
    end

    it "generates pake1 (pA)" do
      commissioner = Matter::Session::Pase::PaseCommissioner.new(
        pin_code: 12345678_u32
      )

      params = Matter::Session::Pase::PbkdfParameters.default
      # Create a properly encoded PBKDF parameter response
      initiator_random = Random::Secure.random_bytes(32)
      responder_random = Random::Secure.random_bytes(32)
      response = Matter::Session::Pase::Definitions::PbkdfParamResponse.new(
        initiator_random: initiator_random,
        responder_random: responder_random,
        responder_session_id: 1000_u16,
        iterations: params.iterations.to_u32,
        salt: params.salt
      )
      commissioner.process_pbkdf_param_response(response.to_slice)

      p_a = commissioner.generate_pake1
      p_a.should be_a(Bytes)
      p_a.size.should eq(65) # Uncompressed EC point
      p_a[0].should eq(0x04) # Uncompressed marker
    end
  end

  describe "PaseResponder" do
    it "creates a responder with PIN and parameters" do
      params = Matter::Session::Pase::PbkdfParameters.default
      responder = Matter::Session::Pase::PaseResponder.new(
        pin_code: 12345678_u32,
        pbkdf_params: params
      )

      responder.pin_code.should eq(12345678_u32)
      responder.pbkdf_params.should eq(params)
      responder.spake.should be_nil
    end

    it "rejects an empty PBKDF param request" do
      responder = Matter::Session::Pase::PaseResponder.new(
        pin_code: 12345678_u32
      )

      expect_raises(Matter::ProtocolError) do
        responder.process_pbkdf_param_request(Bytes.new(0))
      end
    end

    it "processes pake1 and generates pake2 (pB)" do
      pin_code = 12345678_u32
      params = Matter::Session::Pase::PbkdfParameters.default

      # Create both commissioner and responder for valid protocol
      commissioner = Matter::Session::Pase::PaseCommissioner.new(pin_code: pin_code)
      responder = Matter::Session::Pase::PaseResponder.new(
        pin_code: pin_code,
        pbkdf_params: params
      )

      # Commissioner generates valid pA
      initiator_random = Random::Secure.random_bytes(32)
      responder_random = Random::Secure.random_bytes(32)
      response = Matter::Session::Pase::Definitions::PbkdfParamResponse.new(
        initiator_random: initiator_random,
        responder_random: responder_random,
        responder_session_id: 1000_u16,
        iterations: params.iterations.to_u32,
        salt: params.salt
      )
      commissioner.process_pbkdf_param_response(response.to_slice)
      p_a = commissioner.generate_pake1

      # Responder processes pA and generates pB
      p_b = responder.process_pake1(p_a)
      p_b.should be_a(Bytes)
      p_b.size.should eq(65)
      p_b[0].should eq(0x04)
    end

    it "generates pake3 confirmation" do
      pin_code = 12345678_u32
      params = Matter::Session::Pase::PbkdfParameters.default

      # Create both sides for valid protocol
      commissioner = Matter::Session::Pase::PaseCommissioner.new(pin_code: pin_code)
      responder = Matter::Session::Pase::PaseResponder.new(
        pin_code: pin_code,
        pbkdf_params: params
      )

      # Go through protocol steps to compute shared secret
      initiator_random = Random::Secure.random_bytes(32)
      responder_random = Random::Secure.random_bytes(32)
      response = Matter::Session::Pase::Definitions::PbkdfParamResponse.new(
        initiator_random: initiator_random,
        responder_random: responder_random,
        responder_session_id: 1000_u16,
        iterations: params.iterations.to_u32,
        salt: params.salt
      )
      commissioner.process_pbkdf_param_response(response.to_slice)
      p_a = commissioner.generate_pake1
      responder.process_pake1(p_a)

      # Now responder can generate confirmation
      confirmation = responder.generate_pake3
      confirmation.should be_a(Bytes)
      confirmation.size.should eq(32)
    end

    it "supports responder initialized from passcode verifier (w0||L)" do
      pin_code = 95305472_u32
      params = Matter::Session::Pase::PbkdfParameters.new(
        iterations: 1000,
        salt: Bytes.new(32) { |i| (i + 1).to_u8 }
      )

      crypto = Matter::Crypto::StandardCrypto.new
      w0_l = Matter::Crypto::Spake2p.compute_w0_l(
        crypto,
        Matter::Crypto::Spake2p::PbkdfParameters.new(params.iterations, params.salt),
        pin_code
      )

      w0_bytes = w0_l.w0.to_s(16).rjust(64, '0').hexbytes
      verifier = Bytes.new(97)
      32.times { |i| verifier[i] = w0_bytes[i] }
      65.times { |i| verifier[32 + i] = w0_l.l[i] }

      commissioner = Matter::Session::Pase::PaseCommissioner.new(pin_code: pin_code, crypto: crypto)
      responder = Matter::Session::Pase::PaseResponder.from_passcode_verifier(verifier, params, crypto)

      pbkdf_request = commissioner.create_pbkdf_param_request
      pbkdf_response = responder.process_pbkdf_param_request(pbkdf_request)
      commissioner.process_pbkdf_param_response(pbkdf_response)

      p_a = commissioner.generate_pake1
      p_b = responder.process_pake1(p_a)
      c_b = responder.generate_pake3
      c_a = commissioner.process_pake2(p_b)

      # Responder should accept commissioner's confirmation and commissioner should accept responder's.
      c_a.should eq(responder.secret_and_verifiers.as(Matter::Crypto::Spake2p::SecretAndVerifiers).h_ay)
      commissioner.process_pake3(c_b).should be_true
    end
  end

  describe "PASE session establishment" do
    it "establishes a PASE session between commissioner and responder" do
      pin_code = 12345678_u32
      initiator_session_id = 1000_u16
      responder_session_id = 2000_u16

      result = Matter::Session::Pase.establish_session(
        pin_code,
        initiator_session_id,
        responder_session_id
      )

      # Check initiator context
      result[:initiator].session_id.should eq(initiator_session_id)
      result[:initiator].peer_session_id.should eq(responder_session_id)
      result[:initiator].session_type.should eq(Matter::Session::SessionType::Unicast)
      result[:initiator].initiator?.should be_true
      result[:initiator].encryption_key.size.should eq(16)
      result[:initiator].decryption_key.size.should eq(16)

      # Check responder context
      result[:responder].session_id.should eq(responder_session_id)
      result[:responder].peer_session_id.should eq(initiator_session_id)
      result[:responder].session_type.should eq(Matter::Session::SessionType::Unicast)
      result[:responder].initiator?.should be_false
      result[:responder].encryption_key.size.should eq(16)
      result[:responder].decryption_key.size.should eq(16)
    end

    it "allows multiple PASE sessions with different PINs" do
      pin1 = 11111111_u32
      pin2 = 22222222_u32

      session1 = Matter::Session::Pase.establish_session(pin1, 100_u16, 200_u16)
      session2 = Matter::Session::Pase.establish_session(pin2, 300_u16, 400_u16)

      session1[:initiator].session_id.should eq(100_u16)
      session2[:initiator].session_id.should eq(300_u16)

      # Keys should be different (since PINs are different)
      session1[:initiator].encryption_key.should_not eq(session2[:initiator].encryption_key)
    end
  end
end
