require "../spec_helper"

private alias ScheduleAtomic = Matter::Cluster::Thermostat
private alias ScheduleStatus = Matter::InteractionModel::StatusCode

private alias ScheduleAtomicWireReady = ScheduleAtomic

private def schedule_atomic_cluster : ScheduleAtomicWireReady
  type = ScheduleAtomic::ScheduleType.new(ScheduleAtomic::SystemMode::Heat, 2_u8,
    ScheduleAtomic::ScheduleTypeFeatures::SupportsSetpoints)
  cluster = build(ScheduleAtomicWireReady,
    feature_map: ScheduleAtomic::Feature::Heating | ScheduleAtomic::Feature::MatterSchedules,
    schedule_types: [type], schedule_max_transitions: 4_u8, schedule_max_per_day: 2_u8,
    local_time_provider: -> : Time? { nil })
  cluster
end

private def schedule_atomic_actor(cluster : ScheduleAtomic, fabric : UInt8 = 1_u8,
                                  subject : UInt64 = 11_u64) : Nil
  cluster.request_is_case_session = true
  cluster.request_fabric_index = fabric
  cluster.request_peer_node_id = subject
end

private def schedule_atomic_request(cluster : ScheduleAtomic, type : ScheduleAtomic::AtomicRequestType,
                                    timeout : UInt16? = nil) : ScheduleAtomic::AtomicResponse | Matter::InteractionModel::Status
  cluster.atomic_request(ScheduleAtomic::AtomicRequest.new(type, [ScheduleAtomic::ATTR_SCHEDULES], timeout))
end

private def schedule_atomic_write(cluster : ScheduleAtomic, schedules : Array(ScheduleAtomic::Schedule),
                                  fabric : UInt8 = 1_u8, subject : UInt64 = 11_u64,
                                  data_version : UInt32? = nil, is_case : Bool = true) : ScheduleStatus
  endpoint = cluster.endpoint_id.number
  path = Matter::InteractionModel::AttributePath.new(endpoint: endpoint,
    cluster: ScheduleAtomic::CLUSTER_ID, attribute: ScheduleAtomic::ATTR_SCHEDULES)
  data = Matter::InteractionModel::AttributeDataIB.new(path, TLV::Serializable.serialize_value(schedules, nil), data_version)
  statuses = Matter::Protocol::IMHandler.write_attributes([data],
    { {endpoint, ScheduleAtomic::CLUSTER_ID} => cluster.as(Matter::Cluster::Base) },
    session_id: 9_u16, is_case_session: is_case, fabric_index: fabric, peer_subject_ids: [subject])
  ScheduleStatus.new(statuses.first.status.status)
end

private def schedule_atomic_append(cluster : ScheduleAtomic, schedule : ScheduleAtomic::Schedule) : ScheduleStatus
  endpoint = cluster.endpoint_id.number
  replace_path = Matter::InteractionModel::AttributePath.new(endpoint: endpoint,
    cluster: ScheduleAtomic::CLUSTER_ID, attribute: ScheduleAtomic::ATTR_SCHEDULES)
  replace = Matter::InteractionModel::AttributeDataIB.new(replace_path,
    TLV::Serializable.serialize_value([] of ScheduleAtomic::Schedule, nil))
  path = Matter::InteractionModel::AttributePath.new(endpoint: endpoint,
    cluster: ScheduleAtomic::CLUSTER_ID, attribute: ScheduleAtomic::ATTR_SCHEDULES,
    list_index_null: true)
  data = Matter::InteractionModel::AttributeDataIB.new(path, TLV::Serializable.serialize_value(schedule, nil))
  statuses = Matter::Protocol::IMHandler.write_attributes([replace, data],
    { {endpoint, ScheduleAtomic::CLUSTER_ID} => cluster.as(Matter::Cluster::Base) },
    session_id: 9_u16, is_case_session: true, fabric_index: 1_u8, peer_subject_ids: [11_u64])
  ScheduleStatus.new(statuses.last.status.status)
end

private def schedule_atomic_value(handle : Bytes? = nil, heating : Int16 = 2100_i16) : ScheduleAtomic::Schedule
  transition = ScheduleAtomic::ScheduleTransition.new(0x02_u8, 480_u16, nil, nil, nil, heating)
  ScheduleAtomic::Schedule.new(handle, ScheduleAtomic::SystemMode::Heat,
    nil, nil, [transition], false)
end

describe "Thermostat MSCH atomic-write transaction" do
  it "requires a host clock and declares Manage-only wire metadata" do
    expect_raises(ArgumentError) do
      build(ScheduleAtomic, feature_map: ScheduleAtomic::Feature::Heating | ScheduleAtomic::Feature::MatterSchedules)
    end
    cluster = schedule_atomic_cluster
    metadata = cluster.get_attribute_metadata(ScheduleAtomic::ATTR_SCHEDULES) || raise "missing Schedules"
    metadata.write_access.should eq(Matter::InteractionModel::EntryPrivilege::Manage)
    cluster.get_command_metadata(ScheduleAtomic::CMD_ATOMIC_REQUEST).try(&.access)
      .should eq(Matter::InteractionModel::EntryPrivilege::Manage)
  end

  it "stages privately, rolls back, commits, and persists only committed schedules" do
    cluster = schedule_atomic_cluster
    schedule_atomic_actor(cluster)
    schedule_atomic_request(cluster, ScheduleAtomic::AtomicRequestType::BeginWrite, 3_000_u16)
      .as(ScheduleAtomic::AtomicResponse).status_code.should eq(ScheduleStatus::Success)
    schedule_atomic_append(cluster, schedule_atomic_value).should eq(ScheduleStatus::Success)
    cluster.schedules.should be_empty
    schedule_atomic_actor(cluster)
    owner_view = cluster.read_attribute(ScheduleAtomic::ATTR_SCHEDULES).as(TLV::Any)
    TLV::Serializable.deserialize_value(owner_view, Array(ScheduleAtomic::Schedule)).size.should eq(1)
    schedule_atomic_actor(cluster, subject: 12_u64)
    other_view = cluster.read_attribute(ScheduleAtomic::ATTR_SCHEDULES).as(TLV::Any)
    TLV::Serializable.deserialize_value(other_view, Array(ScheduleAtomic::Schedule)).should be_empty
    schedule_atomic_actor(cluster)
    schedule_atomic_request(cluster, ScheduleAtomic::AtomicRequestType::RollbackWrite)
      .as(ScheduleAtomic::AtomicResponse).status_code.should eq(ScheduleStatus::Success)
    cluster.schedules.should be_empty

    schedule_atomic_request(cluster, ScheduleAtomic::AtomicRequestType::BeginWrite, 3_000_u16)
      .as(ScheduleAtomic::AtomicResponse).status_code.should eq(ScheduleStatus::Success)
    schedule_atomic_append(cluster, schedule_atomic_value).should eq(ScheduleStatus::Success)
    schedule_atomic_request(cluster, ScheduleAtomic::AtomicRequestType::CommitWrite)
      .as(ScheduleAtomic::AtomicResponse).status_code.should eq(ScheduleStatus::Success)
    handle = cluster.schedules.first.schedule_handle || raise "schedule handle was not assigned"
    handle.size.should be <= ScheduleAtomic::MAX_SCHEDULE_HANDLE_LENGTH
    restored = schedule_atomic_cluster
    restored.restore_state(cluster.save_state)
    restored.schedules.first.schedule_handle.should eq(handle)
  end

  it "isolates owners and rejects unknown handles without publishing changes" do
    cluster = schedule_atomic_cluster
    schedule_atomic_actor(cluster)
    schedule_atomic_request(cluster, ScheduleAtomic::AtomicRequestType::BeginWrite, 3_000_u16)
      .as(ScheduleAtomic::AtomicResponse).status_code.should eq(ScheduleStatus::Success)
    schedule_atomic_write(cluster, [schedule_atomic_value(Bytes[7_u8])]).should eq(ScheduleStatus::NotFound)
    schedule_atomic_write(cluster, [] of ScheduleAtomic::Schedule, subject: 12_u64)
      .should eq(ScheduleStatus::InvalidInState)
    schedule_atomic_write(cluster, [] of ScheduleAtomic::Schedule, fabric: 2_u8)
      .should eq(ScheduleStatus::InvalidInState)
    schedule_atomic_actor(cluster, subject: 12_u64)
    schedule_atomic_request(cluster, ScheduleAtomic::AtomicRequestType::CommitWrite)
      .as(Matter::InteractionModel::Status).status.should eq(ScheduleStatus::InvalidInState)
    schedule_atomic_actor(cluster)
    schedule_atomic_request(cluster, ScheduleAtomic::AtomicRequestType::RollbackWrite)
      .as(ScheduleAtomic::AtomicResponse).status_code.should eq(ScheduleStatus::Success)
  end

  it "expires writes, caps the timeout, and removes only the owning fabric state" do
    cluster = schedule_atomic_cluster
    Timecop.freeze(Time.utc) do
      schedule_atomic_actor(cluster)
      started = schedule_atomic_request(cluster, ScheduleAtomic::AtomicRequestType::BeginWrite, UInt16::MAX)
        .as(ScheduleAtomic::AtomicResponse)
      started.timeout.should eq(ScheduleAtomic::MAX_PRESET_ATOMIC_TIMEOUT)
      schedule_atomic_actor(cluster, subject: 12_u64)
      busy = schedule_atomic_request(cluster, ScheduleAtomic::AtomicRequestType::BeginWrite, 1_000_u16)
        .as(ScheduleAtomic::AtomicResponse)
      busy.attribute_status.first.status_code.should eq(ScheduleStatus::Busy)
      cluster.remove_fabric(2_u8)
      schedule_atomic_actor(cluster)
      schedule_atomic_write(cluster, [] of ScheduleAtomic::Schedule).should eq(ScheduleStatus::Success)
      cluster.remove_fabric(1_u8)
      schedule_atomic_request(cluster, ScheduleAtomic::AtomicRequestType::CommitWrite)
        .as(Matter::InteractionModel::Status).status.should eq(ScheduleStatus::InvalidInState)
      schedule_atomic_request(cluster, ScheduleAtomic::AtomicRequestType::BeginWrite, 100_u16)
        .as(ScheduleAtomic::AtomicResponse).status_code.should eq(ScheduleStatus::Success)
      Timecop.travel(Time.utc + 1.second) do
        schedule_atomic_request(cluster, ScheduleAtomic::AtomicRequestType::CommitWrite)
          .as(Matter::InteractionModel::Status).status.should eq(ScheduleStatus::InvalidInState)
      end
    end
  end

  it "rejects stale conditional writes and prevents built-in schedule removal at commit" do
    cluster = schedule_atomic_cluster
    schedule_atomic_actor(cluster)
    version = cluster.data_version
    schedule_atomic_request(cluster, ScheduleAtomic::AtomicRequestType::BeginWrite, 3_000_u16)
      .as(ScheduleAtomic::AtomicResponse)
    schedule_atomic_write(cluster, [] of ScheduleAtomic::Schedule, data_version: version)
      .should eq(ScheduleStatus::Success)
    cluster.occupied_heating_setpoint = 1900_i16
    schedule_atomic_actor(cluster)
    failed = schedule_atomic_request(cluster, ScheduleAtomic::AtomicRequestType::CommitWrite)
      .as(ScheduleAtomic::AtomicResponse)
    failed.attribute_status.first.status_code.should eq(ScheduleStatus::DataVersionMismatch)
    cluster.schedules.should be_empty

    built_in = ScheduleAtomic::Schedule.new(Bytes[3_u8], ScheduleAtomic::SystemMode::Heat,
      nil, nil, schedule_atomic_value.transitions, true)
    cluster.configure_schedules(cluster.schedule_types, [built_in], 4_u8, 2_u8)
    schedule_atomic_actor(cluster)
    schedule_atomic_request(cluster, ScheduleAtomic::AtomicRequestType::BeginWrite, 3_000_u16)
      .as(ScheduleAtomic::AtomicResponse)
    schedule_atomic_write(cluster, [] of ScheduleAtomic::Schedule).should eq(ScheduleStatus::Success)
    failed = schedule_atomic_request(cluster, ScheduleAtomic::AtomicRequestType::CommitWrite)
      .as(ScheduleAtomic::AtomicResponse)
    failed.attribute_status.first.status_code.should eq(ScheduleStatus::ConstraintError)
    cluster.schedules.first.schedule_handle.should eq(Bytes[3_u8])
  end

  it "requires an operational session and rejects writes outside an atomic transaction" do
    cluster = schedule_atomic_cluster
    schedule_atomic_write(cluster, [] of ScheduleAtomic::Schedule).should eq(ScheduleStatus::InvalidInState)
    schedule_atomic_actor(cluster)
    schedule_atomic_request(cluster, ScheduleAtomic::AtomicRequestType::BeginWrite, 3_000_u16)
      .as(ScheduleAtomic::AtomicResponse)
    schedule_atomic_write(cluster, [] of ScheduleAtomic::Schedule, is_case: false)
      .should eq(ScheduleStatus::InvalidInState)
  end

  it "reports resource exhaustion for transition and per-day limits" do
    cluster = schedule_atomic_cluster
    schedule_atomic_actor(cluster)
    schedule_atomic_request(cluster, ScheduleAtomic::AtomicRequestType::BeginWrite, 3_000_u16)
      .as(ScheduleAtomic::AtomicResponse)
    transitions = (0...5).map do |index|
      ScheduleAtomic::ScheduleTransition.new(0x02_u8, (300 + index * 60).to_u16,
        nil, nil, nil, 2100_i16)
    end
    oversized = ScheduleAtomic::Schedule.new(nil, ScheduleAtomic::SystemMode::Heat,
      nil, nil, transitions, false)
    schedule_atomic_append(cluster, oversized).should eq(ScheduleStatus::ResourceExhausted)
    per_day = ScheduleAtomic::Schedule.new(nil, ScheduleAtomic::SystemMode::Heat,
      nil, nil, transitions.first(3), false)
    schedule_atomic_append(cluster, per_day).should eq(ScheduleStatus::ResourceExhausted)
    cluster.schedules.should be_empty
  end
end
