require "../spec_helper"

private alias TypeDoorLock = Matter::Cluster::DoorLock

describe "Door Lock SetCredential UserType constraint" do
  [TypeDoorLock::UserType::YearDayScheduleUser,
   TypeDoorLock::UserType::WeekDayScheduleUser,
   TypeDoorLock::UserType::ScheduleRestrictedUser].each do |user_type|
    it "rejects #{user_type} without creating a user or credential" do
      lock = build(TypeDoorLock, default_pin_code: "9999")
      credential = TypeDoorLock::Credential.new(TypeDoorLock::CredentialType::Pin, 1_u16)
      request = TypeDoorLock::SetCredentialRequest.new(
        TypeDoorLock::DataOperationType::Add,
        credential,
        "1357".to_slice,
        user_index: 2_u16,
        user_status: TypeDoorLock::UserStatus::OccupiedEnabled,
        user_type: user_type
      )
      before = lock.save_state
      version = lock.data_version

      result = invoke(lock, TypeDoorLock::CMD_SET_CREDENTIAL, request, fabric_index: 1_u8)

      result.should be_a(Matter::Cluster::CommandResponse)
      response = TypeDoorLock::SetCredentialResponse.from_tlv(
        result.as(Matter::Cluster::CommandResponse).response.as(TLV::Any))
      response.status_code.should eq(TypeDoorLock::StatusCode::InvalidField)
      lock.save_state.should eq(before)
      lock.data_version.should eq(version)
      lock.get_credential_status(TypeDoorLock::GetCredentialStatusRequest.new(credential)).credential_exists?.should be_false
    end
  end
end
