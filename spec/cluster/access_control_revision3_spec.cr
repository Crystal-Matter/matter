require "../spec_helper"
require "../../src/matter/protocol/im_handler"

private alias Rev3Acl = Matter::Cluster::AccessControl

# Independent Matter 1.6 AccessControlEntryStruct tags 1–4. Subjects and
# Targets are mandatory fields whose values may each be TLV Null.
struct NullableAclWire
  include TLV::Serializable

  @[TLV::Field(tag: 1)]
  property privilege : Rev3Acl::AccessControlEntryPrivilege

  @[TLV::Field(tag: 2)]
  property auth_mode : Rev3Acl::AccessControlEntryAuthMode

  @[TLV::Field(tag: 3, optional: false)]
  property subjects : Array(UInt64)?

  @[TLV::Field(tag: 4, optional: false)]
  property targets : Array(Rev3Acl::Target)?

  def initialize(@privilege : Rev3Acl::AccessControlEntryPrivilege,
                 @auth_mode : Rev3Acl::AccessControlEntryAuthMode,
                 @subjects : Array(UInt64)?, @targets : Array(Rev3Acl::Target)?)
  end
end

struct NullableTargetWire
  include TLV::Serializable

  @[TLV::Field(tag: 0, optional: false)]
  property cluster : UInt32?

  @[TLV::Field(tag: 1, optional: false)]
  property endpoint : UInt16?

  @[TLV::Field(tag: 2, optional: false)]
  property device_type : UInt32?

  def initialize(@cluster : UInt32?, @endpoint : UInt16?, @device_type : UInt32?)
  end
end

struct AccessChangeWire
  include TLV::Serializable

  @[TLV::Field(tag: 1, optional: false)]
  property admin_node_id : UInt64?

  @[TLV::Field(tag: 2, optional: false)]
  property admin_passcode_id : UInt16?

  @[TLV::Field(tag: 3)]
  property change_type : Rev3Acl::ChangeType

  @[TLV::Field(tag: 4, optional: false)]
  property latest_value : NullableAclWire?
end

struct AuxiliaryAclWire
  include TLV::Serializable

  @[TLV::Field(tag: 1)]
  property privilege : Rev3Acl::AccessControlEntryPrivilege

  @[TLV::Field(tag: 2)]
  property auth_mode : Rev3Acl::AccessControlEntryAuthMode

  @[TLV::Field(tag: 3, optional: false)]
  property subjects : Array(UInt64)?

  @[TLV::Field(tag: 4, optional: false)]
  property targets : Array(Rev3Acl::Target)?

  @[TLV::Field(tag: 5)]
  property auxiliary_type : Rev3Acl::AccessControlAuxiliaryType

  def initialize(@privilege : Rev3Acl::AccessControlEntryPrivilege,
                 @auth_mode : Rev3Acl::AccessControlEntryAuthMode,
                 @subjects : Array(UInt64)?, @targets : Array(Rev3Acl::Target)?,
                 @auxiliary_type : Rev3Acl::AccessControlAuxiliaryType)
  end
end

struct ExtensionWriteWire
  include TLV::Serializable

  @[TLV::Field(tag: 1)]
  property data : Bytes

  def initialize(@data : Bytes)
  end
end

private def rev3_entry(subject : UInt64, privilege : Rev3Acl::AccessControlEntryPrivilege = Rev3Acl::AccessControlEntryPrivilege::View,
                       fabric_index : UInt8? = nil)
  Rev3Acl::AccessControlEntry.new(privilege, Rev3Acl::AccessControlEntryAuthMode::CASE, [subject], nil, fabric_index)
end

private def rev3_extension_data(value : UInt8) : Bytes
  TLV::Any.new(TLV::List{TLV::Any.new(value, {1_u16, 1_u16})}).to_slice
end

private def rev3_write(cluster : Rev3Acl, attribute : UInt32, value,
                       is_case_session : Bool = true, fabric_index : UInt8? = 1_u8) : UInt8
  request = Matter::InteractionModel::WriteRequestMessage.new(
    suppress_response: false,
    timed_request: false,
    write_requests: [Matter::InteractionModel::AttributeDataIB.new(
      path: Matter::InteractionModel::AttributePath.new(endpoint: 0_u16, cluster: Rev3Acl::CLUSTER_ID, attribute: attribute),
      data: TLV::Serializable.serialize_value(value, nil))])
  parsed = Matter::Protocol::IMHandler.parse_write_request(request.to_slice).as(Matter::InteractionModel::WriteRequestMessage)
  clusters = { {0_u16, Rev3Acl::CLUSTER_ID} => cluster.as(Matter::Cluster::Base) }
  Matter::Protocol::IMHandler.write_attributes(parsed.write_requests, clusters,
    is_case_session: is_case_session, fabric_index: fabric_index,
    peer_subject_ids: is_case_session ? [101_u64] : nil).first.status.status
end

describe "Matter 1.6 Access Control revision 3 without AUX or MNGD" do
  it "decodes explicitly null Subjects and Targets in an ACL wire entry" do
    wire = NullableAclWire.new(Rev3Acl::AccessControlEntryPrivilege::Administer,
      Rev3Acl::AccessControlEntryAuthMode::CASE, nil, nil)
    entry = Rev3Acl::AccessControlEntry.from_slice(wire.to_slice)
    entry.subjects.should be_nil
    entry.targets.should be_nil
  end

  it "round-trips a nullable wildcard ACL through the wire and persistent state" do
    cluster = build(Rev3Acl, 0)
    cluster.acl = [Rev3Acl::AccessControlEntry.new(
      Rev3Acl::AccessControlEntryPrivilege::Operate,
      Rev3Acl::AccessControlEntryAuthMode::CASE, nil, nil, 1_u8)]
    encoded = cluster.read_attribute(Rev3Acl::ATTR_ACL, 1_u8).as(TLV::Any)
    wire_entry = encoded.as_list.first
    wire_entry[3_u8].value.should be_nil
    wire_entry[4_u8].value.should be_nil

    restored = build(Rev3Acl, 0)
    restored.restore_state(cluster.save_state.as(Matter::Storage::Document))
    restored.acl.first.subjects.should be_nil
    restored.acl.first.targets.should be_nil
    restored.check_access(0x1234_u64, 1_u8,
      Rev3Acl::AccessControlEntryPrivilege::Operate).should be_true
  end

  it "encodes all mandatory nullable target tags and decodes explicit Null" do
    wire = NullableTargetWire.new(0x0006_u32, nil, nil)
    target = Rev3Acl::Target.from_slice(wire.to_slice)
    target.cluster.should eq(0x0006_u32)
    target.endpoint.should be_nil
    target.device_type.should be_nil
    encoded = TLV::Any.from_slice(target.to_slice)
    encoded[0_u8].as_u64.should eq(0x0006_u64)
    encoded[1_u8].value.should be_nil
    encoded[2_u8].value.should be_nil
  end

  it "advertises only EXTS and protects change events with Administer privilege" do
    cluster = build(Rev3Acl, 0)
    cluster.cluster_revision.should eq(3_u16)
    cluster.feature_map.value.should eq(1_u32)
    cluster.get_attribute_metadata(0x0005_u32).should be_nil
    cluster.get_attribute_metadata(0x0006_u32).should be_nil
    cluster.get_attribute_metadata(0x0007_u32).should be_nil
    cluster.get_event_metadata(Rev3Acl::EVENT_ACCESS_CONTROL_ENTRY_CHANGED).try(&.access).should eq(Matter::InteractionModel::EntryPrivilege::Administer)
    cluster.get_event_metadata(Rev3Acl::EVENT_ACCESS_CONTROL_EXTENSION_CHANGED).try(&.access).should eq(Matter::InteractionModel::EntryPrivilege::Administer)
  end

  it "emits a fabric-scoped entry event for an authenticated ACL addition" do
    cluster = build(Rev3Acl, 0)
    cluster.acl = [rev3_entry(101_u64, Rev3Acl::AccessControlEntryPrivilege::Administer, 1_u8)]
    events = [] of Tuple(UInt32, UInt8?, TLV::Any)
    cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, event : UInt32, _priority : Matter::InteractionModel::EventPriority, data : TLV::Any, fabric : UInt8?) do
      events << {event, fabric, data}
      nil
    end

    rev3_write(cluster, Rev3Acl::ATTR_ACL, [rev3_entry(101_u64, Rev3Acl::AccessControlEntryPrivilege::Administer), rev3_entry(202_u64)]).should eq(Matter::InteractionModel::StatusCode::Success.value)
    cluster.request_fabric_index.should eq(1_u8)
    cluster.request_is_case_session?.should be_true
    cluster.request_peer_node_id.should eq(101_u64)
    cluster.acl.map { |entry| {entry.subjects, entry.fabric_index} }.should eq([{[101_u64], 1_u8}, {[202_u64], 1_u8}])
    events.map { |event| {event[0], event[1]} }.should eq([{Rev3Acl::EVENT_ACCESS_CONTROL_ENTRY_CHANGED, 1_u8}])
    payload = AccessChangeWire.from_tlv(events.first[2])
    payload.admin_node_id.should eq(101_u64)
    payload.admin_passcode_id.should be_nil
    payload.change_type.should eq(Rev3Acl::ChangeType::Added)
    payload.latest_value.try(&.subjects).should eq([202_u64])
    events.first[2][254_u8]?.should be_nil
  end

  it "emits changed and removed events for replaced ACL entries, but none for rejected auxiliary writes" do
    cluster = build(Rev3Acl, 0)
    cluster.acl = [rev3_entry(101_u64, Rev3Acl::AccessControlEntryPrivilege::Administer, 1_u8)]
    events = [] of AccessChangeWire
    cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, event : UInt32, _priority : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) do
      events << AccessChangeWire.from_tlv(data) if event == Rev3Acl::EVENT_ACCESS_CONTROL_ENTRY_CHANGED
      nil
    end

    rev3_write(cluster, Rev3Acl::ATTR_ACL, [rev3_entry(101_u64, Rev3Acl::AccessControlEntryPrivilege::Administer), rev3_entry(202_u64)]).should eq(Matter::InteractionModel::StatusCode::Success.value)
    rev3_write(cluster, Rev3Acl::ATTR_ACL, [rev3_entry(101_u64, Rev3Acl::AccessControlEntryPrivilege::Administer), rev3_entry(303_u64)]).should eq(Matter::InteractionModel::StatusCode::Success.value)
    rev3_write(cluster, Rev3Acl::ATTR_ACL, [rev3_entry(101_u64, Rev3Acl::AccessControlEntryPrivilege::Administer)]).should eq(Matter::InteractionModel::StatusCode::Success.value)
    events.map(&.change_type).should eq([Rev3Acl::ChangeType::Added, Rev3Acl::ChangeType::Changed, Rev3Acl::ChangeType::Removed])
    events.last.latest_value.should be_nil

    forbidden = AuxiliaryAclWire.new(Rev3Acl::AccessControlEntryPrivilege::View,
      Rev3Acl::AccessControlEntryAuthMode::CASE, [202_u64], nil, Rev3Acl::AccessControlAuxiliaryType::Groupcast)
    rev3_write(cluster, Rev3Acl::ATTR_ACL, [forbidden]).should eq(Matter::InteractionModel::StatusCode::Failure.value)
    events.size.should eq(3)
    cluster.get_acl_for_fabric(1_u8).size.should eq(1)
  end

  it "reports ACL changes only to an Administer reader on the same fabric" do
    node = Matter::Node.new
    endpoint = Matter::Endpoint.new(endpoint(0_u16))
    cluster = build(Rev3Acl, 0)
    cluster.acl = [
      rev3_entry(101_u64, Rev3Acl::AccessControlEntryPrivilege::Administer, 1_u8),
      rev3_entry(303_u64, Rev3Acl::AccessControlEntryPrivilege::View, 1_u8),
      rev3_entry(202_u64, Rev3Acl::AccessControlEntryPrivilege::Administer, 2_u8),
    ]
    endpoint.add_cluster(cluster)
    node.add_endpoint(endpoint)

    rev3_write(cluster, Rev3Acl::ATTR_ACL, [
      rev3_entry(101_u64, Rev3Acl::AccessControlEntryPrivilege::Administer),
      rev3_entry(303_u64, Rev3Acl::AccessControlEntryPrivilege::View),
      rev3_entry(404_u64),
    ]).should eq(Matter::InteractionModel::StatusCode::Success.value)

    path = [Matter::InteractionModel::EventPath.new(endpoint: 0_u16,
      cluster: Rev3Acl::CLUSTER_ID, event: Rev3Acl::EVENT_ACCESS_CONTROL_ENTRY_CHANGED)]
    journal = node.event_journal
    journal.query(path, fabric_index: 1_u8).size.should eq(1)
    journal.query(path, fabric_index: 2_u8).should be_empty
    admin_reports = Matter::Protocol::IMHandler.read_events(path, journal, node.clusters,
      fabric_index: 1_u8, is_case_session: true, peer_subject_ids: [101_u64])
    admin_reports.compact_map(&.event_data).size.should eq(1)
    view_reports = Matter::Protocol::IMHandler.read_events(path, journal, node.clusters,
      fabric_index: 1_u8, is_case_session: true, peer_subject_ids: [303_u64])
    view_reports.compact_map(&.event_data).should be_empty
    other_reports = Matter::Protocol::IMHandler.read_events(path, journal, node.clusters,
      fabric_index: 2_u8, is_case_session: true, peer_subject_ids: [202_u64])
    other_reports.compact_map(&.event_data).should be_empty
  end

  it "ignores a supplied FabricIndex when replacing the authenticated fabric's ACL" do
    cluster = build(Rev3Acl, 0)
    cluster.acl = [
      rev3_entry(101_u64, Rev3Acl::AccessControlEntryPrivilege::Administer, 1_u8),
      rev3_entry(202_u64, Rev3Acl::AccessControlEntryPrivilege::Administer, 2_u8),
    ]
    rev3_write(cluster, Rev3Acl::ATTR_ACL,
      [rev3_entry(303_u64, Rev3Acl::AccessControlEntryPrivilege::Administer, 2_u8)]).should eq(Matter::InteractionModel::StatusCode::Success.value)
    cluster.get_acl_for_fabric(1_u8).map(&.subjects).should eq([[303_u64]])
    cluster.get_acl_for_fabric(2_u8).map(&.subjects).should eq([[202_u64]])
  end

  it "rejects a PASE ACL write without a fabric before it can replace all fabrics" do
    cluster = build(Rev3Acl, 0)
    original = [
      rev3_entry(101_u64, Rev3Acl::AccessControlEntryPrivilege::Administer, 1_u8),
      rev3_entry(202_u64, Rev3Acl::AccessControlEntryPrivilege::Administer, 2_u8),
    ]
    cluster.acl = original.dup
    rev3_write(cluster, Rev3Acl::ATTR_ACL, [rev3_entry(303_u64)],
      is_case_session: false, fabric_index: nil).should eq(Matter::InteractionModel::StatusCode::UnsupportedAccess.value)
    cluster.acl.map(&.to_slice).should eq(original.map(&.to_slice))
  end

  it "rejects a PASE Extension write without a fabric before it can replace all fabrics" do
    cluster = build(Rev3Acl, 0)
    original = [
      Rev3Acl::ExtensionEntry.new(rev3_extension_data(0x01_u8), 1_u8),
      Rev3Acl::ExtensionEntry.new(rev3_extension_data(0x02_u8), 2_u8),
    ]
    cluster.extension = original.dup
    rev3_write(cluster, Rev3Acl::ATTR_EXTENSION,
      [ExtensionWriteWire.new(rev3_extension_data(0x03_u8))],
      is_case_session: false, fabric_index: nil).should eq(Matter::InteractionModel::StatusCode::UnsupportedAccess.value)
    cluster.extension.map(&.to_slice).should eq(original.map(&.to_slice))
  end

  it "allows internal multi-fabric provisioning up to the per-fabric limit" do
    cluster = build(Rev3Acl, 0)
    entries = (1_u8..2_u8).flat_map do |fabric|
      (1_u64..3_u64).map { |subject| rev3_entry(subject, fabric_index: fabric) }
    end
    cluster.acl = entries
    cluster.get_acl_for_fabric(1_u8).size.should eq(3)
    cluster.get_acl_for_fabric(2_u8).size.should eq(3)
  end

  it "rejects ACL lists and fields above their advertised limits without changing state" do
    cluster = build(Rev3Acl, 0)
    original = rev3_entry(101_u64, Rev3Acl::AccessControlEntryPrivilege::Administer, 1_u8)
    cluster.acl = [original]

    oversized_subjects = Rev3Acl::AccessControlEntry.new(
      Rev3Acl::AccessControlEntryPrivilege::View,
      Rev3Acl::AccessControlEntryAuthMode::CASE,
      [101_u64, 102_u64, 103_u64, 104_u64, 105_u64], nil)
    rev3_write(cluster, Rev3Acl::ATTR_ACL, [oversized_subjects]).should eq(Matter::InteractionModel::StatusCode::ConstraintError.value)

    targets = Array.new(4) { |index| Rev3Acl::Target.new(endpoint: index.to_u16) }
    oversized_targets = Rev3Acl::AccessControlEntry.new(
      Rev3Acl::AccessControlEntryPrivilege::View,
      Rev3Acl::AccessControlEntryAuthMode::CASE, [101_u64], targets)
    rev3_write(cluster, Rev3Acl::ATTR_ACL, [oversized_targets]).should eq(Matter::InteractionModel::StatusCode::ConstraintError.value)

    too_many = Array.new(5) { |index| rev3_entry((200 + index).to_u64) }
    rev3_write(cluster, Rev3Acl::ATTR_ACL, too_many).should eq(Matter::InteractionModel::StatusCode::ConstraintError.value)
    cluster.get_acl_for_fabric(1_u8).map(&.to_slice).should eq([original.to_slice])
  end

  it "emits a fabric-scoped extension change only while EXTS is enabled" do
    cluster = build(Rev3Acl, 0)
    cluster.acl = [rev3_entry(101_u64, Rev3Acl::AccessControlEntryPrivilege::Administer, 1_u8)]
    events = [] of Tuple(UInt32, UInt8?, TLV::Any)
    cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, event : UInt32, _priority : Matter::InteractionModel::EventPriority, data : TLV::Any, fabric : UInt8?) do
      events << {event, fabric, data}
      nil
    end

    rev3_write(cluster, Rev3Acl::ATTR_EXTENSION,
      [ExtensionWriteWire.new(rev3_extension_data(0x01_u8))]).should eq(Matter::InteractionModel::StatusCode::Success.value)
    events.size.should eq(1)
    events.first[0].should eq(Rev3Acl::EVENT_ACCESS_CONTROL_EXTENSION_CHANGED)
    events.first[1].should eq(1_u8)
    events.first[2][254_u8]?.should be_nil
    cluster.extension(1_u8).first.fabric_index.should eq(1_u8)

    rev3_write(cluster, Rev3Acl::ATTR_EXTENSION,
      [ExtensionWriteWire.new(rev3_extension_data(0x02_u8))]).should eq(Matter::InteractionModel::StatusCode::Success.value)
    rev3_write(cluster, Rev3Acl::ATTR_EXTENSION,
      [] of ExtensionWriteWire).should eq(Matter::InteractionModel::StatusCode::Success.value)
    events.map { |event| Rev3Acl::ExtensionChangedEvent.from_tlv(event[2]).change_type }.should eq([
      Rev3Acl::ChangeType::Added, Rev3Acl::ChangeType::Changed, Rev3Acl::ChangeType::Removed,
    ])

    cluster.feature_map = Rev3Acl::Feature.new(0_u32)
    cluster.get_event_metadata(Rev3Acl::EVENT_ACCESS_CONTROL_EXTENSION_CHANGED).should be_nil
    rev3_write(cluster, Rev3Acl::ATTR_EXTENSION,
      [Rev3Acl::ExtensionEntry.new(rev3_extension_data(0x02_u8), 1_u8)]).should eq(Matter::InteractionModel::StatusCode::UnsupportedAttribute.value)
    events.size.should eq(3)
  end

  it "rejects oversized, non-profile, malformed, and multiple extension entries" do
    cluster = build(Rev3Acl, 0)
    cluster.acl = [rev3_entry(101_u64, Rev3Acl::AccessControlEntryPrivilege::Administer, 1_u8)]
    valid = rev3_extension_data(0x01_u8)
    rev3_write(cluster, Rev3Acl::ATTR_EXTENSION,
      [Rev3Acl::ExtensionEntry.new(valid, 1_u8)]).should eq(Matter::InteractionModel::StatusCode::Success.value)

    malformed = Bytes[0x17, 0x04, 0x01, 0x18] # anonymous inner item, not a profile tag
    invalid = [malformed, Bytes.new(129, 0_u8), Bytes[0x17], valid + Bytes[0x00]]
    invalid.each do |bytes|
      rev3_write(cluster, Rev3Acl::ATTR_EXTENSION,
        [Rev3Acl::ExtensionEntry.new(bytes, 1_u8)]).should eq(Matter::InteractionModel::StatusCode::ConstraintError.value)
    end
    rev3_write(cluster, Rev3Acl::ATTR_EXTENSION, [
      Rev3Acl::ExtensionEntry.new(valid, 1_u8),
      Rev3Acl::ExtensionEntry.new(valid, 1_u8),
    ]).should eq(Matter::InteractionModel::StatusCode::ConstraintError.value)
    cluster.extension(1_u8).map(&.data).should eq([valid])
  end
end
