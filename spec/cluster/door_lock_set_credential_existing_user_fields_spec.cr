require "../spec_helper"

private alias FieldsDoorLock = Matter::Cluster::DoorLock

private def set_existing_user_credential(lock : FieldsDoorLock, status : FieldsDoorLock::UserStatus?,
                                         user_type : FieldsDoorLock::UserType?) : FieldsDoorLock::SetCredentialResponse
  request = FieldsDoorLock::SetCredentialRequest.new(
    FieldsDoorLock::DataOperationType::Add,
    FieldsDoorLock::Credential.new(FieldsDoorLock::CredentialType::Pin, 1_u16),
    "1357".to_slice,
    user_index: 2_u16,
    user_status: status,
    user_type: user_type
  )
  result = invoke(lock, FieldsDoorLock::CMD_SET_CREDENTIAL, request, fabric_index: 1_u8)
  result.should be_a(Matter::Cluster::CommandResponse)
  FieldsDoorLock::SetCredentialResponse.from_tlv(result.as(Matter::Cluster::CommandResponse).response.as(TLV::Any))
end

describe "Door Lock SetCredential Add for an existing user" do
  it "rejects non-null UserStatus without mutation" do
    lock = build(FieldsDoorLock, default_pin_code: "9999")
    expect_success(invoke(lock, FieldsDoorLock::CMD_SET_USER,
      FieldsDoorLock::SetUserRequest.new(FieldsDoorLock::DataOperationType::Add, 2_u16), fabric_index: 1_u8))
    before = lock.save_state
    version = lock.data_version

    response = set_existing_user_credential(lock, FieldsDoorLock::UserStatus::OccupiedEnabled, nil)

    response.status_code.should eq(FieldsDoorLock::StatusCode::InvalidField)
    lock.save_state.should eq(before)
    lock.data_version.should eq(version)
  end

  it "rejects non-null UserType without mutation" do
    lock = build(FieldsDoorLock, default_pin_code: "9999")
    expect_success(invoke(lock, FieldsDoorLock::CMD_SET_USER,
      FieldsDoorLock::SetUserRequest.new(FieldsDoorLock::DataOperationType::Add, 2_u16), fabric_index: 1_u8))
    before = lock.save_state
    version = lock.data_version

    response = set_existing_user_credential(lock, nil, FieldsDoorLock::UserType::UnrestrictedUser)

    response.status_code.should eq(FieldsDoorLock::StatusCode::InvalidField)
    lock.save_state.should eq(before)
    lock.data_version.should eq(version)
  end
end
