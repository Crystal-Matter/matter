require "../spec_helper"

describe "chip-tool GroupKeyMap list writes" do
  it "accepts a clear followed by a single list-item append" do
    root = Matter::DataType::EndpointNumber.new(0_u16)
    gkm = Matter::Cluster::GroupKeyManagement.new(root)
    acl = Matter::Cluster::AccessControl.new(root)
    acl.acl << Matter::Cluster::AccessControl::AccessControlEntry.new(
      Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer,
      Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
      [0x1111_u64], nil, 1_u8)
    gkm.handle_key_set_write(Matter::Cluster::GroupKeyManagement::KeySetWriteRequest.new(
      Matter::Cluster::GroupKeyManagement::GroupKeySetStruct.new(417_u16,
        epoch_key0: Bytes.new(16, 1_u8), epoch_start_time0: 1_u64)), 1_u8)
    clusters = {} of Tuple(UInt16, UInt32) => Matter::Cluster::Base
    clusters[{0_u16, Matter::Cluster::GroupKeyManagement::CLUSTER_ID}] = gkm
    clusters[{0_u16, Matter::Cluster::AccessControl::CLUSTER_ID}] = acl
    path = Matter::InteractionModel::AttributePath.new(0_u16,
      Matter::Cluster::GroupKeyManagement::CLUSTER_ID,
      Matter::Cluster::GroupKeyManagement::ATTR_GROUP_KEY_MAP)
    clear = Matter::InteractionModel::AttributeDataIB.new(path,
      TLV::Any.from_tlv(([] of Matter::Cluster::GroupKeyManagement::GroupKeyMapStruct).to_tlv))
    # Actual chip-tool item TLV: context-tagged struct, GroupId tag 1,
    # GroupKeySetID tag 2, and no FabricIndex tag 254.
    append_path = Matter::InteractionModel::AttributePath.new(0_u16,
      Matter::Cluster::GroupKeyManagement::CLUSTER_ID,
      Matter::Cluster::GroupKeyManagement::ATTR_GROUP_KEY_MAP,
      list_index_null: true)
    append = Matter::InteractionModel::AttributeDataIB.new(append_path,
      TLV::Any.from_tlv("3502250101012502a10118".hexbytes))

    statuses = Matter::Protocol::IMHandler.write_attributes([clear, append], clusters,
      is_case_session: true, fabric_index: 1_u8, peer_subject_ids: [0x1111_u64])
    statuses.map(&.status.status).should eq([0_u8, 0_u8])
    gkm.group_key_map(1_u8).map(&.group_id).should eq([0x0101_u16])
  end
end
