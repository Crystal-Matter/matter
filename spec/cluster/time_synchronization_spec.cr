require "../spec_helper"
require "../../src/matter/cluster/time_synchronization"

private alias TimeSync = Matter::Cluster::TimeSynchronization

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
