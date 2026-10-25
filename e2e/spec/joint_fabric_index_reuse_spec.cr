require "./e2e_helper"
require "../../src/matter/controller"

private alias IndexReuseJFA = Matter::Cluster::JointFabricAdministrator
private alias IndexReuseJFD = Matter::Cluster::JointFabricDatastore
private alias IndexReuseOpCred = Matter::Cluster::OperationalCredentials
private alias IndexReuseIM = Matter::InteractionModel

private def index_reuse_attribute(im : Matter::Controller::ImClient,
                                  session : Matter::Session::SecureContext,
                                  peer : Socket::IPAddress, endpoint : UInt16,
                                  cluster : UInt32, attribute : UInt32) : TLV::Any
  report = im.read_attribute(session: session, peer: peer, endpoint_id: endpoint,
    cluster_id: cluster, attribute_id: attribute, fabric_filtered: false)
  report.attribute_reports.as(Array(IndexReuseIM::AttributeReportIB)).first
    .attribute_data.as(IndexReuseIM::AttributeDataIB).data.as(TLV::Any)
end

private def index_reuse_bootstrap_with_same_root(previous : Matter::Controller::JointCommissioning::AnchorBootstrap,
                                                 fabric_id : UInt64, controller_node_id : UInt64) : Matter::Controller::JointCommissioning::AnchorBootstrap
  crypto = Matter::Crypto::StandardCrypto.new
  root_key = previous.fabric.certificate_authority_key
  root = previous.fabric.root_cert
  icac_key = crypto.create_key_pair
  icac = Matter::Crypto::MatterCertificate::Builder.intermediate(
    icac_key.public_key, fabric_id, Matter::Controller::JointCommissioning::BOOTSTRAP_ICAC_ID,
    root_key, Matter::Controller::JointCommissioning::BOOTSTRAP_RCAC_ID,
    crypto.random_bytes(Matter::Controller::JointCommissioning::BOOTSTRAP_SERIAL_BYTES), crypto,
    anchor: true, issuer_certificate: root)
  controller_key = crypto.create_key_pair
  base = Matter::Controller::FabricInfo.new(fabric_id: fabric_id,
    controller_node_id: controller_node_id, ipk_value: crypto.random_bytes(Matter::Fabric::IPK_SIZE),
    root_cert: root, root_public_key: root_key.public_key,
    controller_noc: Bytes.empty, controller_private_key: controller_key.private_key,
    root_private_key: root_key.private_key, admin_vendor_id: previous.fabric.admin_vendor_id,
    intermediate_cert: icac, intermediate_private_key: icac_key.private_key)
  temporary = Matter::Controller::JointCommissioning::AnchorBootstrap.new(base, icac_key.private_key)
  noc = temporary.issue_anchor_administrator_noc(controller_node_id, controller_key.public_key)
  fabric = Matter::Controller::FabricInfo.new(fabric_id: fabric_id,
    controller_node_id: controller_node_id, ipk_value: base.ipk_value,
    root_cert: root, root_public_key: root_key.public_key,
    controller_noc: noc, controller_private_key: controller_key.private_key,
    root_private_key: root_key.private_key, admin_vendor_id: previous.fabric.admin_vendor_id,
    intermediate_cert: icac, intermediate_private_key: icac_key.private_key)
  Matter::Controller::JointCommissioning::AnchorBootstrap.new(fabric, icac_key.private_key)
end

describe "Joint Fabric Administrator fabric index reuse" do
  anchor = E2E::Device["matter_joint_fabric_index_reuse_anchor"]

  it "removes an Anchor fabric, restarts, and binds a new Anchor only to its own Datastore" do
    old_anchor_node = 0xD102_u64
    new_anchor_node = 0xD202_u64
    old_bootstrap = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      0xD100_u64, 0xD101_u64, 0xFFF1_u16)
    new_bootstrap = index_reuse_bootstrap_with_same_root(old_bootstrap, 0xD200_u64, 0xD201_u64)
    new_bootstrap.fabric.root_cert.should eq(old_bootstrap.fabric.root_cert)
    store = Matter::Controller::StateStore.new(Matter::Storage::YamlFile.new(
      File.join(E2E::LOG_DIR, "matter_joint_fabric_index_reuse_anchor.bootstrap.yml")))
    store.save(Matter::Controller::State.new(fabric: old_bootstrap.fabric,
      commissioner_node_id: old_bootstrap.fabric.controller_node_id))
    peer = Socket::IPAddress.new(anchor.address, E2E::DEVICE_PORT)
    old_client = Matter::Controller::Client.new(
      unsecured_source_node_id: old_bootstrap.fabric.controller_node_id)
    old_issuer = ->(fabric_id : UInt64, node_id : UInt64, key : Bytes) do
      raise Matter::ConfigurationError.new("Wrong initial Anchor fabric") unless fabric_id == old_bootstrap.fabric.fabric_id
      old_bootstrap.issue_anchor_administrator_noc(node_id, key)
    end
    trust = Matter::Controller::DeviceAttestationVerifier.new(
      Matter::Controller::AttestationTrustStore.matter_test_fixture)
    Matter::Controller::Commissioning::Commissioner.new(store, old_client,
      timeout: E2E::COMMAND_TIMEOUT, certificate_issuer: old_issuer,
      attestation_verifier: trust).pairing_code(old_anchor_node, anchor.pairing_code, peer)
    old_session = Matter::Controller::Pairing::CasePairing.new.pair(old_client, peer,
      old_bootstrap.fabric, peer_node_id: old_anchor_node, timeout: E2E::COMMAND_TIMEOUT)
    old_im = Matter::Controller::ImClient.new(old_client, E2E::COMMAND_TIMEOUT)
    index_reuse_attribute(old_im, old_session, peer, 1_u16,
      IndexReuseJFA::CLUSTER_ID, IndexReuseJFA::ATTR_ADMINISTRATOR_FABRIC_INDEX).as_u8.should eq(1_u8)
    old_admins = Array(IndexReuseJFD::DatastoreAdministratorInformationEntryStruct).from_tlv(
      index_reuse_attribute(old_im, old_session, peer, 1_u16,
        IndexReuseJFD::CLUSTER_ID, IndexReuseJFD::ATTR_ADMIN_LIST).to_slice)
    old_admins.map(&.node_id).should contain(old_anchor_node)

    removed = old_im.invoke(session: old_session, peer: peer, endpoint_id: 0_u16,
      cluster_id: IndexReuseOpCred::CLUSTER_ID, command_id: IndexReuseOpCred::CMD_REMOVE_FABRIC,
      fields: IndexReuseOpCred::Tlv::RemoveFabricRequest.new(1_u8).to_slice)
    fields = removed.invoke_responses.first?.try(&.command_data).try(&.command_fields) ||
             raise Matter::ProtocolError.new("RemoveFabric omitted NOCResponse")
    IndexReuseOpCred::Tlv::TlvNocResponse.from_slice(fields.to_slice).status_code.ok?.should be_true
    old_client.close

    # The device now has no fabric. Replace its provisioned Anchor identity
    # before restarting, so commissioning the second fabric reuses index 1.
    store.save(Matter::Controller::State.new(fabric: new_bootstrap.fabric,
      commissioner_node_id: new_bootstrap.fabric.controller_node_id))
    anchor.restart!(expected_operational: false)
    new_code = anchor.restart_log.match(E2E::PAIRING_CODE_RE).try(&.[1]) ||
               raise Matter::ProtocolError.new("Restarted JFA did not print a pairing code")
    new_client = Matter::Controller::Client.new(
      unsecured_source_node_id: new_bootstrap.fabric.controller_node_id)
    new_issuer = ->(fabric_id : UInt64, node_id : UInt64, key : Bytes) do
      raise Matter::ConfigurationError.new("Wrong replacement Anchor fabric") unless fabric_id == new_bootstrap.fabric.fabric_id
      new_bootstrap.issue_anchor_administrator_noc(node_id, key)
    end
    Matter::Controller::Commissioning::Commissioner.new(store, new_client,
      timeout: E2E::COMMAND_TIMEOUT, certificate_issuer: new_issuer,
      attestation_verifier: trust).pairing_code(new_anchor_node, new_code, peer)
    new_session = Matter::Controller::Pairing::CasePairing.new.pair(new_client, peer,
      new_bootstrap.fabric, peer_node_id: new_anchor_node, timeout: E2E::COMMAND_TIMEOUT)
    new_im = Matter::Controller::ImClient.new(new_client, E2E::COMMAND_TIMEOUT)
    administrator_index = index_reuse_attribute(new_im, new_session, peer, 1_u16,
      IndexReuseJFA::CLUSTER_ID, IndexReuseJFA::ATTR_ADMINISTRATOR_FABRIC_INDEX).as_u8
    fabrics = Array(IndexReuseOpCred::Tlv::FabricDescriptor).from_tlv(
      index_reuse_attribute(new_im, new_session, peer, 0_u16,
        IndexReuseOpCred::CLUSTER_ID, IndexReuseOpCred::ATTR_FABRICS).to_slice)
    fabrics.map(&.fabric_id).should eq([new_bootstrap.fabric.fabric_id])
    fabrics.first.fabric_index.should eq(administrator_index)
    administrator_index.should eq(1_u8)
    admins = Array(IndexReuseJFD::DatastoreAdministratorInformationEntryStruct).from_tlv(
      index_reuse_attribute(new_im, new_session, peer, 1_u16,
        IndexReuseJFD::CLUSTER_ID, IndexReuseJFD::ATTR_ADMIN_LIST).to_slice)
    admins.map(&.node_id).should contain(new_anchor_node)
    admins.map(&.node_id).should_not contain(old_anchor_node)
  ensure
    old_client.try(&.close)
    new_client.try(&.close)
    store.try(&.backend.close)
  end
end
