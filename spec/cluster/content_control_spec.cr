require "../spec_helper"

private alias Control = Matter::Cluster::ContentControl
private alias IMCode = Matter::InteractionModel::StatusCode

describe Control do
  it "exposes the mandatory revision-one controls and persists their state" do
    cluster = build(Control)
    cluster.cluster_id.id.should eq(0x050F_u32)
    cluster.cluster_revision.should eq(1_u16)
    accepted_command_ids(cluster).should eq([Control::CMD_ENABLE, Control::CMD_DISABLE])
    [Control::CMD_ENABLE, Control::CMD_DISABLE].each do |id|
      metadata = cluster.get_command_metadata(id).as(Matter::Cluster::CommandMetadata)
      metadata.access.should eq(Matter::InteractionModel::EntryPrivilege::Manage)
      metadata.timed?.should be_true
    end
    attribute_ids(cluster).should contain(Control::ATTR_ENABLED)
    read(cluster, Control::ATTR_ENABLED).should be_false

    expect_success(invoke(cluster, Control::CMD_ENABLE))
    read(cluster, Control::ATTR_ENABLED).should be_true
    saved = cluster.save_state
    restored = build(Control)
    restored.restore_state(saved)
    read(restored, Control::ATTR_ENABLED).should be_true
    expect_success(invoke(restored, Control::CMD_DISABLE))
    read(restored, Control::ATTR_ENABLED).should be_false
  end

  it "only advertises and mutates configured optional features" do
    cluster = build(Control, feature_map: Control::Feature::BlockUnrated)
    attribute_ids(cluster).should contain(Control::ATTR_BLOCK_UNRATED)
    accepted_command_ids(cluster).should contain(Control::CMD_BLOCK_UNRATED_CONTENT)
    accepted_command_ids(cluster).should contain(Control::CMD_UNBLOCK_UNRATED_CONTENT)
    read(cluster, Control::ATTR_BLOCK_UNRATED).should be_false
    expect_success(invoke(cluster, Control::CMD_BLOCK_UNRATED_CONTENT))
    read(cluster, Control::ATTR_BLOCK_UNRATED).should be_true
    expect_success(invoke(cluster, Control::CMD_UNBLOCK_UNRATED_CONTENT))
    read(cluster, Control::ATTR_BLOCK_UNRATED).should be_false

    bare = build(Control)
    expect_status(invoke(bare, Control::CMD_BLOCK_UNRATED_CONTENT), IMCode::UnsupportedCommand)
    read_status(bare, Control::ATTR_BLOCK_UNRATED).status.should eq(IMCode::UnsupportedAttribute)
  end

  it "uses the configured ratings and rejects unknown thresholds" do
    ratings = [Control::RatingName.new("G"), Control::RatingName.new("PG"), Control::RatingName.new("R")]
    cluster = build(Control, feature_map: Control::Feature::OnDemandContentRating,
      on_demand_ratings: ratings, on_demand_rating_threshold: "R")
    attribute_ids(cluster).should contain(Control::ATTR_ON_DEMAND_RATINGS)
    accepted_command_ids(cluster).should contain(Control::CMD_SET_ON_DEMAND_RATING_THRESHOLD)
    expect_status(invoke(cluster, Control::CMD_SET_ON_DEMAND_RATING_THRESHOLD,
      Control::SetRatingRequest.new("X")), IMCode::Failure).cluster_status.should eq(0x03_u8)
    expect_success(invoke(cluster, Control::CMD_SET_ON_DEMAND_RATING_THRESHOLD,
      Control::SetRatingRequest.new("PG")))
    read(cluster, Control::ATTR_ON_DEMAND_RATING_THRESHOLD).should eq("PG")
    ratings << Control::RatingName.new("X")
    read_tlv(cluster, Control::ATTR_ON_DEMAND_RATINGS).as_list.size.should eq(3)
  end

  it "adds and removes identified applications without partial mutation" do
    app = Control::AppInfo.new(0xFFF1_u16, "radio")
    absent = Control::AppInfo.new(0xFFF1_u16, "video")
    cluster = build(Control, feature_map: Control::Feature::BlockApplications)
    expect_success(invoke(cluster, Control::CMD_ADD_BLOCK_APPLICATIONS,
      Control::ApplicationsRequest.new([app])))
    expect_status(invoke(cluster, Control::CMD_ADD_BLOCK_APPLICATIONS,
      Control::ApplicationsRequest.new([app])), IMCode::Failure).cluster_status.should eq(0x08_u8)
    expect_status(invoke(cluster, Control::CMD_REMOVE_BLOCK_APPLICATIONS,
      Control::ApplicationsRequest.new([app, absent])), IMCode::Failure).cluster_status.should eq(0x09_u8)
    expect_success(invoke(cluster, Control::CMD_ADD_BLOCK_APPLICATIONS,
      Control::ApplicationsRequest.new([] of Control::AppInfo)))
    expect_success(invoke(cluster, Control::CMD_REMOVE_BLOCK_APPLICATIONS,
      Control::ApplicationsRequest.new([] of Control::AppInfo)))
    read_tlv(cluster, Control::ATTR_BLOCK_APPLICATION_LIST).as_list.size.should eq(1)
    expect_success(invoke(cluster, Control::CMD_REMOVE_BLOCK_APPLICATIONS,
      Control::ApplicationsRequest.new([app])))
    read_tlv(cluster, Control::ATTR_BLOCK_APPLICATION_LIST).as_list.should be_empty
  end

  it "assigns unique channel indexes and atomically rejects absent indexes" do
    cluster = build(Control, feature_map: Control::Feature::BlockChannels)
    cluster.on_validate_channel { |channel| channel.major_number > 0 }
    first = Control::BlockChannel.new(nil, 12_u16, 1_u16, "news")
    second = Control::BlockChannel.new(nil, 13_u16, 2_u16, "sport")
    expect_success(invoke(cluster, Control::CMD_ADD_BLOCK_CHANNELS,
      Control::ChannelsRequest.new([first, second])))
    channels = read_tlv(cluster, Control::ATTR_BLOCK_CHANNEL_LIST).as_list.map { |value| Control::BlockChannel.from_tlv(value) }
    channels.map(&.block_channel_index).should eq([0_u16, 1_u16])
    expect_status(invoke(cluster, Control::CMD_REMOVE_BLOCK_CHANNELS,
      Control::ChannelIndexesRequest.new([0_u16, 9_u16])), IMCode::Failure).cluster_status.should eq(0x06_u8)
    expect_success(invoke(cluster, Control::CMD_ADD_BLOCK_CHANNELS,
      Control::ChannelsRequest.new([] of Control::BlockChannel)))
    expect_success(invoke(cluster, Control::CMD_REMOVE_BLOCK_CHANNELS,
      Control::ChannelIndexesRequest.new([] of UInt16)))
    read_tlv(cluster, Control::ATTR_BLOCK_CHANNEL_LIST).as_list.size.should eq(2)
    expect_success(invoke(cluster, Control::CMD_REMOVE_BLOCK_CHANNELS,
      Control::ChannelIndexesRequest.new([0_u16])))
    read_tlv(cluster, Control::ATTR_BLOCK_CHANNEL_LIST).as_list.size.should eq(1)
    expect_success(invoke(cluster, Control::CMD_ENABLE))
    cluster.playback_allowed?(rating: "G", channel: second).should be_false
    cluster.playback_allowed?(rating: "G", channel: first).should be_true
  end

  it "keeps scheduled rating decisions separate from on-demand ratings" do
    ratings = [Control::RatingName.new("U"), Control::RatingName.new("12"), Control::RatingName.new("18")]
    cluster = build(Control, feature_map: Control::Feature::ScheduledContentRating,
      scheduled_content_ratings: ratings, scheduled_content_rating_threshold: "18")
    expect_status(invoke(cluster, Control::CMD_SET_SCHEDULED_CONTENT_RATING_THRESHOLD,
      Control::SetRatingRequest.new("X")), IMCode::Failure).cluster_status.should eq(0x03_u8)
    expect_success(invoke(cluster, Control::CMD_SET_SCHEDULED_CONTENT_RATING_THRESHOLD,
      Control::SetRatingRequest.new("12")))
    expect_success(invoke(cluster, Control::CMD_ENABLE))
    cluster.playback_allowed?(rating: "U", scheduled: true).should be_true
    cluster.playback_allowed?(rating: "12", scheduled: true).should be_false
    cluster.playback_allowed?(rating: "12", scheduled: false).should be_true
  end

  it "lets the host enforce the configured playback policy" do
    ratings = [Control::RatingName.new("G"), Control::RatingName.new("PG"), Control::RatingName.new("R")]
    cluster = build(Control, feature_map: Control::Feature::OnDemandContentRating |
                                          Control::Feature::BlockUnrated | Control::Feature::BlockApplications,
      on_demand_ratings: ratings, on_demand_rating_threshold: "R")
    app = Control::AppInfo.new(0xFFF1_u16, "radio")
    expect_success(invoke(cluster, Control::CMD_SET_ON_DEMAND_RATING_THRESHOLD,
      Control::SetRatingRequest.new("PG")))
    expect_success(invoke(cluster, Control::CMD_ADD_BLOCK_APPLICATIONS,
      Control::ApplicationsRequest.new([app])))
    expect_success(invoke(cluster, Control::CMD_BLOCK_UNRATED_CONTENT))
    cluster.playback_allowed?(rating: "R", application: app).should be_true
    expect_success(invoke(cluster, Control::CMD_ENABLE))
    cluster.playback_allowed?(rating: "G").should be_true
    cluster.playback_allowed?(rating: "PG").should be_false
    cluster.playback_allowed?(rating: "R").should be_false
    cluster.playback_allowed?(rating: nil).should be_false
    cluster.playback_allowed?(rating: "G", application: app).should be_false
  end

  it "rejects optional feature bits whose behavior is not implemented yet" do
    expect_raises(ArgumentError) do
      build(Control, feature_map: Control::Feature::OnDemandContentRating,
        on_demand_ratings: [Control::RatingName.new("G")])
    end
    expect_raises(ArgumentError) do
      build(Control, block_application_list: [Control::AppInfo.new(0xFFF1_u16, "radio")])
    end
  end

  it "accounts ScreenTime during enabled playback, expires once, and restores its balance" do
    now = Time.local(2026, 10, 26, 10, 0, 0)
    cluster = build(Control, feature_map: Control::Feature::ScreenTime, screen_daily_time: 30_u32)
    cluster.local_time_provider = -> : Time? { now }
    attribute_ids(cluster).should contain(Control::ATTR_SCREEN_DAILY_TIME)
    attribute_ids(cluster).should contain(Control::ATTR_REMAINING_SCREEN_TIME)
    accepted_command_ids(cluster).should contain(Control::CMD_ADD_BONUS_TIME)
    accepted_command_ids(cluster).should contain(Control::CMD_SET_SCREEN_DAILY_TIME)
    cluster.get_command_metadata(Control::CMD_ADD_BONUS_TIME).as(Matter::Cluster::CommandMetadata).access.should eq(Matter::InteractionModel::EntryPrivilege::Operate)
    cluster.get_command_metadata(Control::CMD_SET_SCREEN_DAILY_TIME).as(Matter::Cluster::CommandMetadata).access.should eq(Matter::InteractionModel::EntryPrivilege::Manage)
    event = cluster.get_event_metadata(Control::EVENT_REMAINING_SCREEN_TIME_EXPIRED).as(Matter::Cluster::EventMetadata)
    event.access.should eq(Matter::InteractionModel::EntryPrivilege::View)
    event.priority.should eq(Matter::InteractionModel::EventPriority::Info)
    [Control::ATTR_SCREEN_DAILY_TIME, Control::ATTR_REMAINING_SCREEN_TIME].each do |id|
      metadata = cluster.get_attribute_metadata(id).as(Matter::Cluster::AttributeMetadata)
      metadata.writable?.should be_false
      metadata.max.should eq(86_400_i64)
    end
    read(cluster, Control::ATTR_REMAINING_SCREEN_TIME).should eq(30_u32)
    events = [] of UInt32
    cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, id : UInt32, _priority : Matter::InteractionModel::EventPriority, _data : TLV::Any, _fabric : UInt8?) do
      events << id
    end
    tick = Time.instant
    cluster.tick_screen_time(true, now, tick)
    cluster.tick_screen_time(true, now + 5.seconds, tick + 5.seconds)
    read(cluster, Control::ATTR_REMAINING_SCREEN_TIME).should eq(30_u32)
    expect_success(invoke(cluster, Control::CMD_ENABLE))
    cluster.tick_screen_time(true, now + 10.seconds, tick + 10.seconds)
    cluster.tick_screen_time(false, now + 20.seconds, tick + 20.seconds)
    read(cluster, Control::ATTR_REMAINING_SCREEN_TIME).should eq(20_u32)
    cluster.tick_screen_time(false, now + 25.seconds, tick + 25.seconds)
    read(cluster, Control::ATTR_REMAINING_SCREEN_TIME).should eq(20_u32)
    cluster.tick_screen_time(true, now + 26.seconds, tick + 26.seconds)
    cluster.tick_screen_time(true, now + 46.seconds, tick + 46.seconds)
    read(cluster, Control::ATTR_REMAINING_SCREEN_TIME).should eq(0_u32)
    cluster.playback_allowed?.should be_false
    events.should eq([Control::EVENT_REMAINING_SCREEN_TIME_EXPIRED])
    cluster.tick_screen_time(true, now + 50.seconds, tick + 50.seconds)
    events.size.should eq(1)

    restored = build(Control, feature_map: Control::Feature::ScreenTime, screen_daily_time: 30_u32)
    restored.local_time_provider = -> : Time? { now + 55.seconds }
    restored.restore_state(Matter::Storage.deep_copy(cluster.save_state))
    read(restored, Control::ATTR_REMAINING_SCREEN_TIME).should eq(0_u32)
    restored.local_time_provider = -> : Time? { now + 1.day }
    read(restored, Control::ATTR_REMAINING_SCREEN_TIME).should eq(30_u32)
    restored.playback_allowed?.should be_true

    [-1_i64, 86_401_i64, 86_401_u64, "invalid"].each do |invalid_value|
      invalid = Matter::Storage.deep_copy(cluster.save_state)
      invalid[Control::PERSISTED_SCREEN_REMAINING_KEY] = invalid_value
      rejected = build(Control, feature_map: Control::Feature::ScreenTime, screen_daily_time: 30_u32)
      rejected.restore_state(invalid)
      read(rejected, Control::ATTR_REMAINING_SCREEN_TIME).should eq(30_u32)
    end

    legacy = cluster.save_state
    legacy.delete(Control::PERSISTED_SCREEN_DAY_KEY)
    legacy.delete(Control::PERSISTED_SCREEN_REMAINING_KEY)
    upgraded = build(Control, feature_map: Control::Feature::ScreenTime)
    upgraded.restore_state(legacy)
    read(upgraded, Control::ATTR_REMAINING_SCREEN_TIME).should eq(30_u32)
  end

  it "enforces ScreenTime command bounds, daily rollover, and PIN policy" do
    cluster = build(Control, feature_map: Control::Feature::ScreenTime | Control::Feature::PinManagement,
      screen_daily_time: 60_u32)
    now = Time.local(2026, 10, 26, 23, 59, 0)
    cluster.local_time_provider = -> : Time? { now }
    pin = invoke_response(cluster, Control::CMD_RESET_PIN, nil, Control::ResetPinResponse).pin_code
    expect_status(invoke(cluster, Control::CMD_ADD_BONUS_TIME,
      Control::AddBonusTimeRequest.new("000000", 10_u32)), IMCode::Failure).cluster_status.should eq(0x02_u8)
    expect_success(invoke(cluster, Control::CMD_ADD_BONUS_TIME,
      Control::AddBonusTimeRequest.new(pin, 10_u32)))
    read(cluster, Control::ATTR_REMAINING_SCREEN_TIME).should eq(70_u32)
    expect_status(invoke(cluster, Control::CMD_ADD_BONUS_TIME,
      Control::AddBonusTimeRequest.new(pin, 61_u32)), IMCode::ConstraintError)
    expect_status(invoke(cluster, Control::CMD_SET_SCREEN_DAILY_TIME,
      Control::SetScreenDailyTimeRequest.new(86_401_u32)), IMCode::ConstraintError)
    expect_success(invoke(cluster, Control::CMD_SET_SCREEN_DAILY_TIME,
      Control::SetScreenDailyTimeRequest.new(120_u32)))
    read(cluster, Control::ATTR_REMAINING_SCREEN_TIME).should eq(70_u32)
    cluster.local_time_provider = -> : Time? { now + 1.minute }
    read(cluster, Control::ATTR_REMAINING_SCREEN_TIME).should eq(120_u32)
    expect_success(invoke(cluster, Control::CMD_ADD_BONUS_TIME,
      Control::AddBonusTimeRequest.new(pin)))
    read(cluster, Control::ATTR_REMAINING_SCREEN_TIME).should eq(420_u32)
    without_pin = build(Control, feature_map: Control::Feature::ScreenTime)
    expect_status(invoke(without_pin, Control::CMD_ADD_BONUS_TIME,
      Control::AddBonusTimeRequest.new("123456", 5_u32)), IMCode::Failure).cluster_status.should eq(0x02_u8)
  end

  it "splits watched time at midnight and keeps fractional seconds" do
    start = Time.local(2026, 10, 26, 23, 59, 58)
    cluster = build(Control, feature_map: Control::Feature::ScreenTime, screen_daily_time: 10_u32)
    cluster.local_time_provider = -> : Time? { start }
    expect_success(invoke(cluster, Control::CMD_ENABLE))
    instant = Time.instant
    cluster.tick_screen_time(true, start, instant)
    cluster.tick_screen_time(true, start + 500.milliseconds, instant + 500.milliseconds)
    read(cluster, Control::ATTR_REMAINING_SCREEN_TIME).should eq(10_u32)
    cluster.tick_screen_time(true, start + 1.second, instant + 1.second)
    read(cluster, Control::ATTR_REMAINING_SCREEN_TIME).should eq(9_u32)
    cluster.tick_screen_time(true, start + 4.seconds, instant + 4.seconds)
    cluster.local_time_provider = -> : Time? { start + 4.seconds }
    read(cluster, Control::ATTR_REMAINING_SCREEN_TIME).should eq(8_u32)
    cluster.tick_screen_time(true, start + 5.seconds, instant + 5.seconds)
    read(cluster, Control::ATTR_REMAINING_SCREEN_TIME).should eq(7_u32)
    cluster.local_time_provider = -> : Time? { start }
    read(cluster, Control::ATTR_REMAINING_SCREEN_TIME).should eq(7_u32)

    other = build(Control, feature_map: Control::Feature::ScreenTime, screen_daily_time: 10_u32)
    other.local_time_provider = -> : Time? { start }
    expect_success(invoke(other, Control::CMD_ENABLE))
    other.tick_screen_time(true, start, instant)
    other.local_time_provider = -> : Time? { start + 4.seconds }
    read(other, Control::ATTR_REMAINING_SCREEN_TIME).should eq(10_u32)
    other.tick_screen_time(true, start + 4.seconds, instant + 4.seconds)
    read(other, Control::ATTR_REMAINING_SCREEN_TIME).should eq(8_u32)
  end

  it "uses the actual local midnight for the bonus cap across daylight saving" do
    location = Time::Location.load("Australia/Sydney")
    now = Time.local(2026, 10, 4, 1, 0, 0, location: location)
    cluster = build(Control, feature_map: Control::Feature::ScreenTime)
    cluster.local_time_provider = -> : Time? { now }
    cluster.request_command_privilege = Matter::InteractionModel::EntryPrivilege::Manage
    expect_status(invoke(cluster, Control::CMD_ADD_BONUS_TIME,
      Control::AddBonusTimeRequest.new(nil, 80_000_u32)), IMCode::ConstraintError)
    cluster.request_command_privilege = Matter::InteractionModel::EntryPrivilege::Manage
    expect_success(invoke(cluster, Control::CMD_ADD_BONUS_TIME,
      Control::AddBonusTimeRequest.new(nil, 79_200_u32)))
    read(cluster, Control::ATTR_REMAINING_SCREEN_TIME).should eq(79_200_u32)
  end

  it "manages indexed content time windows atomically and persists them" do
    cluster = build(Control, feature_map: Control::Feature::BlockContentTimeWindow)
    accepted_command_ids(cluster).should contain(Control::CMD_SET_BLOCK_CONTENT_TIME_WINDOW)
    accepted_command_ids(cluster).should contain(Control::CMD_REMOVE_BLOCK_CONTENT_TIME_WINDOW)
    attribute_ids(cluster).should contain(Control::ATTR_BLOCK_CONTENT_TIME_WINDOW)
    cluster.get_command_metadata(Control::CMD_SET_BLOCK_CONTENT_TIME_WINDOW).as(Matter::Cluster::CommandMetadata).access.should eq(Matter::InteractionModel::EntryPrivilege::Manage)
    cluster.get_command_metadata(Control::CMD_REMOVE_BLOCK_CONTENT_TIME_WINDOW).as(Matter::Cluster::CommandMetadata).access.should eq(Matter::InteractionModel::EntryPrivilege::Manage)
    event = cluster.get_event_metadata(Control::EVENT_ENTERING_BLOCK_CONTENT_TIME_WINDOW).as(Matter::Cluster::EventMetadata)
    event.access.should eq(Matter::InteractionModel::EntryPrivilege::View)
    event.priority.should eq(Matter::InteractionModel::EventPriority::Info)
    build(Control).get_event_metadata(Control::EVENT_ENTERING_BLOCK_CONTENT_TIME_WINDOW).should be_nil
    monday = Control::TimeWindow.new(nil, 0x02_u8, [Control::TimePeriod.new(9_u8, 0_u8, 10_u8, 30_u8)])
    expect_success(invoke(cluster, Control::CMD_SET_BLOCK_CONTENT_TIME_WINDOW, Control::SetTimeWindowRequest.new(monday)))
    windows = read_tlv(cluster, Control::ATTR_BLOCK_CONTENT_TIME_WINDOW).as_list.map { |item| Control::TimeWindow.from_tlv(item) }
    windows.first.time_window_index.should eq(0_u16)
    expect_status(invoke(cluster, Control::CMD_SET_BLOCK_CONTENT_TIME_WINDOW, Control::SetTimeWindowRequest.new(monday)), IMCode::Failure).cluster_status.should eq(0x0A_u8)
    overlap = Control::TimeWindow.new(nil, 0x03_u8, [Control::TimePeriod.new(11_u8, 0_u8, 12_u8, 0_u8)])
    expect_status(invoke(cluster, Control::CMD_SET_BLOCK_CONTENT_TIME_WINDOW, Control::SetTimeWindowRequest.new(overlap)), IMCode::ConstraintError)
    bad_period = Control::TimeWindow.new(0_u16, 0x02_u8, [Control::TimePeriod.new(10_u8, 30_u8, 10_u8, 30_u8)])
    expect_status(invoke(cluster, Control::CMD_SET_BLOCK_CONTENT_TIME_WINDOW, Control::SetTimeWindowRequest.new(bad_period)), IMCode::ConstraintError)
    overlapping_periods = Control::TimeWindow.new(0_u16, 0x02_u8, [
      Control::TimePeriod.new(9_u8, 0_u8, 10_u8, 30_u8),
      Control::TimePeriod.new(10_u8, 0_u8, 11_u8, 0_u8),
    ])
    expect_status(invoke(cluster, Control::CMD_SET_BLOCK_CONTENT_TIME_WINDOW, Control::SetTimeWindowRequest.new(overlapping_periods)), IMCode::ConstraintError)
    replacement = Control::TimeWindow.new(0_u16, 0x02_u8, [Control::TimePeriod.new(11_u8, 0_u8, 12_u8, 0_u8)])
    expect_success(invoke(cluster, Control::CMD_SET_BLOCK_CONTENT_TIME_WINDOW, Control::SetTimeWindowRequest.new(replacement)))
    expect_status(invoke(cluster, Control::CMD_REMOVE_BLOCK_CONTENT_TIME_WINDOW,
      Control::RemoveTimeWindowsRequest.new([0_u16, 99_u16])), IMCode::Failure).cluster_status.should eq(0x0B_u8)
    read_tlv(cluster, Control::ATTR_BLOCK_CONTENT_TIME_WINDOW).as_list.size.should eq(1)
    restored = build(Control, feature_map: Control::Feature::BlockContentTimeWindow)
    restored.restore_state(cluster.save_state)
    restored.block_content_time_window.first.time_period.first.start_hour.should eq(11_u8)
    expect_success(invoke(restored, Control::CMD_REMOVE_BLOCK_CONTENT_TIME_WINDOW,
      Control::RemoveTimeWindowsRequest.new([0_u16])))
    read_tlv(restored, Control::ATTR_BLOCK_CONTENT_TIME_WINDOW).as_list.should be_empty
  end

  it "blocks playback and emits one entry event at a local time boundary" do
    cluster = build(Control, feature_map: Control::Feature::BlockContentTimeWindow)
    clock = Time.local(2026, 10, 26, 8, 59, 0)
    cluster.local_time_provider = -> : Time? { clock }
    events = [] of UInt32
    cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, event : UInt32, _priority : Matter::InteractionModel::EventPriority, _data : TLV::Any, _fabric : UInt8?) do
      events << event
      nil
    end
    policy_calls = 0
    cluster.on_policy_changed { policy_calls += 1 }
    monday = Control::TimeWindow.new(nil, 0x02_u8, [
      Control::TimePeriod.new(9_u8, 0_u8, 10_u8, 0_u8),
      Control::TimePeriod.new(10_u8, 1_u8, 10_u8, 30_u8),
    ])
    expect_success(invoke(cluster, Control::CMD_SET_BLOCK_CONTENT_TIME_WINDOW, Control::SetTimeWindowRequest.new(monday)))
    expect_success(invoke(cluster, Control::CMD_ENABLE))
    cluster.tick_block_content_time_window
    cluster.playback_allowed?.should be_true
    cluster.local_time_provider = -> : Time? { nil }
    cluster.tick_block_content_time_window
    cluster.playback_allowed?.should be_false
    events.should be_empty
    cluster.local_time_provider = -> : Time? { clock }
    clock = Time.local(2026, 10, 26, 9, 0, 0)
    cluster.tick_block_content_time_window
    cluster.playback_allowed?.should be_false
    events.should eq([Control::EVENT_ENTERING_BLOCK_CONTENT_TIME_WINDOW])
    cluster.tick_block_content_time_window
    events.size.should eq(1)
    policy_calls.should eq(3)
    clock = Time.local(2026, 10, 26, 10, 1, 0)
    cluster.tick_block_content_time_window
    events.size.should eq(2)
    policy_calls.should eq(4)
    cluster.playback_allowed?.should be_false
    clock = Time.local(2026, 10, 26, 10, 31, 0)
    cluster.tick_block_content_time_window
    cluster.playback_allowed?.should be_true
  end

  it "updates and resets a private PIN with timed Manage and Administer access" do
    cluster = build(Control, feature_map: Control::Feature::PinManagement)
    accepted_command_ids(cluster).should eq([
      Control::CMD_UPDATE_PIN, Control::CMD_RESET_PIN,
      Control::CMD_ENABLE, Control::CMD_DISABLE,
    ])
    update = cluster.get_command_metadata(Control::CMD_UPDATE_PIN).as(Matter::Cluster::CommandMetadata)
    update.access.should eq(Matter::InteractionModel::EntryPrivilege::Manage)
    update.timed?.should be_true
    reset = cluster.get_command_metadata(Control::CMD_RESET_PIN).as(Matter::Cluster::CommandMetadata)
    reset.access.should eq(Matter::InteractionModel::EntryPrivilege::Administer)
    reset.timed?.should be_true
    reset.response_id.should eq(Control::CMD_RESET_PIN_RESPONSE)
    generated_command_ids(cluster).should contain(Control::CMD_RESET_PIN_RESPONSE)

    first = invoke_response(cluster, Control::CMD_RESET_PIN, nil, Control::ResetPinResponse).pin_code
    first.should match(/\A\d{6}\z/)
    wrong = first == "000000" ? "111111" : "000000"
    expect_status(invoke(cluster, Control::CMD_UPDATE_PIN,
      Control::UpdatePinRequest.new(wrong, "123456")), IMCode::Failure).cluster_status.should eq(0x02_u8)
    expect_status(invoke(cluster, Control::CMD_UPDATE_PIN,
      Control::UpdatePinRequest.new(first, "1234567")), IMCode::ConstraintError)
    expect_status(invoke(cluster, Control::CMD_UPDATE_PIN,
      Control::UpdatePinRequest.new(first, "12A456")), IMCode::ConstraintError)
    expect_success(invoke(cluster, Control::CMD_UPDATE_PIN,
      Control::UpdatePinRequest.new(first, "123456")))
    expect_status(invoke(cluster, Control::CMD_UPDATE_PIN,
      Control::UpdatePinRequest.new(first, "234567")), IMCode::Failure).cluster_status.should eq(0x02_u8)

    saved = cluster.save_state
    saved["pin_code"]?.should be_nil
    saved["pin_salt"]?.should be_a(Bytes)
    saved["pin_verifier"]?.should be_a(Bytes)
    restored = build(Control, feature_map: Control::Feature::PinManagement)
    restored.restore_state(saved)
    expect_success(invoke(restored, Control::CMD_UPDATE_PIN,
      Control::UpdatePinRequest.new("123456", "234567")))
    second = invoke_response(restored, Control::CMD_RESET_PIN, nil, Control::ResetPinResponse).pin_code
    second.should_not eq("234567")
    expect_status(invoke(restored, Control::CMD_UPDATE_PIN,
      Control::UpdatePinRequest.new("234567", "345678")), IMCode::Failure).cluster_status.should eq(0x02_u8)
    expect_success(invoke(restored, Control::CMD_UPDATE_PIN,
      Control::UpdatePinRequest.new(second, "345678")))
    accepted_command_ids(build(Control)).should eq([Control::CMD_ENABLE, Control::CMD_DISABLE])
  end

  it "upgrades a pre-PIN document with a fresh private PIN" do
    legacy = build(Control).save_state
    legacy.delete("features")
    upgraded = build(Control, feature_map: Control::Feature::PinManagement)
    upgraded.restore_state(legacy)
    reset = invoke_response(upgraded, Control::CMD_RESET_PIN, nil, Control::ResetPinResponse)
    expect_success(invoke(upgraded, Control::CMD_UPDATE_PIN,
      Control::UpdatePinRequest.new(reset.pin_code, "123456")))
  end

  it "notifies a media host of policy changes and restores configured lists" do
    app = Control::AppInfo.new(0xFFF1_u16, "radio")
    cluster = build(Control, feature_map: Control::Feature::BlockApplications | Control::Feature::BlockUnrated)
    calls = 0
    cluster.on_policy_changed { calls += 1 }
    cluster.on_identify_application { |candidate| candidate.application_id == "radio" }
    expect_status(invoke(cluster, Control::CMD_ADD_BLOCK_APPLICATIONS,
      Control::ApplicationsRequest.new([Control::AppInfo.new(0xFFF1_u16, "unknown")])),
      IMCode::Failure).cluster_status.should eq(0x07_u8)
    calls.should eq(0)
    expect_success(invoke(cluster, Control::CMD_ADD_BLOCK_APPLICATIONS,
      Control::ApplicationsRequest.new([app])))
    expect_success(invoke(cluster, Control::CMD_BLOCK_UNRATED_CONTENT))
    expect_success(invoke(cluster, Control::CMD_ENABLE))
    calls.should eq(3)
    cluster.playback_allowed?(rating: "PG").should be_true
    cluster.playback_allowed?(rating: nil).should be_false

    restored = build(Control, feature_map: Control::Feature::BlockApplications | Control::Feature::BlockUnrated)
    restored.restore_state(cluster.save_state)
    read_tlv(restored, Control::ATTR_BLOCK_APPLICATION_LIST).as_list.size.should eq(1)
    restored.playback_allowed?(application: app, rating: "PG").should be_false
  end
end
