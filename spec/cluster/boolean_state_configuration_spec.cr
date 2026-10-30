require "../spec_helper"

private alias BSC = Matter::Cluster::BooleanStateConfiguration

private struct AlarmStateWire
  include TLV::Serializable

  @[TLV::Field(tag: 0)]
  getter alarms_active : BSC::AlarmMode

  @[TLV::Field(tag: 1)]
  getter alarms_suppressed : BSC::AlarmMode?
end

private struct SensorFaultWire
  include TLV::Serializable

  @[TLV::Field(tag: 0)]
  getter sensor_fault : BSC::SensorFault
end

describe Matter::Cluster::BooleanStateConfiguration do
  it "advertises revision 2 and rejects suppression without visual or audible alarms" do
    bare = build(BSC)
    bare.cluster_revision.should eq(2_u16)
    bare.get_command_metadata(BSC::CMD_SUPPRESS_ALARM).should be_nil
    bare.get_command_metadata(BSC::CMD_ENABLE_DISABLE_ALARM).should be_nil
    bare.get_event_metadata(BSC::EVENT_ALARMS_STATE_CHANGED).should be_nil
    bare.get_event_metadata(BSC::EVENT_SENSOR_FAULT).should be_nil
    expect_raises(ArgumentError) { build(BSC, feature_map: BSC::Feature::AlarmSuppress) }
  end

  it "gates sensitivity attributes and validates supported level count" do
    build(BSC).get_attribute_metadata(BSC::ATTR_CURRENT_SENSITIVITY_LEVEL).should be_nil
    expect_raises(ArgumentError) { build(BSC, feature_map: BSC::Feature::SensitivityLevel, supported_sensitivity_levels: 1_u8) }
    expect_raises(ArgumentError) { build(BSC, feature_map: BSC::Feature::SensitivityLevel, supported_sensitivity_levels: 11_u8) }
    sensor = build(BSC, feature_map: BSC::Feature::SensitivityLevel, supported_sensitivity_levels: 4_u8)
    read(sensor, BSC::ATTR_SUPPORTED_SENSITIVITY_LEVELS).should eq(4_u8)
    sensor.get_attribute_metadata(BSC::ATTR_DEFAULT_SENSITIVITY_LEVEL).should be_nil
    expect_success(write(sensor, BSC::ATTR_CURRENT_SENSITIVITY_LEVEL, 3_u8))
    sensor.current_sensitivity_level.should eq(3_u8)
    write(sensor, BSC::ATTR_CURRENT_SENSITIVITY_LEVEL, 4_u8).status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    sensor.save_state["current_sensitivity_level"].as(Int64).should eq(3)
    restored = build(BSC, feature_map: BSC::Feature::SensitivityLevel, supported_sensitivity_levels: 4_u8)
    restored.restore_state(sensor.save_state.as(Matter::Storage::Document))
    restored.current_sensitivity_level.should eq(3_u8)
    with_default = build(BSC, feature_map: BSC::Feature::SensitivityLevel,
      supported_sensitivity_levels: 4_u8, default_sensitivity_level: 2_u8)
    read(with_default, BSC::ATTR_DEFAULT_SENSITIVITY_LEVEL).should eq(2_u8)
  end

  it "updates enabled alarms through a typed command and rejects unsupported modes" do
    sensor = build(BSC, feature_map: BSC::Feature::Visual | BSC::Feature::Audible)
    initial = build(BSC, feature_map: BSC::Feature::Visual | BSC::Feature::Audible)
    initial.restore_state(sensor.save_state.as(Matter::Storage::Document))
    initial.alarms_enabled.should eq(BSC::AlarmMode::Visual | BSC::AlarmMode::Audible)
    request = BSC::EnableDisableAlarmRequest.new(BSC::AlarmMode::Visual)
    expect_success(invoke(sensor, BSC::CMD_ENABLE_DISABLE_ALARM, request))
    sensor.alarms_enabled.should eq(BSC::AlarmMode::Visual)
    restored = build(BSC, feature_map: BSC::Feature::Visual | BSC::Feature::Audible)
    restored.restore_state(sensor.save_state.as(Matter::Storage::Document))
    restored.alarms_enabled.should eq(BSC::AlarmMode::Visual)
    visual_only = build(BSC, feature_map: BSC::Feature::Visual)
    expect_status(invoke(visual_only, BSC::CMD_ENABLE_DISABLE_ALARM,
      BSC::EnableDisableAlarmRequest.new(BSC::AlarmMode::Audible)), Matter::InteractionModel::StatusCode::ConstraintError)
  end

  it "rejects invalid direct alarm assignments before changing state or emitting events" do
    sensor = build(BSC, feature_map: BSC::Feature::Visual | BSC::Feature::AlarmSuppress)
    events = [] of TLV::Any
    sensor.on_event_emitted = ->(_endpoint : UInt16, _cluster : UInt32, event : UInt32, _priority : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) do
      event.should eq(BSC::EVENT_ALARMS_STATE_CHANGED)
      events << data
      nil
    end
    initial_version = sensor.data_version

    expect_raises(ArgumentError) { sensor.alarms_active = BSC::AlarmMode::Audible }
    expect_raises(ArgumentError) { sensor.alarms_enabled = BSC::AlarmMode::Audible }
    expect_raises(ArgumentError) { sensor.alarms_suppressed = BSC::AlarmMode::Audible }
    expect_raises(ArgumentError) { sensor.alarms_suppressed = BSC::AlarmMode::Visual }

    sensor.alarms_active.should eq(BSC::AlarmMode::None)
    sensor.alarms_enabled.should eq(BSC::AlarmMode::Visual)
    sensor.alarms_suppressed.should eq(BSC::AlarmMode::None)
    sensor.data_version.should eq(initial_version)
    events.should be_empty

    sensor.alarms_enabled = BSC::AlarmMode::None
    disabled_version = sensor.data_version
    expect_raises(ArgumentError) { sensor.alarms_active = BSC::AlarmMode::Visual }
    sensor.alarms_active.should eq(BSC::AlarmMode::None)
    sensor.data_version.should eq(disabled_version)
    events.should be_empty
  end

  it "emits supported direct alarm assignments with the current event payload" do
    sensor = build(BSC, feature_map: BSC::Feature::Visual | BSC::Feature::AlarmSuppress)
    events = [] of TLV::Any
    sensor.on_event_emitted = ->(_endpoint : UInt16, _cluster : UInt32, event : UInt32, _priority : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) do
      event.should eq(BSC::EVENT_ALARMS_STATE_CHANGED)
      events << data
      nil
    end

    sensor.alarms_active = BSC::AlarmMode::Visual
    sensor.alarms_suppressed = BSC::AlarmMode::Visual

    events.size.should eq(2)
    first = AlarmStateWire.from_tlv(events.first)
    first.alarms_active.should eq(BSC::AlarmMode::Visual)
    first.alarms_suppressed.should eq(BSC::AlarmMode::None)
    last = AlarmStateWire.from_tlv(events.last)
    last.alarms_active.should eq(BSC::AlarmMode::Visual)
    last.alarms_suppressed.should eq(BSC::AlarmMode::Visual)
  end

  it "journals an alarm state event and keeps suppression separate from active alarms" do
    node = Matter::Node.new
    endpoint1 = Matter::Endpoint.new(endpoint(1))
    sensor = build(BSC, feature_map: BSC::Feature::Visual | BSC::Feature::AlarmSuppress)
    endpoint1.add_cluster(sensor)
    node.add_endpoint(endpoint1)

    sensor.update_alarms_active(BSC::AlarmMode::Visual)
    expect_success(invoke(sensor, BSC::CMD_SUPPRESS_ALARM,
      BSC::SuppressAlarmRequest.new(BSC::AlarmMode::Visual)))
    sensor.alarms_active.should eq(BSC::AlarmMode::Visual)
    sensor.alarms_suppressed.should eq(BSC::AlarmMode::Visual)

    records = node.event_journal.query([Matter::InteractionModel::EventPath.new(
      cluster: BSC::CLUSTER_ID, event: BSC::EVENT_ALARMS_STATE_CHANGED)])
    records.size.should eq(2)
    payload = AlarmStateWire.from_tlv(records.last.data)
    payload.alarms_active.should eq(BSC::AlarmMode::Visual)
    payload.alarms_suppressed.should eq(BSC::AlarmMode::Visual)

    sensor.update_alarms_active(BSC::AlarmMode::None)
    sensor.alarms_suppressed.should eq(BSC::AlarmMode::None)
  end

  it "omits the suppressed field when AlarmSuppress is absent" do
    node = Matter::Node.new
    endpoint1 = Matter::Endpoint.new(endpoint(1))
    sensor = build(BSC, feature_map: BSC::Feature::Visual)
    endpoint1.add_cluster(sensor)
    node.add_endpoint(endpoint1)

    sensor.update_alarms_active(BSC::AlarmMode::Visual)
    records = node.event_journal.query([Matter::InteractionModel::EventPath.new(
      cluster: BSC::CLUSTER_ID, event: BSC::EVENT_ALARMS_STATE_CHANGED)])
    records.size.should eq(1)
    AlarmStateWire.from_tlv(records.first.data).alarms_suppressed.should be_nil
  end

  it "clears active and suppressed modes when a mode is disabled" do
    sensor = build(BSC, feature_map: BSC::Feature::Visual | BSC::Feature::Audible | BSC::Feature::AlarmSuppress)
    sensor.update_alarms_active(BSC::AlarmMode::Visual | BSC::AlarmMode::Audible)
    expect_success(invoke(sensor, BSC::CMD_SUPPRESS_ALARM,
      BSC::SuppressAlarmRequest.new(BSC::AlarmMode::Visual)))

    expect_success(invoke(sensor, BSC::CMD_ENABLE_DISABLE_ALARM,
      BSC::EnableDisableAlarmRequest.new(BSC::AlarmMode::Audible)))
    sensor.alarms_enabled.should eq(BSC::AlarmMode::Audible)
    sensor.alarms_active.should eq(BSC::AlarmMode::Audible)
    sensor.alarms_suppressed.should eq(BSC::AlarmMode::None)
    expect_raises(ArgumentError) { sensor.update_alarms_active(BSC::AlarmMode::Visual) }
  end

  it "returns InvalidInState when suppressing an inactive alarm" do
    sensor = build(BSC, feature_map: BSC::Feature::Visual | BSC::Feature::AlarmSuppress)
    expect_status(invoke(sensor, BSC::CMD_SUPPRESS_ALARM,
      BSC::SuppressAlarmRequest.new(BSC::AlarmMode::Visual)), Matter::InteractionModel::StatusCode::InvalidInState)
  end

  it "gates typed fault events and journals each fault state change" do
    node = Matter::Node.new
    endpoint1 = Matter::Endpoint.new(endpoint(1))
    sensor = build(BSC, feature_map: BSC::Feature::FaultEvents)
    endpoint1.add_cluster(sensor)
    node.add_endpoint(endpoint1)

    sensor.report_sensor_fault(BSC::SensorFault::GeneralFault)
    sensor.report_sensor_fault(BSC::SensorFault::GeneralFault)
    sensor.report_sensor_fault(BSC::SensorFault::None)
    records = node.event_journal.query([Matter::InteractionModel::EventPath.new(
      cluster: BSC::CLUSTER_ID, event: BSC::EVENT_SENSOR_FAULT)])
    records.size.should eq(2)
    SensorFaultWire.from_tlv(records.first.data).sensor_fault.should eq(BSC::SensorFault::GeneralFault)
    SensorFaultWire.from_tlv(records.last.data).sensor_fault.should eq(BSC::SensorFault::None)
  end
end
