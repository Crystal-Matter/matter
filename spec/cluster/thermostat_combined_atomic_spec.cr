require "../spec_helper"

private alias JointThermostat = Matter::Cluster::Thermostat
private alias JointStatus = Matter::InteractionModel::StatusCode

private class JointAtomicWireReady < JointThermostat
  protected def preset_wire_ready? : Bool
    true
  end

  protected def candidate_preset_handle : Bytes
    Bytes[1_u8]
  end
end

private def joint_cluster : JointAtomicWireReady
  type = JointThermostat::ScheduleType.new(JointThermostat::SystemMode::Heat, 2_u8,
    JointThermostat::ScheduleTypeFeatures::SupportsPresets | JointThermostat::ScheduleTypeFeatures::SupportsSetpoints)
  cluster = build(JointAtomicWireReady,
    feature_map: JointThermostat::Feature::Heating | JointThermostat::Feature::Presets |
                 JointThermostat::Feature::MatterSchedules,
    preset_types: [JointThermostat::PresetType.new(JointThermostat::PresetScenario::Sleep, 2_u8)],
    schedule_types: [type], schedule_max_transitions: 4_u8, schedule_max_per_day: 2_u8,
    local_time_provider: -> : Time? { nil })
  cluster
end

private def joint_actor(cluster : JointThermostat, fabric : UInt8 = 1_u8, subject : UInt64 = 11_u64) : Nil
  cluster.request_is_case_session = true
  cluster.request_fabric_index = fabric
  cluster.request_peer_node_id = subject
end

private def joint_request(cluster : JointThermostat, type : JointThermostat::AtomicRequestType,
                          ids = [JointThermostat::ATTR_PRESETS, JointThermostat::ATTR_SCHEDULES],
                          timeout : UInt16? = nil) : JointThermostat::AtomicResponse | Matter::InteractionModel::Status
  cluster.atomic_request(JointThermostat::AtomicRequest.new(type, ids, timeout))
end

private def joint_write_list(cluster : JointThermostat, attribute : UInt32, entries : Array(T),
                             item : T? = nil, data_version : UInt32? = nil) : Array(JointStatus) forall T
  endpoint = cluster.endpoint_id.number
  path = Matter::InteractionModel::AttributePath.new(endpoint: endpoint,
    cluster: JointThermostat::CLUSTER_ID, attribute: attribute)
  writes = [Matter::InteractionModel::AttributeDataIB.new(path,
    TLV::Serializable.serialize_value(entries, nil), data_version)]
  if value = item
    append_path = Matter::InteractionModel::AttributePath.new(endpoint: endpoint,
      cluster: JointThermostat::CLUSTER_ID, attribute: attribute, list_index_null: true)
    writes << Matter::InteractionModel::AttributeDataIB.new(append_path,
      TLV::Serializable.serialize_value(value, nil), data_version)
  end
  Matter::Protocol::IMHandler.write_attributes(writes,
    case_im_clusters(cluster),
    session_id: 9_u16, is_case_session: true, fabric_index: 1_u8, peer_subject_ids: [11_u64])
    .map { |status| JointStatus.new(status.status.status) }
end

private def joint_new_preset : JointThermostat::Preset
  JointThermostat::Preset.new(nil, JointThermostat::PresetScenario::Sleep,
    nil, nil, 2100_i16, nil)
end

private def joint_new_schedule(preset_handle : Bytes = Bytes[1_u8]) : JointThermostat::Schedule
  transition = JointThermostat::ScheduleTransition.new(0x02_u8, 480_u16,
    preset_handle, nil, nil, nil)
  JointThermostat::Schedule.new(nil, JointThermostat::SystemMode::Heat,
    nil, preset_handle, [transition], nil)
end

describe "Thermostat combined Presets and Schedules atomic transaction" do
  it "stages both lists under one owner and commits a reference to a newly generated preset" do
    cluster = joint_cluster
    joint_actor(cluster)
    begun = joint_request(cluster, JointThermostat::AtomicRequestType::BeginWrite,
      timeout: 3_000_u16).as(JointThermostat::AtomicResponse)
    begun.status_code.should eq(JointStatus::Success)
    begun.attribute_status.map(&.attribute_id).should eq([JointThermostat::ATTR_PRESETS, JointThermostat::ATTR_SCHEDULES])
    joint_write_list(cluster, JointThermostat::ATTR_PRESETS,
      [] of JointThermostat::Preset, joint_new_preset).should eq([JointStatus::Success] * 2)
    joint_write_list(cluster, JointThermostat::ATTR_SCHEDULES,
      [] of JointThermostat::Schedule, joint_new_schedule).should eq([JointStatus::Success] * 2)
    cluster.presets.should be_empty
    cluster.schedules.should be_empty

    joint_actor(cluster)
    staged = cluster.read_attribute(JointThermostat::ATTR_PRESETS).as(TLV::Any)
    TLV::Serializable.deserialize_value(staged, Array(JointThermostat::Preset)).first.preset_handle
      .should eq(Bytes[1_u8])
    joint_actor(cluster, subject: 12_u64)
    private_view = cluster.read_attribute(JointThermostat::ATTR_SCHEDULES).as(TLV::Any)
    TLV::Serializable.deserialize_value(private_view, Array(JointThermostat::Schedule)).should be_empty
    joint_actor(cluster)

    joint_request(cluster, JointThermostat::AtomicRequestType::CommitWrite)
      .as(JointThermostat::AtomicResponse).status_code.should eq(JointStatus::Success)
    cluster.presets.first.preset_handle.should eq(Bytes[1_u8])
    cluster.schedules.first.preset_handle.should eq(Bytes[1_u8])
    restored = joint_cluster
    restored.restore_state(cluster.save_state)
    restored.presets.first.preset_handle.should eq(Bytes[1_u8])
    restored.schedules.first.preset_handle.should eq(Bytes[1_u8])
  end

  it "rolls back both lists and rejects a partial commit" do
    cluster = joint_cluster
    joint_actor(cluster)
    joint_request(cluster, JointThermostat::AtomicRequestType::BeginWrite,
      timeout: 3_000_u16).as(JointThermostat::AtomicResponse)
    joint_write_list(cluster, JointThermostat::ATTR_PRESETS,
      [] of JointThermostat::Preset, joint_new_preset).should eq([JointStatus::Success] * 2)
    joint_request(cluster, JointThermostat::AtomicRequestType::CommitWrite,
      ids: [JointThermostat::ATTR_PRESETS]).as(Matter::InteractionModel::Status)
      .status.should eq(JointStatus::InvalidInState)
    joint_request(cluster, JointThermostat::AtomicRequestType::RollbackWrite)
      .as(JointThermostat::AtomicResponse).status_code.should eq(JointStatus::Success)
    cluster.presets.should be_empty
    cluster.schedules.should be_empty
  end

  it "validates references against both final lists before publishing either" do
    cluster = joint_cluster
    joint_actor(cluster)
    joint_request(cluster, JointThermostat::AtomicRequestType::BeginWrite,
      timeout: 3_000_u16).as(JointThermostat::AtomicResponse)
    joint_write_list(cluster, JointThermostat::ATTR_PRESETS,
      [] of JointThermostat::Preset, joint_new_preset).should eq([JointStatus::Success] * 2)
    joint_write_list(cluster, JointThermostat::ATTR_SCHEDULES,
      [] of JointThermostat::Schedule, joint_new_schedule).should eq([JointStatus::Success] * 2)
    joint_write_list(cluster, JointThermostat::ATTR_PRESETS,
      [] of JointThermostat::Preset).should eq([JointStatus::Success])
    joint_actor(cluster)
    rejected = joint_request(cluster, JointThermostat::AtomicRequestType::CommitWrite)
      .as(JointThermostat::AtomicResponse)
    rejected.status_code.should eq(JointStatus::Failure)
    rejected.attribute_status.first.status_code.should eq(JointStatus::ConstraintError)
    cluster.presets.should be_empty
    cluster.schedules.should be_empty
  end

  it "accepts reversed attribute order and drops both reservations on fabric removal" do
    cluster = joint_cluster
    joint_actor(cluster)
    reversed = [JointThermostat::ATTR_SCHEDULES, JointThermostat::ATTR_PRESETS]
    begun = joint_request(cluster, JointThermostat::AtomicRequestType::BeginWrite,
      ids: reversed, timeout: 3_000_u16).as(JointThermostat::AtomicResponse)
    begun.attribute_status.map(&.attribute_id).should eq(reversed)
    joint_write_list(cluster, JointThermostat::ATTR_PRESETS,
      [] of JointThermostat::Preset, joint_new_preset).should eq([JointStatus::Success] * 2)
    cluster.remove_fabric(2_u8)
    joint_actor(cluster)
    joint_request(cluster, JointThermostat::AtomicRequestType::RollbackWrite, ids: reversed)
      .as(JointThermostat::AtomicResponse).status_code.should eq(JointStatus::Success)
    joint_request(cluster, JointThermostat::AtomicRequestType::BeginWrite,
      timeout: 3_000_u16).as(JointThermostat::AtomicResponse)
    cluster.remove_fabric(1_u8)
    joint_request(cluster, JointThermostat::AtomicRequestType::CommitWrite)
      .as(Matter::InteractionModel::Status).status.should eq(JointStatus::InvalidInState)
    cluster.presets.should be_empty
    cluster.schedules.should be_empty
  end

  it "rejects a later preset-only removal while a committed schedule references it" do
    cluster = joint_cluster
    joint_actor(cluster)
    joint_request(cluster, JointThermostat::AtomicRequestType::BeginWrite,
      timeout: 3_000_u16).as(JointThermostat::AtomicResponse)
    joint_write_list(cluster, JointThermostat::ATTR_PRESETS,
      [] of JointThermostat::Preset, joint_new_preset).should eq([JointStatus::Success] * 2)
    joint_write_list(cluster, JointThermostat::ATTR_SCHEDULES,
      [] of JointThermostat::Schedule, joint_new_schedule).should eq([JointStatus::Success] * 2)
    joint_actor(cluster)
    joint_request(cluster, JointThermostat::AtomicRequestType::CommitWrite)
      .as(JointThermostat::AtomicResponse).status_code.should eq(JointStatus::Success)

    joint_request(cluster, JointThermostat::AtomicRequestType::BeginWrite,
      ids: [JointThermostat::ATTR_PRESETS], timeout: 3_000_u16).as(JointThermostat::AtomicResponse)
    joint_write_list(cluster, JointThermostat::ATTR_PRESETS,
      [] of JointThermostat::Preset).should eq([JointStatus::Success])
    joint_actor(cluster)
    failed = joint_request(cluster, JointThermostat::AtomicRequestType::CommitWrite,
      ids: [JointThermostat::ATTR_PRESETS]).as(JointThermostat::AtomicResponse)
    failed.status_code.should eq(JointStatus::Failure)
    failed.attribute_status.first.status_code.should eq(JointStatus::ConstraintError)
    cluster.presets.first.preset_handle.should eq(Bytes[1_u8])
    cluster.schedules.first.preset_handle.should eq(Bytes[1_u8])
  end

  it "abandons both lists on timeout and rejects a stale conditional write atomically" do
    cluster = joint_cluster
    Timecop.freeze(Time.utc) do
      joint_actor(cluster)
      joint_request(cluster, JointThermostat::AtomicRequestType::BeginWrite,
        timeout: 100_u16).as(JointThermostat::AtomicResponse)
      joint_write_list(cluster, JointThermostat::ATTR_PRESETS,
        [] of JointThermostat::Preset, joint_new_preset).should eq([JointStatus::Success] * 2)
      Timecop.travel(Time.utc + 1.second) do
        joint_actor(cluster)
        joint_request(cluster, JointThermostat::AtomicRequestType::CommitWrite)
          .as(Matter::InteractionModel::Status).status.should eq(JointStatus::InvalidInState)
      end
    end
    cluster.presets.should be_empty
    cluster.schedules.should be_empty

    joint_actor(cluster)
    version = cluster.data_version
    joint_request(cluster, JointThermostat::AtomicRequestType::BeginWrite,
      timeout: 3_000_u16).as(JointThermostat::AtomicResponse)
    joint_write_list(cluster, JointThermostat::ATTR_PRESETS,
      [] of JointThermostat::Preset, joint_new_preset, data_version: version)
      .should eq([JointStatus::Success] * 2)
    joint_write_list(cluster, JointThermostat::ATTR_SCHEDULES,
      [] of JointThermostat::Schedule, joint_new_schedule, data_version: version)
      .should eq([JointStatus::Success] * 2)
    cluster.occupied_heating_setpoint = 1900_i16
    joint_actor(cluster)
    rejected = joint_request(cluster, JointThermostat::AtomicRequestType::CommitWrite)
      .as(JointThermostat::AtomicResponse)
    rejected.status_code.should eq(JointStatus::Failure)
    rejected.attribute_status.first.status_code.should eq(JointStatus::DataVersionMismatch)
    cluster.presets.should be_empty
    cluster.schedules.should be_empty
  end
end
