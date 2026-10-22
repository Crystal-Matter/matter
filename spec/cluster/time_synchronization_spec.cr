require "../spec_helper"
require "../../src/matter/cluster/time_synchronization"

private alias TimeSync = Matter::Cluster::TimeSynchronization

private def zone(offset : Int32, valid_at : UInt64, name : String? = nil)
  TimeSync::TimeZoneStruct.new(offset, valid_at, name)
end

private def dst(offset : Int32, starts : UInt64, ends : UInt64?)
  TimeSync::DstOffsetStruct.new(offset, starts, ends)
end

describe TimeSync do
  it "exposes the mandatory Matter 1.6 time state without claiming synchronization" do
    cluster = TimeSync.new(endpoint(0))
    TimeSync::CLUSTER_ID.should eq(0x0038_u32)
    TimeSync::CLUSTER_REVISION.should eq(2_u16)
    read(cluster, TimeSync::ATTR_UTC_TIME).should be_nil
    read(cluster, TimeSync::ATTR_GRANULARITY).should eq(TimeSync::Granularity::NoTime.value)
    read(cluster, TimeSync::ATTR_TIME_SOURCE).should eq(TimeSync::TimeSource::None.value)
    read(cluster, Matter::Cluster::Base::GLOBAL_FEATURE_MAP).should eq(0_u32)
    command = cluster.get_command_metadata(TimeSync::CMD_SET_UTC_TIME)
    command.as(Matter::Cluster::CommandMetadata).access.should eq(Matter::InteractionModel::EntryPrivilege::Administer)
    cluster.get_event_metadata(TimeSync::EVENT_TIME_FAILURE).should_not be_nil
  end

  it "sets UTC from an administrator and advances it with a monotonic clock" do
    cluster = TimeSync.new(endpoint(0))
    request = TimeSync::SetUtcTimeRequest.new(123_456_000_000_u64,
      TimeSync::Granularity::Seconds, TimeSync::TimeSource::NodeTimeCluster)
    result = cluster.invoke_command(TimeSync::CMD_SET_UTC_TIME,
      request.to_tlv(nil), is_case_session: true, fabric_index: 1_u8)
    result.as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::Success)
    first = read(cluster, TimeSync::ATTR_UTC_TIME).as(UInt64)
    first.should be >= request.utc_time
    sleep 5.milliseconds
    second = read(cluster, TimeSync::ATTR_UTC_TIME).as(UInt64)
    second.should be > first
    read(cluster, TimeSync::ATTR_TIME_SOURCE).should eq(TimeSync::TimeSource::Admin.value)
    read(cluster, TimeSync::ATTR_GRANULARITY).should eq(TimeSync::Granularity::Seconds.value)
  end

  it "declines a lower-quality update without replacing synchronized time" do
    cluster = TimeSync.new(endpoint(0))
    cluster.apply_utc_time(TimeSync::SetUtcTimeRequest.new(123_456_000_000_u64,
      TimeSync::Granularity::Seconds, TimeSync::TimeSource::Admin))
    request = TimeSync::SetUtcTimeRequest.new(123_456_000_000_u64,
      TimeSync::Granularity::NoTime, TimeSync::TimeSource::None)
    result = cluster.invoke_command(TimeSync::CMD_SET_UTC_TIME,
      request.to_tlv(nil), is_case_session: true, fabric_index: 1_u8)
    status = result.as(Matter::InteractionModel::Status)
    status.cluster_status.should eq(TimeSync::TIME_NOT_ACCEPTED)
    read(cluster, TimeSync::ATTR_UTC_TIME).should_not be_nil
  end

  it "rejects a NoTime administrator update even when it has no synchronized clock" do
    cluster = TimeSync.new(endpoint(0))
    request = TimeSync::SetUtcTimeRequest.new(0_u64, TimeSync::Granularity::NoTime)
    result = cluster.invoke_command(TimeSync::CMD_SET_UTC_TIME,
      request.to_tlv(nil), is_case_session: true, fabric_index: 1_u8)
    result.as(Matter::InteractionModel::Status).cluster_status.should eq(TimeSync::TIME_NOT_ACCEPTED)
    read(cluster, TimeSync::ATTR_UTC_TIME).should be_nil
    read(cluster, TimeSync::ATTR_GRANULARITY).should eq(TimeSync::Granularity::NoTime.value)
  end

  it "keeps the accepted granularity and rejects a less precise update" do
    cluster = TimeSync.new(endpoint(0))
    first = cluster.apply_utc_time(TimeSync::SetUtcTimeRequest.new(123_456_000_000_u64,
      TimeSync::Granularity::Milliseconds))
    first.status.should eq(Matter::InteractionModel::StatusCode::Success)
    read(cluster, TimeSync::ATTR_GRANULARITY).should eq(TimeSync::Granularity::Milliseconds.value)

    rejected = cluster.apply_utc_time(TimeSync::SetUtcTimeRequest.new(223_456_000_000_u64,
      TimeSync::Granularity::Seconds))
    rejected.cluster_status.should eq(TimeSync::TIME_NOT_ACCEPTED)
    read(cluster, TimeSync::ATTR_GRANULARITY).should eq(TimeSync::Granularity::Milliseconds.value)
    read(cluster, TimeSync::ATTR_UTC_TIME).as(UInt64).should be < 223_456_000_000_u64
  end

  it "forgets untrusted monotonic time after restart" do
    cluster = TimeSync.new(endpoint(0))
    cluster.apply_utc_time(TimeSync::SetUtcTimeRequest.new(123_456_000_000_u64,
      TimeSync::Granularity::Seconds, TimeSync::TimeSource::Admin))
    cluster.save_state.should be_nil
    restarted = TimeSync.new(endpoint(0))
    read(restarted, TimeSync::ATTR_UTC_TIME).should be_nil
    read(restarted, TimeSync::ATTR_GRANULARITY).should eq(TimeSync::Granularity::NoTime.value)
  end

  it "emits TimeFailure once when a source is lost and suppresses repeats within an hour" do
    cluster = TimeSync.new(endpoint(0))
    events = [] of UInt32
    cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, event : UInt32, _priority : Matter::InteractionModel::EventPriority, _data : TLV::Any, _fabric : UInt8?) do
      events << event
      nil
    end
    cluster.apply_utc_time(TimeSync::SetUtcTimeRequest.new(123_456_000_000_u64,
      TimeSync::Granularity::Seconds, TimeSync::TimeSource::Admin))
    cluster.report_time_failure.should_not be_nil
    cluster.report_time_failure.should be_nil
    events.should eq([TimeSync::EVENT_TIME_FAILURE])
    read(cluster, TimeSync::ATTR_UTC_TIME).should be_nil
    read(cluster, TimeSync::ATTR_GRANULARITY).should eq(TimeSync::Granularity::NoTime.value)
  end
end

describe "Matter 1.6 TimeZone feature" do
  it "only exposes the TimeZone elements when the feature is enabled" do
    base = TimeSync.new(endpoint(0))
    base.get_attribute_metadata(TimeSync::ATTR_TIME_ZONE).should be_nil
    base.get_command_metadata(TimeSync::CMD_SET_TIME_ZONE).should be_nil
    base.get_event_metadata(TimeSync::EVENT_DST_STATUS).should be_nil

    cluster = TimeSync.new(endpoint(0), feature_map: TimeSync::Feature::TimeZone)
    read(cluster, Matter::Cluster::Base::GLOBAL_FEATURE_MAP).should eq(1_u32)
    read(cluster, TimeSync::ATTR_TIME_ZONE_LIST_MAX_SIZE).should eq(2_u8)
    read(cluster, TimeSync::ATTR_DST_OFFSET_LIST_MAX_SIZE).should eq(4_u8)
    read(cluster, TimeSync::ATTR_TIME_ZONE_DATABASE).should eq(TimeSync::TimeZoneDatabase::None.value)
    cluster.get_attribute_metadata(TimeSync::ATTR_LOCAL_TIME).should_not be_nil
    cluster.get_event_metadata(TimeSync::EVENT_DST_TABLE_EMPTY).should_not be_nil
    cluster.get_event_metadata(TimeSync::EVENT_TIME_ZONE_STATUS).should_not be_nil
    cluster.get_command_metadata(TimeSync::CMD_SET_TIME_ZONE).as(Matter::Cluster::CommandMetadata).access.should eq(Matter::InteractionModel::EntryPrivilege::Manage)
    cluster.get_command_metadata(TimeSync::CMD_SET_DST_OFFSET).as(Matter::Cluster::CommandMetadata).access.should eq(Matter::InteractionModel::EntryPrivilege::Manage)
  end

  it "encodes the two commands and response using their Matter 1.6 TLV tags" do
    zones = [zone(-43_200, 0_u64, "America/New_York"), zone(50_400, 100_u64)]
    TimeSync::SetTimeZoneRequest.from_slice(TimeSync::SetTimeZoneRequest.new(zones).to_slice).time_zone.should eq(zones)
    offsets = [dst(3_600, 0_u64, nil)]
    TimeSync::SetDstOffsetRequest.from_slice(TimeSync::SetDstOffsetRequest.new(offsets).to_slice).dst_offset.should eq(offsets)
    TimeSync::SetTimeZoneResponse.from_slice(TimeSync::SetTimeZoneResponse.new(true).to_slice).dst_offset_required?.should be_true
  end

  it "validates complete time-zone lists atomically and clears stale DST" do
    cluster = TimeSync.new(endpoint(0), feature_map: TimeSync::Feature::TimeZone)
    accepted = cluster.apply_time_zone(TimeSync::SetTimeZoneRequest.new([zone(36_000, 0_u64, "Australia/Sydney")]))
    accepted.as(TimeSync::SetTimeZoneResponse).dst_offset_required?.should be_true
    cluster.apply_dst_offset(TimeSync::SetDstOffsetRequest.new([dst(3_600, 0_u64, nil)]))

    cluster.apply_time_zone(TimeSync::SetTimeZoneRequest.new([zone(0, 0_u64), zone(1, 1_u64), zone(2, 2_u64)]))
      .as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::ResourceExhausted)
    cluster.apply_time_zone(TimeSync::SetTimeZoneRequest.new([zone(50_401, 0_u64)]))
      .as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    cluster.apply_time_zone(TimeSync::SetTimeZoneRequest.new([zone(0, 10_u64)]))
      .as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    cluster.time_zone.should eq([zone(36_000, 0_u64, "Australia/Sydney")])
    cluster.dst_offset.should eq([dst(3_600, 0_u64, nil)])

    cluster.apply_time_zone(TimeSync::SetTimeZoneRequest.new([zone(0, 0_u64)]))
    cluster.dst_offset.should be_empty
    cluster.local_time.should be_nil
  end

  it "validates sorted non-overlapping DST lists and calculates local time" do
    cluster = TimeSync.new(endpoint(0), feature_map: TimeSync::Feature::TimeZone)
    cluster.apply_time_zone(TimeSync::SetTimeZoneRequest.new([zone(36_000, 0_u64)]))
    cluster.local_time.should be_nil
    cluster.apply_utc_time(TimeSync::SetUtcTimeRequest.new(1_000_000_000_u64, TimeSync::Granularity::Seconds))
    cluster.local_time.should be_nil

    cluster.apply_dst_offset(TimeSync::SetDstOffsetRequest.new([dst(3_600, 0_u64, nil)]))
    local = cluster.local_time.as(UInt64)
    local.should be >= 40_600_000_000_u64
    local.should be < 40_601_000_000_u64

    invalid = [dst(3_600, 100_u64, 200_u64), dst(0, 150_u64, nil)]
    cluster.apply_dst_offset(TimeSync::SetDstOffsetRequest.new(invalid))
      .status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    cluster.dst_offset.should eq([dst(3_600, 0_u64, nil)])
    cluster.apply_dst_offset(TimeSync::SetDstOffsetRequest.new([dst(3_600, 100_u64, 100_u64)]))
      .status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    cluster.apply_dst_offset(TimeSync::SetDstOffsetRequest.new([dst(0, 0_u64, 1_u64)] * 5))
      .status.should eq(Matter::InteractionModel::StatusCode::ResourceExhausted)
  end

  it "accepts exact TimeZone bounds and the full signed DST offset range" do
    cluster = TimeSync.new(endpoint(0), feature_map: TimeSync::Feature::TimeZone)
    cluster.apply_time_zone(TimeSync::SetTimeZoneRequest.new([zone(-43_200, 0_u64, "x" * 64)]))
      .should be_a(TimeSync::SetTimeZoneResponse)
    cluster.apply_time_zone(TimeSync::SetTimeZoneRequest.new([zone(50_400, 0_u64)]))
      .should be_a(TimeSync::SetTimeZoneResponse)
    [-43_201, 50_401].each do |invalid_offset|
      cluster.apply_time_zone(TimeSync::SetTimeZoneRequest.new([zone(invalid_offset, 0_u64)]))
        .as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    end
    cluster.apply_time_zone(TimeSync::SetTimeZoneRequest.new([zone(0, 0_u64, "x" * 65)]))
      .as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    cluster.time_zone.should eq([zone(50_400, 0_u64)])

    cluster.apply_dst_offset(TimeSync::SetDstOffsetRequest.new([
      dst(Int32::MIN, 0_u64, 1_000_000_u64),
      dst(Int32::MAX, 1_000_000_u64, nil),
    ])).status.should eq(Matter::InteractionModel::StatusCode::Success)
  end

  it "uses epoch microseconds for zone boundaries and retains local time after DST entries expire" do
    cluster = TimeSync.new(endpoint(0), feature_map: TimeSync::Feature::TimeZone)
    cluster.apply_time_zone(TimeSync::SetTimeZoneRequest.new([
      zone(0, 0_u64), zone(3_600, 2_000_000_u64),
    ]))
    cluster.apply_dst_offset(TimeSync::SetDstOffsetRequest.new([dst(3_600, 0_u64, 2_000_000_u64)]))
    cluster.apply_utc_time(TimeSync::SetUtcTimeRequest.new(1_000_000_u64, TimeSync::Granularity::Seconds))
    during_dst = cluster.local_time.as(UInt64)
    during_dst.should be >= 3_601_000_000_u64
    during_dst.should be < 3_602_000_000_u64

    cluster.apply_utc_time(TimeSync::SetUtcTimeRequest.new(3_000_000_u64, TimeSync::Granularity::Seconds))
    after_dst = cluster.local_time.as(UInt64)
    after_dst.should be >= 3_603_000_000_u64
    after_dst.should be < 3_604_000_000_u64
    cluster.dst_offset.size.should eq(1)
  end

  it "emits the mandatory status and empty-table events" do
    cluster = TimeSync.new(endpoint(0), feature_map: TimeSync::Feature::TimeZone)
    events = [] of UInt32
    cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, event : UInt32, _priority : Matter::InteractionModel::EventPriority, _data : TLV::Any, _fabric : UInt8?) do
      events << event
      nil
    end
    cluster.apply_utc_time(TimeSync::SetUtcTimeRequest.new(1_000_000_000_u64, TimeSync::Granularity::Seconds))
    cluster.apply_time_zone(TimeSync::SetTimeZoneRequest.new([zone(36_000, 0_u64)]))
    events.should contain(TimeSync::EVENT_TIME_ZONE_STATUS)
    events.should contain(TimeSync::EVENT_DST_TABLE_EMPTY)
    cluster.apply_dst_offset(TimeSync::SetDstOffsetRequest.new([dst(3_600, 0_u64, nil)]))
    events.should contain(TimeSync::EVENT_DST_STATUS)
    cluster.apply_dst_offset(TimeSync::SetDstOffsetRequest.new([] of TimeSync::DstOffsetStruct))
    events.last.should eq(TimeSync::EVENT_DST_TABLE_EMPTY)
  end

  it "reports scheduled time-zone and DST transitions when UTC advances" do
    cluster = TimeSync.new(endpoint(0), feature_map: TimeSync::Feature::TimeZone)
    events = [] of UInt32
    cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, event : UInt32, _priority : Matter::InteractionModel::EventPriority, _data : TLV::Any, _fabric : UInt8?) do
      events << event
      nil
    end
    cluster.apply_utc_time(TimeSync::SetUtcTimeRequest.new(1_000_000_u64, TimeSync::Granularity::Seconds))
    cluster.apply_time_zone(TimeSync::SetTimeZoneRequest.new([zone(0, 0_u64), zone(3_600, 2_000_000_u64)]))
    cluster.apply_dst_offset(TimeSync::SetDstOffsetRequest.new([dst(3_600, 1_000_000_u64, 3_000_000_u64)]))
    events.clear

    cluster.apply_utc_time(TimeSync::SetUtcTimeRequest.new(2_100_000_u64, TimeSync::Granularity::Seconds))
    events.should contain(TimeSync::EVENT_TIME_ZONE_STATUS)
    events.clear
    cluster.apply_utc_time(TimeSync::SetUtcTimeRequest.new(3_100_000_u64, TimeSync::Granularity::Seconds))
    events.should contain(TimeSync::EVENT_DST_STATUS)
    events.should contain(TimeSync::EVENT_DST_TABLE_EMPTY)
  end

  it "emits each scheduled transition once across a runtime tick and read" do
    origin = Time.utc
    Timecop.freeze(origin) do
      cluster = TimeSync.new(endpoint(0), feature_map: TimeSync::Feature::TimeZone)
      events = [] of UInt32
      cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, event : UInt32, _priority : Matter::InteractionModel::EventPriority, _data : TLV::Any, _fabric : UInt8?) do
        events << event
        nil
      end
      cluster.apply_utc_time(TimeSync::SetUtcTimeRequest.new(1_000_000_u64, TimeSync::Granularity::Seconds))
      cluster.apply_time_zone(TimeSync::SetTimeZoneRequest.new([
        zone(0, 0_u64), zone(3_600, 2_000_000_u64),
      ]))
      cluster.apply_dst_offset(TimeSync::SetDstOffsetRequest.new([dst(3_600, 0_u64, 3_000_000_u64)]))
      events.clear

      Timecop.freeze(origin + 3.seconds) do
        cluster.advance_time_state
        cluster.local_time.should_not be_nil
        cluster.advance_time_state
      end
      events.count(TimeSync::EVENT_TIME_ZONE_STATUS).should eq(1)
      events.count(TimeSync::EVENT_DST_STATUS).should eq(1)
      events.count(TimeSync::EVENT_DST_TABLE_EMPTY).should eq(1)
    end
  end

  it "reports exhaustion of a zero-offset DST entry without a false DST status" do
    origin = Time.utc
    Timecop.freeze(origin) do
      cluster = TimeSync.new(endpoint(0), feature_map: TimeSync::Feature::TimeZone)
      events = [] of UInt32
      cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, event : UInt32, _priority : Matter::InteractionModel::EventPriority, _data : TLV::Any, _fabric : UInt8?) do
        events << event
        nil
      end
      cluster.apply_utc_time(TimeSync::SetUtcTimeRequest.new(1_000_000_u64, TimeSync::Granularity::Seconds))
      cluster.apply_dst_offset(TimeSync::SetDstOffsetRequest.new([dst(0, 0_u64, 2_000_000_u64)]))
      events.clear
      Timecop.freeze(origin + 2.seconds) { cluster.advance_time_state }
      events.should eq([TimeSync::EVENT_DST_TABLE_EMPTY])
    end
  end

  it "persists zone and DST configuration but not the running UTC clock" do
    cluster = TimeSync.new(endpoint(0), feature_map: TimeSync::Feature::TimeZone)
    cluster.apply_time_zone(TimeSync::SetTimeZoneRequest.new([zone(36_000, 0_u64, "Australia/Sydney")]))
    cluster.apply_dst_offset(TimeSync::SetDstOffsetRequest.new([dst(3_600, 0_u64, nil)]))
    cluster.apply_utc_time(TimeSync::SetUtcTimeRequest.new(1_000_000_000_u64, TimeSync::Granularity::Seconds))
    state = cluster.save_state.as(Matter::Storage::Document)
    restored = TimeSync.new(endpoint(0), feature_map: TimeSync::Feature::TimeZone)
    restored.restore_state(state)
    restored.time_zone.should eq(cluster.time_zone)
    restored.dst_offset.should eq(cluster.dst_offset)
    restored.local_time.should be_nil
    restored.utc_time.should be_nil
  end
end
