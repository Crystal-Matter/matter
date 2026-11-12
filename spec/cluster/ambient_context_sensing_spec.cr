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

describe "Ambient Context Sensing HoldTimeMax" do
  it "extends the same detection only once in a HoldTime period" do
    limits = Ambient::HoldTimeLimits.new(1_u16, 10_u16, 1_u16)
    unknown = Ambient::SemanticTag.human_activity(Ambient::HumanActivity::Unknown)
    walking = Ambient::SemanticTag.human_activity(Ambient::HumanActivity::Walking)
    cluster = build(Ambient, supported_activity_tags: [unknown, walking], hold_time_limits: limits)
    events = [] of UInt32
    cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, id : UInt32, _priority : Matter::InteractionModel::EventPriority, _data : TLV::Any, _fabric : UInt8?) do
      events << id
      nil
    end

    started_at = Time.instant
    cluster.observe_human_activity(walking)
    sleep 200.milliseconds
    cluster.observe_human_activity(walking)
    sleep 200.milliseconds
    cluster.observe_human_activity(walking)
    before_expiry = started_at + 1.25.seconds - Time.instant
    sleep before_expiry if before_expiry > 0.seconds
    cluster.human_activity_detected?.should be_true
    after_expiry = started_at + 2.25.seconds - Time.instant
    sleep after_expiry if after_expiry > 0.seconds
    cluster.human_activity_detected?.should be_false
    events.should eq([Ambient::EVENT_AMBIENT_CONTEXT_DETECT_STARTED,
                      Ambient::EVENT_AMBIENT_CONTEXT_DETECT_ENDED])
  end

  it "ends a continuously repeated detection by HoldTimeMax in every supported sensing profile" do
    limits = Ambient::HoldTimeLimits.new(1_u16, 10_u16, 1_u16)
    unknown_activity = Ambient::SemanticTag.human_activity(Ambient::HumanActivity::Unknown)
    walking = Ambient::SemanticTag.human_activity(Ambient::HumanActivity::Walking)
    unknown_sound = Ambient::SemanticTag.identified_sound(Ambient::IdentifiedSound::Unknown)
    barking = Ambient::SemanticTag.identified_sound(Ambient::IdentifiedSound::Barking)
    unknown_object = Ambient::SemanticTag.identified_object(Ambient::IdentifiedObject::Unknown)
    person = Ambient::SemanticTag.identified_object(Ambient::IdentifiedObject::Person)
    ha = build(Ambient, supported_activity_tags: [unknown_activity, walking],
      hold_time_limits: limits)
    ha_pred = build(Ambient,
      feature_map: Ambient::Feature::HumanActivity | Ambient::Feature::PredictedActivity,
      supported_activity_tags: [unknown_activity, walking], hold_time_limits: limits,
      prediction_clock: -> : UInt32? { 100_u32 })
    aud = build(Ambient, feature_map: Ambient::Feature::SoundIdentification,
      supported_sound_tags: [unknown_sound, barking], hold_time_limits: limits)
    aud_pred = build(Ambient,
      feature_map: Ambient::Feature::SoundIdentification | Ambient::Feature::PredictedActivity,
      supported_sound_tags: [unknown_sound, barking], hold_time_limits: limits,
      prediction_clock: -> : UInt32? { 100_u32 })
    oc_oi = build(Ambient,
      feature_map: Ambient::Feature::ObjectCounting | Ambient::Feature::ObjectIdentification,
      supported_object_tags: [unknown_object, person], hold_time_limits: limits)

    started_at = Time.instant
    ha.observe_human_activity(walking)
    ha_pred.observe_human_activity(walking)
    aud.observe_sound(barking)
    aud_pred.observe_sound(barking)
    oc_oi.observe_object_count(person, 1_u16)
    while Time.instant - started_at < 9.4.seconds
      sleep 250.milliseconds
      ha.observe_human_activity(walking)
      ha_pred.observe_human_activity(walking)
      aud.observe_sound(barking)
      aud_pred.observe_sound(barking)
      oc_oi.observe_object_count(person, 1_u16)
    end
    remaining = started_at + 10.2.seconds - Time.instant
    sleep remaining if remaining > 0.seconds

    ha.human_activity_detected?.should be_false
    ha_pred.human_activity_detected?.should be_false
    aud.audio_context_detected?.should be_false
    aud_pred.audio_context_detected?.should be_false
    oc_oi.object_identified?.should be_false
  end
end

describe "Ambient Context Sensing HA+PRED profile" do
  unknown = Ambient::SemanticTag.human_activity(Ambient::HumanActivity::Unknown)
  walking = Ambient::SemanticTag.human_activity(Ambient::HumanActivity::Walking)
  feature_map = Ambient::Feature::HumanActivity | Ambient::Feature::PredictedActivity

  it "advertises the conditional prediction list and its canonical Matter epoch wire fields" do
    now = 100_u32
    cluster = build(Ambient, feature_map: feature_map,
      supported_activity_tags: [unknown, walking], prediction_clock: -> : UInt32? { now })
    read(cluster, Matter::Cluster::Base::GLOBAL_FEATURE_MAP).should eq(feature_map.value)
    attribute_ids(cluster).should contain(Ambient::ATTR_PREDICTED_ACTIVITY)
    read_tlv(cluster, Ambient::ATTR_PREDICTED_ACTIVITY).as_list.should be_empty
    cluster.get_event_metadata(Ambient::EVENT_AMBIENT_CONTEXT_DETECT_STARTED).should_not be_nil
    cluster.get_event_metadata(Ambient::EVENT_AMBIENT_CONTEXT_DETECT_ENDED).should_not be_nil

    changed = [] of UInt32
    cluster.on_attribute_changed = ->(_ep : UInt16, _cl : UInt32, attr : UInt32) { changed << attr; nil }
    forecast = Ambient::PredictedActivityStruct.new(120_u32, 180_u32, [walking], 80_u8)
    version = cluster.data_version
    cluster.replace_predicted_activities([forecast])
    cluster.data_version.should eq(version + 1_u32)
    changed.should eq([Ambient::ATTR_PREDICTED_ACTIVITY])
    wire = read_tlv(cluster, Ambient::ATTR_PREDICTED_ACTIVITY).as_list
    wire.size.should eq(1)
    decoded = Ambient::PredictedActivityStruct.from_tlv(wire[0])
    decoded.start_timestamp.should eq(120_u32)
    decoded.end_timestamp.should eq(180_u32)
    decoded.ambient_context_type.should eq([walking])
    decoded.confidence.should eq(80_u8)
    wire[0].as_structure.keys.should eq([0_u8, 1_u8, 2_u8, 5_u8])
    cluster.replace_predicted_activities([forecast])
    cluster.data_version.should eq(version + 1_u32)

    now = 120_u32
    read_tlv(cluster, Ambient::ATTR_PREDICTED_ACTIVITY).as_list.should be_empty
    cluster.data_version.should eq(version + 2_u32)
    changed.should eq([Ambient::ATTR_PREDICTED_ACTIVITY, Ambient::ATTR_PREDICTED_ACTIVITY])
  end

  it "validates the entire replacement before publication and prunes on clock advance" do
    now = 100_u32
    cluster = build(Ambient, feature_map: feature_map,
      supported_activity_tags: [unknown, walking], prediction_clock: -> : UInt32? { now })
    first = Ambient::PredictedActivityStruct.new(110_u32, 120_u32, [walking], 50_u8)
    second = Ambient::PredictedActivityStruct.new(130_u32, 140_u32, [unknown], 75_u8)
    cluster.replace_predicted_activities([first, second])
    version = cluster.data_version
    expect_raises(ArgumentError, /ordered/) do
      cluster.replace_predicted_activities([first,
                                            Ambient::PredictedActivityStruct.new(120_u32, 150_u32, [walking], 50_u8)])
    end
    expect_raises(ArgumentError, /future/) do
      cluster.replace_predicted_activities([
        Ambient::PredictedActivityStruct.new(100_u32, 120_u32, [walking], 50_u8),
      ])
    end
    expect_raises(ArgumentError, /supported/) do
      cluster.replace_predicted_activities([
        Ambient::PredictedActivityStruct.new(110_u32, 120_u32,
          [Ambient::SemanticTag.human_activity(Ambient::HumanActivity::Sleeping)], 50_u8),
      ])
    end
    expect_raises(ArgumentError, /one supported/) do
      cluster.replace_predicted_activities([
        Ambient::PredictedActivityStruct.new(110_u32, 120_u32, [walking, unknown], 50_u8),
      ])
    end
    expect_raises(ArgumentError, /too many/) do
      cluster.replace_predicted_activities(Array.new(Ambient::MAX_PREDICTED_ACTIVITIES + 1) { first })
    end
    cluster.data_version.should eq(version)
    cluster.predicted_activity.size.should eq(2)
    now = 110_u32
    cluster.refresh_predicted_activities
    cluster.predicted_activity.should eq([second])
    now = 130_u32
    cluster.refresh_predicted_activities
    cluster.predicted_activity.should be_empty
  end

  it "rejects unsupported shapes, missing clocks, and unavailable time" do
    expect_raises(ArgumentError, /clock/) { build(Ambient, feature_map: feature_map) }
    now : UInt32? = nil
    cluster = build(Ambient, feature_map: feature_map,
      supported_activity_tags: [unknown, walking], prediction_clock: -> : UInt32? { now })
    expect_raises(ArgumentError, /unavailable/) do
      cluster.replace_predicted_activities([
        Ambient::PredictedActivityStruct.new(110_u32, 120_u32, [walking], 50_u8),
      ])
    end
    now = 100_u32
    cluster.replace_predicted_activities([
      Ambient::PredictedActivityStruct.new(110_u32, 120_u32, [walking], 50_u8),
    ])
    now = nil
    cluster.refresh_predicted_activities
    cluster.predicted_activity.should be_empty
    expect_raises(ArgumentError, /precede/) do
      Ambient::PredictedActivityStruct.new(120_u32, 120_u32, [walking], 50_u8)
    end
    expect_raises(ArgumentError, /confidence/) do
      Ambient::PredictedActivityStruct.new(110_u32, 120_u32, [walking], 101_u8)
    end
    expect_raises(ArgumentError, /tags/) do
      Ambient::PredictedActivityStruct.new(110_u32, 120_u32, [] of Ambient::SemanticTag, 50_u8)
    end
    normal = build(Ambient, supported_activity_tags: [unknown, walking])
    attribute_ids(normal).should_not contain(Ambient::ATTR_PREDICTED_ACTIVITY)
    expect_raises(ArgumentError, /not enabled/) do
      normal.replace_predicted_activities([] of Ambient::PredictedActivityStruct)
    end
  end
end

describe "Ambient Context Sensing OI+PRED profile" do
  unknown = Ambient::SemanticTag.identified_object(Ambient::IdentifiedObject::Unknown)
  person = Ambient::SemanticTag.identified_object(Ambient::IdentifiedObject::Person)
  feature_map = Ambient::Feature::ObjectIdentification | Ambient::Feature::PredictedActivity

  it "advertises object identity, tagged forecasts, and detection events without count fields" do
    now : UInt32? = 100_u32
    cluster = build(Ambient, feature_map: feature_map,
      supported_object_tags: [unknown, person], prediction_clock: -> : UInt32? { now })

    read(cluster, Matter::Cluster::Base::GLOBAL_FEATURE_MAP).should eq(feature_map.value)
    [Ambient::ATTR_OBJECT_IDENTIFIED, Ambient::ATTR_AMBIENT_CONTEXT_TYPE,
     Ambient::ATTR_AMBIENT_CONTEXT_TYPE_SUPPORTED, Ambient::ATTR_SIMULTANEOUS_DETECTION_LIMIT,
     Ambient::ATTR_HOLD_TIME, Ambient::ATTR_HOLD_TIME_LIMITS,
     Ambient::ATTR_PREDICTED_ACTIVITY].each { |id| attribute_ids(cluster).should contain(id) }
    [Ambient::ATTR_HUMAN_ACTIVITY_DETECTED, Ambient::ATTR_AUDIO_CONTEXT_DETECTED,
     Ambient::ATTR_OBJECT_COUNT_REACHED, Ambient::ATTR_OBJECT_COUNT_CONFIG,
     Ambient::ATTR_OBJECT_COUNT].each { |id| attribute_ids(cluster).should_not contain(id) }
    cluster.get_event_metadata(Ambient::EVENT_AMBIENT_CONTEXT_DETECT_STARTED).should_not be_nil
    cluster.get_event_metadata(Ambient::EVENT_AMBIENT_CONTEXT_DETECT_ENDED).should_not be_nil
    read(cluster, Ambient::ATTR_OBJECT_IDENTIFIED).should be_false
    cluster.ambient_context_type_supported.should eq([unknown, person])
    read_tlv(cluster, Ambient::ATTR_PREDICTED_ACTIVITY).as_list.should be_empty
  end

  it "publishes only configured object tags, prunes forecasts, and emits identity events without counts" do
    now : UInt32? = 100_u32
    cluster = build(Ambient, feature_map: feature_map,
      supported_object_tags: [unknown, person], prediction_clock: -> : UInt32? { now })
    events = [] of Tuple(UInt32, TLV::Any)
    cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, id : UInt32, _priority : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) do
      events << {id, data}
      nil
    end

    first = Ambient::PredictedActivityStruct.new(120_u32, 180_u32, [person], 80_u8)
    second = Ambient::PredictedActivityStruct.new(190_u32, 210_u32, [unknown], 60_u8)
    cluster.replace_predicted_activities([first, second])
    wire = read_tlv(cluster, Ambient::ATTR_PREDICTED_ACTIVITY).as_list
    wire.size.should eq(2)
    wire.first.as_structure.has_key?(2_u8).should be_true
    wire.first.as_structure.has_key?(3_u8).should be_false
    wire.first.as_structure.has_key?(4_u8).should be_false
    Ambient::PredictedActivityStruct.from_tlv(wire.first).ambient_context_type.should eq([person])

    expect_raises(ArgumentError, /supported ambient context tag/) do
      cluster.replace_predicted_activities([
        Ambient::PredictedActivityStruct.new(130_u32, 140_u32,
          [Ambient::SemanticTag.identified_sound(Ambient::IdentifiedSound::Barking)], 50_u8),
      ])
    end
    expect_raises(ArgumentError, /crowd fields/) do
      cluster.replace_predicted_activities([
        Ambient::PredictedActivityStruct.new(130_u32, 140_u32, [person], 50_u8, true),
      ])
    end
    cluster.predicted_activity.should eq([first, second])

    cluster.observe_object(person, true)
    read(cluster, Ambient::ATTR_OBJECT_IDENTIFIED).should be_true
    started = events.first
    started[0].should eq(Ambient::EVENT_AMBIENT_CONTEXT_DETECT_STARTED)
    started[1].as_structure.has_key?(1_u8).should be_false
    started[1].as_structure.has_key?(2_u8).should be_false
    Ambient::AmbientContextDetectStartedEvent.from_tlv(started[1])
      .ambient_context_detected.ambient_context_sensed.should eq([person])
    cluster.observe_object(person, false)
    events.last[0].should eq(Ambient::EVENT_AMBIENT_CONTEXT_DETECT_ENDED)

    now = 120_u32
    cluster.refresh_predicted_activities
    cluster.predicted_activity.should eq([second])
    now = nil
    cluster.refresh_predicted_activities
    cluster.predicted_activity.should be_empty
  end
end

describe "Ambient Context Sensing OC+OI+PRED profile" do
  unknown = Ambient::SemanticTag.identified_object(Ambient::IdentifiedObject::Unknown)
  person = Ambient::SemanticTag.identified_object(Ambient::IdentifiedObject::Person)
  feature_map = Ambient::Feature::ObjectCounting | Ambient::Feature::ObjectIdentification |
                Ambient::Feature::PredictedActivity

  it "advertises counting, identity, forecasts, and events with both conditional prediction fields" do
    now : UInt32? = 100_u32
    cluster = build(Ambient, feature_map: feature_map,
      supported_object_tags: [unknown, person],
      object_count_config: Ambient::ObjectCountConfig.new(person, 2_u16),
      prediction_clock: -> : UInt32? { now })

    read(cluster, Matter::Cluster::Base::GLOBAL_FEATURE_MAP).should eq(feature_map.value)
    [Ambient::ATTR_OBJECT_IDENTIFIED, Ambient::ATTR_AMBIENT_CONTEXT_TYPE,
     Ambient::ATTR_AMBIENT_CONTEXT_TYPE_SUPPORTED, Ambient::ATTR_OBJECT_COUNT_REACHED,
     Ambient::ATTR_OBJECT_COUNT_CONFIG, Ambient::ATTR_OBJECT_COUNT,
     Ambient::ATTR_SIMULTANEOUS_DETECTION_LIMIT, Ambient::ATTR_HOLD_TIME,
     Ambient::ATTR_HOLD_TIME_LIMITS, Ambient::ATTR_PREDICTED_ACTIVITY].each do |id|
      attribute_ids(cluster).should contain(id)
    end
    [Ambient::ATTR_HUMAN_ACTIVITY_DETECTED, Ambient::ATTR_AUDIO_CONTEXT_DETECTED].each do |id|
      attribute_ids(cluster).should_not contain(id)
    end
    cluster.get_event_metadata(Ambient::EVENT_AMBIENT_CONTEXT_DETECT_STARTED).should_not be_nil
    cluster.get_event_metadata(Ambient::EVENT_AMBIENT_CONTEXT_DETECT_ENDED).should_not be_nil
    read(cluster, Ambient::ATTR_OBJECT_IDENTIFIED).should be_false
    read(cluster, Ambient::ATTR_OBJECT_COUNT_REACHED).should be_false
    read_tlv(cluster, Ambient::ATTR_PREDICTED_ACTIVITY).as_list.should be_empty

    forecast = Ambient::PredictedActivityStruct.new(120_u32, 180_u32,
      [person], 80_u8, true, 12_u8)
    cluster.replace_predicted_activities([forecast])
    wire = read_tlv(cluster, Ambient::ATTR_PREDICTED_ACTIVITY).as_list.first
    wire.as_structure.keys.should eq([0_u8, 1_u8, 2_u8, 3_u8, 4_u8, 5_u8])
    decoded = Ambient::PredictedActivityStruct.from_tlv(wire)
    decoded.ambient_context_type.should eq([person])
    decoded.crowd_detected.should be_true
    decoded.crowd_count.should eq(12_u8)
  end

  it "validates both forecast dimensions atomically and prunes on clock changes" do
    now : UInt32? = 100_u32
    cluster = build(Ambient, feature_map: feature_map,
      supported_object_tags: [unknown, person],
      object_count_config: Ambient::ObjectCountConfig.new(person, 2_u16),
      prediction_clock: -> : UInt32? { now })
    first = Ambient::PredictedActivityStruct.new(120_u32, 180_u32, [person], 80_u8, true, 12_u8)
    second = Ambient::PredictedActivityStruct.new(190_u32, 210_u32, [unknown], 60_u8, false)
    cluster.replace_predicted_activities([first, second])
    wire = read_tlv(cluster, Ambient::ATTR_PREDICTED_ACTIVITY).as_list
    wire[1].as_structure.keys.should eq([0_u8, 1_u8, 2_u8, 3_u8, 5_u8])
    version = cluster.data_version

    expect_raises(ArgumentError, /CrowdDetected/) do
      cluster.replace_predicted_activities([
        Ambient::PredictedActivityStruct.new(130_u32, 140_u32, [person], 50_u8),
      ])
    end
    expect_raises(ArgumentError, /supported ambient context tag/) do
      cluster.replace_predicted_activities([
        Ambient::PredictedActivityStruct.crowd(130_u32, 140_u32, true, 50_u8),
      ])
    end
    expect_raises(ArgumentError, /supported ambient context tag/) do
      cluster.replace_predicted_activities([
        Ambient::PredictedActivityStruct.new(130_u32, 140_u32,
          [Ambient::SemanticTag.identified_sound(Ambient::IdentifiedSound::Barking)], 50_u8, true),
      ])
    end
    cluster.data_version.should eq(version)
    cluster.predicted_activity.should eq([first, second])

    now = 120_u32
    cluster.refresh_predicted_activities
    cluster.predicted_activity.should eq([second])
    now = nil
    cluster.refresh_predicted_activities
    cluster.predicted_activity.should be_empty
  end

  it "keeps live count threshold events and expiry alongside forecasts" do
    now : UInt32? = 100_u32
    cluster = build(Ambient, feature_map: feature_map,
      supported_object_tags: [unknown, person],
      object_count_config: Ambient::ObjectCountConfig.new(person, 2_u16),
      hold_time: 1_u16, prediction_clock: -> : UInt32? { now })
    events = [] of Tuple(UInt32, TLV::Any)
    cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, id : UInt32, _priority : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) do
      events << {id, data}
      nil
    end
    cluster.replace_predicted_activities([
      Ambient::PredictedActivityStruct.new(120_u32, 180_u32, [person], 80_u8, true, 12_u8),
    ])
    cluster.observe_object_count(person, 2_u16)
    read(cluster, Ambient::ATTR_OBJECT_IDENTIFIED).should be_true
    read(cluster, Ambient::ATTR_OBJECT_COUNT_REACHED).should be_true
    read(cluster, Ambient::ATTR_OBJECT_COUNT).should eq(2_u16)
    started = Ambient::AmbientContextDetectStartedEvent.from_tlv(events.first[1])
    started.ambient_context_detected.ambient_context_sensed.should eq([person])
    started.object_count_reached.should be_true
    started.object_count.should eq(2_u16)

    deadline = Time.instant + 3.seconds
    while cluster.object_identified? && Time.instant < deadline
      sleep 20.milliseconds
    end
    cluster.object_identified?.should be_false
    read(cluster, Ambient::ATTR_OBJECT_COUNT_REACHED).should be_false
    read(cluster, Ambient::ATTR_OBJECT_COUNT).should be_nil
    events.last[0].should eq(Ambient::EVENT_AMBIENT_CONTEXT_DETECT_ENDED)
    cluster.predicted_activity.size.should eq(1)
  end
end

describe "Ambient Context Sensing OC-only profile" do
  it "advertises only the unconditional attributes, with no live count, identity, forecast, or events" do
    cluster = build(Ambient, feature_map: Ambient::Feature::ObjectCounting)

    read(cluster, Matter::Cluster::Base::GLOBAL_FEATURE_MAP).should eq(Ambient::Feature::ObjectCounting.value)
    [Ambient::ATTR_SIMULTANEOUS_DETECTION_LIMIT, Ambient::ATTR_HOLD_TIME,
     Ambient::ATTR_HOLD_TIME_LIMITS].each { |id| attribute_ids(cluster).should contain(id) }
    [Ambient::ATTR_HUMAN_ACTIVITY_DETECTED, Ambient::ATTR_OBJECT_IDENTIFIED,
     Ambient::ATTR_AUDIO_CONTEXT_DETECTED, Ambient::ATTR_AMBIENT_CONTEXT_TYPE,
     Ambient::ATTR_AMBIENT_CONTEXT_TYPE_SUPPORTED, Ambient::ATTR_OBJECT_COUNT_REACHED,
     Ambient::ATTR_OBJECT_COUNT_CONFIG, Ambient::ATTR_OBJECT_COUNT,
     Ambient::ATTR_PREDICTED_ACTIVITY].each { |id| attribute_ids(cluster).should_not contain(id) }
    cluster.get_event_metadata(Ambient::EVENT_AMBIENT_CONTEXT_DETECT_STARTED).should be_nil
    cluster.get_event_metadata(Ambient::EVENT_AMBIENT_CONTEXT_DETECT_ENDED).should be_nil
  end

  it "keeps count, identity, and forecast host operations unavailable" do
    cluster = build(Ambient, feature_map: Ambient::Feature::ObjectCounting)
    person = Ambient::SemanticTag.identified_object(Ambient::IdentifiedObject::Person)
    expect_raises(ArgumentError, /not enabled/) { cluster.observe_object_count(person, 1_u16) }
    expect_raises(ArgumentError, /not enabled/) { cluster.observe_object(person, true) }
    expect_raises(ArgumentError, /not enabled/) do
      cluster.replace_predicted_activities([] of Ambient::PredictedActivityStruct)
    end
    expect_raises(ArgumentError, /ObjectIdentification/) do
      build(Ambient, feature_map: Ambient::Feature::ObjectCounting,
        object_count_config: Ambient::ObjectCountConfig.new(person, 2_u16))
    end
    expect_raises(ArgumentError) { build(Ambient, feature_map: Ambient::Feature::PredictedActivity) }
  end
end

describe "Ambient Context Sensing OC+PRED profile" do
  feature_map = Ambient::Feature::ObjectCounting | Ambient::Feature::PredictedActivity

  it "advertises crowd forecasts without identity, count attributes, or detection events" do
    now : UInt32? = 100_u32
    cluster = build(Ambient, feature_map: feature_map,
      prediction_clock: -> : UInt32? { now })

    read(cluster, Matter::Cluster::Base::GLOBAL_FEATURE_MAP).should eq(feature_map.value)
    [Ambient::ATTR_SIMULTANEOUS_DETECTION_LIMIT, Ambient::ATTR_HOLD_TIME,
     Ambient::ATTR_HOLD_TIME_LIMITS, Ambient::ATTR_PREDICTED_ACTIVITY].each do |id|
      attribute_ids(cluster).should contain(id)
    end
    [Ambient::ATTR_HUMAN_ACTIVITY_DETECTED, Ambient::ATTR_OBJECT_IDENTIFIED,
     Ambient::ATTR_AUDIO_CONTEXT_DETECTED, Ambient::ATTR_AMBIENT_CONTEXT_TYPE,
     Ambient::ATTR_AMBIENT_CONTEXT_TYPE_SUPPORTED, Ambient::ATTR_OBJECT_COUNT_REACHED,
     Ambient::ATTR_OBJECT_COUNT_CONFIG, Ambient::ATTR_OBJECT_COUNT].each do |id|
      attribute_ids(cluster).should_not contain(id)
    end
    cluster.get_event_metadata(Ambient::EVENT_AMBIENT_CONTEXT_DETECT_STARTED).should be_nil
    cluster.get_event_metadata(Ambient::EVENT_AMBIENT_CONTEXT_DETECT_ENDED).should be_nil
    read_tlv(cluster, Ambient::ATTR_PREDICTED_ACTIVITY).as_list.should be_empty
  end

  it "publishes crowd-only TLV fields atomically and prunes expired forecasts" do
    now : UInt32? = 100_u32
    cluster = build(Ambient, feature_map: feature_map,
      prediction_clock: -> : UInt32? { now })
    changed = [] of UInt32
    cluster.on_attribute_changed = ->(_ep : UInt16, _cl : UInt32, attr : UInt32) { changed << attr; nil }
    first = Ambient::PredictedActivityStruct.crowd(120_u32, 180_u32, true, 80_u8, 12_u8)
    second = Ambient::PredictedActivityStruct.crowd(190_u32, 210_u32, false, 60_u8)

    version = cluster.data_version
    cluster.replace_predicted_activities([first, second])
    cluster.data_version.should eq(version + 1_u32)
    changed.should eq([Ambient::ATTR_PREDICTED_ACTIVITY])
    wire = read_tlv(cluster, Ambient::ATTR_PREDICTED_ACTIVITY).as_list
    wire.size.should eq(2)
    wire[0].as_structure.keys.should eq([0_u8, 1_u8, 3_u8, 4_u8, 5_u8])
    wire[1].as_structure.keys.should eq([0_u8, 1_u8, 3_u8, 5_u8])
    decoded = Ambient::PredictedActivityStruct.from_tlv(wire[0])
    decoded.ambient_context_type.should be_nil
    decoded.crowd_detected.should be_true
    decoded.crowd_count.should eq(12_u8)
    decoded.confidence.should eq(80_u8)
    cluster.replace_predicted_activities([first, second])
    cluster.data_version.should eq(version + 1_u32)

    now = 120_u32
    cluster.refresh_predicted_activities
    cluster.predicted_activity.should eq([second])
    now = nil
    cluster.refresh_predicted_activities
    cluster.predicted_activity.should be_empty
    changed.should eq([Ambient::ATTR_PREDICTED_ACTIVITY] * 3)
  end

  it "rejects missing clocks, invalid crowd fields, and identity/count operations" do
    expect_raises(ArgumentError, /clock/) { build(Ambient, feature_map: feature_map) }
    now : UInt32? = 100_u32
    cluster = build(Ambient, feature_map: feature_map,
      prediction_clock: -> : UInt32? { now })
    expect_raises(ArgumentError, /not enabled/) do
      cluster.observe_object_count(Ambient::SemanticTag.identified_object(Ambient::IdentifiedObject::Person), 1_u16)
    end
    expect_raises(ArgumentError, /ObjectIdentification/) do
      build(Ambient, feature_map: feature_map, prediction_clock: -> : UInt32? { now },
        object_count_config: Ambient::ObjectCountConfig.new(
          Ambient::SemanticTag.identified_object(Ambient::IdentifiedObject::Person), 2_u16))
    end
    expect_raises(ArgumentError, /crowd count/) do
      Ambient::PredictedActivityStruct.crowd(120_u32, 180_u32, true, 80_u8, 0_u8)
    end
    expect_raises(ArgumentError, /crowd count/) do
      Ambient::PredictedActivityStruct.crowd(120_u32, 180_u32, true, 80_u8, 255_u8)
    end

    valid = Ambient::PredictedActivityStruct.crowd(120_u32, 180_u32, true, 80_u8, 12_u8)
    cluster.replace_predicted_activities([valid])
    version = cluster.data_version
    expect_raises(ArgumentError, /crowd prediction/) do
      cluster.replace_predicted_activities([
        Ambient::PredictedActivityStruct.new(130_u32, 140_u32,
          [Ambient::SemanticTag.identified_object(Ambient::IdentifiedObject::Person)], 50_u8),
      ])
    end
    expect_raises(ArgumentError, /ordered/) do
      cluster.replace_predicted_activities([valid,
                                            Ambient::PredictedActivityStruct.crowd(180_u32, 200_u32, false, 50_u8)])
    end
    cluster.data_version.should eq(version)
    cluster.predicted_activity.should eq([valid])

    now = nil
    expect_raises(ArgumentError, /unavailable/) do
      cluster.replace_predicted_activities([valid])
    end
    cluster.refresh_predicted_activities
    cluster.predicted_activity.should be_empty
  end
end

describe "Ambient Context Sensing AUD+PRED profile" do
  unknown = Ambient::SemanticTag.identified_sound(Ambient::IdentifiedSound::Unknown)
  barking = Ambient::SemanticTag.identified_sound(Ambient::IdentifiedSound::Barking)
  walking = Ambient::SemanticTag.human_activity(Ambient::HumanActivity::Walking)
  feature_map = Ambient::Feature::SoundIdentification | Ambient::Feature::PredictedActivity

  it "publishes sound forecasts atomically and prunes them on clock advance" do
    now : UInt32? = 100_u32
    cluster = build(Ambient, feature_map: feature_map,
      supported_sound_tags: [unknown, barking], prediction_clock: -> : UInt32? { now })
    read(cluster, Matter::Cluster::Base::GLOBAL_FEATURE_MAP).should eq(feature_map.value)
    attribute_ids(cluster).should contain(Ambient::ATTR_AUDIO_CONTEXT_DETECTED)
    attribute_ids(cluster).should contain(Ambient::ATTR_PREDICTED_ACTIVITY)
    cluster.ambient_context_type_supported.should eq([unknown, barking])
    read_tlv(cluster, Ambient::ATTR_PREDICTED_ACTIVITY).as_list.should be_empty
    cluster.get_event_metadata(Ambient::EVENT_AMBIENT_CONTEXT_DETECT_STARTED).should_not be_nil
    cluster.get_event_metadata(Ambient::EVENT_AMBIENT_CONTEXT_DETECT_ENDED).should_not be_nil

    first = Ambient::PredictedActivityStruct.new(120_u32, 180_u32, [barking], 80_u8)
    second = Ambient::PredictedActivityStruct.new(190_u32, 210_u32, [unknown], 60_u8)
    version = cluster.data_version
    cluster.replace_predicted_activities([first, second])
    cluster.data_version.should eq(version + 1_u32)
    wire = read_tlv(cluster, Ambient::ATTR_PREDICTED_ACTIVITY).as_list
    wire.size.should eq(2)
    wire[0].as_structure.keys.should eq([0_u8, 1_u8, 2_u8, 5_u8])
    decoded = Ambient::PredictedActivityStruct.from_tlv(wire[0])
    decoded.ambient_context_type.should eq([barking])
    decoded.confidence.should eq(80_u8)

    expect_raises(ArgumentError, /supported/) do
      cluster.replace_predicted_activities([
        Ambient::PredictedActivityStruct.new(130_u32, 140_u32, [walking], 50_u8),
      ])
    end
    expect_raises(ArgumentError, /one supported/) do
      cluster.replace_predicted_activities([
        Ambient::PredictedActivityStruct.new(130_u32, 140_u32, [barking, unknown], 50_u8),
      ])
    end
    expect_raises(ArgumentError, /ordered/) do
      cluster.replace_predicted_activities([first,
                                            Ambient::PredictedActivityStruct.new(180_u32, 220_u32, [barking], 50_u8)])
    end
    cluster.data_version.should eq(version + 1_u32)
    cluster.predicted_activity.should eq([first, second])

    now = 120_u32
    cluster.refresh_predicted_activities
    cluster.predicted_activity.should eq([second])
    now = nil
    cluster.refresh_predicted_activities
    cluster.predicted_activity.should be_empty
    expect_raises(ArgumentError, /unavailable/) { cluster.replace_predicted_activities([first]) }
    cluster.observe_sound(barking)
    cluster.audio_context_detected?.should be_true
  end

  it "requires a prediction clock" do
    expect_raises(ArgumentError, /clock/) do
      build(Ambient, feature_map: feature_map, supported_sound_tags: [unknown, barking])
    end
  end
end

describe "Ambient Context Sensing AUD profile" do
  unknown_sound = Ambient::SemanticTag.identified_sound(Ambient::IdentifiedSound::Unknown)
  barking = Ambient::SemanticTag.identified_sound(Ambient::IdentifiedSound::Barking)

  it "advertises the provisional sound profile and validates its supported tags" do
    cluster = build(Ambient, feature_map: Ambient::Feature::SoundIdentification,
      supported_sound_tags: [unknown_sound, barking])
    read(cluster, Matter::Cluster::Base::GLOBAL_FEATURE_MAP).should eq(8_u32)
    attribute_ids(cluster).should contain(Ambient::ATTR_AUDIO_CONTEXT_DETECTED)
    attribute_ids(cluster).should contain(Ambient::ATTR_AMBIENT_CONTEXT_TYPE)
    attribute_ids(cluster).should contain(Ambient::ATTR_AMBIENT_CONTEXT_TYPE_SUPPORTED)
    attribute_ids(cluster).should_not contain(Ambient::ATTR_HUMAN_ACTIVITY_DETECTED)
    attribute_ids(cluster).should_not contain(Ambient::ATTR_OBJECT_IDENTIFIED)
    read(cluster, Ambient::ATTR_AUDIO_CONTEXT_DETECTED).should be_false
    Ambient::AmbientContextTypeStruct.from_tlv(
      read_tlv(cluster, Ambient::ATTR_AMBIENT_CONTEXT_TYPE).as_list[0]).ambient_context_sensed.should eq([unknown_sound])
    Ambient::SemanticTag.from_tlv(
      read_tlv(cluster, Ambient::ATTR_AMBIENT_CONTEXT_TYPE_SUPPORTED).as_list[1]).should eq(barking)
    cluster.get_event_metadata(Ambient::EVENT_AMBIENT_CONTEXT_DETECT_STARTED).should_not be_nil
    cluster.get_event_metadata(Ambient::EVENT_AMBIENT_CONTEXT_DETECT_ENDED).should_not be_nil

    expect_raises(ArgumentError) do
      build(Ambient, feature_map: Ambient::Feature::SoundIdentification,
        supported_sound_tags: [barking])
    end
    expect_raises(ArgumentError) do
      build(Ambient, feature_map: Ambient::Feature::SoundIdentification,
        supported_sound_tags: [unknown_sound, unknown_sound])
    end
    expect_raises(ArgumentError) do
      build(Ambient, feature_map: Ambient::Feature::SoundIdentification,
        supported_sound_tags: [unknown_sound, Ambient::SemanticTag.human_activity(Ambient::HumanActivity::Walking)])
    end
  end

  it "emits sound start and end events and expires after HoldTime" do
    cluster = build(Ambient, feature_map: Ambient::Feature::SoundIdentification,
      supported_sound_tags: [unknown_sound, barking], hold_time: 1_u16)
    events = [] of Tuple(UInt32, TLV::Any)
    cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, id : UInt32, _priority : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) do
      events << {id, data}
      nil
    end

    expect_raises(ArgumentError) { cluster.observe_sound(unknown_sound) }
    cluster.observe_sound(barking)
    read(cluster, Ambient::ATTR_AUDIO_CONTEXT_DETECTED).should be_true
    cluster.observe_sound(barking)
    events.size.should eq(1)
    events[0][0].should eq(Ambient::EVENT_AMBIENT_CONTEXT_DETECT_STARTED)
    Ambient::AmbientContextDetectStartedEvent.from_tlv(events[0][1])
      .ambient_context_detected.ambient_context_sensed.should eq([barking])

    deadline = Time.instant + 3.seconds
    while cluster.audio_context_detected? && Time.instant < deadline
      sleep 20.milliseconds
    end
    cluster.audio_context_detected?.should be_false
    read(cluster, Ambient::ATTR_AUDIO_CONTEXT_DETECTED).should be_false
    events.size.should eq(2)
    events[1][0].should eq(Ambient::EVENT_AMBIENT_CONTEXT_DETECT_ENDED)
    Ambient::AmbientContextDetectEndedEvent.from_tlv(events[1][1]).event_start_time.should be > 0_u64
    Ambient::AmbientContextTypeStruct.from_tlv(
      read_tlv(cluster, Ambient::ATTR_AMBIENT_CONTEXT_TYPE).as_list[0]).ambient_context_sensed.should eq([unknown_sound])
  end
end

describe "Ambient Context Sensing OI-only profile" do
  unknown = Ambient::SemanticTag.identified_object(Ambient::IdentifiedObject::Unknown)
  person = Ambient::SemanticTag.identified_object(Ambient::IdentifiedObject::Person)

  it "advertises object identification without object counting" do
    cluster = build(Ambient, feature_map: Ambient::Feature::ObjectIdentification,
      supported_object_tags: [unknown, person], hold_time: 1_u16)

    read(cluster, Matter::Cluster::Base::GLOBAL_FEATURE_MAP).should eq(Ambient::Feature::ObjectIdentification.value)
    [Ambient::ATTR_OBJECT_IDENTIFIED, Ambient::ATTR_AMBIENT_CONTEXT_TYPE,
     Ambient::ATTR_AMBIENT_CONTEXT_TYPE_SUPPORTED, Ambient::ATTR_SIMULTANEOUS_DETECTION_LIMIT,
     Ambient::ATTR_HOLD_TIME, Ambient::ATTR_HOLD_TIME_LIMITS].each do |id|
      attribute_ids(cluster).should contain(id)
    end
    [Ambient::ATTR_HUMAN_ACTIVITY_DETECTED, Ambient::ATTR_AUDIO_CONTEXT_DETECTED,
     Ambient::ATTR_OBJECT_COUNT_REACHED, Ambient::ATTR_OBJECT_COUNT_CONFIG,
     Ambient::ATTR_OBJECT_COUNT, Ambient::ATTR_PREDICTED_ACTIVITY].each do |id|
      attribute_ids(cluster).should_not contain(id)
    end
    cluster.get_event_metadata(Ambient::EVENT_AMBIENT_CONTEXT_DETECT_STARTED).should_not be_nil
    cluster.get_event_metadata(Ambient::EVENT_AMBIENT_CONTEXT_DETECT_ENDED).should_not be_nil
    read(cluster, Ambient::ATTR_OBJECT_IDENTIFIED).should be_false
    Ambient::AmbientContextTypeStruct.from_tlv(
      read_tlv(cluster, Ambient::ATTR_AMBIENT_CONTEXT_TYPE).as_list.first).ambient_context_sensed.should eq([unknown])
    read_tlv(cluster, Ambient::ATTR_AMBIENT_CONTEXT_TYPE_SUPPORTED).as_list.size.should eq(2)
  end

  it "detects and clears a present object without count fields" do
    cluster = build(Ambient, feature_map: Ambient::Feature::ObjectIdentification,
      supported_object_tags: [unknown, person], hold_time: 1_u16)
    events = [] of Tuple(UInt32, TLV::Any)
    cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, id : UInt32, _priority : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) do
      events << {id, data}
      nil
    end

    cluster.observe_object(person, true)
    read(cluster, Ambient::ATTR_OBJECT_IDENTIFIED).should be_true
    Ambient::AmbientContextTypeStruct.from_tlv(
      read_tlv(cluster, Ambient::ATTR_AMBIENT_CONTEXT_TYPE).as_list.first).ambient_context_sensed.should eq([person])
    events.map(&.[0]).should eq([Ambient::EVENT_AMBIENT_CONTEXT_DETECT_STARTED])
    started = Ambient::AmbientContextDetectStartedEvent.from_tlv(events.first[1])
    started.ambient_context_detected.ambient_context_sensed.should eq([person])
    started.object_count_reached.should be_nil
    started.object_count.should be_nil
    events.first[1].as_structure.has_key?(1_u8).should be_false
    events.first[1].as_structure.has_key?(2_u8).should be_false

    cluster.observe_object(person, true)
    events.size.should eq(1)
    cluster.observe_object(person, false)
    read(cluster, Ambient::ATTR_OBJECT_IDENTIFIED).should be_false
    Ambient::AmbientContextTypeStruct.from_tlv(
      read_tlv(cluster, Ambient::ATTR_AMBIENT_CONTEXT_TYPE).as_list.first).ambient_context_sensed.should eq([unknown])
    events.map(&.[0]).should eq([Ambient::EVENT_AMBIENT_CONTEXT_DETECT_STARTED,
                                 Ambient::EVENT_AMBIENT_CONTEXT_DETECT_ENDED])
    Ambient::AmbientContextDetectEndedEvent.from_tlv(events.last[1]).event_start_time.should be > 0_u64
  end

  it "expires, persists HoldTime, and rejects count observations and unsupported tags" do
    cluster = build(Ambient, feature_map: Ambient::Feature::ObjectIdentification,
      supported_object_tags: [unknown, person], hold_time: 1_u16)
    expect_raises(ArgumentError) { cluster.observe_object(unknown, true) }
    expect_raises(ArgumentError) { cluster.observe_object_count(person, 1_u16) }
    expect_raises(ArgumentError, /ObjectCountConfig/) do
      build(Ambient, feature_map: Ambient::Feature::ObjectIdentification,
        supported_object_tags: [unknown, person],
        object_count_config: Ambient::ObjectCountConfig.new(person, 2_u16))
    end
    cluster.observe_object(person, true)
    deadline = Time.instant + 3.seconds
    while cluster.object_identified? && Time.instant < deadline
      sleep 20.milliseconds
    end
    cluster.object_identified?.should be_false
    write(cluster, Ambient::ATTR_HOLD_TIME, 3_u16).status.should eq(Matter::InteractionModel::StatusCode::Success)
    document = cluster.save_state.as(Matter::Storage::Document)
    document.keys.should contain("hold_time")
    document.keys.should_not contain("object_identified")
    restored = build(Ambient, feature_map: Ambient::Feature::ObjectIdentification,
      supported_object_tags: [unknown, person])
    restored.restore_state(document)
    restored.hold_time.should eq(3_u16)
    restored.object_identified?.should be_false
  end
end

describe "Ambient Context Sensing HA+OI profile" do
  unknown_activity = Ambient::SemanticTag.human_activity(Ambient::HumanActivity::Unknown)
  walking = Ambient::SemanticTag.human_activity(Ambient::HumanActivity::Walking)
  unknown_object = Ambient::SemanticTag.identified_object(Ambient::IdentifiedObject::Unknown)
  person = Ambient::SemanticTag.identified_object(Ambient::IdentifiedObject::Person)
  feature_map = Ambient::Feature::HumanActivity | Ambient::Feature::ObjectIdentification

  it "advertises both independent detection attributes and the union of supported tags" do
    cluster = build(Ambient, feature_map: feature_map,
      supported_activity_tags: [unknown_activity, walking],
      supported_object_tags: [unknown_object, person])
    read(cluster, Matter::Cluster::Base::GLOBAL_FEATURE_MAP).should eq(feature_map.value)
    [Ambient::ATTR_HUMAN_ACTIVITY_DETECTED, Ambient::ATTR_OBJECT_IDENTIFIED,
     Ambient::ATTR_AMBIENT_CONTEXT_TYPE, Ambient::ATTR_AMBIENT_CONTEXT_TYPE_SUPPORTED,
     Ambient::ATTR_SIMULTANEOUS_DETECTION_LIMIT, Ambient::ATTR_HOLD_TIME,
     Ambient::ATTR_HOLD_TIME_LIMITS].each { |id| attribute_ids(cluster).should contain(id) }
    [Ambient::ATTR_AUDIO_CONTEXT_DETECTED, Ambient::ATTR_OBJECT_COUNT_REACHED,
     Ambient::ATTR_OBJECT_COUNT_CONFIG, Ambient::ATTR_OBJECT_COUNT,
     Ambient::ATTR_PREDICTED_ACTIVITY].each { |id| attribute_ids(cluster).should_not contain(id) }
    cluster.get_event_metadata(Ambient::EVENT_AMBIENT_CONTEXT_DETECT_STARTED).should_not be_nil
    cluster.get_event_metadata(Ambient::EVENT_AMBIENT_CONTEXT_DETECT_ENDED).should_not be_nil
    read(cluster, Ambient::ATTR_HUMAN_ACTIVITY_DETECTED).should be_false
    read(cluster, Ambient::ATTR_OBJECT_IDENTIFIED).should be_false
    Ambient::SemanticTag.from_tlv(read_tlv(cluster, Ambient::ATTR_AMBIENT_CONTEXT_TYPE_SUPPORTED).as_list[0]).should eq(unknown_activity)
    cluster.ambient_context_type_supported.should eq([unknown_activity, walking, unknown_object, person])
  end

  it "ends the active modality before switching and expires the second modality" do
    cluster = build(Ambient, feature_map: feature_map,
      supported_activity_tags: [unknown_activity, walking],
      supported_object_tags: [unknown_object, person], hold_time: 1_u16)
    events = [] of Tuple(UInt32, TLV::Any)
    cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, id : UInt32, _priority : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) do
      events << {id, data}
      nil
    end
    cluster.observe_human_activity(walking)
    read(cluster, Ambient::ATTR_HUMAN_ACTIVITY_DETECTED).should be_true
    read(cluster, Ambient::ATTR_OBJECT_IDENTIFIED).should be_false
    cluster.observe_object(person, true)
    read(cluster, Ambient::ATTR_HUMAN_ACTIVITY_DETECTED).should be_false
    read(cluster, Ambient::ATTR_OBJECT_IDENTIFIED).should be_true
    cluster.ambient_context_type.first.ambient_context_sensed.should eq([person])
    events.map(&.[0]).should eq([
      Ambient::EVENT_AMBIENT_CONTEXT_DETECT_STARTED,
      Ambient::EVENT_AMBIENT_CONTEXT_DETECT_ENDED,
      Ambient::EVENT_AMBIENT_CONTEXT_DETECT_STARTED,
    ])
    started = Ambient::AmbientContextDetectStartedEvent.from_tlv(events.last[1])
    started.ambient_context_detected.ambient_context_sensed.should eq([person])
    events.last[1].as_structure.has_key?(1_u8).should be_false
    events.last[1].as_structure.has_key?(2_u8).should be_false
    deadline = Time.instant + 3.seconds
    while cluster.object_identified? && Time.instant < deadline
      sleep 20.milliseconds
    end
    read(cluster, Ambient::ATTR_OBJECT_IDENTIFIED).should be_false
    cluster.ambient_context_type.first.ambient_context_sensed.should eq([unknown_object])
    events.last[0].should eq(Ambient::EVENT_AMBIENT_CONTEXT_DETECT_ENDED)

    cluster.observe_object(person, true)
    cluster.observe_human_activity(walking)
    read(cluster, Ambient::ATTR_OBJECT_IDENTIFIED).should be_false
    read(cluster, Ambient::ATTR_HUMAN_ACTIVITY_DETECTED).should be_true
    cluster.ambient_context_type.first.ambient_context_sensed.should eq([walking])
    events.last[0].should eq(Ambient::EVENT_AMBIENT_CONTEXT_DETECT_STARTED)
    Ambient::AmbientContextDetectStartedEvent.from_tlv(events.last[1])
      .ambient_context_detected.ambient_context_sensed.should eq([walking])
    cluster.observe_object(person, false)
    read(cluster, Ambient::ATTR_HUMAN_ACTIVITY_DETECTED).should be_true
  end
end

describe "Ambient Context Sensing HA+AUD profile" do
  unknown_activity = Ambient::SemanticTag.human_activity(Ambient::HumanActivity::Unknown)
  walking = Ambient::SemanticTag.human_activity(Ambient::HumanActivity::Walking)
  unknown_sound = Ambient::SemanticTag.identified_sound(Ambient::IdentifiedSound::Unknown)
  barking = Ambient::SemanticTag.identified_sound(Ambient::IdentifiedSound::Barking)
  feature_map = Ambient::Feature::HumanActivity | Ambient::Feature::SoundIdentification

  it "advertises independent human and sound detection with their supported tag union" do
    cluster = build(Ambient, feature_map: feature_map,
      supported_activity_tags: [unknown_activity, walking],
      supported_sound_tags: [unknown_sound, barking])
    read(cluster, Matter::Cluster::Base::GLOBAL_FEATURE_MAP).should eq(feature_map.value)
    [Ambient::ATTR_HUMAN_ACTIVITY_DETECTED, Ambient::ATTR_AUDIO_CONTEXT_DETECTED,
     Ambient::ATTR_AMBIENT_CONTEXT_TYPE, Ambient::ATTR_AMBIENT_CONTEXT_TYPE_SUPPORTED,
     Ambient::ATTR_SIMULTANEOUS_DETECTION_LIMIT, Ambient::ATTR_HOLD_TIME,
     Ambient::ATTR_HOLD_TIME_LIMITS].each { |id| attribute_ids(cluster).should contain(id) }
    [Ambient::ATTR_OBJECT_IDENTIFIED, Ambient::ATTR_OBJECT_COUNT_REACHED,
     Ambient::ATTR_OBJECT_COUNT_CONFIG, Ambient::ATTR_OBJECT_COUNT,
     Ambient::ATTR_PREDICTED_ACTIVITY].each { |id| attribute_ids(cluster).should_not contain(id) }
    cluster.ambient_context_type_supported.should eq([unknown_activity, walking, unknown_sound, barking])
    read(cluster, Ambient::ATTR_HUMAN_ACTIVITY_DETECTED).should be_false
    read(cluster, Ambient::ATTR_AUDIO_CONTEXT_DETECTED).should be_false
    cluster.get_event_metadata(Ambient::EVENT_AMBIENT_CONTEXT_DETECT_STARTED).should_not be_nil
    cluster.get_event_metadata(Ambient::EVENT_AMBIENT_CONTEXT_DETECT_ENDED).should_not be_nil
    expect_raises(ArgumentError, /sound tags/) do
      build(Ambient, feature_map: feature_map,
        supported_activity_tags: [unknown_activity, walking],
        supported_sound_tags: [unknown_sound])
    end
  end

  it "ends one modality before starting the other and expires the active sound" do
    cluster = build(Ambient, feature_map: feature_map,
      supported_activity_tags: [unknown_activity, walking],
      supported_sound_tags: [unknown_sound, barking], hold_time: 1_u16)
    events = [] of Tuple(UInt32, TLV::Any)
    cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, id : UInt32, _priority : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) do
      events << {id, data}
      nil
    end
    cluster.observe_human_activity(walking)
    cluster.human_activity_detected?.should be_true
    cluster.audio_context_detected?.should be_false
    cluster.observe_sound(barking)
    cluster.human_activity_detected?.should be_false
    cluster.audio_context_detected?.should be_true
    cluster.ambient_context_type.first.ambient_context_sensed.should eq([barking])
    events.map(&.[0]).should eq([
      Ambient::EVENT_AMBIENT_CONTEXT_DETECT_STARTED,
      Ambient::EVENT_AMBIENT_CONTEXT_DETECT_ENDED,
      Ambient::EVENT_AMBIENT_CONTEXT_DETECT_STARTED,
    ])
    events.last[1].as_structure.keys.should eq([0_u8])
    Ambient::AmbientContextDetectStartedEvent.from_tlv(events.last[1])
      .ambient_context_detected.ambient_context_sensed.should eq([barking])
    deadline = Time.instant + 3.seconds
    while cluster.audio_context_detected? && Time.instant < deadline
      sleep 20.milliseconds
    end
    cluster.audio_context_detected?.should be_false
    cluster.ambient_context_type.first.ambient_context_sensed.should eq([unknown_sound])
    events.last[0].should eq(Ambient::EVENT_AMBIENT_CONTEXT_DETECT_ENDED)

    cluster.observe_sound(barking)
    cluster.observe_human_activity(walking)
    cluster.audio_context_detected?.should be_false
    cluster.human_activity_detected?.should be_true
    cluster.ambient_context_type.first.ambient_context_sensed.should eq([walking])
    events.last[0].should eq(Ambient::EVENT_AMBIENT_CONTEXT_DETECT_STARTED)
    Ambient::AmbientContextDetectStartedEvent.from_tlv(events.last[1])
      .ambient_context_detected.ambient_context_sensed.should eq([walking])
  end
end

describe "Ambient Context Sensing HA+OI+PRED profile" do
  unknown_activity = Ambient::SemanticTag.human_activity(Ambient::HumanActivity::Unknown)
  walking = Ambient::SemanticTag.human_activity(Ambient::HumanActivity::Walking)
  unknown_object = Ambient::SemanticTag.identified_object(Ambient::IdentifiedObject::Unknown)
  person = Ambient::SemanticTag.identified_object(Ambient::IdentifiedObject::Person)
  feature_map = Ambient::Feature::HumanActivity | Ambient::Feature::ObjectIdentification |
                Ambient::Feature::PredictedActivity

  it "advertises both detection flags and clock-pruned tagged forecasts without count fields" do
    now : UInt32? = 100_u32
    cluster = build(Ambient, feature_map: feature_map,
      supported_activity_tags: [unknown_activity, walking],
      supported_object_tags: [unknown_object, person],
      prediction_clock: -> : UInt32? { now })
    read(cluster, Matter::Cluster::Base::GLOBAL_FEATURE_MAP).should eq(feature_map.value)
    [Ambient::ATTR_HUMAN_ACTIVITY_DETECTED, Ambient::ATTR_OBJECT_IDENTIFIED,
     Ambient::ATTR_AMBIENT_CONTEXT_TYPE, Ambient::ATTR_AMBIENT_CONTEXT_TYPE_SUPPORTED,
     Ambient::ATTR_SIMULTANEOUS_DETECTION_LIMIT, Ambient::ATTR_HOLD_TIME,
     Ambient::ATTR_HOLD_TIME_LIMITS, Ambient::ATTR_PREDICTED_ACTIVITY].each do |id|
      attribute_ids(cluster).should contain(id)
    end
    [Ambient::ATTR_AUDIO_CONTEXT_DETECTED, Ambient::ATTR_OBJECT_COUNT_REACHED,
     Ambient::ATTR_OBJECT_COUNT_CONFIG, Ambient::ATTR_OBJECT_COUNT].each do |id|
      attribute_ids(cluster).should_not contain(id)
    end
    cluster.ambient_context_type_supported.should eq([unknown_activity, walking, unknown_object, person])
    cluster.get_event_metadata(Ambient::EVENT_AMBIENT_CONTEXT_DETECT_STARTED).should_not be_nil
    cluster.get_event_metadata(Ambient::EVENT_AMBIENT_CONTEXT_DETECT_ENDED).should_not be_nil

    activity = Ambient::PredictedActivityStruct.new(120_u32, 180_u32, [walking], 80_u8)
    object = Ambient::PredictedActivityStruct.new(190_u32, 250_u32, [person], 60_u8)
    cluster.replace_predicted_activities([activity, object])
    wire = read_tlv(cluster, Ambient::ATTR_PREDICTED_ACTIVITY).as_list
    wire.size.should eq(2)
    wire.each { |item| item.as_structure.keys.should eq([0_u8, 1_u8, 2_u8, 5_u8]) }
    Ambient::PredictedActivityStruct.from_tlv(wire[0]).ambient_context_type.should eq([walking])
    Ambient::PredictedActivityStruct.from_tlv(wire[1]).ambient_context_type.should eq([person])

    now = 120_u32
    cluster.refresh_predicted_activities
    cluster.predicted_activity.should eq([object])
    now = nil
    cluster.refresh_predicted_activities
    cluster.predicted_activity.should be_empty
  end

  it "rejects unsupported and crowd forecasts atomically while live detection switches modality" do
    cluster = build(Ambient, feature_map: feature_map,
      supported_activity_tags: [unknown_activity, walking],
      supported_object_tags: [unknown_object, person],
      prediction_clock: -> : UInt32? { 100_u32 })
    activity = Ambient::PredictedActivityStruct.new(120_u32, 180_u32, [walking], 80_u8)
    cluster.replace_predicted_activities([activity])
    expect_raises(ArgumentError, /supported ambient context tag/) do
      cluster.replace_predicted_activities([
        Ambient::PredictedActivityStruct.new(190_u32, 250_u32,
          [Ambient::SemanticTag.identified_sound(Ambient::IdentifiedSound::Barking)], 50_u8),
      ])
    end
    expect_raises(ArgumentError, /crowd fields/) do
      cluster.replace_predicted_activities([
        Ambient::PredictedActivityStruct.new(190_u32, 250_u32, [person], 50_u8, true),
      ])
    end
    cluster.predicted_activity.should eq([activity])
    cluster.observe_human_activity(walking)
    cluster.human_activity_detected?.should be_true
    cluster.observe_object(person, true)
    cluster.human_activity_detected?.should be_false
    cluster.object_identified?.should be_true
    cluster.predicted_activity.should eq([activity])
  end
end

describe "Ambient Context Sensing OC+OI profile" do
  unknown_object = Ambient::SemanticTag.identified_object(Ambient::IdentifiedObject::Unknown)
  person = Ambient::SemanticTag.identified_object(Ambient::IdentifiedObject::Person)
  dog = Ambient::SemanticTag.identified_object(Ambient::IdentifiedObject::Dog)
  feature_map = Ambient::Feature::ObjectCounting | Ambient::Feature::ObjectIdentification

  it "advertises the complete conditional count surface and validates Manage writes" do
    config = Ambient::ObjectCountConfig.new(person, 2_u16)
    cluster = build(Ambient, feature_map: feature_map,
      supported_object_tags: [unknown_object, person, dog], object_count_config: config)

    read(cluster, Matter::Cluster::Base::GLOBAL_FEATURE_MAP).should eq(6_u32)
    [Ambient::ATTR_OBJECT_IDENTIFIED, Ambient::ATTR_AMBIENT_CONTEXT_TYPE,
     Ambient::ATTR_AMBIENT_CONTEXT_TYPE_SUPPORTED, Ambient::ATTR_OBJECT_COUNT_REACHED,
     Ambient::ATTR_OBJECT_COUNT_CONFIG, Ambient::ATTR_OBJECT_COUNT].each do |id|
      attribute_ids(cluster).should contain(id)
    end
    attribute_ids(cluster).should_not contain(Ambient::ATTR_HUMAN_ACTIVITY_DETECTED)
    config_metadata = cluster.get_attribute_metadata(Ambient::ATTR_OBJECT_COUNT_CONFIG).as(Matter::Cluster::AttributeMetadata)
    config_metadata.write_access.should eq(Matter::InteractionModel::EntryPrivilege::Manage)
    read(cluster, Ambient::ATTR_OBJECT_COUNT_REACHED).should be_false
    read(cluster, Ambient::ATTR_OBJECT_IDENTIFIED).should be_false
    read(cluster, Ambient::ATTR_OBJECT_COUNT).should be_nil

    write(cluster, Ambient::ATTR_OBJECT_COUNT_CONFIG, Ambient::ObjectCountConfig.new(dog, 3_u16)).status
      .should eq(Matter::InteractionModel::StatusCode::Success)
    expect_raises(ArgumentError) { Ambient::ObjectCountConfig.new(person, 0_u16) }
    zero_threshold = TLV::Any.new({
      0_u8 => person.to_tlv(0_u8),
      1_u8 => TLV::Any.new(0_u16, 1_u8),
    } of TLV::TagId => TLV::Any)
    write(cluster, Ambient::ATTR_OBJECT_COUNT_CONFIG, zero_threshold).status
      .should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    source = cluster.save_state.as(Matter::Storage::Document)
    source.keys.should contain("object_count_config")
    restored = build(Ambient, feature_map: feature_map,
      supported_object_tags: [unknown_object, person, dog], object_count_config: config)
    restored.restore_state(source)
    restored.object_count_config.counting_object.should eq(dog)
    restored.object_count_config.object_count_threshold.should eq(3_u16)

    config_document = source["object_count_config"].as(Matter::Storage::Document)
    config_document["object_count_threshold"] = 0_i64
    restored.restore_state(source)
    restored.object_count_config.counting_object.should eq(person)
    restored.object_count_config.object_count_threshold.should eq(1_u16)
  end

  it "reports object detection and threshold transitions with conditional event fields" do
    cluster = build(Ambient, feature_map: feature_map,
      supported_object_tags: [unknown_object, person, dog],
      object_count_config: Ambient::ObjectCountConfig.new(person, 2_u16), hold_time: 1_u16)
    events = [] of Tuple(UInt32, TLV::Any)
    cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, id : UInt32, _priority : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) do
      events << {id, data}
      nil
    end

    cluster.observe_object_count(person, 1_u16)
    read(cluster, Ambient::ATTR_OBJECT_IDENTIFIED).should be_true
    read(cluster, Ambient::ATTR_OBJECT_COUNT_REACHED).should be_false
    attribute_ids(cluster).should contain(Ambient::ATTR_OBJECT_COUNT)
    read(cluster, Ambient::ATTR_OBJECT_COUNT).should be_nil
    start = Ambient::AmbientContextDetectStartedEvent.from_tlv(events[0][1])
    start.ambient_context_detected.ambient_context_sensed.should eq([person])
    start.object_count_reached.should be_false
    start.object_count.should be_nil

    cluster.observe_object_count(person, 2_u16)
    read(cluster, Ambient::ATTR_OBJECT_COUNT_REACHED).should be_true
    read(cluster, Ambient::ATTR_OBJECT_COUNT).should eq(2_u16)
    events.size.should eq(1)
    cluster.observe_object_count(person, 3_u16)
    read(cluster, Ambient::ATTR_OBJECT_COUNT).should eq(3_u16)
    cluster.object_count_config = Ambient::ObjectCountConfig.new(person, 4_u16)
    read(cluster, Ambient::ATTR_OBJECT_COUNT_REACHED).should be_false
    attribute_ids(cluster).should contain(Ambient::ATTR_OBJECT_COUNT)
    read(cluster, Ambient::ATTR_OBJECT_COUNT).should be_nil
    cluster.object_count_config = Ambient::ObjectCountConfig.new(person, 2_u16)
    read(cluster, Ambient::ATTR_OBJECT_COUNT_REACHED).should be_true
    read(cluster, Ambient::ATTR_OBJECT_COUNT).should eq(3_u16)
    cluster.observe_object_count(person, 0_u16)
    read(cluster, Ambient::ATTR_OBJECT_IDENTIFIED).should be_false
    read(cluster, Ambient::ATTR_OBJECT_COUNT_REACHED).should be_false
    attribute_ids(cluster).should contain(Ambient::ATTR_OBJECT_COUNT)
    read(cluster, Ambient::ATTR_OBJECT_COUNT).should be_nil
    events.map(&.[0]).should eq([Ambient::EVENT_AMBIENT_CONTEXT_DETECT_STARTED,
                                 Ambient::EVENT_AMBIENT_CONTEXT_DETECT_ENDED])

    cluster.observe_object_count(person, 4_u16)
    start = Ambient::AmbientContextDetectStartedEvent.from_tlv(events[-1][1])
    start.object_count_reached.should be_true
    start.object_count.should eq(4_u16)
    deadline = Time.instant + 3.seconds
    while cluster.object_identified? && Time.instant < deadline
      sleep 20.milliseconds
    end
    cluster.object_identified?.should be_false
    events[-1][0].should eq(Ambient::EVENT_AMBIENT_CONTEXT_DETECT_ENDED)
  end

  it "rejects unsupported object tags and incomplete feature combinations" do
    reversed = build(Ambient, feature_map: feature_map,
      supported_object_tags: [person, unknown_object])
    reversed.object_count_config.counting_object.should eq(person)
    reversed.object_count_config.object_count_threshold.should eq(1_u16)
    expect_raises(ArgumentError) { build(Ambient, feature_map: Ambient::Feature::ObjectIdentification) }
    expect_raises(ArgumentError) do
      build(Ambient, feature_map: Ambient::Feature::HumanActivity | feature_map)
    end
    expect_raises(ArgumentError) do
      build(Ambient, feature_map: feature_map, supported_object_tags: [person, dog])
    end
    cluster = build(Ambient, feature_map: feature_map,
      supported_object_tags: [unknown_object, person],
      object_count_config: Ambient::ObjectCountConfig.new(person, 2_u16))
    expect_raises(ArgumentError) { cluster.observe_object_count(dog, 1_u16) }
    expect_raises(ArgumentError) do
      cluster.object_count_config = Ambient::ObjectCountConfig.new(dog, 2_u16)
    end
    expect_raises(ArgumentError) { cluster.feature_map = Ambient::Feature::HumanActivity }
  end
end
