require "../spec_helper"

private alias Zone = Matter::Cluster::ZoneManagement
private alias IMCode = Matter::InteractionModel::StatusCode

private def motion_zone(name = "Door")
  Zone::TwoDCartesianZone.new(name, Zone::ZoneUse::Motion,
    [Zone::Vertex.new(0_u16, 0_u16), Zone::Vertex.new(100_u16, 0_u16),
     Zone::Vertex.new(100_u16, 100_u16), Zone::Vertex.new(0_u16, 100_u16)], "#00FFFF")
end

private def zone_fixture
  build(Zone, automatic_timeouts: false)
end

private def create_zone(cluster : Zone, zone = motion_zone) : UInt16
  result = invoke(cluster, Zone::CMD_CREATE_TWO_D_CARTESIAN_ZONE,
    Zone::CreateZoneRequest.new(zone)).as(Matter::Cluster::CommandResponse)
  result.command_id.should eq(Zone::CMD_CREATE_TWO_D_CARTESIAN_ZONE_RESPONSE)
  Zone::CreateZoneResponse.from_tlv(result.response.as(TLV::Any)).zone_id
end

describe Zone do
  it "accepts only conformant feature combinations" do
    expect_raises(ArgumentError) { build(Zone, feature_map: Zone::Feature::PerZoneSensitivity) }
    expect_raises(ArgumentError) { build(Zone, feature_map: Zone::Feature::FocusZones | Zone::Feature::TwoDCartesianZone) }
    build(Zone, feature_map: Zone::Feature::TwoDCartesianZone | Zone::Feature::UserDefined |
                             Zone::Feature::PerZoneSensitivity).feature_map.value.should eq(7_u32)
    build(Zone, feature_map: Zone::Feature::TwoDCartesianZone | Zone::Feature::UserDefined |
                             Zone::Feature::FocusZones).feature_map.value.should eq(13_u32)
    build(Zone, feature_map: Zone::Feature::TwoDCartesianZone | Zone::Feature::UserDefined |
                             Zone::Feature::PerZoneSensitivity | Zone::Feature::FocusZones).feature_map.value.should eq(15_u32)
    cluster = zone_fixture
    cluster.feature_map = cluster.feature_map
    expect_raises(ArgumentError) do
      cluster.feature_map = Zone::Feature::TwoDCartesianZone |
                            Zone::Feature::UserDefined | Zone::Feature::PerZoneSensitivity
    end
    cluster.feature_map.value.should eq(5_u32)
  end

  it "requires bounded trigger sensitivity and removes the global attribute in PERZONESENS" do
    features = Zone::Feature::TwoDCartesianZone | Zone::Feature::UserDefined |
               Zone::Feature::PerZoneSensitivity
    cluster = build(Zone, feature_map: features, automatic_timeouts: false)
    attribute_ids(cluster).should_not contain(Zone::ATTR_SENSITIVITY)
    read_status(cluster, Zone::ATTR_SENSITIVITY).status.should eq(IMCode::UnsupportedAttribute)
    expect_status(write(cluster, Zone::ATTR_SENSITIVITY, 3_u8), IMCode::UnsupportedAttribute)
    id = create_zone(cluster)
    [nil, 0_u8, 6_u8].each do |sensitivity|
      trigger = Zone::Trigger.new(id, 2_u32, 1_u32, 4_u32, 1_u32, sensitivity)
      expect_status(invoke(cluster, Zone::CMD_CREATE_OR_UPDATE_TRIGGER,
        Zone::TriggerRequest.new(trigger)), IMCode::ConstraintError)
    end
    trigger = Zone::Trigger.new(id, 2_u32, 1_u32, 4_u32, 1_u32, 5_u8)
    expect_success(invoke(cluster, Zone::CMD_CREATE_OR_UPDATE_TRIGGER, Zone::TriggerRequest.new(trigger)))
    Zone::Trigger.from_tlv(read_tlv(cluster, Zone::ATTR_TRIGGERS).as_list.first).sensitivity.should eq(5_u8)
    restored = build(Zone, feature_map: features, automatic_timeouts: false)
    restored.restore_state(cluster.save_state)
    restored.triggers.first.sensitivity.should eq(5_u8)
    expect_raises(ArgumentError) do
      restored.triggers = [Zone::Trigger.new(id, 2_u32, 1_u32, 4_u32, 1_u32)]
    end
    restored.triggers.first.sensitivity.should eq(5_u8)
  end

  it "accepts focus zones only with FOCUSZONES and a host handler, then restores them" do
    focus = Zone::TwoDCartesianZone.new("Focus", Zone::ZoneUse::Focus, motion_zone.vertices)
    default = zone_fixture
    default.on_zone_change { |_old, _new| Matter::InteractionModel::Status.success }
    expect_status(invoke(default, Zone::CMD_CREATE_TWO_D_CARTESIAN_ZONE,
      Zone::CreateZoneRequest.new(focus)), IMCode::ConstraintError)
    cluster = build(Zone, feature_map: Zone::Feature::TwoDCartesianZone |
                                       Zone::Feature::UserDefined | Zone::Feature::FocusZones, automatic_timeouts: false)
    expect_status(invoke(cluster, Zone::CMD_CREATE_TWO_D_CARTESIAN_ZONE,
      Zone::CreateZoneRequest.new(focus)), IMCode::InvalidInState)
    changes = [] of {Zone::ZoneInformation?, Zone::ZoneInformation?}
    cluster.on_zone_change do |previous, current|
      changes << {previous, current}
      Matter::InteractionModel::Status.success
    end
    id = create_zone(cluster, focus)
    changes.last[1].as(Zone::ZoneInformation).two_d_cartesian_zone.use.should eq(Zone::ZoneUse::Focus)
    expect_status(invoke(cluster, Zone::CMD_CREATE_OR_UPDATE_TRIGGER, Zone::TriggerRequest.new(
      Zone::Trigger.new(id, 2_u32, 1_u32, 4_u32, 1_u32))), IMCode::ConstraintError)
    restored = build(Zone, feature_map: cluster.feature_map, automatic_timeouts: false)
    restored.restore_state(cluster.save_state)
    restored.zones.first.two_d_cartesian_zone.use.should eq(Zone::ZoneUse::Focus)
    restored.on_zone_change { |previous, current| changes << {previous, current}; Matter::InteractionModel::Status.success }
    restored.replay_zones_to_host!
    changes.last[0].should be_nil
    changes.last[1].as(Zone::ZoneInformation).zone_id.should eq(id)
    expect_success(invoke(restored, Zone::CMD_REMOVE_ZONE, Zone::ZoneIdRequest.new(id)))
    changes.last[0].as(Zone::ZoneInformation).zone_id.should eq(id)
    changes.last[1].should be_nil
    failing = build(Zone, feature_map: cluster.feature_map, automatic_timeouts: false)
    failing.restore_state(cluster.save_state)
    expect_raises(Matter::ConfigurationError) { failing.replay_zones_to_host! }
    failing.on_zone_change { |_previous, _current| Matter::InteractionModel::Status.invalid_in_state }
    expect_raises(Matter::ConfigurationError) { failing.replay_zones_to_host! }
  end

  it "declares revision-one attributes, manage commands, and mandatory events" do
    cluster = zone_fixture
    cluster.cluster_id.id.should eq(0x0550_u32)
    cluster.cluster_revision.should eq(1_u16)
    read(cluster, Zone::GLOBAL_FEATURE_MAP).should eq(5_u32)
    [Zone::ATTR_MAX_USER_DEFINED_ZONES, Zone::ATTR_MAX_ZONES, Zone::ATTR_ZONES,
     Zone::ATTR_TRIGGERS, Zone::ATTR_SENSITIVITY_MAX, Zone::ATTR_SENSITIVITY,
     Zone::ATTR_TWO_D_CARTESIAN_MAX].each { |id| attribute_ids(cluster).should contain(id) }
    accepted_command_ids(cluster).should eq([
      Zone::CMD_CREATE_TWO_D_CARTESIAN_ZONE, Zone::CMD_UPDATE_TWO_D_CARTESIAN_ZONE,
      Zone::CMD_REMOVE_ZONE, Zone::CMD_CREATE_OR_UPDATE_TRIGGER, Zone::CMD_REMOVE_TRIGGER,
    ])
    accepted_command_ids(cluster).each do |id|
      cluster.get_command_metadata(id).as(Matter::Cluster::CommandMetadata).access.should eq(Matter::InteractionModel::EntryPrivilege::Manage)
    end
    cluster.get_event_metadata(Zone::EVENT_ZONE_TRIGGERED).should_not be_nil
    cluster.get_event_metadata(Zone::EVENT_ZONE_STOPPED).should_not be_nil
    read(cluster, Zone::ATTR_SENSITIVITY).should eq(3_u8)
    expect_status(write(cluster, Zone::ATTR_SENSITIVITY, 6_u8), IMCode::ConstraintError)
  end

  it "creates, updates, removes, and restores validated user zones" do
    cluster = zone_fixture
    id = create_zone(cluster)
    id.should eq(0_u16)
    zones = read_tlv(cluster, Zone::ATTR_ZONES).as_list.map { |value| Zone::ZoneInformation.from_tlv(value) }
    zones.map(&.zone_id).should eq([id])
    zones.first.source.should eq(Zone::ZoneSource::User)
    updated = motion_zone("Porch")
    expect_success(invoke(cluster, Zone::CMD_UPDATE_TWO_D_CARTESIAN_ZONE, Zone::UpdateZoneRequest.new(id, updated)))
    restored = zone_fixture
    restored.restore_state(cluster.save_state)
    restored.zones.first.two_d_cartesian_zone.name.should eq("Porch")
    expect_success(invoke(restored, Zone::CMD_REMOVE_ZONE, Zone::ZoneIdRequest.new(id)))
    restored.zones.should be_empty
    create_zone(restored).should eq(1_u16)
    again = zone_fixture
    again.restore_state(restored.save_state)
    expect_success(invoke(again, Zone::CMD_REMOVE_ZONE, Zone::ZoneIdRequest.new(1_u16)))
    create_zone(again).should eq(2_u16)
  end

  it "rejects out-of-bounds or self-intersecting polygons atomically" do
    cluster = zone_fixture
    bad = Zone::TwoDCartesianZone.new("Bad", Zone::ZoneUse::Motion,
      [Zone::Vertex.new(0_u16, 0_u16), Zone::Vertex.new(100_u16, 100_u16),
       Zone::Vertex.new(0_u16, 100_u16), Zone::Vertex.new(100_u16, 0_u16)])
    expect_status(invoke(cluster, Zone::CMD_CREATE_TWO_D_CARTESIAN_ZONE,
      Zone::CreateZoneRequest.new(bad)), IMCode::ConstraintError)
    outside = Zone::TwoDCartesianZone.new("Outside", Zone::ZoneUse::Motion,
      [Zone::Vertex.new(0_u16, 0_u16), Zone::Vertex.new(101_u16, 0_u16),
       Zone::Vertex.new(0_u16, 100_u16)])
    expect_status(invoke(cluster, Zone::CMD_CREATE_TWO_D_CARTESIAN_ZONE,
      Zone::CreateZoneRequest.new(outside)), IMCode::ConstraintError)
    cluster.zones.should be_empty
  end

  it "requires a host privacy handler before accepting privacy geometry" do
    cluster = zone_fixture
    privacy = Zone::TwoDCartesianZone.new("Private", Zone::ZoneUse::Privacy,
      motion_zone.vertices)
    expect_status(invoke(cluster, Zone::CMD_CREATE_TWO_D_CARTESIAN_ZONE,
      Zone::CreateZoneRequest.new(privacy)), IMCode::InvalidInState)
    cluster.zones.should be_empty

    changes = [] of {Zone::ZoneInformation?, Zone::ZoneInformation?}
    cluster.on_zone_change do |previous, current|
      changes << {previous, current}
      Matter::InteractionModel::Status.success
    end
    id = create_zone(cluster, privacy)
    changes.last[1].as(Zone::ZoneInformation).zone_id.should eq(id)
    expect_success(invoke(cluster, Zone::CMD_REMOVE_ZONE, Zone::ZoneIdRequest.new(id)))
    changes.last[0].as(Zone::ZoneInformation).zone_id.should eq(id)
    changes.last[1].should be_nil
  end

  it "stores one trigger per motion zone, checks durations, and persists it" do
    cluster = zone_fixture
    id = create_zone(cluster)
    invalid = Zone::Trigger.new(id, 2_u32, 3_u32, 5_u32, 1_u32)
    expect_status(invoke(cluster, Zone::CMD_CREATE_OR_UPDATE_TRIGGER,
      Zone::TriggerRequest.new(invalid)), IMCode::ConstraintError)
    trigger = Zone::Trigger.new(id, 2_u32, 1_u32, 5_u32, 1_u32)
    expect_success(invoke(cluster, Zone::CMD_CREATE_OR_UPDATE_TRIGGER,
      Zone::TriggerRequest.new(trigger)))
    read_tlv(cluster, Zone::ATTR_TRIGGERS).as_list.size.should eq(1)
    restored = zone_fixture
    restored.restore_state(cluster.save_state)
    restored.triggers.first.zone_id.should eq(id)
    expect_success(invoke(restored, Zone::CMD_REMOVE_TRIGGER, Zone::ZoneIdRequest.new(id)))
    restored.triggers.should be_empty
    expect_status(invoke(restored, Zone::CMD_REMOVE_TRIGGER, Zone::ZoneIdRequest.new(id)), IMCode::NotFound)
  end

  it "emits one trigger event, stops on timeout, and honors blind duration" do
    cluster = zone_fixture
    id = create_zone(cluster)
    trigger = Zone::Trigger.new(id, 2_u32, 1_u32, 4_u32, 3_u32)
    expect_success(invoke(cluster, Zone::CMD_CREATE_OR_UPDATE_TRIGGER, Zone::TriggerRequest.new(trigger)))
    ids = [] of UInt32
    payloads = [] of TLV::Any
    cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, event : UInt32, _priority : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) do
      ids << event
      payloads << data
      nil
    end
    start = Time.monotonic
    cluster.report_motion(id, start).should be_true
    cluster.report_motion(id, start + 1.second).should be_false
    cluster.report_motion(id, start + 3.seconds).should be_false
    cluster.advance_trigger_timers(start + 4.seconds)
    ids.should eq([Zone::EVENT_ZONE_TRIGGERED, Zone::EVENT_ZONE_STOPPED])
    Zone::ZoneStoppedEvent.from_tlv(payloads.last).reason.should eq(Zone::StoppedReason::Timeout)
    cluster.report_motion(id, start + 5.seconds).should be_false
    cluster.report_motion(id, start + 7.seconds).should be_true
  end
end
