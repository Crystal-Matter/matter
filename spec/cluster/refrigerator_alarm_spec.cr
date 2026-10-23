require "../spec_helper"

private alias RefrigeratorAlarm = Matter::Cluster::RefrigeratorAlarm
private alias RefrigeratorCode = Matter::InteractionModel::StatusCode
private REFRIGERATOR_LATCH_ATTRIBUTE               = 0x0001_u32
private REFRIGERATOR_RESET_COMMAND                 =   0x00_u32
private REFRIGERATOR_MODIFY_ENABLED_ALARMS_COMMAND =   0x01_u32

private def refrigerator_alarm(**options)
  build(RefrigeratorAlarm, **options)
end

describe RefrigeratorAlarm do
  it "advertises revision one and only the Alarm Base fields allowed by Refrigerator Alarm" do
    cluster = refrigerator_alarm
    cluster.cluster_id.id.should eq(0x0057_u32)
    cluster.cluster_revision.should eq(1_u16)
    read(cluster, 0xFFFC_u32).should eq(0_u32)
    cluster.attributes.map(&.id.id).should eq([
      RefrigeratorAlarm::ATTR_MASK, RefrigeratorAlarm::ATTR_STATE, RefrigeratorAlarm::ATTR_SUPPORTED,
    ])
    cluster.commands.should be_empty
    cluster.events.map(&.id.id).should eq([RefrigeratorAlarm::EVENT_NOTIFY])
    read(cluster, RefrigeratorAlarm::ATTR_SUPPORTED).should eq(1_u8)
    read(cluster, RefrigeratorAlarm::ATTR_MASK).should eq(1_u8)
    read_status(cluster, REFRIGERATOR_LATCH_ATTRIBUTE).status.should eq(RefrigeratorCode::UnsupportedAttribute)
  end

  it "accepts only the DoorOpen alarm and keeps Supported fixed" do
    cluster = refrigerator_alarm
    expect_raises(ArgumentError) { refrigerator_alarm(supported: RefrigeratorAlarm::AlarmBitmap::None) }
    expect_raises(ArgumentError) { refrigerator_alarm(supported: RefrigeratorAlarm::AlarmBitmap.new(2_u8)) }
    expect_raises(ArgumentError) { cluster.mask = RefrigeratorAlarm::AlarmBitmap.new(2_u8) }
    expect_raises(ArgumentError) { cluster.report_alarms(RefrigeratorAlarm::AlarmBitmap.new(2_u8)) }
    expect_raises(ArgumentError) { cluster.supported = RefrigeratorAlarm::AlarmBitmap::None }
  end

  it "publishes DoorOpen transitions with canonical Notify event fields" do
    node = Matter::Node.new
    endpoint1 = Matter::Endpoint.new(endpoint(1))
    cluster = refrigerator_alarm
    endpoint1.add_cluster(cluster)
    node.add_endpoint(endpoint1)

    cluster.report_alarms(RefrigeratorAlarm::AlarmBitmap::DoorOpen)
    cluster.report_alarms(RefrigeratorAlarm::AlarmBitmap::None)
    events = node.event_journal.query([Matter::InteractionModel::EventPath.new(
      cluster: RefrigeratorAlarm::CLUSTER_ID, event: RefrigeratorAlarm::EVENT_NOTIFY)])
    events.size.should eq(2)
    first = RefrigeratorAlarm::NotifyEvent.from_tlv(events.first.data)
    first.active.should eq(RefrigeratorAlarm::AlarmBitmap::DoorOpen)
    first.inactive.should eq(RefrigeratorAlarm::AlarmBitmap::None)
    first.state.should eq(RefrigeratorAlarm::AlarmBitmap::DoorOpen)
    first.mask.should eq(RefrigeratorAlarm::AlarmBitmap::DoorOpen)
    second = RefrigeratorAlarm::NotifyEvent.from_tlv(events.last.data)
    second.active.should eq(RefrigeratorAlarm::AlarmBitmap::None)
    second.inactive.should eq(RefrigeratorAlarm::AlarmBitmap::DoorOpen)
    second.state.should eq(RefrigeratorAlarm::AlarmBitmap::None)
    second.to_tlv(nil).as_structure.keys.should eq([0_u8, 1_u8, 2_u8, 3_u8])
  end

  it "suppresses a disabled alarm and reports it when the host enables Mask" do
    cluster = refrigerator_alarm
    cluster.mask = RefrigeratorAlarm::AlarmBitmap::None
    cluster.report_alarms(RefrigeratorAlarm::AlarmBitmap::DoorOpen)
    cluster.state.should eq(RefrigeratorAlarm::AlarmBitmap::None)
    cluster.mask = RefrigeratorAlarm::AlarmBitmap::DoorOpen
    cluster.state.should eq(RefrigeratorAlarm::AlarmBitmap::DoorOpen)
  end

  it "does not accept Alarm Base commands forbidden by Refrigerator Alarm" do
    cluster = refrigerator_alarm
    expect_status(invoke(cluster, REFRIGERATOR_RESET_COMMAND), RefrigeratorCode::UnsupportedCommand)
    expect_status(invoke(cluster, REFRIGERATOR_MODIFY_ENABLED_ALARMS_COMMAND), RefrigeratorCode::UnsupportedCommand)
  end
end
