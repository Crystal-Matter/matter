require "./e2e_helper"
require "../../src/matter/controller"

private alias JFD = Matter::Cluster::JointFabricDatastore
private alias IM = Matter::InteractionModel

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
    endpoints = refresh_datastore_list(JFD::DatastoreEndpointEntryStruct, im, anchor_session,
      anchor_peer, JFD::ATTR_NODE_ENDPOINT_LIST)
    endpoints.select(&.node_id.==(target_node_id)).map(&.endpoint_id).should contain(1_u16)
    acls = refresh_datastore_list(JFD::DatastoreACLEntryStruct, im, anchor_session,
      anchor_peer, JFD::ATTR_NODE_ACL_LIST)
    acls.any? do |entry|
      entry.node_id == target_node_id && entry.acl_entry.subjects.try(&.includes?(admin_subject))
    end.should be_true
  ensure
    client.try(&.close)
    store.try(&.backend.close)
  end
end
