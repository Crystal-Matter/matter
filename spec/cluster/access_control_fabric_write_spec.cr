require "../spec_helper"

private alias FabricWriteAcl = Matter::Cluster::AccessControl

# Matter 1.6 AccessControlEntryStruct adds optional context tag 5. Keep the
# wire fixture independent of the implementation's typed ACL entry.
private struct AuxiliaryAclEntryWire
  include TLV::Serializable

  @[TLV::Field(tag: 1)]
  property privilege : FabricWriteAcl::AccessControlEntryPrivilege

  @[TLV::Field(tag: 2)]
  property auth_mode : FabricWriteAcl::AccessControlEntryAuthMode

  @[TLV::Field(tag: 3)]
  property subjects : Array(UInt64)

  @[TLV::Field(tag: 5)]
  property auxiliary_type : UInt8

  def initialize(@privilege : FabricWriteAcl::AccessControlEntryPrivilege,
                 @auth_mode : FabricWriteAcl::AccessControlEntryAuthMode,
                 @subjects : Array(UInt64), @auxiliary_type : UInt8)
  end
end

private def fabric_write_cluster : FabricWriteAcl
  cluster = build(FabricWriteAcl, 0)
  cluster.acl = [
    FabricWriteAcl::AccessControlEntry.new(FabricWriteAcl::AccessControlEntryPrivilege::Administer,
      FabricWriteAcl::AccessControlEntryAuthMode::CASE, [101_u64], nil, 1_u8),
    FabricWriteAcl::AccessControlEntry.new(FabricWriteAcl::AccessControlEntryPrivilege::Administer,
      FabricWriteAcl::AccessControlEntryAuthMode::CASE, [202_u64], nil, 2_u8),
  ]
  cluster
end

private def write_on_second_fabric(cluster : FabricWriteAcl, attribute_id : UInt32, entries)
  request = Matter::InteractionModel::WriteRequestMessage.new(
    suppress_response: false,
    timed_request: false,
    write_requests: [Matter::InteractionModel::AttributeDataIB.new(
      path: Matter::InteractionModel::AttributePath.new(endpoint: 0_u16, cluster: FabricWriteAcl::CLUSTER_ID, attribute: attribute_id),
      data: TLV::Serializable.serialize_value(entries, nil))])
  parsed = Matter::Protocol::IMHandler.parse_write_request(request.to_slice).as(Matter::InteractionModel::WriteRequestMessage)
  clusters = { {0_u16, FabricWriteAcl::CLUSTER_ID} => cluster.as(Matter::Cluster::Base) }
  Matter::Protocol::IMHandler.write_attributes(parsed.write_requests, clusters,
    is_case_session: true, fabric_index: 2_u8, peer_subject_ids: [202_u64]).first.status.status
end

describe "fabric-scoped access control writes" do
  it "stores omitted FabricIndex from the authenticated session and preserves other fabrics" do
    cluster = fabric_write_cluster
    replacement = FabricWriteAcl::AccessControlEntry.new(FabricWriteAcl::AccessControlEntryPrivilege::View,
      FabricWriteAcl::AccessControlEntryAuthMode::CASE, [202_u64], nil)

    write_on_second_fabric(cluster, FabricWriteAcl::ATTR_ACL, [replacement]).should eq(Matter::InteractionModel::StatusCode::Success.value)
    cluster.get_acl_for_fabric(1_u8).first.subjects.should eq([101_u64])
    cluster.get_acl_for_fabric(2_u8).size.should eq(1)
    cluster.check_access(202_u64, 2_u8, FabricWriteAcl::AccessControlEntryPrivilege::View).should be_true
    cluster.check_access(202_u64, 2_u8, FabricWriteAcl::AccessControlEntryPrivilege::Administer).should be_false
    cluster.acl.any? { |entry| entry.fabric_index.nil? }.should be_false
  end

  it "stores extension entries under the session fabric instead of the supplied index" do
    cluster = fabric_write_cluster
    cluster.extension = [
      FabricWriteAcl::ExtensionEntry.new(Bytes[0xA1], 1_u8),
      FabricWriteAcl::ExtensionEntry.new(Bytes[0xB1], 2_u8),
    ]
    replacement = FabricWriteAcl::ExtensionEntry.new(Bytes[0xB2], 1_u8)

    write_on_second_fabric(cluster, FabricWriteAcl::ATTR_EXTENSION, [replacement]).should eq(Matter::InteractionModel::StatusCode::Success.value)
    cluster.extension.select { |entry| entry.fabric_index == 1_u8 }.map(&.data).should eq([Bytes[0xA1]])
    cluster.extension.select { |entry| entry.fabric_index == 2_u8 }.map(&.data).should eq([Bytes[0xB2]])
  end

  it "rejects a Matter 1.6 AuxiliaryType in the primary ACL without changing either fabric" do
    cluster = fabric_write_cluster
    original = cluster.acl.map(&.to_slice)
    entry = AuxiliaryAclEntryWire.new(FabricWriteAcl::AccessControlEntryPrivilege::Administer,
      FabricWriteAcl::AccessControlEntryAuthMode::CASE, [202_u64], 1_u8)
    decoded = FabricWriteAcl::AccessControlEntry.from_slice(entry.to_slice)
    decoded.auxiliary_type.should eq(FabricWriteAcl::AccessControlAuxiliaryType::Groupcast)

    write_on_second_fabric(cluster, FabricWriteAcl::ATTR_ACL, [entry]).should eq(Matter::InteractionModel::StatusCode::Failure.value)
    cluster.acl.map(&.to_slice).should eq(original)
  end
end
