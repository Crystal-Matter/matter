require "../spec_helper"

private alias StatusDoorLock = Matter::Cluster::DoorLock

describe "Door Lock SetCredential UserStatus constraint" do
  it "rejects Available for a newly created user without changing state" do
    lock = build(StatusDoorLock, default_pin_code: "9999")
    credential = StatusDoorLock::Credential.new(StatusDoorLock::CredentialType::Pin, 1_u16)
    request = StatusDoorLock::SetCredentialRequest.new(
      StatusDoorLock::DataOperationType::Add,
      credential,
      "1357".to_slice,
      user_index: nil,
      user_status: StatusDoorLock::UserStatus::Available,
      user_type: StatusDoorLock::UserType::UnrestrictedUser
    )
    before = lock.save_state
    version = lock.data_version

    result = invoke(lock, StatusDoorLock::CMD_SET_CREDENTIAL, request, fabric_index: 1_u8)

    result.should be_a(Matter::Cluster::CommandResponse)
    response = StatusDoorLock::SetCredentialResponse.from_tlv(
      result.as(Matter::Cluster::CommandResponse).response.as(TLV::Any))
    response.status_code.should eq(StatusDoorLock::StatusCode::InvalidField)
    lock.save_state.should eq(before)
    lock.data_version.should eq(version)
    lock.get_credential_status(StatusDoorLock::GetCredentialStatusRequest.new(credential)).credential_exists?.should be_false
  end
end
