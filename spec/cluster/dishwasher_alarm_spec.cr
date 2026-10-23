require "../spec_helper"

private alias DishwasherAlarm = Matter::Cluster::DishwasherAlarm
private alias DishwasherCode = Matter::InteractionModel::StatusCode
private alias DishwasherStatus = Matter::InteractionModel::Status

private def dishwasher_alarm(**options)
  build(DishwasherAlarm, **options)
end

describe DishwasherAlarm do
  it "advertises revision one with inherited Alarm Base elements and one configured alarm" do
    cluster = dishwasher_alarm
    cluster.cluster_id.id.should eq(0x005D_u32)
    cluster.cluster_revision.should eq(1_u16)
    cluster.attributes.map(&.id.id).should eq([
      DishwasherAlarm::ATTR_MASK, DishwasherAlarm::ATTR_STATE, DishwasherAlarm::ATTR_SUPPORTED,
    ])
    cluster.commands.map(&.id.id).should eq([DishwasherAlarm::CMD_MODIFY_ENABLED_ALARMS])
    cluster.events.map(&.id.id).should eq([DishwasherAlarm::EVENT_NOTIFY])
    read(cluster, DishwasherAlarm::ATTR_SUPPORTED).should eq(DishwasherAlarm::AlarmBitmap::DoorError.value)
    read(cluster, DishwasherAlarm::ATTR_MASK).should eq(DishwasherAlarm::AlarmBitmap::DoorError.value)
    read_status(cluster, DishwasherAlarm::ATTR_LATCH).status.should eq(DishwasherCode::UnsupportedAttribute)
  end

  it "supports the six canonical alarm bits and rejects empty or unknown support" do
    all = DishwasherAlarm::AlarmBitmap.new(0x3F_u8)
    cluster = dishwasher_alarm(supported: all)
    cluster.supported.value.should eq(0x3F_u8)
    expect_raises(ArgumentError) { dishwasher_alarm(supported: DishwasherAlarm::AlarmBitmap::None) }
    expect_raises(ArgumentError) { dishwasher_alarm(supported: DishwasherAlarm::AlarmBitmap.new(0x40_u8)) }
    expect_raises(ArgumentError) do
      dishwasher_alarm(supported: DishwasherAlarm::AlarmBitmap::DoorError,
        latch: DishwasherAlarm::AlarmBitmap::DrainError)
    end
  end

  it "exposes Reset and fixed Latch only when Reset is configured" do
    cluster = dishwasher_alarm(feature_map: DishwasherAlarm::Feature::Reset,
      latch: DishwasherAlarm::AlarmBitmap::DoorError)
    cluster.attributes.map(&.id.id).should contain(DishwasherAlarm::ATTR_LATCH)
    cluster.commands.map(&.id.id).should contain(DishwasherAlarm::CMD_RESET)
    cluster.attributes.find!(&.id.id.==(DishwasherAlarm::ATTR_LATCH)).fixed?.should be_true
    cluster.attributes.find!(&.id.id.==(DishwasherAlarm::ATTR_SUPPORTED)).fixed?.should be_true
    version = cluster.data_version
    expect_raises(ArgumentError) { cluster.latch = DishwasherAlarm::AlarmBitmap::None }
    expect_raises(ArgumentError) { cluster.supported = DishwasherAlarm::AlarmBitmap::None }
    cluster.data_version.should eq(version)
    expect_raises(ArgumentError) { dishwasher_alarm(latch: DishwasherAlarm::AlarmBitmap::DoorError) }
  end

  it "publishes state transitions with canonical Notify event fields" do
    node = Matter::Node.new
    endpoint1 = Matter::Endpoint.new(endpoint(1))
    cluster = dishwasher_alarm(supported: DishwasherAlarm::AlarmBitmap::DoorError | DishwasherAlarm::AlarmBitmap::DrainError)
    endpoint1.add_cluster(cluster)
    node.add_endpoint(endpoint1)
    cluster.report_alarms(DishwasherAlarm::AlarmBitmap::DoorError)
    cluster.report_alarms(DishwasherAlarm::AlarmBitmap::DrainError)
    events = node.event_journal.query([Matter::InteractionModel::EventPath.new(
      cluster: DishwasherAlarm::CLUSTER_ID, event: DishwasherAlarm::EVENT_NOTIFY)])
    events.size.should eq(2)
    first = DishwasherAlarm::NotifyEvent.from_tlv(events.first.data)
    first.active.should eq(DishwasherAlarm::AlarmBitmap::DoorError)
    first.inactive.should eq(DishwasherAlarm::AlarmBitmap::None)
    first.state.should eq(DishwasherAlarm::AlarmBitmap::DoorError)
    first.mask.value.should eq(0x06_u8)
    second = DishwasherAlarm::NotifyEvent.from_tlv(events.last.data)
    second.active.should eq(DishwasherAlarm::AlarmBitmap::DrainError)
    second.inactive.should eq(DishwasherAlarm::AlarmBitmap::DoorError)
    second.state.should eq(DishwasherAlarm::AlarmBitmap::DrainError)
    second.to_tlv(nil).as_structure.keys.should eq([0_u8, 1_u8, 2_u8, 3_u8])
  end

  it "latches a resolved condition until Reset and validates command masks" do
    cluster = dishwasher_alarm(feature_map: DishwasherAlarm::Feature::Reset,
      latch: DishwasherAlarm::AlarmBitmap::DoorError)
    cluster.report_alarms(DishwasherAlarm::AlarmBitmap::DoorError)
    cluster.report_alarms(DishwasherAlarm::AlarmBitmap::None)
    cluster.state.should eq(DishwasherAlarm::AlarmBitmap::DoorError)
    expect_status(invoke(cluster, DishwasherAlarm::CMD_RESET,
      DishwasherAlarm::ResetRequest.new(DishwasherAlarm::AlarmBitmap::DrainError)), DishwasherCode::InvalidCommand)
    expect_success(invoke(cluster, DishwasherAlarm::CMD_RESET,
      DishwasherAlarm::ResetRequest.new(DishwasherAlarm::AlarmBitmap::DoorError)))
    cluster.state.should eq(DishwasherAlarm::AlarmBitmap::None)
  end

  it "masks disabled conditions and omits optional ModifyEnabledAlarms when configured absent" do
    cluster = dishwasher_alarm(modify_enabled_alarms_supported: false)
    cluster.commands.should be_empty
    expect_status(invoke(cluster, DishwasherAlarm::CMD_MODIFY_ENABLED_ALARMS,
      DishwasherAlarm::ModifyEnabledAlarmsRequest.new(DishwasherAlarm::AlarmBitmap::None)), DishwasherCode::UnsupportedCommand)
    enabled = dishwasher_alarm
    expect_status(invoke(enabled, DishwasherAlarm::CMD_MODIFY_ENABLED_ALARMS,
      DishwasherAlarm::ModifyEnabledAlarmsRequest.new(DishwasherAlarm::AlarmBitmap::DrainError)), DishwasherCode::InvalidCommand)
    expect_success(invoke(enabled, DishwasherAlarm::CMD_MODIFY_ENABLED_ALARMS,
      DishwasherAlarm::ModifyEnabledAlarmsRequest.new(DishwasherAlarm::AlarmBitmap::None)))
    enabled.report_alarms(DishwasherAlarm::AlarmBitmap::DoorError)
    enabled.state.should eq(DishwasherAlarm::AlarmBitmap::None)
    enabled.mask.should eq(DishwasherAlarm::AlarmBitmap::None)
  end

  it "clears disabled State bits when the host changes Mask directly" do
    cluster = dishwasher_alarm
    cluster.report_alarms(DishwasherAlarm::AlarmBitmap::DoorError)
    cluster.mask = DishwasherAlarm::AlarmBitmap::None
    cluster.state.should eq(DishwasherAlarm::AlarmBitmap::None)
    expect_raises(ArgumentError) { cluster.state = DishwasherAlarm::AlarmBitmap::DoorError }
  end

  it "recomputes State from retained physical conditions when Mask enables an alarm" do
    node = Matter::Node.new
    endpoint1 = Matter::Endpoint.new(endpoint(1))
    cluster = dishwasher_alarm
    endpoint1.add_cluster(cluster)
    node.add_endpoint(endpoint1)
    path = Matter::InteractionModel::EventPath.new(
      cluster: DishwasherAlarm::CLUSTER_ID, event: DishwasherAlarm::EVENT_NOTIFY)

    cluster.mask = DishwasherAlarm::AlarmBitmap::None
    cluster.report_alarms(DishwasherAlarm::AlarmBitmap::DoorError)
    cluster.state.should eq(DishwasherAlarm::AlarmBitmap::None)
    node.event_journal.query([path]).should be_empty

    expect_success(invoke(cluster, DishwasherAlarm::CMD_MODIFY_ENABLED_ALARMS,
      DishwasherAlarm::ModifyEnabledAlarmsRequest.new(DishwasherAlarm::AlarmBitmap::DoorError)))
    cluster.state.should eq(DishwasherAlarm::AlarmBitmap::DoorError)
    records = node.event_journal.query([path])
    records.size.should eq(1)
    first = DishwasherAlarm::NotifyEvent.from_tlv(records.first.data)
    first.active.should eq(DishwasherAlarm::AlarmBitmap::DoorError)
    first.mask.should eq(DishwasherAlarm::AlarmBitmap::DoorError)

    cluster.mask = DishwasherAlarm::AlarmBitmap::None
    cluster.state.should eq(DishwasherAlarm::AlarmBitmap::None)
    records = node.event_journal.query([path])
    records.size.should eq(2)
    second = DishwasherAlarm::NotifyEvent.from_tlv(records.last.data)
    second.inactive.should eq(DishwasherAlarm::AlarmBitmap::DoorError)
    second.mask.should eq(DishwasherAlarm::AlarmBitmap::None)
  end

  it "emits one Notify for direct State changes and subsequent Reset" do
    node = Matter::Node.new
    endpoint1 = Matter::Endpoint.new(endpoint(1))
    cluster = dishwasher_alarm(feature_map: DishwasherAlarm::Feature::Reset)
    endpoint1.add_cluster(cluster)
    node.add_endpoint(endpoint1)
    path = Matter::InteractionModel::EventPath.new(
      cluster: DishwasherAlarm::CLUSTER_ID, event: DishwasherAlarm::EVENT_NOTIFY)

    cluster.state = DishwasherAlarm::AlarmBitmap::DoorError
    cluster.state = DishwasherAlarm::AlarmBitmap::DoorError
    first = node.event_journal.query([path])
    first.size.should eq(1)
    payload = DishwasherAlarm::NotifyEvent.from_tlv(first.first.data)
    payload.active.should eq(DishwasherAlarm::AlarmBitmap::DoorError)
    payload.inactive.should eq(DishwasherAlarm::AlarmBitmap::None)
    payload.state.should eq(DishwasherAlarm::AlarmBitmap::DoorError)

    expect_success(invoke(cluster, DishwasherAlarm::CMD_RESET,
      DishwasherAlarm::ResetRequest.new(DishwasherAlarm::AlarmBitmap::DoorError)))
    second = node.event_journal.query([path])
    second.size.should eq(2)
    reset = DishwasherAlarm::NotifyEvent.from_tlv(second.last.data)
    reset.active.should eq(DishwasherAlarm::AlarmBitmap::None)
    reset.inactive.should eq(DishwasherAlarm::AlarmBitmap::DoorError)
    reset.state.should eq(DishwasherAlarm::AlarmBitmap::None)
  end

  it "encodes inherited command fields at anonymous structure tag zero" do
    reset = DishwasherAlarm::ResetRequest.new(DishwasherAlarm::AlarmBitmap::DoorError)
    reset.to_tlv(nil).as_structure.keys.should eq([0_u8])
    DishwasherAlarm::ResetRequest.from_tlv(reset.to_tlv(nil)).alarms.should eq(DishwasherAlarm::AlarmBitmap::DoorError)
    modify = DishwasherAlarm::ModifyEnabledAlarmsRequest.new(DishwasherAlarm::AlarmBitmap::DrainError)
    modify.to_tlv(nil).as_structure.keys.should eq([0_u8])
    DishwasherAlarm::ModifyEnabledAlarmsRequest.from_tlv(modify.to_tlv(nil)).mask.should eq(DishwasherAlarm::AlarmBitmap::DrainError)
  end

  it "lets the host reject alarm commands without visible state changes" do
    cluster = dishwasher_alarm(feature_map: DishwasherAlarm::Feature::Reset)
    cluster.report_alarms(DishwasherAlarm::AlarmBitmap::DoorError)
    cluster.on_reset { |_alarms| DishwasherStatus.failure }
    expect_status(invoke(cluster, DishwasherAlarm::CMD_RESET,
      DishwasherAlarm::ResetRequest.new(DishwasherAlarm::AlarmBitmap::DoorError)), DishwasherCode::Failure)
    cluster.state.should eq(DishwasherAlarm::AlarmBitmap::DoorError)
    cluster.on_modify_enabled_alarms { |_mask| DishwasherStatus.failure }
    expect_status(invoke(cluster, DishwasherAlarm::CMD_MODIFY_ENABLED_ALARMS,
      DishwasherAlarm::ModifyEnabledAlarmsRequest.new(DishwasherAlarm::AlarmBitmap::None)), DishwasherCode::Failure)
    cluster.mask.should eq(DishwasherAlarm::AlarmBitmap::DoorError)
  end
end
