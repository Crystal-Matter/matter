require "../spec_helper"

private alias MissingUserDoorLock = Matter::Cluster::DoorLock

private def add_missing_user_pin(lock : MissingUserDoorLock) : MissingUserDoorLock::SetCredentialResponse
  request = MissingUserDoorLock::SetCredentialRequest.new(
    MissingUserDoorLock::DataOperationType::Add,
    MissingUserDoorLock::Credential.new(MissingUserDoorLock::CredentialType::Pin, 1_u16),
    "1357".to_slice,
    user_index: 2_u16
  )
  result = invoke(lock, MissingUserDoorLock::CMD_SET_CREDENTIAL, request, fabric_index: 1_u8)
  result.should be_a(Matter::Cluster::CommandResponse)
  MissingUserDoorLock::SetCredentialResponse.from_tlv(result.as(Matter::Cluster::CommandResponse).response.as(TLV::Any))
end

describe "Door Lock Add credential with a specified UserIndex" do
  it "requires the user to exist before adding the credential" do
    lock = build(MissingUserDoorLock, default_pin_code: "9999")
    credential = MissingUserDoorLock::Credential.new(MissingUserDoorLock::CredentialType::Pin, 1_u16)
    before = lock.save_state
    version = lock.data_version

    add_missing_user_pin(lock).status_code.should eq(MissingUserDoorLock::StatusCode::InvalidField)
    lock.save_state.should eq(before)
    lock.data_version.should eq(version)
    lock.get_credential_status(MissingUserDoorLock::GetCredentialStatusRequest.new(credential)).credential_exists?.should be_false

    expect_success(invoke(lock, MissingUserDoorLock::CMD_SET_USER,
      MissingUserDoorLock::SetUserRequest.new(MissingUserDoorLock::DataOperationType::Add, 2_u16), fabric_index: 1_u8))
    add_missing_user_pin(lock).status_code.should eq(MissingUserDoorLock::StatusCode::Success)
    lock.get_credential_status(MissingUserDoorLock::GetCredentialStatusRequest.new(credential)).user_index.should eq(2_u16)
  end
end
