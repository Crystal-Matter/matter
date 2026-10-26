require "../spec_helper"

private alias DuplicateDoorLock = Matter::Cluster::DoorLock

private class DuplicateTestVerifier < DuplicateDoorLock::LocalCredentialVerifier
  def ready_for?(type : DuplicateDoorLock::CredentialType) : Bool
    type.rfid?
  end

  def authenticate(type : DuplicateDoorLock::CredentialType, transaction : Bytes) : DuplicateDoorLock::LocalAuthenticatedCredential?
    nil
  end
end

private def duplicate_lock : DuplicateDoorLock
  build(DuplicateDoorLock,
    feature_map: DuplicateDoorLock::Feature::PinCredential |
                 DuplicateDoorLock::Feature::RfidCredential |
                 DuplicateDoorLock::Feature::User,
    local_credential_verifier: DuplicateTestVerifier.new,
    default_pin_code: "9999")
end

private def duplicate_credential(type : DuplicateDoorLock::CredentialType, index : UInt16) : DuplicateDoorLock::Credential
  DuplicateDoorLock::Credential.new(type, index)
end

private def add_duplicate_user(lock : DuplicateDoorLock, index : UInt16) : Nil
  lock.handle_set_user(DuplicateDoorLock::SetUserRequest.new(
    DuplicateDoorLock::DataOperationType::Add, index)).success?.should be_true
end

private def set_duplicate_credential(lock : DuplicateDoorLock, operation : DuplicateDoorLock::DataOperationType,
                                     credential : DuplicateDoorLock::Credential, data : String, user_index : UInt16) : DuplicateDoorLock::SetCredentialResponse
  lock.handle_set_credential(DuplicateDoorLock::SetCredentialRequest.new(
    operation, credential, data.to_slice, user_index: user_index))
end

describe "Door Lock duplicate credential values" do
  [DuplicateDoorLock::CredentialType::Pin, DuplicateDoorLock::CredentialType::Rfid].each do |type|
    it "rejects a duplicate #{type} on Add without creating the second user" do
      lock = duplicate_lock
      first = duplicate_credential(type, 1_u16)
      second = duplicate_credential(type, 2_u16)
      add_duplicate_user(lock, 2_u16)
      set_duplicate_credential(lock, DuplicateDoorLock::DataOperationType::Add, first, "1357", 2_u16)
        .status_code.should eq(DuplicateDoorLock::StatusCode::Success)

      set_duplicate_credential(lock, DuplicateDoorLock::DataOperationType::Add, second, "1357", 3_u16)
        .status_code.should eq(DuplicateDoorLock::StatusCode::Duplicate)
      lock.get_credential_status(DuplicateDoorLock::GetCredentialStatusRequest.new(second))
        .credential_exists?.should be_false
      lock.get_user(DuplicateDoorLock::GetUserRequest.new(3_u16)).user_status
        .should eq(DuplicateDoorLock::UserStatus::Available)
    end

    it "rejects a duplicate #{type} on Modify without changing either credential" do
      lock = duplicate_lock
      first = duplicate_credential(type, 1_u16)
      second = duplicate_credential(type, 2_u16)
      add_duplicate_user(lock, 2_u16)
      add_duplicate_user(lock, 3_u16)
      set_duplicate_credential(lock, DuplicateDoorLock::DataOperationType::Add, first, "1357", 2_u16)
        .status_code.should eq(DuplicateDoorLock::StatusCode::Success)
      set_duplicate_credential(lock, DuplicateDoorLock::DataOperationType::Add, second, "2468", 3_u16)
        .status_code.should eq(DuplicateDoorLock::StatusCode::Success)
      before = lock.save_state

      set_duplicate_credential(lock, DuplicateDoorLock::DataOperationType::Modify, second, "1357", 3_u16)
        .status_code.should eq(DuplicateDoorLock::StatusCode::Duplicate)
      lock.save_state.should eq(before)
      set_duplicate_credential(lock, DuplicateDoorLock::DataOperationType::Modify, second, "2468", 3_u16)
        .status_code.should eq(DuplicateDoorLock::StatusCode::Success)
    end
  end

  it "keeps PIN and RFID values in separate credential types" do
    lock = duplicate_lock
    pin = duplicate_credential(DuplicateDoorLock::CredentialType::Pin, 1_u16)
    rfid = duplicate_credential(DuplicateDoorLock::CredentialType::Rfid, 1_u16)
    add_duplicate_user(lock, 2_u16)
    add_duplicate_user(lock, 3_u16)
    set_duplicate_credential(lock, DuplicateDoorLock::DataOperationType::Add, pin, "1357", 2_u16)
      .status_code.should eq(DuplicateDoorLock::StatusCode::Success)
    set_duplicate_credential(lock, DuplicateDoorLock::DataOperationType::Add, rfid, "1357", 3_u16)
      .status_code.should eq(DuplicateDoorLock::StatusCode::Success)
  end

  [DuplicateDoorLock::CredentialType::Pin, DuplicateDoorLock::CredentialType::Rfid].each do |type|
    it "rejects duplicate persisted #{type} data before changing live state" do
      original = duplicate_lock
      first = duplicate_credential(type, 1_u16)
      second = duplicate_credential(type, 2_u16)
      add_duplicate_user(original, 2_u16)
      add_duplicate_user(original, 3_u16)
      set_duplicate_credential(original, DuplicateDoorLock::DataOperationType::Add, first, "1357", 2_u16)
      set_duplicate_credential(original, DuplicateDoorLock::DataOperationType::Add, second, "2468", 3_u16)
      document = original.save_state.as(Matter::Storage::Document)
      database = DuplicateDoorLock::PersistedDatabase.from_document(
        document[DuplicateDoorLock::PERSISTED_DATABASE_KEY].as(Matter::Storage::Document))
      records = database.credentials
      second_index = records.index! { |record| record.credential.credential_type == type && record.credential.credential_index == 2_u16 }
      duplicate = records[second_index]
      duplicate.credential_data = "1357".to_slice
      records[second_index] = duplicate
      document[DuplicateDoorLock::PERSISTED_DATABASE_KEY] = DuplicateDoorLock::PersistedDatabase.new(
        database.users, records, database.week_day_schedules, database.year_day_schedules,
        database.holiday_schedules, database.aliro_reader_config).to_document

      restored = duplicate_lock
      add_duplicate_user(restored, 2_u16)
      set_duplicate_credential(restored, DuplicateDoorLock::DataOperationType::Add, first, "8642", 2_u16)
      before = restored.save_state
      restored.restore_state(document)
      restored.save_state.should eq(before)
    end
  end
end
