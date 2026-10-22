require "../spec_helper"

describe "Matter 1.6 Groupcast adoption wire behavior" do
  it "requires Administer privilege to read adoption state" do
    root = Matter::DataType::EndpointNumber.new(0_u16)
    keys = Matter::Cluster::GroupKeyManagement.new(root,
      feature_map: Matter::Cluster::GroupKeyManagement::Feature::Groupcast)
    metadata = keys.get_attribute_metadata(Matter::Cluster::GroupKeyManagement::ATTR_GROUPCAST_ADOPTION)
      .as(Matter::Cluster::AttributeMetadata)
    metadata.access.should eq(Matter::InteractionModel::EntryPrivilege::Administer)
    metadata.write_access.should eq(Matter::InteractionModel::EntryPrivilege::Administer)
  end

  it "marks auxiliary ACL changes omitted as the Access Control XML requires" do
    root = Matter::DataType::EndpointNumber.new(0_u16)
    acl = Matter::Cluster::AccessControl.new(root,
      feature_map: Matter::Cluster::AccessControl::Feature::Auxiliary)
    metadata = acl.get_attribute_metadata(Matter::Cluster::AccessControl::ATTR_AUXILIARY_ACL)
      .as(Matter::Cluster::AttributeMetadata)
    metadata.access.should eq(Matter::InteractionModel::EntryPrivilege::Administer)
    metadata.omit_changes?.should be_true
  end

  it "rejects oversized endpoint membership before installing a supplied key" do
    root = Matter::DataType::EndpointNumber.new(0_u16)
    keys = Matter::Cluster::GroupKeyManagement.new(root,
      feature_map: Matter::Cluster::GroupKeyManagement::Feature::Groupcast,
      max_groups_per_fabric: 0_u16)
    acl = Matter::Cluster::AccessControl.new(root,
      feature_map: Matter::Cluster::AccessControl::Feature::Auxiliary)
    acl.acl = [Matter::Cluster::AccessControl::AccessControlEntry.new(
      Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer,
      Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
      [10_u64], nil, 1_u8)]
    listener = Matter::Cluster::Groupcast.new(root, keys, acl)
    listener.request_is_case_session = true
    listener.request_fabric_index = 1_u8
    listener.request_peer_subject_ids = [10_u64]

    endpoints = (1_u16..256_u16).to_a
    status = listener.join_group(Matter::Cluster::Groupcast::JoinGroupRequest.new(
      0x1234_u16, endpoints, 7_u16, key: Bytes.new(16, 0x55_u8)))
    status.status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    keys.get_key_set(7_u16, 1_u8).should be_nil
    listener.membership(1_u8).should be_empty
  end

  it "ignores an untrusted FabricIndex and hides only the adopted fabric's legacy maps" do
    root = Matter::DataType::EndpointNumber.new(0_u16)
    keys = Matter::Cluster::GroupKeyManagement.new(root,
      feature_map: Matter::Cluster::GroupKeyManagement::Feature::Groupcast,
      max_groups_per_fabric: 0_u16)
    [1_u8, 2_u8].each do |fabric|
      keys.handle_key_set_write(Matter::Cluster::GroupKeyManagement::KeySetWriteRequest.new(
        Matter::Cluster::GroupKeyManagement::GroupKeySetStruct.new(7_u16,
          epoch_key0: Bytes.new(16, fabric), epoch_start_time0: 1_u64)), fabric)
      keys.replace_groupcast_membership(0x1234_u16, [1_u16], 7_u16, fabric)
    end

    keys.request_fabric_index = 1_u8
    forged = Matter::Cluster::GroupKeyManagement::GroupcastAdoptionStruct.new(true, 2_u8)
    status = keys.write_attribute(Matter::Cluster::GroupKeyManagement::ATTR_GROUPCAST_ADOPTION,
      TLV::Serializable.serialize_value([forged], nil))
    status.status.should eq(Matter::InteractionModel::StatusCode::Success)
    keys.groupcast_adoption(1_u8).first.fabric_index.should eq(1_u8)
    keys.groupcast_adoption(2_u8).should be_empty
    keys.group_key_map(1_u8).should be_empty
    keys.group_table(1_u8).should be_empty
    keys.group_key_map(2_u8).size.should eq(1)
    keys.group_table(2_u8).size.should eq(1)
    keys.operational_group_key_map(1_u8).size.should eq(1)
    keys.write_group_key_map(TLV::Serializable.serialize_value([] of Matter::Cluster::GroupKeyManagement::GroupKeyMapStruct, nil),
      1_u8).status.should eq(Matter::InteractionModel::StatusCode::InvalidInState)
  end

  it "does not let Manage access create a group key or auxiliary ACL" do
    root = Matter::DataType::EndpointNumber.new(0_u16)
    keys = Matter::Cluster::GroupKeyManagement.new(root,
      feature_map: Matter::Cluster::GroupKeyManagement::Feature::Groupcast,
      max_groups_per_fabric: 0_u16)
    acl = Matter::Cluster::AccessControl.new(root,
      feature_map: Matter::Cluster::AccessControl::Feature::Auxiliary)
    acl.acl = [Matter::Cluster::AccessControl::AccessControlEntry.new(
      Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Manage,
      Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
      [10_u64], nil, 1_u8)]
    listener = Matter::Cluster::Groupcast.new(root, keys, acl)
    listener.request_is_case_session = true
    listener.request_fabric_index = 1_u8
    listener.request_peer_node_id = 10_u64
    listener.request_peer_subject_ids = [10_u64]

    listener.join_group(Matter::Cluster::Groupcast::JoinGroupRequest.new(
      0x1234_u16, [1_u16], 7_u16, key: Bytes.new(16, 0x55_u8))).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAccess)
    keys.get_key_set(7_u16, 1_u8).should be_nil
    keys.handle_key_set_write(Matter::Cluster::GroupKeyManagement::KeySetWriteRequest.new(
      Matter::Cluster::GroupKeyManagement::GroupKeySetStruct.new(7_u16,
        epoch_key0: Bytes.new(16, 0x55_u8), epoch_start_time0: 1_u64)), 1_u8)
    listener.join_group(Matter::Cluster::Groupcast::JoinGroupRequest.new(
      0x1234_u16, [1_u16], 7_u16, use_auxiliary_acl: true)).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAccess)
    listener.membership(1_u8).should be_empty
    acl.auxiliary_acl(1_u8).should be_empty
    listener.join_group(Matter::Cluster::Groupcast::JoinGroupRequest.new(
      0x1234_u16, [1_u16], 7_u16)).status.should eq(Matter::InteractionModel::StatusCode::Success)
    acl.auxiliary_acl(1_u8).should be_empty
  end
end
