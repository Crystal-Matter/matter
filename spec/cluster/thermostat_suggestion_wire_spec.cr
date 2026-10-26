require "../spec_helper"

private alias SuggestWire = Matter::Cluster::Thermostat
private alias SuggestCode = Matter::InteractionModel::StatusCode

private class ReadySuggestionThermostat < SuggestWire
  protected def preset_wire_ready? : Bool
    true
  end

  protected def preset_wire_ready?(command_id : UInt32) : Bool
    true
  end

  protected def suggestion_wire_ready? : Bool
    true
  end

  protected def suggestion_wire_ready?(command_id : UInt32) : Bool
    true
  end
end

private def suggestion_features : SuggestWire::Feature
  SuggestWire::Feature::Heating | SuggestWire::Feature::Presets |
    SuggestWire::Feature::ThermostatSuggestions
end

private def ready_suggestion_thermostat(clock : Proc(UInt32?) = -> : UInt32? { 1_000_u32 },
                                        scheduler : Proc(Time::Span, Proc(Nil), Nil)? = nil) : ReadySuggestionThermostat
  scheduler ||= ->(delay : Time::Span, action : Proc(Nil)) : Nil { spawn { sleep delay; action.call } }
  cluster = build(ReadySuggestionThermostat, feature_map: suggestion_features,
    utc_time_provider: clock, suggestion_timer_scheduler: scheduler)
  cluster.configure_presets([
    SuggestWire::PresetType.new(SuggestWire::PresetScenario::Sleep, 1_u8),
    SuggestWire::PresetType.new(SuggestWire::PresetScenario::Wake, 1_u8),
  ], [
    SuggestWire::Preset.new(Bytes[1_u8], SuggestWire::PresetScenario::Sleep, nil, nil, 1900_i16, false),
    SuggestWire::Preset.new(Bytes[2_u8], SuggestWire::PresetScenario::Wake, nil, nil, 2100_i16, false),
  ])
  cluster
end

private def suggestion_im_invoke(cluster : SuggestWire, command_id : UInt32, request) : Matter::InteractionModel::InvokeResponseIB
  endpoint = cluster.endpoint_id.number
  path = Matter::InteractionModel::CommandPath.new(endpoint, SuggestWire::CLUSTER_ID, command_id)
  data = Matter::InteractionModel::CommandDataIBTlv.new(path, TLV::Serializable.serialize_value(request, nil))
  Matter::Protocol::IMHandler.invoke_commands([data],
    { {endpoint, SuggestWire::CLUSTER_ID} => cluster.as(Matter::Cluster::Base) },
    session_id: 9_u64, is_case_session: true, fabric_index: 1_u8,
    peer_subject_ids: [11_u64]).first
end

private def suggestion_im_status(response : Matter::InteractionModel::InvokeResponseIB) : SuggestCode
  status = response.command_status || raise "expected command status"
  SuggestCode.new(status.status.status)
end

describe "Thermostat guarded suggestion wire" do
  it "advertises canonical read-only metadata and Manage commands only in the ready fixture" do
    expect_raises(ArgumentError) { build(SuggestWire, feature_map: suggestion_features) }
    hidden = build(SuggestWire)
    (0x53_u32..0x56_u32).each { |id| hidden.get_attribute_metadata(id).should be_nil }
    hidden.get_attribute_metadata(0x23_u32).should be_nil
    hidden.get_attribute_metadata(0x24_u32).should be_nil
    hidden.get_command_metadata(0x07_u32).should be_nil

    cluster = ready_suggestion_thermostat
    {0x23_u32, 0x24_u32}.each do |id|
      metadata = cluster.get_attribute_metadata(id) || raise "missing hold attribute"
      metadata.write_access.should eq(Matter::InteractionModel::EntryPrivilege::Manage)
    end
    (0x53_u32..0x56_u32).each do |id|
      metadata = cluster.get_attribute_metadata(id) || raise "missing attribute"
      metadata.write_access.should eq(Matter::InteractionModel::EntryPrivilege::View)
    end
    add = cluster.get_command_metadata(0x07_u32) || raise "missing Add metadata"
    add.access.should eq(Matter::InteractionModel::EntryPrivilege::Manage)
    add.response_id.should eq(0x02_u32)
    remove = cluster.get_command_metadata(0x08_u32) || raise "missing Remove metadata"
    remove.access.should eq(Matter::InteractionModel::EntryPrivilege::Manage)
    read(cluster, 0x53_u32).should eq(5_u8)
    read_tlv(cluster, 0x54_u32).as_list.should be_empty
    read(cluster, 0x55_u32).should be_nil
    read(cluster, 0x56_u32).should be_nil
  end

  it "routes Add and Remove through IM with pinned status and response behavior" do
    cluster = ready_suggestion_thermostat
    response = suggestion_im_invoke(cluster, 0x07_u32,
      SuggestWire::AddThermostatSuggestionRequest.new(Bytes[99_u8], 1_000_u32, 30_u16))
    suggestion_im_status(response).should eq(SuggestCode::NotFound)
    added = suggestion_im_invoke(cluster, 0x07_u32,
      SuggestWire::AddThermostatSuggestionRequest.new(Bytes[1_u8], 1_000_u32, 30_u16))
    data = added.command_data || raise "expected Add response"
    data.command_path.command.should eq(0x02_u32)
    fields = data.command_fields || raise "expected Add response fields"
    id = SuggestWire::AddThermostatSuggestionResponse.from_tlv(fields).unique_id
    read_tlv(cluster, 0x54_u32).as_list.size.should eq(1)
    SuggestWire::ThermostatSuggestion.from_tlv(read_tlv(cluster, 0x55_u32)).unique_id.should eq(id)
    read(cluster, 0x4e_u32).should eq(Bytes[1_u8])
    missing = suggestion_im_invoke(cluster, 0x08_u32, SuggestWire::RemoveThermostatSuggestionRequest.new(255_u8))
    suggestion_im_status(missing).should eq(SuggestCode::NotFound)
    removed = suggestion_im_invoke(cluster, 0x08_u32, SuggestWire::RemoveThermostatSuggestionRequest.new(id))
    suggestion_im_status(removed).should eq(SuggestCode::Success)
  end

  it "rejects invalid UTC and a 25-hour future suggestion without mutating state" do
    cluster = ready_suggestion_thermostat(-> : UInt32? { nil })
    request = SuggestWire::AddThermostatSuggestionRequest.new(Bytes[1_u8], 1_000_u32, 30_u16)
    invalid = suggestion_im_invoke(cluster, 0x07_u32, request)
    suggestion_im_status(invalid).should eq(SuggestCode::InvalidInState)
    cluster.thermostat_suggestions.should be_empty

    valid = ready_suggestion_thermostat
    future = SuggestWire::AddThermostatSuggestionRequest.new(Bytes[1_u8], 91_000_u32, 30_u16)
    rejected = suggestion_im_invoke(valid, 0x07_u32, future)
    suggestion_im_status(rejected).should eq(SuggestCode::InvalidCommand)
    valid.thermostat_suggestions.should be_empty
  end

  it "keeps a selected suggestion among overlapping entries and enforces capacity" do
    now = 1_000_u32
    cluster = ready_suggestion_thermostat(-> : UInt32? { now })
    ids = Array.new(5) do |index|
      handle = index.odd? ? Bytes[2_u8] : Bytes[1_u8]
      request = SuggestWire::AddThermostatSuggestionRequest.new(handle, now, 30_u16)
      response = suggestion_im_invoke(cluster, 0x07_u32, request)
      data = response.command_data || raise "expected Add response"
      fields = data.command_fields || raise "expected Add response fields"
      SuggestWire::AddThermostatSuggestionResponse.from_tlv(fields).unique_id
    end
    ids.uniq.size.should eq(5)
    read_tlv(cluster, 0x54_u32).as_list.size.should eq(5)
    current = SuggestWire::ThermostatSuggestion.from_tlv(read_tlv(cluster, 0x55_u32))
    ids.should contain(current.unique_id)
    read(cluster, 0x4e_u32).should eq(current.preset_handle)
    full = suggestion_im_invoke(cluster, 0x07_u32,
      SuggestWire::AddThermostatSuggestionRequest.new(Bytes[1_u8], now, 30_u16))
    suggestion_im_status(full).should eq(SuggestCode::ResourceExhausted)
    read_tlv(cluster, 0x54_u32).as_list.size.should eq(5)
  end

  it "does not report a failed preset activation as a followed current suggestion" do
    cluster = ready_suggestion_thermostat
    suggestion_im_invoke(cluster, 0x07_u32,
      SuggestWire::AddThermostatSuggestionRequest.new(Bytes[1_u8], 1_000_u32, 30_u16))
    read_tlv(cluster, 0x55_u32).should_not be_nil
    cluster.min_heat_setpoint_limit = 2_000_i16
    read(cluster, 0x55_u32).should be_nil
    read(cluster, 0x56_u32).should be_nil
  end

  it "keeps the current suggestion visible but does not follow it during an indefinite setpoint hold" do
    cluster = ready_suggestion_thermostat
    cluster.activate_preset(SuggestWire::SetActivePresetRequest.new(Bytes[1_u8]))
      .status.should eq(SuggestCode::Success)
    changed = [] of UInt32
    cluster.on_attribute_changed = ->(_endpoint : UInt16, _cluster : UInt32, attribute : UInt32) : Nil {
      changed << attribute
      nil
    }

    write(cluster, 0x24_u32, nil).status.should eq(SuggestCode::Success)
    write(cluster, 0x23_u32, 1_u8).status.should eq(SuggestCode::Success)
    write(cluster, 0x24_u32, 10_u16).status.should eq(SuggestCode::InvalidDataType)
    write(cluster, 0x23_u32, 2_u8).status.should eq(SuggestCode::ConstraintError)
    suggestion_im_invoke(cluster, 0x07_u32,
      SuggestWire::AddThermostatSuggestionRequest.new(Bytes[2_u8], 1_000_u32, 30_u16))
    current = SuggestWire::ThermostatSuggestion.from_tlv(read_tlv(cluster, 0x55_u32))
    current.preset_handle.should eq(Bytes[2_u8])
    read(cluster, 0x56_u32).should eq(2_u16)
    read(cluster, 0x4e_u32).should eq(Bytes[1_u8])
    changed.should contain(0x55_u32)
    changed.should contain(0x56_u32)
    changed.should_not contain(0x4e_u32)

    restored = ready_suggestion_thermostat
    restored.restore_state(cluster.save_state)
    read(restored, 0x23_u32).should eq(1_u8)
    read(restored, 0x24_u32).should be_nil
    read(restored, 0x55_u32).should_not be_nil
    read(restored, 0x56_u32).should eq(2_u16)
    read(restored, 0x4e_u32).should eq(Bytes[1_u8])

    changed.clear
    write(cluster, 0x23_u32, 0_u8).status.should eq(SuggestCode::Success)
    read(cluster, 0x55_u32).should_not be_nil
    read(cluster, 0x56_u32).should be_nil
    read(cluster, 0x4e_u32).should eq(Bytes[2_u8])
    changed.should contain(0x56_u32)
    changed.should contain(0x4e_u32)
  end

  it "requires Manage privilege for Add and Remove over IM" do
    cluster = ready_suggestion_thermostat
    acl = build(Matter::Cluster::AccessControl, 0)
    clusters = {
      {0_u16, Matter::Cluster::AccessControl::CLUSTER_ID}   => acl.as(Matter::Cluster::Base),
      {cluster.endpoint_id.number, SuggestWire::CLUSTER_ID} => cluster.as(Matter::Cluster::Base),
    }
    add_request = SuggestWire::AddThermostatSuggestionRequest.new(Bytes[1_u8], 1_000_u32, 30_u16)
    add_path = Matter::InteractionModel::CommandPath.new(cluster.endpoint_id.number, SuggestWire::CLUSTER_ID, 0x07_u32)
    add_data = Matter::InteractionModel::CommandDataIBTlv.new(add_path, add_request.to_tlv)
    acl.acl << Matter::Cluster::AccessControl::AccessControlEntry.new(
      Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Operate,
      Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
      [11_u64], nil, 1_u8)
    denied = Matter::Protocol::IMHandler.invoke_commands([add_data], clusters,
      is_case_session: true, fabric_index: 1_u8, peer_subject_ids: [11_u64]).first
    suggestion_im_status(denied).should eq(SuggestCode::UnsupportedAccess)

    acl.acl.clear
    acl.acl << Matter::Cluster::AccessControl::AccessControlEntry.new(
      Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Manage,
      Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
      [11_u64], nil, 1_u8)
    added = Matter::Protocol::IMHandler.invoke_commands([add_data], clusters,
      is_case_session: true, fabric_index: 1_u8, peer_subject_ids: [11_u64]).first
    data = added.command_data || raise "expected Add response"
    fields = data.command_fields || raise "expected Add fields"
    id = SuggestWire::AddThermostatSuggestionResponse.from_tlv(fields).unique_id
    remove_path = Matter::InteractionModel::CommandPath.new(cluster.endpoint_id.number, SuggestWire::CLUSTER_ID, 0x08_u32)
    remove_data = Matter::InteractionModel::CommandDataIBTlv.new(remove_path,
      SuggestWire::RemoveThermostatSuggestionRequest.new(id).to_tlv)
    acl.acl.clear
    acl.acl << Matter::Cluster::AccessControl::AccessControlEntry.new(
      Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Operate,
      Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
      [11_u64], nil, 1_u8)
    denied_remove = Matter::Protocol::IMHandler.invoke_commands([remove_data], clusters,
      is_case_session: true, fabric_index: 1_u8, peer_subject_ids: [11_u64]).first
    suggestion_im_status(denied_remove).should eq(SuggestCode::UnsupportedAccess)
    acl.acl.clear
    acl.acl << Matter::Cluster::AccessControl::AccessControlEntry.new(
      Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Manage,
      Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
      [11_u64], nil, 1_u8)
    removed = Matter::Protocol::IMHandler.invoke_commands([remove_data], clusters,
      is_case_session: true, fabric_index: 1_u8, peer_subject_ids: [11_u64]).first
    suggestion_im_status(removed).should eq(SuggestCode::Success)
  end

  it "reevaluates at future effective and expiry boundaries and reports changes" do
    now = 1_000_u32
    timers = [] of Tuple(Time::Span, Proc(Nil))
    scheduler = ->(delay : Time::Span, action : Proc(Nil)) : Nil { timers << {delay, action}; nil }
    cluster = ready_suggestion_thermostat(-> : UInt32? { now }, scheduler)
    changed = [] of UInt32
    cluster.on_attribute_changed = ->(_endpoint : UInt16, _cluster : UInt32, attribute : UInt32) : Nil {
      changed << attribute
      nil
    }
    response = suggestion_im_invoke(cluster, 0x07_u32,
      SuggestWire::AddThermostatSuggestionRequest.new(Bytes[1_u8], 1_200_u32, 30_u16))
    response.command_data.should_not be_nil
    read(cluster, SuggestWire::ATTR_CURRENT_THERMOSTAT_SUGGESTION).should be_nil
    timers.last[0].should eq(200.seconds)
    changed.should contain(SuggestWire::ATTR_THERMOSTAT_SUGGESTIONS)
    changed.should_not contain(SuggestWire::ATTR_CURRENT_THERMOSTAT_SUGGESTION)
    version = cluster.data_version
    now = 1_200_u32
    timers.last[1].call
    cluster.data_version.should be > version
    changed.should contain(SuggestWire::ATTR_CURRENT_THERMOSTAT_SUGGESTION)
    changed.should contain(SuggestWire::ATTR_ACTIVE_PRESET_HANDLE)
    read(cluster, SuggestWire::ATTR_ACTIVE_PRESET_HANDLE).should eq(Bytes[1_u8])
    timers.last[0].should eq(1_800.seconds)

    changed.clear
    version = cluster.data_version
    now = 3_000_u32
    timers.last[1].call
    cluster.data_version.should be > version
    changed.should contain(SuggestWire::ATTR_THERMOSTAT_SUGGESTIONS)
    changed.should contain(SuggestWire::ATTR_CURRENT_THERMOSTAT_SUGGESTION)
    cluster.thermostat_suggestions.should be_empty
    read(cluster, SuggestWire::ATTR_CURRENT_THERMOSTAT_SUGGESTION).should be_nil
  end

  it "rearms a pending suggestion after restoring persisted state" do
    now = 1_000_u32
    timers = [] of Tuple(Time::Span, Proc(Nil))
    scheduler = ->(delay : Time::Span, action : Proc(Nil)) : Nil { timers << {delay, action}; nil }
    clock = -> : UInt32? { now }
    original = ready_suggestion_thermostat(clock, scheduler)
    original.add_thermostat_suggestion(
      SuggestWire::AddThermostatSuggestionRequest.new(Bytes[2_u8], 1_200_u32, 30_u16), now)
    saved = original.save_state
    timers.clear
    restored = ready_suggestion_thermostat(clock, scheduler)
    changed = [] of UInt32
    restored.on_attribute_changed = ->(_endpoint : UInt16, _cluster : UInt32, attribute : UInt32) : Nil {
      changed << attribute
      nil
    }
    restored.restore_state(saved)
    timers.last[0].should eq(200.seconds)
    version = restored.data_version
    changed.clear
    now = 1_200_u32
    timers.last[1].call
    restored.data_version.should be > version
    changed.should contain(SuggestWire::ATTR_CURRENT_THERMOSTAT_SUGGESTION)
    changed.should contain(SuggestWire::ATTR_ACTIVE_PRESET_HANDLE)
    read(restored, SuggestWire::ATTR_ACTIVE_PRESET_HANDLE).should eq(Bytes[2_u8])
    restored.current_thermostat_suggestion.try(&.preset_handle).should eq(Bytes[2_u8])
  end

  it "ignores a cancelled timer after removal and rescheduling" do
    now = 1_000_u32
    timers = [] of Tuple(Time::Span, Proc(Nil))
    scheduler = ->(delay : Time::Span, action : Proc(Nil)) : Nil { timers << {delay, action}; nil }
    cluster = ready_suggestion_thermostat(-> : UInt32? { now }, scheduler)
    added = suggestion_im_invoke(cluster, 0x07_u32,
      SuggestWire::AddThermostatSuggestionRequest.new(Bytes[1_u8], 1_200_u32, 30_u16))
    fields = added.command_data.try(&.command_fields) || raise "expected Add response fields"
    id = SuggestWire::AddThermostatSuggestionResponse.from_tlv(fields).unique_id
    cancelled = timers.last[1]
    removed = suggestion_im_invoke(cluster, 0x08_u32, SuggestWire::RemoveThermostatSuggestionRequest.new(id))
    suggestion_im_status(removed).should eq(SuggestCode::Success)
    suggestion_im_invoke(cluster, 0x07_u32,
      SuggestWire::AddThermostatSuggestionRequest.new(Bytes[2_u8], 1_300_u32, 30_u16))
    timers.last[0].should eq(300.seconds)
    version = cluster.data_version
    now = 1_200_u32
    cancelled.call
    cluster.data_version.should eq(version)
    now = 1_300_u32
    timers.last[1].call
    read(cluster, SuggestWire::ATTR_ACTIVE_PRESET_HANDLE).should eq(Bytes[2_u8])
  end
end
