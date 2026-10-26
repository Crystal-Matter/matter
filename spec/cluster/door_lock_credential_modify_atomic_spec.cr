require "../spec_helper"

private alias AtomicDoorLock = Matter::Cluster::DoorLock

private def atomic_credential_response(lock : AtomicDoorLock, request : AtomicDoorLock::SetCredentialRequest,
                                       fabric_index : UInt8) : AtomicDoorLock::SetCredentialResponse
  result = invoke(lock, AtomicDoorLock::CMD_SET_CREDENTIAL, request, fabric_index: fabric_index)
  result.should be_a(Matter::Cluster::CommandResponse)
  AtomicDoorLock::SetCredentialResponse.from_tlv(result.as(Matter::Cluster::CommandResponse).response.as(TLV::Any))
end

private def atomic_pin_request(operation : AtomicDoorLock::DataOperationType, index : UInt16,
                               data : String, user_index : UInt16) : AtomicDoorLock::SetCredentialRequest
  AtomicDoorLock::SetCredentialRequest.new(operation,
    AtomicDoorLock::Credential.new(AtomicDoorLock::CredentialType::Pin, index),
    data.to_slice, user_index: user_index)
end

describe "Door Lock SetCredential Modify atomicity" do
  it "keeps the user association when modifying credential data" do
    lock = build(AtomicDoorLock, default_pin_code: "9999")
    expect_success(invoke(lock, AtomicDoorLock::CMD_SET_USER,
      AtomicDoorLock::SetUserRequest.new(AtomicDoorLock::DataOperationType::Add, 2_u16),
      fabric_index: 1_u8))
    credential = AtomicDoorLock::Credential.new(AtomicDoorLock::CredentialType::Pin, 1_u16)
    atomic_credential_response(lock,
      atomic_pin_request(AtomicDoorLock::DataOperationType::Add, 1_u16, "1357", 2_u16), 1_u8)
      .status_code.should eq(AtomicDoorLock::StatusCode::Success)

    atomic_credential_response(lock,
      atomic_pin_request(AtomicDoorLock::DataOperationType::Modify, 1_u16, "8642", 2_u16), 1_u8)
      .status_code.should eq(AtomicDoorLock::StatusCode::Success)

    lock.get_user(AtomicDoorLock::GetUserRequest.new(2_u16)).credentials.should eq([credential])
    lock.get_credential_status(AtomicDoorLock::GetCredentialStatusRequest.new(credential))
      .user_index.should eq(2_u16)
    lock.unlock(pin: "8642").success?.should be_true
    lock.lock(pin: "1357").success?.should be_false
  end

  it "leaves both users and the credential unchanged when the destination is full" do
    lock = build(AtomicDoorLock, number_of_credentials_supported_per_user: 1_u8,
      default_pin_code: "9999")
    [2_u16, 3_u16].each do |index|
      expect_success(invoke(lock, AtomicDoorLock::CMD_SET_USER,
        AtomicDoorLock::SetUserRequest.new(AtomicDoorLock::DataOperationType::Add, index),
        fabric_index: 1_u8))
      atomic_credential_response(lock,
        atomic_pin_request(AtomicDoorLock::DataOperationType::Add, index - 1_u16,
          index == 2_u16 ? "1357" : "2468", index), 1_u8)
        .status_code.should eq(AtomicDoorLock::StatusCode::Success)
    end

    before = lock.save_state
    version = lock.data_version
    events = [] of UInt32
    lock.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, event : UInt32, _priority : Matter::InteractionModel::EventPriority, _data : TLV::Any, _fabric : UInt8?) {
      events << event
      nil
    }

    response = atomic_credential_response(lock,
      atomic_pin_request(AtomicDoorLock::DataOperationType::Modify, 1_u16, "8642", 3_u16), 2_u8)

    response.status_code.should eq(AtomicDoorLock::StatusCode::ResourceExhausted)
    lock.save_state.should eq(before)
    lock.data_version.should eq(version)
    events.should be_empty
    lock.get_user(AtomicDoorLock::GetUserRequest.new(2_u16)).last_modified_fabric_index.should eq(1_u8)
  end
end
