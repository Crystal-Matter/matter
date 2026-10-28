require "../spec_helper"

private alias ActiveScheduleThermostat = Matter::Cluster::Thermostat
private alias ActiveScheduleStatus = Matter::InteractionModel::StatusCode

private alias ActiveScheduleWireReady = ActiveScheduleThermostat

private def active_schedule_cluster(events : Bool = false) : ActiveScheduleWireReady
  features = ActiveScheduleThermostat::Feature::Heating | ActiveScheduleThermostat::Feature::MatterSchedules
  features |= ActiveScheduleThermostat::Feature::Events if events
  type = ActiveScheduleThermostat::ScheduleType.new(ActiveScheduleThermostat::SystemMode::Heat, 2_u8,
    ActiveScheduleThermostat::ScheduleTypeFeatures::SupportsSetpoints)
  transition = ActiveScheduleThermostat::ScheduleTransition.new(0x02_u8, 480_u16, nil, nil, nil, 2100_i16)
  schedule = ActiveScheduleThermostat::Schedule.new(Bytes[1_u8], ActiveScheduleThermostat::SystemMode::Heat,
    nil, nil, [transition], false)
  build(ActiveScheduleWireReady, feature_map: features,
    schedule_types: [type], schedules: [schedule], schedule_max_transitions: 4_u8,
    schedule_max_per_day: 2_u8, local_time_provider: -> : Time? { nil })
end

private def invoke_active_schedule(cluster : ActiveScheduleThermostat, handle : Bytes) : ActiveScheduleStatus
  endpoint = cluster.endpoint_id.number
  path = Matter::InteractionModel::CommandPath.new(endpoint, ActiveScheduleThermostat::CLUSTER_ID,
    ActiveScheduleThermostat::CMD_SET_ACTIVE_SCHEDULE)
  request = ActiveScheduleThermostat::SetActiveScheduleRequest.new(handle)
  command = Matter::InteractionModel::CommandDataIBTlv.new(path, TLV::Serializable.serialize_value(request, nil))
  response = Matter::Protocol::IMHandler.invoke_commands([command],
    case_im_clusters(cluster),
    session_id: 9_u64, is_case_session: true, fabric_index: 1_u8,
    peer_subject_ids: [11_u64]).first
  status = response.command_status || raise "expected SetActiveSchedule status"
  ActiveScheduleStatus.new(status.status.status)
end

describe "Thermostat MSCH SetActiveSchedule" do
  it "requires a host clock and exposes command 0x05 only with configured MSCH" do
    expect_raises(ArgumentError) do
      build(ActiveScheduleThermostat,
        feature_map: ActiveScheduleThermostat::Feature::Heating | ActiveScheduleThermostat::Feature::MatterSchedules)
    end
    build(ActiveScheduleThermostat).get_command_metadata(0x05_u32).should be_nil
    active_schedule_cluster.get_command_metadata(0x05_u32).should_not be_nil
  end

  it "accepts a committed schedule handle, reports the change once, and emits a typed event" do
    cluster = active_schedule_cluster(events: true)
    changed = [] of UInt32
    cluster.on_attribute_changed = ->(_endpoint : UInt16, _cluster : UInt32, attribute : UInt32) {
      changed << attribute
      nil
    }
    events = [] of TLV::Any
    cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, id : UInt32, _priority : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) do
      events << data if id == ActiveScheduleThermostat::EVENT_ACTIVE_SCHEDULE_CHANGE
      nil
    end

    invoke_active_schedule(cluster, Bytes[1_u8]).should eq(ActiveScheduleStatus::Success)
    cluster.active_schedule_handle.should eq(Bytes[1_u8])
    read(cluster, ActiveScheduleThermostat::ATTR_ACTIVE_SCHEDULE_HANDLE).should eq(Bytes[1_u8])
    changed.should eq([ActiveScheduleThermostat::ATTR_ACTIVE_SCHEDULE_HANDLE])
    events.size.should eq(1)
    event = ActiveScheduleThermostat::ActiveScheduleChangeEvent.from_tlv(events.first)
    event.previous_schedule_handle.should be_nil
    event.current_schedule_handle.should eq(Bytes[1_u8])

    invoke_active_schedule(cluster, Bytes[1_u8]).should eq(ActiveScheduleStatus::Success)
    changed.size.should eq(1)
    events.size.should eq(1)
  end

  it "rejects unknown and oversized handles without changing active state" do
    cluster = active_schedule_cluster
    invoke_active_schedule(cluster, Bytes[2_u8]).should eq(ActiveScheduleStatus::InvalidCommand)
    invoke_active_schedule(cluster, Bytes.new(17, 1_u8)).should eq(ActiveScheduleStatus::ConstraintError)
    cluster.active_schedule_handle.should be_nil
  end

  it "persists the selected handle and prevents host removal of the active schedule" do
    cluster = active_schedule_cluster
    invoke_active_schedule(cluster, Bytes[1_u8]).should eq(ActiveScheduleStatus::Success)
    restored = active_schedule_cluster
    restored.restore_state(cluster.save_state)
    restored.active_schedule_handle.should eq(Bytes[1_u8])
    expect_raises(ArgumentError) do
      restored.configure_schedules(restored.schedule_types, [] of ActiveScheduleThermostat::Schedule, 4_u8, 2_u8)
    end
    restored.active_schedule_handle.should eq(Bytes[1_u8])
  end

  it "reads older schedule state without an active handle and ignores a stale persisted selection" do
    cluster = active_schedule_cluster
    document = cluster.save_state || raise "expected saved state"
    state = document[ActiveScheduleThermostat::SCHEDULE_STATE_KEY].as(Matter::Storage::Document)
    state.has_key?("active_schedule_handle").should be_false

    restored = active_schedule_cluster
    restored.restore_state(document)
    restored.active_schedule_handle.should be_nil
    state["active_schedule_handle"] = Bytes[2_u8]
    restored.restore_state(document)
    restored.active_schedule_handle.should be_nil
    restored.schedules.first.schedule_handle.should eq(Bytes[1_u8])
  end
end
