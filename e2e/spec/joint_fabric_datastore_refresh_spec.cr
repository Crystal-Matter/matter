require "./e2e_helper"
require "../../src/matter/controller"

private alias JFD = Matter::Cluster::JointFabricDatastore
private alias IM = Matter::InteractionModel
private alias Rollout = Matter::Controller::IpkRollout

private def refresh_datastore_list(type : T.class, im : Matter::Controller::ImClient,
                                   session : Matter::Session::SecureContext, peer : Socket::IPAddress,
                                   attribute_id : UInt32) : Array(T) forall T
  report = im.read_attribute(session: session, peer: peer, endpoint_id: 1_u16,
    cluster_id: JFD::CLUSTER_ID, attribute_id: attribute_id)
  data = report.attribute_reports.as(Array(IM::AttributeReportIB))
    .first.attribute_data.as(IM::AttributeDataIB).data.as(TLV::Any)
  Array(T).from_tlv(data.to_slice)
end

private def refresh_invoke(im : Matter::Controller::ImClient, session : Matter::Session::SecureContext,
                           peer : Socket::IPAddress, command_id : UInt32, fields : Bytes) : Nil
  response = im.invoke(session: session, peer: peer, endpoint_id: 1_u16,
    cluster_id: JFD::CLUSTER_ID, command_id: command_id, fields: fields)
  Matter::Controller::JointCommissioning.assert_status_success(response)
end

private def refresh_node_status(im : Matter::Controller::ImClient, session : Matter::Session::SecureContext,
                                peer : Socket::IPAddress, node_id : UInt64) : JFD::DatastoreStatusEntryStruct?
  refresh_datastore_list(JFD::DatastoreNodeInformationEntryStruct, im, session, peer,
    JFD::ATTR_NODE_LIST).find(&.node_id.==(node_id)).try(&.commissioning_status_entry)
end

private def refresh_rollout_snapshot(im : Matter::Controller::ImClient,
                                     session : Matter::Session::SecureContext,
                                     peer : Socket::IPAddress, anchor_node_id : UInt64) : JFD
  snapshot = JFD.new(Matter::DataType::EndpointNumber.new(1_u16))
  root_report = im.read_attribute(session: session, peer: peer, endpoint_id: 1_u16,
    cluster_id: JFD::CLUSTER_ID, attribute_id: JFD::ATTR_ANCHOR_ROOT_CA)
  root_data = root_report.attribute_reports.as(Array(IM::AttributeReportIB))
    .first.attribute_data.as(IM::AttributeDataIB).data.as(TLV::Any)
  snapshot.anchor_root_ca = Bytes.from_tlv(root_data.to_slice)
  snapshot.anchor_node_id = anchor_node_id
  snapshot.group_key_set_list = refresh_datastore_list(JFD::DatastoreGroupKeySetStruct, im,
    session, peer, JFD::ATTR_GROUP_KEY_SET_LIST)
  snapshot.node_list = refresh_datastore_list(JFD::DatastoreNodeInformationEntryStruct, im,
    session, peer, JFD::ATTR_NODE_LIST)
  snapshot.node_key_set_list = refresh_datastore_list(JFD::DatastoreNodeKeySetEntryStruct, im,
    session, peer, JFD::ATTR_NODE_KEY_SET_LIST)
  snapshot.admin_list = refresh_datastore_list(JFD::DatastoreAdministratorInformationEntryStruct, im,
    session, peer, JFD::ATTR_ADMIN_LIST)
  snapshot
end

private def wait_refresh_status(im : Matter::Controller::ImClient, session : Matter::Session::SecureContext,
                                peer : Socket::IPAddress, node_id : UInt64,
                                expected : JFD::DatastoreStateEnum, timeout : Time::Span) : JFD::DatastoreStatusEntryStruct
  deadline = Time.instant + timeout
  loop do
    status = refresh_node_status(im, session, peer, node_id)
    return status if status && status.state == expected
    if Time.instant >= deadline
      raise Matter::TimeoutError.new("RefreshNode for 0x#{node_id.to_s(16)} remained #{status.try(&.state)}")
    end
    sleep 1.second
  end
end

private def wait_joint_acl(im : Matter::Controller::ImClient, session : Matter::Session::SecureContext,
                           peer : Socket::IPAddress, node_id : UInt64, subject : UInt64,
                           timeout : Time::Span) : Nil
  deadline = Time.instant + timeout
  loop do
    entry = refresh_datastore_list(JFD::DatastoreACLEntryStruct, im, session, peer,
      JFD::ATTR_NODE_ACL_LIST).find do |candidate|
      candidate.node_id == node_id && candidate.acl_entry.subjects.try(&.includes?(subject))
    end
    return if entry && entry.status_entry.state == JFD::DatastoreStateEnum::Committed
    if Time.instant >= deadline
      raise Matter::TimeoutError.new("Joint Fabric CAT ACL for 0x#{node_id.to_s(16)} remained #{entry.try(&.status_entry.state)}")
    end
    sleep 1.second
  end
end

# A dedicated Anchor and switch keep this scenario independent of the JCM,
# shared-switch and ordinary switch specs. The pending node starts offline;
# RefreshNode retries after it joins the fabric and reconciles its live state.
describe "Joint Fabric Datastore RefreshNode against a commissioned device" do
  anchor = E2E::Device["matter_joint_fabric_refresh_anchor"]
  target = E2E::Device["matter_joint_fabric_refresh_target"]

  it "recovers an offline node and discovers its endpoint and ACL" do
    anchor_node_id = 0xC102_u64
    target_node_id = 0xC201_u64
    bootstrap = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      0xC100_u64, 0xC101_u64, 0xFFF1_u16)
    store = Matter::Controller::StateStore.new(Matter::Storage::YamlFile.new(
      File.join(E2E::LOG_DIR, "matter_joint_fabric_refresh_anchor.bootstrap.yml")))
    store.save(Matter::Controller::State.new(fabric: bootstrap.fabric,
      commissioner_node_id: bootstrap.fabric.controller_node_id))
    client = Matter::Controller::Client.new(
      unsecured_source_node_id: bootstrap.fabric.controller_node_id)
    anchor_peer = Socket::IPAddress.new(anchor.address, E2E::DEVICE_PORT)
    target_peer = Socket::IPAddress.new(target.address, E2E::DEVICE_PORT)
    issuer = ->(fabric_id : UInt64, node_id : UInt64, key : Bytes) do
      raise Matter::ConfigurationError.new("Wrong refresh fabric") unless fabric_id == bootstrap.fabric.fabric_id
      bootstrap.issue_anchor_administrator_noc(node_id, key)
    end

    Matter::Controller::Commissioning::Commissioner.new(store, client,
      timeout: E2E::COMMAND_TIMEOUT, certificate_issuer: issuer,
      attestation_verifier: Matter::Controller::DeviceAttestationVerifier.new(
        Matter::Controller::AttestationTrustStore.matter_test_fixture)).pairing_code(
      anchor_node_id, anchor.pairing_code, anchor_peer)
    anchor_session = Matter::Controller::Pairing::CasePairing.new.pair(client, anchor_peer,
      bootstrap.fabric, peer_node_id: anchor_node_id, timeout: E2E::COMMAND_TIMEOUT)
    im = Matter::Controller::ImClient.new(client, E2E::COMMAND_TIMEOUT)

    # The target has no operational identity yet. Propagation retries and
    # records the failure rather than declaring an unobserved success.
    refresh_invoke(im, anchor_session, anchor_peer, JFD::CMD_ADD_PENDING_NODE,
      JFD::AddPendingNodeRequest.new(target_node_id, "Refresh target").to_slice)
    failed = wait_refresh_status(im, anchor_session, anchor_peer, target_node_id,
      JFD::DatastoreStateEnum::CommitFailed, 150.seconds)
    failed.failure_code.should eq(IM::StatusCode::Failure.value)

    # A future IPK update would evict the target's only epoch. The host-side
    # guard must refuse it while this real Datastore reports CommitFailed.
    eviction = JFD::DatastoreGroupKeySetStruct.new(0_u16,
      JFD::DatastoreGroupKeySecurityPolicyEnum::TrustFirst,
      Bytes.new(16, 0xA6_u8), 2_u64, nil, nil, nil, nil)
    rollout = refresh_rollout_snapshot(im, anchor_session, anchor_peer, anchor_node_id)
    expect_raises(Matter::ConfigurationError, /node #{target_node_id}/) do
      Rollout.preflight_eviction!(rollout, bootstrap.fabric.fabric_id,
        bootstrap.fabric.root_cert, eviction, [] of Rollout::AdministratorAcknowledgment)
    end

    Matter::Controller::Commissioning::Commissioner.new(store, client,
      timeout: E2E::COMMAND_TIMEOUT,
      attestation_verifier: Matter::Controller::DeviceAttestationVerifier.new(
        Matter::Controller::AttestationTrustStore.matter_test_fixture)).pairing_code(target_node_id, target.pairing_code,
      target_peer, fabric_id: bootstrap.fabric.fabric_id,
      root_public_key: bootstrap.fabric.root_public_key,
      controller_node_id: bootstrap.fabric.controller_node_id)
    target_session = Matter::Controller::Pairing::CasePairing.new.pair(client, target_peer,
      bootstrap.fabric, peer_node_id: target_node_id, timeout: E2E::COMMAND_TIMEOUT)

    # The Anchor device needs CASE Administer access to inspect and apply the
    # target's operational ACL during its own background propagation.
    acl_report = im.read_attribute(session: target_session, peer: target_peer, endpoint_id: 0_u16,
      cluster_id: Matter::Cluster::AccessControl::CLUSTER_ID,
      attribute_id: Matter::Cluster::AccessControl::ATTR_ACL)
    acl_data = acl_report.attribute_reports.as(Array(IM::AttributeReportIB))
      .first.attribute_data.as(IM::AttributeDataIB).data.as(TLV::Any)
    acl = Array(Matter::Cluster::AccessControl::AccessControlEntry).from_tlv(acl_data.to_slice)
    admin_subject = Matter::DataType::NodeId.from_case_authenticated_tag(
      Matter::DataType::CaseAuthenticatedTag.create(0xFFFF_u16, 1_u16)).id
    acl << Matter::Cluster::AccessControl::AccessControlEntry.new(
      Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer,
      Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
      [admin_subject], nil)
    write = im.write_attribute(session: target_session, peer: target_peer, endpoint_id: 0_u16,
      cluster_id: Matter::Cluster::AccessControl::CLUSTER_ID,
      attribute_id: Matter::Cluster::AccessControl::ATTR_ACL, value: acl.to_tlv)
    write.write_responses.first.status.status.should eq(IM::StatusCode::Success.value)

    refresh_invoke(im, anchor_session, anchor_peer, JFD::CMD_REFRESH_NODE,
      JFD::RefreshNodeRequest.new(target_node_id).to_slice)
    committed = wait_refresh_status(im, anchor_session, anchor_peer, target_node_id,
      JFD::DatastoreStateEnum::Committed, 120.seconds)
    committed.failure_code.should eq(0_u8)
    rollout = refresh_rollout_snapshot(im, anchor_session, anchor_peer, anchor_node_id)
    Rollout.preflight_eviction!(rollout, bootstrap.fabric.fabric_id,
      bootstrap.fabric.root_cert, eviction, [] of Rollout::AdministratorAcknowledgment)
    endpoints = refresh_datastore_list(JFD::DatastoreEndpointEntryStruct, im, anchor_session,
      anchor_peer, JFD::ATTR_NODE_ENDPOINT_LIST)
    endpoints.select(&.node_id.==(target_node_id)).map(&.endpoint_id).should contain(1_u16)
    acls = refresh_datastore_list(JFD::DatastoreACLEntryStruct, im, anchor_session,
      anchor_peer, JFD::ATTR_NODE_ACL_LIST)
    acls.any? do |entry|
      entry.node_id == target_node_id && entry.acl_entry.subjects.try(&.includes?(admin_subject))
    end.should be_true

    # A second Crystal controller carries a group CAT in its NOC. It can
    # establish CASE before authorization, but its IM read is denied until the
    # Anchor Datastore propagates the CAT ACL to this switch.
    delegate_id = 0xC103_u64
    group_cat = 0x1234_u16
    group_version = 2_u16
    delegated = Matter::Controller::SharedFabric.delegate_joint(bootstrap.fabric,
      delegate_id, group_cat, group_version)
    delegate_store = Matter::Controller::StateStore.new(Matter::Storage::Memory.new)
    Matter::Controller::SharedFabric.install(delegate_store, delegated)
    delegate_client = Matter::Controller::Client.new(unsecured_source_node_id: delegate_id)
    delegate_session = Matter::Controller::Pairing::CasePairing.new.pair(delegate_client,
      target_peer, delegated, peer_node_id: target_node_id, timeout: E2E::COMMAND_TIMEOUT)
    delegate_im = Matter::Controller::ImClient.new(delegate_client, E2E::COMMAND_TIMEOUT)
    before = delegate_im.read_attribute(session: delegate_session, peer: target_peer,
      endpoint_id: 1_u16, cluster_id: Matter::Cluster::OnOff::CLUSTER_ID,
      attribute_id: Matter::Cluster::OnOff::ATTR_ON_OFF)
    before.attribute_reports.as(Array(IM::AttributeReportIB)).first.attribute_status
      .as(IM::AttributeStatusIB).status.status.should eq(IM::StatusCode::UnsupportedAccess.value)

    Matter::Controller::SharedFabric.grant_joint_admin(im, anchor_session, anchor_peer,
      1_u16, anchor_node_id, target_node_id, 1_u16, 10_u16, "Joint controllers", delegated)
    cat_subject = Matter::DataType::NodeId.from_case_authenticated_tag(
      Matter::DataType::CaseAuthenticatedTag.create(group_cat, group_version)).id
    wait_joint_acl(im, anchor_session, anchor_peer, target_node_id, cat_subject, 120.seconds)
    after = delegate_im.read_attribute(session: delegate_session, peer: target_peer,
      endpoint_id: 1_u16, cluster_id: Matter::Cluster::OnOff::CLUSTER_ID,
      attribute_id: Matter::Cluster::OnOff::ATTR_ON_OFF)
    after.attribute_reports.as(Array(IM::AttributeReportIB)).first.attribute_data.should_not be_nil

    # Exercise the device as a jointly controlled node, including a restart.
    # Both controller identities must keep operational access to the same
    # fabric and observe each other's changes to an ordinary application cluster.
    turned_on = delegate_im.invoke(session: delegate_session, peer: target_peer,
      endpoint_id: 1_u16, cluster_id: Matter::Cluster::OnOff::CLUSTER_ID,
      command_id: Matter::Cluster::OnOff::CMD_ON, fields: Bytes.empty)
    Matter::Controller::JointCommissioning.assert_status_success(turned_on)
    on_report = im.read_attribute(session: target_session, peer: target_peer,
      endpoint_id: 1_u16, cluster_id: Matter::Cluster::OnOff::CLUSTER_ID,
      attribute_id: Matter::Cluster::OnOff::ATTR_ON_OFF)
    on_data = on_report.attribute_reports.as(Array(IM::AttributeReportIB))
      .first.attribute_data.as(IM::AttributeDataIB).data.as(TLV::Any)
    Bool.from_tlv(on_data.to_slice).should be_true

    target.restart!
    delegate_session = Matter::Controller::Pairing::CasePairing.new.pair(delegate_client,
      target_peer, delegated, peer_node_id: target_node_id, timeout: E2E::COMMAND_TIMEOUT)
    target_session = Matter::Controller::Pairing::CasePairing.new.pair(client, target_peer,
      bootstrap.fabric, peer_node_id: target_node_id, timeout: E2E::COMMAND_TIMEOUT)
    persisted = delegate_im.read_attribute(session: delegate_session, peer: target_peer,
      endpoint_id: 1_u16, cluster_id: Matter::Cluster::OnOff::CLUSTER_ID,
      attribute_id: Matter::Cluster::OnOff::ATTR_ON_OFF)
    persisted_data = persisted.attribute_reports.as(Array(IM::AttributeReportIB))
      .first.attribute_data.as(IM::AttributeDataIB).data.as(TLV::Any)
    Bool.from_tlv(persisted_data.to_slice).should be_true

    turned_off = im.invoke(session: target_session, peer: target_peer,
      endpoint_id: 1_u16, cluster_id: Matter::Cluster::OnOff::CLUSTER_ID,
      command_id: Matter::Cluster::OnOff::CMD_OFF, fields: Bytes.empty)
    Matter::Controller::JointCommissioning.assert_status_success(turned_off)
    off_report = delegate_im.read_attribute(session: delegate_session, peer: target_peer,
      endpoint_id: 1_u16, cluster_id: Matter::Cluster::OnOff::CLUSTER_ID,
      attribute_id: Matter::Cluster::OnOff::ATTR_ON_OFF)
    off_data = off_report.attribute_reports.as(Array(IM::AttributeReportIB))
      .first.attribute_data.as(IM::AttributeDataIB).data.as(TLV::Any)
    Bool.from_tlv(off_data.to_slice).should be_false
  ensure
    delegate_client.try(&.close)
    client.try(&.close)
    store.try(&.backend.close)
  end
end
