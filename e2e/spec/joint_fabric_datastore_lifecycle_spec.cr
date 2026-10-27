require "./e2e_helper"
require "../../src/matter/controller"

private alias LifecycleJFD = Matter::Cluster::JointFabricDatastore
private alias LifecycleIM = Matter::InteractionModel

private class LifecycleCredentials < Matter::Controller::Commissioning::Commissioner::Hooks
  def initialize(@bootstrap : Matter::Controller::JointCommissioning::AnchorBootstrap)
  end

  def prepare_credentials(fabric : Matter::Controller::FabricInfo, node_id : UInt64,
                          csr_public_key : Bytes, im : Matter::Controller::ImClient,
                          pase_session : Matter::Session::SecureContext,
                          peer : Socket::IPAddress) : Matter::Controller::Commissioning::Commissioner::OperationalCredentials
    anchor_cat = Matter::Controller::JointCommissioning.cat_subject(LifecycleJFD::ANCHOR_CAT, 1_u16)
    Matter::Controller::Commissioning::Commissioner::OperationalCredentials.new(
      @bootstrap.issue_noc(node_id, csr_public_key), fabric.intermediate_cert,
      fabric.ipk_value, anchor_cat, fabric.admin_vendor_id)
  end

  def before_complete(fabric : Matter::Controller::FabricInfo, node_id : UInt64,
                      im : Matter::Controller::ImClient,
                      case_session : Matter::Session::SecureContext,
                      peer : Socket::IPAddress) : Nil
  end
end

private class ObservedLifecycleDelivery < Matter::Controller::DatastoreNodeRegistrar::Delivery
  getter? pending_seen = false
  getter? refresh_sent = false

  def initialize(@network : Matter::Controller::DatastoreNodeRegistrar::NetworkDelivery,
                 @client : Matter::Controller::Client, @anchor_peer : Socket::IPAddress,
                 @anchor_node_id : UInt64, @timeout : Time::Span)
  end

  def add_pending_node(fabric : Matter::Controller::FabricInfo, node_id : UInt64,
                       friendly_name : String) : Nil
    @network.add_pending_node(fabric, node_id, friendly_name)
    # Simulate a lost command acknowledgement. NodeList must make this retry
    # idempotent while commissioning has not yet entered final CASE.
    @network.add_pending_node(fabric, node_id, friendly_name)
    session = Matter::Controller::Pairing::CasePairing.new.pair(@client, @anchor_peer,
      fabric, peer_node_id: @anchor_node_id, timeout: @timeout)
    im = Matter::Controller::ImClient.new(@client, @timeout)
    entry = lifecycle_nodes(im, session, @anchor_peer).find(&.node_id.==(node_id)) ||
            raise Matter::ProtocolError.new("AddPendingNode was not visible before final CASE")
    unless entry.friendly_name == friendly_name &&
           entry.commissioning_status_entry.state.in?(LifecycleJFD::DatastoreStateEnum::Pending,
             LifecycleJFD::DatastoreStateEnum::CommitFailed)
      raise Matter::ProtocolError.new("AddPendingNode had an unexpected pre-completion state")
    end
    @pending_seen = true
  end

  def refresh_node(fabric : Matter::Controller::FabricInfo, node_id : UInt64) : Nil
    @network.refresh_node(fabric, node_id)
    @refresh_sent = true
  end

  def remove_node(fabric : Matter::Controller::FabricInfo, node_id : UInt64,
                  friendly_name : String) : Nil
    @network.remove_node(fabric, node_id, friendly_name)
  end
end

private def lifecycle_list(type : T.class, im : Matter::Controller::ImClient,
                           session : Matter::Session::SecureContext, peer : Socket::IPAddress,
                           attribute_id : UInt32) : Array(T) forall T
  report = im.read_attribute(session: session, peer: peer, endpoint_id: 1_u16,
    cluster_id: LifecycleJFD::CLUSTER_ID, attribute_id: attribute_id)
  data = report.attribute_reports.as(Array(LifecycleIM::AttributeReportIB))
    .first.attribute_data.as(LifecycleIM::AttributeDataIB).data.as(TLV::Any)
  Array(T).from_tlv(data.to_slice)
end

private def lifecycle_nodes(im : Matter::Controller::ImClient,
                            session : Matter::Session::SecureContext,
                            peer : Socket::IPAddress) : Array(LifecycleJFD::DatastoreNodeInformationEntryStruct)
  lifecycle_list(LifecycleJFD::DatastoreNodeInformationEntryStruct, im, session,
    peer, LifecycleJFD::ATTR_NODE_LIST)
end

private def wait_lifecycle_commit(im : Matter::Controller::ImClient,
                                  session : Matter::Session::SecureContext,
                                  peer : Socket::IPAddress, node_id : UInt64,
                                  timeout : Time::Span) : LifecycleJFD::DatastoreNodeInformationEntryStruct
  deadline = Time.instant + timeout
  loop do
    node = lifecycle_nodes(im, session, peer).find(&.node_id.==(node_id))
    return node if node && node.commissioning_status_entry.state == LifecycleJFD::DatastoreStateEnum::Committed
    if Time.instant >= deadline
      raise Matter::TimeoutError.new("Datastore node 0x#{node_id.to_s(16)} remained #{node.try(&.commissioning_status_entry.state)}")
    end
    sleep 1.second
  end
end

describe "Joint Fabric Datastore commissioning lifecycle" do
  anchor = E2E::Device["matter_joint_fabric_lifecycle_anchor"]
  target = E2E::Device["matter_joint_fabric_lifecycle_target"]

  it "registers a chip-tool commissioned device before final CASE and refreshes it after completion" do
    anchor_node_id = 0xC302_u64
    target_node_id = 0xC401_u64
    bootstrap = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      0xC300_u64, 0xC301_u64, 0xFFF1_u16)
    store = Matter::Controller::StateStore.new(Matter::Storage::YamlFile.new(
      File.join(E2E::LOG_DIR, "matter_joint_fabric_lifecycle_anchor.bootstrap.yml")))
    store.save(Matter::Controller::State.new(fabric: bootstrap.fabric,
      commissioner_node_id: bootstrap.fabric.controller_node_id))
    client = Matter::Controller::Client.new(
      unsecured_source_node_id: bootstrap.fabric.controller_node_id)
    anchor_peer = Socket::IPAddress.new(anchor.address, E2E::DEVICE_PORT)
    target_peer = Socket::IPAddress.new(target.address, E2E::DEVICE_PORT)
    trust = Matter::Controller::DeviceAttestationVerifier.new(
      Matter::Controller::AttestationTrustStore.matter_test_fixture)
    issuer = ->(fabric_id : UInt64, node_id : UInt64, key : Bytes) do
      raise Matter::ConfigurationError.new("Wrong lifecycle fabric") unless fabric_id == bootstrap.fabric.fabric_id
      bootstrap.issue_anchor_administrator_noc(node_id, key)
    end

    Matter::Controller::Commissioning::Commissioner.new(store, client,
      timeout: E2E::COMMAND_TIMEOUT, certificate_issuer: issuer,
      attestation_verifier: trust).pairing_code(anchor_node_id, anchor.pairing_code, anchor_peer)

    # chip-tool supplies an independent first fabric and opens the enhanced
    # window through which the Crystal controller adds the Anchor fabric.
    target.commission!
    window = expect_success(target.chip(["pairing", "open-commissioning-window",
                                         target.node, "1", "900", "1000", "3840"]))
    pairing_code = window.output.match(/Manual pairing code:\s*\[?([0-9]{4}-[0-9]{3}-[0-9]{4}|[0-9]{11})\]?/i)
      .try(&.[1]) || raise Matter::ProtocolError.new("chip-tool did not report the enhanced-window pairing code")

    network = Matter::Controller::DatastoreNodeRegistrar::NetworkDelivery.new(
      store, client, anchor_node_id, 1_u16, E2E::COMMAND_TIMEOUT)
    observed = ObservedLifecycleDelivery.new(network, client, anchor_peer,
      anchor_node_id, E2E::COMMAND_TIMEOUT)
    registrar = Matter::Controller::DatastoreNodeRegistrar.new(store, observed)
    Matter::Controller::Commissioning::Commissioner.new(store, client,
      timeout: E2E::COMMAND_TIMEOUT, hooks: LifecycleCredentials.new(bootstrap),
      attestation_verifier: trust, datastore_registrar: registrar).pairing_code(
      target_node_id, pairing_code, target_peer,
      fabric_id: bootstrap.fabric.fabric_id,
      root_public_key: bootstrap.fabric.root_public_key,
      controller_node_id: bootstrap.fabric.controller_node_id,
      friendly_name: "Lifecycle target")

    observed.pending_seen?.should be_true
    observed.refresh_sent?.should be_true
    store.load.pending_datastore_nodes.should be_empty
    anchor_session = Matter::Controller::Pairing::CasePairing.new.pair(client, anchor_peer,
      bootstrap.fabric, peer_node_id: anchor_node_id, timeout: E2E::COMMAND_TIMEOUT)
    im = Matter::Controller::ImClient.new(client, E2E::COMMAND_TIMEOUT)
    committed = wait_lifecycle_commit(im, anchor_session, anchor_peer, target_node_id, 120.seconds)
    committed.friendly_name.should eq("Lifecycle target")
    committed.commissioning_status_entry.failure_code.should eq(0_u8)
    endpoints = lifecycle_list(LifecycleJFD::DatastoreEndpointEntryStruct, im, anchor_session,
      anchor_peer, LifecycleJFD::ATTR_NODE_ENDPOINT_LIST)
    endpoints.select(&.node_id.==(target_node_id)).map(&.endpoint_id).should contain(1_u16)
    acls = lifecycle_list(LifecycleJFD::DatastoreACLEntryStruct, im, anchor_session,
      anchor_peer, LifecycleJFD::ATTR_NODE_ACL_LIST)
    anchor_subject = Matter::Controller::JointCommissioning.cat_subject(LifecycleJFD::ANCHOR_CAT, 1_u16)
    acls.any? do |entry|
      entry.node_id == target_node_id && entry.acl_entry.subjects.try(&.includes?(anchor_subject))
    end.should be_true
  ensure
    client.try(&.close)
    store.try(&.backend.close)
  end
end
