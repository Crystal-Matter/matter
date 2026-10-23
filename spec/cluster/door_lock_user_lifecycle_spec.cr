require "../spec_helper"

private alias LifecycleDoorLock = Matter::Cluster::DoorLock

private class LifecycleAliroReader < LifecycleDoorLock::AliroReaderDelegate
  property authenticated : LifecycleDoorLock::AliroAuthenticatedAccess? = nil

  def ready? : Bool
    true
  end

  def supported_protocol_versions : Array(Bytes)
    [Bytes[0x01, 0x00]]
  end

  def group_sub_identifier : Bytes
    Bytes.new(16, 0xAA_u8)
  end

  def configure(config : LifecycleDoorLock::AliroReaderConfig) : Bool
    true
  end

  def clear_with_user_permission : Bool
    true
  end

  def authenticate(transaction : Bytes, required_step_up_data_element : String) : LifecycleDoorLock::AliroAuthenticatedAccess?
    @authenticated
  end
end

private def lifecycle_lock(clock : Proc(Time?) = -> : Time? { Time.utc }) : LifecycleDoorLock
  build(LifecycleDoorLock,
    feature_map: LifecycleDoorLock::Feature::PinCredential | LifecycleDoorLock::Feature::CredentialOverTheAirAccess |
                 LifecycleDoorLock::Feature::User,
    require_pin_for_remote_operation: true,
    default_pin_code: "9999",
    expiring_user_timeout: 1_u16,
    local_time_provider: clock)
end

private def provision_lifecycle_pin(lock : LifecycleDoorLock, user_type : LifecycleDoorLock::UserType) : LifecycleDoorLock::Credential
  lock.handle_set_user(LifecycleDoorLock::SetUserRequest.new(
    LifecycleDoorLock::DataOperationType::Add, 2_u16,
    user_status: LifecycleDoorLock::UserStatus::OccupiedEnabled,
    user_type: user_type
  )).success?.should be_true
  credential = LifecycleDoorLock::Credential.new(LifecycleDoorLock::CredentialType::Pin, 1_u16)
  response = lock.handle_set_credential(LifecycleDoorLock::SetCredentialRequest.new(
    LifecycleDoorLock::DataOperationType::Add, credential, "5757".to_slice, user_index: 2_u16))
  response.status_code.should eq(LifecycleDoorLock::StatusCode::Success)
  credential
end

private def lifecycle_user_status(lock : LifecycleDoorLock) : LifecycleDoorLock::UserStatus?
  lock.get_user(LifecycleDoorLock::GetUserRequest.new(2_u16)).user_status
end

describe "Door Lock user lifecycle" do
  it "disables a disposable user after the first successful PIN unlock" do
    lock = lifecycle_lock
    provision_lifecycle_pin(lock, LifecycleDoorLock::UserType::DisposableUser)
    events = [] of Tuple(UInt32, TLV::Any)
    lock.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, event : UInt32, _priority : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) do
      events << {event, data}
      nil
    end
    lock.unlock(pin: "0000").success?.should be_false
    lifecycle_user_status(lock).should eq(LifecycleDoorLock::UserStatus::OccupiedEnabled)

    lock.lock(pin: "5757").success?.should be_true
    lifecycle_user_status(lock).should eq(LifecycleDoorLock::UserStatus::OccupiedEnabled)

    lock.unlock(pin: "5757").success?.should be_true
    lifecycle_user_status(lock).should eq(LifecycleDoorLock::UserStatus::OccupiedDisabled)
    user_change = events.find! { |id, _| id == LifecycleDoorLock::EVENT_LOCK_USER_CHANGE }[1]
    changed = LifecycleDoorLock::Events::LockUserChange.from_tlv(user_change)
    changed.data_operation_type.should eq(LifecycleDoorLock::DataOperationType::Modify)
    changed.user_index.should eq(2_u16)
    lock.unlock(pin: "5757").success?.should be_false
  end

  it "persists the first-use expiring deadline and disables the user at its absolute boundary" do
    now = Time.utc(2026, 10, 23, 12, 0, 0)
    clock = -> : Time? { now }
    lock = lifecycle_lock(clock)
    provision_lifecycle_pin(lock, LifecycleDoorLock::UserType::ExpiringUser)
    lock.unlock(pin: "0000").success?.should be_false
    now += 10.minutes
    lock.unlock(pin: "5757").success?.should be_true
    document = lock.save_state.as(Matter::Storage::Document)

    now += 59.seconds
    restored = lifecycle_lock(clock)
    restored.restore_state(document)
    restored.unlock(pin: "5757").success?.should be_true
    lifecycle_user_status(restored).should eq(LifecycleDoorLock::UserStatus::OccupiedEnabled)

    now += 1.second
    lifecycle_user_status(restored).should eq(LifecycleDoorLock::UserStatus::OccupiedDisabled)
    restored.unlock(pin: "5757").success?.should be_false
  end

  it "applies the same expiring deadline to an authenticated Aliro endpoint key" do
    now = Time.utc(2026, 10, 23, 12, 0, 0)
    clock = -> : Time? { now }
    reader = LifecycleAliroReader.new
    lock = build(LifecycleDoorLock,
      feature_map: LifecycleDoorLock::Feature::PinCredential | LifecycleDoorLock::Feature::CredentialOverTheAirAccess |
                   LifecycleDoorLock::Feature::User | LifecycleDoorLock::Feature::AliroProvisioning,
      require_pin_for_remote_operation: true,
      default_pin_code: "9999",
      expiring_user_timeout: 1_u16,
      local_time_provider: clock,
      aliro_reader_delegate: reader,
      number_of_aliro_credential_issuer_keys_supported: 1_u16,
      number_of_aliro_endpoint_keys_supported: 1_u16)
    provision_lifecycle_pin(lock, LifecycleDoorLock::UserType::ExpiringUser)
    signing = Matter::Crypto::Key.generate_key_pair
    lock.configure_aliro_reader(LifecycleDoorLock::AliroReaderConfig.new(signing.private_key, signing.public_key, Bytes.new(16))).success?.should be_true
    endpoint = Matter::Crypto::Key.generate_key_pair
    lock.provision_aliro_key(LifecycleDoorLock::CredentialType::AliroNonEvictableEndpointKey, 1_u16, 2_u16, endpoint.public_key).should eq(LifecycleDoorLock::StatusCode::Success)
    reader.authenticated = LifecycleDoorLock::AliroAuthenticatedAccess.new(endpoint.public_key)

    lock.unlock(pin: "5757").success?.should be_true
    now += 1.minute
    lock.perform_aliro_transaction(Bytes[0x01]).success?.should be_false
    lifecycle_user_status(lock).should eq(LifecycleDoorLock::UserStatus::OccupiedDisabled)
  end

  it "restarts the expiring-user cycle when an administrator re-enables the user" do
    now = Time.utc(2026, 10, 23, 12, 0, 0)
    lock = lifecycle_lock(-> : Time? { now })
    provision_lifecycle_pin(lock, LifecycleDoorLock::UserType::ExpiringUser)
    lock.unlock(pin: "5757").success?.should be_true

    now += 30.seconds
    lock.handle_set_user(LifecycleDoorLock::SetUserRequest.new(
      LifecycleDoorLock::DataOperationType::Modify, 2_u16,
      user_status: LifecycleDoorLock::UserStatus::OccupiedDisabled)).success?.should be_true
    lock.handle_set_user(LifecycleDoorLock::SetUserRequest.new(
      LifecycleDoorLock::DataOperationType::Modify, 2_u16,
      user_status: LifecycleDoorLock::UserStatus::OccupiedEnabled)).success?.should be_true

    now += 31.seconds
    lifecycle_user_status(lock).should eq(LifecycleDoorLock::UserStatus::OccupiedEnabled)
    lock.unlock(pin: "5757").success?.should be_true
    now += 1.minute
    lifecycle_user_status(lock).should eq(LifecycleDoorLock::UserStatus::OccupiedDisabled)
  end

  it "emits ForcedUser operation and silent alarm with the PIN user and credential" do
    lock = lifecycle_lock
    credential = provision_lifecycle_pin(lock, LifecycleDoorLock::UserType::ForcedUser)
    emitted = [] of Tuple(UInt32, TLV::Any)
    lock.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, event : UInt32, _priority : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) do
      emitted << {event, data}
      nil
    end

    lock.unlock(pin: "5757").success?.should be_true
    operation = emitted.find! { |id, _| id == LifecycleDoorLock::EVENT_LOCK_OPERATION }[1]
    decoded = LifecycleDoorLock::Events::LockOperation.from_tlv(operation)
    decoded.lock_operation_type.should eq(LifecycleDoorLock::LockOperationType::ForcedUserEvent)
    decoded.user_index.should eq(2_u16)
    decoded.credentials.should eq([credential])
    alarm = emitted.find! { |id, _| id == LifecycleDoorLock::EVENT_DOOR_LOCK_ALARM }[1]
    LifecycleDoorLock::Events::DoorLockAlarm.from_tlv(alarm).alarm_code.should eq(LifecycleDoorLock::AlarmCode::ForcedUser)
  end

  it "journals an invalid credential LockOperationError with source and cause" do
    lock = lifecycle_lock
    events = [] of Tuple(UInt32, TLV::Any)
    lock.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, event : UInt32, _priority : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) do
      events << {event, data}
      nil
    end
    lock.unlock(pin: "0000").success?.should be_false
    payload = events.find! { |id, _| id == LifecycleDoorLock::EVENT_LOCK_OPERATION_ERROR }[1]
    error = LifecycleDoorLock::Events::LockOperationError.from_tlv(payload)
    error.lock_operation_type.should eq(LifecycleDoorLock::LockOperationType::Unlock)
    error.operation_source.should eq(LifecycleDoorLock::OperationSource::Remote)
    error.operation_error.should eq(LifecycleDoorLock::OperationError::InvalidCredential)
  end

  it "identifies the disabled user and fabric on a denied credential operation" do
    lock = lifecycle_lock
    credential = provision_lifecycle_pin(lock, LifecycleDoorLock::UserType::DisposableUser)
    lock.request_fabric_index = 1_u8
    lock.request_peer_node_id = 0xA123_u64
    events = [] of TLV::Any
    lock.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, event : UInt32, _priority : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) do
      events << data if event == LifecycleDoorLock::EVENT_LOCK_OPERATION_ERROR
      nil
    end

    lock.unlock(pin: "5757").success?.should be_true
    lock.unlock(pin: "5757").success?.should be_false
    error = LifecycleDoorLock::Events::LockOperationError.from_tlv(events.last)
    error.operation_error.should eq(LifecycleDoorLock::OperationError::DisabledUserDenied)
    error.user_index.should eq(2_u16)
    error.credentials.should eq([credential])
    error.fabric_index.should eq(1_u8)
    error.source_node.should eq(0xA123_u64)
  end

  it "does not bypass a disabled user by assigning its PIN to a second user" do
    lock = lifecycle_lock
    provision_lifecycle_pin(lock, LifecycleDoorLock::UserType::DisposableUser)
    lock.unlock(pin: "5757").success?.should be_true

    lock.handle_set_user(LifecycleDoorLock::SetUserRequest.new(
      LifecycleDoorLock::DataOperationType::Add, 3_u16,
      user_status: LifecycleDoorLock::UserStatus::OccupiedEnabled,
      user_type: LifecycleDoorLock::UserType::UnrestrictedUser
    )).success?.should be_true
    credential = LifecycleDoorLock::Credential.new(LifecycleDoorLock::CredentialType::Pin, 2_u16)
    response = lock.handle_set_credential(LifecycleDoorLock::SetCredentialRequest.new(
      LifecycleDoorLock::DataOperationType::Add, credential, "5757".to_slice, user_index: 3_u16))
    response.status_code.should eq(LifecycleDoorLock::StatusCode::Duplicate)

    lock.unlock(pin: "5757").success?.should be_false
    lifecycle_user_status(lock).should eq(LifecycleDoorLock::UserStatus::OccupiedDisabled)
    lock.get_user(LifecycleDoorLock::GetUserRequest.new(3_u16)).credentials.should be_nil
  end

  it "defaults SendPINOverTheAir to the Matter false value" do
    # PIN requires USR in Matter 1.6, so this legacy optional attribute is not exposed.
    lock = build(LifecycleDoorLock)
    lock.send_pin_over_the_air?.should be_false
    lock.attributes.map(&.id.id).should_not contain(LifecycleDoorLock::ATTR_SEND_PIN_OVER_THE_AIR)
  end

  it "accepts only the Matter ExpiringUserTimeout range" do
    expect_raises(ArgumentError) { build(LifecycleDoorLock, expiring_user_timeout: 0_u16) }
    expect_raises(ArgumentError) { build(LifecycleDoorLock, expiring_user_timeout: 2881_u16) }
    build(LifecycleDoorLock, expiring_user_timeout: 2880_u16).expiring_user_timeout.should eq(2880_u16)
  end
end
