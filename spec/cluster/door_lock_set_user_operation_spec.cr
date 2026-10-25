require "../spec_helper"

private alias UserOperationDoorLock = Matter::Cluster::DoorLock

describe "Door Lock SetUser operation constraint" do
  it "rejects Clear without changing the user and leaves ClearUser operational" do
    lock = build(UserOperationDoorLock)
    user_index = 2_u16
    credential = UserOperationDoorLock::Credential.new(UserOperationDoorLock::CredentialType::Pin, 1_u16)
    expect_success(invoke(lock, UserOperationDoorLock::CMD_SET_USER,
      UserOperationDoorLock::SetUserRequest.new(UserOperationDoorLock::DataOperationType::Add,
        user_index, user_name: "Guest")))
    add_credential = UserOperationDoorLock::SetCredentialRequest.new(
      operation_type: UserOperationDoorLock::DataOperationType::Add,
      credential: credential,
      credential_data: "1357".to_slice,
      user_index: user_index)
    invoke_response(lock, UserOperationDoorLock::CMD_SET_CREDENTIAL, add_credential,
      UserOperationDoorLock::SetCredentialResponse).status_code.should eq(UserOperationDoorLock::StatusCode::Success)

    emitted = [] of UInt32
    lock.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, event : UInt32, _priority : Matter::InteractionModel::EventPriority, _data : TLV::Any, _fabric : UInt8?) do
      emitted << event
      nil
    end
    version = lock.data_version
    clear_via_set = UserOperationDoorLock::SetUserRequest.new(
      UserOperationDoorLock::DataOperationType::Clear, user_index)

    status = expect_status(invoke(lock, UserOperationDoorLock::CMD_SET_USER, clear_via_set),
      Matter::InteractionModel::StatusCode::Failure)
    status.cluster_status.should eq(UserOperationDoorLock::StatusCode::InvalidField.value)
    lock.data_version.should eq(version)
    emitted.should be_empty
    user = lock.get_user(UserOperationDoorLock::GetUserRequest.new(user_index))
    user.user_name.should eq("Guest")
    user.credentials.should eq([credential])
    lock.get_credential_status(UserOperationDoorLock::GetCredentialStatusRequest.new(credential))
      .credential_exists?.should be_true

    expect_success(invoke(lock, UserOperationDoorLock::CMD_CLEAR_USER,
      UserOperationDoorLock::ClearUserRequest.new(user_index)))
    lock.get_user(UserOperationDoorLock::GetUserRequest.new(user_index)).user_name.should be_nil
    lock.get_credential_status(UserOperationDoorLock::GetCredentialStatusRequest.new(credential))
      .credential_exists?.should be_false
  end
end
