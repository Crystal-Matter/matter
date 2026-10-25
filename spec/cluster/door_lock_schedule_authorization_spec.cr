require "../spec_helper"

private alias ScheduledDoorLock = Matter::Cluster::DoorLock

private class HolidayTestTimer < ScheduledDoorLock::HolidayTimer
  @callbacks = [] of Tuple(Time, Proc(Nil))

  def initialize(@now : Proc(Time))
  end

  def schedule(delay : Time::Span, &block : -> Nil) : Proc(Nil)
    active = true
    @callbacks << {@now.call + delay, -> { block.call if active }}
    -> { active = false; nil }
  end

  def fire_due : Nil
    due, future = @callbacks.partition { |deadline, _| deadline <= @now.call }
    @callbacks = future
    due.each { |_, callback| callback.call }
  end
end

private def schedule_test_lock(clock : Proc(Time?), wrong_code_entry_limit : UInt8 = 3_u8) : ScheduledDoorLock
  build(ScheduledDoorLock,
    feature_map: ScheduledDoorLock::Feature::PinCredential | ScheduledDoorLock::Feature::CredentialOverTheAirAccess |
                 ScheduledDoorLock::Feature::User | ScheduledDoorLock::Feature::WeekDayAccessSchedules |
                 ScheduledDoorLock::Feature::YearDayAccessSchedules | ScheduledDoorLock::Feature::HolidaySchedules,
    require_pin_for_remote_operation: true,
    default_pin_code: "9999",
    wrong_code_entry_limit: wrong_code_entry_limit,
    local_time_provider: clock)
end

private def provision_schedule_user(lock : ScheduledDoorLock, user_type : ScheduledDoorLock::UserType) : Nil
  expect_success(invoke(lock, ScheduledDoorLock::CMD_SET_USER, ScheduledDoorLock::SetUserRequest.new(
    operation_type: ScheduledDoorLock::DataOperationType::Add,
    user_index: 2_u16,
    user_status: ScheduledDoorLock::UserStatus::OccupiedEnabled,
    user_type: user_type
  )))
  credential = ScheduledDoorLock::Credential.new(ScheduledDoorLock::CredentialType::Pin, 1_u16)
  response = invoke(lock, ScheduledDoorLock::CMD_SET_CREDENTIAL, ScheduledDoorLock::SetCredentialRequest.new(
    ScheduledDoorLock::DataOperationType::Add, credential, "2468".to_slice, user_index: 2_u16))
  ScheduledDoorLock::SetCredentialResponse.from_tlv(response.as(Matter::Cluster::CommandResponse).response.as(TLV::Any)).status_code.should eq(ScheduledDoorLock::StatusCode::Success)
end

private def unlock_with_schedule_pin(lock : ScheduledDoorLock)
  invoke(lock, ScheduledDoorLock::CMD_UNLOCK_DOOR, ScheduledDoorLock::UnlockDoorRequest.new("2468".to_slice))
end

private def local_schedule_epoch(time : Time) : UInt32
  Time.utc(time.year, time.month, time.day, time.hour, time.minute, time.second).to_unix.to_u32
end

describe "Door Lock schedule authorization" do
  it "denies a weekday user without a matching schedule, then honors the restored schedule" do
    now = Time.utc(2026, 10, 23, 12, 0, 0)
    clock = -> : Time? { now }
    lock = schedule_test_lock(clock, wrong_code_entry_limit: 1_u8)
    provision_schedule_user(lock, ScheduledDoorLock::UserType::WeekDayScheduleUser)

    expect_status(unlock_with_schedule_pin(lock), Matter::InteractionModel::StatusCode::Failure)
    day_mask = (1_u8 << now.day_of_week.value).to_u8
    expect_success(invoke(lock, ScheduledDoorLock::CMD_SET_WEEK_DAY_SCHEDULE,
      ScheduledDoorLock::SetWeekDayScheduleRequest.new(1_u8, 2_u16, day_mask, 11_u8, 0_u8, 13_u8, 0_u8)))

    restored = schedule_test_lock(clock, wrong_code_entry_limit: 1_u8)
    restored.restore_state(lock.save_state.as(Matter::Storage::Document))
    expect_success(unlock_with_schedule_pin(restored))

    now = Time.utc(2026, 10, 23, 14, 0, 0)
    expect_status(unlock_with_schedule_pin(restored), Matter::InteractionModel::StatusCode::Failure)
  end

  it "requires a matching year-day window and both schedule kinds for a restricted user" do
    now = Time.utc(2026, 10, 23, 12, 0, 0)
    clock = -> : Time? { now }
    lock = schedule_test_lock(clock)
    provision_schedule_user(lock, ScheduledDoorLock::UserType::ScheduleRestrictedUser)

    day_mask = (1_u8 << now.day_of_week.value).to_u8
    expect_success(invoke(lock, ScheduledDoorLock::CMD_SET_WEEK_DAY_SCHEDULE,
      ScheduledDoorLock::SetWeekDayScheduleRequest.new(1_u8, 2_u16, day_mask, 11_u8, 0_u8, 13_u8, 0_u8)))
    expect_success(unlock_with_schedule_pin(lock))

    expect_success(invoke(lock, ScheduledDoorLock::CMD_SET_YEAR_DAY_SCHEDULE,
      ScheduledDoorLock::SetYearDayScheduleRequest.new(1_u8, 2_u16,
        local_schedule_epoch(now + 1.day), local_schedule_epoch(now + 2.days))))
    expect_status(unlock_with_schedule_pin(lock), Matter::InteractionModel::StatusCode::Failure)

    expect_success(invoke(lock, ScheduledDoorLock::CMD_SET_YEAR_DAY_SCHEDULE,
      ScheduledDoorLock::SetYearDayScheduleRequest.new(1_u8, 2_u16,
        local_schedule_epoch(now - 1.hour), local_schedule_epoch(now + 1.hour))))
    expect_success(unlock_with_schedule_pin(lock))
  end

  it "grants a year-day user only inside a configured local date window" do
    now = Time.utc(2026, 10, 23, 12, 0, 0)
    clock = -> : Time? { now }
    lock = schedule_test_lock(clock)
    provision_schedule_user(lock, ScheduledDoorLock::UserType::YearDayScheduleUser)

    expect_status(unlock_with_schedule_pin(lock), Matter::InteractionModel::StatusCode::Failure)
    expect_success(invoke(lock, ScheduledDoorLock::CMD_SET_YEAR_DAY_SCHEDULE,
      ScheduledDoorLock::SetYearDayScheduleRequest.new(1_u8, 2_u16,
        local_schedule_epoch(now - 1.hour), local_schedule_epoch(now + 1.hour))))
    expect_success(unlock_with_schedule_pin(lock))

    now = Time.utc(2026, 10, 23, 14, 0, 0)
    expect_status(unlock_with_schedule_pin(lock), Matter::InteractionModel::StatusCode::Failure)
  end

  it "denies schedule users when local time is unknown" do
    clock = -> : Time? { nil }
    lock = schedule_test_lock(clock)
    provision_schedule_user(lock, ScheduledDoorLock::UserType::YearDayScheduleUser)
    expect_success(invoke(lock, ScheduledDoorLock::CMD_SET_YEAR_DAY_SCHEDULE,
      ScheduledDoorLock::SetYearDayScheduleRequest.new(1_u8, 2_u16, 1_u32, UInt32::MAX)))
    expect_status(unlock_with_schedule_pin(lock), Matter::InteractionModel::StatusCode::Failure)
  end

  it "rejects an invalid weekday time window before storing it" do
    now = Time.utc(2026, 10, 23, 12, 0, 0)
    lock = schedule_test_lock(-> : Time? { now })
    provision_schedule_user(lock, ScheduledDoorLock::UserType::WeekDayScheduleUser)

    result = invoke(lock, ScheduledDoorLock::CMD_SET_WEEK_DAY_SCHEDULE,
      ScheduledDoorLock::SetWeekDayScheduleRequest.new(1_u8, 2_u16, 0x7F_u8, 24_u8, 0_u8, 23_u8, 59_u8))
    status = result.as(Matter::InteractionModel::Status)
    status.status.should eq(Matter::InteractionModel::StatusCode::Failure)
    status.cluster_status.should eq(ScheduledDoorLock::StatusCode::InvalidField.value)
    lock.get_week_day_schedule(ScheduledDoorLock::GetWeekDayScheduleRequest.new(1_u8, 2_u16)).status_code.should eq(ScheduledDoorLock::StatusCode::NotFound)
  end

  it "applies a holiday operating mode only during its local-time interval" do
    now = Time.utc(2026, 10, 23, 12, 0, 0)
    clock = -> : Time? { now }
    lock = schedule_test_lock(clock)
    expect_success(invoke(lock, ScheduledDoorLock::CMD_SET_HOLIDAY_SCHEDULE,
      ScheduledDoorLock::SetHolidayScheduleRequest.new(1_u8,
        local_schedule_epoch(now - 1.hour), local_schedule_epoch(now + 1.hour),
        ScheduledDoorLock::OperatingMode::NoRemoteLockUnlock)))

    read(lock, ScheduledDoorLock::ATTR_OPERATING_MODE).should eq(ScheduledDoorLock::OperatingMode::NoRemoteLockUnlock.value)
    expect_status(invoke(lock, ScheduledDoorLock::CMD_UNLOCK_DOOR,
      ScheduledDoorLock::UnlockDoorRequest.new("9999".to_slice)), Matter::InteractionModel::StatusCode::Failure)

    now = Time.utc(2026, 10, 23, 14, 0, 0)
    read(lock, ScheduledDoorLock::ATTR_OPERATING_MODE).should eq(ScheduledDoorLock::OperatingMode::Normal.value)
    expect_success(invoke(lock, ScheduledDoorLock::CMD_UNLOCK_DOOR,
      ScheduledDoorLock::UnlockDoorRequest.new("9999".to_slice)))
  end

  it "reports only actual OperatingMode transitions at holiday boundaries" do
    now = Time.utc(2026, 10, 23, 12, 0, 0)
    clock = -> : Time? { now }
    timer = HolidayTestTimer.new(-> { now })
    lock = build(ScheduledDoorLock,
      feature_map: ScheduledDoorLock::Feature::User | ScheduledDoorLock::Feature::HolidaySchedules,
      local_time_provider: clock,
      holiday_timer: timer)
    notifications = [] of UInt32
    lock.on_attribute_changed = ->(_endpoint : UInt16, _cluster : UInt32, attribute : UInt32) { notifications << attribute }

    expect_success(invoke(lock, ScheduledDoorLock::CMD_SET_HOLIDAY_SCHEDULE,
      ScheduledDoorLock::SetHolidayScheduleRequest.new(1_u8,
        local_schedule_epoch(now + 1.hour), local_schedule_epoch(now + 3.hours),
        ScheduledDoorLock::OperatingMode::NoRemoteLockUnlock)))
    version_after_set = lock.data_version
    notifications.should be_empty

    now += 1.hour
    timer.fire_due
    read(lock, ScheduledDoorLock::ATTR_OPERATING_MODE).should eq(ScheduledDoorLock::OperatingMode::NoRemoteLockUnlock.value)
    lock.data_version.should eq(version_after_set &+ 1_u32)
    notifications.should eq([ScheduledDoorLock::ATTR_OPERATING_MODE])

    # Adding an overlapping schedule with the same mode does not change the wire value.
    expect_success(invoke(lock, ScheduledDoorLock::CMD_SET_HOLIDAY_SCHEDULE,
      ScheduledDoorLock::SetHolidayScheduleRequest.new(2_u8,
        local_schedule_epoch(now + 1.hour), local_schedule_epoch(now + 3.hours),
        ScheduledDoorLock::OperatingMode::NoRemoteLockUnlock)))
    notifications.size.should eq(1)
    now += 2.hours + 1.second
    timer.fire_due
    read(lock, ScheduledDoorLock::ATTR_OPERATING_MODE).should eq(ScheduledDoorLock::OperatingMode::NoRemoteLockUnlock.value)
    notifications.size.should eq(1)

    now += 1.hour
    timer.fire_due
    read(lock, ScheduledDoorLock::ATTR_OPERATING_MODE).should eq(ScheduledDoorLock::OperatingMode::Normal.value)
    notifications.should eq([ScheduledDoorLock::ATTR_OPERATING_MODE, ScheduledDoorLock::ATTR_OPERATING_MODE])

    timer.fire_due
    notifications.size.should eq(2)

    # A host clock correction can re-enter an interval without waiting for an old timer.
    now -= 1.hour
    lock.refresh_holiday_operating_mode
    read(lock, ScheduledDoorLock::ATTR_OPERATING_MODE).should eq(ScheduledDoorLock::OperatingMode::NoRemoteLockUnlock.value)
    notifications.size.should eq(3)
  end

  it "arms a restored holiday schedule without reporting a false transition" do
    now = Time.utc(2026, 10, 23, 12, 0, 0)
    clock = -> : Time? { now }
    features = ScheduledDoorLock::Feature::User | ScheduledDoorLock::Feature::HolidaySchedules
    first = build(ScheduledDoorLock, feature_map: features, local_time_provider: clock,
      holiday_timer: HolidayTestTimer.new(-> { now }))
    expect_success(invoke(first, ScheduledDoorLock::CMD_SET_HOLIDAY_SCHEDULE,
      ScheduledDoorLock::SetHolidayScheduleRequest.new(1_u8,
        local_schedule_epoch(now + 1.hour), local_schedule_epoch(now + 2.hours),
        ScheduledDoorLock::OperatingMode::NoRemoteLockUnlock)))

    timer = HolidayTestTimer.new(-> { now })
    restored = build(ScheduledDoorLock, feature_map: features, local_time_provider: clock, holiday_timer: timer)
    notifications = [] of UInt32
    restored.on_attribute_changed = ->(_endpoint : UInt16, _cluster : UInt32, attribute : UInt32) { notifications << attribute }
    restored.restore_state(first.save_state.as(Matter::Storage::Document))
    version_after_restore = restored.data_version
    notifications.should be_empty

    now += 1.hour
    timer.fire_due
    restored.data_version.should eq(version_after_restore &+ 1_u32)
    notifications.should eq([ScheduledDoorLock::ATTR_OPERATING_MODE])

    expect_success(invoke(restored, ScheduledDoorLock::CMD_CLEAR_HOLIDAY_SCHEDULE,
      ScheduledDoorLock::ClearHolidayScheduleRequest.new(1_u8)))
    read(restored, ScheduledDoorLock::ATTR_OPERATING_MODE).should eq(ScheduledDoorLock::OperatingMode::Normal.value)
    notifications.should eq([ScheduledDoorLock::ATTR_OPERATING_MODE, ScheduledDoorLock::ATTR_OPERATING_MODE])
    now += 2.hours + 1.second
    timer.fire_due
    notifications.size.should eq(2)
  end

  it "does not report a boundary when the configured mode already matches the holiday" do
    now = Time.utc(2026, 10, 23, 12, 0, 0)
    timer = HolidayTestTimer.new(-> { now })
    lock = build(ScheduledDoorLock,
      feature_map: ScheduledDoorLock::Feature::User | ScheduledDoorLock::Feature::HolidaySchedules,
      local_time_provider: -> : Time? { now }, holiday_timer: timer)
    notifications = [] of UInt32
    lock.on_attribute_changed = ->(_endpoint : UInt16, _cluster : UInt32, attribute : UInt32) { notifications << attribute }
    lock.operating_mode = ScheduledDoorLock::OperatingMode::NoRemoteLockUnlock
    notifications.should eq([ScheduledDoorLock::ATTR_OPERATING_MODE])

    expect_success(invoke(lock, ScheduledDoorLock::CMD_SET_HOLIDAY_SCHEDULE,
      ScheduledDoorLock::SetHolidayScheduleRequest.new(1_u8,
        local_schedule_epoch(now + 1.hour), local_schedule_epoch(now + 2.hours),
        ScheduledDoorLock::OperatingMode::NoRemoteLockUnlock)))
    version_after_set = lock.data_version
    now += 1.hour
    timer.fire_due
    lock.data_version.should eq(version_after_set)
    notifications.size.should eq(1)
  end

  it "keeps a configured mode write silent while an active holiday masks it" do
    now = Time.utc(2026, 10, 23, 12, 0, 0)
    timer = HolidayTestTimer.new(-> { now })
    lock = build(ScheduledDoorLock,
      feature_map: ScheduledDoorLock::Feature::User | ScheduledDoorLock::Feature::HolidaySchedules,
      supported_operating_modes: 0xFFE2_u16,
      local_time_provider: -> : Time? { now }, holiday_timer: timer)
    notifications = [] of UInt32
    lock.on_attribute_changed = ->(_endpoint : UInt16, _cluster : UInt32, attribute : UInt32) { notifications << attribute }

    expect_success(invoke(lock, ScheduledDoorLock::CMD_SET_HOLIDAY_SCHEDULE,
      ScheduledDoorLock::SetHolidayScheduleRequest.new(1_u8,
        local_schedule_epoch(now - 1.hour), local_schedule_epoch(now + 1.hour),
        ScheduledDoorLock::OperatingMode::NoRemoteLockUnlock)))
    notifications.should eq([ScheduledDoorLock::ATTR_OPERATING_MODE])
    notifications.clear
    version_before_write = lock.data_version

    expect_success(write(lock, ScheduledDoorLock::ATTR_OPERATING_MODE,
      ScheduledDoorLock::OperatingMode::Privacy.value))
    lock.operating_mode.should eq(ScheduledDoorLock::OperatingMode::Privacy)
    read(lock, ScheduledDoorLock::ATTR_OPERATING_MODE).should eq(ScheduledDoorLock::OperatingMode::NoRemoteLockUnlock.value)
    # The stored configuration changed, so persistence still needs a version bump.
    lock.data_version.should eq(version_before_write &+ 1_u32)
    notifications.should be_empty

    now += 1.hour + 1.second
    timer.fire_due
    read(lock, ScheduledDoorLock::ATTR_OPERATING_MODE).should eq(ScheduledDoorLock::OperatingMode::Privacy.value)
    lock.data_version.should eq(version_before_write &+ 2_u32)
    notifications.should eq([ScheduledDoorLock::ATTR_OPERATING_MODE])
  end
end
