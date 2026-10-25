require "../spec_helper"
require "../../src/matter/cluster/time_synchronization"

private alias TimeSync = Matter::Cluster::TimeSynchronization

describe "Matter 1.6 Trusted Time Client feature" do
  it "requires a CASE fabric and round-trips the mandatory nullable command field" do
    base = TimeSync.new(endpoint(0))
    base.get_attribute_metadata(TimeSync::ATTR_TRUSTED_TIME_SOURCE).should be_nil
    base.get_command_metadata(TimeSync::CMD_SET_TRUSTED_TIME_SOURCE).should be_nil

    tsc = TimeSync.new(endpoint(0), feature_map: TimeSync::Feature::TrustedTimeClient)
    read(tsc, Matter::Cluster::Base::GLOBAL_FEATURE_MAP).should eq(8_u32)
    read(tsc, TimeSync::ATTR_TRUSTED_TIME_SOURCE).should be_nil
    request = TimeSync::SetTrustedTimeSourceRequest.new(nil)
    request.to_slice.should eq(Bytes[0x15, 0x34, 0x00, 0x18])
    TimeSync::SetTrustedTimeSourceRequest.from_slice(request.to_slice).trusted_time_source.should be_nil
    expect_raises(TLV::DeserializationError) do
      TimeSync::SetTrustedTimeSourceRequest.from_slice(Bytes[0x15, 0x18])
    end
    status = tsc.invoke_command(TimeSync::CMD_SET_TRUSTED_TIME_SOURCE, request.to_tlv(nil))
    status.as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAccess)
    status = tsc.invoke_command(TimeSync::CMD_SET_TRUSTED_TIME_SOURCE, request.to_tlv(nil),
      is_case_session: true, fabric_index: 0_u8)
    status.as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAccess)
  end

  it "stores the accessing fabric, emits Missing on clear, and clears on fabric removal" do
    tsc = TimeSync.new(endpoint(0), feature_map: TimeSync::Feature::TrustedTimeClient)
    events = [] of UInt32
    tsc.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, event : UInt32, _priority : Matter::InteractionModel::EventPriority, _data : TLV::Any, _fabric : UInt8?) do
      events << event
      nil
    end
    source = TimeSync::FabricScopedTrustedTimeSourceStruct.new(0x1234_u64, 2_u16)
    request = TimeSync::SetTrustedTimeSourceRequest.new(source)
    tsc.invoke_command(TimeSync::CMD_SET_TRUSTED_TIME_SOURCE, request.to_tlv(nil),
      is_case_session: true, fabric_index: 3_u8).as(Matter::InteractionModel::Status).status
      .should eq(Matter::InteractionModel::StatusCode::Success)
    read(tsc, TimeSync::ATTR_TRUSTED_TIME_SOURCE).should_not be_nil
    restored = TimeSync.new(endpoint(0), feature_map: TimeSync::Feature::TrustedTimeClient)
    restored.restore_state(tsc.save_state.as(Matter::Storage::Document))
    restored.trusted_time_source.should eq(TimeSync::TrustedTimeSourceStruct.new(3_u8, 0x1234_u64, 2_u16))
    restored.retain_fabrics([4_u8]).should be_true
    restored.trusted_time_source.should be_nil
    tsc.remove_fabric(4_u8)
    tsc.trusted_time_source.should_not be_nil
    tsc.remove_fabric(3_u8)
    tsc.trusted_time_source.should be_nil
    events.should eq([TimeSync::EVENT_MISSING_TRUSTED_TIME_SOURCE])
    tsc.invoke_command(TimeSync::CMD_SET_TRUSTED_TIME_SOURCE,
      TimeSync::SetTrustedTimeSourceRequest.new(nil).to_tlv(nil),
      is_case_session: true, fabric_index: 4_u8)
    events.should eq([TimeSync::EVENT_MISSING_TRUSTED_TIME_SOURCE, TimeSync::EVENT_MISSING_TRUSTED_TIME_SOURCE])
    tsc.retain_fabrics([3_u8]).should be_false
  end

  it "accepts the configured peer only and rate limits unreachable updates" do
    tsc = TimeSync.new(endpoint(0), feature_map: TimeSync::Feature::TrustedTimeClient)
    tsc.invoke_command(TimeSync::CMD_SET_TRUSTED_TIME_SOURCE,
      TimeSync::SetTrustedTimeSourceRequest.new(TimeSync::FabricScopedTrustedTimeSourceStruct.new(0x1234_u64, 2_u16)).to_tlv(nil),
      is_case_session: true, fabric_index: 3_u8)
    events = [] of UInt32
    tsc.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, event : UInt32, _priority : Matter::InteractionModel::EventPriority, _data : TLV::Any, _fabric : UInt8?) do
      events << event
      nil
    end
    tsc.on_trusted_time_query = ->(fabric : UInt8, node : UInt64, ep : UInt16) : TimeSync::TrustedTimeSample? do
      {fabric, node, ep}.should eq({3_u8, 0x1234_u64, 2_u16})
      TimeSync::TrustedTimeSample.new(321_000_000_u64, TimeSync::Granularity::Seconds)
    end
    now = Time.instant
    tsc.refresh_from_trusted_time_source(now).should be_true
    read(tsc, TimeSync::ATTR_TIME_SOURCE).should eq(TimeSync::TimeSource::NodeTimeCluster.value)
    tsc.refresh_from_trusted_time_source(now + 1.second).should be_false
    tsc.on_trusted_time_query = ->(_fabric : UInt8, _node : UInt64, _ep : UInt16) : TimeSync::TrustedTimeSample? { nil }
    tsc.refresh_from_trusted_time_source(now + TimeSync::TRUSTED_TIME_REFRESH_INTERVAL).should be_false
    events.should eq([TimeSync::EVENT_MISSING_TRUSTED_TIME_SOURCE])
    tsc.utc_time.should_not be_nil
  end

  it "rejects non-operational peer Node IDs without changing the stored source" do
    tsc = TimeSync.new(endpoint(0), feature_map: TimeSync::Feature::TrustedTimeClient)
    invalid = TimeSync::SetTrustedTimeSourceRequest.new(TimeSync::FabricScopedTrustedTimeSourceStruct.new(0_u64, 0_u16))
    status = tsc.invoke_command(TimeSync::CMD_SET_TRUSTED_TIME_SOURCE, invalid.to_tlv(nil),
      is_case_session: true, fabric_index: 1_u8)
    status.as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    tsc.trusted_time_source.should be_nil
  end

  it "reports an unreachable callback once without stopping later refreshes" do
    tsc = TimeSync.new(endpoint(0), feature_map: TimeSync::Feature::TrustedTimeClient)
    tsc.invoke_command(TimeSync::CMD_SET_TRUSTED_TIME_SOURCE,
      TimeSync::SetTrustedTimeSourceRequest.new(TimeSync::FabricScopedTrustedTimeSourceStruct.new(2_u64, 0_u16)).to_tlv(nil),
      is_case_session: true, fabric_index: 1_u8)
    events = [] of UInt32
    tsc.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, event : UInt32, _priority : Matter::InteractionModel::EventPriority, _data : TLV::Any, _fabric : UInt8?) do
      events << event
      nil
    end
    tsc.on_trusted_time_query = ->(_fabric : UInt8, _node : UInt64, _ep : UInt16) : TimeSync::TrustedTimeSample? do
      raise Matter::TransportError.new("peer unavailable")
    end
    now = Time.instant
    tsc.refresh_from_trusted_time_source(now).should be_false
    tsc.refresh_from_trusted_time_source(now + 1.second).should be_false
    events.should eq([TimeSync::EVENT_MISSING_TRUSTED_TIME_SOURCE, TimeSync::EVENT_TIME_FAILURE])
    tsc.on_trusted_time_query = ->(_fabric : UInt8, _node : UInt64, _ep : UInt16) : TimeSync::TrustedTimeSample? do
      TimeSync::TrustedTimeSample.new(123_000_000_u64, TimeSync::Granularity::Seconds)
    end
    tsc.refresh_from_trusted_time_source(now + TimeSync::TRUSTED_TIME_REFRESH_INTERVAL).should be_true
    tsc.utc_time.should_not be_nil
  end
end

private def zone(offset : Int32, valid_at : UInt64, name : String? = nil)
  TimeSync::TimeZoneStruct.new(offset, valid_at, name)
end

describe "Matter 1.6 NTPClient feature" do
  it "queries a local SNTP responder and accepts only its matched packet" do
    server = UDPSocket.new(:inet6)
    server.bind("::1", 0)
    done = Channel(Nil).new
    spawn do
      request = Bytes.new(TimeSync::SntpClient::PACKET_SIZE)
      size, peer = server.receive(request)
      size.should eq(TimeSync::SntpClient::PACKET_SIZE)
      request[0].should eq(TimeSync::SntpClient::REQUEST_HEADER)
      response = Bytes.new(TimeSync::SntpClient::PACKET_SIZE, 0_u8)
      response[0] = 0x24_u8
      response[1] = 2_u8
      response[24, 8].copy_from(request[40, 8])
      seconds = TimeSync::SntpClient::NTP_TO_MATTER_SECONDS + 456_u64
      4.times { |i| response[40 + i] = ((seconds >> (24 - 8 * i)) & 0xFF).to_u8 }
      server.send(response, peer)
    ensure
      done.send(nil)
    end
    TimeSync::SntpClient.query("::1", server.local_address.port).should eq(456_000_000_u64)
    done.receive
    server.close
  end

  it "refreshes from NTP at a bounded rate and marks the source accurately" do
    ntpc = TimeSync.new(endpoint(0), feature_map: TimeSync::Feature::NtpClient)
    ntpc.apply_default_ntp(TimeSync::SetDefaultNtpRequest.new("2001:db8::123"))
    attempts = 0
    ntpc.on_ntp_query = ->(_address : String) : UInt64? do
      attempts += 1
      123_000_000_000_u64
    end
    now = Time.instant
    ntpc.refresh_from_default_ntp(now).should be_true
    ntpc.refresh_from_default_ntp(now + 1.second).should be_false
    attempts.should eq(1)
    read(ntpc, TimeSync::ATTR_TIME_SOURCE).should eq(TimeSync::TimeSource::NonMatterSntp.value)
    read(ntpc, TimeSync::ATTR_UTC_TIME).as(UInt64).should be >= 123_000_000_000_u64
    ntpc.refresh_from_default_ntp(now + TimeSync::NTP_REFRESH_INTERVAL).should be_true
    attempts.should eq(2)
  end

  it "reports an unavailable fallback once per interval without discarding administrator time" do
    ntpc = TimeSync.new(endpoint(0), feature_map: TimeSync::Feature::NtpClient)
    ntpc.apply_default_ntp(TimeSync::SetDefaultNtpRequest.new("2001:db8::123"))
    ntpc.on_ntp_query = ->(_address : String) : UInt64? { nil }
    events = [] of UInt32
    ntpc.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, event : UInt32, _priority : Matter::InteractionModel::EventPriority, _data : TLV::Any, _fabric : UInt8?) do
      events << event
      nil
    end
    now = Time.instant
    ntpc.refresh_from_default_ntp(now).should be_false
    ntpc.refresh_from_default_ntp(now + 1.second).should be_false
    events.should eq([TimeSync::EVENT_TIME_FAILURE])

    ntpc.apply_utc_time(TimeSync::SetUtcTimeRequest.new(123_000_000_000_u64, TimeSync::Granularity::Seconds))
    ntpc.refresh_from_default_ntp(now + TimeSync::NTP_REFRESH_INTERVAL).should be_false
    events.should eq([TimeSync::EVENT_TIME_FAILURE])
    ntpc.utc_time.should_not be_nil
  end

  it "discards a response when the administrator changes the fallback during the query" do
    ntpc = TimeSync.new(endpoint(0), feature_map: TimeSync::Feature::NtpClient)
    ntpc.apply_default_ntp(TimeSync::SetDefaultNtpRequest.new("2001:db8::123"))
    ntpc.on_ntp_query = ->(_address : String) : UInt64? do
      ntpc.apply_default_ntp(TimeSync::SetDefaultNtpRequest.new(nil))
      123_000_000_000_u64
    end
    ntpc.refresh_from_default_ntp.should be_false
    ntpc.utc_time.should be_nil
  end

  it "accepts a matching SNTP server response and rejects spoofed or unsynchronized packets" do
    token = Bytes[1, 2, 3, 4, 5, 6, 7, 8]
    response = Bytes.new(TimeSync::SntpClient::PACKET_SIZE, 0_u8)
    response[0] = 0x24_u8
    response[1] = 2_u8
    response[24, 8].copy_from(token)
    seconds = TimeSync::SntpClient::NTP_TO_MATTER_SECONDS + 123_u64
    4.times { |i| response[40 + i] = ((seconds >> (24 - 8 * i)) & 0xFF).to_u8 }
    response[44] = 0x80_u8
    TimeSync::SntpClient.decode(response, token).should eq(123_500_000_u64)
    response[24] = 0_u8
    TimeSync::SntpClient.decode(response, token).should be_nil
    response[24] = token[0]
    response[0] = 0xE4_u8
    TimeSync::SntpClient.decode(response, token).should be_nil
    response[0] = 0x1C_u8
    TimeSync::SntpClient.decode(response, token).should be_nil
    response[0] = 0x24_u8
    response[1] = 0_u8
    TimeSync::SntpClient.decode(response, token).should be_nil
  end

  it "exposes only the NTPC contract and round-trips a mandatory nullable SetDefaultNTP field" do
    base = TimeSync.new(endpoint(0))
    base.get_attribute_metadata(TimeSync::ATTR_DEFAULT_NTP).should be_nil
    base.get_command_metadata(TimeSync::CMD_SET_DEFAULT_NTP).should be_nil

    ntpc = TimeSync.new(endpoint(0), feature_map: TimeSync::Feature::NtpClient)
    read(ntpc, Matter::Cluster::Base::GLOBAL_FEATURE_MAP).should eq(2_u32)
    read(ntpc, TimeSync::ATTR_DEFAULT_NTP).should be_nil
    read(ntpc, TimeSync::ATTR_SUPPORTS_DNS_RESOLVE).should be_false
    ntpc.get_command_metadata(TimeSync::CMD_SET_DEFAULT_NTP).as(Matter::Cluster::CommandMetadata).access
      .should eq(Matter::InteractionModel::EntryPrivilege::Administer)
    TimeSync::SetDefaultNtpRequest.new(nil).to_slice.should eq(Bytes[0x15, 0x34, 0x00, 0x18])
    TimeSync::SetDefaultNtpRequest.from_slice(TimeSync::SetDefaultNtpRequest.new(nil).to_slice).default_ntp.should be_nil
    expect_raises(TLV::DeserializationError) do
      TimeSync::SetDefaultNtpRequest.from_slice(Bytes[0x15, 0x18])
    end
    TimeSync::SetDefaultNtpRequest.from_slice(TimeSync::SetDefaultNtpRequest.new("2001:db8::123").to_slice).default_ntp
      .should eq("2001:db8::123")
  end

  it "validates an IPv6-only address, persists a nullable default, and refuses a domain without DNS" do
    ntpc = TimeSync.new(endpoint(0), feature_map: TimeSync::Feature::NtpClient)
    ntpc.apply_default_ntp(TimeSync::SetDefaultNtpRequest.new("2001:db8::123")).status
      .should eq(Matter::InteractionModel::StatusCode::Success)
    ntpc.apply_default_ntp(TimeSync::SetDefaultNtpRequest.new("pool.ntp.org")).status
      .should eq(Matter::InteractionModel::StatusCode::InvalidCommand)
    ntpc.apply_default_ntp(TimeSync::SetDefaultNtpRequest.new("[2001:db8::123]:123")).status
      .should eq(Matter::InteractionModel::StatusCode::InvalidCommand)
    ntpc.apply_default_ntp(TimeSync::SetDefaultNtpRequest.new("2001:0db8::123")).status
      .should eq(Matter::InteractionModel::StatusCode::InvalidCommand)
    ntpc.apply_default_ntp(TimeSync::SetDefaultNtpRequest.new("x" * 129)).status
      .should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    read(ntpc, TimeSync::ATTR_DEFAULT_NTP).should eq("2001:db8::123")

    restored = TimeSync.new(endpoint(0), feature_map: TimeSync::Feature::NtpClient)
    restored.restore_state(ntpc.save_state.as(Matter::Storage::Document))
    read(restored, TimeSync::ATTR_DEFAULT_NTP).should eq("2001:db8::123")
    restored.utc_time.should be_nil
    restored.apply_default_ntp(TimeSync::SetDefaultNtpRequest.new(nil)).status
      .should eq(Matter::InteractionModel::StatusCode::Success)
    read(restored, TimeSync::ATTR_DEFAULT_NTP).should be_nil
  end
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
