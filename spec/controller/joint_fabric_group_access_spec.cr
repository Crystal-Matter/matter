require "../spec_helper"
require "../../src/matter/controller"

private alias JointStore = Matter::Cluster::JointFabricDatastore

private class JointGroupImClient < Matter::Controller::ImClient
  getter commands = [] of UInt32
  property? lose_update_response = false
  property reported_anchor_node_id : UInt64? = nil

  def initialize(@store : JointStore)
    super(Matter::Controller::Client.new)
  end

  def close : Nil
    @client.close
  end

  def read_attribute(session : Matter::Session::SecureContext, peer : Socket::IPAddress,
                     endpoint_id : UInt16, cluster_id : UInt32, attribute_id : UInt32,
                     fabric_filtered : Bool = true) : Matter::InteractionModel::ReportDataMessage
    value = case attribute_id
            when JointStore::ATTR_ANCHOR_ROOT_CA         then @store.anchor_root_ca.to_tlv
            when JointStore::ATTR_ANCHOR_NODE_ID         then (@reported_anchor_node_id || @store.anchor_node_id).to_tlv
            when JointStore::ATTR_GROUP_LIST             then @store.group_list.to_tlv
            when JointStore::ATTR_GROUP_KEY_SET_LIST     then @store.group_key_set_list.to_tlv
            when JointStore::ATTR_NODE_KEY_SET_LIST      then @store.node_key_set_list.to_tlv
            when JointStore::ATTR_ENDPOINT_GROUP_ID_LIST then @store.endpoint_group_id_list.to_tlv
            when JointStore::ATTR_NODE_ACL_LIST          then @store.node_acl_list.to_tlv
            else                                              raise Matter::ProtocolError.new("Unexpected Joint Fabric Datastore read")
            end
    path = Matter::InteractionModel::AttributePath.new(endpoint: endpoint_id, cluster: cluster_id, attribute: attribute_id)
    data = Matter::InteractionModel::AttributeDataIB.new(path: path, data: TLV::Any.from_slice(value))
    Matter::InteractionModel::ReportDataMessage.new(attribute_reports: [Matter::InteractionModel::AttributeReportIB.new(attribute_data: data)])
  end

  def invoke(session : Matter::Session::SecureContext, peer : Socket::IPAddress,
             endpoint_id : UInt16, cluster_id : UInt32, command_id : UInt32,
             fields : Bytes = Bytes.empty, timed_request : Bool = false,
             timed_request_timeout : Time::Span = DEFAULT_TIMED_REQUEST_TIMEOUT) : Matter::InteractionModel::InvokeResponseMessage
    @commands << command_id
    result = case command_id
             when JointStore::CMD_ADD_KEY_SET
               @store.add_key_set(JointStore::AddKeySetRequest.from_slice(fields))
             when JointStore::CMD_ADD_GROUP
               @store.add_group(JointStore::AddGroupRequest.from_slice(fields))
             when JointStore::CMD_ADD_GROUP_ID_TO_ENDPOINT_FOR_NODE
               @store.add_group_id_to_endpoint_for_node(JointStore::AddGroupIDToEndpointForNodeRequest.from_slice(fields))
             when JointStore::CMD_ADD_ACL_TO_NODE
               @store.add_acl_to_node(JointStore::AddACLToNodeRequest.from_slice(fields))
             when JointStore::CMD_REFRESH_NODE
               @store.refresh_node(JointStore::RefreshNodeRequest.from_slice(fields))
             when JointStore::CMD_UPDATE_GROUP
               update_status = @store.update_group(JointStore::UpdateGroupRequest.from_slice(fields))
               if @lose_update_response
                 @lose_update_response = false
                 raise Matter::ProtocolError.new("Simulated lost UpdateGroup response")
               end
               update_status
             else
               raise Matter::ProtocolError.new("Unexpected Joint Fabric Datastore command")
             end
    path = Matter::InteractionModel::CommandPath.new(endpoint: endpoint_id, cluster: cluster_id, command: command_id)
    status = Matter::InteractionModel::CommandStatusIB.new(path,
      Matter::InteractionModel::StatusIB.new(result.status.value))
    Matter::InteractionModel::InvokeResponseMessage.new(invoke_responses: [Matter::InteractionModel::InvokeResponseIB.new(command_status: status)])
  end
end

describe "Joint Fabric shared group revocation" do
  it "rotates the CAT for survivors and stays pending until target ACL delivery succeeds" do
    bootstrap = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(0x1234_u64, 0x100_u64, 0xFFF1_u16)
    authority = bootstrap.fabric
    revoked = Matter::Controller::SharedFabric.delegate_joint(authority, 0x101_u64, 0x1234_u16, 2_u16)
    survivor = Matter::Controller::SharedFabric.delegate_joint(authority, 0x102_u64, 0x1234_u16, 2_u16)
    survivor_store = Matter::Controller::StateStore.new(Matter::Storage::Memory.new)
    Matter::Controller::SharedFabric.install(survivor_store, survivor)

    datastore = JointStore.new(Matter::DataType::EndpointNumber.new(1_u16))
    datastore.configure_anchor(authority.root_cert, 0x100_u64, 0xFFF1_u16, "Anchor")
    datastore.add_pending_node(JointStore::AddPendingNodeRequest.new(0x200_u64, "Lamp"))
    datastore.record_endpoint(0x200_u64, 1_u16, "Light")
    im = JointGroupImClient.new(datastore)
    session = Matter::Session::SecureContext.new(
      session_id: 1_u16, peer_session_id: 1_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16), decryption_key: Bytes.new(16), case_session: true,
      peer_node_id: Matter::DataType::NodeId.new(0x100_u64))
    peer = Socket::IPAddress.new("127.0.0.1", 5540)
    Matter::Controller::SharedFabric.grant_joint_admin(im, session, peer,
      datastore_endpoint: 1_u16, anchor_node_id: authority.controller_node_id,
      device_node_id: 0x200_u64, device_endpoint: 1_u16,
      group_id: 10_u16, group_name: "Controllers", controller: survivor)
    membership = datastore.endpoint_group_id_list.last
    acl = datastore.node_acl_list.last
    datastore.complete_group_membership(0x200_u64, 1_u16, 10_u16).should be_true
    datastore.complete_acl(0x200_u64, acl.list_id).should be_true
    older_acl = acl.acl_entry
    older_acl.subjects = [Matter::DataType::NodeId.from_case_authenticated_tag(
      Matter::DataType::CaseAuthenticatedTag.create(0x1234_u16, 1_u16)).id]
    datastore.add_acl_to_node(JointStore::AddACLToNodeRequest.new(0x200_u64, older_acl))
    second_acl = datastore.node_acl_list.last
    datastore.complete_acl(0x200_u64, second_acl.list_id).should be_true

    session.peer_node_id = Matter::DataType::NodeId.new(0x999_u64)
    expect_raises(Matter::AuthenticationError, /expected Anchor/) do
      Matter::Controller::SharedFabric.stage_joint_group_revocation(im, session, peer,
        datastore_endpoint: 1_u16, group_id: 10_u16, revoked: revoked,
        survivors: [{survivor_store, survivor.controller_node_id}], authority: authority,
        anchor_node_id: 0x100_u64)
    end
    survivor_store.load.fabric_for(authority.fabric_id, authority.root_public_key)
      .controller_noc.should eq(survivor.controller_noc)
    session.peer_node_id = Matter::DataType::NodeId.new(0x100_u64)

    receipt = Matter::Controller::SharedFabric.stage_joint_group_revocation(im, session, peer,
      datastore_endpoint: 1_u16, group_id: 10_u16, revoked: revoked,
      survivors: [{survivor_store, survivor.controller_node_id}], authority: authority,
      anchor_node_id: 0x100_u64)
    receipt.target_node_ids.should eq([0x200_u64])
    receipt.target_acls.map(&.list_id).should eq([acl.list_id, second_acl.list_id])
    Matter::Controller::SharedFabric::JointGroupRevocation.from_document(receipt.to_document)
      .target_acls.map(&.list_id).should eq(receipt.target_acls.map(&.list_id))
    im.commands.last.should eq(JointStore::CMD_UPDATE_GROUP)
    datastore.group_list.last.group_cat_version.should eq(3_u16)
    datastore.endpoint_group_id_list.last.group_id.should eq(membership.group_id)
    datastore.endpoint_group_id_list.last.status_entry.state.should eq(JointStore::DatastoreStateEnum::Committed)
    datastore.node_acl_list.last.acl_entry.subjects.should eq([
      Matter::DataType::NodeId.from_case_authenticated_tag(
        Matter::DataType::CaseAuthenticatedTag.create(0x1234_u16, 3_u16)).id,
    ])
    datastore.node_acl_list.last.status_entry.state.should eq(JointStore::DatastoreStateEnum::Pending)

    renewed = survivor_store.load.fabric_for(authority.fabric_id, authority.root_public_key)
    Matter::Crypto::MatterCertificate.public_key_from_tlv(renewed.controller_noc).should eq(
      Matter::Crypto::MatterCertificate.public_key_from_tlv(survivor.controller_noc))
    renewed.controller_private_key.should eq(survivor.controller_private_key)
    Matter::Crypto::MatterCertificate.subject_ids_from_tlv(renewed.controller_noc).should contain(
      Matter::DataType::NodeId.from_case_authenticated_tag(
        Matter::DataType::CaseAuthenticatedTag.create(0x1234_u16, 3_u16)).id)
    Matter::Crypto::MatterCertificate.subject_ids_from_tlv(revoked.controller_noc).should contain(
      Matter::DataType::NodeId.from_case_authenticated_tag(
        Matter::DataType::CaseAuthenticatedTag.create(0x1234_u16, 2_u16)).id)

    Matter::Controller::SharedFabric.joint_group_revocation_status(im, session, peer, 1_u16, receipt)
      .should eq(Matter::Controller::SharedFabric::JointGroupRevocation::Status::Pending)
    datastore.complete_acl(0x200_u64, acl.list_id, 1_u8).should be_true
    Matter::Controller::SharedFabric.joint_group_revocation_status(im, session, peer, 1_u16, receipt)
      .should eq(Matter::Controller::SharedFabric::JointGroupRevocation::Status::Pending)
    Matter::Controller::SharedFabric.retry_failed_joint_group_revocation(im, session, peer, 1_u16, receipt)
    im.commands.last.should eq(JointStore::CMD_REFRESH_NODE)
    datastore.node_acl_list.last.status_entry.state.should eq(JointStore::DatastoreStateEnum::Pending)
    datastore.complete_acl(0x200_u64, acl.list_id).should be_true
    Matter::Controller::SharedFabric.joint_group_revocation_status(im, session, peer, 1_u16, receipt)
      .should eq(Matter::Controller::SharedFabric::JointGroupRevocation::Status::Pending)
    datastore.complete_acl(0x200_u64, second_acl.list_id).should be_true
    Matter::Controller::SharedFabric.joint_group_revocation_status(im, session, peer, 1_u16, receipt)
      .should eq(Matter::Controller::SharedFabric::JointGroupRevocation::Status::Effective)

    changed_acls = datastore.node_acl_list
    changed_entry = changed_acls.first
    changed_acl = changed_entry.acl_entry
    changed_acl.privilege = JointStore::DatastoreAccessControlEntryPrivilegeEnum::View
    changed_entry.acl_entry = changed_acl
    changed_acls[0] = changed_entry
    datastore.node_acl_list = changed_acls
    Matter::Controller::SharedFabric.joint_group_revocation_status(im, session, peer, 1_u16, receipt)
      .should eq(Matter::Controller::SharedFabric::JointGroupRevocation::Status::Pending)
    changed_acl.privilege = JointStore::DatastoreAccessControlEntryPrivilegeEnum::Administer
    changed_entry.acl_entry = changed_acl
    changed_acls[0] = changed_entry
    datastore.node_acl_list = changed_acls
    Matter::Controller::SharedFabric.joint_group_revocation_status(im, session, peer, 1_u16, receipt)
      .should eq(Matter::Controller::SharedFabric::JointGroupRevocation::Status::Effective)

    # A later ACL using the old CAT anywhere in the group reopens access.
    datastore.add_acl_to_node(JointStore::AddACLToNodeRequest.new(0x200_u64, acl.acl_entry))
    stale_acl_id = datastore.node_acl_list.last.list_id
    Matter::Controller::SharedFabric.joint_group_revocation_status(im, session, peer, 1_u16, receipt)
      .should eq(Matter::Controller::SharedFabric::JointGroupRevocation::Status::Pending)
    datastore.remove_acl_from_node(JointStore::RemoveACLFromNodeRequest.new(stale_acl_id, 0x200_u64))
      .success?.should be_true
    datastore.complete_acl(0x200_u64, stale_acl_id).should be_true
    Matter::Controller::SharedFabric.joint_group_revocation_status(im, session, peer, 1_u16, receipt)
      .should eq(Matter::Controller::SharedFabric::JointGroupRevocation::Status::Effective)

    # Group permission is also part of the revocation proof.
    datastore.update_group(JointStore::UpdateGroupRequest.new(10_u16, nil, nil, nil, nil,
      JointStore::DatastoreAccessControlEntryPrivilegeEnum::View)).success?.should be_true
    datastore.node_acl_list.each { |entry| datastore.complete_acl(entry.node_id, entry.list_id) }
    Matter::Controller::SharedFabric.joint_group_revocation_status(im, session, peer, 1_u16, receipt)
      .should eq(Matter::Controller::SharedFabric::JointGroupRevocation::Status::Pending)
  ensure
    im.try(&.close)
  end

  it "recovers a pending receipt after the Anchor applies UpdateGroup but its response is lost" do
    bootstrap = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(0x1234_u64, 0x100_u64, 0xFFF1_u16)
    authority = bootstrap.fabric
    revoked = Matter::Controller::SharedFabric.delegate_joint(authority, 0x101_u64, 0x1234_u16, 2_u16)
    survivor = Matter::Controller::SharedFabric.delegate_joint(authority, 0x102_u64, 0x1234_u16, 2_u16)
    survivor_store = Matter::Controller::StateStore.new(Matter::Storage::Memory.new)
    Matter::Controller::SharedFabric.install(survivor_store, survivor)
    datastore = JointStore.new(Matter::DataType::EndpointNumber.new(1_u16))
    datastore.configure_anchor(authority.root_cert, 0x100_u64, 0xFFF1_u16, "Anchor")
    datastore.add_pending_node(JointStore::AddPendingNodeRequest.new(0x200_u64, "Lamp"))
    datastore.record_endpoint(0x200_u64, 1_u16, "Light")
    im = JointGroupImClient.new(datastore)
    session = Matter::Session::SecureContext.new(
      session_id: 1_u16, peer_session_id: 1_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16), decryption_key: Bytes.new(16), case_session: true,
      peer_node_id: Matter::DataType::NodeId.new(0x100_u64))
    peer = Socket::IPAddress.new("127.0.0.1", 5540)
    Matter::Controller::SharedFabric.grant_joint_admin(im, session, peer,
      datastore_endpoint: 1_u16, anchor_node_id: authority.controller_node_id,
      device_node_id: 0x200_u64, device_endpoint: 1_u16,
      group_id: 10_u16, group_name: "Controllers", controller: survivor)
    im.lose_update_response = true
    expect_raises(Matter::ProtocolError, /lost UpdateGroup response/) do
      Matter::Controller::SharedFabric.stage_joint_group_revocation(im, session, peer,
        datastore_endpoint: 1_u16, group_id: 10_u16, revoked: revoked,
        survivors: [{survivor_store, survivor.controller_node_id}], authority: authority,
        anchor_node_id: 0x100_u64)
    end
    datastore.group_list.last.group_cat_version.should eq(3_u16)
    update_count = im.commands.count(JointStore::CMD_UPDATE_GROUP)
    receipt = Matter::Controller::SharedFabric.stage_joint_group_revocation(im, session, peer,
      datastore_endpoint: 1_u16, group_id: 10_u16, revoked: revoked,
      survivors: [{survivor_store, survivor.controller_node_id}], authority: authority,
      anchor_node_id: 0x100_u64)
    im.commands.count(JointStore::CMD_UPDATE_GROUP).should eq(update_count)
    receipt.previous_version.should eq(2_u16)
    receipt.current_version.should eq(3_u16)
    Matter::Controller::SharedFabric.joint_group_revocation_status(im, session, peer, 1_u16, receipt)
      .should eq(Matter::Controller::SharedFabric::JointGroupRevocation::Status::Pending)
  ensure
    im.try(&.close)
  end

  it "rotates the key set and CAT together for a keyed View group" do
    bootstrap = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(0x1234_u64, 0x100_u64, 0xFFF1_u16)
    authority = bootstrap.fabric
    revoked = Matter::Controller::SharedFabric.delegate_joint(authority, 0x101_u64, 0x1234_u16, 2_u16)
    survivor = Matter::Controller::SharedFabric.delegate_joint(authority, 0x102_u64, 0x1234_u16, 2_u16)
    survivor_store = Matter::Controller::StateStore.new(Matter::Storage::Memory.new)
    Matter::Controller::SharedFabric.install(survivor_store, survivor)
    datastore = JointStore.new(Matter::DataType::EndpointNumber.new(1_u16))
    datastore.configure_anchor(authority.root_cert, 0x100_u64, 0xFFF1_u16, "Anchor")
    old_key = JointStore::DatastoreGroupKeySetStruct.new(10_u16,
      JointStore::DatastoreGroupKeySecurityPolicyEnum::TrustFirst,
      Bytes.new(JointStore::EPOCH_KEY_BYTES, 0x11_u8), 1_u64, nil, nil, nil, nil)
    replacement = JointStore::DatastoreGroupKeySetStruct.new(11_u16,
      JointStore::DatastoreGroupKeySecurityPolicyEnum::TrustFirst,
      Bytes.new(JointStore::EPOCH_KEY_BYTES, 0x22_u8), 2_u64, nil, nil, nil, nil)
    view = JointStore::DatastoreAccessControlEntryPrivilegeEnum::View
    datastore.add_key_set(JointStore::AddKeySetRequest.new(old_key)).success?.should be_true
    datastore.add_group(JointStore::AddGroupRequest.new(10_u16, "Viewers", 10_u16, 0x1234_u16,
      2_u16, view)).success?.should be_true
    datastore.add_pending_node(JointStore::AddPendingNodeRequest.new(0x200_u64, "Lamp"))
    datastore.record_endpoint(0x200_u64, 1_u16, "Light")
    datastore.add_group_id_to_endpoint_for_node(JointStore::AddGroupIDToEndpointForNodeRequest.new(
      0x200_u64, 1_u16, 10_u16)).success?.should be_true
    datastore.complete_node_key_set(0x200_u64, 10_u16).should be_true
    datastore.complete_group_membership(0x200_u64, 1_u16, 10_u16).should be_true
    subject = Matter::DataType::NodeId.from_case_authenticated_tag(
      Matter::DataType::CaseAuthenticatedTag.create(0x1234_u16, 2_u16)).id
    acl = JointStore::DatastoreAccessControlEntryStruct.new(view,
      JointStore::DatastoreAccessControlEntryAuthModeEnum::CASE, [subject], nil)
    datastore.add_acl_to_node(JointStore::AddACLToNodeRequest.new(0x200_u64, acl)).success?.should be_true
    acl_id = datastore.node_acl_list.last.list_id
    datastore.complete_acl(0x200_u64, acl_id).should be_true
    im = JointGroupImClient.new(datastore)
    session = Matter::Session::SecureContext.new(
      session_id: 1_u16, peer_session_id: 1_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16), decryption_key: Bytes.new(16), case_session: true,
      peer_node_id: Matter::DataType::NodeId.new(0x100_u64))
    peer = Socket::IPAddress.new("127.0.0.1", 5540)

    expect_raises(Matter::ConfigurationError, /explicit key rotation/) do
      Matter::Controller::SharedFabric.stage_joint_group_revocation(im, session, peer,
        datastore_endpoint: 1_u16, group_id: 10_u16, revoked: revoked,
        survivors: [{survivor_store, survivor.controller_node_id}], authority: authority,
        anchor_node_id: 0x100_u64)
    end
    reused = JointStore::DatastoreGroupKeySetStruct.new(11_u16,
      JointStore::DatastoreGroupKeySecurityPolicyEnum::TrustFirst,
      old_key.epoch_key0, 2_u64, nil, nil, nil, nil)
    expect_raises(Matter::ConfigurationError, /reuses a revoked epoch key/) do
      Matter::Controller::SharedFabric.stage_joint_group_revocation(im, session, peer,
        datastore_endpoint: 1_u16, group_id: 10_u16, revoked: revoked,
        survivors: [{survivor_store, survivor.controller_node_id}], authority: authority,
        anchor_node_id: 0x100_u64,
        key_rotation: Matter::Controller::SharedFabric::JointGroupKeyRotation.new(10_u16, reused))
    end
    im.commands.should be_empty

    rotation = Matter::Controller::SharedFabric::JointGroupKeyRotation.new(10_u16, replacement)
    im.lose_update_response = true
    expect_raises(Matter::ProtocolError, /lost UpdateGroup response/) do
      Matter::Controller::SharedFabric.stage_joint_group_revocation(im, session, peer,
        datastore_endpoint: 1_u16, group_id: 10_u16, revoked: revoked,
        survivors: [{survivor_store, survivor.controller_node_id}], authority: authority,
        anchor_node_id: 0x100_u64, key_rotation: rotation)
    end
    im.commands.should eq([JointStore::CMD_ADD_KEY_SET, JointStore::CMD_UPDATE_GROUP])
    receipt = Matter::Controller::SharedFabric.stage_joint_group_revocation(im, session, peer,
      datastore_endpoint: 1_u16, group_id: 10_u16, revoked: revoked,
      survivors: [{survivor_store, survivor.controller_node_id}], authority: authority,
      anchor_node_id: 0x100_u64, key_rotation: rotation)
    im.commands.should eq([JointStore::CMD_ADD_KEY_SET, JointStore::CMD_UPDATE_GROUP])
    datastore.group_list.last.group_key_set_id.should eq(11_u16)
    datastore.group_list.last.group_cat_version.should eq(3_u16)
    receipt = Matter::Controller::SharedFabric::JointGroupRevocation.from_document(receipt.to_document)
    receipt.previous_key_set_id.should eq(10_u16)
    receipt.current_key_set_id.should eq(11_u16)
    receipt.group_permission.should eq(view)
    Matter::Controller::SharedFabric.joint_group_revocation_status(im, session, peer, 1_u16, receipt)
      .should eq(Matter::Controller::SharedFabric::JointGroupRevocation::Status::Pending)
    datastore.complete_node_key_set(0x200_u64, 11_u16, 1_u8).should be_true
    Matter::Controller::SharedFabric.retry_failed_joint_group_revocation(im, session, peer, 1_u16, receipt)
    im.commands.last.should eq(JointStore::CMD_REFRESH_NODE)
    datastore.complete_node_key_set(0x200_u64, 11_u16).should be_true
    datastore.complete_group_membership(0x200_u64, 1_u16, 10_u16).should be_true
    datastore.complete_acl(0x200_u64, acl_id).should be_true
    Matter::Controller::SharedFabric.joint_group_revocation_status(im, session, peer, 1_u16, receipt)
      .should eq(Matter::Controller::SharedFabric::JointGroupRevocation::Status::Pending)
    datastore.complete_node_key_set(0x200_u64, 10_u16).should be_true
    Matter::Controller::SharedFabric.joint_group_revocation_status(im, session, peer, 1_u16, receipt)
      .should eq(Matter::Controller::SharedFabric::JointGroupRevocation::Status::Effective)
  ensure
    im.try(&.close)
  end

  it "keeps a shared former key set when another group still needs it" do
    bootstrap = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(0x1234_u64, 0x100_u64, 0xFFF1_u16)
    authority = bootstrap.fabric
    datastore = JointStore.new(Matter::DataType::EndpointNumber.new(1_u16))
    datastore.configure_anchor(authority.root_cert, 0x100_u64, 0xFFF1_u16, "Anchor")
    view = JointStore::DatastoreAccessControlEntryPrivilegeEnum::View
    old_key = JointStore::DatastoreGroupKeySetStruct.new(10_u16,
      JointStore::DatastoreGroupKeySecurityPolicyEnum::TrustFirst,
      Bytes.new(JointStore::EPOCH_KEY_BYTES, 0x11_u8), 1_u64, nil, nil, nil, nil)
    replacement = JointStore::DatastoreGroupKeySetStruct.new(11_u16,
      JointStore::DatastoreGroupKeySecurityPolicyEnum::TrustFirst,
      Bytes.new(JointStore::EPOCH_KEY_BYTES, 0x22_u8), 2_u64, nil, nil, nil, nil)
    datastore.add_key_set(JointStore::AddKeySetRequest.new(old_key)).success?.should be_true
    datastore.add_key_set(JointStore::AddKeySetRequest.new(replacement)).success?.should be_true
    datastore.add_group(JointStore::AddGroupRequest.new(10_u16, "Rotated", 11_u16, 0x1234_u16,
      3_u16, view)).success?.should be_true
    datastore.add_group(JointStore::AddGroupRequest.new(20_u16, "Still keyed", 10_u16, nil,
      nil, view)).success?.should be_true
    datastore.add_pending_node(JointStore::AddPendingNodeRequest.new(0x200_u64, "Lamp"))
    datastore.record_endpoint(0x200_u64, 1_u16, "Light")
    {10_u16, 20_u16}.each do |group_id|
      datastore.add_group_id_to_endpoint_for_node(JointStore::AddGroupIDToEndpointForNodeRequest.new(
        0x200_u64, 1_u16, group_id)).success?.should be_true
      datastore.complete_group_membership(0x200_u64, 1_u16, group_id).should be_true
    end
    datastore.complete_node_key_set(0x200_u64, 10_u16).should be_true
    datastore.complete_node_key_set(0x200_u64, 11_u16).should be_true
    subject = Matter::DataType::NodeId.from_case_authenticated_tag(
      Matter::DataType::CaseAuthenticatedTag.create(0x1234_u16, 3_u16)).id
    acl = JointStore::DatastoreAccessControlEntryStruct.new(view,
      JointStore::DatastoreAccessControlEntryAuthModeEnum::CASE, [subject], nil)
    datastore.add_acl_to_node(JointStore::AddACLToNodeRequest.new(0x200_u64, acl)).success?.should be_true
    acl_id = datastore.node_acl_list.last.list_id
    datastore.complete_acl(0x200_u64, acl_id).should be_true
    im = JointGroupImClient.new(datastore)
    session = Matter::Session::SecureContext.new(
      session_id: 1_u16, peer_session_id: 1_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16), decryption_key: Bytes.new(16), case_session: true,
      peer_node_id: Matter::DataType::NodeId.new(0x100_u64))
    peer = Socket::IPAddress.new("127.0.0.1", 5540)
    receipt = Matter::Controller::SharedFabric::JointGroupRevocation.new(10_u16, 0x1234_u16,
      2_u16, 3_u16, [0x200_u64],
      [Matter::Controller::SharedFabric::JointGroupACLTarget.new(0x200_u64, acl_id)],
      authority.root_cert, 0x100_u64, view, 10_u16, 11_u16,
      Matter::Crypto::StandardCrypto.new.compute_sha256(replacement.to_slice),
      [Matter::Controller::SharedFabric::JointGroupMembershipTarget.new(0x200_u64, 1_u16)])
    datastore.node_key_set_list.map(&.group_key_set_id).should contain(10_u16)
    Matter::Controller::SharedFabric.joint_group_revocation_status(im, session, peer, 1_u16, receipt)
      .should eq(Matter::Controller::SharedFabric::JointGroupRevocation::Status::Effective)
  ensure
    im.try(&.close)
  end
end

describe Matter::Controller::SharedFabric do
  it "grants a Joint Fabric controller access through a Datastore CAT group" do
    bootstrap = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(0x1234_u64, 0x100_u64, 0xFFF1_u16)
    authority = bootstrap.fabric
    delegated = Matter::Controller::SharedFabric.delegate_joint(authority, 0x101_u64, 0x1234_u16, 2_u16)
    expect_raises(Matter::ConfigurationError, /group CAT/) do
      Matter::Controller::SharedFabric.delegate_joint(authority, 0x102_u64, 0x1234_u16, UInt16::MAX)
    end
    expect_raises(Matter::ConfigurationError, /intermediate CA key/) do
      Matter::Controller::SharedFabric.delegate_joint(delegated, 0x102_u64, 0x1234_u16, 2_u16)
    end
    Matter::Crypto::MatterCertificate::Validation.verify_chain(
      delegated.controller_noc, delegated.intermediate_cert, authority.root_public_key, authority.root_cert)
    Matter::Crypto::MatterCertificate.subject_ids_from_tlv(delegated.controller_noc)
      .should contain(0xFFFF_FFFD_1234_0002_u64)

    datastore = JointStore.new(Matter::DataType::EndpointNumber.new(1_u16))
    datastore.configure_anchor(authority.root_cert, 0x100_u64, 0xFFF1_u16, "Anchor")
    datastore.add_pending_node(JointStore::AddPendingNodeRequest.new(0x200_u64, "Lamp"))
    datastore.record_endpoint(0x200_u64, 1_u16, "Light")
    im = JointGroupImClient.new(datastore)
    session = Matter::Session::SecureContext.new(
      session_id: 1_u16, peer_session_id: 1_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16), decryption_key: Bytes.new(16),
      # Initiator CASE contexts do not know the remote fabric index.
      case_session: true, peer_node_id: Matter::DataType::NodeId.new(0x100_u64))
    peer = Socket::IPAddress.new("127.0.0.1", 5540)

    wrong_peer_session = Matter::Session::SecureContext.new(
      session_id: 2_u16, peer_session_id: 2_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16), decryption_key: Bytes.new(16),
      case_session: true, peer_node_id: Matter::DataType::NodeId.new(0x103_u64))
    expect_raises(Matter::AuthenticationError, /expected Anchor/) do
      Matter::Controller::SharedFabric.grant_joint_admin(im, wrong_peer_session, peer,
        datastore_endpoint: 1_u16, anchor_node_id: 0x100_u64,
        device_node_id: 0x200_u64, device_endpoint: 1_u16,
        group_id: 10_u16, group_name: "Controllers", controller: delegated)
    end
    im.commands.should be_empty
    datastore.group_list.should be_empty
    datastore.endpoint_group_id_list.should be_empty
    datastore.node_acl_list.should be_empty

    im.reported_anchor_node_id = 0x103_u64
    expect_raises(Matter::AuthenticationError, /AnchorNodeID/) do
      Matter::Controller::SharedFabric.grant_joint_admin(im, session, peer,
        datastore_endpoint: 1_u16, anchor_node_id: 0x100_u64,
        device_node_id: 0x200_u64, device_endpoint: 1_u16,
        group_id: 10_u16, group_name: "Controllers", controller: delegated)
    end
    im.commands.should be_empty
    datastore.group_list.should be_empty
    datastore.endpoint_group_id_list.should be_empty
    datastore.node_acl_list.should be_empty
    im.reported_anchor_node_id = nil

    Matter::Controller::SharedFabric.grant_joint_admin(im, session, peer,
      datastore_endpoint: 1_u16, anchor_node_id: 0x100_u64,
      device_node_id: 0x200_u64, device_endpoint: 1_u16,
      group_id: 10_u16, group_name: "Controllers", controller: delegated)
    im.commands.should eq([JointStore::CMD_ADD_GROUP,
                           JointStore::CMD_ADD_GROUP_ID_TO_ENDPOINT_FOR_NODE, JointStore::CMD_ADD_ACL_TO_NODE])
    datastore.group_list.last.group_cat.should eq(0x1234_u16)
    datastore.group_list.last.group_cat_version.should eq(2_u16)
    datastore.node_acl_list.last.acl_entry.subjects.should eq([0xFFFF_FFFD_1234_0002_u64])

    Matter::Controller::SharedFabric.grant_joint_admin(im, session, peer,
      datastore_endpoint: 1_u16, anchor_node_id: 0x100_u64,
      device_node_id: 0x200_u64, device_endpoint: 1_u16,
      group_id: 10_u16, group_name: "Controllers", controller: delegated)
    im.commands.size.should eq(3)

    datastore.complete_group_membership(0x200_u64, 1_u16, 10_u16, 1_u8).should be_true
    datastore.complete_acl(0x200_u64, datastore.node_acl_list.last.list_id, 1_u8).should be_true
    Matter::Controller::SharedFabric.grant_joint_admin(im, session, peer,
      datastore_endpoint: 1_u16, anchor_node_id: 0x100_u64,
      device_node_id: 0x200_u64, device_endpoint: 1_u16,
      group_id: 10_u16, group_name: "Controllers", controller: delegated)
    im.commands.last.should eq(JointStore::CMD_REFRESH_NODE)
    datastore.node_acl_list.last.status_entry.state.should eq(JointStore::DatastoreStateEnum::Pending)

    datastore.add_group(JointStore::AddGroupRequest.new(11_u16, "Other group", nil, 0x2345_u16,
      1_u16, JointStore::DatastoreAccessControlEntryPrivilegeEnum::Administer))
    expect_raises(Matter::CommissioningError, /different CAT/) do
      Matter::Controller::SharedFabric.grant_joint_admin(im, session, peer,
        datastore_endpoint: 1_u16, anchor_node_id: 0x100_u64,
        device_node_id: 0x200_u64, device_endpoint: 1_u16,
        group_id: 11_u16, group_name: "Controllers", controller: delegated)
    end
    expect_raises(Matter::CertificateError, /group CAT/) do
      Matter::Controller::SharedFabric.grant_joint_admin(im, session, peer,
        datastore_endpoint: 1_u16, anchor_node_id: 0x100_u64,
        device_node_id: 0x200_u64, device_endpoint: 1_u16,
        group_id: 12_u16, group_name: "Controllers", controller: authority)
    end
    im.commands.size.should eq(4)
  ensure
    im.try(&.close)
  end
end
