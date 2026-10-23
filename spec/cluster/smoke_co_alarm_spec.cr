require "../spec_helper"

private alias SmokeCO = Matter::Cluster::SmokeCOAlarm
private alias SmokeStatus = Matter::InteractionModel::Status
private alias SmokeCode = Matter::InteractionModel::StatusCode

private def smoke_alarm(**options)
  build(SmokeCO, **options)
end

private def smoke_events(node : Matter::Node, event : UInt32)
  node.event_journal.query([Matter::InteractionModel::EventPath.new(
    cluster: SmokeCO::CLUSTER_ID, event: event)])
end

describe SmokeCO do
  it "advertises revision two with at least one sensor feature" do
    expect_raises(ArgumentError) { smoke_alarm(feature_map: SmokeCO::Feature::None) }
    cluster = smoke_alarm(feature_map: SmokeCO::Feature::SmokeAlarm)
    cluster.cluster_id.id.should eq(0x005C_u32)
    cluster.cluster_revision.should eq(2_u16)
    read(cluster, 0xFFFC_u32).should eq(SmokeCO::Feature::SmokeAlarm.value)
    cluster.attributes.map(&.id.id).should contain(SmokeCO::ATTR_SMOKE_STATE)
    cluster.attributes.map(&.id.id).should_not contain(SmokeCO::ATTR_CO_STATE)
    cluster.events.map(&.id.id).should contain(SmokeCO::EVENT_SMOKE_ALARM)
    cluster.events.map(&.id.id).should_not contain(SmokeCO::EVENT_CO_ALARM)
    read(cluster, SmokeCO::ATTR_UNMOUNTED).should be_false
  end

  it "publishes alarm transitions, priority, mute end, and AllClear exactly once" do
    node = Matter::Node.new
    endpoint1 = Matter::Endpoint.new(endpoint(1))
    cluster = smoke_alarm(feature_map: SmokeCO::Feature::SmokeAlarm,
      self_test_supported: true)
    endpoint1.add_cluster(cluster)
    node.add_endpoint(endpoint1)

    cluster.device_muted = SmokeCO::MuteState::Muted
    cluster.smoke_state = SmokeCO::AlarmState::Warning
    cluster.expressed_state.should eq(SmokeCO::ExpressedState::SmokeAlarm)
    expect_raises(ArgumentError) { cluster.expressed_state = SmokeCO::ExpressedState::Normal }
    smoke_events(node, SmokeCO::EVENT_ALARM_MUTED).size.should eq(1)
    cluster.smoke_state = SmokeCO::AlarmState::Critical
    cluster.device_muted.should eq(SmokeCO::MuteState::NotMuted)
    smoke_events(node, SmokeCO::EVENT_MUTE_ENDED).size.should eq(1)
    smoke_events(node, SmokeCO::EVENT_SMOKE_ALARM).size.should eq(2)
    cluster.smoke_state = SmokeCO::AlarmState::Normal
    cluster.expressed_state.should eq(SmokeCO::ExpressedState::Normal)
    smoke_events(node, SmokeCO::EVENT_ALL_CLEAR).size.should eq(1)
  end

  it "returns Busy during smoke alarm or concurrent self test and completes host test" do
    cluster = smoke_alarm(feature_map: SmokeCO::Feature::SmokeAlarm,
      self_test_supported: true)
    cluster.on_self_test { SmokeStatus.success }
    cluster.smoke_state = SmokeCO::AlarmState::Warning
    expect_status(invoke(cluster, SmokeCO::CMD_SELF_TEST_REQUEST), SmokeCode::Busy)
    cluster.smoke_state = SmokeCO::AlarmState::Normal
    expect_success(invoke(cluster, SmokeCO::CMD_SELF_TEST_REQUEST))
    cluster.test_in_progress?.should be_true
    cluster.expressed_state.should eq(SmokeCO::ExpressedState::Testing)
    expect_status(invoke(cluster, SmokeCO::CMD_SELF_TEST_REQUEST), SmokeCode::Busy)
    cluster.complete_self_test
    cluster.test_in_progress?.should be_false
    cluster.expressed_state.should eq(SmokeCO::ExpressedState::Normal)
  end

  it "restores nonvolatile alarms without resurrecting an interrupted test" do
    cluster = smoke_alarm(feature_map: SmokeCO::Feature::SmokeAlarm,
      self_test_supported: true)
    cluster.on_self_test { SmokeStatus.success }
    cluster.battery_alert = SmokeCO::AlarmState::Warning
    expect_success(invoke(cluster, SmokeCO::CMD_SELF_TEST_REQUEST))
    restored = smoke_alarm(feature_map: SmokeCO::Feature::SmokeAlarm,
      self_test_supported: true)
    restored.restore_state(cluster.save_state.as(Matter::Storage::Document))
    restored.battery_alert.should eq(SmokeCO::AlarmState::Warning)
    restored.test_in_progress?.should be_false
    restored.expressed_state.should eq(SmokeCO::ExpressedState::BatteryAlert)
  end

  it "supports CO-only devices and rejects unsupported smoke reports" do
    cluster = smoke_alarm(feature_map: SmokeCO::Feature::CoAlarm)
    cluster.attributes.map(&.id.id).should contain(SmokeCO::ATTR_CO_STATE)
    cluster.attributes.map(&.id.id).should_not contain(SmokeCO::ATTR_SMOKE_STATE)
    expect_raises(ArgumentError) { cluster.smoke_state = SmokeCO::AlarmState::Warning }
    cluster.co_state = SmokeCO::AlarmState::Critical
    cluster.expressed_state.should eq(SmokeCO::ExpressedState::COAlarm)
    expect_raises(ArgumentError) { cluster.device_muted = SmokeCO::MuteState::Muted }
  end

  it "reports a physical inability only with an active cause" do
    cluster = smoke_alarm
    expect_raises(ArgumentError) { cluster.report_inoperative(true) }
    cluster.unmounted = true
    cluster.report_inoperative(true)
    cluster.expressed_state.should eq(SmokeCO::ExpressedState::Inoperative)
    cluster.unmounted = false
    cluster.expressed_state.should eq(SmokeCO::ExpressedState::Normal)
  end

  it "fires an interconnect event for each received alarm and faults on critical contamination" do
    node = Matter::Node.new
    endpoint1 = Matter::Endpoint.new(endpoint(1))
    cluster = smoke_alarm
    endpoint1.add_cluster(cluster)
    node.add_endpoint(endpoint1)
    cluster.receive_interconnect_smoke(SmokeCO::AlarmState::Warning)
    cluster.receive_interconnect_smoke(SmokeCO::AlarmState::Warning)
    smoke_events(node, SmokeCO::EVENT_INTERCONNECT_SMOKE_ALARM).size.should eq(2)
    cluster.contamination_state = SmokeCO::ContaminationState::Critical
    cluster.hardware_fault_alert?.should be_true
    smoke_events(node, SmokeCO::EVENT_HARDWARE_FAULT).size.should eq(1)
  end

  it "also emits a received alarm when the host assigns InterconnectSmokeAlarm directly" do
    node = Matter::Node.new
    endpoint1 = Matter::Endpoint.new(endpoint(1))
    cluster = smoke_alarm
    endpoint1.add_cluster(cluster)
    node.add_endpoint(endpoint1)
    cluster.interconnect_smoke_alarm = SmokeCO::AlarmState::Warning
    smoke_events(node, SmokeCO::EVENT_INTERCONNECT_SMOKE_ALARM).size.should eq(1)
    cluster.receive_interconnect_smoke(SmokeCO::AlarmState::Warning)
    smoke_events(node, SmokeCO::EVENT_INTERCONNECT_SMOKE_ALARM).size.should eq(2)
    first = SmokeCO::AlarmEvent.from_tlv(smoke_events(node,
      SmokeCO::EVENT_INTERCONNECT_SMOKE_ALARM).first.data)
    first.alarm_severity_level.should eq(SmokeCO::AlarmState::Warning)
    first.to_tlv(nil).as_structure.keys.should eq([0_u8])
  end

  it "emits InterconnectCOAlarm for direct host assignment and repeated reports" do
    node = Matter::Node.new
    endpoint1 = Matter::Endpoint.new(endpoint(1))
    cluster = smoke_alarm(feature_map: SmokeCO::Feature::CoAlarm)
    endpoint1.add_cluster(cluster)
    node.add_endpoint(endpoint1)
    cluster.interconnect_co_alarm = SmokeCO::AlarmState::Critical
    cluster.receive_interconnect_co(SmokeCO::AlarmState::Critical)
    smoke_events(node, SmokeCO::EVENT_INTERCONNECT_CO_ALARM).size.should eq(2)
    cluster.expressed_state.should eq(SmokeCO::ExpressedState::InterconnectCO)
  end

  it "cannot clear a hardware fault while smoke contamination remains critical" do
    cluster = smoke_alarm
    cluster.contamination_state = SmokeCO::ContaminationState::Critical
    expect_raises(ArgumentError) { cluster.hardware_fault_alert = false }
    cluster.hardware_fault_alert?.should be_true
  end

  it "keeps ExpiryDate fixed and allows a host clock to report end of service" do
    cluster = smoke_alarm(expiry_date: 100_u32)
    read(cluster, SmokeCO::ATTR_EXPIRY_DATE).should eq(100_u32)
    cluster.refresh_expiry(99_u32)
    cluster.end_of_service_alert.should eq(SmokeCO::EndOfService::Normal)
    cluster.refresh_expiry(100_u32)
    cluster.end_of_service_alert.should eq(SmokeCO::EndOfService::Expired)
    cluster.expressed_state.should eq(SmokeCO::ExpressedState::EndOfService)
    expect_raises(ArgumentError) { cluster.expiry_date = 101_u32 }
    expect_raises(ArgumentError) { cluster.end_of_service_alert = SmokeCO::EndOfService::Normal }
  end

  it "rejects undefined states before changing a public attribute" do
    cluster = smoke_alarm
    expect_raises(ArgumentError) { cluster.smoke_state = SmokeCO::AlarmState.new(3_u8) }
    expect_raises(ArgumentError) { cluster.battery_alert = SmokeCO::AlarmState.new(3_u8) }
    expect_raises(ArgumentError) { cluster.contamination_state = SmokeCO::ContaminationState.new(4_u8) }
    cluster.smoke_state.should eq(SmokeCO::AlarmState::Normal)
    cluster.expressed_state.should eq(SmokeCO::ExpressedState::Normal)
  end
end
