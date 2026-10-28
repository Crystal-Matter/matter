require "./e2e_helper"
require "../../src/matter/controller"

private alias IPKJFD = Matter::Cluster::JointFabricDatastore
private alias IPKGKM = Matter::Cluster::GroupKeyManagement

private def ipk_group_key_set(im : Matter::Controller::ImClient,
                              session : Matter::Session::SecureContext,
                              peer : Socket::IPAddress) : TLV::Any
  response = im.invoke(session: session, peer: peer, endpoint_id: 0_u16,
    cluster_id: IPKGKM::CLUSTER_ID, command_id: IPKGKM::CMD_KEY_SET_READ,
    fields: IPKGKM::KeySetReadRequest.new(0_u16).to_slice)
  fields = response.invoke_responses.first?.try(&.command_data).try(&.command_fields) ||
           raise Matter::ProtocolError.new("KeySetRead omitted its response")
  TLV::Any.from_slice(fields.to_slice).as_structure[0]
end

private def ipk_datastore_key_set(im : Matter::Controller::ImClient,
                                  session : Matter::Session::SecureContext,
                                  peer : Socket::IPAddress) : IPKJFD::DatastoreGroupKeySetStruct
  report = im.read_attribute(session: session, peer: peer, endpoint_id: 1_u16,
    cluster_id: IPKJFD::CLUSTER_ID, attribute_id: IPKJFD::ATTR_GROUP_KEY_SET_LIST)
  data = report.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
    .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any)
  Array(IPKJFD::DatastoreGroupKeySetStruct).from_tlv(data.to_slice).find!(&.group_key_set_id.==(0_u16))
end

private def ipk_node_key_status(im : Matter::Controller::ImClient,
                                session : Matter::Session::SecureContext,
                                peer : Socket::IPAddress,
                                node_id : UInt64) : IPKJFD::DatastoreStateEnum?
  report = im.read_attribute(session: session, peer: peer, endpoint_id: 1_u16,
    cluster_id: IPKJFD::CLUSTER_ID, attribute_id: IPKJFD::ATTR_NODE_KEY_SET_LIST)
  data = report.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
    .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any)
  Array(IPKJFD::DatastoreNodeKeySetEntryStruct).from_tlv(data.to_slice)
    .find { |entry| entry.node_id == node_id && entry.group_key_set_id == 0_u16 }
    .try(&.status_entry.state)
end

private def wait_ipk_node_key_status(im : Matter::Controller::ImClient,
                                     session : Matter::Session::SecureContext,
                                     peer : Socket::IPAddress, node_id : UInt64,
                                     expected : IPKJFD::DatastoreStateEnum) : Nil
  deadline = Time.instant + 150.seconds
  loop do
    return if ipk_node_key_status(im, session, peer, node_id) == expected
    raise Matter::TimeoutError.new("Node IPK delivery did not reach #{expected}") if Time.instant >= deadline
    sleep 1.second
  end
end

describe "Joint Fabric Anchor IPK rotation" do
  anchor = E2E::Device["matter_joint_fabric_ipk_anchor"]
  target = E2E::Device["matter_joint_fabric_ipk_target"]

  it "keeps an updated three-epoch IPK after restart and accepts fresh CASE on the selected epoch" do
    node_id = 0xC902_u64
    bootstrap = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      0xC900_u64, 0xC901_u64, 0xFFF1_u16)
    store = Matter::Controller::StateStore.new(Matter::Storage::YamlFile.new(
      File.join(E2E::LOG_DIR, "matter_joint_fabric_ipk_anchor.bootstrap.yml")))
    store.save(Matter::Controller::State.new(fabric: bootstrap.fabric,
      commissioner_node_id: bootstrap.fabric.controller_node_id))
    client = Matter::Controller::Client.new(counter_lease: store.counter_lease(bootstrap.fabric.controller_node_id))
    peer = Socket::IPAddress.new(anchor.address, E2E::DEVICE_PORT)
    issuer = ->(fabric_id : UInt64, requested_node_id : UInt64, key : Bytes) do
      raise Matter::ConfigurationError.new("Wrong Anchor fabric") unless fabric_id == bootstrap.fabric.fabric_id
      bootstrap.issue_anchor_administrator_noc(requested_node_id, key)
    end
    Matter::Controller::Commissioning::Commissioner.new(store, client,
      timeout: E2E::COMMAND_TIMEOUT, certificate_issuer: issuer,
      attestation_verifier: Matter::Controller::DeviceAttestationVerifier.new(
        Matter::Controller::AttestationTrustStore.matter_test_fixture)).pairing_code(
      node_id, anchor.pairing_code, peer)

    session = Matter::Controller::Pairing::CasePairing.new.pair(client, peer,
      bootstrap.fabric, peer_node_id: node_id, timeout: E2E::COMMAND_TIMEOUT)
    im = Matter::Controller::ImClient.new(client, E2E::COMMAND_TIMEOUT)
    initial = ipk_datastore_key_set(im, session, peer)
    initial.epoch_key0.should eq(bootstrap.fabric.ipk_value)

    target_node_id = 0xC903_u64
    target_peer = Socket::IPAddress.new(target.address, E2E::DEVICE_PORT)
    Matter::Controller::Commissioning::Commissioner.new(store, client,
      timeout: E2E::COMMAND_TIMEOUT,
      attestation_verifier: Matter::Controller::DeviceAttestationVerifier.new(
        Matter::Controller::AttestationTrustStore.matter_test_fixture)).pairing_code(
      target_node_id, target.pairing_code, target_peer,
      fabric_id: bootstrap.fabric.fabric_id,
      root_public_key: bootstrap.fabric.root_public_key,
      controller_node_id: bootstrap.fabric.controller_node_id)
    target_session = Matter::Controller::Pairing::CasePairing.new.pair(client, target_peer,
      bootstrap.fabric, peer_node_id: target_node_id, timeout: E2E::COMMAND_TIMEOUT)
    acl_report = im.read_attribute(session: target_session, peer: target_peer, endpoint_id: 0_u16,
      cluster_id: Matter::Cluster::AccessControl::CLUSTER_ID,
      attribute_id: Matter::Cluster::AccessControl::ATTR_ACL)
    acl_data = acl_report.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any)
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
    write.write_responses.first.status.status.should eq(Matter::InteractionModel::StatusCode::Success.value)
    added = im.invoke(session: session, peer: peer, endpoint_id: 1_u16,
      cluster_id: IPKJFD::CLUSTER_ID, command_id: IPKJFD::CMD_ADD_PENDING_NODE,
      fields: IPKJFD::AddPendingNodeRequest.new(target_node_id, "IPK target").to_slice)
    Matter::Controller::JointCommissioning.assert_status_success(added)
    wait_ipk_node_key_status(im, session, peer, target_node_id, IPKJFD::DatastoreStateEnum::Committed)

    next_key = Bytes.new(16, 0xA6_u8)
    future_key = Bytes.new(16, 0xB7_u8)
    # A controller can already know the proposed epochs while a target still
    # accepts only the old one. CASE must retry that retained epoch.
    transitional = store.load.fabric.as(Matter::Controller::FabricInfo)
    transitional.ipk_epoch_keys = [bootstrap.fabric.ipk_value, next_key, future_key]
    fallback_client = Matter::Controller::Client.new(
      counter_lease: store.counter_lease(transitional.controller_node_id),
      shared_message_counter: client.transport.message_counter)
    fallback_session = Matter::Controller::Pairing::CasePairing.new.pair(fallback_client,
      target_peer, transitional, peer_node_id: target_node_id, timeout: E2E::COMMAND_TIMEOUT)
    Matter::Controller::ImClient.new(fallback_client, E2E::COMMAND_TIMEOUT).read_attribute(
      session: fallback_session, peer: target_peer, endpoint_id: 0_u16,
      cluster_id: Matter::Cluster::Descriptor::CLUSTER_ID,
      attribute_id: Matter::Cluster::Descriptor::ATTR_PARTS_LIST)
      .attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB)).should_not be_empty
    fallback_client.close
    updated = IPKJFD::DatastoreGroupKeySetStruct.new(0_u16,
      IPKJFD::DatastoreGroupKeySecurityPolicyEnum::TrustFirst,
      bootstrap.fabric.ipk_value, 1_u64, next_key, 2_u64, future_key, 3_u64)
    response = im.invoke(session: session, peer: peer, endpoint_id: 1_u16,
      cluster_id: IPKJFD::CLUSTER_ID, command_id: IPKJFD::CMD_UPDATE_KEY_SET,
      fields: IPKJFD::UpdateKeySetRequest.new(updated).to_slice)
    Matter::Controller::JointCommissioning.assert_status_success(response)
    ipk_datastore_key_set(im, session, peer).epoch_key1.should eq(next_key)
    ipk_group_key_set(im, session, peer).as_structure[7].as_u64.should eq(3_u64)
    Matter::Controller::SharedFabric.refresh_ipk_from_anchor(store, bootstrap.fabric,
      im, session, peer, 1_u16, node_id)
    store.load.fabric.as(Matter::Controller::FabricInfo).ipk_epoch_keys.should eq(
      [bootstrap.fabric.ipk_value, next_key, future_key])
    wait_ipk_node_key_status(im, session, peer, target_node_id, IPKJFD::DatastoreStateEnum::Committed)

    newest_key = Bytes.new(16, 0xC8_u8)
    evicted = IPKJFD::DatastoreGroupKeySetStruct.new(0_u16,
      IPKJFD::DatastoreGroupKeySecurityPolicyEnum::TrustFirst,
      next_key, 4_u64, future_key, 5_u64, newest_key, 6_u64)
    response = im.invoke(session: session, peer: peer, endpoint_id: 1_u16,
      cluster_id: IPKJFD::CLUSTER_ID, command_id: IPKJFD::CMD_UPDATE_KEY_SET,
      fields: IPKJFD::UpdateKeySetRequest.new(evicted).to_slice)
    Matter::Controller::JointCommissioning.assert_status_success(response)
    Matter::Controller::SharedFabric.refresh_ipk_from_anchor(store, bootstrap.fabric,
      im, session, peer, 1_u16, node_id)
    store.load.fabric.as(Matter::Controller::FabricInfo).ipk_epoch_keys.should eq(
      [next_key, future_key, newest_key])
    wait_ipk_node_key_status(im, session, peer, target_node_id, IPKJFD::DatastoreStateEnum::Committed)

    anchor.restart!
    target.restart!
    rotated = store.load.fabric.as(Matter::Controller::FabricInfo)
    fresh_client = Matter::Controller::Client.new(
      counter_lease: store.counter_lease(rotated.controller_node_id),
      shared_message_counter: client.transport.message_counter)
    fresh_session = Matter::Controller::Pairing::CasePairing.new.pair(fresh_client, peer,
      rotated, peer_node_id: node_id, timeout: E2E::COMMAND_TIMEOUT)
    fresh_im = Matter::Controller::ImClient.new(fresh_client, E2E::COMMAND_TIMEOUT)
    ipk_datastore_key_set(fresh_im, fresh_session, peer).epoch_key2.should eq(newest_key)
    ipk_group_key_set(fresh_im, fresh_session, peer).as_structure[5].as_u64.should eq(5_u64)
    target_session = Matter::Controller::Pairing::CasePairing.new.pair(fresh_client, target_peer,
      rotated, peer_node_id: target_node_id, timeout: E2E::COMMAND_TIMEOUT)
    fresh_im.read_attribute(session: target_session, peer: target_peer, endpoint_id: 0_u16,
      cluster_id: Matter::Cluster::Descriptor::CLUSTER_ID,
      attribute_id: Matter::Cluster::Descriptor::ATTR_PARTS_LIST)
      .attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB)).should_not be_empty
  end
end
