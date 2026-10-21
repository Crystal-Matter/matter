require "../../spec_helper"

describe Matter::Session::Pase::PaseResponder do
  it "rejects PBKDF requests missing mandatory fields or using a nondefault passcode ID" do
    responder = Matter::Session::Pase::PaseResponder.new(pin_code: 20_202_021_u32)
    random = Bytes.new(32, 0x42_u8)
    valid = Matter::Session::Pase::Definitions::PbkdfParamRequest.new(
      initiator_random: random,
      initiator_session_id: 1_u16,
      passcode_id: 0_u16,
      has_pbkdf_parameters: false)
    responder.process_pbkdf_param_request(valid.to_slice).should_not be_empty

    invalid = [
      Matter::Session::Pase::Definitions::PbkdfParamRequest.new(
        initiator_session_id: 1_u16, passcode_id: 0_u16, has_pbkdf_parameters: false),
      Matter::Session::Pase::Definitions::PbkdfParamRequest.new(
        initiator_random: random, passcode_id: 0_u16, has_pbkdf_parameters: false),
      Matter::Session::Pase::Definitions::PbkdfParamRequest.new(initiator_random: random,
        initiator_session_id: 1_u16, has_pbkdf_parameters: false),
      Matter::Session::Pase::Definitions::PbkdfParamRequest.new(initiator_random: random,
        initiator_session_id: 1_u16, passcode_id: 0_u16),
      Matter::Session::Pase::Definitions::PbkdfParamRequest.new(initiator_random: Bytes.new(31, 0x42_u8),
        initiator_session_id: 1_u16, passcode_id: 0_u16, has_pbkdf_parameters: false),
      Matter::Session::Pase::Definitions::PbkdfParamRequest.new(initiator_random: random,
        initiator_session_id: 1_u16, passcode_id: 1_u16, has_pbkdf_parameters: false),
    ]
    invalid.each do |request|
      expect_raises(Matter::ProtocolError) do
        responder.process_pbkdf_param_request(request.to_slice)
      end
    end
    expect_raises(Matter::ProtocolError) do
      responder.process_pbkdf_param_request(Bytes[0xff])
    end

    cached = Matter::Session::Pase::Definitions::PbkdfParamRequest.new(
      initiator_random: random, initiator_session_id: 1_u16,
      passcode_id: 0_u16, has_pbkdf_parameters: true)
    response = Matter::Session::Pase::Definitions::PbkdfParamResponse.from_slice(
      responder.process_pbkdf_param_request(cached.to_slice))
    response.pbkdf_parameters.should be_nil
  end
end
