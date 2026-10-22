require "../spec_helper"

private alias TemperatureAlarm = Matter::Cluster::TemperatureAlarm
private alias AlarmStatus = Matter::InteractionModel::Status
private alias AlarmCode = Matter::InteractionModel::StatusCode

private def alarm_cluster(features = TemperatureAlarm::Feature::OverTemperature | TemperatureAlarm::Feature::UnderTemperature)
  build(TemperatureAlarm, feature_map: features)
end

describe TemperatureAlarm do
  it "declares revision-one Alarm Base elements and only the configured thresholds" do
    cluster = alarm_cluster(TemperatureAlarm::Feature::OverTemperature)
    cluster.cluster_id.id.should eq(0x0064_u32)
    cluster.cluster_revision.should eq(1_u16)
    cluster.attributes.map(&.id.id).should eq([
      TemperatureAlarm::ATTR_MASK,
      TemperatureAlarm::ATTR_STATE,
      TemperatureAlarm::ATTR_SUPPORTED,
      TemperatureAlarm::ATTR_CRITICAL_OVER_TEMPERATURE_THRESHOLD,
    ])
    cluster.commands.map(&.id.id).should eq([TemperatureAlarm::CMD_MODIFY_ENABLED_ALARMS])
    cluster.events.map(&.id.id).should eq([TemperatureAlarm::EVENT_NOTIFY])
    read(cluster, TemperatureAlarm::ATTR_SUPPORTED).should eq(1_u8)
    read_status(cluster, TemperatureAlarm::ATTR_CRITICAL_UNDER_TEMPERATURE_THRESHOLD).status.should eq(AlarmCode::UnsupportedAttribute)
  end

  it "validates feature dependencies and threshold ordering before advertisement" do
    expect_raises(ArgumentError) { alarm_cluster(TemperatureAlarm::Feature::None) }
    expect_raises(ArgumentError) { alarm_cluster(TemperatureAlarm::Feature::MinorThreshold) }
    expect_raises(ArgumentError) do
      alarm_cluster(TemperatureAlarm::Feature::OverTemperature | TemperatureAlarm::Feature::MinorThreshold)
    end
    expect_raises(ArgumentError) { alarm_cluster(TemperatureAlarm::Feature::OverCriticalAdjustable) }
    expect_raises(ArgumentError) do
      build(TemperatureAlarm, feature_map: TemperatureAlarm::Feature::OverTemperature,
        critical_over_temperature_threshold: -27_316_i16)
    end
    expect_raises(ArgumentError) do
      build(TemperatureAlarm, feature_map: TemperatureAlarm::Feature::OverTemperature | TemperatureAlarm::Feature::UnderTemperature,
        critical_over_temperature_threshold: 1000_i16, critical_under_temperature_threshold: 1000_i16)
    end
  end

  it "reports threshold crossings and emits a typed Notify event" do
    node = Matter::Node.new
    endpoint1 = Matter::Endpoint.new(endpoint(1))
    cluster = alarm_cluster
    endpoint1.add_cluster(cluster)
    node.add_endpoint(endpoint1)
    cluster.update_temperature(5001_i16)
    read(cluster, TemperatureAlarm::ATTR_STATE).should eq(1_u8)
    cluster.update_temperature(2000_i16)
    read(cluster, TemperatureAlarm::ATTR_STATE).should eq(0_u8)
    records = node.event_journal.query([Matter::InteractionModel::EventPath.new(
      cluster: TemperatureAlarm::CLUSTER_ID, event: TemperatureAlarm::EVENT_NOTIFY)])
    records.size.should eq(2)
    first = TemperatureAlarm::NotifyEvent.from_tlv(records.first.data)
    first.active.should eq(TemperatureAlarm::AlarmBitmap::CriticalOverTemperature)
    first.inactive.should eq(TemperatureAlarm::AlarmBitmap::None)
    last = TemperatureAlarm::NotifyEvent.from_tlv(records.last.data)
    last.inactive.should eq(TemperatureAlarm::AlarmBitmap::CriticalOverTemperature)
    last.state.should eq(TemperatureAlarm::AlarmBitmap::None)
  end

  it "sets adjustable thresholds atomically and rejects out-of-order or unsupported fields" do
    features = TemperatureAlarm::Feature::OverTemperature |
               TemperatureAlarm::Feature::UnderTemperature |
               TemperatureAlarm::Feature::OverCriticalAdjustable
    cluster = alarm_cluster(features)
    cluster.commands.map(&.id.id).should contain(TemperatureAlarm::CMD_SET_TEMPERATURE_ALARM_THRESHOLDS)
    cluster.on_set_thresholds { |_request| AlarmStatus.success }
    expect_status(invoke(cluster, TemperatureAlarm::CMD_SET_TEMPERATURE_ALARM_THRESHOLDS,
      TemperatureAlarm::SetTemperatureAlarmThresholdsRequest.new), AlarmCode::InvalidCommand)
    expect_status(invoke(cluster, TemperatureAlarm::CMD_SET_TEMPERATURE_ALARM_THRESHOLDS,
      TemperatureAlarm::SetTemperatureAlarmThresholdsRequest.new(critical_under_temperature_threshold: -2000_i16)), AlarmCode::InvalidCommand)
    expect_success(invoke(cluster, TemperatureAlarm::CMD_SET_TEMPERATURE_ALARM_THRESHOLDS,
      TemperatureAlarm::SetTemperatureAlarmThresholdsRequest.new(critical_over_temperature_threshold: 6000_i16)))
    read(cluster, TemperatureAlarm::ATTR_CRITICAL_OVER_TEMPERATURE_THRESHOLD).should eq(6000_i16)
  end

  it "exposes all configured threshold ranks with ordered AlarmBitmap bits" do
    features = TemperatureAlarm::Feature::OverTemperature |
               TemperatureAlarm::Feature::UnderTemperature |
               TemperatureAlarm::Feature::MajorThreshold |
               TemperatureAlarm::Feature::MinorThreshold
    cluster = alarm_cluster(features)
    cluster.supported.value.should eq(0x3F_u8)
    cluster.attributes.map(&.id.id).last(6).should eq([
      TemperatureAlarm::ATTR_CRITICAL_OVER_TEMPERATURE_THRESHOLD,
      TemperatureAlarm::ATTR_MAJOR_OVER_TEMPERATURE_THRESHOLD,
      TemperatureAlarm::ATTR_MINOR_OVER_TEMPERATURE_THRESHOLD,
      TemperatureAlarm::ATTR_MINOR_UNDER_TEMPERATURE_THRESHOLD,
      TemperatureAlarm::ATTR_MAJOR_UNDER_TEMPERATURE_THRESHOLD,
      TemperatureAlarm::ATTR_CRITICAL_UNDER_TEMPERATURE_THRESHOLD,
    ])
    cluster.update_temperature(4500_i16)
    cluster.state.value.should eq(0x06_u8)
    cluster.update_temperature(-500_i16)
    cluster.state.value.should eq(0x18_u8)
  end

  it "masks unsupported bits and applies the fixed latch only with Reset" do
    features = TemperatureAlarm::Feature::OverTemperature | TemperatureAlarm::Feature::Reset
    cluster = build(TemperatureAlarm, feature_map: features,
      latch: TemperatureAlarm::AlarmBitmap::CriticalOverTemperature)
    cluster.attributes.map(&.id.id).should contain(TemperatureAlarm::ATTR_LATCH)
    cluster.commands.map(&.id.id).should contain(TemperatureAlarm::CMD_RESET)
    cluster.update_temperature(5001_i16)
    cluster.update_temperature(2000_i16)
    cluster.state.value.should eq(1_u8)
    expect_status(invoke(cluster, TemperatureAlarm::CMD_RESET,
      TemperatureAlarm::ResetRequest.new(TemperatureAlarm::AlarmBitmap::CriticalUnderTemperature)), AlarmCode::InvalidCommand)
    expect_success(invoke(cluster, TemperatureAlarm::CMD_RESET,
      TemperatureAlarm::ResetRequest.new(TemperatureAlarm::AlarmBitmap::CriticalOverTemperature)))
    cluster.state.value.should eq(0_u8)
    expect_status(invoke(cluster, TemperatureAlarm::CMD_MODIFY_ENABLED_ALARMS,
      TemperatureAlarm::ModifyEnabledAlarmsRequest.new(TemperatureAlarm::AlarmBitmap::CriticalUnderTemperature)), AlarmCode::InvalidCommand)
    expect_success(invoke(cluster, TemperatureAlarm::CMD_MODIFY_ENABLED_ALARMS,
      TemperatureAlarm::ModifyEnabledAlarmsRequest.new(TemperatureAlarm::AlarmBitmap::None)))
    cluster.mask.value.should eq(0_u8)
    cluster.update_temperature(6000_i16)
    cluster.state.value.should eq(0_u8)
  end

  it "rejects a threshold update that would cross another rank without partial writes" do
    features = TemperatureAlarm::Feature::OverTemperature |
               TemperatureAlarm::Feature::UnderTemperature |
               TemperatureAlarm::Feature::OverCriticalAdjustable
    cluster = alarm_cluster(features)
    cluster.on_set_thresholds { |_request| AlarmStatus.success }
    version_delta(cluster) do
      expect_status(invoke(cluster, TemperatureAlarm::CMD_SET_TEMPERATURE_ALARM_THRESHOLDS,
        TemperatureAlarm::SetTemperatureAlarmThresholdsRequest.new(critical_over_temperature_threshold: -2000_i16)), AlarmCode::ConstraintError)
    end.should eq(0)
    cluster.critical_over_temperature_threshold.should eq(5000_i16)
    cluster.on_set_thresholds { |_request| AlarmStatus.invalid_in_state }
    expect_status(invoke(cluster, TemperatureAlarm::CMD_SET_TEMPERATURE_ALARM_THRESHOLDS,
      TemperatureAlarm::SetTemperatureAlarmThresholdsRequest.new(critical_over_temperature_threshold: 6000_i16)), AlarmCode::InvalidInState)
    cluster.critical_over_temperature_threshold.should eq(5000_i16)
    write(cluster, TemperatureAlarm::ATTR_CRITICAL_OVER_TEMPERATURE_THRESHOLD, 6000_i16).status.should eq(AlarmCode::UnsupportedWrite)
  end

  it "omits optional commands and rejects commands without their features" do
    cluster = build(TemperatureAlarm, feature_map: TemperatureAlarm::Feature::UnderTemperature,
      modify_enabled_alarms_supported: false)
    cluster.commands.should be_empty
    read_status(cluster, TemperatureAlarm::ATTR_LATCH).status.should eq(AlarmCode::UnsupportedAttribute)
    read_status(cluster, TemperatureAlarm::ATTR_CRITICAL_OVER_TEMPERATURE_THRESHOLD).status.should eq(AlarmCode::UnsupportedAttribute)
    expect_status(invoke(cluster, TemperatureAlarm::CMD_RESET,
      TemperatureAlarm::ResetRequest.new(TemperatureAlarm::AlarmBitmap::None)), AlarmCode::UnsupportedCommand)
    expect_status(invoke(cluster, TemperatureAlarm::CMD_MODIFY_ENABLED_ALARMS,
      TemperatureAlarm::ModifyEnabledAlarmsRequest.new(TemperatureAlarm::AlarmBitmap::None)), AlarmCode::UnsupportedCommand)
    expect_status(invoke(cluster, TemperatureAlarm::CMD_SET_TEMPERATURE_ALARM_THRESHOLDS,
      TemperatureAlarm::SetTemperatureAlarmThresholdsRequest.new(critical_over_temperature_threshold: 1000_i16)), AlarmCode::UnsupportedCommand)
  end

  it "encodes the inherited and derived command fields with canonical TLV tags" do
    request = TemperatureAlarm::SetTemperatureAlarmThresholdsRequest.new(
      critical_over_temperature_threshold: 5000_i16,
      critical_under_temperature_threshold: -1000_i16)
    request.to_tlv(nil).as_structure.keys.should eq([0_u8, 5_u8])
    parsed = TemperatureAlarm::SetTemperatureAlarmThresholdsRequest.from_tlv(request.to_tlv(nil))
    parsed.critical_over_temperature_threshold.should eq(5000_i16)
    parsed.critical_under_temperature_threshold.should eq(-1000_i16)
    TemperatureAlarm::ResetRequest.new(TemperatureAlarm::AlarmBitmap::None).to_tlv(nil).as_structure.keys.should eq([0_u8])
  end

  it "keeps accepted threshold updates atomic when several features are adjustable" do
    features = TemperatureAlarm::Feature::OverTemperature |
               TemperatureAlarm::Feature::UnderTemperature |
               TemperatureAlarm::Feature::OverCriticalAdjustable |
               TemperatureAlarm::Feature::UnderCriticalAdjustable
    cluster = alarm_cluster(features)
    calls = 0
    cluster.on_set_thresholds { |_request| calls += 1; AlarmStatus.success }
    request = TemperatureAlarm::SetTemperatureAlarmThresholdsRequest.new(
      critical_over_temperature_threshold: 6000_i16,
      critical_under_temperature_threshold: 7000_i16)
    expect_status(invoke(cluster, TemperatureAlarm::CMD_SET_TEMPERATURE_ALARM_THRESHOLDS, request), AlarmCode::ConstraintError)
    calls.should eq(0)
    cluster.critical_over_temperature_threshold.should eq(5000_i16)
    cluster.critical_under_temperature_threshold.should eq(-1000_i16)
    expect_success(invoke(cluster, TemperatureAlarm::CMD_SET_TEMPERATURE_ALARM_THRESHOLDS,
      TemperatureAlarm::SetTemperatureAlarmThresholdsRequest.new(
        critical_over_temperature_threshold: 6000_i16,
        critical_under_temperature_threshold: -2000_i16)))
    calls.should eq(1)
    cluster.critical_over_temperature_threshold.should eq(6000_i16)
    cluster.critical_under_temperature_threshold.should eq(-2000_i16)
  end

  it "resets currently active bits until the next physical update" do
    cluster = build(TemperatureAlarm,
      feature_map: TemperatureAlarm::Feature::OverTemperature | TemperatureAlarm::Feature::Reset,
      latch: TemperatureAlarm::AlarmBitmap::CriticalOverTemperature)
    cluster.update_temperature(6000_i16)
    cluster.state.value.should eq(1_u8)
    expect_success(invoke(cluster, TemperatureAlarm::CMD_RESET,
      TemperatureAlarm::ResetRequest.new(TemperatureAlarm::AlarmBitmap::CriticalOverTemperature)))
    cluster.state.value.should eq(0_u8)
    cluster.update_temperature(6000_i16)
    cluster.state.value.should eq(1_u8)
  end

  it "emits Notify only for State transitions, not a mask-only update" do
    node = Matter::Node.new
    endpoint1 = Matter::Endpoint.new(endpoint(1))
    cluster = alarm_cluster(TemperatureAlarm::Feature::OverTemperature)
    endpoint1.add_cluster(cluster)
    node.add_endpoint(endpoint1)
    records = -> do
      node.event_journal.query([Matter::InteractionModel::EventPath.new(
        cluster: TemperatureAlarm::CLUSTER_ID, event: TemperatureAlarm::EVENT_NOTIFY)])
    end
    expect_success(invoke(cluster, TemperatureAlarm::CMD_MODIFY_ENABLED_ALARMS,
      TemperatureAlarm::ModifyEnabledAlarmsRequest.new(TemperatureAlarm::AlarmBitmap::None)))
    records.call.size.should eq(0)
    cluster.update_temperature(6000_i16)
    cluster.state.value.should eq(0_u8)
    expect_success(invoke(cluster, TemperatureAlarm::CMD_MODIFY_ENABLED_ALARMS,
      TemperatureAlarm::ModifyEnabledAlarmsRequest.new(TemperatureAlarm::AlarmBitmap::CriticalOverTemperature)))
    cluster.state.value.should eq(0_u8)
    records.call.size.should eq(0)
    cluster.update_temperature(6000_i16)
    cluster.state.value.should eq(1_u8)
    records.call.size.should eq(1)
  end

  it "lets the host reject Reset and ModifyEnabledAlarms without visible changes" do
    cluster = build(TemperatureAlarm, feature_map: TemperatureAlarm::Feature::OverTemperature | TemperatureAlarm::Feature::Reset)
    cluster.update_temperature(6000_i16)
    cluster.on_reset { |_alarms| AlarmStatus.failure }
    expect_status(invoke(cluster, TemperatureAlarm::CMD_RESET,
      TemperatureAlarm::ResetRequest.new(TemperatureAlarm::AlarmBitmap::CriticalOverTemperature)), AlarmCode::Failure)
    cluster.state.value.should eq(1_u8)
    cluster.on_modify_enabled_alarms { |_mask| AlarmStatus.failure }
    expect_status(invoke(cluster, TemperatureAlarm::CMD_MODIFY_ENABLED_ALARMS,
      TemperatureAlarm::ModifyEnabledAlarmsRequest.new(TemperatureAlarm::AlarmBitmap::None)), AlarmCode::Failure)
    cluster.mask.value.should eq(1_u8)
    cluster.state.value.should eq(1_u8)
  end
end
