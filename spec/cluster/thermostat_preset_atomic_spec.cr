require "../spec_helper"

private alias Thermostat = Matter::Cluster::Thermostat
private alias AtomicType = Thermostat::AtomicRequestType
private alias IMCode = Matter::InteractionModel::StatusCode

private def atomic_actor(cluster : Thermostat, *, fabric : UInt8 = 1_u8,
                         subject : UInt64 = 11_u64) : Nil
  cluster.request_is_case_session = true
  cluster.request_fabric_index = fabric
  cluster.request_peer_node_id = subject
end

private def atomic_request(cluster : Thermostat, type : AtomicType,
                           timeout : UInt16? = nil) : Thermostat::AtomicResponse | Matter::InteractionModel::Status
  cluster.atomic_request(Thermostat::AtomicRequest.new(type, [0x50_u32], timeout))
end

private def atomic_write(cluster : Thermostat, presets : Array(Thermostat::Preset), *,
                         fabric : UInt8 = 1_u8, subject : UInt64 = 11_u64,
                         wire_session : UInt16 = 7_u16) : IMCode
  endpoint = cluster.endpoint_id.number
  path = Matter::InteractionModel::AttributePath.new(endpoint: endpoint,
    cluster: Thermostat::CLUSTER_ID, attribute: 0x50_u32)
  existing = presets.reject { |preset| preset.preset_handle.nil? }
  data = Matter::InteractionModel::AttributeDataIB.new(path, TLV::Serializable.serialize_value(existing, nil))
  statuses = Matter::Protocol::IMHandler.write_attributes([data],
    { {endpoint, Thermostat::CLUSTER_ID} => cluster.as(Matter::Cluster::Base) },
    session_id: wire_session, is_case_session: true,
    fabric_index: fabric, peer_subject_ids: [subject])
  result = IMCode.new(statuses.first.status.status)
  return result unless result == IMCode::Success

  presets.each do |preset|
    next unless preset.preset_handle.nil?
    result = cluster.append_preset(TLV::Serializable.serialize_value(preset, nil)).status
    return result unless result == IMCode::Success
  end
  result
end

describe "Thermostat preset atomic-write foundation" do
  it "encodes the canonical AtomicRequest and AtomicResponse fields" do
    request = Thermostat::AtomicRequest.new(AtomicType::BeginWrite, [0x50_u32], 3000_u16)
    decoded = Thermostat::AtomicRequest.from_tlv(request.to_tlv)
    decoded.request_type.should eq(AtomicType::BeginWrite)
    decoded.attribute_requests.should eq([0x50_u32])
    decoded.timeout.should eq(3000_u16)
    response = Thermostat::AtomicResponse.new(IMCode::Success,
      [Thermostat::AtomicAttributeStatus.new(0x50_u32, IMCode::Success)], 3000_u16)
    Thermostat::AtomicResponse.from_tlv(response.to_tlv).attribute_status.first.attribute_id.should eq(0x50_u32)
    cluster = build(Thermostat)
    cluster.get_command_metadata(Thermostat::CMD_ATOMIC_REQUEST).should be_nil
    cluster.get_attribute_metadata(Thermostat::ATTR_PRESETS).should be_nil
    atomic_write(cluster, [] of Thermostat::Preset).should eq(IMCode::UnsupportedAttribute)
  end

  it "rejects malformed and non-operational transaction requests" do
    cluster = build(Thermostat)
    cluster.configure_presets([Thermostat::PresetType.new(Thermostat::PresetScenario::Sleep, 1_u8)],
      [] of Thermostat::Preset)
    atomic_request(cluster, AtomicType::BeginWrite, 100_u16).as(Matter::InteractionModel::Status).status.should eq(IMCode::InvalidCommand)
    atomic_actor(cluster)
    cluster.atomic_request(Thermostat::AtomicRequest.new(AtomicType::BeginWrite, [] of UInt32, 100_u16))
      .as(Matter::InteractionModel::Status).status.should eq(IMCode::InvalidCommand)
    cluster.atomic_request(Thermostat::AtomicRequest.new(AtomicType::BeginWrite, [0x50_u32, 0x50_u32], 100_u16))
      .as(Matter::InteractionModel::Status).status.should eq(IMCode::InvalidCommand)
    cluster.atomic_request(Thermostat::AtomicRequest.new(AtomicType::BeginWrite, [0x51_u32], 100_u16))
      .as(Matter::InteractionModel::Status).status.should eq(IMCode::InvalidCommand)
    atomic_request(cluster, AtomicType::BeginWrite).as(Matter::InteractionModel::Status).status.should eq(IMCode::InvalidCommand)
    atomic_request(cluster, AtomicType::BeginWrite, 0_u16).as(Matter::InteractionModel::Status).status.should eq(IMCode::InvalidCommand)
    atomic_actor(cluster, subject: Matter::DataType::NodeId::UNSPECIFIED)
    atomic_request(cluster, AtomicType::BeginWrite, 100_u16).as(Matter::InteractionModel::Status).status.should eq(IMCode::InvalidCommand)
    atomic_actor(cluster, fabric: 0_u8)
    atomic_request(cluster, AtomicType::BeginWrite, 100_u16).as(Matter::InteractionModel::Status).status.should eq(IMCode::InvalidCommand)
  end

  it "stages a list for one secure peer, commits once, and persists only the committed value" do
    cluster = build(Thermostat)
    cluster.configure_presets([Thermostat::PresetType.new(Thermostat::PresetScenario::Sleep, 2_u8)],
      [Thermostat::Preset.new(Bytes[1_u8], Thermostat::PresetScenario::Sleep,
        nil, 2700_i16, 1800_i16, false)])
    atomic_actor(cluster)
    atomic_request(cluster, AtomicType::BeginWrite, 3000_u16).as(Thermostat::AtomicResponse).status_code.should eq(IMCode::Success)
    updated = [Thermostat::Preset.new(Bytes[1_u8], Thermostat::PresetScenario::Sleep,
      nil, 2800_i16, 1900_i16, nil)]
    atomic_write(cluster, updated).should eq(IMCode::Success)
    cluster.presets.first.cooling_setpoint.should eq(2700_i16)
    saved_before = cluster.save_state
    committed = atomic_request(cluster, AtomicType::CommitWrite).as(Thermostat::AtomicResponse)
    committed.status_code.should eq(IMCode::Success)
    committed.attribute_status.should be_empty
    cluster.presets.first.cooling_setpoint.should eq(2800_i16)
    saved_before.should_not eq(cluster.save_state)
    restored = build(Thermostat)
    restored.configure_presets([Thermostat::PresetType.new(Thermostat::PresetScenario::Sleep, 2_u8)],
      [] of Thermostat::Preset)
    restored.restore_state(cluster.save_state)
    restored.presets.first.cooling_setpoint.should eq(2800_i16)
  end

  it "lets the same operational peer continue on a fresh CASE session but rejects another peer or fabric" do
    cluster = build(Thermostat)
    cluster.configure_presets([Thermostat::PresetType.new(Thermostat::PresetScenario::Sleep, 2_u8)],
      [] of Thermostat::Preset)
    atomic_actor(cluster)
    atomic_request(cluster, AtomicType::BeginWrite, 3000_u16).as(Thermostat::AtomicResponse).status_code.should eq(IMCode::Success)
    proposed = [Thermostat::Preset.new(nil, Thermostat::PresetScenario::Sleep,
      nil, 2700_i16, 1800_i16, nil)]
    atomic_write(cluster, proposed, wire_session: 8_u16).should eq(IMCode::Success)
    atomic_write(cluster, proposed, subject: 12_u64).should eq(IMCode::InvalidInState)
    atomic_write(cluster, proposed, fabric: 2_u8).should eq(IMCode::InvalidInState)
    atomic_write(cluster, proposed).should eq(IMCode::Success)
    atomic_actor(cluster, subject: 12_u64)
    atomic_request(cluster, AtomicType::CommitWrite).as(Matter::InteractionModel::Status).status.should eq(IMCode::InvalidInState)
    atomic_actor(cluster)
    atomic_request(cluster, AtomicType::RollbackWrite).as(Thermostat::AtomicResponse).status_code.should eq(IMCode::Success)
    cluster.presets.should be_empty
  end

  it "expires a pending list and rejects commit after the timeout" do
    cluster = build(Thermostat)
    cluster.configure_presets([Thermostat::PresetType.new(Thermostat::PresetScenario::Sleep, 1_u8)],
      [] of Thermostat::Preset)
    atomic_actor(cluster)
    Timecop.freeze(Time.utc) do
      atomic_request(cluster, AtomicType::BeginWrite, 100_u16).as(Thermostat::AtomicResponse).status_code.should eq(IMCode::Success)
      Timecop.travel(Time.utc + 1.second) do
        atomic_request(cluster, AtomicType::CommitWrite).as(Matter::InteractionModel::Status).status.should eq(IMCode::InvalidInState)
      end
    end
  end

  it "reserves the list for one peer, clamps the timeout and rolls back without a version change" do
    cluster = build(Thermostat)
    cluster.configure_presets([Thermostat::PresetType.new(Thermostat::PresetScenario::Sleep, 1_u8)],
      [] of Thermostat::Preset)
    atomic_actor(cluster)
    before = cluster.data_version
    started = atomic_request(cluster, AtomicType::BeginWrite, 9_000_u16).as(Thermostat::AtomicResponse)
    started.timeout.should eq(3_000_u16)
    atomic_request(cluster, AtomicType::BeginWrite, 100_u16).as(Matter::InteractionModel::Status).status.should eq(IMCode::InvalidInState)
    atomic_actor(cluster, subject: 12_u64)
    busy = atomic_request(cluster, AtomicType::BeginWrite, 100_u16).as(Thermostat::AtomicResponse)
    busy.status_code.should eq(IMCode::Failure)
    busy.attribute_status.first.status_code.should eq(IMCode::Busy)
    busy.timeout.should eq(100_u16)
    atomic_actor(cluster)
    proposed = [Thermostat::Preset.new(nil, Thermostat::PresetScenario::Sleep,
      nil, 2700_i16, 1800_i16, nil)]
    atomic_write(cluster, proposed).should eq(IMCode::Success)
    atomic_request(cluster, AtomicType::RollbackWrite).as(Thermostat::AtomicResponse).status_code.should eq(IMCode::Success)
    cluster.presets.should be_empty
    cluster.data_version.should eq(before)
  end

  it "validates each pending replacement and generates a unique handle on commit" do
    cluster = build(Thermostat)
    cluster.configure_presets([Thermostat::PresetType.new(Thermostat::PresetScenario::Sleep, 1_u8)],
      [] of Thermostat::Preset)
    atomic_actor(cluster)
    atomic_request(cluster, AtomicType::BeginWrite, 500_u16).as(Thermostat::AtomicResponse).status_code.should eq(IMCode::Success)
    unknown = [Thermostat::Preset.new(Bytes[2_u8], Thermostat::PresetScenario::Sleep,
      nil, 2700_i16, 1800_i16, false)]
    atomic_write(cluster, unknown).should eq(IMCode::NotFound)
    oversized = [Thermostat::Preset.new(nil, Thermostat::PresetScenario::Sleep,
      nil, 2700_i16, 1800_i16, nil),
                 Thermostat::Preset.new(nil, Thermostat::PresetScenario::Sleep,
                   nil, 2700_i16, 1800_i16, nil)]
    atomic_write(cluster, oversized).should eq(IMCode::ResourceExhausted)
    added = [Thermostat::Preset.new(nil, Thermostat::PresetScenario::Sleep,
      nil, 2700_i16, 1800_i16, nil)]
    atomic_write(cluster, added).should eq(IMCode::Success)
    cluster.presets.should be_empty
    atomic_request(cluster, AtomicType::CommitWrite).as(Thermostat::AtomicResponse).status_code.should eq(IMCode::Success)
    cluster.presets.first.preset_handle.try(&.size).should eq(16)
    cluster.presets.first.built_in.should be_false
  end

  it "rejects deletion of built-in or active presets when committing" do
    cluster = build(Thermostat)
    built_in = Thermostat::Preset.new(Bytes[1_u8], Thermostat::PresetScenario::Sleep,
      nil, 2700_i16, 1800_i16, true)
    active = Thermostat::Preset.new(Bytes[2_u8], Thermostat::PresetScenario::Sleep,
      "Active", 2600_i16, 1900_i16, false)
    cluster.configure_presets([Thermostat::PresetType.new(Thermostat::PresetScenario::Sleep, 2_u8,
      Thermostat::PresetTypeFeatures::SupportsNames)],
      [built_in, active])
    cluster.activate_preset(Thermostat::SetActivePresetRequest.new(Bytes[2_u8])).should eq(Matter::InteractionModel::Status.success)
    atomic_actor(cluster)
    atomic_request(cluster, AtomicType::BeginWrite, 500_u16).as(Thermostat::AtomicResponse).status_code.should eq(IMCode::Success)
    atomic_write(cluster, [active]).should eq(IMCode::Success)
    failed = atomic_request(cluster, AtomicType::CommitWrite).as(Thermostat::AtomicResponse)
    failed.status_code.should eq(IMCode::Failure)
    failed.attribute_status.first.status_code.should eq(IMCode::ConstraintError)
    cluster.presets.size.should eq(2)
    atomic_request(cluster, AtomicType::BeginWrite, 500_u16).as(Thermostat::AtomicResponse).status_code.should eq(IMCode::Success)
    atomic_write(cluster, [built_in]).should eq(IMCode::Success)
    active_failure = atomic_request(cluster, AtomicType::CommitWrite).as(Thermostat::AtomicResponse)
    active_failure.status_code.should eq(IMCode::Failure)
    active_failure.attribute_status.first.status_code.should eq(IMCode::InvalidInState)
    cluster.presets.size.should eq(2)
  end
end
