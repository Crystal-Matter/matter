require "../spec_helper"

private alias RuleDoorLock = Matter::Cluster::DoorLock

private def rule_request(rule : RuleDoorLock::CredentialRule, operation : RuleDoorLock::DataOperationType) : RuleDoorLock::SetUserRequest
  RuleDoorLock::SetUserRequest.new(
    operation_type: operation,
    user_index: 2_u16,
    user_status: RuleDoorLock::UserStatus::OccupiedEnabled,
    user_type: RuleDoorLock::UserType::UnrestrictedUser,
    credential_rule: rule
  )
end

private def assert_unsupported_rule(status : Matter::InteractionModel::Status) : Nil
  status.status.should eq(Matter::InteractionModel::StatusCode::Failure)
  status.cluster_status.should eq(RuleDoorLock::StatusCode::InvalidField.value)
end

describe "Door Lock credential rules and configuration defaults" do
  it "uses the Matter 1.6 defaults for optional local controls" do
    lock = build(RuleDoorLock)
    RuleDoorLock::ALL_LOCAL_PROGRAMMING_FEATURES.should eq(0x0F_u8)
    lock.enable_one_touch_locking?.should be_false
    lock.enable_inside_status_led?.should be_false
    lock.enable_privacy_mode_button?.should be_false
    lock.local_programming_features.should eq(0_u8)

    explicitly_enabled = build(RuleDoorLock,
      enable_one_touch_locking: true,
      enable_inside_status_led: true,
      enable_privacy_mode_button: true,
      local_programming_features: RuleDoorLock::ALL_LOCAL_PROGRAMMING_FEATURES)
    explicitly_enabled.enable_one_touch_locking?.should be_true
    explicitly_enabled.enable_inside_status_led?.should be_true
    explicitly_enabled.enable_privacy_mode_button?.should be_true
    explicitly_enabled.local_programming_features.should eq(RuleDoorLock::ALL_LOCAL_PROGRAMMING_FEATURES)
  end

  it "rejects reserved LocalProgrammingFeatures bits on host and wire input" do
    expect_raises(ArgumentError) { build(RuleDoorLock, local_programming_features: 0x10_u8) }

    lock = build(RuleDoorLock)
    expect_status(write(lock, RuleDoorLock::ATTR_LOCAL_PROGRAMMING_FEATURES, 0x10_u8),
      Matter::InteractionModel::StatusCode::ConstraintError)
    lock.local_programming_features.should eq(0_u8)
  end

  it "rejects host configurations that advertise unenforced multi-credential rules" do
    [0_u8, 0x02_u8, 0x03_u8, 0x05_u8].each do |rules|
      expect_raises(ArgumentError) { build(RuleDoorLock, credential_rules_support: rules) }
    end
    build(RuleDoorLock, credential_rules_support: RuleDoorLock::CREDENTIAL_RULE_SINGLE)
      .credential_rules_support.should eq(RuleDoorLock::CREDENTIAL_RULE_SINGLE)
  end

  it "rejects Dual and Tri on direct SetUser Add without creating a user" do
    [RuleDoorLock::CredentialRule::Dual, RuleDoorLock::CredentialRule::Tri].each do |rule|
      lock = build(RuleDoorLock)
      assert_unsupported_rule(lock.handle_set_user(rule_request(rule, RuleDoorLock::DataOperationType::Add)))
      lock.get_user(RuleDoorLock::GetUserRequest.new(2_u16)).user_status.should eq(RuleDoorLock::UserStatus::Available)
    end
  end

  it "rejects Dual and Tri on wire SetUser Modify without changing a user" do
    [RuleDoorLock::CredentialRule::Dual, RuleDoorLock::CredentialRule::Tri].each do |rule|
      lock = build(RuleDoorLock)
      lock.handle_set_user(rule_request(RuleDoorLock::CredentialRule::Single, RuleDoorLock::DataOperationType::Add))
        .success?.should be_true
      result = invoke(lock, RuleDoorLock::CMD_SET_USER, rule_request(rule, RuleDoorLock::DataOperationType::Modify))
      assert_unsupported_rule(result.as(Matter::InteractionModel::Status))
      lock.get_user(RuleDoorLock::GetUserRequest.new(2_u16)).credential_rule.should eq(RuleDoorLock::CredentialRule::Single)
    end
  end

  it "does not restore a legacy multi-credential user with one-factor access" do
    original = build(RuleDoorLock)
    document = original.save_state.as(Matter::Storage::Document)
    database = RuleDoorLock::PersistedDatabase.from_document(
      document[RuleDoorLock::PERSISTED_DATABASE_KEY].as(Matter::Storage::Document))
    users = database.users
    user = users.first
    user.credential_rule = RuleDoorLock::CredentialRule::Dual
    users[0] = user
    document[RuleDoorLock::PERSISTED_DATABASE_KEY] = RuleDoorLock::PersistedDatabase.new(
      users, database.credentials, database.week_day_schedules,
      database.year_day_schedules, database.holiday_schedules,
      database.aliro_reader_config).to_document

    restored = build(RuleDoorLock)
    restored.handle_set_user(rule_request(RuleDoorLock::CredentialRule::Single, RuleDoorLock::DataOperationType::Add))
      .success?.should be_true
    restored.restore_state(document)
    restored.get_user(RuleDoorLock::GetUserRequest.new(2_u16)).credential_rule.should eq(RuleDoorLock::CredentialRule::Single)
  end

  it "rejects reserved stored LocalProgrammingFeatures bits without changing state" do
    original = build(RuleDoorLock)
    document = original.save_state.as(Matter::Storage::Document)
    document["local_programming_features"] = 0x10_i64

    restored = build(RuleDoorLock)
    restored.handle_set_user(rule_request(RuleDoorLock::CredentialRule::Single, RuleDoorLock::DataOperationType::Add))
      .success?.should be_true
    restored.restore_state(document)
    restored.local_programming_features.should eq(0_u8)
    restored.get_user(RuleDoorLock::GetUserRequest.new(2_u16)).credential_rule.should eq(RuleDoorLock::CredentialRule::Single)
  end

  it "migrates the former stored 0xFF default without losing users" do
    original = build(RuleDoorLock)
    original.handle_set_user(rule_request(RuleDoorLock::CredentialRule::Single, RuleDoorLock::DataOperationType::Add))
      .success?.should be_true
    credential = RuleDoorLock::Credential.new(RuleDoorLock::CredentialType::Pin, 1_u16)
    original.handle_set_credential(RuleDoorLock::SetCredentialRequest.new(
      RuleDoorLock::DataOperationType::Add, credential, "2468".to_slice, user_index: 2_u16))
      .status_code.should eq(RuleDoorLock::StatusCode::Success)
    document = original.save_state.as(Matter::Storage::Document)
    document["local_programming_features"] = 0xFF_i64

    restored = build(RuleDoorLock)
    restored.restore_state(document)
    restored.local_programming_features.should eq(RuleDoorLock::ALL_LOCAL_PROGRAMMING_FEATURES)
    restored.get_user(RuleDoorLock::GetUserRequest.new(2_u16)).credential_rule.should eq(RuleDoorLock::CredentialRule::Single)
    restored.get_credential_status(RuleDoorLock::GetCredentialStatusRequest.new(credential)).credential_exists?.should be_true
    restored.data_version.should_not eq(original.data_version)
    restored.save_state.as(Matter::Storage::Document)["local_programming_features"].should eq(0x0F_i64)
  end
end
