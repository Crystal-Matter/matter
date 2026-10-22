require "../spec_helper"
require "../../src/matter/cluster/ambient_context_sensing"

private alias Ambient = Matter::Cluster::AmbientContextSensing

describe Ambient do
  unknown = Ambient::SemanticTag.human_activity(Ambient::HumanActivity::Unknown)
  walking = Ambient::SemanticTag.human_activity(Ambient::HumanActivity::Walking)

  it "advertises only the provisional HumanActivity feature and its mandatory surface" do
    cluster = build(Ambient, supported_activity_tags: [unknown, walking])

    cluster.cluster_id.id.should eq(0x0431_u32)
    read(cluster, Matter::Cluster::Base::GLOBAL_CLUSTER_REVISION).should eq(1_u16)
    read(cluster, Matter::Cluster::Base::GLOBAL_FEATURE_MAP).should eq(1_u32)
    [Ambient::ATTR_HUMAN_ACTIVITY_DETECTED, Ambient::ATTR_AMBIENT_CONTEXT_TYPE,
     Ambient::ATTR_AMBIENT_CONTEXT_TYPE_SUPPORTED, Ambient::ATTR_SIMULTANEOUS_DETECTION_LIMIT,
     Ambient::ATTR_HOLD_TIME, Ambient::ATTR_HOLD_TIME_LIMITS].each do |id|
      attribute_ids(cluster).should contain(id)
    end
    [0x0001_u32, 0x0002_u32, 0x0005_u32, 0x0006_u32, 0x0007_u32, 0x000B_u32].each do |id|
      attribute_ids(cluster).should_not contain(id)
    end
    cluster.get_event_metadata(Ambient::EVENT_AMBIENT_CONTEXT_DETECT_STARTED).should_not be_nil
    cluster.get_event_metadata(Ambient::EVENT_AMBIENT_CONTEXT_DETECT_ENDED).should_not be_nil
    limit = cluster.get_attribute_metadata(Ambient::ATTR_SIMULTANEOUS_DETECTION_LIMIT).as(Matter::Cluster::AttributeMetadata)
    hold = cluster.get_attribute_metadata(Ambient::ATTR_HOLD_TIME).as(Matter::Cluster::AttributeMetadata)
    limits = cluster.get_attribute_metadata(Ambient::ATTR_HOLD_TIME_LIMITS).as(Matter::Cluster::AttributeMetadata)
    limit.write_access.should eq(Matter::InteractionModel::EntryPrivilege::Operate)
    hold.write_access.should eq(Matter::InteractionModel::EntryPrivilege::Manage)
    limits.fixed?.should be_true
    limits.writable?.should be_false
    expect_raises(ArgumentError, /HumanActivity/) { build(Ambient, feature_map: Ambient::Feature::None) }
    expect_raises(ArgumentError, /HumanActivity/) { build(Ambient, feature_map: Ambient::Feature.from_value(0x03_u32)) }
  end

  it "encodes standard SemanticTag structs and requires a supported human activity type" do
    cluster = build(Ambient, supported_activity_tags: [unknown, walking])
    supported = read_tlv(cluster, Ambient::ATTR_AMBIENT_CONTEXT_TYPE_SUPPORTED).as_list
    supported.size.should eq(2)
    tag = Ambient::SemanticTag.from_tlv(supported[1])
    tag.mfg_code.should be_nil
    tag.namespace_id.should eq(Ambient::HUMAN_ACTIVITY_NAMESPACE)
    tag.tag.should eq(Ambient::HumanActivity::Walking.value)
    current = read_tlv(cluster, Ambient::ATTR_AMBIENT_CONTEXT_TYPE).as_list
    current.size.should eq(1)
    Ambient::AmbientContextTypeStruct.from_tlv(current[0]).ambient_context_sensed.should eq([unknown])

    expect_raises(ArgumentError) { build(Ambient, supported_activity_tags: [] of Ambient::SemanticTag) }
    expect_raises(ArgumentError) { build(Ambient, supported_activity_tags: [walking]) }
    expect_raises(ArgumentError) { build(Ambient, supported_activity_tags: [unknown, unknown]) }
    expect_raises(ArgumentError, /inactive/) { cluster.observe_human_activity(unknown) }
    expect_raises(ArgumentError) do
      build(Ambient, supported_activity_tags: [unknown,
                                               Ambient::SemanticTag.new(nil, 0x49_u8, Ambient::HumanActivity::Walking.value)])
    end
  end

  it "validates the one-detection capacity and HoldTime bounds on host and wire writes" do
    limits = Ambient::HoldTimeLimits.new(1_u16, 10_u16, 2_u16)
    cluster = build(Ambient, hold_time_limits: limits, hold_time: 2_u16)
    read(cluster, Ambient::ATTR_SIMULTANEOUS_DETECTION_LIMIT).should eq(1_u8)
    read(cluster, Ambient::ATTR_HOLD_TIME).should eq(2_u16)
    Ambient::HoldTimeLimits.from_tlv(read_tlv(cluster, Ambient::ATTR_HOLD_TIME_LIMITS)).should eq(limits)
    write(cluster, Ambient::ATTR_SIMULTANEOUS_DETECTION_LIMIT, 2_u8).status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    write(cluster, Ambient::ATTR_HOLD_TIME, 0_u16).status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    write(cluster, Ambient::ATTR_HOLD_TIME, 11_u16).status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    write(cluster, Ambient::ATTR_HOLD_TIME, 3_u16).status.should eq(Matter::InteractionModel::StatusCode::Success)
    cluster.hold_time.should eq(3_u16)
    expect_raises(ArgumentError) { cluster.hold_time = 0_u16 }
    expect_raises(ArgumentError) { cluster.simultaneous_detection_limit = 2_u8 }
    expect_raises(ArgumentError) { cluster.hold_time_limits = Ambient::HoldTimeLimits.new(1_u16, 20_u16, 2_u16) }
    expect_raises(ArgumentError) { Ambient::HoldTimeLimits.new(0_u16, 10_u16, 1_u16) }
    expect_raises(ArgumentError) { Ambient::HoldTimeLimits.new(2_u16, 9_u16, 2_u16) }
  end

  it "emits typed start and end payloads, avoids duplicate starts, and expires after HoldTime" do
    cluster = build(Ambient, supported_activity_tags: [unknown, walking], hold_time: 1_u16)
    events = [] of Tuple(UInt32, TLV::Any)
    cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, id : UInt32, _priority : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) do
      events << {id, data}
      nil
    end

    cluster.observe_human_activity(walking)
    cluster.human_activity_detected?.should be_true
    read(cluster, Ambient::ATTR_HUMAN_ACTIVITY_DETECTED).should be_true
    Ambient::AmbientContextTypeStruct.from_tlv(
      read_tlv(cluster, Ambient::ATTR_AMBIENT_CONTEXT_TYPE).as_list[0]).ambient_context_sensed.should eq([walking])
    events.size.should eq(1)
    events[0][0].should eq(Ambient::EVENT_AMBIENT_CONTEXT_DETECT_STARTED)
    Ambient::AmbientContextDetectStartedEvent.from_tlv(events[0][1]).ambient_context_detected.ambient_context_sensed.should eq([walking])

    cluster.observe_human_activity(walking)
    events.size.should eq(1)
    deadline = Time.instant + 3.seconds
    while cluster.human_activity_detected? && Time.instant < deadline
      sleep 20.milliseconds
    end
    cluster.human_activity_detected?.should be_false
    read(cluster, Ambient::ATTR_HUMAN_ACTIVITY_DETECTED).should be_false
    events.size.should eq(2)
    events[1][0].should eq(Ambient::EVENT_AMBIENT_CONTEXT_DETECT_ENDED)
    Ambient::AmbientContextDetectEndedEvent.from_tlv(events[1][1]).event_start_time.should be > 0_u64
    Ambient::AmbientContextTypeStruct.from_tlv(
      read_tlv(cluster, Ambient::ATTR_AMBIENT_CONTEXT_TYPE).as_list[0]).ambient_context_sensed.should eq([unknown])
  end

  it "persists HoldTime while detection state is volatile" do
    source = build(Ambient, supported_activity_tags: [unknown, walking], hold_time: 2_u16)
    source.observe_human_activity(walking)
    write(source, Ambient::ATTR_HOLD_TIME, 3_u16).status.should eq(Matter::InteractionModel::StatusCode::Success)
    document = source.save_state.as(Matter::Storage::Document)
    document.keys.should contain("hold_time")
    document.keys.should_not contain("human_activity_detected")
    restored = build(Ambient, supported_activity_tags: [unknown, walking], hold_time: 2_u16)
    restored.restore_state(document)
    restored.hold_time.should eq(3_u16)
    restored.human_activity_detected?.should be_false
  end
end
