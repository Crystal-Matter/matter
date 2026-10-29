require "./e2e_helper"
require "../../src/matter/controller"
require "../../examples/support/joint_fabric_administrator_device"
require "../interop/jfa_vvs_dcl_fixture"

# These are fixture identities, not protocol IDs.
private LINK_LOCAL_ANCHOR_FABRIC_ID = 0xD100_u64
private LINK_LOCAL_JOINER_FABRIC_ID = 0xE100_u64
private LINK_LOCAL_ANCHOR_NODE_ID   = 0xD102_u64
private LINK_LOCAL_JOINER_NODE_ID   = 0xE102_u64
private LINK_LOCAL_JOINED_NODE_ID   = 0xD103_u64
private LINK_LOCAL_NETWORK_PREFIX   = "fd006d617475"
private LINK_LOCAL_PRIMARY_PREFIX   = "fd006d617474"
private LINK_LOCAL_ANCHOR_NAME      = "matter_joint_fabric_link_local_anchor"
private LINK_LOCAL_JOINER_NAME      = "matter_joint_fabric_link_local_joiner"

# /proc/net/if_inet6 includes an interface index and name for each IPv6 address.
# Match the dedicated Compose bridge by its ULA, then take its link-local peer
# and the runner's own interface index on that same bridge. No ethN ordering is
# assumed, and the index is never copied between network namespaces.
private def link_local_bridge_address(path : String, local_scope : Bool) : Socket::IPAddress
  rows = File.read(path).lines.map(&.split)
  bridge = rows.find { |row| row.size >= 6 && row[0].starts_with?(LINK_LOCAL_NETWORK_PREFIX) } ||
           raise Matter::TransportError.new("Dedicated IPv6 bridge is missing from #{path}")
  link_local = rows.find { |row| row.size >= 6 && row[5] == bridge[5] && row[0].starts_with?("fe80") } ||
               raise Matter::TransportError.new("No IPv6 link-local address on dedicated bridge in #{path}")
  # Crystal 1.21 cannot parse a zone on an eight-field IPv6 literal.
  host = Socket::IPAddress.new(link_local[0].scan(/.{4}/).map(&.[0]).join(":"),
    E2E::DEVICE_PORT).address
  index = bridge[1].to_i(16)
  address = local_scope ? "#{host}%#{index}" : host
  Socket::IPAddress.new(address, E2E::DEVICE_PORT)
end

private def link_local_command(request : MatterJointFabricAdministrator::Device::CommandRequest) : MatterJointFabricAdministrator::Device::CommandResult
  path = File.join(E2E::LOG_DIR, "#{LINK_LOCAL_ANCHOR_NAME}.command.yml")
  File.delete?(path)
  backend = Matter::Storage::YamlFile.new(path)
  backend.open
  begin
    backend.write(MatterJointFabricAdministrator::Device::COMMAND_RPC_COLLECTION, "request", request.to_document)
  ensure
    backend.close if backend.open?
  end
  deadline = Time.instant + 120.seconds
  loop do
    store = Matter::Storage::YamlFile.new(path)
    store.open
    result = begin
      value = store.read(MatterJointFabricAdministrator::Device::COMMAND_RPC_COLLECTION, "result")
      value.try { |document| MatterJointFabricAdministrator::Device::CommandResult.from_document(document) }
    ensure
      store.close if store.open?
    end
    return result if result && result.status != "in-progress"
    raise Matter::TimeoutError.new("Link-local Anchor handoff command timed out") if Time.instant >= deadline
    sleep 200.milliseconds
  end
end

describe "scoped IPv6 link-local Joint Commissioning" do
  anchor = E2E::Device[LINK_LOCAL_ANCHOR_NAME]
  joiner = E2E::Device[LINK_LOCAL_JOINER_NAME]

  it "joint-commissions over the second bridge and completes the Anchor handoff" do
    anchor_bootstrap = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      LINK_LOCAL_ANCHOR_FABRIC_ID, 0xD101_u64, 0xFFF1_u16)
    joiner_bootstrap = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      LINK_LOCAL_JOINER_FABRIC_ID, 0xE101_u64, 0xFFF1_u16)
    anchor_store = Matter::Controller::StateStore.new(Matter::Storage::YamlFile.new(
      File.join(E2E::LOG_DIR, "#{LINK_LOCAL_ANCHOR_NAME}.bootstrap.yml")))
    joiner_store = Matter::Controller::StateStore.new(Matter::Storage::YamlFile.new(
      File.join(E2E::LOG_DIR, "#{LINK_LOCAL_JOINER_NAME}.bootstrap.yml")))
    anchor_store.save(Matter::Controller::State.new(fabric: anchor_bootstrap.fabric,
      commissioner_node_id: anchor_bootstrap.fabric.controller_node_id))
    joiner_store.save(Matter::Controller::State.new(fabric: joiner_bootstrap.fabric,
      commissioner_node_id: joiner_bootstrap.fabric.controller_node_id))
    File.write(File.join(E2E::LOG_DIR, "#{LINK_LOCAL_ANCHOR_NAME}.trust-root.tlv"),
      joiner_bootstrap.fabric.root_cert)
    File.write(File.join(E2E::LOG_DIR, "#{LINK_LOCAL_JOINER_NAME}.trust-root.tlv"),
      anchor_bootstrap.fabric.root_cert)

    dcl_fixture = JfaVvsDclFixture.new(E2E::LOG_DIR)
    previous_ssl_cert_file = ENV["SSL_CERT_FILE"]?
    ENV["SSL_CERT_FILE"] = dcl_fixture.cert_path
    mirror_log = File.open(File.join(E2E::LOG_DIR, "jfa-link-local-dcl-mirror.log"), "w")
    mirror = Process.new("python3", ["e2e/interop/jfa_vvs_dcl_mirror.py",
                                     "--state", dcl_fixture.state_path, "--cert", dcl_fixture.server_cert_path,
                                     "--key", dcl_fixture.key_path], output: mirror_log, error: mirror_log)
    mirror_deadline = Time.instant + 10.seconds
    loop do
      begin
        source = Matter::Controller::VidVerification::HttpDclSource.new("https://tests")
        break if source.roots_for(joiner_bootstrap.fabric.admin_vendor_id).size == 1
      rescue Matter::AuthenticationError | IO::Error | Socket::Error | OpenSSL::Error
      end
      raise Matter::TimeoutError.new("Link-local DCL mirror did not start") if Time.instant >= mirror_deadline || mirror.terminated?
      sleep 100.milliseconds
    end

    anchor_client = Matter::Controller::Client.new(
      counter_lease: anchor_store.counter_lease(anchor_bootstrap.fabric.controller_node_id))
    joiner_client = Matter::Controller::Client.new(
      counter_lease: joiner_store.counter_lease(joiner_bootstrap.fabric.controller_node_id))
    anchor_ula = Socket::IPAddress.new(anchor.address, E2E::DEVICE_PORT)
    joiner_ula = Socket::IPAddress.new(joiner.address, E2E::DEVICE_PORT)
    runner_interface = link_local_bridge_address("/proc/net/if_inet6", true)
    joiner_link_local = link_local_bridge_address(
      File.join(E2E::LOG_DIR, "#{LINK_LOCAL_JOINER_NAME}.if_inet6"), false)
    joiner_peer = Socket::IPAddress.new(
      "#{joiner_link_local.address}%#{runner_interface.zone_id}", E2E::DEVICE_PORT)
    joiner_peer.link_local?.should be_true
    joiner_peer.zone_id.should eq(runner_interface.zone_id)
    # A second interface is present in the runner, and the scoped address is
    # tied to the dedicated bridge rather than the primary Matter bridge.
    File.read("/proc/net/if_inet6").lines.any?(&.starts_with?(LINK_LOCAL_PRIMARY_PREFIX)).should be_true

    anchor_issuer = ->(fabric_id : UInt64, node_id : UInt64, key : Bytes) do
      raise Matter::ConfigurationError.new("Wrong link-local Anchor fabric") unless fabric_id == anchor_bootstrap.fabric.fabric_id
      anchor_bootstrap.issue_anchor_administrator_noc(node_id, key)
    end
    joiner_issuer = ->(fabric_id : UInt64, node_id : UInt64, key : Bytes) do
      raise Matter::ConfigurationError.new("Wrong link-local joining fabric") unless fabric_id == joiner_bootstrap.fabric.fabric_id
      joiner_bootstrap.issue_anchor_administrator_noc(node_id, key)
    end
    attestation = Matter::Controller::DeviceAttestationVerifier.new(
      Matter::Controller::AttestationTrustStore.matter_test_fixture)
    Matter::Controller::Commissioning::Commissioner.new(anchor_store, anchor_client,
      timeout: E2E::COMMAND_TIMEOUT, certificate_issuer: anchor_issuer,
      attestation_verifier: attestation).pairing_code(LINK_LOCAL_ANCHOR_NODE_ID,
      anchor.pairing_code, anchor_ula)
    Matter::Controller::Commissioning::Commissioner.new(joiner_store, joiner_client,
      timeout: E2E::COMMAND_TIMEOUT, certificate_issuer: joiner_issuer,
      attestation_verifier: attestation).pairing_code(LINK_LOCAL_JOINER_NODE_ID,
      joiner.pairing_code, joiner_ula)

    # The JFA now has both Compose bridges. Resolve its operational service
    # over mDNS and require the second bridge's link-local AAAA with the
    # runner's interface scope before any JCM traffic uses that route.
    scanner = Matter::Controller::Scanner.new
    begin
      scanner.start
      deadline = Time.instant + 20.seconds
      discovered = nil
      loop do
        scanner.query_operational
        discovered = scanner.operational_devices.find do |device|
          device.node_id == LINK_LOCAL_JOINER_NODE_ID && device.addresses.any? do |address|
            address.address == joiner_link_local.address && address.zone_id == runner_interface.zone_id
          end
        end
        break if discovered || Time.instant >= deadline
        sleep 1.second
      end
      device = discovered || raise Matter::TimeoutError.new("Second-bridge link-local JFA discovery timed out")
      address = device.addresses.find! do |candidate|
        candidate.address == joiner_link_local.address && candidate.zone_id == runner_interface.zone_id
      end
      joiner_peer = Socket::IPAddress.new(
        Matter::Controller::OperationalPeerResolver.address_hint(address), device.port)
      joiner_peer.zone_id.should eq(runner_interface.zone_id)
    ensure
      scanner.close
    end

    joiner_session = Matter::Controller::Pairing::CasePairing.new.pair(joiner_client, joiner_peer,
      joiner_bootstrap.fabric, peer_node_id: LINK_LOCAL_JOINER_NODE_ID,
      timeout: E2E::COMMAND_TIMEOUT)
    joiner_im = Matter::Controller::ImClient.new(joiner_client, E2E::COMMAND_TIMEOUT)
    fabrics = joiner_im.read_attribute(session: joiner_session, peer: joiner_peer,
      endpoint_id: Matter::DataType::EndpointNumber::ROOT.number,
      cluster_id: Matter::Cluster::OperationalCredentials::CLUSTER_ID,
      attribute_id: Matter::Cluster::OperationalCredentials::ATTR_FABRICS,
      fabric_filtered: false)
    fabrics_data = fabrics.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any)
    descriptor = Array(Matter::Cluster::OperationalCredentials::Tlv::FabricDescriptor)
      .from_tlv(fabrics_data.to_slice).find!(&.fabric_id.==(joiner_bootstrap.fabric.fabric_id))
    signer_crypto = Matter::Crypto::StandardCrypto.new
    statement_tbs = IO::Memory.new
    statement_tbs.write_byte Matter::Controller::VidVerification::STATEMENT_VERSION
    statement_tbs.write Matter::Controller::VidVerification.binding_message(descriptor)
    statement_tbs.write dcl_fixture.signer_skid
    statement = IO::Memory.new
    statement.write_byte Matter::Controller::VidVerification::STATEMENT_VERSION
    statement.write dcl_fixture.signer_skid
    statement.write signer_crypto.sign_ecdsa(dcl_fixture.signer_key, statement_tbs.to_slice)
    install_vvs = joiner_im.invoke(session: joiner_session, peer: joiner_peer,
      endpoint_id: Matter::DataType::EndpointNumber::ROOT.number,
      cluster_id: Matter::Cluster::OperationalCredentials::CLUSTER_ID,
      command_id: Matter::Cluster::OperationalCredentials::CMD_SET_VID_VERIFICATION_STATEMENT,
      fields: Matter::Cluster::OperationalCredentials::Tlv::SetVIDVerificationStatementRequest.new(
        joiner_bootstrap.fabric.admin_vendor_id, statement.to_slice.dup).to_slice)
    Matter::Controller::JointCommissioning.assert_status_success(install_vvs)

    discriminator = 0x0F10_u16
    passcode = 20_202_030_u32
    salt = Matter::Crypto::StandardCrypto.new.random_bytes(32)
    iterations = 1_000
    verifier = Matter::Crypto::Spake2p.compute_passcode_verifier(
      Matter::Crypto::StandardCrypto.new,
      Matter::Crypto::Spake2p::PbkdfParameters.new(iterations, salt), passcode)
    open_request = Matter::Cluster::JointFabricAdministrator::OpenJointCommissioningWindowRequest.new(
      900_u16, verifier, discriminator, iterations.to_u32, salt)
    open_response = joiner_im.invoke(session: joiner_session, peer: joiner_peer,
      endpoint_id: 1_u16,
      cluster_id: Matter::Cluster::JointFabricAdministrator::CLUSTER_ID,
      command_id: Matter::Cluster::JointFabricAdministrator::CMD_OPEN_JOINT_COMMISSIONING_WINDOW,
      fields: open_request.to_slice)
    Matter::Controller::JointCommissioning.assert_status_success(open_response)

    trust = Matter::Controller::VidVerification::DclOperationalTrustAnchors.new(
      Matter::Controller::VidVerification::HttpDclSource.new("https://tests"))
    registrar = Matter::Controller::JointCommissioning::RemoteDatastoreRegistrar.new(
      anchor_store, anchor_client, anchor_bootstrap.fabric.fabric_id,
      anchor_bootstrap.fabric.root_public_key, anchor_bootstrap.fabric.controller_node_id,
      LINK_LOCAL_ANCHOR_NODE_ID, 1_u16)
    exchange_path = File.join(E2E::LOG_DIR, "#{LINK_LOCAL_ANCHOR_NAME}.jcm-rpc.yml")
    anchor_exchange = ->(fabric : Matter::Controller::FabricInfo, joining_node_id : UInt64, peer : Socket::IPAddress, endpoint : UInt16, icac_public_key : Bytes, icac_id : UInt64) do
      peer.should eq(joiner_peer)
      File.delete?(exchange_path)
      rpc = Matter::Storage::YamlFile.new(exchange_path)
      rpc.open
      begin
        # The Anchor lives in another network namespace. Its interface index
        # differs from the runner's, so give this separate exchange the ULA.
        request = MatterJointFabricAdministrator::Device::AnchorExchangeRequest.new(
          fabric.fabric_id, fabric.root_public_key, joining_node_id,
          joiner_ula, endpoint, icac_public_key, icac_id)
        rpc.write(MatterJointFabricAdministrator::Device::JCM_RPC_COLLECTION,
          MatterJointFabricAdministrator::Device::JCM_RPC_REQUEST, request.to_document)
      ensure
        rpc.close if rpc.open?
      end
      deadline = Time.instant + 45.seconds
      loop do
        store = Matter::Storage::YamlFile.new(exchange_path)
        store.open
        result = begin
          value = store.read(MatterJointFabricAdministrator::Device::JCM_RPC_COLLECTION,
            MatterJointFabricAdministrator::Device::JCM_RPC_RESULT)
          value.try { |document| MatterJointFabricAdministrator::Device::AnchorExchangeResult.from_document(document) }
        ensure
          store.close if store.open?
        end
        if result
          if result.status == "ok"
            break result.certificate || raise Matter::CommissioningError.new("Link-local Anchor exchange returned no ICAC")
          elsif result.status == "error"
            raise Matter::CommissioningError.new("Link-local Anchor exchange failed: #{result.error}")
          end
        end
        raise Matter::TimeoutError.new("Link-local Anchor exchange timed out") if Time.instant >= deadline
        sleep 100.milliseconds
      end
    end
    anchor_finalize = ->(fabric : Matter::Controller::FabricInfo, joining_node_id : UInt64, peer : Socket::IPAddress, endpoint : UInt16, icac_public_key : Bytes, _icac_id : UInt64, nonce : String) do
      peer.should eq(joiner_peer)
      result = link_local_command(MatterJointFabricAdministrator::Device::CommandRequest.new(
        "finalize-commissioning", joining_node_id,
        fabric_id: fabric.fabric_id, root_public_key: fabric.root_public_key,
        nonce: nonce, jcm: true, trusted_icac_public_key_b: icac_public_key,
        peer_admin_jfa_endpoint_id: endpoint))
      result.status.should eq("ok"), result.error.to_s
      result.nonce.should eq(nonce)
      result.certificate || raise Matter::CommissioningError.new("Link-local handoff returned no ICAC")
    end
    handoff_result = ->(nonce : String) do
      path = File.join(E2E::LOG_DIR, "#{LINK_LOCAL_ANCHOR_NAME}.command.yml")
      store = Matter::Storage::YamlFile.new(path)
      store.open
      result = begin
        value = store.read(MatterJointFabricAdministrator::Device::COMMAND_RPC_COLLECTION, "result")
        value.try { |document| MatterJointFabricAdministrator::Device::CommandResult.from_document(document) }
      ensure
        store.close if store.open?
      end
      if result && result.status == "ok" && result.nonce == nonce
        if certificate = result.certificate
          Matter::Controller::JointCommissioning::Workflow::HandoffResult.new(nonce, certificate)
        end
      end
    end
    workflow = Matter::Controller::JointCommissioning::Workflow.new(
      anchor_store, anchor_bootstrap.fabric.fabric_id,
      anchor_bootstrap.fabric.root_public_key, anchor_bootstrap.fabric.controller_node_id,
      1_u8, 1_u16, "Link-local Joining Administrator", 1_u16, 1_u16, 3_u64, trust,
      ->(_im : Matter::Controller::ImClient, _session : Matter::Session::SecureContext, _peer : Socket::IPAddress, _joiner : Matter::Controller::JointCommissioning::VerifiedJoiner) { true },
      ->(_joiner : Matter::Controller::JointCommissioning::VerifiedJoiner) { true },
      registrar.callback, anchor_exchange,
      client: anchor_client, anchor_finalize: anchor_finalize,
      node_list_check: registrar.node_list_check, handoff_result: handoff_result,
      attestation_verifier: attestation)
    workflow.commission(LINK_LOCAL_JOINED_NODE_ID,
      Matter::SetupPayload.generate_manual_code(discriminator, passcode), joiner_peer,
      defer_completion: true)
    workflow.stored_icac(LINK_LOCAL_JOINED_NODE_ID).should_not be_nil
    joined_session = Matter::Controller::Pairing::CasePairing.new.pair(anchor_client, joiner_peer,
      anchor_bootstrap.fabric, peer_node_id: LINK_LOCAL_JOINED_NODE_ID,
      timeout: E2E::COMMAND_TIMEOUT)
    joined_fabrics = Matter::Controller::ImClient.new(anchor_client, E2E::COMMAND_TIMEOUT).read_attribute(
      session: joined_session, peer: joiner_peer,
      endpoint_id: Matter::DataType::EndpointNumber::ROOT.number,
      cluster_id: Matter::Cluster::OperationalCredentials::CLUSTER_ID,
      attribute_id: Matter::Cluster::OperationalCredentials::ATTR_FABRICS)
    joined_data = joined_fabrics.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any)
    Array(Matter::Cluster::OperationalCredentials::Tlv::FabricDescriptor)
      .from_tlv(joined_data.to_slice).map(&.fabric_id).should contain(anchor_bootstrap.fabric.fabric_id)
    anchor_session = Matter::Controller::Pairing::CasePairing.new.pair(anchor_client, anchor_ula,
      anchor_bootstrap.fabric, peer_node_id: LINK_LOCAL_ANCHOR_NODE_ID,
      timeout: E2E::COMMAND_TIMEOUT)
    admins = Matter::Controller::ImClient.new(anchor_client, E2E::COMMAND_TIMEOUT).read_attribute(
      session: anchor_session, peer: anchor_ula, endpoint_id: 1_u16,
      cluster_id: Matter::Cluster::JointFabricDatastore::CLUSTER_ID,
      attribute_id: Matter::Cluster::JointFabricDatastore::ATTR_ADMIN_LIST)
    admins_data = admins.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any)
    Array(Matter::Cluster::JointFabricDatastore::DatastoreAdministratorInformationEntryStruct)
      .from_tlv(admins_data.to_slice).map(&.node_id).should contain(LINK_LOCAL_JOINED_NODE_ID)
  ensure
    if previous_ssl_cert_file
      ENV["SSL_CERT_FILE"] = previous_ssl_cert_file
    else
      ENV.delete("SSL_CERT_FILE")
    end
    mirror.try(&.terminate)
    mirror.try(&.wait)
    mirror_log.try(&.close)
    anchor_client.try(&.close)
    joiner_client.try(&.close)
  end
end
