require "../spec_helper"

alias Datastore = Matter::Cluster::JointFabricDatastore

private def jf_cat_subject(cat : UInt16, version : UInt16) : UInt64
  Matter::DataType::NodeId.from_case_authenticated_tag(
    Matter::DataType::CaseAuthenticatedTag.create(cat, version)).id
end

private def full_node_key_set_list : Array(Datastore::DatastoreNodeKeySetEntryStruct)
  committed = Datastore::DatastoreStatusEntryStruct.new(Datastore::DatastoreStateEnum::Committed, 0_u32, 0_u8)
  Array.new(Datastore::MAX_NODE_ENTRIES) do |index|
    Datastore::DatastoreNodeKeySetEntryStruct.new(1000_u64 + (index // 254).to_u64,
      ((index % 254) + 1).to_u16, committed)
  end
end

describe Matter::Cluster::JointFabricDatastore do
  it "preserves a committed Anchor status when the same configuration is attached again" do
    cluster = Datastore.new(Matter::DataType::EndpointNumber::ROOT)
    root = Bytes[1_u8]
    cluster.configure_anchor(root, 7_u64, 0xFFF1_u16, "Anchor").success?.should be_true
    copied_status = Datastore::DatastoreStatusEntryStruct.new(
      Datastore::DatastoreStateEnum::Committed, 1_u32, Datastore::NO_FAILURE_CODE)
    cluster.status = copied_status
    previous_version = cluster.data_version

    cluster.configure_anchor(root, 7_u64, 0xFFF1_u16, "Anchor").success?.should be_true
    cluster.status.to_slice.should eq(copied_status.to_slice)
    cluster.data_version.should eq(previous_version)

    cluster.configure_anchor(root, 7_u64, 0xFFF1_u16, "Renamed Anchor").success?.should be_true
    cluster.status.update_timestamp.should be > copied_status.update_timestamp
  end

  it "publishes the Anchor fabric IPK in GroupKeySetID zero for JCM device migration" do
    cluster = Matter::Cluster::JointFabricDatastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    ipk = Bytes.new(16, 0xA5_u8)
    cluster.configure_anchor(Bytes[1], 7_u64, 0xFFF1_u16, "Anchor", ipk).success?.should be_true
    key_set = cluster.group_key_set_list.find!(&.group_key_set_id.==(0_u16))
    key_set.epoch_key0.should eq(ipk)
    key_set.epoch_start_time0.should eq(0_u64)
  end
  it "publishes the Matter 1.6 Datastore command and attribute schema" do
    cluster = Datastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    cluster.cluster_revision.should eq(1_u16)
    cluster.attributes.size.should eq(14)
    cluster.commands.size.should eq(20)
    cluster.get_attribute_metadata(Datastore::ATTR_NODE_ACL_LIST).as(Matter::Cluster::AttributeMetadata).access.should eq(Matter::InteractionModel::EntryPrivilege::Administer)
  end

  it "limits a bound datastore to its CASE fabric" do
    cluster = Datastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    cluster.joint_fabric_index = 2_u8
    cluster.access_mode = Datastore::AccessMode::Active
    cluster.read_attribute(Datastore::ATTR_ANCHOR_NODE_ID, 1_u8).as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAccess)
    cluster.read_attribute(Datastore::ATTR_ANCHOR_NODE_ID, 2_u8).as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAccess)
    cluster.request_is_case_session = true
    cluster.read_attribute(Datastore::ATTR_ANCHOR_NODE_ID, 2_u8).should be_a(TLV::Any)
    request = Datastore::AddPendingNodeRequest.new(42_u64, "Kitchen")
    cluster.invoke_command(Datastore::CMD_ADD_PENDING_NODE, request.to_tlv(nil), fabric_index: 2_u8)
      .as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAccess)
    cluster.invoke_command(Datastore::CMD_ADD_PENDING_NODE, request.to_tlv(nil), is_case_session: true, fabric_index: 2_u8)
      .as(Matter::InteractionModel::Status).success?.should be_true
  end

  it "allows a frozen Anchor snapshot but closes CASE reads and commands after transfer" do
    cluster = Datastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    cluster.configure_anchor(Bytes[1], 7_u64, 0xFFF1_u16, "Anchor").success?.should be_true
    cluster.joint_fabric_index = 1_u8
    cluster.access_mode = Datastore::AccessMode::Active
    cluster.request_is_case_session = true
    cluster.read_attribute(Datastore::ATTR_ANCHOR_NODE_ID, 1_u8).should be_a(TLV::Any)
    cluster.begin_anchor_transfer.should be_true
    cluster.access_mode.should eq(Datastore::AccessMode::Frozen)
    cluster.read_attribute(Datastore::ATTR_ANCHOR_NODE_ID, 1_u8).should be_a(TLV::Any)
    request = Datastore::AddPendingNodeRequest.new(42_u64, "Kitchen")
    cluster.invoke_command(Datastore::CMD_ADD_PENDING_NODE, request.to_tlv(nil), is_case_session: true, fabric_index: 1_u8)
      .as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAccess)

    cluster.access_mode = Datastore::AccessMode::Inactive
    cluster.read_attribute(Datastore::ATTR_ANCHOR_NODE_ID, 1_u8)
      .as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAccess)
    cluster.invoke_command(Datastore::CMD_ADD_PENDING_NODE, request.to_tlv(nil), is_case_session: true, fabric_index: 1_u8)
      .as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAccess)
  end

  it "rejects wire reads and commands before the Datastore is bound to a fabric" do
    cluster = Datastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    cluster.request_is_case_session = true
    cluster.read_attribute(Datastore::ATTR_GROUP_LIST, 1_u8).as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAccess)
    request = Datastore::AddPendingNodeRequest.new(42_u64, "Kitchen")
    cluster.invoke_command(Datastore::CMD_ADD_PENDING_NODE, request.to_tlv(nil), is_case_session: true, fabric_index: 1_u8)
      .as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAccess)
    cluster.node_list.should be_empty
  end

  it "permits only GroupList to a PASE JCM reader while its gate is active" do
    cluster = Datastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    cluster.joint_fabric_index = 1_u8
    cluster.access_mode = Datastore::AccessMode::Active
    armed = false
    cluster.allow_jcm_pase_group_list = -> { armed }
    cluster.read_attribute(Datastore::ATTR_GROUP_LIST).as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAccess)
    armed = true
    cluster.read_attribute(Datastore::ATTR_GROUP_LIST).should be_a(TLV::Any)
    cluster.read_attribute(Datastore::ATTR_ADMIN_LIST).as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAccess)
    cluster.read_attribute(Datastore::ATTR_GROUP_LIST, 2_u8).as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAccess)
  end

  it "isolates JCM GroupList reads to the PASE session that armed the fail-safe" do
    cluster = Datastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    cluster.joint_fabric_index = 1_u8
    cluster.access_mode = Datastore::AccessMode::Active
    owner_session_id = 7_u64
    cluster.allow_jcm_pase_group_list = -> { cluster.request_session_id == owner_session_id }
    clusters = Hash(Tuple(UInt16, UInt32), Matter::Cluster::Base).new
    clusters[{1_u16, Datastore::CLUSTER_ID}] = cluster
    path = Matter::InteractionModel::AttributePath.new(
      endpoint: 1_u16, cluster: Datastore::CLUSTER_ID, attribute: Datastore::ATTR_GROUP_LIST)

    owner = Matter::Protocol::IMHandler.read_attributes([path], clusters, session_id: owner_session_id)
    owner.first.attribute_data.should_not be_nil
    other = Matter::Protocol::IMHandler.read_attributes([path], clusters, session_id: 8_u64)
    other.first.attribute_data.should be_nil
    other.first.attribute_status.as(Matter::InteractionModel::AttributeStatusIB).status.status
      .should eq(Matter::InteractionModel::StatusCode::UnsupportedAccess.value)
  end

  it "adds and removes nodes with persisted state" do
    cluster = Datastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    cluster.add_pending_node(Datastore::AddPendingNodeRequest.new(42_u64, "Kitchen")).success?.should be_true
    wire_request = Datastore::AddPendingNodeRequest.new(43_u64, "Hall")
    cluster.joint_fabric_index = 1_u8
    cluster.access_mode = Datastore::AccessMode::Active
    cluster.invoke_command(Datastore::CMD_ADD_PENDING_NODE, wire_request.to_tlv(nil), is_case_session: true, fabric_index: 1_u8)
      .as(Matter::InteractionModel::Status).success?.should be_true
    cluster.node_list.first.node_id.should eq(42_u64)
    restored = Datastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    restored.restore_state(cluster.save_state.as(Matter::Storage::Document))
    restored.node_list.first.friendly_name.should eq("Kitchen")
    restored.remove_node(Datastore::RemoveNodeRequest.new(42_u64)).success?.should be_true
    restored.node_list.map(&.node_id).should eq([43_u64])
  end

  it "rejects reserved Joint Fabric Node IDs and Administrator collisions" do
    cluster = Datastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    upper_bound = Matter::DataType::NodeId::JOINT_FABRIC_EXCLUSIVE_MAXIMUM
    admin_id = 7_u64
    anchor_id = 8_u64
    cluster.anchor_node_id = anchor_id
    cluster.add_admin(Datastore::AddAdminRequest.new(admin_id, "Administrator", 0xFFF1_u16, Bytes.empty)).success?.should be_true
    cluster.add_admin(Datastore::AddAdminRequest.new(upper_bound, "Invalid", 0xFFF1_u16, Bytes.empty))
      .status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    [0_u64, upper_bound, UInt64::MAX, admin_id, anchor_id].each do |node_id|
      cluster.add_pending_node(Datastore::AddPendingNodeRequest.new(node_id, "Device"))
        .status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    end
    cluster.add_pending_node(Datastore::AddPendingNodeRequest.new(upper_bound - 1_u64, "Device"))
      .success?.should be_true
    cluster.node_list.map(&.node_id).should eq([upper_bound - 1_u64])
  end

  it "round trips a typed group and rejects duplicate group ids" do
    cluster = Datastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    request = Datastore::AddGroupRequest.new(1_u16, "Lights", nil, nil, nil,
      Datastore::DatastoreAccessControlEntryPrivilegeEnum::Operate)
    parsed = Datastore::AddGroupRequest.from_tlv(request.to_tlv(nil))
    parsed.group_id.should eq(1_u16)
    cluster.add_group(parsed).success?.should be_true
    cluster.add_group(parsed).status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    cluster.add_group(Datastore::AddGroupRequest.new(2_u16, "Bad CAT", nil, 0_u16, 1_u16,
      Datastore::DatastoreAccessControlEntryPrivilegeEnum::Operate))
      .status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    cluster.update_group(Datastore::UpdateGroupRequest.new(1_u16, nil, nil, 0_u16, nil, nil))
      .status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
  end

  it "accepts an unprovisioned but valid group key set reference as TC_JFDS_2_3 does" do
    cluster = Datastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    privilege = Datastore::DatastoreAccessControlEntryPrivilegeEnum::View
    cluster.add_group(Datastore::AddGroupRequest.new(10_u16, "Group", 11_u16, 1_u16, 1_u16, privilege)).success?.should be_true
    cluster.update_group(Datastore::UpdateGroupRequest.new(10_u16, "Updated", 12_u16, 1_u16, 2_u16, privilege)).success?.should be_true
    cluster.group_list.first.group_key_set_id.should eq(12_u16)
    cluster.remove_group(Datastore::RemoveGroupRequest.new(10_u16)).success?.should be_true
  end

  it "enforces GroupCAT version and privileged group key set constraints" do
    cluster = Datastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    view = Datastore::DatastoreAccessControlEntryPrivilegeEnum::View
    manage = Datastore::DatastoreAccessControlEntryPrivilegeEnum::Manage
    constraint = Matter::InteractionModel::StatusCode::ConstraintError

    cluster.add_group(Datastore::AddGroupRequest.new(10_u16, "Invalid version", nil, nil, 1_u16, view))
      .status.should eq(constraint)
    cluster.add_group(Datastore::AddGroupRequest.new(11_u16, "Invalid key", 10_u16, nil, nil, manage))
      .status.should eq(constraint)

    cluster.add_group(Datastore::AddGroupRequest.new(12_u16, "Valid", 10_u16, nil, nil, view)).success?.should be_true
    cluster.update_group(Datastore::UpdateGroupRequest.new(12_u16, nil, nil, nil, 1_u16, nil))
      .status.should eq(constraint)
    cluster.update_group(Datastore::UpdateGroupRequest.new(12_u16, nil, nil, nil, nil, manage))
      .status.should eq(constraint)
    cluster.group_list.first.group_permission.should eq(view)
  end

  it "persists an inferred association for a single CASE CAT subject" do
    cluster = Datastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    view = Datastore::DatastoreAccessControlEntryPrivilegeEnum::View
    cluster.add_group(Datastore::AddGroupRequest.new(10_u16, "Group", nil, 1_u16, 2_u16, view)).success?.should be_true
    cluster.add_pending_node(Datastore::AddPendingNodeRequest.new(42_u64, "Node")).success?.should be_true
    acl = Datastore::DatastoreAccessControlEntryStruct.new(view,
      Datastore::DatastoreAccessControlEntryAuthModeEnum::CASE, [jf_cat_subject(1_u16, 1_u16)], nil)
    cluster.add_acl_to_node(Datastore::AddACLToNodeRequest.new(42_u64, acl)).success?.should be_true
    cluster.node_acl_list.first.associated_group_id.should eq(10_u16)
    Datastore::DatastoreACLEntryStruct.from_slice(cluster.node_acl_list.first.to_slice).associated_group_id.should be_nil
    restored = Datastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    restored.restore_state(cluster.save_state.as(Matter::Storage::Document))
    restored.node_acl_list.first.associated_group_id.should eq(10_u16)
  end

  it "rotates the bound CAT subject and privilege while keeping the prior ACL for delivery" do
    cluster = Datastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    view = Datastore::DatastoreAccessControlEntryPrivilegeEnum::View
    operate = Datastore::DatastoreAccessControlEntryPrivilegeEnum::Operate
    cluster.add_group(Datastore::AddGroupRequest.new(10_u16, "Group", nil, 1_u16, 1_u16, view)).success?.should be_true
    cluster.add_pending_node(Datastore::AddPendingNodeRequest.new(42_u64, "Node")).success?.should be_true
    acl = Datastore::DatastoreAccessControlEntryStruct.new(view,
      Datastore::DatastoreAccessControlEntryAuthModeEnum::CASE, [jf_cat_subject(1_u16, 1_u16)], nil)
    cluster.add_acl_to_node(Datastore::AddACLToNodeRequest.new(42_u64, acl)).success?.should be_true
    cluster.complete_acl(42_u64, cluster.node_acl_list.first.list_id).should be_true

    cluster.update_group(Datastore::UpdateGroupRequest.new(10_u16, nil, nil, 2_u16, 2_u16, operate)).success?.should be_true
    updated = cluster.node_acl_list.first
    updated.acl_entry.subjects.should eq([jf_cat_subject(2_u16, 2_u16)])
    updated.acl_entry.privilege.should eq(operate)
    updated.prior_acl_entry.try(&.subjects).should eq([jf_cat_subject(1_u16, 1_u16)])
    updated.status_entry.state.should eq(Datastore::DatastoreStateEnum::Pending)
    cluster.group_list.first.group_cat.should eq(2_u16)

    cluster.update_group(Datastore::UpdateGroupRequest.new(10_u16, nil, nil, 3_u16, 3_u16, view)).success?.should be_true
    updated = cluster.node_acl_list.first
    updated.acl_entry.subjects.should eq([jf_cat_subject(3_u16, 3_u16)])
    updated.prior_acl_entry.try(&.subjects).should eq([jf_cat_subject(1_u16, 1_u16)])
  end

  it "allows explicit binding of a uniquely attributable legacy ACL" do
    cluster = Datastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    view = Datastore::DatastoreAccessControlEntryPrivilegeEnum::View
    cluster.add_group(Datastore::AddGroupRequest.new(10_u16, "Group", nil, 1_u16, 2_u16, view)).success?.should be_true
    acl = Datastore::DatastoreAccessControlEntryStruct.new(view,
      Datastore::DatastoreAccessControlEntryAuthModeEnum::CASE, [jf_cat_subject(1_u16, 1_u16)], nil)
    committed = Datastore::DatastoreStatusEntryStruct.new(Datastore::DatastoreStateEnum::Committed, 0_u32, 0_u8)
    cluster.node_acl_list = [Datastore::DatastoreACLEntryStruct.new(42_u64, 7_u16, acl, committed)]
    cluster.associate_acl_with_group(42_u64, 7_u16, 10_u16).success?.should be_true
    cluster.node_acl_list.first.associated_group_id.should eq(10_u16)
    cluster.associate_acl_with_group(42_u64, 7_u16, 10_u16).success?.should be_true
    cluster.associate_acl_with_group(42_u64, 7_u16, 11_u16)
      .status.should eq(Matter::InteractionModel::StatusCode::NotFound)
  end

  it "rejects malformed binding targets before staging delivery" do
    cluster = Datastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    cluster.add_pending_node(Datastore::AddPendingNodeRequest.new(42_u64, "Node"))
    cluster.record_endpoint(42_u64, 1_u16, "Endpoint")
    before = cluster.save_state
    version = cluster.data_version
    constraint = Matter::InteractionModel::StatusCode::ConstraintError
    [
      Datastore::DatastoreBindingTargetStruct.new(group: 0_u16),
      Datastore::DatastoreBindingTargetStruct.new(group: 1_u16, endpoint: 2_u16),
      Datastore::DatastoreBindingTargetStruct.new(node: 43_u64),
      Datastore::DatastoreBindingTargetStruct.new(node: Matter::DataType::NodeId::UNSPECIFIED, endpoint: 1_u16),
      Datastore::DatastoreBindingTargetStruct.new(node: Matter::DataType::NodeId::CAT_PREFIX, endpoint: 1_u16),
      Datastore::DatastoreBindingTargetStruct.new(node: Matter::DataType::NodeId::JOINT_FABRIC_EXCLUSIVE_MAXIMUM, endpoint: 1_u16),
    ].each do |binding|
      cluster.add_binding_to_endpoint_for_node(Datastore::AddBindingToEndpointForNodeRequest.new(42_u64, 1_u16, binding))
        .status.should eq(constraint)
    end
    cluster.endpoint_binding_list.should be_empty
    cluster.save_state.should eq(before)
    cluster.data_version.should eq(version)

    cluster.reconcile_node_bindings(42_u64, 1_u16,
      [Datastore::DatastoreBindingTargetStruct.new(node: Matter::DataType::NodeId::UNSPECIFIED, endpoint: 1_u16)])
      .status.should eq(constraint)
    cluster.endpoint_binding_list.should be_empty
    cluster.save_state.should eq(before)
    cluster.data_version.should eq(version)

    group_binding = Datastore::DatastoreBindingTargetStruct.new(group: 1_u16)
    cluster.add_binding_to_endpoint_for_node(Datastore::AddBindingToEndpointForNodeRequest.new(42_u64, 1_u16, group_binding))
      .success?.should be_true
    cluster.endpoint_binding_list.first.binding.should eq(group_binding)
  end

  it "returns NotFound for missing nodes and endpoints in datastore update commands without changing state" do
    cluster = Datastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    node_id = 42_u64
    missing_node_id = 43_u64
    endpoint_id = 1_u16
    missing_endpoint_id = 2_u16
    cluster.add_pending_node(Datastore::AddPendingNodeRequest.new(node_id, "Node")).success?.should be_true
    cluster.record_endpoint(node_id, endpoint_id, "Endpoint").success?.should be_true
    privilege = Datastore::DatastoreAccessControlEntryPrivilegeEnum::Operate
    cluster.add_group(Datastore::AddGroupRequest.new(10_u16, "Group", nil, nil, nil, privilege)).success?.should be_true
    binding = Datastore::DatastoreBindingTargetStruct.new(node: node_id, endpoint: endpoint_id)
    acl = Datastore::DatastoreAccessControlEntryStruct.new(privilege,
      Datastore::DatastoreAccessControlEntryAuthModeEnum::CASE, [node_id], nil)
    before = cluster.save_state
    version = cluster.data_version
    not_found = Matter::InteractionModel::StatusCode::NotFound

    cluster.update_endpoint_for_node(Datastore::UpdateEndpointForNodeRequest.new(endpoint_id, missing_node_id, "Missing"))
      .status.should eq(not_found)
    cluster.update_endpoint_for_node(Datastore::UpdateEndpointForNodeRequest.new(missing_endpoint_id, node_id, "Missing"))
      .status.should eq(not_found)
    cluster.add_group_id_to_endpoint_for_node(Datastore::AddGroupIDToEndpointForNodeRequest.new(missing_node_id, endpoint_id, 10_u16))
      .status.should eq(not_found)
    cluster.add_group_id_to_endpoint_for_node(Datastore::AddGroupIDToEndpointForNodeRequest.new(node_id, missing_endpoint_id, 10_u16))
      .status.should eq(not_found)
    cluster.add_binding_to_endpoint_for_node(Datastore::AddBindingToEndpointForNodeRequest.new(missing_node_id, endpoint_id, binding))
      .status.should eq(not_found)
    cluster.add_binding_to_endpoint_for_node(Datastore::AddBindingToEndpointForNodeRequest.new(node_id, missing_endpoint_id, binding))
      .status.should eq(not_found)
    cluster.add_acl_to_node(Datastore::AddACLToNodeRequest.new(missing_node_id, acl))
      .status.should eq(not_found)

    cluster.save_state.should eq(before)
    cluster.data_version.should eq(version)
  end

  it "keeps ConstraintError for invalid datastore update inputs without changing state" do
    cluster = Datastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    node_id = 42_u64
    endpoint_id = 1_u16
    cluster.add_pending_node(Datastore::AddPendingNodeRequest.new(node_id, "Node")).success?.should be_true
    cluster.record_endpoint(node_id, endpoint_id, "Endpoint").success?.should be_true
    privilege = Datastore::DatastoreAccessControlEntryPrivilegeEnum::Operate
    oversized_name = "x" * (Datastore::MAX_FRIENDLY_NAME_BYTES + 1)
    invalid_binding = Datastore::DatastoreBindingTargetStruct.new(node: Matter::DataType::NodeId::UNSPECIFIED,
      endpoint: endpoint_id)
    oversized_acl = Datastore::DatastoreAccessControlEntryStruct.new(privilege,
      Datastore::DatastoreAccessControlEntryAuthModeEnum::CASE,
      [1_u64, 2_u64, 3_u64, 4_u64, 5_u64], nil)
    before = cluster.save_state
    version = cluster.data_version
    constraint = Matter::InteractionModel::StatusCode::ConstraintError

    cluster.update_endpoint_for_node(Datastore::UpdateEndpointForNodeRequest.new(endpoint_id, node_id, oversized_name))
      .status.should eq(constraint)
    cluster.add_group_id_to_endpoint_for_node(Datastore::AddGroupIDToEndpointForNodeRequest.new(node_id, endpoint_id, 10_u16))
      .status.should eq(constraint)
    cluster.add_binding_to_endpoint_for_node(Datastore::AddBindingToEndpointForNodeRequest.new(node_id, endpoint_id, invalid_binding))
      .status.should eq(constraint)
    cluster.add_acl_to_node(Datastore::AddACLToNodeRequest.new(node_id, oversized_acl))
      .status.should eq(constraint)

    cluster.save_state.should eq(before)
    cluster.data_version.should eq(version)
  end

  it "checks update targets before invalid payloads and leaves datastore state unchanged" do
    cluster = Datastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    node_id = 42_u64
    endpoint_id = 1_u16
    key_set_id = 10_u16
    cluster.add_pending_node(Datastore::AddPendingNodeRequest.new(node_id, "Node")).success?.should be_true
    cluster.record_endpoint(node_id, endpoint_id, "Endpoint").success?.should be_true
    key_set = Datastore::DatastoreGroupKeySetStruct.new(key_set_id,
      Datastore::DatastoreGroupKeySecurityPolicyEnum::TrustFirst,
      Bytes.new(Datastore::EPOCH_KEY_BYTES, 1_u8), 1_u64, nil, nil, nil, nil)
    cluster.add_key_set(Datastore::AddKeySetRequest.new(key_set)).success?.should be_true
    invalid_name = "x" * (Datastore::MAX_FRIENDLY_NAME_BYTES + 1)
    invalid_key_set = Datastore::DatastoreGroupKeySetStruct.new(key_set_id,
      Datastore::DatastoreGroupKeySecurityPolicyEnum::TrustFirst,
      nil, nil, nil, nil, nil, nil)
    missing_invalid_key_set = Datastore::DatastoreGroupKeySetStruct.new(key_set_id + 1_u16,
      Datastore::DatastoreGroupKeySecurityPolicyEnum::TrustFirst,
      nil, nil, nil, nil, nil, nil)
    before = cluster.save_state
    version = cluster.data_version
    not_found = Matter::InteractionModel::StatusCode::NotFound
    constraint = Matter::InteractionModel::StatusCode::ConstraintError

    cluster.update_node(Datastore::UpdateNodeRequest.new(node_id + 1_u64, invalid_name))
      .status.should eq(not_found)
    cluster.update_key_set(Datastore::UpdateKeySetRequest.new(missing_invalid_key_set))
      .status.should eq(not_found)
    cluster.update_endpoint_for_node(Datastore::UpdateEndpointForNodeRequest.new(endpoint_id, node_id + 1_u64, invalid_name))
      .status.should eq(not_found)
    cluster.update_endpoint_for_node(Datastore::UpdateEndpointForNodeRequest.new(endpoint_id + 1_u16, node_id, invalid_name))
      .status.should eq(not_found)

    cluster.update_node(Datastore::UpdateNodeRequest.new(node_id, invalid_name))
      .status.should eq(constraint)
    cluster.update_key_set(Datastore::UpdateKeySetRequest.new(invalid_key_set))
      .status.should eq(constraint)
    cluster.update_endpoint_for_node(Datastore::UpdateEndpointForNodeRequest.new(endpoint_id, node_id, invalid_name))
      .status.should eq(constraint)

    cluster.save_state.should eq(before)
    cluster.data_version.should eq(version)
  end

  it "uses target snapshots to prune stale committed records while preserving pending work" do
    cluster = Datastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    cluster.add_pending_node(Datastore::AddPendingNodeRequest.new(42_u64, "Node"))
    cluster.record_endpoint(42_u64, 1_u16, "Endpoint")
    committed = Datastore::DatastoreStatusEntryStruct.new(Datastore::DatastoreStateEnum::Committed, 0_u32, 0_u8)
    pending = Datastore::DatastoreStatusEntryStruct.new(Datastore::DatastoreStateEnum::Pending, 0_u32, 0_u8)
    cluster.endpoint_group_id_list = [
      Datastore::DatastoreEndpointGroupIDEntryStruct.new(42_u64, 1_u16, 1_u16, committed),
      Datastore::DatastoreEndpointGroupIDEntryStruct.new(42_u64, 1_u16, 2_u16, pending),
    ]
    cluster.node_key_set_list = [
      Datastore::DatastoreNodeKeySetEntryStruct.new(42_u64, 1_u16, committed),
      Datastore::DatastoreNodeKeySetEntryStruct.new(42_u64, 2_u16, pending),
    ]

    cluster.reconcile_node_groups(42_u64, 1_u16, [] of UInt16).success?.should be_true
    cluster.reconcile_node_key_sets(42_u64, [] of UInt16).success?.should be_true
    cluster.endpoint_group_id_list.map(&.group_id).should eq([2_u16])
    cluster.node_key_set_list.map(&.group_key_set_id).should eq([2_u16])
  end

  it "refuses ambiguous Group CAT ACL rewrites without mutating state" do
    cluster = Datastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    view = Datastore::DatastoreAccessControlEntryPrivilegeEnum::View
    cluster.add_group(Datastore::AddGroupRequest.new(10_u16, "First", nil, 1_u16, 1_u16, view)).success?.should be_true
    cluster.add_group(Datastore::AddGroupRequest.new(11_u16, "Second", nil, 1_u16, 2_u16, view)).success?.should be_true
    cluster.add_pending_node(Datastore::AddPendingNodeRequest.new(42_u64, "Node")).success?.should be_true
    acl = Datastore::DatastoreAccessControlEntryStruct.new(view,
      Datastore::DatastoreAccessControlEntryAuthModeEnum::CASE, [jf_cat_subject(1_u16, 1_u16)], nil)
    cluster.add_acl_to_node(Datastore::AddACLToNodeRequest.new(42_u64, acl)).success?.should be_true
    cluster.node_acl_list.first.associated_group_id.should be_nil
    before = cluster.save_state
    cluster.update_group(Datastore::UpdateGroupRequest.new(10_u16, nil, nil, 2_u16, 2_u16, nil))
      .status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    cluster.save_state.should eq(before)
  end

  it "recovers a unique ACL association after wire-only Anchor transfer" do
    cluster = Datastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    view = Datastore::DatastoreAccessControlEntryPrivilegeEnum::View
    cluster.add_group(Datastore::AddGroupRequest.new(10_u16, "Group", nil, 1_u16, 1_u16, view)).success?.should be_true
    acl = Datastore::DatastoreAccessControlEntryStruct.new(view,
      Datastore::DatastoreAccessControlEntryAuthModeEnum::CASE, [jf_cat_subject(1_u16, 1_u16)], nil)
    committed = Datastore::DatastoreStatusEntryStruct.new(Datastore::DatastoreStateEnum::Committed, 0_u32, 0_u8)
    cluster.node_acl_list = [Datastore::DatastoreACLEntryStruct.from_slice(
      Datastore::DatastoreACLEntryStruct.new(42_u64, 7_u16, acl, committed).to_slice)]
    cluster.node_acl_list.first.associated_group_id.should be_nil

    cluster.update_group(Datastore::UpdateGroupRequest.new(10_u16, nil, nil, 2_u16, 2_u16, nil)).success?.should be_true
    cluster.node_acl_list.first.associated_group_id.should eq(10_u16)
    cluster.node_acl_list.first.acl_entry.subjects.should eq([jf_cat_subject(2_u16, 2_u16)])
  end

  it "rejects multi-subject ACLs and a destination CAT shared with another group" do
    cluster = Datastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    view = Datastore::DatastoreAccessControlEntryPrivilegeEnum::View
    cluster.add_group(Datastore::AddGroupRequest.new(10_u16, "First", nil, 1_u16, 1_u16, view)).success?.should be_true
    cluster.add_group(Datastore::AddGroupRequest.new(11_u16, "Second", nil, 2_u16, 1_u16, view)).success?.should be_true
    cluster.add_pending_node(Datastore::AddPendingNodeRequest.new(42_u64, "Node")).success?.should be_true
    acl = Datastore::DatastoreAccessControlEntryStruct.new(view,
      Datastore::DatastoreAccessControlEntryAuthModeEnum::CASE, [jf_cat_subject(1_u16, 1_u16), 42_u64], nil)
    cluster.add_acl_to_node(Datastore::AddACLToNodeRequest.new(42_u64, acl)).success?.should be_true
    cluster.node_acl_list.first.associated_group_id.should be_nil
    before = cluster.save_state
    cluster.update_group(Datastore::UpdateGroupRequest.new(10_u16, nil, nil, 3_u16, 2_u16, nil))
      .status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    cluster.save_state.should eq(before)

    single = Datastore::DatastoreAccessControlEntryStruct.new(view,
      Datastore::DatastoreAccessControlEntryAuthModeEnum::CASE, [jf_cat_subject(1_u16, 1_u16)], nil)
    cluster.node_acl_list = [Datastore::DatastoreACLEntryStruct.new(42_u64, 7_u16, single,
      Datastore::DatastoreStatusEntryStruct.new(Datastore::DatastoreStateEnum::Committed, 0_u32, 0_u8))]
    before = cluster.save_state
    cluster.update_group(Datastore::UpdateGroupRequest.new(10_u16, nil, nil, 2_u16, 2_u16, nil))
      .status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    cluster.save_state.should eq(before)
  end

  it "protects the reserved Administrator and Anchor CAT groups" do
    cluster = Datastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    privilege = Datastore::DatastoreAccessControlEntryPrivilegeEnum::Administer
    cluster.seed_reserved_cat_group(1_u16, "Admin", 0xFFFF_u16, 1_u16).success?.should be_true
    cluster.seed_reserved_cat_group(2_u16, "Anchor", 0xFFFE_u16, 1_u16).success?.should be_true
    cluster.seed_reserved_cat_group(1_u16, "Admin", 0xFFFF_u16, 1_u16).success?.should be_true
    {0xFFFF_u16, 0xFFFE_u16}.each do |cat|
      cluster.add_group(Datastore::AddGroupRequest.new(10_u16, "Reserved", nil, cat, 1_u16, privilege))
        .status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    end
    {1_u16, 2_u16}.each do |id|
      cluster.update_group(Datastore::UpdateGroupRequest.new(id, "Changed", nil, 1_u16, 2_u16, privilege))
        .status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
      cluster.remove_group(Datastore::RemoveGroupRequest.new(id))
        .status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    end
    cluster.group_list.map(&.friendly_name).should eq(["Admin", "Anchor"])
  end

  it "validates key set epochs and keeps ACL list identifiers unique" do
    cluster = Datastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    key = Datastore::DatastoreGroupKeySetStruct.new(1_u16,
      Datastore::DatastoreGroupKeySecurityPolicyEnum::TrustFirst,
      Bytes.new(16, 0xAA_u8), 1_u64, nil, nil, nil, nil)
    cluster.add_key_set(Datastore::AddKeySetRequest.new(key)).success?.should be_true
    cluster.add_key_set(Datastore::AddKeySetRequest.new(key)).status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)

    cluster.add_pending_node(Datastore::AddPendingNodeRequest.new(42_u64, "Kitchen"))
    acl = Datastore::DatastoreAccessControlEntryStruct.new(
      Datastore::DatastoreAccessControlEntryPrivilegeEnum::Operate,
      Datastore::DatastoreAccessControlEntryAuthModeEnum::CASE,
      [42_u64], nil)
    cluster.add_acl_to_node(Datastore::AddACLToNodeRequest.new(42_u64, acl)).success?.should be_true
    cluster.add_acl_to_node(Datastore::AddACLToNodeRequest.new(42_u64, acl)).success?.should be_true
    cluster.node_acl_list.map(&.list_id).should eq([0_u16, 1_u16])
    cluster.record_endpoint(42_u64, 1_u16, "Light")
    binding = Datastore::DatastoreBindingTargetStruct.new(node: 42_u64, endpoint: 1_u16)
    cluster.add_binding_to_endpoint_for_node(Datastore::AddBindingToEndpointForNodeRequest.new(42_u64, 1_u16, binding)).success?.should be_true
    cluster.endpoint_binding_list.first.list_id.should eq(2_u16)
    cluster.node_acl_list.first.status_entry.state.should eq(Datastore::DatastoreStateEnum::Pending)
    cluster.complete_acl(42_u64, 0_u16).should be_true
    cluster.node_acl_list.first.status_entry.state.should eq(Datastore::DatastoreStateEnum::Committed)
    cluster.remove_acl_from_node(Datastore::RemoveACLFromNodeRequest.new(0_u16, 42_u64)).success?.should be_true
    cluster.node_acl_list.first.status_entry.state.should eq(Datastore::DatastoreStateEnum::DeletePending)
    cluster.complete_acl(42_u64, 0_u16).should be_true
    cluster.node_acl_list.map(&.list_id).should eq([1_u16])
  end

  it "rejects oversized datastore ACL subjects and targets without changing state" do
    cluster = Datastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    cluster.add_pending_node(Datastore::AddPendingNodeRequest.new(42_u64, "Kitchen")).success?.should be_true
    privilege = Datastore::DatastoreAccessControlEntryPrivilegeEnum::Operate
    auth_mode = Datastore::DatastoreAccessControlEntryAuthModeEnum::CASE
    target = Datastore::DatastoreAccessControlTargetStruct.new(nil, 1_u16, nil)
    before = cluster.save_state
    version = cluster.data_version

    [
      Datastore::DatastoreAccessControlEntryStruct.new(privilege, auth_mode, [1_u64, 2_u64, 3_u64, 4_u64, 5_u64], nil),
      Datastore::DatastoreAccessControlEntryStruct.new(privilege, auth_mode, nil, [target, target, target, target]),
    ].each do |acl|
      cluster.add_acl_to_node(Datastore::AddACLToNodeRequest.new(42_u64, acl))
        .status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
      cluster.node_acl_list.should be_empty
      cluster.data_version.should eq(version)
      cluster.save_state.should eq(before)
    end
  end

  it "accepts datastore ACL lists at their Access Control capacity and nullable lists" do
    cluster = Datastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    cluster.add_pending_node(Datastore::AddPendingNodeRequest.new(42_u64, "Kitchen")).success?.should be_true
    privilege = Datastore::DatastoreAccessControlEntryPrivilegeEnum::Operate
    auth_mode = Datastore::DatastoreAccessControlEntryAuthModeEnum::CASE
    target = Datastore::DatastoreAccessControlTargetStruct.new(nil, 1_u16, nil)
    bounded = Datastore::DatastoreAccessControlEntryStruct.new(privilege, auth_mode,
      [1_u64, 2_u64, 3_u64, 4_u64], [target, target, target])
    nullable = Datastore::DatastoreAccessControlEntryStruct.new(privilege, auth_mode, nil, nil)

    cluster.add_acl_to_node(Datastore::AddACLToNodeRequest.new(42_u64, bounded)).success?.should be_true
    cluster.add_acl_to_node(Datastore::AddACLToNodeRequest.new(42_u64, nullable)).success?.should be_true
    cluster.node_acl_list.map(&.acl_entry).should eq([bounded, nullable])
  end

  it "reserves key set zero when an Anchor Datastore is initialized" do
    cluster = Datastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    cluster.configure_anchor(Bytes[1], 42_u64, 0xFFF1_u16, "Anchor").success?.should be_true
    cluster.group_key_set_list.map(&.group_key_set_id).should eq([0_u16])
    reserved = cluster.group_key_set_list.first
    cluster.add_key_set(Datastore::AddKeySetRequest.new(reserved)).status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    cluster.update_key_set(Datastore::UpdateKeySetRequest.new(reserved)).success?.should be_true
    cluster.remove_key_set(Datastore::RemoveKeySetRequest.new(0_u16)).status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    invalid = Datastore::DatastoreGroupKeySetStruct.new(UInt16::MAX,
      Datastore::DatastoreGroupKeySecurityPolicyEnum::TrustFirst,
      nil, nil, nil, nil, nil, nil)
    cluster.add_key_set(Datastore::AddKeySetRequest.new(invalid)).status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    cluster.remove_key_set(Datastore::RemoveKeySetRequest.new(UInt16::MAX)).status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
  end

  it "updates the Anchor IPK key set and stages associated node delivery" do
    cluster = Datastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    cluster.on_ipk_key_set_updated = ->(_store : Datastore, _entry : Datastore::DatastoreGroupKeySetStruct) { nil }
    first = Bytes.new(16, 0xA5_u8)
    second = Bytes.new(16, 0xB6_u8)
    cluster.configure_anchor(Bytes[1], 42_u64, 0xFFF1_u16, "Anchor", first).success?.should be_true
    cluster.add_pending_node(Datastore::AddPendingNodeRequest.new(43_u64, "Device")).success?.should be_true
    committed = Datastore::DatastoreStatusEntryStruct.new(Datastore::DatastoreStateEnum::Committed, 0_u32, 0_u8)
    cluster.node_key_set_list = [Datastore::DatastoreNodeKeySetEntryStruct.new(43_u64, 0_u16, committed)]
    zero_time_update = Datastore::DatastoreGroupKeySetStruct.new(0_u16,
      Datastore::DatastoreGroupKeySecurityPolicyEnum::TrustFirst,
      first, 0_u64, second, 2_u64, nil, nil)
    cluster.update_key_set(Datastore::UpdateKeySetRequest.new(zero_time_update)).status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    updated = Datastore::DatastoreGroupKeySetStruct.new(0_u16,
      Datastore::DatastoreGroupKeySecurityPolicyEnum::TrustFirst,
      first, 1_u64, second, 2_u64, nil, nil)
    cluster.update_key_set(Datastore::UpdateKeySetRequest.new(updated)).success?.should be_true
    cluster.group_key_set_list.first.epoch_key1.should eq(second)
    cluster.node_key_set_list.first.status_entry.state.should eq(Datastore::DatastoreStateEnum::Pending)
    cleared = Datastore::DatastoreGroupKeySetStruct.new(0_u16,
      Datastore::DatastoreGroupKeySecurityPolicyEnum::TrustFirst,
      nil, nil, nil, nil, nil, nil)
    cluster.update_key_set(Datastore::UpdateKeySetRequest.new(cleared)).status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    cluster.remove_key_set(Datastore::RemoveKeySetRequest.new(0_u16)).status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
  end

  it "does not acknowledge an IPK update without a durable host callback" do
    cluster = Datastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    first = Bytes.new(16, 0xA5_u8)
    cluster.configure_anchor(Bytes[1], 42_u64, 0xFFF1_u16, "Anchor", first).success?.should be_true
    before_version = cluster.data_version
    updated = Datastore::DatastoreGroupKeySetStruct.new(0_u16,
      Datastore::DatastoreGroupKeySecurityPolicyEnum::TrustFirst,
      first, 1_u64, nil, nil, nil, nil)
    cluster.update_key_set(Datastore::UpdateKeySetRequest.new(updated)).status.should eq(Matter::InteractionModel::StatusCode::Failure)
    cluster.data_version.should eq(before_version)
    cluster.group_key_set_list.first.epoch_start_time0.should eq(0_u64)
  end

  it "restores the IPK and data version when durable rotation fails" do
    cluster = Datastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    first = Bytes.new(16, 0xA5_u8)
    cluster.configure_anchor(Bytes[1], 42_u64, 0xFFF1_u16, "Anchor", first).success?.should be_true
    before_version = cluster.data_version
    cluster.on_ipk_key_set_updated = ->(_store : Datastore, _entry : Datastore::DatastoreGroupKeySetStruct) do
      raise Matter::StorageError.new("injected failure")
    end
    updated = Datastore::DatastoreGroupKeySetStruct.new(0_u16,
      Datastore::DatastoreGroupKeySecurityPolicyEnum::TrustFirst,
      first, 1_u64, nil, nil, nil, nil)
    cluster.update_key_set(Datastore::UpdateKeySetRequest.new(updated)).status.should eq(Matter::InteractionModel::StatusCode::Failure)
    cluster.data_version.should eq(before_version)
    cluster.group_key_set_list.first.epoch_start_time0.should eq(0_u64)
  end

  it "rejects key sets that a device cannot install without changing datastore state" do
    policy = Datastore::DatastoreGroupKeySecurityPolicyEnum::TrustFirst
    key = Bytes.new(16, 1_u8)
    invalid = [
      Datastore::DatastoreGroupKeySetStruct.new(10_u16, policy, nil, nil, nil, nil, nil, nil),
      Datastore::DatastoreGroupKeySetStruct.new(10_u16, policy, key, 0_u64, nil, nil, nil, nil),
      Datastore::DatastoreGroupKeySetStruct.new(10_u16, policy, key, 1_u64, nil, nil, key, 3_u64),
    ]
    cluster = Datastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    before = cluster.save_state
    version = cluster.data_version
    notifications = 0
    cluster.on_version_changed = -> { notifications += 1; nil }

    invalid.each do |entry|
      cluster.add_key_set(Datastore::AddKeySetRequest.new(entry)).status
        .should eq(Matter::InteractionModel::StatusCode::ConstraintError)
      cluster.group_key_set_list.should be_empty
      cluster.save_state.should eq(before)
      cluster.data_version.should eq(version)
      notifications.should eq(0)
    end

    valid = Datastore::DatastoreGroupKeySetStruct.new(10_u16, policy, key, 1_u64, nil, nil, nil, nil)
    cluster.add_key_set(Datastore::AddKeySetRequest.new(valid)).success?.should be_true
    committed = Datastore::DatastoreStatusEntryStruct.new(Datastore::DatastoreStateEnum::Committed, 0_u32, 0_u8)
    cluster.node_key_set_list = [Datastore::DatastoreNodeKeySetEntryStruct.new(42_u64, 10_u16, committed)]
    before = cluster.save_state
    version = cluster.data_version
    notifications = 0

    invalid.each do |entry|
      cluster.update_key_set(Datastore::UpdateKeySetRequest.new(entry)).status
        .should eq(Matter::InteractionModel::StatusCode::ConstraintError)
      cluster.group_key_set_list.should eq([valid])
      cluster.node_key_set_list.first.status_entry.state.should eq(Datastore::DatastoreStateEnum::Committed)
      cluster.save_state.should eq(before)
      cluster.data_version.should eq(version)
      notifications.should eq(0)
    end
  end

  it "allows removing a key set when every node reference is DeletePending" do
    cluster = Datastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    key = Datastore::DatastoreGroupKeySetStruct.new(10_u16,
      Datastore::DatastoreGroupKeySecurityPolicyEnum::TrustFirst,
      Bytes.new(16, 1_u8), 1_u64, nil, nil, nil, nil)
    cluster.add_key_set(Datastore::AddKeySetRequest.new(key)).success?.should be_true
    cluster.add_group(Datastore::AddGroupRequest.new(10_u16, "Group", 10_u16, nil, nil,
      Datastore::DatastoreAccessControlEntryPrivilegeEnum::Operate)).success?.should be_true
    cluster.node_key_set_list = [Datastore::DatastoreNodeKeySetEntryStruct.new(42_u64, 10_u16,
      Datastore::DatastoreStatusEntryStruct.new(Datastore::DatastoreStateEnum::Committed, 0_u32, 0_u8))]
    cluster.remove_key_set(Datastore::RemoveKeySetRequest.new(10_u16)).status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)

    cluster.node_key_set_list = [Datastore::DatastoreNodeKeySetEntryStruct.new(42_u64, 10_u16,
      Datastore::DatastoreStatusEntryStruct.new(Datastore::DatastoreStateEnum::DeletePending, 0_u32, 0_u8))]
    cluster.remove_key_set(Datastore::RemoveKeySetRequest.new(10_u16)).success?.should be_true
    cluster.group_key_set_list.should be_empty
  end

  it "marks affected node key sets Pending when key material changes" do
    cluster = Datastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    key = Datastore::DatastoreGroupKeySetStruct.new(10_u16,
      Datastore::DatastoreGroupKeySecurityPolicyEnum::TrustFirst,
      Bytes.new(16, 1_u8), 1_u64, nil, nil, nil, nil)
    cluster.add_key_set(Datastore::AddKeySetRequest.new(key)).success?.should be_true
    committed = Datastore::DatastoreStatusEntryStruct.new(Datastore::DatastoreStateEnum::Committed, 0_u32, 0_u8)
    deleting = Datastore::DatastoreStatusEntryStruct.new(Datastore::DatastoreStateEnum::DeletePending, 0_u32, 0_u8)
    cluster.node_key_set_list = [
      Datastore::DatastoreNodeKeySetEntryStruct.new(42_u64, 10_u16, committed),
      Datastore::DatastoreNodeKeySetEntryStruct.new(43_u64, 10_u16, deleting),
      Datastore::DatastoreNodeKeySetEntryStruct.new(44_u64, 11_u16, committed),
    ]
    cluster.update_key_set(Datastore::UpdateKeySetRequest.new(key)).success?.should be_true
    cluster.node_key_set_list.first.status_entry.state.should eq(Datastore::DatastoreStateEnum::Committed)
    updated = Datastore::DatastoreGroupKeySetStruct.new(10_u16,
      Datastore::DatastoreGroupKeySecurityPolicyEnum::TrustFirst,
      Bytes.new(16, 2_u8), 2_u64, nil, nil, nil, nil)
    cluster.update_key_set(Datastore::UpdateKeySetRequest.new(updated)).success?.should be_true
    cluster.node_key_set_list.map(&.status_entry.state).should eq([
      Datastore::DatastoreStateEnum::Pending,
      Datastore::DatastoreStateEnum::DeletePending,
      Datastore::DatastoreStateEnum::Committed,
    ])
  end

  it "marks an unused previous key set DeletePending after UpdateGroup" do
    cluster = Datastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    cluster.add_pending_node(Datastore::AddPendingNodeRequest.new(42_u64, "Light"))
    cluster.record_endpoint(42_u64, 1_u16, "Light")
    privilege = Datastore::DatastoreAccessControlEntryPrivilegeEnum::Operate
    cluster.add_group(Datastore::AddGroupRequest.new(10_u16, "Group", 10_u16, nil, nil, privilege))
    cluster.add_group_id_to_endpoint_for_node(Datastore::AddGroupIDToEndpointForNodeRequest.new(42_u64, 1_u16, 10_u16))
    cluster.node_key_set_list.first.status_entry = Datastore::DatastoreStatusEntryStruct.new(
      Datastore::DatastoreStateEnum::Committed, 0_u32, 0_u8)

    cluster.update_group(Datastore::UpdateGroupRequest.new(10_u16, nil, 11_u16, nil, nil, nil)).success?.should be_true
    old_key = cluster.node_key_set_list.find(&.group_key_set_id.==(10_u16)).as(Datastore::DatastoreNodeKeySetEntryStruct)
    new_key = cluster.node_key_set_list.find(&.group_key_set_id.==(11_u16)).as(Datastore::DatastoreNodeKeySetEntryStruct)
    old_key.status_entry.state.should eq(Datastore::DatastoreStateEnum::DeletePending)
    new_key.status_entry.state.should eq(Datastore::DatastoreStateEnum::Pending)
  end

  it "rejects a group membership when its key set would exceed NodeKeySetList capacity" do
    cluster = Datastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    cluster.add_pending_node(Datastore::AddPendingNodeRequest.new(42_u64, "Light"))
    cluster.record_endpoint(42_u64, 1_u16, "Light")
    privilege = Datastore::DatastoreAccessControlEntryPrivilegeEnum::Operate
    cluster.add_group(Datastore::AddGroupRequest.new(10_u16, "Group", 10_u16, nil, nil, privilege))
    cluster.node_key_set_list = full_node_key_set_list
    before = cluster.save_state
    version = cluster.data_version
    notifications = 0
    cluster.on_version_changed = -> { notifications += 1; nil }

    cluster.add_group_id_to_endpoint_for_node(Datastore::AddGroupIDToEndpointForNodeRequest.new(42_u64, 1_u16, 10_u16))
      .status.should eq(Matter::InteractionModel::StatusCode::ResourceExhausted)
    cluster.endpoint_group_id_list.should be_empty
    cluster.node_key_set_list.size.should eq(Datastore::MAX_NODE_ENTRIES)
    cluster.save_state.should eq(before)
    cluster.data_version.should eq(version)
    notifications.should eq(0)
  end

  it "rejects a group key-set update before changing GroupList when NodeKeySetList is full" do
    cluster = Datastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    cluster.add_pending_node(Datastore::AddPendingNodeRequest.new(42_u64, "Light"))
    cluster.record_endpoint(42_u64, 1_u16, "Light")
    privilege = Datastore::DatastoreAccessControlEntryPrivilegeEnum::Operate
    cluster.add_group(Datastore::AddGroupRequest.new(10_u16, "Group", nil, nil, nil, privilege))
    cluster.add_group_id_to_endpoint_for_node(Datastore::AddGroupIDToEndpointForNodeRequest.new(42_u64, 1_u16, 10_u16))
    cluster.node_key_set_list = full_node_key_set_list
    before = cluster.save_state
    version = cluster.data_version
    notifications = 0
    cluster.on_version_changed = -> { notifications += 1; nil }

    cluster.update_group(Datastore::UpdateGroupRequest.new(10_u16, "Changed", 10_u16, nil, nil, nil))
      .status.should eq(Matter::InteractionModel::StatusCode::ResourceExhausted)
    cluster.group_list.first.friendly_name.should eq("Group")
    cluster.group_list.first.group_key_set_id.should be_nil
    cluster.node_key_set_list.size.should eq(Datastore::MAX_NODE_ENTRIES)
    cluster.save_state.should eq(before)
    cluster.data_version.should eq(version)
    notifications.should eq(0)
  end

  it "counts distinct nodes once when a group key-set update fills the final slot" do
    cluster = Datastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    cluster.add_pending_node(Datastore::AddPendingNodeRequest.new(42_u64, "Light"))
    cluster.record_endpoint(42_u64, 1_u16, "First")
    cluster.record_endpoint(42_u64, 2_u16, "Second")
    privilege = Datastore::DatastoreAccessControlEntryPrivilegeEnum::Operate
    cluster.add_group(Datastore::AddGroupRequest.new(10_u16, "Group", nil, nil, nil, privilege))
    cluster.add_group_id_to_endpoint_for_node(Datastore::AddGroupIDToEndpointForNodeRequest.new(42_u64, 1_u16, 10_u16))
    cluster.add_group_id_to_endpoint_for_node(Datastore::AddGroupIDToEndpointForNodeRequest.new(42_u64, 2_u16, 10_u16))
    cluster.node_key_set_list = full_node_key_set_list.first(Datastore::MAX_NODE_ENTRIES - 1)

    cluster.update_group(Datastore::UpdateGroupRequest.new(10_u16, nil, 10_u16, nil, nil, nil))
      .success?.should be_true
    cluster.node_key_set_list.size.should eq(Datastore::MAX_NODE_ENTRIES)
    cluster.node_key_set_list.count { |entry| entry.node_id == 42_u64 && entry.group_key_set_id == 10_u16 }.should eq(1)
  end

  it "retains group membership until device removal is confirmed" do
    cluster = Datastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    cluster.add_pending_node(Datastore::AddPendingNodeRequest.new(42_u64, "Kitchen"))
    cluster.record_endpoint(42_u64, 1_u16, "Light")
    cluster.add_group(Datastore::AddGroupRequest.new(1_u16, "Lights", nil, nil, nil,
      Datastore::DatastoreAccessControlEntryPrivilegeEnum::Operate))
    cluster.add_group_id_to_endpoint_for_node(Datastore::AddGroupIDToEndpointForNodeRequest.new(42_u64, 1_u16, 1_u16))
    cluster.remove_group(Datastore::RemoveGroupRequest.new(1_u16)).status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    cluster.remove_group_id_from_endpoint_for_node(Datastore::RemoveGroupIDFromEndpointForNodeRequest.new(42_u64, 1_u16, 1_u16)).success?.should be_true
    cluster.remove_group(Datastore::RemoveGroupRequest.new(1_u16)).success?.should be_true
    cluster.endpoint_group_id_list.first.status_entry.state.should eq(Datastore::DatastoreStateEnum::DeletePending)
    cluster.complete_group_membership(42_u64, 1_u16, 1_u16).should be_true
    cluster.endpoint_group_id_list.should be_empty
  end

  it "preserves pending group removal when the group's friendly name changes" do
    cluster = Datastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    cluster.add_pending_node(Datastore::AddPendingNodeRequest.new(42_u64, "Node"))
    cluster.record_endpoint(42_u64, 1_u16, "Removing")
    cluster.record_endpoint(42_u64, 2_u16, "Retained")
    cluster.add_group(Datastore::AddGroupRequest.new(1_u16, "Old", nil, nil, nil,
      Datastore::DatastoreAccessControlEntryPrivilegeEnum::Operate))
    cluster.add_group_id_to_endpoint_for_node(Datastore::AddGroupIDToEndpointForNodeRequest.new(42_u64, 1_u16, 1_u16))
    cluster.add_group_id_to_endpoint_for_node(Datastore::AddGroupIDToEndpointForNodeRequest.new(42_u64, 2_u16, 1_u16))
    cluster.complete_group_membership(42_u64, 1_u16, 1_u16)
    cluster.complete_group_membership(42_u64, 2_u16, 1_u16)
    cluster.remove_group_id_from_endpoint_for_node(Datastore::RemoveGroupIDFromEndpointForNodeRequest.new(42_u64, 1_u16, 1_u16))
      .success?.should be_true

    cluster.update_group(Datastore::UpdateGroupRequest.new(1_u16, "New", nil, nil, nil, nil))
      .success?.should be_true
    cluster.endpoint_group_id_list.find!(&.endpoint_id.==(1_u16)).status_entry.state
      .should eq(Datastore::DatastoreStateEnum::DeletePending)
    cluster.endpoint_group_id_list.find!(&.endpoint_id.==(2_u16)).status_entry.state
      .should eq(Datastore::DatastoreStateEnum::Pending)
  end

  it "rearms failed deletions when the node is refreshed" do
    cluster = Datastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    cluster.add_pending_node(Datastore::AddPendingNodeRequest.new(42_u64, "Kitchen"))
    cluster.record_endpoint(42_u64, 1_u16, "Light")
    cluster.add_group(Datastore::AddGroupRequest.new(1_u16, "Lights", nil, nil, nil,
      Datastore::DatastoreAccessControlEntryPrivilegeEnum::Operate))
    cluster.add_group_id_to_endpoint_for_node(Datastore::AddGroupIDToEndpointForNodeRequest.new(42_u64, 1_u16, 1_u16))
    cluster.remove_group_id_from_endpoint_for_node(Datastore::RemoveGroupIDFromEndpointForNodeRequest.new(42_u64, 1_u16, 1_u16))
    cluster.remove_group(Datastore::RemoveGroupRequest.new(1_u16))
    cluster.complete_group_membership(42_u64, 1_u16, 1_u16, 1_u8)
    failed = cluster.endpoint_group_id_list.first.status_entry
    failed.state.should eq(Datastore::DatastoreStateEnum::DeletePending)
    failed.failure_code.should eq(1_u8)

    cluster.refresh_node(Datastore::RefreshNodeRequest.new(42_u64)).success?.should be_true
    retried = cluster.endpoint_group_id_list.first.status_entry
    retried.state.should eq(Datastore::DatastoreStateEnum::DeletePending)
    retried.failure_code.should eq(0_u8)
  end

  it "freezes a committed Datastore as DeletePending during Anchor transfer" do
    cluster = Datastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    cluster.configure_anchor(Bytes[1], 42_u64, 0xFFF1_u16, "Anchor").success?.should be_true
    cluster.add_pending_node(Datastore::AddPendingNodeRequest.new(43_u64, "Light"))
    cluster.begin_anchor_transfer.should be_false
    cluster.complete_node(43_u64)
    cluster.begin_anchor_transfer.should be_true
    cluster.status.state.should eq(Datastore::DatastoreStateEnum::DeletePending)
    cluster.add_group(Datastore::AddGroupRequest.new(1_u16, "Lights", nil, nil, nil,
      Datastore::DatastoreAccessControlEntryPrivilegeEnum::Operate)).status.should eq(Matter::InteractionModel::StatusCode::Busy)
    cluster.refresh_node(Datastore::RefreshNodeRequest.new(43_u64)).status.should eq(Matter::InteractionModel::StatusCode::Busy)
    restored = Datastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    restored.restore_state(cluster.save_state.as(Matter::Storage::Document))
    restored.status.state.should eq(Datastore::DatastoreStateEnum::DeletePending)
  end
end

describe Matter::Cluster::JointFabricAdministrator do
  it "publishes the Matter 1.6 Administrator schema" do
    cluster = Matter::Cluster::JointFabricAdministrator.new(Matter::DataType::EndpointNumber.new(1_u16))
    cluster.cluster_revision.should eq(1_u16)
    cluster.attributes.size.should eq(1)
    cluster.commands.size.should eq(6)
    expect_raises(Matter::ConfigurationError, /1\.\.254/) { cluster.administrator_fabric_index = 0_u8 }
    expect_raises(Matter::ConfigurationError, /1\.\.254/) { cluster.administrator_fabric_index = 255_u8 }
    cluster.administrator_fabric_index = 1_u8
    cluster.administrator_fabric_index.should eq(1_u8)
    cluster.invoke_command(Matter::Cluster::JointFabricAdministrator::CMD_ICACCSR_REQUEST)
      .as(Matter::InteractionModel::Status).success?.should be_false
  end
end

describe "joint commissioning advertisement" do
  it "uses CM=3 and the anchor/datastore JF bitmap" do
    cluster = Matter::Cluster::AdministratorCommissioning.new(Matter::DataType::EndpointNumber.new(0_u16))
    advertised_mode = nil.as(Matter::MDNS::CommissioningMode?)
    cluster.on_start_commissioning_advertising = ->(_discriminator : UInt16?, mode : Matter::MDNS::CommissioningMode) do
      advertised_mode = mode
    end
    request = Matter::Cluster::AdministratorCommissioning::OpenCommissioningWindowRequest.new(
      180_u16, Bytes.new(97), 3840_u16, 1000_u32, Bytes.new(16))
    cluster.open_commissioning_window(request, 1_u8, 0xFFF1_u16, joint: true)
    advertised_mode.should eq(Matter::MDNS::CommissioningMode::Joint)
    cluster.window.close

    roles = Matter::MDNS::JointFabricRole::Administrator |
            Matter::MDNS::JointFabricRole::Anchor |
            Matter::MDNS::JointFabricRole::Datastore
    info = Matter::MDNS::CommissioningInfo.new("Anchor", 0xFFF1_u16, 0x0130_u16,
      3840_u16, Matter::DeviceType::JOINT_FABRIC_ADMINISTRATOR,
      commissioning_mode: Matter::MDNS::CommissioningMode::Joint,
      joint_fabric_role: roles)
    info.to_txt_records["CM"].should eq("3")
    info.to_txt_records["JF"].should eq("14")
  end
end
