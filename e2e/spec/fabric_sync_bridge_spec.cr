require "./e2e_helper"
require "../../src/matter/controller"

private alias BridgeHost = Matter::Controller::BridgedCommissioningHost
private alias BridgeCluster = Matter::Cluster::BridgedAdministratorCommissioning
private alias Admin = Matter::Cluster::AdministratorCommissioning

describe "real target Fabric Synchronization bridge" do
  bridge = E2E::Device["matter_fabric_sync_bridge"]
  target = E2E::Device["matter_fabric_sync_target"]
  state_path = File.join(E2E::LOG_DIR, "matter_fabric_sync_bridge.controller.yml")
  consent_path = File.join(E2E::LOG_DIR, "matter_fabric_sync_bridge.consent")
  consent_request_path = consent_path + ".request"
  target_node_id = 0xB801_u64
  target_fabric_index = 1_u8
  timed = ["--timedInteractionTimeoutMs", "30000"]

  it "forwards consented timed Open and Revoke to the CASE-verified target across restart" do
    File.delete?(consent_path)
    File.delete?(consent_request_path)
    bootstrap = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      0xB800_u64, 0xB802_u64, Matter::SetupPayload.test_vendor_id)
    store = Matter::Controller::StateStore.new(Matter::Storage::YamlFile.new(state_path))
    store.save(Matter::Controller::State.new(fabric: bootstrap.fabric,
      commissioner_node_id: bootstrap.fabric.controller_node_id))
    target_peer = Socket::IPAddress.new(target.address, E2E::DEVICE_PORT)
    client = Matter::Controller::Client.new
    begin
      Matter::Controller::Commissioning::Commissioner.new(store, client,
        timeout: E2E::COMMAND_TIMEOUT,
        attestation_verifier: Matter::Controller::DeviceAttestationVerifier.new(
          Matter::Controller::AttestationTrustStore.matter_test_fixture)).pairing_code(
        target_node_id, target.pairing_code, target_peer)
    ensure
      client.close
    end

    # Provisioning creates a persistent binding only after live CASE and an
    # unfiltered Fabrics read match the expected target and fabric index.
    endpoint = Matter::DataType::EndpointNumber.new(1_u16)
    noop_open = ->(_fabric : UInt8, _node : UInt64, _caller : UInt8, _caller_node : UInt64, _request : Admin::OpenCommissioningWindowRequest) { Matter::InteractionModel::Status.success }
    noop_revoke = ->(_fabric : UInt8, _node : UInt64, _caller : UInt8, _caller_node : UInt64) { Matter::InteractionModel::Status.success }
    cluster = BridgeCluster.new(endpoint, target_fabric_index, target_node_id, noop_open, noop_revoke)
    setup_host = BridgeHost.new(store, cluster,
      ->(_index : UInt8) { nil.as(Tuple(UInt64, Bytes)?) },
      ->(_caller : BridgeHost::CallerIdentity, _node : UInt64, _operation : Symbol) { true },
      E2E::COMMAND_TIMEOUT)
    setup_host.bind!(BridgeHost::Binding.new(bootstrap.fabric.fabric_id,
      bootstrap.fabric.root_public_key, bootstrap.fabric.controller_node_id,
      target_node_id, target_fabric_index, target.address, E2E::DEVICE_PORT))

    bridge.commission!
    bridge.restart!
    pin = Matter::SetupPayload.generate_random_pin
    discriminator = Matter::SetupPayload.generate_random_discriminator
    salt = Random::Secure.random_bytes(Admin::PAKE_SALT_MIN_LENGTH)
    iterations = Admin::PBKDF2_MIN_ITERATIONS.to_u32
    pbkdf = Matter::Crypto::Spake2p::PbkdfParameters.new(iterations.to_i32, salt)
    verifier = Matter::Crypto::Spake2p.compute_passcode_verifier(Matter::Crypto::StandardCrypto.new, pbkdf, pin)
    open_args = ["180", "hex:#{verifier.hexstring}", discriminator.to_s,
                 iterations.to_s, "hex:#{salt.hexstring}"]

    expect_failure(bridge.invoke("administratorcommissioning", "open-commissioning-window",
      open_args, endpoint: 1, options: timed), "UNSUPPORTED_ACCESS")
    File.write(consent_path, File.read(consent_request_path))
    expect_success(bridge.invoke("administratorcommissioning", "open-commissioning-window",
      open_args, endpoint: 1, options: timed))
    read_int(bridge, "administratorcommissioning", "window-status", "WindowStatus", 1).should eq(
      Admin::CommissioningWindowStatus::EnhancedWindowOpen.value.to_i64)
    read_int(bridge, "administratorcommissioning", "admin-vendor-id", "AdminVendorId", 1).should eq(
      bootstrap.fabric.admin_vendor_id.to_i64)

    bridge.restart!
    deadline = Time.instant + E2E::COMMAND_TIMEOUT
    until read_int(bridge, "administratorcommissioning", "window-status", "WindowStatus", 1) ==
            Admin::CommissioningWindowStatus::EnhancedWindowOpen.value.to_i64
      raise Matter::TimeoutError.new("Bridge did not restore observed remote window status") if Time.instant >= deadline
      sleep 1.second
    end
    expect_failure(bridge.invoke("administratorcommissioning", "revoke-commissioning",
      endpoint: 1, options: timed), "UNSUPPORTED_ACCESS")
    File.write(consent_path, File.read(consent_request_path))
    expect_success(bridge.invoke("administratorcommissioning", "revoke-commissioning",
      endpoint: 1, options: timed))
    read_int(bridge, "administratorcommissioning", "window-status", "WindowStatus", 1).should eq(
      Admin::CommissioningWindowStatus::WindowNotOpen.value.to_i64)
    verify_client = Matter::Controller::Client.new
    begin
      session = Matter::Controller::Pairing::CasePairing.new.pair(verify_client, target_peer,
        bootstrap.fabric, peer_node_id: target_node_id, timeout: E2E::COMMAND_TIMEOUT)
      report = Matter::Controller::ImClient.new(verify_client, E2E::COMMAND_TIMEOUT).read_attribute(
        session, target_peer, Matter::Node::ROOT_ENDPOINT_ID,
        Admin::CLUSTER_ID, Admin::ATTR_WINDOW_STATUS)
      report.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
        .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any).as_u8
        .should eq(Admin::CommissioningWindowStatus::WindowNotOpen.value)
    ensure
      verify_client.close
    end
  end
end
