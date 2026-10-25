require "../spec_helper"

private alias VerifiedDoorLock = Matter::Cluster::DoorLock

private class TestLocalCredentialVerifier < VerifiedDoorLock::LocalCredentialVerifier
  property authenticated : VerifiedDoorLock::LocalAuthenticatedCredential? = nil
  property? ready : Bool = true
  property? fail_authentication : Bool = false
  property on_authenticate : Proc(Nil)? = nil

  def ready_for?(type : VerifiedDoorLock::CredentialType) : Bool
    @ready && {VerifiedDoorLock::CredentialType::Rfid, VerifiedDoorLock::CredentialType::Fingerprint,
               VerifiedDoorLock::CredentialType::FingerVein, VerifiedDoorLock::CredentialType::Face}.includes?(type)
  end

  def authenticate(type : VerifiedDoorLock::CredentialType, transaction : Bytes) : VerifiedDoorLock::LocalAuthenticatedCredential?
    raise "reader authentication failed" if @fail_authentication
    @on_authenticate.try(&.call)
    @authenticated
  end
end

private def verified_credential_lock(features : VerifiedDoorLock::Feature, verifier : TestLocalCredentialVerifier? = TestLocalCredentialVerifier.new,
                                     clock : Proc(Time?) = -> : Time? { Time.local }) : VerifiedDoorLock
  build(VerifiedDoorLock,
    feature_map: VerifiedDoorLock::Feature::User | features,
    local_credential_verifier: verifier,
    default_pin_code: "9999",
    local_time_provider: clock)
end

private def provision_verified_credential(lock : VerifiedDoorLock, type : VerifiedDoorLock::CredentialType,
                                          user_type : VerifiedDoorLock::UserType = VerifiedDoorLock::UserType::UnrestrictedUser) : VerifiedDoorLock::Credential
  credential = VerifiedDoorLock::Credential.new(type, 1_u16)
  response = lock.handle_set_credential(VerifiedDoorLock::SetCredentialRequest.new(
    VerifiedDoorLock::DataOperationType::Add, credential, "1357".to_slice, 2_u16,
    VerifiedDoorLock::UserStatus::OccupiedEnabled, user_type))
  response.status_code.should eq(VerifiedDoorLock::StatusCode::Success)
  credential
end

private def authenticated_credential(credential : VerifiedDoorLock::Credential, data : String = "1357") : VerifiedDoorLock::LocalAuthenticatedCredential
  VerifiedDoorLock::LocalAuthenticatedCredential.new(credential, data.to_slice)
end

describe "Door Lock trusted local credential verification" do
  it "blocks an exterior RFID reader in Privacy mode" do
    verifier = TestLocalCredentialVerifier.new
    lock = build(VerifiedDoorLock,
      feature_map: VerifiedDoorLock::Feature::User | VerifiedDoorLock::Feature::RfidCredential,
      local_credential_verifier: verifier,
      supported_operating_modes: 0xFFE2_u16,
      operating_mode: VerifiedDoorLock::OperatingMode::Privacy)
    credential = provision_verified_credential(lock, VerifiedDoorLock::CredentialType::Rfid)
    verifier.authenticated = authenticated_credential(credential)

    lock.perform_local_credential_transaction(VerifiedDoorLock::CredentialType::Rfid, Bytes[0x42]).success?.should be_false
    lock.locked?.should be_true
  end

  {VerifiedDoorLock::Feature::RfidCredential, VerifiedDoorLock::Feature::FingerCredentials,
   VerifiedDoorLock::Feature::FaceCredentials}.each do |feature|
    it "rejects advertised #{feature} without a ready verifier" do
      expect_raises(ArgumentError, /verifier/) { verified_credential_lock(feature, nil) }
      unavailable = TestLocalCredentialVerifier.new
      unavailable.ready = false
      expect_raises(ArgumentError, /not ready/) { verified_credential_lock(feature, unavailable) }
      verified_credential_lock(feature).feature_map.includes?(feature).should be_true
    end
  end

  it "does not let a caller label a remote unlock as RFID or biometric authentication" do
    rfid = verified_credential_lock(VerifiedDoorLock::Feature::RfidCredential)
    rfid.unlock(source: VerifiedDoorLock::OperationSource::Rfid).success?.should be_false
    rfid.locked?.should be_true

    finger = verified_credential_lock(VerifiedDoorLock::Feature::FingerCredentials)
    finger.unlock(source: VerifiedDoorLock::OperationSource::Biometric).success?.should be_false
    finger.locked?.should be_true
  end

  it "uses a verified RFID identity to unlock and reports the stored user and credential" do
    verifier = TestLocalCredentialVerifier.new
    lock = verified_credential_lock(VerifiedDoorLock::Feature::RfidCredential, verifier)
    credential = provision_verified_credential(lock, VerifiedDoorLock::CredentialType::Rfid)
    events = [] of Tuple(UInt32, TLV::Any)
    lock.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, event : UInt32, _priority : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) do
      events << {event, data}
      nil
    end

    lock.perform_local_credential_transaction(VerifiedDoorLock::CredentialType::Rfid, Bytes[0xA1]).success?.should be_false
    lock.locked?.should be_true
    verifier.authenticated = authenticated_credential(credential)
    lock.perform_local_credential_transaction(VerifiedDoorLock::CredentialType::Rfid, Bytes[0xA2]).success?.should be_true
    lock.unlocked?.should be_true

    payload = events.find! { |id, _| id == VerifiedDoorLock::EVENT_LOCK_OPERATION }[1]
    operation = VerifiedDoorLock::Events::LockOperation.from_tlv(payload)
    operation.operation_source.should eq(VerifiedDoorLock::OperationSource::Rfid)
    operation.user_index.should eq(2_u16)
    operation.credentials.should eq([credential])
    operation.fabric_index.should be_nil
  end

  it "fails closed when verification raises or returns a credential that is absent" do
    verifier = TestLocalCredentialVerifier.new
    lock = verified_credential_lock(VerifiedDoorLock::Feature::RfidCredential, verifier)
    verifier.fail_authentication = true
    lock.perform_local_credential_transaction(VerifiedDoorLock::CredentialType::Rfid, Bytes[0x01]).success?.should be_false
    lock.locked?.should be_true
    verifier.fail_authentication = false
    verifier.authenticated = authenticated_credential(VerifiedDoorLock::Credential.new(VerifiedDoorLock::CredentialType::Rfid, 9_u16))
    lock.perform_local_credential_transaction(VerifiedDoorLock::CredentialType::Rfid, Bytes[0x02]).success?.should be_false
    lock.locked?.should be_true
  end

  it "fails closed if a reader loses readiness after feature advertisement" do
    verifier = TestLocalCredentialVerifier.new
    lock = verified_credential_lock(VerifiedDoorLock::Feature::RfidCredential, verifier)
    verifier.authenticated = authenticated_credential(provision_verified_credential(lock, VerifiedDoorLock::CredentialType::Rfid))
    verifier.ready = false

    lock.perform_local_credential_transaction(VerifiedDoorLock::CredentialType::Rfid, Bytes[0x03]).success?.should be_false
    lock.locked?.should be_true
  end

  it "rejects a stale reader mapping when Matter changes the credential data" do
    verifier = TestLocalCredentialVerifier.new
    lock = verified_credential_lock(VerifiedDoorLock::Feature::RfidCredential, verifier)
    credential = provision_verified_credential(lock, VerifiedDoorLock::CredentialType::Rfid)
    verifier.authenticated = authenticated_credential(credential)
    modified = lock.handle_set_credential(VerifiedDoorLock::SetCredentialRequest.new(
      VerifiedDoorLock::DataOperationType::Modify, credential, "2468".to_slice, 2_u16,
      VerifiedDoorLock::UserStatus::OccupiedEnabled, VerifiedDoorLock::UserType::UnrestrictedUser))
    modified.status_code.should eq(VerifiedDoorLock::StatusCode::Success)

    lock.perform_local_credential_transaction(VerifiedDoorLock::CredentialType::Rfid, Bytes[0x04]).success?.should be_false
    lock.locked?.should be_true
    verifier.authenticated = authenticated_credential(credential, "2468")
    lock.perform_local_credential_transaction(VerifiedDoorLock::CredentialType::Rfid, Bytes[0x05]).success?.should be_true
  end

  it "rejects a mismatched type and a credential cleared during authentication" do
    verifier = TestLocalCredentialVerifier.new
    lock = verified_credential_lock(VerifiedDoorLock::Feature::RfidCredential, verifier)
    credential = provision_verified_credential(lock, VerifiedDoorLock::CredentialType::Rfid)
    verifier.authenticated = authenticated_credential(VerifiedDoorLock::Credential.new(VerifiedDoorLock::CredentialType::Face, 1_u16))
    lock.perform_local_credential_transaction(VerifiedDoorLock::CredentialType::Rfid, Bytes[0x05]).success?.should be_false
    verifier.authenticated = authenticated_credential(credential)
    verifier.on_authenticate = -> do
      lock.clear_credential(VerifiedDoorLock::ClearCredentialRequest.new(credential))
      nil
    end
    lock.perform_local_credential_transaction(VerifiedDoorLock::CredentialType::Rfid, Bytes[0x06]).success?.should be_false
    lock.locked?.should be_true
  end

  it "enforces the stored user's weekday schedule after verified RFID presentation" do
    now = Time.utc(2026, 10, 23, 12, 0, 0)
    clock = -> : Time? { now }
    verifier = TestLocalCredentialVerifier.new
    lock = verified_credential_lock(VerifiedDoorLock::Feature::RfidCredential | VerifiedDoorLock::Feature::WeekDayAccessSchedules,
      verifier, clock)
    credential = provision_verified_credential(lock, VerifiedDoorLock::CredentialType::Rfid,
      VerifiedDoorLock::UserType::WeekDayScheduleUser)
    verifier.authenticated = authenticated_credential(credential)
    lock.perform_local_credential_transaction(VerifiedDoorLock::CredentialType::Rfid, Bytes[0x07]).success?.should be_false
    day_mask = (1_u8 << now.day_of_week.value).to_u8
    lock.handle_set_week_day_schedule(VerifiedDoorLock::SetWeekDayScheduleRequest.new(
      1_u8, 2_u16, day_mask, 11_u8, 0_u8, 13_u8, 0_u8)).success?.should be_true
    lock.perform_local_credential_transaction(VerifiedDoorLock::CredentialType::Rfid, Bytes[0x08]).success?.should be_true
    now += 2.hours
    lock.lock(source: VerifiedDoorLock::OperationSource::Manual).success?.should be_true
    lock.perform_local_credential_transaction(VerifiedDoorLock::CredentialType::Rfid, Bytes[0x09]).success?.should be_false
    lock.locked?.should be_true
  end

  it "applies disabled-user policy to verified RFID access after restore" do
    verifier = TestLocalCredentialVerifier.new
    original = verified_credential_lock(VerifiedDoorLock::Feature::RfidCredential, verifier)
    credential = provision_verified_credential(original, VerifiedDoorLock::CredentialType::Rfid,
      VerifiedDoorLock::UserType::DisposableUser)
    restored = verified_credential_lock(VerifiedDoorLock::Feature::RfidCredential, verifier)
    restored.restore_state(original.save_state.as(Matter::Storage::Document))
    verifier.authenticated = authenticated_credential(credential)

    restored.perform_local_credential_transaction(VerifiedDoorLock::CredentialType::Rfid, Bytes[0x03]).success?.should be_true
    restored.lock(source: VerifiedDoorLock::OperationSource::Manual).success?.should be_true
    restored.perform_local_credential_transaction(VerifiedDoorLock::CredentialType::Rfid, Bytes[0x04]).success?.should be_false
    restored.locked?.should be_true
    restored.get_credential_status(VerifiedDoorLock::GetCredentialStatusRequest.new(credential)).user_index.should eq(2_u16)
  end

  {VerifiedDoorLock::CredentialType::Fingerprint, VerifiedDoorLock::CredentialType::FingerVein,
   VerifiedDoorLock::CredentialType::Face}.each do |type|
    it "accepts only a verified #{type} identity with the matching advertised feature" do
      verifier = TestLocalCredentialVerifier.new
      feature = type.face? ? VerifiedDoorLock::Feature::FaceCredentials : VerifiedDoorLock::Feature::FingerCredentials
      lock = verified_credential_lock(feature, verifier)
      credential = provision_verified_credential(lock, type)
      verifier.authenticated = authenticated_credential(credential)
      lock.perform_local_credential_transaction(type, Bytes[0x10]).success?.should be_true
      lock.unlocked?.should be_true
    end
  end
end
