require "../spec_helper"

private alias TimedOnOff = Matter::Cluster::OnOff

describe "OnOff timed lighting behavior" do
  it "counts down OnTime and turns off when it expires" do
    cluster = build(TimedOnOff, feature_map: TimedOnOff::Feature::Lighting)
    request = TimedOnOff::OnWithTimedOffRequest.new(TimedOnOff::OnOffControl::None, 2_u16, 3_u16)
    invoke(cluster, TimedOnOff::CMD_ON_WITH_TIMED_OFF, request)
    start = Time.instant

    cluster.on_off?.should be_true
    read(cluster, TimedOnOff::ATTR_ON_TIME).should eq(2_u16)
    read(cluster, TimedOnOff::ATTR_OFF_WAIT_TIME).should eq(3_u16)
    cluster.advance_timed_state(start + 110.milliseconds)
    read(cluster, TimedOnOff::ATTR_ON_TIME).should eq(1_u16)
    cluster.advance_timed_state(start + 210.milliseconds)
    cluster.on_off?.should be_false
    read(cluster, TimedOnOff::ATTR_ON_TIME).should eq(0_u16)
    read(cluster, TimedOnOff::ATTR_OFF_WAIT_TIME).should eq(0_u16)
  end

  it "guards an early Off and only shortens OffWaitTime while guarded" do
    cluster = build(TimedOnOff, feature_map: TimedOnOff::Feature::Lighting)
    invoke(cluster, TimedOnOff::CMD_ON_WITH_TIMED_OFF,
      TimedOnOff::OnWithTimedOffRequest.new(TimedOnOff::OnOffControl::None, 5_u16, 4_u16))
    cluster.off
    start = Time.instant
    cluster.on_off?.should be_false
    read(cluster, TimedOnOff::ATTR_ON_TIME).should eq(0_u16)
    cluster.advance_timed_state(start + 110.milliseconds)
    read(cluster, TimedOnOff::ATTR_OFF_WAIT_TIME).should eq(3_u16)

    invoke(cluster, TimedOnOff::CMD_ON_WITH_TIMED_OFF,
      TimedOnOff::OnWithTimedOffRequest.new(TimedOnOff::OnOffControl::None, 5_u16, 2_u16))
    cluster.on_off?.should be_false
    read(cluster, TimedOnOff::ATTR_OFF_WAIT_TIME).should eq(2_u16)
    cluster.advance_timed_state(start + 310.milliseconds)
    read(cluster, TimedOnOff::ATTR_OFF_WAIT_TIME).should eq(0_u16)
  end

  it "honors AcceptOnlyWhenOn and the indefinite hold value" do
    cluster = build(TimedOnOff, feature_map: TimedOnOff::Feature::Lighting)
    invoke(cluster, TimedOnOff::CMD_ON_WITH_TIMED_OFF,
      TimedOnOff::OnWithTimedOffRequest.new(TimedOnOff::OnOffControl::AcceptOnlyWhenOn, 2_u16, 3_u16))
    cluster.on_off?.should be_false

    invoke(cluster, TimedOnOff::CMD_ON_WITH_TIMED_OFF,
      TimedOnOff::OnWithTimedOffRequest.new(TimedOnOff::OnOffControl::None, UInt16::MAX, 3_u16))
    cluster.advance_timed_state(Time.instant + 1.second)
    cluster.on_off?.should be_true
    read(cluster, TimedOnOff::ATTR_ON_TIME).should eq(UInt16::MAX)
  end

  it "runs the countdown without an application tick callback" do
    cluster = build(TimedOnOff, feature_map: TimedOnOff::Feature::Lighting)
    invoke(cluster, TimedOnOff::CMD_ON_WITH_TIMED_OFF,
      TimedOnOff::OnWithTimedOffRequest.new(TimedOnOff::OnOffControl::None, 1_u16, 0_u16))
    deadline = Time.instant + 2.seconds
    while cluster.on_off? && Time.instant < deadline
      sleep 10.milliseconds
    end
    cluster.on_off?.should be_false
  end

  it "applies an Off scene through the timed state transition" do
    cluster = build(TimedOnOff, feature_map: TimedOnOff::Feature::Lighting)
    invoke(cluster, TimedOnOff::CMD_ON_WITH_TIMED_OFF,
      TimedOnOff::OnWithTimedOffRequest.new(TimedOnOff::OnOffControl::None, 5_u16, 2_u16))
    scene = Matter::Cluster::ScenesManagement::ExtensionFieldSet.new(
      TimedOnOff::CLUSTER_ID,
      attribute_list: [{TimedOnOff::ATTR_ON_OFF, TLV::Any.new(false)}] of Tuple(UInt32, TLV::Any))
    cluster.apply_scene_extension_field_set(scene).should be_true
    cluster.on_off?.should be_false
    read(cluster, TimedOnOff::ATTR_ON_TIME).should eq(0_u16)
    cluster.advance_timed_state(Time.instant + 210.milliseconds)
    read(cluster, TimedOnOff::ATTR_OFF_WAIT_TIME).should eq(0_u16)
  end
end
