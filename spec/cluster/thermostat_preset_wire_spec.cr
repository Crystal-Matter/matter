require "../spec_helper"

private alias PresetThermostat = Matter::Cluster::Thermostat
private alias PresetCode = Matter::InteractionModel::StatusCode

# Production Thermostat refuses PRES until the remaining conformance gate is
# complete. This subclass exercises the already-declared wire paths in specs.
private class WireReadyThermostat < PresetThermostat
  protected def preset_wire_ready? : Bool
    true
  end

  protected def preset_wire_ready?(command_id : UInt32) : Bool
    true
  end
end

private class PredictableHandleThermostat < WireReadyThermostat
  @candidate_attempts = 0

  protected def candidate_preset_handle : Bytes
    @candidate_attempts += 1
    Bytes[@candidate_attempts.to_u8]
  end
end

private def wire_preset_features : PresetThermostat::Feature
  PresetThermostat::Feature::Cooling | PresetThermostat::Feature::Heating |
    PresetThermostat::Feature::Presets
end

private def wire_preset_actor(cluster : PresetThermostat, *, fabric : UInt8 = 1_u8,
                              subject : UInt64 = 11_u64) : Nil
  cluster.request_is_case_session = true
  cluster.request_fabric_index = fabric
  cluster.request_peer_node_id = subject
end

private def wire_preset_begin(cluster : PresetThermostat) : PresetThermostat::AtomicResponse
  wire_preset_actor(cluster)
  cluster.atomic_request(PresetThermostat::AtomicRequest.new(
    PresetThermostat::AtomicRequestType::BeginWrite,
    [PresetThermostat::ATTR_PRESETS], 3_000_u16)).as(PresetThermostat::AtomicResponse)
end

private def wire_preset_write(cluster : PresetThermostat, data : Array(Matter::InteractionModel::AttributeDataIB),
                              *, subject : UInt64 = 11_u64) : Array(PresetCode)
  endpoint = cluster.endpoint_id.number
  Matter::Protocol::IMHandler.write_attributes(data,
    { {endpoint, PresetThermostat::CLUSTER_ID} => cluster.as(Matter::Cluster::Base) },
    session_id: 9_u16, is_case_session: true, fabric_index: 1_u8,
    peer_subject_ids: [subject]).map { |status| PresetCode.new(status.status.status) }
end

private def wire_preset_data(cluster : PresetThermostat, value, *, append : Bool = false,
                             data_version : UInt32? = nil) : Matter::InteractionModel::AttributeDataIB
  path = Matter::InteractionModel::AttributePath.new(endpoint: cluster.endpoint_id.number,
    cluster: PresetThermostat::CLUSTER_ID, attribute: PresetThermostat::ATTR_PRESETS,
    list_index_null: append)
  Matter::InteractionModel::AttributeDataIB.new(path, TLV::Serializable.serialize_value(value, nil), data_version)
end

private def wire_preset_read(cluster : PresetThermostat, *, fabric : UInt8 = 1_u8,
                             subject : UInt64 = 11_u64) : Array(PresetThermostat::Preset)
  endpoint = cluster.endpoint_id.number
  path = Matter::InteractionModel::AttributePath.new(endpoint: endpoint,
    cluster: PresetThermostat::CLUSTER_ID, attribute: PresetThermostat::ATTR_PRESETS)
  reports = Matter::Protocol::IMHandler.read_attributes([path],
    { {endpoint, PresetThermostat::CLUSTER_ID} => cluster.as(Matter::Cluster::Base) },
    fabric_index: fabric, is_case_session: true, peer_subject_ids: [subject])
  data = reports.first.attribute_data || raise "expected Presets data"
  TLV::Serializable.deserialize_value(data.data, Array(PresetThermostat::Preset))
end

private def wire_preset_invoke(cluster : PresetThermostat, command_id : UInt32, request,
                               *, subject : UInt64 = 11_u64) : Matter::InteractionModel::InvokeResponseIB
  endpoint = cluster.endpoint_id.number
  path = Matter::InteractionModel::CommandPath.new(endpoint, PresetThermostat::CLUSTER_ID, command_id)
  command = Matter::InteractionModel::CommandDataIBTlv.new(path, TLV::Serializable.serialize_value(request, nil))
  Matter::Protocol::IMHandler.invoke_commands([command],
    { {endpoint, PresetThermostat::CLUSTER_ID} => cluster.as(Matter::Cluster::Base) },
    session_id: 9_u64, is_case_session: true, fabric_index: 1_u8,
    peer_subject_ids: [subject]).first
end

describe "Thermostat Presets wire preparation" do
  it "declares the mandatory PRES metadata while keeping production instances gated" do
    expect_raises(ArgumentError) { build(PresetThermostat, feature_map: wire_preset_features) }
    hidden = build(PresetThermostat)
    hidden.get_attribute_metadata(0x48_u32).should be_nil
    hidden.get_command_metadata(0x06_u32).should be_nil

    cluster = build(WireReadyThermostat, feature_map: wire_preset_features)
    cluster.configure_presets([PresetThermostat::PresetType.new(PresetThermostat::PresetScenario::Sleep, 2_u8,
      PresetThermostat::PresetTypeFeatures::SupportsNames)],
      [] of PresetThermostat::Preset)
    [0x48_u32, 0x4a_u32, 0x4e_u32, 0x50_u32].each do |id|
      cluster.get_attribute_metadata(id).should_not be_nil
    end
    presets_metadata = cluster.get_attribute_metadata(0x50_u32) || raise "expected Presets metadata"
    presets_metadata.write_access.should eq(Matter::InteractionModel::EntryPrivilege::Manage)
    cluster.get_command_metadata(0x06_u32).should_not be_nil
    atomic_metadata = cluster.get_command_metadata(0xfe_u32) || raise "expected AtomicRequest metadata"
    atomic_metadata.access.should eq(Matter::InteractionModel::EntryPrivilege::Manage)
    before = cluster.data_version
    wire_preset_write(cluster, [wire_preset_data(cluster, [] of PresetThermostat::Preset)])
      .should eq([PresetCode::InvalidInState])
    cluster.data_version.should eq(before)
    read(cluster, 0x4a_u32).should eq(2_u8)
    read_tlv(cluster, 0x48_u32).as_list.size.should eq(1)
    read(cluster, 0x4e_u32).should be_nil
    expect_raises(ArgumentError, /automatic preset transitions/) do
      cluster.configure_presets([PresetThermostat::PresetType.new(PresetThermostat::PresetScenario::Sleep, 1_u8,
        PresetThermostat::PresetTypeFeatures::Automatic)], [] of PresetThermostat::Preset)
    end
  end

  it "dispatches AtomicRequest and SetActivePreset with their canonical command IDs" do
    cluster = build(WireReadyThermostat, feature_map: wire_preset_features)
    handle = Bytes[1_u8]
    cluster.configure_presets([PresetThermostat::PresetType.new(PresetThermostat::PresetScenario::Sleep, 1_u8)],
      [PresetThermostat::Preset.new(handle, PresetThermostat::PresetScenario::Sleep,
        nil, 2700_i16, 1800_i16, false)])
    changed = [] of UInt32
    cluster.on_attribute_changed = ->(_endpoint : UInt16, _cluster : UInt32, attribute : UInt32) {
      changed << attribute
      nil
    }
    started = wire_preset_invoke(cluster, PresetThermostat::CMD_ATOMIC_REQUEST,
      PresetThermostat::AtomicRequest.new(PresetThermostat::AtomicRequestType::BeginWrite,
        [PresetThermostat::ATTR_PRESETS], 500_u16))
    started_data = started.command_data || raise "expected AtomicResponse"
    started_data.command_path.command.should eq(PresetThermostat::CMD_ATOMIC_RESPONSE)
    fields = started_data.command_fields || raise "expected AtomicResponse fields"
    response = PresetThermostat::AtomicResponse.from_tlv(fields)
    response.status_code.should eq(PresetCode::Success)
    wire_preset_invoke(cluster, PresetThermostat::CMD_ATOMIC_REQUEST,
      PresetThermostat::AtomicRequest.new(PresetThermostat::AtomicRequestType::RollbackWrite,
        [PresetThermostat::ATTR_PRESETS])).command_data.should_not be_nil
    activated = wire_preset_invoke(cluster, PresetThermostat::CMD_SET_ACTIVE_PRESET,
      PresetThermostat::SetActivePresetRequest.new(handle))
    activated_status = activated.command_status || raise "expected SetActivePreset status"
    activated_status.status.status.should eq(PresetCode::Success.value)
    read(cluster, PresetThermostat::ATTR_ACTIVE_PRESET_HANDLE).should eq(handle)
    changed.should contain(PresetThermostat::ATTR_ACTIVE_PRESET_HANDLE)
    changed.clear
    cluster.occupied_heating_setpoint = 1900_i16
    read(cluster, PresetThermostat::ATTR_ACTIVE_PRESET_HANDLE).should be_nil
    changed.should contain(PresetThermostat::ATTR_ACTIVE_PRESET_HANDLE)
  end

  it "commits a whole-list IM write through the AtomicRequest wire command" do
    cluster = build(WireReadyThermostat, feature_map: wire_preset_features)
    handle = Bytes[1_u8]
    cluster.configure_presets([PresetThermostat::PresetType.new(PresetThermostat::PresetScenario::Sleep, 1_u8)],
      [PresetThermostat::Preset.new(handle, PresetThermostat::PresetScenario::Sleep,
        nil, 2700_i16, 1800_i16, true)])
    changed = PresetThermostat::Preset.new(handle, PresetThermostat::PresetScenario::Sleep,
      nil, 2700_i16, 1900_i16, true)

    begun = wire_preset_invoke(cluster, PresetThermostat::CMD_ATOMIC_REQUEST,
      PresetThermostat::AtomicRequest.new(PresetThermostat::AtomicRequestType::BeginWrite,
        [PresetThermostat::ATTR_PRESETS], 9_000_u16))
    begin_fields = begun.command_data.try(&.command_fields) || raise "expected BeginWrite response"
    PresetThermostat::AtomicResponse.from_tlv(begin_fields).timeout.should eq(9_000_u16)
    wire_preset_write(cluster, [wire_preset_data(cluster, [changed])]).should eq([PresetCode::Success])
    cluster.presets.first.heating_setpoint.should eq(1800_i16)
    wire_preset_read(cluster).first.heating_setpoint.should eq(1900_i16)

    committed = wire_preset_invoke(cluster, PresetThermostat::CMD_ATOMIC_REQUEST,
      PresetThermostat::AtomicRequest.new(PresetThermostat::AtomicRequestType::CommitWrite,
        [PresetThermostat::ATTR_PRESETS]))
    commit_fields = committed.command_data.try(&.command_fields) || raise "expected CommitWrite response"
    PresetThermostat::AtomicResponse.from_tlv(commit_fields).status_code.should eq(PresetCode::Success)
    cluster.presets.first.heating_setpoint.should eq(1900_i16)
  end

  it "reports ActivePresetChange when TEVT and PRES are combined" do
    cluster = build(WireReadyThermostat,
      feature_map: wire_preset_features | PresetThermostat::Feature::Events)
    handle = Bytes[1_u8]
    cluster.configure_presets([PresetThermostat::PresetType.new(PresetThermostat::PresetScenario::Sleep, 1_u8)],
      [PresetThermostat::Preset.new(handle, PresetThermostat::PresetScenario::Sleep,
        nil, 2700_i16, 1800_i16, false)])
    events = [] of TLV::Any
    cluster.on_event_emitted = ->(_endpoint : UInt16, _cluster : UInt32, id : UInt32, _priority : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) {
      events << data if id == PresetThermostat::EVENT_ACTIVE_PRESET_CHANGE
      nil
    }
    cluster.get_event_metadata(PresetThermostat::EVENT_ACTIVE_PRESET_CHANGE).should_not be_nil
    cluster.activate_preset(PresetThermostat::SetActivePresetRequest.new(handle)).status.should eq(PresetCode::Success)
    cluster.occupied_heating_setpoint = 1900_i16
    events.size.should eq(2)
    first = PresetThermostat::ActivePresetChangeEvent.from_tlv(events[0])
    first.previous_preset_handle.should be_nil
    first.current_preset_handle.should eq(handle)
    second = PresetThermostat::ActivePresetChangeEvent.from_tlv(events[1])
    second.previous_preset_handle.should eq(handle)
    second.current_preset_handle.should be_nil
  end

  it "enforces Manage privilege for AtomicRequest and Presets writes" do
    cluster = build(WireReadyThermostat, feature_map: wire_preset_features)
    cluster.configure_presets([PresetThermostat::PresetType.new(PresetThermostat::PresetScenario::Sleep, 1_u8)],
      [] of PresetThermostat::Preset)
    acl = build(Matter::Cluster::AccessControl, 0)
    clusters = {
      {0_u16, Matter::Cluster::AccessControl::CLUSTER_ID}        => acl.as(Matter::Cluster::Base),
      {cluster.endpoint_id.number, PresetThermostat::CLUSTER_ID} => cluster.as(Matter::Cluster::Base),
    }
    privilege = Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Operate
    acl.acl << Matter::Cluster::AccessControl::AccessControlEntry.new(privilege,
      Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
      [11_u64], nil, 1_u8)
    path = Matter::InteractionModel::CommandPath.new(cluster.endpoint_id.number,
      PresetThermostat::CLUSTER_ID, PresetThermostat::CMD_ATOMIC_REQUEST)
    request = PresetThermostat::AtomicRequest.new(PresetThermostat::AtomicRequestType::BeginWrite,
      [PresetThermostat::ATTR_PRESETS], 500_u16)
    command = Matter::InteractionModel::CommandDataIBTlv.new(path, request.to_tlv)
    denied = Matter::Protocol::IMHandler.invoke_commands([command], clusters,
      is_case_session: true, fabric_index: 1_u8, peer_subject_ids: [11_u64]).first
    denied.command_status.as(Matter::InteractionModel::CommandStatusIB).status.status.should eq(PresetCode::UnsupportedAccess.value)

    acl.acl.clear
    privilege = Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Manage
    acl.acl << Matter::Cluster::AccessControl::AccessControlEntry.new(privilege,
      Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
      [11_u64], nil, 1_u8)
    allowed = Matter::Protocol::IMHandler.invoke_commands([command], clusters,
      is_case_session: true, fabric_index: 1_u8, peer_subject_ids: [11_u64]).first
    allowed.command_data.should_not be_nil

    write = wire_preset_data(cluster, [] of PresetThermostat::Preset)
    acl.acl.clear
    acl.acl << Matter::Cluster::AccessControl::AccessControlEntry.new(
      Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Operate,
      Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
      [11_u64], nil, 1_u8)
    denied_write = Matter::Protocol::IMHandler.write_attributes([write], clusters,
      is_case_session: true, fabric_index: 1_u8, peer_subject_ids: [11_u64]).first
    denied_write.status.status.should eq(PresetCode::UnsupportedAccess.value)
    acl.acl.clear
    acl.acl << Matter::Cluster::AccessControl::AccessControlEntry.new(privilege,
      Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
      [11_u64], nil, 1_u8)
    allowed_write = Matter::Protocol::IMHandler.write_attributes([write], clusters,
      is_case_session: true, fabric_index: 1_u8, peer_subject_ids: [11_u64]).first
    allowed_write.status.status.should eq(PresetCode::Success.value)
  end

  it "stages a replacement and appends against the pending list, with peer-private reads and one commit" do
    cluster = build(WireReadyThermostat, feature_map: wire_preset_features)
    cluster.configure_presets([PresetThermostat::PresetType.new(PresetThermostat::PresetScenario::Sleep, 2_u8,
      PresetThermostat::PresetTypeFeatures::SupportsNames)],
      [] of PresetThermostat::Preset)
    before = cluster.data_version
    wire_preset_begin(cluster).status_code.should eq(PresetCode::Success)
    first = PresetThermostat::Preset.new(nil, PresetThermostat::PresetScenario::Sleep,
      nil, 2700_i16, 1800_i16, nil)
    second = PresetThermostat::Preset.new(nil, PresetThermostat::PresetScenario::Sleep,
      "Second", 2600_i16, 1900_i16, nil)
    writes = [wire_preset_data(cluster, [] of PresetThermostat::Preset),
              wire_preset_data(cluster, first, append: true),
              wire_preset_data(cluster, second, append: true)]
    wire_preset_write(cluster, writes).should eq([PresetCode::Success] * 3)
    cluster.presets.should be_empty
    pending = wire_preset_read(cluster)
    pending.size.should eq(2)
    pending.map(&.preset_handle).uniq!.size.should eq(2)
    wire_preset_read(cluster, subject: 12_u64).should be_empty
    wire_preset_read(cluster, fabric: 2_u8).should be_empty
    cluster.data_version.should eq(before)
    wire_preset_actor(cluster)
    committed = cluster.atomic_request(PresetThermostat::AtomicRequest.new(
      PresetThermostat::AtomicRequestType::CommitWrite,
      [PresetThermostat::ATTR_PRESETS])).as(PresetThermostat::AtomicResponse)
    committed.status_code.should eq(PresetCode::Success)
    cluster.presets.size.should eq(2)
    cluster.data_version.should eq(before &+ 1_u32)
  end

  it "can clear and append an existing built-in preset before adding a new one" do
    built_in = PresetThermostat::Preset.new(Bytes[1_u8], PresetThermostat::PresetScenario::Sleep,
      nil, 2700_i16, 1800_i16, true)
    cluster = build(WireReadyThermostat, feature_map: wire_preset_features,
      preset_types: [PresetThermostat::PresetType.new(PresetThermostat::PresetScenario::Sleep, 2_u8,
        PresetThermostat::PresetTypeFeatures::SupportsNames)],
      presets: [built_in])
    wire_preset_begin(cluster)
    addition = PresetThermostat::Preset.new(nil, PresetThermostat::PresetScenario::Sleep,
      "New", 2600_i16, 1900_i16, nil)
    writes = [wire_preset_data(cluster, [] of PresetThermostat::Preset),
              wire_preset_data(cluster, built_in, append: true),
              wire_preset_data(cluster, addition, append: true)]
    wire_preset_write(cluster, writes).should eq([PresetCode::Success] * 3)
    wire_preset_actor(cluster)
    cluster.atomic_request(PresetThermostat::AtomicRequest.new(
      PresetThermostat::AtomicRequestType::CommitWrite,
      [PresetThermostat::ATTR_PRESETS])).as(PresetThermostat::AtomicResponse).status_code.should eq(PresetCode::Success)
    cluster.presets.size.should eq(2)
    cluster.presets.first.built_in.should be_true
  end

  it "allows multiple unnamed presets within a scenario when capacity permits" do
    cluster = build(WireReadyThermostat, feature_map: wire_preset_features,
      preset_types: [PresetThermostat::PresetType.new(PresetThermostat::PresetScenario::Sleep, 2_u8)])
    wire_preset_begin(cluster)
    first = PresetThermostat::Preset.new(nil, PresetThermostat::PresetScenario::Sleep,
      nil, 2700_i16, 1800_i16, nil)
    second = PresetThermostat::Preset.new(nil, PresetThermostat::PresetScenario::Sleep,
      nil, 2600_i16, 1900_i16, nil)
    wire_preset_write(cluster, [wire_preset_data(cluster, [first, second])]).should eq([PresetCode::Success])
    cluster.presets.should be_empty
    wire_preset_read(cluster).map(&.preset_handle).uniq!.size.should eq(2)
  end

  it "creates null-handle presets in whole-list atomic writes and keeps them private until commit" do
    types = [PresetThermostat::PresetType.new(PresetThermostat::PresetScenario::Sleep, 2_u8)]
    cluster = build(PredictableHandleThermostat, feature_map: wire_preset_features, preset_types: types)
    creation = PresetThermostat::Preset.new(nil, PresetThermostat::PresetScenario::Sleep,
      nil, 2700_i16, 1800_i16, nil)
    wire_preset_begin(cluster).status_code.should eq(PresetCode::Success)
    wire_preset_write(cluster, [wire_preset_data(cluster, [creation])]).should eq([PresetCode::Success])
    wire_preset_read(cluster).first.preset_handle.should eq(Bytes[1_u8])
    wire_preset_read(cluster, subject: 12_u64).should be_empty
    cluster.presets.should be_empty
    wire_preset_actor(cluster)
    cluster.atomic_request(PresetThermostat::AtomicRequest.new(
      PresetThermostat::AtomicRequestType::RollbackWrite,
      [PresetThermostat::ATTR_PRESETS])).as(PresetThermostat::AtomicResponse).status_code.should eq(PresetCode::Success)
    cluster.presets.should be_empty

    wire_preset_begin(cluster).status_code.should eq(PresetCode::Success)
    wire_preset_write(cluster, [wire_preset_data(cluster, [creation])]).should eq([PresetCode::Success])
    wire_preset_read(cluster).first.preset_handle.should eq(Bytes[2_u8])
    wire_preset_actor(cluster)
    cluster.atomic_request(PresetThermostat::AtomicRequest.new(
      PresetThermostat::AtomicRequestType::CommitWrite,
      [PresetThermostat::ATTR_PRESETS])).as(PresetThermostat::AtomicResponse).status_code.should eq(PresetCode::Success)
    cluster.presets.first.preset_handle.should eq(Bytes[2_u8])
    restored = build(PredictableHandleThermostat, feature_map: wire_preset_features, preset_types: types)
    restored.restore_state(cluster.save_state)
    restored.presets.first.preset_handle.should eq(Bytes[2_u8])
  end

  it "returns Busy when another operational peer writes during an atomic reservation" do
    cluster = build(WireReadyThermostat, feature_map: wire_preset_features,
      preset_types: [PresetThermostat::PresetType.new(PresetThermostat::PresetScenario::Sleep, 1_u8)])
    wire_preset_begin(cluster).status_code.should eq(PresetCode::Success)
    wire_preset_write(cluster, [wire_preset_data(cluster, [] of PresetThermostat::Preset)],
      subject: 12_u64).should eq([PresetCode::Busy])
    wire_preset_read(cluster, subject: 12_u64).should be_empty
  end

  it "encodes PresetTypeFeatures as the canonical bitmap16" do
    type = PresetThermostat::PresetType.new(PresetThermostat::PresetScenario::Sleep, 1_u8,
      PresetThermostat::PresetTypeFeatures::SupportsNames)
    type.to_tlv(nil).as_structure[2_u8].value.class.name.should eq("UInt16")
  end

  it "discards pending appends on rollback and timeout" do
    cluster = build(WireReadyThermostat, feature_map: wire_preset_features)
    cluster.configure_presets([PresetThermostat::PresetType.new(PresetThermostat::PresetScenario::Sleep, 2_u8)],
      [] of PresetThermostat::Preset)
    first = PresetThermostat::Preset.new(nil, PresetThermostat::PresetScenario::Sleep,
      nil, 2700_i16, 1800_i16, nil)
    wire_preset_begin(cluster)
    wire_preset_write(cluster, [wire_preset_data(cluster, [] of PresetThermostat::Preset),
                                wire_preset_data(cluster, first, append: true)]).should eq([PresetCode::Success] * 2)
    wire_preset_actor(cluster)
    cluster.atomic_request(PresetThermostat::AtomicRequest.new(
      PresetThermostat::AtomicRequestType::RollbackWrite,
      [PresetThermostat::ATTR_PRESETS])).as(PresetThermostat::AtomicResponse).status_code.should eq(PresetCode::Success)
    wire_preset_read(cluster).should be_empty

    Timecop.freeze(Time.utc) do
      wire_preset_actor(cluster)
      cluster.atomic_request(PresetThermostat::AtomicRequest.new(
        PresetThermostat::AtomicRequestType::BeginWrite,
        [PresetThermostat::ATTR_PRESETS], 100_u16)).as(PresetThermostat::AtomicResponse)
      wire_preset_write(cluster, [wire_preset_data(cluster, [] of PresetThermostat::Preset),
                                  wire_preset_data(cluster, first, append: true)]).should eq([PresetCode::Success] * 2)
      Timecop.travel(Time.utc + 1.second) do
        wire_preset_read(cluster).should be_empty
      end
    end
  end

  it "rejects an atomic commit when a versioned list write becomes stale" do
    cluster = build(WireReadyThermostat, feature_map: wire_preset_features,
      preset_types: [PresetThermostat::PresetType.new(PresetThermostat::PresetScenario::Sleep, 1_u8)])
    version = cluster.data_version
    wire_preset_begin(cluster).status_code.should eq(PresetCode::Success)
    created = PresetThermostat::Preset.new(nil, PresetThermostat::PresetScenario::Sleep,
      nil, 2700_i16, 1800_i16, nil)
    writes = [wire_preset_data(cluster, [] of PresetThermostat::Preset, data_version: version),
              wire_preset_data(cluster, created, append: true, data_version: version)]
    wire_preset_write(cluster, writes).should eq([PresetCode::Success] * 2)

    cluster.occupied_heating_setpoint = 1900_i16
    wire_preset_actor(cluster)
    response = cluster.atomic_request(PresetThermostat::AtomicRequest.new(
      PresetThermostat::AtomicRequestType::CommitWrite,
      [PresetThermostat::ATTR_PRESETS])).as(PresetThermostat::AtomicResponse)
    response.status_code.should eq(PresetCode::Failure)
    response.attribute_status.first.status_code.should eq(PresetCode::DataVersionMismatch)
    cluster.presets.should be_empty
    cluster.atomic_request(PresetThermostat::AtomicRequest.new(
      PresetThermostat::AtomicRequestType::CommitWrite,
      [PresetThermostat::ATTR_PRESETS])).as(Matter::InteractionModel::Status).status
      .should eq(PresetCode::InvalidInState)
  end

  it "restores committed presets when the type configuration is supplied at construction" do
    types = [PresetThermostat::PresetType.new(PresetThermostat::PresetScenario::Sleep, 1_u8)]
    cluster = build(WireReadyThermostat, feature_map: wire_preset_features, preset_types: types)
    first = PresetThermostat::Preset.new(nil, PresetThermostat::PresetScenario::Sleep,
      nil, 2700_i16, 1800_i16, nil)
    wire_preset_begin(cluster)
    wire_preset_write(cluster, [wire_preset_data(cluster, [] of PresetThermostat::Preset),
                                wire_preset_data(cluster, first, append: true)]).should eq([PresetCode::Success] * 2)
    wire_preset_actor(cluster)
    cluster.atomic_request(PresetThermostat::AtomicRequest.new(
      PresetThermostat::AtomicRequestType::CommitWrite,
      [PresetThermostat::ATTR_PRESETS])).as(PresetThermostat::AtomicResponse).status_code.should eq(PresetCode::Success)
    saved = cluster.save_state
    restored = build(WireReadyThermostat, feature_map: wire_preset_features, preset_types: types)
    restored.restore_state(saved)
    restored.presets.first.cooling_setpoint.should eq(2700_i16)
  end

  it "never reuses a deleted generated handle after persistence and restart" do
    types = [PresetThermostat::PresetType.new(PresetThermostat::PresetScenario::Sleep, 1_u8)]
    first = build(PredictableHandleThermostat, feature_map: wire_preset_features, preset_types: types)
    creation = PresetThermostat::Preset.new(nil, PresetThermostat::PresetScenario::Sleep,
      nil, 2700_i16, 1800_i16, nil)
    wire_preset_begin(first)
    wire_preset_write(first, [wire_preset_data(first, [] of PresetThermostat::Preset),
                              wire_preset_data(first, creation, append: true)]).should eq([PresetCode::Success] * 2)
    wire_preset_actor(first)
    first.atomic_request(PresetThermostat::AtomicRequest.new(
      PresetThermostat::AtomicRequestType::CommitWrite,
      [PresetThermostat::ATTR_PRESETS])).as(PresetThermostat::AtomicResponse).status_code.should eq(PresetCode::Success)
    first.presets.first.preset_handle.should eq(Bytes[1_u8])

    wire_preset_begin(first)
    wire_preset_write(first, [wire_preset_data(first, [] of PresetThermostat::Preset)]).should eq([PresetCode::Success])
    wire_preset_actor(first)
    first.atomic_request(PresetThermostat::AtomicRequest.new(
      PresetThermostat::AtomicRequestType::CommitWrite,
      [PresetThermostat::ATTR_PRESETS])).as(PresetThermostat::AtomicResponse).status_code.should eq(PresetCode::Success)
    first.presets.should be_empty

    restored = build(PredictableHandleThermostat, feature_map: wire_preset_features, preset_types: types)
    restored.restore_state(first.save_state)
    wire_preset_begin(restored)
    wire_preset_write(restored, [wire_preset_data(restored, [] of PresetThermostat::Preset),
                                 wire_preset_data(restored, creation, append: true)]).should eq([PresetCode::Success] * 2)
    wire_preset_actor(restored)
    restored.atomic_request(PresetThermostat::AtomicRequest.new(
      PresetThermostat::AtomicRequestType::CommitWrite,
      [PresetThermostat::ATTR_PRESETS])).as(PresetThermostat::AtomicResponse).status_code.should eq(PresetCode::Success)
    restored.presets.first.preset_handle.should eq(Bytes[2_u8])
  end

  it "restores preset state saved before handle history was added" do
    types = [PresetThermostat::PresetType.new(PresetThermostat::PresetScenario::Sleep, 1_u8)]
    original = build(WireReadyThermostat, feature_map: wire_preset_features,
      preset_types: types,
      presets: [PresetThermostat::Preset.new(Bytes[1_u8], PresetThermostat::PresetScenario::Sleep,
        nil, 2700_i16, 1800_i16, false)])
    legacy = original.save_state
    legacy_state = legacy[PresetThermostat::PRESET_STATE_KEY].as(Matter::Storage::Document)
    legacy_state.delete("used_preset_handles")
    restored = build(WireReadyThermostat, feature_map: wire_preset_features, preset_types: types)
    restored.restore_state(legacy)
    restored.presets.first.preset_handle.should eq(Bytes[1_u8])
  end

  it "discards only the removed fabric's pending atomic transaction" do
    cluster = build(WireReadyThermostat, feature_map: wire_preset_features,
      preset_types: [PresetThermostat::PresetType.new(PresetThermostat::PresetScenario::Sleep, 1_u8)])
    creation = PresetThermostat::Preset.new(nil, PresetThermostat::PresetScenario::Sleep,
      nil, 2700_i16, 1800_i16, nil)
    wire_preset_begin(cluster)
    wire_preset_write(cluster, [wire_preset_data(cluster, [] of PresetThermostat::Preset),
                                wire_preset_data(cluster, creation, append: true)]).should eq([PresetCode::Success] * 2)

    cluster.remove_fabric(2_u8)
    wire_preset_read(cluster).size.should eq(1)
    cluster.remove_fabric(1_u8)
    wire_preset_read(cluster).should be_empty
    wire_preset_actor(cluster)
    cluster.atomic_request(PresetThermostat::AtomicRequest.new(
      PresetThermostat::AtomicRequestType::CommitWrite,
      [PresetThermostat::ATTR_PRESETS])).as(Matter::InteractionModel::Status).status
      .should eq(PresetCode::InvalidInState)
  end
end
