require "./e2e_helper"
require "../../src/matter/controller"

# Two independent controller identities use one fabric on a real device.
# This exercises PASE, AddNOC, CASE, fabric-scoped ACL writes, and CASE again
# with the delegated controller's own operational certificate and key.
describe "shared fabric between Crystal controllers" do
  device = E2E::Device["matter_shared_switch"]

  it "commissions once and gives a second controller operational access" do
    authority_path = File.join(E2E::LOG_DIR, "shared-fabric-authority.yml")
    File.delete?(authority_path)
    authority_store = Matter::Controller::StateStore.new(Matter::Storage::YamlFile.new(authority_path))
    authority_client = Matter::Controller::Client.new
    peer = Socket::IPAddress.new(device.address, E2E::DEVICE_PORT)
    node_id = 0x301_u64
    delegate_id = 0x302_u64

    commissioner = Matter::Controller::Commissioning::Commissioner.new(
      authority_store, authority_client, timeout: E2E::COMMAND_TIMEOUT,
      attestation_verifier: Matter::Controller::DeviceAttestationVerifier.new(
        Matter::Controller::AttestationTrustStore.matter_test_fixture)
    )
    commissioner.pairing_code(node_id, device.pairing_code, peer)

    authority = authority_store.load.fabric.as(Matter::Controller::FabricInfo)
    authority_session = Matter::Controller::Pairing::CasePairing.new.pair(
      authority_client, peer, authority, peer_node_id: node_id, timeout: E2E::COMMAND_TIMEOUT
    )
    im = Matter::Controller::ImClient.new(authority_client, E2E::COMMAND_TIMEOUT)
    Matter::Controller::SharedFabric.grant_admin(im, authority_session, peer, delegate_id)

    delegate_path = File.join(E2E::LOG_DIR, "shared-fabric-delegate.yml")
    File.delete?(delegate_path)
    delegate_store = Matter::Controller::StateStore.new(Matter::Storage::YamlFile.new(delegate_path))
    delegated = Matter::Controller::SharedFabric.delegate(authority, delegate_id)
    Matter::Controller::SharedFabric.install(delegate_store, delegated)
    delegate_state = delegate_store.load
    delegate_client = Matter::Controller::Client.new(
      counter_lease: delegate_store.counter_lease(delegate_state.commissioner_node_id)
    )
    delegate_session = Matter::Controller::Pairing::CasePairing.new.pair(
      delegate_client, peer, delegated, peer_node_id: node_id, timeout: E2E::COMMAND_TIMEOUT
    )
    delegate_im = Matter::Controller::ImClient.new(delegate_client, E2E::COMMAND_TIMEOUT)
    report = delegate_im.read_attribute(
      session: delegate_session,
      peer: peer,
      endpoint_id: 1_u16,
      cluster_id: Matter::Cluster::OnOff::CLUSTER_ID,
      attribute_id: Matter::Cluster::OnOff::ATTR_ON_OFF
    )
    report.attribute_reports.should_not be_nil
    report.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB)).first.attribute_data.should_not be_nil
  ensure
    delegate_client.try(&.close)
    authority_client.try(&.close)
  end
end
