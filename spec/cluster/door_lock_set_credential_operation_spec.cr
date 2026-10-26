require "../spec_helper"

private alias CredentialDoorLock = Matter::Cluster::DoorLock

describe "Door Lock SetCredential operation constraint" do
  it "rejects Clear without changing a credential and leaves ClearCredential operational" do
    lock = build(CredentialDoorLock)
    credential = CredentialDoorLock::Credential.new(CredentialDoorLock::CredentialType::Pin, 1_u16)
    add = CredentialDoorLock::SetCredentialRequest.new(
      operation_type: CredentialDoorLock::DataOperationType::Add,
      credential: credential,
      credential_data: "1357".to_slice,
      user_index: 2_u16)
    invoke_response(lock, CredentialDoorLock::CMD_SET_CREDENTIAL, add,
      CredentialDoorLock::SetCredentialResponse).status_code.should eq(CredentialDoorLock::StatusCode::Success)

    emitted = [] of UInt32
    lock.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, event : UInt32, _priority : Matter::InteractionModel::EventPriority, _data : TLV::Any, _fabric : UInt8?) do
      emitted << event
      nil
    end
    version = lock.data_version
    clear_via_set = CredentialDoorLock::SetCredentialRequest.new(
      operation_type: CredentialDoorLock::DataOperationType::Clear,
      credential: credential,
      credential_data: "1357".to_slice,
      user_index: 2_u16)

    invoke_response(lock, CredentialDoorLock::CMD_SET_CREDENTIAL, clear_via_set,
      CredentialDoorLock::SetCredentialResponse).status_code.should eq(CredentialDoorLock::StatusCode::InvalidField)
    lock.data_version.should eq(version)
    emitted.should be_empty
    lock.get_credential_status(CredentialDoorLock::GetCredentialStatusRequest.new(credential))
      .credential_exists?.should be_true
    lock.get_user(CredentialDoorLock::GetUserRequest.new(2_u16))
      .credentials.should eq([credential])

    expect_success(invoke(lock, CredentialDoorLock::CMD_CLEAR_CREDENTIAL,
      CredentialDoorLock::ClearCredentialRequest.new(credential)))
    lock.get_credential_status(CredentialDoorLock::GetCredentialStatusRequest.new(credential))
      .credential_exists?.should be_false
    lock.get_user(CredentialDoorLock::GetUserRequest.new(2_u16)).credentials.should be_nil
  end
end
