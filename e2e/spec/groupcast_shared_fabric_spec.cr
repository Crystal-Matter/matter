require "./e2e_helper"
require "../../src/matter/controller"

private alias SharedGKM = Matter::Cluster::GroupKeyManagement
private alias SharedGC = Matter::Cluster::Groupcast
private alias SharedIM = Matter::InteractionModel

private def shared_groupcast_invoke!(im : Matter::Controller::ImClient,
                                     session : Matter::Session::SecureContext,
                                     peer : Socket::IPAddress, endpoint : UInt16,
                                     cluster : UInt32, command : UInt32,
                                     fields : Bytes = Bytes.empty) : Nil
  response = im.invoke(session, peer, endpoint, cluster, command, fields)
  status = response.invoke_responses.first?.try(&.command_status).try(&.status.status)
  unless status == SharedIM::StatusCode::Success.value || response.invoke_responses.any?(&.command_data)
    raise Matter::ProtocolError.new("Shared fabric command 0x#{command.to_s(16)} failed: #{status}")
  end
end

private def shared_groupcast_attribute(type : T.class, im : Matter::Controller::ImClient,
                                       session : Matter::Session::SecureContext,
                                       peer : Socket::IPAddress, cluster : UInt32,
                                       attribute : UInt32) : T forall T
  report = im.read_attribute(session, peer, 0_u16, cluster, attribute)
  data = report.attribute_reports.as(Array(SharedIM::AttributeReportIB))
    .first.attribute_data.as(SharedIM::AttributeDataIB).data.as(TLV::Any)
  T.from_tlv(data.to_slice)
end

describe "Groupcast Listener on a shared Matter fabric" do
  device = E2E::Device["matter_groupcast_shared"]

  it "lets two controllers share adoption, AUX access and IANA groupcast across restart" do
    authority_path = File.join(E2E::LOG_DIR, "groupcast-shared-authority.yml")
    delegate_path = File.join(E2E::LOG_DIR, "groupcast-shared-delegate.yml")
    File.delete?(authority_path)
    File.delete?(delegate_path)
    authority_backend = Matter::Storage::YamlFile.new(authority_path)
    authority_store = Matter::Controller::StateStore.new(authority_backend)
    authority_state = authority_store.load
    authority_client = Matter::Controller::Client.new(
      unsecured_source_node_id: authority_state.commissioner_node_id,
      initial_unsecured_message_counter: authority_state.unsecured_message_counter)
    peer = Socket::IPAddress.new(device.address, E2E::DEVICE_PORT)
    node_id = 0x7411_u64
    delegate_id = 0x7412_u64
    group_id = 0x7413_u16
    key_set_id = 0x7414_u16
    epoch_key = Bytes.new(16, 0x74_u8)

    Matter::Controller::Commissioning::Commissioner.new(authority_store, authority_client,
      timeout: E2E::COMMAND_TIMEOUT,
      attestation_verifier: Matter::Controller::DeviceAttestationVerifier.new(
        Matter::Controller::AttestationTrustStore.matter_test_fixture)).pairing_code(
      node_id, device.pairing_code, peer)
    fabric = authority_store.load.fabric.as(Matter::Controller::FabricInfo)
    authority_session = Matter::Controller::Pairing::CasePairing.new.pair(
      authority_client, peer, fabric, peer_node_id: node_id, timeout: E2E::COMMAND_TIMEOUT)
    authority_im = Matter::Controller::ImClient.new(authority_client, E2E::COMMAND_TIMEOUT)
    Matter::Controller::SharedFabric.grant_admin(authority_im, authority_session, peer, delegate_id)

    delegate_backend = Matter::Storage::YamlFile.new(delegate_path)
    delegate_store = Matter::Controller::StateStore.new(delegate_backend)
    delegated = Matter::Controller::SharedFabric.delegate(fabric, delegate_id)
    Matter::Controller::SharedFabric.install(delegate_store, delegated)
    delegate_state = delegate_store.load
    delegate_client = Matter::Controller::Client.new(
      unsecured_source_node_id: delegate_state.commissioner_node_id,
      initial_unsecured_message_counter: delegate_state.unsecured_message_counter)
    delegate_session = Matter::Controller::Pairing::CasePairing.new.pair(
      delegate_client, peer, delegated, peer_node_id: node_id, timeout: E2E::COMMAND_TIMEOUT)
    delegate_im = Matter::Controller::ImClient.new(delegate_client, E2E::COMMAND_TIMEOUT)

    key_set = SharedGKM::GroupKeySetStruct.new(key_set_id,
      SharedGKM::GroupKeySecurityPolicyEnum::TrustFirst, epoch_key, 1_u64)
    shared_groupcast_invoke!(authority_im, authority_session, peer, 0_u16,
      SharedGKM::CLUSTER_ID, SharedGKM::CMD_KEY_SET_WRITE,
      SharedGKM::KeySetWriteRequest.new(key_set).to_slice)
    shared_groupcast_invoke!(delegate_im, delegate_session, peer, 0_u16,
      SharedGC::CLUSTER_ID, SharedGC::CMD_JOIN_GROUP,
      SharedGC::JoinGroupRequest.new(group_id, [1_u16], key_set_id,
        use_auxiliary_acl: true).to_slice)
    adoption = [SharedGKM::GroupcastAdoptionStruct.new(true)]
    write = delegate_im.write_attribute(delegate_session, peer, 0_u16,
      SharedGKM::CLUSTER_ID, SharedGKM::ATTR_GROUPCAST_ADOPTION, adoption.to_tlv)
    write.write_responses.all? { |entry| entry.status.status == SharedIM::StatusCode::Success.value }.should be_true

    memberships = shared_groupcast_attribute(Array(SharedGC::MembershipStruct),
      authority_im, authority_session, peer, SharedGC::CLUSTER_ID, SharedGC::ATTR_MEMBERSHIP)
    memberships.first.group_id.should eq(group_id)
    memberships.first.endpoints.should eq([1_u16])
    shared_groupcast_attribute(Array(SharedGKM::GroupKeyMapStruct),
      delegate_im, delegate_session, peer, SharedGKM::CLUSTER_ID,
      SharedGKM::ATTR_GROUP_KEY_MAP).should be_empty
    auxiliary = shared_groupcast_attribute(Array(Matter::Cluster::AccessControl::AccessControlEntry),
      delegate_im, delegate_session, peer, Matter::Cluster::AccessControl::CLUSTER_ID,
      Matter::Cluster::AccessControl::ATTR_AUXILIARY_ACL)
    auxiliary.any? { |entry| entry.subjects.try(&.includes?(group_id.to_u64)) }.should be_true

    invoker = Matter::Controller::GroupInvoker.new(delegate_client, delegate_store)
    invoker.install_epoch_key(fabric.fabric_id, fabric.root_public_key, group_id, epoch_key)
    shared_groupcast_invoke!(authority_im, authority_session, peer, 1_u16,
      Matter::Cluster::OnOff::CLUSTER_ID, Matter::Cluster::OnOff::CMD_OFF)
    invoker.invoke(fabric.fabric_id, group_id, Matter::Cluster::OnOff::CLUSTER_ID,
      Matter::Cluster::OnOff::CMD_ON, root_public_key: fabric.root_public_key,
      iana_address: true)
    sleep 1.second
    on_off = authority_im.read_attribute(authority_session, peer, 1_u16,
      Matter::Cluster::OnOff::CLUSTER_ID, Matter::Cluster::OnOff::ATTR_ON_OFF)
    value = on_off.attribute_reports.as(Array(SharedIM::AttributeReportIB))
      .first.attribute_data.as(SharedIM::AttributeDataIB).data.as(TLV::Any)
    Bool.from_tlv(value.to_slice).should be_true

    device.restart!
    authority_session = Matter::Controller::Pairing::CasePairing.new.pair(
      authority_client, peer, fabric, peer_node_id: node_id, timeout: E2E::COMMAND_TIMEOUT)
    memberships = shared_groupcast_attribute(Array(SharedGC::MembershipStruct),
      authority_im, authority_session, peer, SharedGC::CLUSTER_ID, SharedGC::ATTR_MEMBERSHIP)
    memberships.first.endpoints.should eq([1_u16])
    shared_groupcast_attribute(Array(SharedGKM::GroupcastAdoptionStruct),
      authority_im, authority_session, peer, SharedGKM::CLUSTER_ID,
      SharedGKM::ATTR_GROUPCAST_ADOPTION).first.groupcast_adopted?.should be_true
  ensure
    delegate_client.try(&.close)
    authority_client.try(&.close)
    delegate_backend.try { |backend| backend.close if backend.open? }
    authority_backend.try { |backend| backend.close if backend.open? }
  end
end
