require "../spec_helper"
require "../../src/matter/device/persistence"

private alias DoorLock = Matter::Cluster::DoorLock

private def persistent_lock : DoorLock
  build(DoorLock,
    feature_map: DoorLock::Feature::PinCredential | DoorLock::Feature::CredentialOverTheAirAccess |
                 DoorLock::Feature::User | DoorLock::Feature::WeekDayAccessSchedules |
                 DoorLock::Feature::YearDayAccessSchedules | DoorLock::Feature::HolidaySchedules,
    require_pin_for_remote_operation: true,
    default_pin_code: "9999")
end

describe Matter::Cluster::DoorLock do
  it "restores a user, credential, schedules, fabric attribution, and PIN authorization" do
    first = persistent_lock
    first.request_fabric_index = 1_u8

    expect_success(invoke(first, DoorLock::CMD_SET_USER, DoorLock::SetUserRequest.new(
      operation_type: DoorLock::DataOperationType::Add,
      user_index: 2_u16,
      user_name: "Guest",
      user_unique_id: 222_u32,
      user_status: DoorLock::UserStatus::OccupiedEnabled,
      user_type: DoorLock::UserType::UnrestrictedUser,
      credential_rule: DoorLock::CredentialRule::Single
    ), fabric_index: 1_u8))

    credential = DoorLock::Credential.new(DoorLock::CredentialType::Pin, 1_u16)
    result = invoke(first, DoorLock::CMD_SET_CREDENTIAL, DoorLock::SetCredentialRequest.new(
      DoorLock::DataOperationType::Add, credential, "2468".to_slice,
      user_index: 2_u16), fabric_index: 1_u8)
    DoorLock::SetCredentialResponse.from_tlv(result.as(Matter::Cluster::CommandResponse).response.as(TLV::Any)).status_code.should eq(DoorLock::StatusCode::Success)

    expect_success(invoke(first, DoorLock::CMD_SET_WEEK_DAY_SCHEDULE,
      DoorLock::SetWeekDayScheduleRequest.new(1_u8, 2_u16, 0x3E_u8, 9_u8, 0_u8, 17_u8, 0_u8)))
    expect_success(invoke(first, DoorLock::CMD_SET_YEAR_DAY_SCHEDULE,
      DoorLock::SetYearDayScheduleRequest.new(1_u8, 2_u16, 100_u32, 200_u32)))
    expect_success(invoke(first, DoorLock::CMD_SET_HOLIDAY_SCHEDULE,
      DoorLock::SetHolidayScheduleRequest.new(1_u8, 100_u32, 200_u32, DoorLock::OperatingMode::Vacation)))

    path = File.join(Dir.tempdir, "matter-door-lock-#{Random::Secure.hex(6)}.yml")
    persistence = Matter::Device::Persistence.new(Matter::Storage::YamlFile.new(path))
    persistence.track(first)
    persistence.save_cluster(first).should be_true
    persistence.close

    restored = persistent_lock
    reopened = Matter::Device::Persistence.new(Matter::Storage::YamlFile.new(path))
    reopened.restore_clusters([restored] of Matter::Cluster::Base).should eq(1)
    restored.data_version.should eq(first.data_version)

    user = restored.get_user(DoorLock::GetUserRequest.new(2_u16))
    user.user_name.should eq("Guest")
    user.creator_fabric_index.should eq(1_u8)
    user.credentials.should eq([credential])

    status = restored.get_credential_status(DoorLock::GetCredentialStatusRequest.new(credential))
    status.credential_exists?.should be_true
    status.user_index.should eq(2_u16)
    status.creator_fabric_index.should eq(1_u8)

    restored.get_week_day_schedule(DoorLock::GetWeekDayScheduleRequest.new(1_u8, 2_u16)).status_code.should eq(DoorLock::StatusCode::Success)
    restored.get_year_day_schedule(DoorLock::GetYearDayScheduleRequest.new(1_u8, 2_u16)).status_code.should eq(DoorLock::StatusCode::Success)
    restored.get_holiday_schedule(DoorLock::GetHolidayScheduleRequest.new(1_u8)).status_code.should eq(DoorLock::StatusCode::Success)

    expect_success(invoke(restored, DoorLock::CMD_UNLOCK_DOOR,
      DoorLock::UnlockDoorRequest.new("2468".to_slice)))
    reopened.close
  ensure
    File.delete?(path) if path
  end

  it "keeps the constructed user database when a stored document is malformed" do
    original = persistent_lock
    document = original.save_state.as(Matter::Storage::Document)
    document[DoorLock::PERSISTED_DATABASE_KEY] = "invalid"

    restored = persistent_lock
    restored.restore_state(document)
    restored.get_user(DoorLock::GetUserRequest.new(1_u16)).user_name.should eq("Admin")
    restored.get_user(DoorLock::GetUserRequest.new(2_u16)).user_status.should eq(DoorLock::UserStatus::Available)
  end

  it "does not grant remote access to a disabled user after restore" do
    original = persistent_lock
    expect_success(invoke(original, DoorLock::CMD_SET_USER, DoorLock::SetUserRequest.new(
      operation_type: DoorLock::DataOperationType::Add,
      user_index: 2_u16,
      user_status: DoorLock::UserStatus::OccupiedDisabled
    )))
    credential = DoorLock::Credential.new(DoorLock::CredentialType::Pin, 1_u16)
    result = invoke(original, DoorLock::CMD_SET_CREDENTIAL, DoorLock::SetCredentialRequest.new(
      DoorLock::DataOperationType::Add, credential, "2468".to_slice, user_index: 2_u16))
    DoorLock::SetCredentialResponse.from_tlv(result.as(Matter::Cluster::CommandResponse).response.as(TLV::Any)).status_code.should eq(DoorLock::StatusCode::Success)

    restored = persistent_lock
    restored.restore_state(original.save_state.as(Matter::Storage::Document))
    expect_status(invoke(restored, DoorLock::CMD_UNLOCK_DOOR,
      DoorLock::UnlockDoorRequest.new("2468".to_slice)), Matter::InteractionModel::StatusCode::Failure)
  end
end
