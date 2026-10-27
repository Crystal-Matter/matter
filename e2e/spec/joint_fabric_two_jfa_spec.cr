require "./e2e_helper"
require "../../src/matter/controller"
require "../../examples/support/joint_fabric_administrator_device"
require "../interop/jfa_vvs_dcl_fixture"

private alias JfaRolloutDatastore = Matter::Cluster::JointFabricDatastore
private alias JfaRollout = Matter::Controller::IpkRollout
MIGRATION_RECOVERY_MIN_WAIT = 120.seconds

# The joining Administrator's original fabric has an ICAC, so its VVS signer
# must be provisioned out of band rather than carried as a VVSC in NOCStruct.

private class JcmInterruptedDelivery < Matter::Controller::DatastoreNodeRegistrar::Delivery
  def add_pending_node(fabric : Matter::Controller::FabricInfo, node_id : UInt64,
                       friendly_name : String) : Nil
  end

  def refresh_node(fabric : Matter::Controller::FabricInfo, node_id : UInt64) : Nil
  end

  def remove_node(fabric : Matter::Controller::FabricInfo, node_id : UInt64,
                  friendly_name : String) : Nil
  end
end

# completing runs after the controller has persisted AddICAC and before it
# invokes CommissioningComplete. The failure is scoped to this E2E registrar.
private class JcmInterruptedRegistrar < Matter::Controller::DatastoreNodeRegistrar
  def completing(fabric : Matter::Controller::FabricInfo, node_id : UInt64) : Nil
    raise Matter::TransportError.new("Injected interruption after AddICAC")
  end
end

private def jfa_command(device_name : String,
                        request : MatterJointFabricAdministrator::Device::CommandRequest,
                        timeout : Time::Span = 300.seconds) : MatterJointFabricAdministrator::Device::CommandResult
  path = File.join(E2E::LOG_DIR, "#{device_name}.command.yml")
  File.delete?(path)
  backend = Matter::Storage::YamlFile.new(path)
  backend.open
  begin
    backend.write(MatterJointFabricAdministrator::Device::COMMAND_RPC_COLLECTION,
      "request", request.to_document)
  ensure
    backend.close if backend.open?
  end
  deadline = Time.instant + timeout
  loop do
    result_store = Matter::Storage::YamlFile.new(path)
    result_store.open
    result = begin
      document = result_store.read(MatterJointFabricAdministrator::Device::COMMAND_RPC_COLLECTION,
        "result")
      document.try { |value| MatterJointFabricAdministrator::Device::CommandResult.from_document(value) }
    ensure
      result_store.close if result_store.open?
    end
    return result if result && result.status != "in-progress"
    raise Matter::TimeoutError.new("#{device_name} headless command timed out") if Time.instant >= deadline
    sleep 200.milliseconds
  end
end

private def candidate_admin_icac(client : Matter::Controller::Client,
                                 peer : Socket::IPAddress,
                                 fabric : Matter::Controller::FabricInfo,
                                 candidate_node_id : UInt64,
                                 administrator_node_id : UInt64) : Bytes
  session = Matter::Controller::Pairing::CasePairing.new.pair(client, peer, fabric,
    peer_node_id: candidate_node_id, timeout: E2E::COMMAND_TIMEOUT)
  im = Matter::Controller::ImClient.new(client, E2E::COMMAND_TIMEOUT)
  report = im.read_attribute(session: session, peer: peer, endpoint_id: 1_u16,
    cluster_id: Matter::Cluster::JointFabricDatastore::CLUSTER_ID,
    attribute_id: Matter::Cluster::JointFabricDatastore::ATTR_ADMIN_LIST)
  data = report.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
    .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any)
  Array(Matter::Cluster::JointFabricDatastore::DatastoreAdministratorInformationEntryStruct)
    .from_tlv(data.to_slice).find!(&.node_id.==(administrator_node_id)).icac
end

private def administrator_noc(client : Matter::Controller::Client,
                              peer : Socket::IPAddress,
                              fabric : Matter::Controller::FabricInfo,
                              node_id : UInt64) : Matter::Cluster::OperationalCredentials::Tlv::NOC
  session = Matter::Controller::Pairing::CasePairing.new.pair(client, peer, fabric,
    peer_node_id: node_id, timeout: E2E::COMMAND_TIMEOUT)
  im = Matter::Controller::ImClient.new(client, E2E::COMMAND_TIMEOUT)
  report = im.read_attribute(session: session, peer: peer,
    endpoint_id: Matter::DataType::EndpointNumber::ROOT.number,
    cluster_id: Matter::Cluster::OperationalCredentials::CLUSTER_ID,
    attribute_id: Matter::Cluster::OperationalCredentials::ATTR_NOCS)
  data = report.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
    .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any)
  Array(Matter::Cluster::OperationalCredentials::Tlv::NOC).from_tlv(data.to_slice).first
end

private def wait_two_jfa_acl(im : Matter::Controller::ImClient,
                             session : Matter::Session::SecureContext,
                             peer : Socket::IPAddress, node_id : UInt64,
                             subject : UInt64, timeout : Time::Span) : Nil
  deadline = Time.instant + timeout
  loop do
    report = im.read_attribute(session: session, peer: peer, endpoint_id: 1_u16,
      cluster_id: Matter::Cluster::JointFabricDatastore::CLUSTER_ID,
      attribute_id: Matter::Cluster::JointFabricDatastore::ATTR_NODE_ACL_LIST)
    data = report.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any)
    acl = Array(Matter::Cluster::JointFabricDatastore::DatastoreACLEntryStruct).from_tlv(data.to_slice)
    entry = acl.find do |candidate|
      candidate.node_id == node_id && candidate.acl_entry.subjects.try(&.includes?(subject))
    end
    return if entry && entry.status_entry.state.committed?
    raise Matter::TimeoutError.new("B controller ACL did not commit for migrated A node") if Time.instant >= deadline
    sleep 1.second
  end
end

private def jfa_rollout_attribute(type : T.class, im : Matter::Controller::ImClient,
                                  session : Matter::Session::SecureContext,
                                  peer : Socket::IPAddress, attribute_id : UInt32) : T forall T
  report = im.read_attribute(session: session, peer: peer, endpoint_id: 1_u16,
    cluster_id: Matter::Cluster::JointFabricDatastore::CLUSTER_ID,
    attribute_id: attribute_id)
  data = report.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
    .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any)
  T.from_tlv(data.to_slice)
end

private def assert_joiner_vvs(client : Matter::Controller::Client,
                              peer : Socket::IPAddress,
                              fabric : Matter::Controller::FabricInfo,
                              signed_statement : Bytes,
                              expected_icac : Bytes) : Nil
  session = Matter::Controller::Pairing::CasePairing.new.pair(client, peer, fabric,
    peer_node_id: 0xB102_u64, timeout: E2E::COMMAND_TIMEOUT)
  im = Matter::Controller::ImClient.new(client, E2E::COMMAND_TIMEOUT)
  verified = Matter::Controller::VidVerification.verify(im, session, peer, 1_u8,
    Matter::Controller::VidVerification::DclOperationalTrustAnchors.new(
      Matter::Controller::VidVerification::HttpDclSource.new("https://tests")))
  verified.descriptor.vid_verification_statement.should eq(signed_statement)
  verified.noc.icac.should eq(expected_icac)
  verified.noc.vvsc.should be_nil
end

private def commission_third_administrator(anchor_store : Matter::Controller::StateStore,
                                           anchor_client : Matter::Controller::Client,
                                           anchor_bootstrap : Matter::Controller::JointCommissioning::AnchorBootstrap,
                                           third_client : Matter::Controller::Client,
                                           third_bootstrap : Matter::Controller::JointCommissioning::AnchorBootstrap,
                                           third_peer : Socket::IPAddress) : Bytes
  discriminator = 0x0F01_u16
  passcode = 20_202_022_u32
  salt = Matter::Crypto::StandardCrypto.new.random_bytes(32)
  iterations = 1_000
  verifier = Matter::Crypto::Spake2p.compute_passcode_verifier(
    Matter::Crypto::StandardCrypto.new,
    Matter::Crypto::Spake2p::PbkdfParameters.new(iterations, salt), passcode)
  open_request = Matter::Cluster::JointFabricAdministrator::OpenJointCommissioningWindowRequest.new(
    900_u16, verifier, discriminator, iterations.to_u32, salt)
  session = Matter::Controller::Pairing::CasePairing.new.pair(third_client, third_peer,
    third_bootstrap.fabric, peer_node_id: 0xC102_u64, timeout: E2E::COMMAND_TIMEOUT)
  im = Matter::Controller::ImClient.new(third_client, E2E::COMMAND_TIMEOUT)
  response = im.invoke(session: session, peer: third_peer, endpoint_id: 1_u16,
    cluster_id: Matter::Cluster::JointFabricAdministrator::CLUSTER_ID,
    command_id: Matter::Cluster::JointFabricAdministrator::CMD_OPEN_JOINT_COMMISSIONING_WINDOW,
    fields: open_request.to_slice)
  Matter::Controller::JointCommissioning.assert_status_success(response)

  trust = Matter::Controller::VidVerification::StaticOperationalTrustAnchors.new(
    {third_bootstrap.fabric.admin_vendor_id => [third_bootstrap.fabric.root_cert]})
  registrar = Matter::Controller::JointCommissioning::RemoteDatastoreRegistrar.new(
    anchor_store, anchor_client, anchor_bootstrap.fabric.fabric_id,
    anchor_bootstrap.fabric.root_public_key, anchor_bootstrap.fabric.controller_node_id,
    0xA102_u64, 1_u16)
  exchange_path = File.join(E2E::LOG_DIR, "matter_joint_fabric_anchor.jcm-rpc.yml")
  anchor_exchange = ->(fabric : Matter::Controller::FabricInfo, joining_node_id : UInt64, peer : Socket::IPAddress, endpoint : UInt16, icac_public_key : Bytes, icac_id : UInt64) do
    unless fabric.fabric_id == anchor_bootstrap.fabric.fabric_id
      raise Matter::ConfigurationError.new("Third Administrator exchange selected the wrong fabric")
    end
    File.delete?(exchange_path)
    rpc = Matter::Storage::YamlFile.new(exchange_path)
    rpc.open
    begin
      request = MatterJointFabricAdministrator::Device::AnchorExchangeRequest.new(
        fabric.fabric_id, fabric.root_public_key, joining_node_id,
        peer, endpoint, icac_public_key, icac_id)
      rpc.write(MatterJointFabricAdministrator::Device::JCM_RPC_COLLECTION,
        MatterJointFabricAdministrator::Device::JCM_RPC_REQUEST, request.to_document)
    ensure
      rpc.close if rpc.open?
    end
    deadline = Time.instant + 45.seconds
    loop do
      result_store = Matter::Storage::YamlFile.new(exchange_path)
      result_store.open
      result = begin
        document = result_store.read(MatterJointFabricAdministrator::Device::JCM_RPC_COLLECTION,
          MatterJointFabricAdministrator::Device::JCM_RPC_RESULT)
        document.try { |value| MatterJointFabricAdministrator::Device::AnchorExchangeResult.from_document(value) }
      ensure
        result_store.close if result_store.open?
      end
      if result
        if result.status == "ok"
          break result.certificate || raise Matter::CommissioningError.new("Third Administrator exchange returned no ICAC")
        elsif result.status == "error"
          raise Matter::CommissioningError.new("Third Administrator exchange failed: #{result.error}")
        end
      end
      raise Matter::TimeoutError.new("Third Administrator exchange timed out") if Time.instant >= deadline
      sleep 100.milliseconds
    end
  end
  anchor_finalize = ->(fabric : Matter::Controller::FabricInfo, joining_node_id : UInt64, peer : Socket::IPAddress, endpoint : UInt16, icac_public_key : Bytes, _icac_id : UInt64, nonce : String) do
    unless fabric.fabric_id == anchor_bootstrap.fabric.fabric_id && peer == third_peer
      raise Matter::ConfigurationError.new("Third Administrator handoff selected the wrong fabric or peer")
    end
    result = jfa_command("matter_joint_fabric_anchor",
      MatterJointFabricAdministrator::Device::CommandRequest.new("finalize-commissioning", joining_node_id,
        fabric_id: fabric.fabric_id, root_public_key: fabric.root_public_key,
        nonce: nonce, jcm: true, trusted_icac_public_key_b: icac_public_key,
        peer_admin_jfa_endpoint_id: endpoint))
    unless result.status == "ok" && result.nonce == nonce
      raise Matter::CommissioningError.new("Third Administrator handoff failed: #{result.error}")
    end
    result.certificate || raise Matter::CommissioningError.new("Third Administrator handoff returned no ICAC")
  end
  handoff_result = ->(nonce : String) do
    path = File.join(E2E::LOG_DIR, "matter_joint_fabric_anchor.command.yml")
    backend = Matter::Storage::YamlFile.new(path)
    backend.open
    result = begin
      document = backend.read(MatterJointFabricAdministrator::Device::COMMAND_RPC_COLLECTION, "result")
      document.try { |value| MatterJointFabricAdministrator::Device::CommandResult.from_document(value) }
    ensure
      backend.close if backend.open?
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
    1_u8, 1_u16, "Third Administrator", 1_u16, 1_u16, 3_u64, trust,
    ->(_im : Matter::Controller::ImClient, _session : Matter::Session::SecureContext, _peer : Socket::IPAddress, _joiner : Matter::Controller::JointCommissioning::VerifiedJoiner) { true },
    ->(_joiner : Matter::Controller::JointCommissioning::VerifiedJoiner) { true },
    registrar.callback, anchor_exchange, client: anchor_client,
    anchor_finalize: anchor_finalize, handoff_result: handoff_result,
    attestation_verifier: Matter::Controller::DeviceAttestationVerifier.new(
      Matter::Controller::AttestationTrustStore.matter_test_fixture))
  workflow.commission(0xA104_u64,
    Matter::SetupPayload.generate_manual_code(discriminator, passcode), third_peer,
    defer_completion: true)
  workflow.stored_icac(0xA104_u64) ||
    raise Matter::CommissioningError.new("Third Administrator cross-signed ICAC was not retained")
end

# Three separately bootstrapped Joint Fabric Administrators, each carrying its
# own Anchor ICAC and CATs. Their controller states and trust roots are written
# into the shared e2e volume before commissioning the device processes.
describe "three provisioned Joint Fabric Administrators" do
  anchor = E2E::Device["matter_joint_fabric_anchor"]
  joiner = E2E::Device["matter_joint_fabric_joiner"]
  third = E2E::Device["matter_joint_fabric_third"]
  migration_target = E2E::Device["matter_joint_fabric_migration_target"]

  it "joint-commissions two Administrators, transfers Anchor, and removes one" do
    anchor_bootstrap = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      0xA100_u64, 0xA101_u64, 0xFFF1_u16)
    joiner_bootstrap = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      0xB100_u64, 0xB101_u64, 0xFFF1_u16)
    third_bootstrap = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      0xC100_u64, 0xC101_u64, 0xFFF1_u16)

    anchor_store = Matter::Controller::StateStore.new(Matter::Storage::YamlFile.new(
      File.join(E2E::LOG_DIR, "matter_joint_fabric_anchor.bootstrap.yml")))
    joiner_store = Matter::Controller::StateStore.new(Matter::Storage::YamlFile.new(
      File.join(E2E::LOG_DIR, "matter_joint_fabric_joiner.bootstrap.yml")))
    third_store = Matter::Controller::StateStore.new(Matter::Storage::YamlFile.new(
      File.join(E2E::LOG_DIR, "matter_joint_fabric_third.bootstrap.yml")))
    anchor_store.save(Matter::Controller::State.new(fabric: anchor_bootstrap.fabric,
      commissioner_node_id: anchor_bootstrap.fabric.controller_node_id))
    joiner_store.save(Matter::Controller::State.new(fabric: joiner_bootstrap.fabric,
      commissioner_node_id: joiner_bootstrap.fabric.controller_node_id))
    third_store.save(Matter::Controller::State.new(fabric: third_bootstrap.fabric,
      commissioner_node_id: third_bootstrap.fabric.controller_node_id))

    File.write(File.join(E2E::LOG_DIR, "matter_joint_fabric_anchor.trust-root.tlv"),
      joiner_bootstrap.fabric.root_cert)
    File.write(File.join(E2E::LOG_DIR, "matter_joint_fabric_joiner.trust-root.tlv"),
      anchor_bootstrap.fabric.root_cert)
    File.write(File.join(E2E::LOG_DIR, "matter_joint_fabric_anchor.third-trust-root.tlv"),
      third_bootstrap.fabric.root_cert)
    File.write(File.join(E2E::LOG_DIR, "matter_joint_fabric_third.trust-root.tlv"),
      anchor_bootstrap.fabric.root_cert)
    File.write(File.join(E2E::LOG_DIR, "matter_joint_fabric_third.new-anchor-root.tlv"),
      joiner_bootstrap.fabric.root_cert)

    dcl_fixture = JfaVvsDclFixture.new(E2E::LOG_DIR)
    previous_ssl_cert_file = ENV["SSL_CERT_FILE"]?
    ENV["SSL_CERT_FILE"] = dcl_fixture.cert_path
    mirror_log = File.open(File.join(E2E::LOG_DIR, "jfa-dcl-mirror.log"), "w")
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
      raise Matter::TimeoutError.new("Test HTTPS DCL mirror did not start") if Time.instant >= mirror_deadline || mirror.terminated?
      sleep 100.milliseconds
    end

    anchor_client = Matter::Controller::Client.new(
      unsecured_source_node_id: anchor_bootstrap.fabric.controller_node_id)
    joiner_client = Matter::Controller::Client.new(
      unsecured_source_node_id: joiner_bootstrap.fabric.controller_node_id)
    third_client = Matter::Controller::Client.new(
      unsecured_source_node_id: third_bootstrap.fabric.controller_node_id)
    anchor_peer = Socket::IPAddress.new(anchor.address, E2E::DEVICE_PORT)
    joiner_peer = Socket::IPAddress.new(joiner.address, E2E::DEVICE_PORT)
    third_peer = Socket::IPAddress.new(third.address, E2E::DEVICE_PORT)

    anchor_issuer = ->(fabric_id : UInt64, node_id : UInt64, key : Bytes) do
      raise Matter::ConfigurationError.new("Wrong Anchor fabric") unless fabric_id == anchor_bootstrap.fabric.fabric_id
      anchor_bootstrap.issue_anchor_administrator_noc(node_id, key)
    end
    joiner_issuer = ->(fabric_id : UInt64, node_id : UInt64, key : Bytes) do
      raise Matter::ConfigurationError.new("Wrong joining fabric") unless fabric_id == joiner_bootstrap.fabric.fabric_id
      joiner_bootstrap.issue_anchor_administrator_noc(node_id, key)
    end
    third_issuer = ->(fabric_id : UInt64, node_id : UInt64, key : Bytes) do
      raise Matter::ConfigurationError.new("Wrong third fabric") unless fabric_id == third_bootstrap.fabric.fabric_id
      third_bootstrap.issue_anchor_administrator_noc(node_id, key)
    end
    Matter::Controller::Commissioning::Commissioner.new(anchor_store, anchor_client,
      timeout: E2E::COMMAND_TIMEOUT, certificate_issuer: anchor_issuer,
      attestation_verifier: Matter::Controller::DeviceAttestationVerifier.new(
        Matter::Controller::AttestationTrustStore.matter_test_fixture)).pairing_code(
      0xA102_u64, anchor.pairing_code, anchor_peer)
    Matter::Controller::Commissioning::Commissioner.new(joiner_store, joiner_client,
      timeout: E2E::COMMAND_TIMEOUT, certificate_issuer: joiner_issuer,
      attestation_verifier: Matter::Controller::DeviceAttestationVerifier.new(
        Matter::Controller::AttestationTrustStore.matter_test_fixture)).pairing_code(
      0xB102_u64, joiner.pairing_code, joiner_peer)
    Matter::Controller::Commissioning::Commissioner.new(third_store, third_client,
      timeout: E2E::COMMAND_TIMEOUT, certificate_issuer: third_issuer,
      attestation_verifier: Matter::Controller::DeviceAttestationVerifier.new(
        Matter::Controller::AttestationTrustStore.matter_test_fixture)).pairing_code(
      0xC102_u64, third.pairing_code, third_peer)

    [{anchor_client, anchor_peer, anchor_bootstrap.fabric, 0xA102_u64},
     {joiner_client, joiner_peer, joiner_bootstrap.fabric, 0xB102_u64},
     {third_client, third_peer, third_bootstrap.fabric, 0xC102_u64}].each do |client, peer, fabric, node_id|
      session = Matter::Controller::Pairing::CasePairing.new.pair(client, peer, fabric,
        peer_node_id: node_id, timeout: E2E::COMMAND_TIMEOUT)
      im = Matter::Controller::ImClient.new(client, E2E::COMMAND_TIMEOUT)
      report = im.read_attribute(session: session, peer: peer, endpoint_id: 1_u16,
        cluster_id: Matter::Cluster::JointFabricDatastore::CLUSTER_ID,
        attribute_id: Matter::Cluster::JointFabricDatastore::ATTR_GROUP_LIST)
      data = report.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
        .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any)
      groups = Array(Matter::Cluster::JointFabricDatastore::DatastoreGroupInformationEntryStruct).from_tlv(data.to_slice)
      groups.compact_map(&.group_cat).should contain(0xFFFF_u16)
      groups.compact_map(&.group_cat).should contain(0xFFFE_u16)

      key_report = im.read_attribute(session: session, peer: peer, endpoint_id: 1_u16,
        cluster_id: Matter::Cluster::JointFabricDatastore::CLUSTER_ID,
        attribute_id: Matter::Cluster::JointFabricDatastore::ATTR_GROUP_KEY_SET_LIST)
      key_data = key_report.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
        .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any)
      key_sets = Array(Matter::Cluster::JointFabricDatastore::DatastoreGroupKeySetStruct).from_tlv(key_data.to_slice)
      key_sets.map(&.group_key_set_id).should contain(0_u16)

      admin_report = im.read_attribute(session: session, peer: peer, endpoint_id: 1_u16,
        cluster_id: Matter::Cluster::JointFabricDatastore::CLUSTER_ID,
        attribute_id: Matter::Cluster::JointFabricDatastore::ATTR_ADMIN_LIST)
      admin_data = admin_report.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
        .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any)
      admins = Array(Matter::Cluster::JointFabricDatastore::DatastoreAdministratorInformationEntryStruct).from_tlv(admin_data.to_slice)
      admins.map(&.node_id).should contain(node_id)
      admins.first.icac.should eq(fabric.intermediate_cert)
    end

    discriminator = 0x0F00_u16
    passcode = 20_202_021_u32
    salt = Matter::Crypto::StandardCrypto.new.random_bytes(32)
    iterations = 1_000
    verifier = Matter::Crypto::Spake2p.compute_passcode_verifier(
      Matter::Crypto::StandardCrypto.new,
      Matter::Crypto::Spake2p::PbkdfParameters.new(iterations, salt), passcode)
    open_request = Matter::Cluster::JointFabricAdministrator::OpenJointCommissioningWindowRequest.new(
      900_u16, verifier, discriminator, iterations.to_u32, salt)
    joiner_session = Matter::Controller::Pairing::CasePairing.new.pair(joiner_client, joiner_peer,
      joiner_bootstrap.fabric, peer_node_id: 0xB102_u64, timeout: E2E::COMMAND_TIMEOUT)
    joiner_im = Matter::Controller::ImClient.new(joiner_client, E2E::COMMAND_TIMEOUT)
    open_response = joiner_im.invoke(session: joiner_session, peer: joiner_peer,
      endpoint_id: 1_u16,
      cluster_id: Matter::Cluster::JointFabricAdministrator::CLUSTER_ID,
      command_id: Matter::Cluster::JointFabricAdministrator::CMD_OPEN_JOINT_COMMISSIONING_WINDOW,
      fields: open_request.to_slice)
    Matter::Controller::JointCommissioning.assert_status_success(open_response)

    original_fabrics_report = joiner_im.read_attribute(session: joiner_session, peer: joiner_peer,
      endpoint_id: 0_u16,
      cluster_id: Matter::Cluster::OperationalCredentials::CLUSTER_ID,
      attribute_id: Matter::Cluster::OperationalCredentials::ATTR_FABRICS,
      fabric_filtered: false)
    original_fabrics_data = original_fabrics_report.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any)
    descriptor = Array(Matter::Cluster::OperationalCredentials::Tlv::FabricDescriptor)
      .from_tlv(original_fabrics_data.to_slice)
      .find { |entry| entry.fabric_id == joiner_bootstrap.fabric.fabric_id && entry.node_id == 0xB102_u64 }
      .as(Matter::Cluster::OperationalCredentials::Tlv::FabricDescriptor)
    signer_crypto = Matter::Crypto::StandardCrypto.new
    signer_key = dcl_fixture.signer_key
    signer_skid = dcl_fixture.signer_skid
    statement_tbs = IO::Memory.new
    statement_tbs.write_byte Matter::Controller::VidVerification::STATEMENT_VERSION
    statement_tbs.write Matter::Controller::VidVerification.binding_message(descriptor)
    statement_tbs.write signer_skid
    statement = IO::Memory.new
    statement.write_byte Matter::Controller::VidVerification::STATEMENT_VERSION
    statement.write signer_skid
    statement.write signer_crypto.sign_ecdsa(signer_key, statement_tbs.to_slice)
    signed_statement = statement.to_slice.dup
    signed_statement.size.should eq(Matter::Controller::VidVerification::STATEMENT_SIZE)
    install_vvs = joiner_im.invoke(session: joiner_session, peer: joiner_peer,
      endpoint_id: 0_u16,
      cluster_id: Matter::Cluster::OperationalCredentials::CLUSTER_ID,
      command_id: Matter::Cluster::OperationalCredentials::CMD_SET_VID_VERIFICATION_STATEMENT,
      fields: Matter::Cluster::OperationalCredentials::Tlv::SetVIDVerificationStatementRequest.new(
        joiner_bootstrap.fabric.admin_vendor_id, signed_statement).to_slice)
    Matter::Controller::JointCommissioning.assert_status_success(install_vvs)

    installed_fabrics_report = joiner_im.read_attribute(session: joiner_session, peer: joiner_peer,
      endpoint_id: 0_u16,
      cluster_id: Matter::Cluster::OperationalCredentials::CLUSTER_ID,
      attribute_id: Matter::Cluster::OperationalCredentials::ATTR_FABRICS,
      fabric_filtered: false)
    installed_fabrics_data = installed_fabrics_report.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any)
    installed_descriptor = Array(Matter::Cluster::OperationalCredentials::Tlv::FabricDescriptor)
      .from_tlv(installed_fabrics_data.to_slice)
      .find(&.fabric_index.==(descriptor.fabric_index))
      .as(Matter::Cluster::OperationalCredentials::Tlv::FabricDescriptor)
    installed_descriptor.vid_verification_statement.should eq(signed_statement)
    original_nocs_report = joiner_im.read_attribute(session: joiner_session, peer: joiner_peer,
      endpoint_id: 0_u16,
      cluster_id: Matter::Cluster::OperationalCredentials::CLUSTER_ID,
      attribute_id: Matter::Cluster::OperationalCredentials::ATTR_NOCS,
      fabric_filtered: false)
    original_nocs_data = original_nocs_report.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any)
    original_noc = Array(Matter::Cluster::OperationalCredentials::Tlv::NOC)
      .from_tlv(original_nocs_data.to_slice).find(&.fabric_index.==(descriptor.fabric_index))
      .as(Matter::Cluster::OperationalCredentials::Tlv::NOC)
    original_noc.icac.should eq(joiner_bootstrap.fabric.intermediate_cert)
    original_noc.vvsc.should be_nil

    trust = Matter::Controller::VidVerification::DclOperationalTrustAnchors.new(
      Matter::Controller::VidVerification::HttpDclSource.new("https://tests"))
    {"removed", "wrong-root", "wrong-vid", "wrong-signer", "stale"}.each do |mode|
      dcl_fixture.write_mode(mode)
      expect_raises(Matter::AuthenticationError, /trusted signer/) do
        Matter::Controller::VidVerification.verify(joiner_im, joiner_session, joiner_peer,
          descriptor.fabric_index, trust)
      end
    end
    dcl_fixture.write_mode("active")
    Matter::Controller::VidVerification.verify(joiner_im, joiner_session, joiner_peer,
      descriptor.fabric_index, trust)
    revocation_source = Matter::Controller::HttpDclRevocationSource.new("https://tests")
    issuer_skid = Bytes.new(20, 1_u8)
    revocation_source.points_for(issuer_skid).should be_empty
    dcl_fixture.write_mode("stale")
    expect_raises(Matter::AuthenticationError, /cache/) { revocation_source.points_for(issuer_skid) }
    dcl_fixture.write_mode("active")
    # Leave a direct JCM between AddICAC and CommissioningComplete, then
    # restart its controller Workflow while the joiner's fail-safe is armed.
    # A short device limit keeps the real expiry bounded for Docker CI.
    recovery_max = 120_u16
    recovery_expiry = 60_u16
    configured = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("set-test-fail-safe-max", 0_u64,
        fail_safe_max_seconds: recovery_max))
    configured.status.should eq("ok")
    exchange_path = File.join(E2E::LOG_DIR, "matter_joint_fabric_anchor.jcm-rpc.yml")
    anchor_exchange = ->(fabric : Matter::Controller::FabricInfo, joining_node_id : UInt64, peer : Socket::IPAddress, endpoint : UInt16, icac_public_key : Bytes, icac_id : UInt64) do
      unless fabric.fabric_id == anchor_bootstrap.fabric.fabric_id
        raise Matter::ConfigurationError.new("Anchor exchange selected the wrong fabric")
      end
      File.delete?(exchange_path)
      rpc = Matter::Storage::YamlFile.new(exchange_path)
      rpc.open
      begin
        request = MatterJointFabricAdministrator::Device::AnchorExchangeRequest.new(
          fabric.fabric_id, fabric.root_public_key, joining_node_id,
          peer, endpoint, icac_public_key, icac_id)
        rpc.write(MatterJointFabricAdministrator::Device::JCM_RPC_COLLECTION,
          MatterJointFabricAdministrator::Device::JCM_RPC_REQUEST, request.to_document)
      ensure
        rpc.close if rpc.open?
      end

      deadline = Time.instant + 45.seconds
      loop do
        result_store = Matter::Storage::YamlFile.new(exchange_path)
        result_store.open
        result = begin
          document = result_store.read(MatterJointFabricAdministrator::Device::JCM_RPC_COLLECTION,
            MatterJointFabricAdministrator::Device::JCM_RPC_RESULT)
          document.try { |value| MatterJointFabricAdministrator::Device::AnchorExchangeResult.from_document(value) }
        ensure
          result_store.close if result_store.open?
        end
        if result
          if result.status == "ok"
            break result.certificate || raise Matter::CommissioningError.new("Anchor exchange returned no ICAC")
          elsif result.status == "error"
            raise Matter::CommissioningError.new("Anchor exchange failed: #{result.error}")
          end
        end
        raise Matter::TimeoutError.new("Anchor exchange timed out") if Time.instant >= deadline
        sleep 100.milliseconds
      end
    end
    interrupted_client = Matter::Controller::Client.new(
      unsecured_source_node_id: anchor_bootstrap.fabric.controller_node_id)
    interrupted = Matter::Controller::JointCommissioning::Workflow.new(
      anchor_store, anchor_bootstrap.fabric.fabric_id,
      anchor_bootstrap.fabric.root_public_key, anchor_bootstrap.fabric.controller_node_id,
      1_u8, 1_u16, "Joining Administrator", 1_u16, 1_u16, 3_u64, trust,
      ->(_im : Matter::Controller::ImClient, _session : Matter::Session::SecureContext, _peer : Socket::IPAddress, _joiner : Matter::Controller::JointCommissioning::VerifiedJoiner) { true },
      ->(_joiner : Matter::Controller::JointCommissioning::VerifiedJoiner) { true },
      ->(_request : Matter::Cluster::JointFabricDatastore::AddAdminRequest) { nil },
      anchor_exchange, client: interrupted_client,
      datastore_registrar: JcmInterruptedRegistrar.new(anchor_store, JcmInterruptedDelivery.new),
      attestation_verifier: Matter::Controller::DeviceAttestationVerifier.new(
        Matter::Controller::AttestationTrustStore.matter_test_fixture),
      fail_safe_expiry_seconds: recovery_expiry)
    expect_raises(Matter::TransportError, /Injected interruption after AddICAC/) do
      interrupted.commission(0xA103_u64,
        Matter::SetupPayload.generate_manual_code(discriminator, passcode), joiner_peer)
    end
    pending = interrupted.hooks.pending.as(Matter::Controller::JointCommissioning::PendingRegistration)
    pending.icac.empty?.should be_false
    pending.fail_safe_max_seconds.should eq(recovery_max)
    pending.original_fabric_id.should eq(joiner_bootstrap.fabric.fabric_id)
    pending.original_node_id.should eq(0xB102_u64)
    deadline_unix = pending.fail_safe_deadline_unix.as(Int64)
    deadline_unix.should be > Time.utc.to_unix
    interrupted.close

    recovered_client = Matter::Controller::Client.new(
      unsecured_source_node_id: anchor_bootstrap.fabric.controller_node_id)
    recovered = Matter::Controller::JointCommissioning::Workflow.new(
      anchor_store, anchor_bootstrap.fabric.fabric_id,
      anchor_bootstrap.fabric.root_public_key, anchor_bootstrap.fabric.controller_node_id,
      1_u8, 1_u16, "Joining Administrator", 1_u16, 1_u16, 3_u64, trust,
      ->(_im : Matter::Controller::ImClient, _session : Matter::Session::SecureContext, _peer : Socket::IPAddress, _joiner : Matter::Controller::JointCommissioning::VerifiedJoiner) { true },
      ->(_joiner : Matter::Controller::JointCommissioning::VerifiedJoiner) { true },
      ->(_request : Matter::Cluster::JointFabricDatastore::AddAdminRequest) { nil },
      anchor_exchange, client: recovered_client,
      attestation_verifier: Matter::Controller::DeviceAttestationVerifier.new(
        Matter::Controller::AttestationTrustStore.matter_test_fixture))
    recovered.hooks.pending.as(Matter::Controller::JointCommissioning::PendingRegistration)
      .to_document.should eq(pending.to_document)
    joiner_session = Matter::Controller::Pairing::CasePairing.new.pair(joiner_client, joiner_peer,
      joiner_bootstrap.fabric, peer_node_id: 0xB102_u64, timeout: E2E::COMMAND_TIMEOUT)
    provisional_report = joiner_im.read_attribute(session: joiner_session, peer: joiner_peer,
      endpoint_id: 0_u16, cluster_id: Matter::Cluster::OperationalCredentials::CLUSTER_ID,
      attribute_id: Matter::Cluster::OperationalCredentials::ATTR_FABRICS,
      fabric_filtered: false)
    provisional_data = provisional_report.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any)
    Array(Matter::Cluster::OperationalCredentials::Tlv::FabricDescriptor)
      .from_tlv(provisional_data.to_slice)
      .any? do |entry|
        entry.fabric_id == anchor_bootstrap.fabric.fabric_id &&
          entry.root_public_key == anchor_bootstrap.fabric.root_public_key
      end.should be_true
    recovered.resume_pending.should be_false
    expect_raises(Matter::CommissioningError, /deadline has not passed/) do
      recovered.recover_abandoned_pending(joiner_bootstrap.fabric, 0xB102_u64, joiner_peer,
        Matter::Controller::JointCommissioning::NetworkRecoveryPort.new(joiner_client))
    end
    expect_raises(Matter::CommissioningError, /still pending/) do
      recovered.commission(0xA103_u64, "invalid manual code", joiner_peer)
    end
    while Time.utc.to_unix <= deadline_unix
      sleep 1.second
    end
    recovered.recover_abandoned_pending(joiner_bootstrap.fabric, 0xB102_u64, joiner_peer,
      Matter::Controller::JointCommissioning::NetworkRecoveryPort.new(joiner_client)).should be_true
    recovered.hooks.pending.should be_nil
    expect_raises(ArgumentError, /11 digits/) do
      recovered.commission(0xA103_u64, "invalid manual code", joiner_peer)
    end
    recovered.close

    # Interrupt the deferred path after AddNOC and durable handoff recording,
    # before the Anchor can finalize it. The real joiner must roll back the
    # provisional fabric before the restarted controller clears both records.
    deferred_max = Matter::Commissioning::WindowService::MINIMUM_COMMISSIONING_TIMEOUT
    configured_deferred = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("set-test-fail-safe-max", 0_u64,
        fail_safe_max_seconds: deferred_max))
    configured_deferred.status.should eq("ok")
    joiner_session = Matter::Controller::Pairing::CasePairing.new.pair(joiner_client, joiner_peer,
      joiner_bootstrap.fabric, peer_node_id: 0xB102_u64, timeout: E2E::COMMAND_TIMEOUT)
    recovery_open_request = Matter::Cluster::JointFabricAdministrator::OpenJointCommissioningWindowRequest.new(
      deferred_max, verifier, discriminator, iterations.to_u32, salt)
    # The rolled-back A fabric no longer owns JFA endpoint 1. Reopen through
    # the surviving B bootstrap Administrator on endpoint 2.
    recovery_window = joiner_im.invoke(session: joiner_session, peer: joiner_peer,
      endpoint_id: 2_u16,
      cluster_id: Matter::Cluster::JointFabricAdministrator::CLUSTER_ID,
      command_id: Matter::Cluster::JointFabricAdministrator::CMD_OPEN_JOINT_COMMISSIONING_WINDOW,
      fields: recovery_open_request.to_slice)
    Matter::Controller::JointCommissioning.assert_status_success(recovery_window)
    deferred_client = Matter::Controller::Client.new(
      unsecured_source_node_id: anchor_bootstrap.fabric.controller_node_id)
    # Endpoint 1 belonged to the rolled-back A fabric; B's live JFA is on 2.
    deferred = Matter::Controller::JointCommissioning::Workflow.new(
      anchor_store, anchor_bootstrap.fabric.fabric_id,
      anchor_bootstrap.fabric.root_public_key, anchor_bootstrap.fabric.controller_node_id,
      1_u8, 2_u16, "Joining Administrator", 1_u16, 1_u16, 3_u64, trust,
      ->(_im : Matter::Controller::ImClient, _session : Matter::Session::SecureContext, _peer : Socket::IPAddress, _joiner : Matter::Controller::JointCommissioning::VerifiedJoiner) { true },
      ->(_joiner : Matter::Controller::JointCommissioning::VerifiedJoiner) { true },
      ->(_request : Matter::Cluster::JointFabricDatastore::AddAdminRequest) { nil },
      anchor_exchange, client: deferred_client,
      anchor_finalize: ->(_fabric : Matter::Controller::FabricInfo, _node : UInt64, _peer : Socket::IPAddress, _endpoint : UInt16, _key : Bytes, _icac_id : UInt64, _nonce : String) do
        raise Matter::TransportError.new("Injected interruption before deferred Anchor finalization")
      end,
      attestation_verifier: Matter::Controller::DeviceAttestationVerifier.new(
        Matter::Controller::AttestationTrustStore.matter_test_fixture),
      fail_safe_expiry_seconds: recovery_expiry)
    expect_raises(Matter::TransportError, /Injected interruption before deferred Anchor finalization/) do
      deferred.commission(0xA103_u64,
        Matter::SetupPayload.generate_manual_code(discriminator, passcode), joiner_peer,
        defer_completion: true)
    end
    deferred_pending = deferred.hooks.pending.as(Matter::Controller::JointCommissioning::PendingRegistration)
    deferred_pending.handoff_nonce.should_not be_nil
    deferred_pending.completion_acknowledged?.should be_false
    deferred_pending.icac.should be_empty
    deferred_pending.fail_safe_max_seconds.should eq(deferred_max)
    deferred_deadline_unix = deferred_pending.fail_safe_deadline_unix.as(Int64)
    deferred_deadline_unix.should be > Time.utc.to_unix
    saved_handoff = anchor_store.load.pending_handoffs.find { |entry| entry.node_id == 0xA103_u64 }
    saved_handoff.should_not be_nil
    saved_handoff.as(Matter::Controller::PendingCommissioningHandoff).nonce.should eq(deferred_pending.handoff_nonce)
    saved_handoff.as(Matter::Controller::PendingCommissioningHandoff).expires_at_unix.should be < deferred_deadline_unix
    deferred.close

    joiner_session = Matter::Controller::Pairing::CasePairing.new.pair(joiner_client, joiner_peer,
      joiner_bootstrap.fabric, peer_node_id: 0xB102_u64, timeout: E2E::COMMAND_TIMEOUT)
    deferred_fabrics = joiner_im.read_attribute(session: joiner_session, peer: joiner_peer,
      endpoint_id: 0_u16, cluster_id: Matter::Cluster::OperationalCredentials::CLUSTER_ID,
      attribute_id: Matter::Cluster::OperationalCredentials::ATTR_FABRICS,
      fabric_filtered: false)
    deferred_data = deferred_fabrics.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any)
    Array(Matter::Cluster::OperationalCredentials::Tlv::FabricDescriptor)
      .from_tlv(deferred_data.to_slice)
      .any? do |entry|
        entry.fabric_id == anchor_bootstrap.fabric.fabric_id &&
          entry.root_public_key == anchor_bootstrap.fabric.root_public_key
      end.should be_true

    deferred_restarted = Matter::Controller::JointCommissioning::Workflow.new(
      anchor_store, anchor_bootstrap.fabric.fabric_id,
      anchor_bootstrap.fabric.root_public_key, anchor_bootstrap.fabric.controller_node_id,
      1_u8, 2_u16, "Joining Administrator", 1_u16, 1_u16, 3_u64, trust,
      ->(_im : Matter::Controller::ImClient, _session : Matter::Session::SecureContext, _peer : Socket::IPAddress, _joiner : Matter::Controller::JointCommissioning::VerifiedJoiner) { true },
      ->(_joiner : Matter::Controller::JointCommissioning::VerifiedJoiner) { true },
      ->(_request : Matter::Cluster::JointFabricDatastore::AddAdminRequest) { nil },
      anchor_exchange,
      attestation_verifier: Matter::Controller::DeviceAttestationVerifier.new(
        Matter::Controller::AttestationTrustStore.matter_test_fixture))
    deferred_restarted.hooks.pending.as(Matter::Controller::JointCommissioning::PendingRegistration)
      .to_document.should eq(deferred_pending.to_document)
    expect_raises(Matter::CommissioningError, /deadline has not passed/) do
      deferred_restarted.recover_abandoned_pending(joiner_bootstrap.fabric, 0xB102_u64, joiner_peer,
        Matter::Controller::JointCommissioning::NetworkRecoveryPort.new(joiner_client))
    end
    while Time.utc.to_unix <= deferred_deadline_unix
      sleep 1.second
    end
    deferred_restarted.recover_abandoned_pending(joiner_bootstrap.fabric, 0xB102_u64, joiner_peer,
      Matter::Controller::JointCommissioning::NetworkRecoveryPort.new(joiner_client)).should be_true
    deferred_restarted.hooks.pending.should be_nil
    anchor_store.load.pending_handoffs.any? { |entry| entry.node_id == 0xA103_u64 }.should be_false
    expect_raises(ArgumentError, /11 digits/) do
      deferred_restarted.commission(0xA103_u64, "invalid manual code", joiner_peer)
    end
    deferred_restarted.close

    reset_max = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("set-test-fail-safe-max", 0_u64,
        fail_safe_max_seconds: Matter::Commissioning::FailsafeService::DEFAULT_MAX_CUMULATIVE_SECONDS))
    reset_max.status.should eq("ok")
    joiner_session = Matter::Controller::Pairing::CasePairing.new.pair(joiner_client, joiner_peer,
      joiner_bootstrap.fabric, peer_node_id: 0xB102_u64, timeout: E2E::COMMAND_TIMEOUT)
    reopened_window = joiner_im.invoke(session: joiner_session, peer: joiner_peer,
      endpoint_id: 2_u16,
      cluster_id: Matter::Cluster::JointFabricAdministrator::CLUSTER_ID,
      command_id: Matter::Cluster::JointFabricAdministrator::CMD_OPEN_JOINT_COMMISSIONING_WINDOW,
      fields: open_request.to_slice)
    Matter::Controller::JointCommissioning.assert_status_success(reopened_window)

    registrar = Matter::Controller::JointCommissioning::RemoteDatastoreRegistrar.new(
      anchor_store, anchor_client, anchor_bootstrap.fabric.fabric_id,
      anchor_bootstrap.fabric.root_public_key, anchor_bootstrap.fabric.controller_node_id,
      0xA102_u64, 1_u16)
    anchor_finalize = ->(fabric : Matter::Controller::FabricInfo, joining_node_id : UInt64, peer : Socket::IPAddress, endpoint : UInt16, icac_public_key : Bytes, _icac_id : UInt64, nonce : String) do
      unless fabric.fabric_id == anchor_bootstrap.fabric.fabric_id && peer == joiner_peer
        raise Matter::ConfigurationError.new("Anchor handoff selected the wrong fabric or joiner")
      end
      result = jfa_command("matter_joint_fabric_anchor",
        MatterJointFabricAdministrator::Device::CommandRequest.new("finalize-commissioning", joining_node_id,
          fabric_id: fabric.fabric_id, root_public_key: fabric.root_public_key,
          nonce: nonce, jcm: true, trusted_icac_public_key_b: icac_public_key,
          peer_admin_jfa_endpoint_id: endpoint))
      unless result.status == "ok" && result.nonce == nonce
        raise Matter::CommissioningError.new("Anchor handoff failed: #{result.error}")
      end
      result.certificate || raise Matter::CommissioningError.new("Anchor handoff returned no ICAC")
    end
    handoff_result = ->(nonce : String) do
      path = File.join(E2E::LOG_DIR, "matter_joint_fabric_anchor.command.yml")
      backend = Matter::Storage::YamlFile.new(path)
      backend.open
      result = begin
        document = backend.read(MatterJointFabricAdministrator::Device::COMMAND_RPC_COLLECTION, "result")
        document.try { |value| MatterJointFabricAdministrator::Device::CommandResult.from_document(value) }
      ensure
        backend.close if backend.open?
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
      1_u8, 2_u16, "Joining Administrator", 1_u16, 1_u16, 3_u64, trust,
      ->(_im : Matter::Controller::ImClient, _session : Matter::Session::SecureContext, _peer : Socket::IPAddress, _joiner : Matter::Controller::JointCommissioning::VerifiedJoiner) { true },
      ->(_joiner : Matter::Controller::JointCommissioning::VerifiedJoiner) { true },
      registrar.callback,
      anchor_exchange,
      client: anchor_client, anchor_finalize: anchor_finalize,
      handoff_result: handoff_result,
      attestation_verifier: Matter::Controller::DeviceAttestationVerifier.new(
        Matter::Controller::AttestationTrustStore.matter_test_fixture))
    workflow.commission(0xA103_u64,
      Matter::SetupPayload.generate_manual_code(discriminator, passcode), joiner_peer,
      defer_completion: true)
    cross_signed_icac = workflow.stored_icac(0xA103_u64).as(Bytes)
    # The workflow's CASE exchange can supersede the earlier inspection session.
    joiner_session = Matter::Controller::Pairing::CasePairing.new.pair(joiner_client, joiner_peer,
      joiner_bootstrap.fabric, peer_node_id: 0xB102_u64, timeout: E2E::COMMAND_TIMEOUT)

    anchor_session = Matter::Controller::Pairing::CasePairing.new.pair(anchor_client, anchor_peer,
      anchor_bootstrap.fabric, peer_node_id: 0xA102_u64, timeout: E2E::COMMAND_TIMEOUT)
    anchor_im = Matter::Controller::ImClient.new(anchor_client, E2E::COMMAND_TIMEOUT)
    admins_report = anchor_im.read_attribute(session: anchor_session, peer: anchor_peer,
      endpoint_id: 1_u16,
      cluster_id: Matter::Cluster::JointFabricDatastore::CLUSTER_ID,
      attribute_id: Matter::Cluster::JointFabricDatastore::ATTR_ADMIN_LIST)
    admins_data = admins_report.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any)
    registered = Array(Matter::Cluster::JointFabricDatastore::DatastoreAdministratorInformationEntryStruct)
      .from_tlv(admins_data.to_slice).find(&.node_id.==(0xA103_u64)).as(Matter::Cluster::JointFabricDatastore::DatastoreAdministratorInformationEntryStruct)
    registered.icac.should eq(cross_signed_icac)

    third_icac = commission_third_administrator(anchor_store, anchor_client,
      anchor_bootstrap, third_client, third_bootstrap, third_peer)
    # The second JCM opens a fresh CASE connection from this controller and
    # supersedes the session used to inspect the first registration.
    anchor_session = Matter::Controller::Pairing::CasePairing.new.pair(anchor_client, anchor_peer,
      anchor_bootstrap.fabric, peer_node_id: 0xA102_u64, timeout: E2E::COMMAND_TIMEOUT)
    three_admins_report = anchor_im.read_attribute(session: anchor_session, peer: anchor_peer,
      endpoint_id: 1_u16, cluster_id: Matter::Cluster::JointFabricDatastore::CLUSTER_ID,
      attribute_id: Matter::Cluster::JointFabricDatastore::ATTR_ADMIN_LIST)
    three_admins_data = three_admins_report.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any)
    three_admins = Array(Matter::Cluster::JointFabricDatastore::DatastoreAdministratorInformationEntryStruct)
      .from_tlv(three_admins_data.to_slice)
    three_admins.map(&.node_id).sort!.should eq([0xA102_u64, 0xA103_u64, 0xA104_u64])
    three_admins.find(&.node_id.==(0xA104_u64)).as(Matter::Cluster::JointFabricDatastore::DatastoreAdministratorInformationEntryStruct)
      .icac.should eq(third_icac)
    third_joined_session = Matter::Controller::Pairing::CasePairing.new.pair(anchor_client, third_peer,
      anchor_bootstrap.fabric, peer_node_id: 0xA104_u64, timeout: E2E::COMMAND_TIMEOUT)
    third_acl_report = anchor_im.read_attribute(session: third_joined_session, peer: third_peer,
      endpoint_id: 0_u16, cluster_id: Matter::Cluster::AccessControl::CLUSTER_ID,
      attribute_id: Matter::Cluster::AccessControl::ATTR_ACL)
    third_acl_data = third_acl_report.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any)
    third_acl = Array(Matter::Cluster::AccessControl::AccessControlEntry).from_tlv(third_acl_data.to_slice)
    third_acl.any? { |entry| entry.subjects.try(&.includes?(0xFFFF_FFFD_FFFF_0001_u64)) || false }.should be_true

    # The live Anchor now has two other Administrators. An eviction that drops
    # its only IPK must wait for each trusted host to acknowledge the exact
    # current KeySet0. The B/C processes have joined using this original IPK;
    # this exercises the host guard, not adoption of a newly rotated epoch.
    rollout = JfaRolloutDatastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    rollout.anchor_node_id = 0xA102_u64
    rollout.anchor_root_ca = jfa_rollout_attribute(Bytes, anchor_im, anchor_session,
      anchor_peer, JfaRolloutDatastore::ATTR_ANCHOR_ROOT_CA)
    rollout.group_key_set_list = jfa_rollout_attribute(Array(JfaRolloutDatastore::DatastoreGroupKeySetStruct),
      anchor_im, anchor_session, anchor_peer, JfaRolloutDatastore::ATTR_GROUP_KEY_SET_LIST)
    rollout.node_list = jfa_rollout_attribute(Array(JfaRolloutDatastore::DatastoreNodeInformationEntryStruct),
      anchor_im, anchor_session, anchor_peer, JfaRolloutDatastore::ATTR_NODE_LIST)
    rollout.node_key_set_list = jfa_rollout_attribute(Array(JfaRolloutDatastore::DatastoreNodeKeySetEntryStruct),
      anchor_im, anchor_session, anchor_peer, JfaRolloutDatastore::ATTR_NODE_KEY_SET_LIST)
    rollout.admin_list = three_admins
    current_ipk = rollout.group_key_set_list.find!(&.group_key_set_id.==(0_u16))
    current_ipk.epoch_key0.should eq(anchor_bootstrap.fabric.ipk_value)
    b_joined_node_id = 0xA103_u64
    c_joined_node_id = 0xA104_u64
    evicted_ipk = JfaRolloutDatastore::DatastoreGroupKeySetStruct.new(0_u16,
      JfaRolloutDatastore::DatastoreGroupKeySecurityPolicyEnum::TrustFirst,
      Bytes.new(16, 0xA6_u8), 2_u64, nil, nil, nil, nil)
    expect_raises(Matter::ConfigurationError, Regex.new("Administrator #{b_joined_node_id} acknowledgment")) do
      JfaRollout.preflight_eviction!(rollout, anchor_bootstrap.fabric.fabric_id,
        anchor_bootstrap.fabric.root_cert, evicted_ipk, [] of JfaRollout::AdministratorAcknowledgment)
    end
    b_ack = JfaRollout.acknowledgment(b_joined_node_id, anchor_bootstrap.fabric.fabric_id,
      anchor_bootstrap.fabric.root_cert, current_ipk)
    expect_raises(Matter::ConfigurationError, Regex.new("Administrator #{c_joined_node_id} acknowledgment")) do
      JfaRollout.preflight_eviction!(rollout, anchor_bootstrap.fabric.fabric_id,
        anchor_bootstrap.fabric.root_cert, evicted_ipk, [b_ack])
    end
    stale_ipk = JfaRolloutDatastore::DatastoreGroupKeySetStruct.new(0_u16,
      JfaRolloutDatastore::DatastoreGroupKeySecurityPolicyEnum::TrustFirst,
      Bytes.new(16, 0xB7_u8), 1_u64, nil, nil, nil, nil)
    stale_c_ack = JfaRollout.acknowledgment(c_joined_node_id, anchor_bootstrap.fabric.fabric_id,
      anchor_bootstrap.fabric.root_cert, stale_ipk)
    expect_raises(Matter::ConfigurationError, Regex.new("Administrator #{c_joined_node_id} acknowledgment")) do
      JfaRollout.preflight_eviction!(rollout, anchor_bootstrap.fabric.fabric_id,
        anchor_bootstrap.fabric.root_cert, evicted_ipk, [b_ack, stale_c_ack])
    end
    c_ack = JfaRollout.acknowledgment(c_joined_node_id, anchor_bootstrap.fabric.fabric_id,
      anchor_bootstrap.fabric.root_cert, current_ipk)
    JfaRollout.preflight_eviction!(rollout, anchor_bootstrap.fabric.fabric_id,
      anchor_bootstrap.fabric.root_cert, evicted_ipk, [b_ack, c_ack])
    jfa_rollout_attribute(Array(JfaRolloutDatastore::DatastoreGroupKeySetStruct),
      anchor_im, anchor_session, anchor_peer, JfaRolloutDatastore::ATTR_GROUP_KEY_SET_LIST)
      .find!(&.group_key_set_id.==(0_u16)).should eq(current_ipk)

    joined_session = Matter::Controller::Pairing::CasePairing.new.pair(anchor_client, joiner_peer,
      anchor_bootstrap.fabric, peer_node_id: 0xA103_u64, timeout: E2E::COMMAND_TIMEOUT)
    index_report = anchor_im.read_attribute(session: joined_session, peer: joiner_peer,
      endpoint_id: 1_u16,
      cluster_id: Matter::Cluster::JointFabricAdministrator::CLUSTER_ID,
      attribute_id: Matter::Cluster::JointFabricAdministrator::ATTR_ADMINISTRATOR_FABRIC_INDEX)
    index_report.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any).as_u8.should eq(2_u8)

    # B remains an independently addressable Administrator on its own fabric.
    b_index_report = joiner_im.read_attribute(session: joiner_session, peer: joiner_peer,
      endpoint_id: 2_u16,
      cluster_id: Matter::Cluster::JointFabricAdministrator::CLUSTER_ID,
      attribute_id: Matter::Cluster::JointFabricAdministrator::ATTR_ADMINISTRATOR_FABRIC_INDEX)
    b_index_report.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any).as_u8.should eq(1_u8)
    b_csr_without_failsafe = joiner_im.invoke(session: joiner_session, peer: joiner_peer,
      endpoint_id: 2_u16,
      cluster_id: Matter::Cluster::JointFabricAdministrator::CLUSTER_ID,
      command_id: Matter::Cluster::JointFabricAdministrator::CMD_ICACCSR_REQUEST,
      fields: Bytes.empty)
    b_csr_without_failsafe.invoke_responses.first.command_status.as(Matter::InteractionModel::CommandStatusIB)
      .status.status.should eq(Matter::InteractionModel::StatusCode::FailsafeRequired.value)

    # B's bootstrap Datastore remains on endpoint 2 after the JFA joins A.
    # Commission an ordinary B device, grant B's Administrator CAT, and move
    # it under A using B's locally held cross-signed ICAC signing key.
    migration_peer = Socket::IPAddress.new(migration_target.address, E2E::DEVICE_PORT)
    Matter::Controller::Commissioning::Commissioner.new(joiner_store, joiner_client,
      timeout: E2E::COMMAND_TIMEOUT,
      attestation_verifier: Matter::Controller::DeviceAttestationVerifier.new(
        Matter::Controller::AttestationTrustStore.matter_test_fixture)).pairing_code(
      0xB201_u64, migration_target.pairing_code, migration_peer,
      fabric_id: joiner_bootstrap.fabric.fabric_id,
      root_public_key: joiner_bootstrap.fabric.root_public_key,
      controller_node_id: joiner_bootstrap.fabric.controller_node_id)
    b_target_session = Matter::Controller::Pairing::CasePairing.new.pair(joiner_client,
      migration_peer, joiner_bootstrap.fabric,
      peer_node_id: 0xB201_u64, timeout: E2E::COMMAND_TIMEOUT)
    acl_report = joiner_im.read_attribute(session: b_target_session, peer: migration_peer,
      endpoint_id: 0_u16, cluster_id: Matter::Cluster::AccessControl::CLUSTER_ID,
      attribute_id: Matter::Cluster::AccessControl::ATTR_ACL)
    acl_data = acl_report.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any)
    acl = Array(Matter::Cluster::AccessControl::AccessControlEntry).from_tlv(acl_data.to_slice)
    b_admin_subject = Matter::DataType::NodeId.from_case_authenticated_tag(
      Matter::DataType::CaseAuthenticatedTag.create(0xFFFF_u16, 1_u16)).id
    acl << Matter::Cluster::AccessControl::AccessControlEntry.new(
      Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer,
      Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
      [b_admin_subject], nil)
    acl_write = joiner_im.write_attribute(session: b_target_session, peer: migration_peer,
      endpoint_id: 0_u16, cluster_id: Matter::Cluster::AccessControl::CLUSTER_ID,
      attribute_id: Matter::Cluster::AccessControl::ATTR_ACL, value: acl.to_tlv)
    acl_write.write_responses.first.status.status.should eq(Matter::InteractionModel::StatusCode::Success.value)

    b_datastore_session = Matter::Controller::Pairing::CasePairing.new.pair(joiner_client,
      joiner_peer, joiner_bootstrap.fabric,
      peer_node_id: 0xB102_u64, timeout: E2E::COMMAND_TIMEOUT)
    added_b = joiner_im.invoke(session: b_datastore_session, peer: joiner_peer,
      endpoint_id: 2_u16, cluster_id: Matter::Cluster::JointFabricDatastore::CLUSTER_ID,
      command_id: Matter::Cluster::JointFabricDatastore::CMD_ADD_PENDING_NODE,
      fields: Matter::Cluster::JointFabricDatastore::AddPendingNodeRequest.new(
        0xB201_u64, "B device").to_slice)
    Matter::Controller::JointCommissioning.assert_status_success(added_b)
    b_deadline = Time.instant + 90.seconds
    loop do
      report = joiner_im.read_attribute(session: b_datastore_session, peer: joiner_peer,
        endpoint_id: 2_u16, cluster_id: Matter::Cluster::JointFabricDatastore::CLUSTER_ID,
        attribute_id: Matter::Cluster::JointFabricDatastore::ATTR_NODE_LIST)
      data = report.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
        .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any)
      entries = Array(Matter::Cluster::JointFabricDatastore::DatastoreNodeInformationEntryStruct).from_tlv(data.to_slice)
      break if entries.any? { |entry| entry.node_id == 0xB201_u64 && entry.commissioning_status_entry.state.committed? }
      raise Matter::TimeoutError.new("B Datastore did not commit the original device") if Time.instant >= b_deadline
      sleep 500.milliseconds
    end
    # The target commits A's fabric, but B loses the result before recording
    # durable acknowledgement or a local node record. Recovery must observe
    # the full advertised fail-safe bound before trusting that fabric.
    interrupted_migration = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("migrate-device", 0xB201_u64,
        fabric_id: anchor_bootstrap.fabric.fabric_id,
        root_public_key: anchor_bootstrap.fabric.root_public_key,
        nonce: Random::Secure.hex(8), anchor_node_id: 0xA201_u64,
        peer_address: migration_target.address, peer_port: E2E::DEVICE_PORT,
        interrupt_after_migration_complete_before_ack: true))
    interrupted_migration.status.should eq("error")
    interrupted_migration.error.to_s.should contain("Injected interruption after device CommissioningComplete")

    provisional_a_session = Matter::Controller::Pairing::CasePairing.new.pair(anchor_client,
      migration_peer, anchor_bootstrap.fabric,
      peer_node_id: 0xA201_u64, timeout: E2E::COMMAND_TIMEOUT)
    provisional_fabrics_report = anchor_im.read_attribute(session: provisional_a_session,
      peer: migration_peer, endpoint_id: 0_u16,
      cluster_id: Matter::Cluster::OperationalCredentials::CLUSTER_ID,
      attribute_id: Matter::Cluster::OperationalCredentials::ATTR_FABRICS,
      fabric_filtered: false)
    provisional_fabrics_data = provisional_fabrics_report.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any)
    provisional_fabrics = Array(Matter::Cluster::OperationalCredentials::Tlv::FabricDescriptor).from_tlv(provisional_fabrics_data.to_slice)
    provisional_fabrics.any? { |fabric| fabric.fabric_id == anchor_bootstrap.fabric.fabric_id }.should be_true
    provisional_fabrics.any? { |fabric| fabric.fabric_id == joiner_bootstrap.fabric.fabric_id }.should be_true

    joiner.restart!
    b_datastore_session = Matter::Controller::Pairing::CasePairing.new.pair(joiner_client,
      joiner_peer, joiner_bootstrap.fabric,
      peer_node_id: 0xB102_u64, timeout: E2E::COMMAND_TIMEOUT)
    recovery_started = Time.instant
    migrated = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("migrate-device", 0xB201_u64,
        fabric_id: anchor_bootstrap.fabric.fabric_id,
        root_public_key: anchor_bootstrap.fabric.root_public_key,
        nonce: Random::Secure.hex(8), anchor_node_id: 0xA201_u64,
        peer_address: migration_target.address, peer_port: E2E::DEVICE_PORT))
    migrated.status.should eq("ok"), migrated.error.to_s
    (Time.instant - recovery_started).should be >= MIGRATION_RECOVERY_MIN_WAIT
    a_target_session = Matter::Controller::Pairing::CasePairing.new.pair(anchor_client,
      migration_peer, anchor_bootstrap.fabric,
      peer_node_id: 0xA201_u64, timeout: E2E::COMMAND_TIMEOUT)
    fabrics_report = anchor_im.read_attribute(session: a_target_session, peer: migration_peer,
      endpoint_id: 0_u16, cluster_id: Matter::Cluster::OperationalCredentials::CLUSTER_ID,
      attribute_id: Matter::Cluster::OperationalCredentials::ATTR_FABRICS,
      fabric_filtered: false)
    fabrics_data = fabrics_report.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any)
    target_fabrics = Array(Matter::Cluster::OperationalCredentials::Tlv::FabricDescriptor).from_tlv(fabrics_data.to_slice)
    target_fabrics.any? { |fabric| fabric.fabric_id == anchor_bootstrap.fabric.fabric_id }.should be_true
    target_fabrics.any? { |fabric| fabric.fabric_id == joiner_bootstrap.fabric.fabric_id }.should be_false
    a_nodes_report = anchor_im.read_attribute(session: anchor_session, peer: anchor_peer,
      endpoint_id: 1_u16, cluster_id: Matter::Cluster::JointFabricDatastore::CLUSTER_ID,
      attribute_id: Matter::Cluster::JointFabricDatastore::ATTR_NODE_LIST)
    a_nodes_data = a_nodes_report.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any)
    a_nodes = Array(Matter::Cluster::JointFabricDatastore::DatastoreNodeInformationEntryStruct).from_tlv(a_nodes_data.to_slice)
    a_nodes.any? { |entry| entry.node_id == 0xA201_u64 && entry.commissioning_status_entry.state.committed? }.should be_true
    b_nodes_report = joiner_im.read_attribute(session: b_datastore_session, peer: joiner_peer,
      endpoint_id: 2_u16, cluster_id: Matter::Cluster::JointFabricDatastore::CLUSTER_ID,
      attribute_id: Matter::Cluster::JointFabricDatastore::ATTR_NODE_LIST)
    b_nodes_data = b_nodes_report.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any)
    b_nodes = Array(Matter::Cluster::JointFabricDatastore::DatastoreNodeInformationEntryStruct).from_tlv(b_nodes_data.to_slice)
    b_nodes.any?(&.node_id.==(0xB201_u64)).should be_false

    # B retains its original ICAC key after JCM. A cross-signed that key, so
    # a B-issued controller can join A's fabric with its own group CAT while
    # the migrated device has only the single A fabric installed. The local
    # Administrator identity below satisfies the issuer's joining-identity
    # validation; the ICAC itself came from the live JCM exchange above.
    crypto = Matter::Crypto::StandardCrypto.new
    joined_key = crypto.create_key_pair
    joined_noc = anchor_bootstrap.issue_noc(0xA103_u64, joined_key.public_key,
      [0xFFFF_0001_u32], crypto)
    joined_identity = Matter::Controller::FabricInfo.new(
      anchor_bootstrap.fabric.fabric_id, 0xA103_u64,
      anchor_bootstrap.fabric.ipk_value, anchor_bootstrap.fabric.root_cert,
      anchor_bootstrap.fabric.root_public_key, joined_noc, joined_key.private_key,
      admin_vendor_id: joiner_bootstrap.fabric.admin_vendor_id,
      intermediate_cert: anchor_bootstrap.fabric.intermediate_cert)
    b_issuer = Matter::Controller::JointFabricDeviceMigration.cross_signed_issuer(
      joiner_bootstrap.fabric, joined_identity, cross_signed_icac,
      joiner_bootstrap.fabric.intermediate_private_key.as(Bytes))
    b_controller_node_id = 0xA105_u64
    b_group_cat = 0x1235_u16
    b_group_version = 2_u16
    b_controller = b_issuer.delegate_controller(joined_identity,
      b_controller_node_id, b_group_cat, b_group_version, crypto)
    Matter::Crypto::MatterCertificate::Validation.verify_chain(b_controller.controller_noc,
      cross_signed_icac, anchor_bootstrap.fabric.root_public_key,
      anchor_bootstrap.fabric.root_cert)
    b_controller.intermediate_cert.should eq(cross_signed_icac)
    b_controller.intermediate_cert.should_not eq(joined_identity.intermediate_cert)
    b_controller_store = Matter::Controller::StateStore.new(Matter::Storage::Memory.new)
    Matter::Controller::SharedFabric.install(b_controller_store, b_controller)
    b_controller_client = Matter::Controller::Client.new(unsecured_source_node_id: b_controller_node_id)
    b_controller_im = Matter::Controller::ImClient.new(b_controller_client, E2E::COMMAND_TIMEOUT)
    b_target_session = Matter::Controller::Pairing::CasePairing.new.pair(b_controller_client,
      migration_peer, b_controller, peer_node_id: 0xA201_u64, timeout: E2E::COMMAND_TIMEOUT)
    denied = b_controller_im.read_attribute(session: b_target_session, peer: migration_peer,
      endpoint_id: 1_u16, cluster_id: Matter::Cluster::OnOff::CLUSTER_ID,
      attribute_id: Matter::Cluster::OnOff::ATTR_ON_OFF)
    denied.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_status.as(Matter::InteractionModel::AttributeStatusIB)
      .status.status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAccess.value)

    Matter::Controller::SharedFabric.grant_joint_admin(anchor_im, anchor_session, anchor_peer,
      1_u16, 0xA201_u64, 1_u16, 11_u16, "B ecosystem controllers", b_controller)
    b_cat_subject = Matter::DataType::NodeId.from_case_authenticated_tag(
      Matter::DataType::CaseAuthenticatedTag.create(b_group_cat, b_group_version)).id
    wait_two_jfa_acl(anchor_im, anchor_session, anchor_peer,
      0xA201_u64, b_cat_subject, 120.seconds)
    turned_on = b_controller_im.invoke(session: b_target_session, peer: migration_peer,
      endpoint_id: 1_u16, cluster_id: Matter::Cluster::OnOff::CLUSTER_ID,
      command_id: Matter::Cluster::OnOff::CMD_ON, fields: Bytes.empty)
    Matter::Controller::JointCommissioning.assert_status_success(turned_on)
    on_report = anchor_im.read_attribute(session: a_target_session, peer: migration_peer,
      endpoint_id: 1_u16, cluster_id: Matter::Cluster::OnOff::CLUSTER_ID,
      attribute_id: Matter::Cluster::OnOff::ATTR_ON_OFF)
    on_data = on_report.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any)
    Bool.from_tlv(on_data.to_slice).should be_true

    migration_target.restart!
    b_target_session = Matter::Controller::Pairing::CasePairing.new.pair(b_controller_client,
      migration_peer, b_controller, peer_node_id: 0xA201_u64, timeout: E2E::COMMAND_TIMEOUT)
    persisted = b_controller_im.read_attribute(session: b_target_session, peer: migration_peer,
      endpoint_id: 1_u16, cluster_id: Matter::Cluster::OnOff::CLUSTER_ID,
      attribute_id: Matter::Cluster::OnOff::ATTR_ON_OFF)
    persisted_data = persisted.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any)
    Bool.from_tlv(persisted_data.to_slice).should be_true

    before_transfer = jfa_command("matter_joint_fabric_anchor",
      MatterJointFabricAdministrator::Device::CommandRequest.new("inspect-new-anchor", 0xA102_u64,
        nonce: Random::Secure.hex(8)))
    before_transfer.subscription_committed.should be_false

    copied_anchor_name = "Shared Fabric Anchor"
    named_source = jfa_command("matter_joint_fabric_anchor",
      MatterJointFabricAdministrator::Device::CommandRequest.new("set-test-datastore-friendly-name", 0xA102_u64,
        test_friendly_name: copied_anchor_name))
    named_source.status.should eq("ok"), named_source.error.to_s

    # A freezes its Datastore before B receives the TransferAnchorRequest
    # acknowledgement. Restart B with a persisted Requesting journal and
    # require it to recognize the frozen Datastore without sending the request
    # again. A second interruption later exercises participant follow-up.
    lost_request = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("transfer-anchor", 0xA102_u64,
        interrupt_after_transfer_request: true))
    lost_request.status.should eq("error")
    lost_request.error.to_s.should contain("Injected lost TransferAnchorRequest acknowledgement")
    anchor_frozen = anchor_im.read_attribute(session: anchor_session, peer: anchor_peer,
      endpoint_id: 1_u16, cluster_id: Matter::Cluster::JointFabricDatastore::CLUSTER_ID,
      attribute_id: Matter::Cluster::JointFabricDatastore::ATTR_STATUS)
    frozen_data = anchor_frozen.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any)
    Matter::Cluster::JointFabricDatastore::DatastoreStatusEntryStruct.from_slice(frozen_data.to_slice)
      .state.should eq(Matter::Cluster::JointFabricDatastore::DatastoreStateEnum::DeletePending)
    joiner.restart!
    unsafe_retry = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("transfer-anchor", 0xA102_u64))
    unsafe_retry.status.should eq("error")
    unsafe_retry.error.to_s.should contain("needs authenticated requester reconciliation")
    request_nonce = Random::Secure.hex(16)
    witness = jfa_command("matter_joint_fabric_anchor",
      MatterJointFabricAdministrator::Device::CommandRequest.new("inspect-transfer-requester", 0xA103_u64,
        nonce: request_nonce))
    witness.status.should eq("ok"), witness.error.to_s
    witness.inspected_transfer_requester_node_id.should eq(0xA103_u64)
    rejected_witness = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("reconcile-transfer-requested", 0xA104_u64,
        nonce: request_nonce))
    rejected_witness.status.should eq("error")
    accepted_witness = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("reconcile-transfer-requested", 0xA102_u64,
        nonce: request_nonce))
    accepted_witness.status.should eq("ok"), accepted_witness.error.to_s

    # B commits its copied Datastore, but crashes before saving Copied in the
    # transfer journal. Recovery must prove that exact copy before proceeding.
    interrupted_copy = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("transfer-anchor", 0xA102_u64,
        interrupt_before_transfer_copy_journal: true))
    interrupted_copy.status.should eq("error")
    interrupted_copy.error.to_s.should contain("Injected interruption after durable copy before Copied journal save")
    copied_stage = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("inspect-transfer-stage", 0xA102_u64))
    copied_stage.inspected_transfer_stage.should eq(Matter::Controller::AnchorTransfer::Stage::Copying.value)
    copied_identity = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("inspect-anchor-identity", 0xA102_u64,
        nonce: Random::Secure.hex(8)))
    copied_entries = copied_identity.inspected_datastore_admin_entries.as(Array(Bytes))
    copied_entries.map { |entry| Matter::Cluster::JointFabricDatastore::DatastoreAdministratorInformationEntryStruct.from_slice(entry).node_id }
      .sort!.should eq([0xA102_u64, 0xA104_u64, 0xB102_u64])
    joiner.restart!
    joiner_client.close
    joiner_client = Matter::Controller::Client.new(
      unsecured_source_node_id: joiner_bootstrap.fabric.controller_node_id)
    persisted_copy = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("inspect-transfer-stage", 0xA102_u64))
    persisted_copy.inspected_transfer_stage.should eq(Matter::Controller::AnchorTransfer::Stage::Copying.value)
    reloaded_identity = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("inspect-anchor-identity", 0xA102_u64,
        nonce: Random::Secure.hex(8)))
    reloaded_identity.inspected_datastore_admin_entries.should eq(copied_entries)
    unsafe_copy_retry = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("transfer-anchor", 0xA102_u64))
    unsafe_copy_retry.status.should eq("error")
    unsafe_copy_retry.error.to_s.should contain("needs reconciliation")
    reconciled_copy = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("reconcile-transfer-copied", 0xA102_u64))
    reconciled_copy.status.should eq("ok"), reconciled_copy.error.to_s
    recovered_copy_stage = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("inspect-transfer-stage", 0xA102_u64))
    recovered_copy_stage.inspected_transfer_stage.should eq(Matter::Controller::AnchorTransfer::Stage::Copied.value)

    # A commits its new-fabric AddNOC and CommissioningComplete, then B loses
    # the acknowledgement before saving A in its rotation journal. B must
    # prove the committed credential after restart instead of adding it again.
    a_old_noc_before_rotation = administrator_noc(anchor_client, anchor_peer,
      anchor_bootstrap.fabric, 0xA102_u64)
    b_noc_before_rotation = administrator_noc(joiner_client, joiner_peer,
      joiner_bootstrap.fabric, 0xB102_u64)
    c_old_noc_before_rotation = administrator_noc(anchor_client, third_peer,
      anchor_bootstrap.fabric, 0xA104_u64)
    interrupted_first_rotation = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("transfer-anchor", 0xA102_u64,
        interrupt_after_first_transfer_administrator_rotation: true))
    interrupted_first_rotation.status.should eq("error")
    interrupted_first_rotation.error.to_s.should contain("Injected interruption after durable first Administrator rotation")
    active_rotation = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("inspect-transfer-stage", 0xA102_u64))
    active_rotation.inspected_transfer_stage.should eq(Matter::Controller::AnchorTransfer::Stage::Rotating.value)
    active_rotation.inspected_active_rotation_node_id.should eq(0xA102_u64)
    a_new_noc_before_restart = administrator_noc(joiner_client, anchor_peer,
      joiner_bootstrap.fabric, 0xA102_u64)
    a_new_noc_before_restart.noc.should_not be_empty
    administrator_noc(anchor_client, anchor_peer, anchor_bootstrap.fabric, 0xA102_u64).noc
      .should eq(a_old_noc_before_rotation.noc)
    administrator_noc(joiner_client, joiner_peer, joiner_bootstrap.fabric, 0xB102_u64).noc
      .should eq(b_noc_before_rotation.noc)
    administrator_noc(anchor_client, third_peer, anchor_bootstrap.fabric, 0xA104_u64).noc
      .should eq(c_old_noc_before_rotation.noc)
    c_before_transfer_rotation = jfa_command("matter_joint_fabric_third",
      MatterJointFabricAdministrator::Device::CommandRequest.new("inspect-fabric", 0xA104_u64,
        joiner_bootstrap.fabric.fabric_id, joiner_bootstrap.fabric.root_public_key,
        Random::Secure.hex(8)))
    c_before_transfer_rotation.fabric_present.should be_false
    joiner.restart!
    joiner_client.close
    joiner_client = Matter::Controller::Client.new(
      unsecured_source_node_id: joiner_bootstrap.fabric.controller_node_id)
    persisted_active_rotation = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("inspect-transfer-stage", 0xA102_u64))
    persisted_active_rotation.inspected_transfer_stage.should eq(Matter::Controller::AnchorTransfer::Stage::Rotating.value)
    persisted_active_rotation.inspected_active_rotation_node_id.should eq(0xA102_u64)
    a_new_noc_after_restart = administrator_noc(joiner_client, anchor_peer,
      joiner_bootstrap.fabric, 0xA102_u64)
    a_new_noc_after_restart.noc.should eq(a_new_noc_before_restart.noc)
    unsafe_rotation_retry = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("transfer-anchor", 0xA102_u64))
    unsafe_rotation_retry.status.should eq("error")
    unsafe_rotation_retry.error.to_s.should contain("needs reconciliation")
    malformed_rotation_nonce = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("reconcile-transfer-rotated-administrator", 0xA102_u64,
        nonce: "invalid"))
    malformed_rotation_nonce.status.should eq("error")
    malformed_rotation_nonce.error.to_s.should contain("32-byte hexadecimal rotation nonce")
    wrong_rotation_target = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("reconcile-transfer-rotated-administrator", 0xA104_u64,
        nonce: Random::Secure.hex(32)))
    wrong_rotation_target.status.should eq("error")
    wrong_rotation_target.error.to_s.should contain("not awaiting the old Anchor rotation")
    reconciled_first_rotation = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("reconcile-transfer-rotated-administrator", 0xA102_u64,
        nonce: Random::Secure.hex(32)))
    reconciled_first_rotation.status.should eq("ok"), reconciled_first_rotation.error.to_s

    # A and C rotate onto B's root, then B loses the durable Rotated save
    # acknowledgement before promoting its own Anchor credentials.
    interrupted_rotation = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("transfer-anchor", 0xA102_u64,
        interrupt_after_transfer_rotation: true))
    interrupted_rotation.status.should eq("error")
    interrupted_rotation.error.to_s.should contain("Injected interruption after durable Administrator rotations")
    rotated_stage = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("inspect-transfer-stage", 0xA102_u64))
    rotated_stage.inspected_transfer_stage.should eq(Matter::Controller::AnchorTransfer::Stage::Rotated.value)
    a_new_noc_after_resume = administrator_noc(joiner_client, anchor_peer,
      joiner_bootstrap.fabric, 0xA102_u64)
    a_new_noc_after_resume.noc.should eq(a_new_noc_before_restart.noc)
    c_new_fabric_after_rotation = jfa_command("matter_joint_fabric_third",
      MatterJointFabricAdministrator::Device::CommandRequest.new("inspect-fabric", 0xA104_u64,
        joiner_bootstrap.fabric.fabric_id, joiner_bootstrap.fabric.root_public_key,
        Random::Secure.hex(8)))
    c_new_fabric_after_rotation.fabric_present.should be_true
    c_rotated_credentials = administrator_noc(joiner_client, third_peer,
      joiner_bootstrap.fabric, 0xA104_u64)
    joiner.restart!
    joiner_client.close
    joiner_client = Matter::Controller::Client.new(
      unsecured_source_node_id: joiner_bootstrap.fabric.controller_node_id)
    persisted_rotation = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("inspect-transfer-stage", 0xA102_u64))
    persisted_rotation.inspected_transfer_stage.should eq(Matter::Controller::AnchorTransfer::Stage::Rotated.value)
    c_reloaded_credentials = administrator_noc(joiner_client, third_peer,
      joiner_bootstrap.fabric, 0xA104_u64)
    c_reloaded_credentials.noc.should eq(c_rotated_credentials.noc)
    c_reloaded_credentials.icac.should eq(c_rotated_credentials.icac)

    # B completes its own NOC rotation and persists the promoted Datastore,
    # endpoint binding, and Anchor role, then loses the acknowledgement before
    # its Promoted journal save. Recovery must prove this outcome without
    # issuing UpdateNOC again.
    interrupted_promotion = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("transfer-anchor", 0xA102_u64,
        interrupt_after_transfer_promotion: true))
    interrupted_promotion.status.should eq("error")
    interrupted_promotion.error.to_s.should contain("Injected interruption after durable Anchor promotion")
    promoting_stage = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("inspect-transfer-stage", 0xA102_u64))
    promoting_stage.inspected_transfer_stage.should eq(Matter::Controller::AnchorTransfer::Stage::Promoting.value)
    promoted_noc_before_restart = administrator_noc(joiner_client, joiner_peer,
      joiner_bootstrap.fabric, 0xB102_u64)
    promoted_noc_before_restart.noc.should_not be_empty
    joiner.restart!
    joiner_client.close
    joiner_client = Matter::Controller::Client.new(
      unsecured_source_node_id: joiner_bootstrap.fabric.controller_node_id)
    persisted_promotion = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("inspect-transfer-stage", 0xA102_u64))
    persisted_promotion.inspected_transfer_stage.should eq(Matter::Controller::AnchorTransfer::Stage::Promoting.value)
    promoted_identity = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("inspect-anchor-identity", 0xA102_u64,
        nonce: Random::Secure.hex(8)))
    promoted_identity.inspected_fabric_id.should eq(joiner_bootstrap.fabric.fabric_id)
    promoted_identity.inspected_root_public_key.should eq(joiner_bootstrap.fabric.root_public_key)
    promoted_identity.inspected_datastore_admin_entries.should eq(copied_entries)
    anchor_session = Matter::Controller::Pairing::CasePairing.new.pair(anchor_client, anchor_peer,
      anchor_bootstrap.fabric, peer_node_id: 0xA102_u64, timeout: E2E::COMMAND_TIMEOUT)
    frozen_old = anchor_im.read_attribute(session: anchor_session, peer: anchor_peer,
      endpoint_id: MatterJointFabricAdministrator::Device::ANCHOR_JFA_ENDPOINT_ID,
      cluster_id: Matter::Cluster::JointFabricDatastore::CLUSTER_ID,
      attribute_id: Matter::Cluster::JointFabricDatastore::ATTR_STATUS)
    frozen_old_data = frozen_old.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any)
    Matter::Cluster::JointFabricDatastore::DatastoreStatusEntryStruct.from_slice(frozen_old_data.to_slice)
      .state.should eq(Matter::Cluster::JointFabricDatastore::DatastoreStateEnum::DeletePending)
    promoted_noc_after_restart = administrator_noc(joiner_client, joiner_peer,
      joiner_bootstrap.fabric, 0xB102_u64)
    promoted_noc_after_restart.noc.should eq(promoted_noc_before_restart.noc)
    promoted_noc_after_restart.icac.should eq(promoted_noc_before_restart.icac)
    unsafe_promotion_retry = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("transfer-anchor", 0xA102_u64))
    unsafe_promotion_retry.status.should eq("error")
    unsafe_promotion_retry.error.to_s.should contain("needs reconciliation")
    reconciled_promotion = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("reconcile-transfer-promoted", 0xA102_u64))
    reconciled_promotion.status.should eq("ok"), reconciled_promotion.error.to_s
    promoted_stage = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("inspect-transfer-stage", 0xA102_u64))
    promoted_stage.inspected_transfer_stage.should eq(Matter::Controller::AnchorTransfer::Stage::Promoted.value)

    # A executes TransferAnchorComplete, then B loses the response. Restart B
    # with its persisted Completing journal while A and C still use A's fabric.
    interrupted_transfer = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("transfer-anchor", 0xA102_u64,
        interrupt_after_transfer_complete: true))
    interrupted_transfer.status.should eq("error")
    interrupted_transfer.error.to_s.should contain("Injected lost TransferAnchorComplete acknowledgement")
    inactive_old_store = anchor_im.read_attribute(session: anchor_session, peer: anchor_peer,
      endpoint_id: 1_u16, cluster_id: Matter::Cluster::JointFabricDatastore::CLUSTER_ID,
      attribute_id: Matter::Cluster::JointFabricDatastore::ATTR_STATUS)
    inactive_old_store.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_status.as(Matter::InteractionModel::AttributeStatusIB)
      .status.status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAccess.value)
    third_before_follow_up = jfa_command("matter_joint_fabric_third",
      MatterJointFabricAdministrator::Device::CommandRequest.new("inspect-fabric", 0xA104_u64,
        anchor_bootstrap.fabric.fabric_id, anchor_bootstrap.fabric.root_public_key,
        Random::Secure.hex(8)))
    third_before_follow_up.fabric_present.should be_true
    # The promoted JFA must serve B immediately, before a restart rebuilds its
    # service. Opening a JCM window through B CASE must identify B as its owner.
    live_promoted_session = Matter::Controller::Pairing::CasePairing.new.pair(joiner_client,
      joiner_peer, joiner_bootstrap.fabric, peer_node_id: 0xB102_u64, timeout: E2E::COMMAND_TIMEOUT)
    live_promoted_im = Matter::Controller::ImClient.new(joiner_client, E2E::COMMAND_TIMEOUT)
    live_window = live_promoted_im.invoke(session: live_promoted_session, peer: joiner_peer,
      endpoint_id: 1_u16, cluster_id: Matter::Cluster::JointFabricAdministrator::CLUSTER_ID,
      command_id: Matter::Cluster::JointFabricAdministrator::CMD_OPEN_JOINT_COMMISSIONING_WINDOW,
      fields: open_request.to_slice)
    Matter::Controller::JointCommissioning.assert_status_success(live_window)
    live_window_owner = live_promoted_im.read_attribute(session: live_promoted_session, peer: joiner_peer,
      endpoint_id: 0_u16, cluster_id: Matter::Cluster::AdministratorCommissioning::CLUSTER_ID,
      attribute_id: Matter::Cluster::AdministratorCommissioning::ATTR_ADMIN_FABRIC_INDEX)
    live_window_owner_report = live_window_owner.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB)).first
    live_window_owner_data = live_window_owner_report.attribute_data ||
                             raise "Promoted Anchor window owner read failed with IM status #{live_window_owner_report.attribute_status.try(&.status.status)}"
    live_window_owner_data.data.as(TLV::Any).as_u8.should eq(1_u8)
    joiner.restart!
    unsafe_complete_retry = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("transfer-anchor", 0xA102_u64))
    unsafe_complete_retry.status.should eq("error")
    unsafe_complete_retry.error.to_s.should contain("needs authenticated completion reconciliation")
    completion_nonce = Random::Secure.hex(16)
    completion_witness = jfa_command("matter_joint_fabric_anchor",
      MatterJointFabricAdministrator::Device::CommandRequest.new("inspect-transfer-completion", 0xA103_u64,
        nonce: completion_nonce))
    completion_witness.status.should eq("ok"), completion_witness.error.to_s
    completion_witness.inspected_transfer_requester_node_id.should eq(0xA103_u64)
    rejected_completion = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("reconcile-transfer-complete", 0xA104_u64,
        nonce: completion_nonce))
    rejected_completion.status.should eq("error")
    accepted_completion = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("reconcile-transfer-complete", 0xA102_u64,
        nonce: completion_nonce))
    accepted_completion.status.should eq("ok"), accepted_completion.error.to_s
    transferred_stage = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("inspect-transfer-stage", 0xA102_u64))
    transferred_stage.inspected_transfer_stage.should eq(Matter::Controller::AnchorTransfer::Stage::Transferred.value)
    interrupted_follow_up = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("transfer-anchor", 0xA102_u64,
        interrupt_before_transfer_follow_up: true))
    interrupted_follow_up.status.should eq("error")
    interrupted_follow_up.error.to_s.should contain("Injected interruption before Anchor transfer follow-up")
    following_up_stage = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("inspect-transfer-stage", 0xA102_u64))
    following_up_stage.inspected_transfer_stage.should eq(Matter::Controller::AnchorTransfer::Stage::FollowingUp.value)
    joiner.restart!
    joiner_client.close
    joiner_client = Matter::Controller::Client.new(
      unsecured_source_node_id: joiner_bootstrap.fabric.controller_node_id)
    assert_joiner_vvs(joiner_client, joiner_peer, joiner_bootstrap.fabric,
      signed_statement, joiner_bootstrap.fabric.intermediate_cert.as(Bytes))
    promoted_session = Matter::Controller::Pairing::CasePairing.new.pair(joiner_client, joiner_peer,
      joiner_bootstrap.fabric, peer_node_id: 0xB102_u64, timeout: E2E::COMMAND_TIMEOUT)
    promoted_im = Matter::Controller::ImClient.new(joiner_client, E2E::COMMAND_TIMEOUT)
    promoted_groups_before_resume = promoted_im.read_attribute(session: promoted_session, peer: joiner_peer,
      endpoint_id: 1_u16, cluster_id: Matter::Cluster::JointFabricDatastore::CLUSTER_ID,
      attribute_id: Matter::Cluster::JointFabricDatastore::ATTR_GROUP_LIST)
    promoted_groups_before_resume_report = promoted_groups_before_resume.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB)).first
    promoted_groups_before_resume_data = promoted_groups_before_resume_report.attribute_data ||
                                         raise "Promoted Anchor GroupList read failed with IM status #{promoted_groups_before_resume_report.attribute_status.try(&.status.status)}"
    transfer_admin_cat_version = Array(Matter::Cluster::JointFabricDatastore::DatastoreGroupInformationEntryStruct)
      .from_tlv(promoted_groups_before_resume_data.data.as(TLV::Any).to_slice).find!(&.group_cat.==(0xFFFF_u16))
      .group_cat_version
    noc_before_resume = promoted_im.read_attribute(session: promoted_session, peer: joiner_peer,
      endpoint_id: 0_u16, cluster_id: Matter::Cluster::OperationalCredentials::CLUSTER_ID,
      attribute_id: Matter::Cluster::OperationalCredentials::ATTR_NOCS)
    noc_before_resume_data = noc_before_resume.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any)
    transfer_anchor_noc = Array(Matter::Cluster::OperationalCredentials::Tlv::NOC)
      .from_tlv(noc_before_resume_data.to_slice).first.noc
    # A finishes follow-up, then B crashes before it reaches C. The journal
    # must skip A after restart and finish C without rotating B again.
    interrupted_participants = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("transfer-anchor", 0xA102_u64,
        interrupt_after_first_transfer_follow_up: true))
    interrupted_participants.status.should eq("error")
    interrupted_participants.error.to_s.should contain("Injected interruption after first Anchor participant follow-up")
    a_follow_up = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("inspect-follow-up-stage", 0xA102_u64))
    a_follow_up.inspected_follow_up_stage.should eq(Matter::Controller::AnchorTransfer::AdministratorFollowUp::Stage::Completed.value)
    c_follow_up = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("inspect-follow-up-stage", 0xA104_u64))
    c_follow_up.inspected_follow_up_stage.should be_nil
    first_done = jfa_command("matter_joint_fabric_anchor",
      MatterJointFabricAdministrator::Device::CommandRequest.new("inspect-fabric", 0xA102_u64,
        anchor_bootstrap.fabric.fabric_id, anchor_bootstrap.fabric.root_public_key,
        Random::Secure.hex(8)))
    first_done.fabric_present.should be_false
    first_new_fabric = jfa_command("matter_joint_fabric_anchor",
      MatterJointFabricAdministrator::Device::CommandRequest.new("inspect-fabric", 0xA102_u64,
        joiner_bootstrap.fabric.fabric_id, joiner_bootstrap.fabric.root_public_key,
        Random::Secure.hex(8)))
    first_new_fabric.fabric_present.should be_true
    third_pending = jfa_command("matter_joint_fabric_third",
      MatterJointFabricAdministrator::Device::CommandRequest.new("inspect-fabric", 0xA104_u64,
        anchor_bootstrap.fabric.fabric_id, anchor_bootstrap.fabric.root_public_key,
        Random::Secure.hex(8)))
    third_pending.fabric_present.should be_true
    joiner.restart!
    joiner_client.close
    joiner_client = Matter::Controller::Client.new(
      unsecured_source_node_id: joiner_bootstrap.fabric.controller_node_id)
    persisted_first_follow_up = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("inspect-follow-up-stage", 0xA102_u64))
    persisted_first_follow_up.inspected_follow_up_stage.should eq(
      Matter::Controller::AnchorTransfer::AdministratorFollowUp::Stage::Completed.value)
    # C commits B's cross-signed ICAC, but B stops after durably recording
    # CrossSigned and before asking C to remove A's fabric.
    interrupted_cross_signed = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("transfer-anchor", 0xA102_u64,
        interrupt_after_next_transfer_cross_sign: true))
    interrupted_cross_signed.status.should eq("error")
    interrupted_cross_signed.error.to_s.should contain("Injected interruption after durable Anchor participant cross-sign")
    cross_signed_stage = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("inspect-follow-up-stage", 0xA104_u64))
    cross_signed_stage.inspected_follow_up_stage.should eq(
      Matter::Controller::AnchorTransfer::AdministratorFollowUp::Stage::CrossSigned.value)
    c_old_before_restart = jfa_command("matter_joint_fabric_third",
      MatterJointFabricAdministrator::Device::CommandRequest.new("inspect-fabric", 0xA104_u64,
        anchor_bootstrap.fabric.fabric_id, anchor_bootstrap.fabric.root_public_key,
        Random::Secure.hex(8)))
    c_old_before_restart.fabric_present.should be_true
    c_new_before_restart = jfa_command("matter_joint_fabric_third",
      MatterJointFabricAdministrator::Device::CommandRequest.new("inspect-fabric", 0xA104_u64,
        joiner_bootstrap.fabric.fabric_id, joiner_bootstrap.fabric.root_public_key,
        Random::Secure.hex(8)))
    c_new_before_restart.fabric_present.should be_true
    c_new_session = Matter::Controller::Pairing::CasePairing.new.pair(joiner_client, third_peer,
      joiner_bootstrap.fabric, peer_node_id: 0xA104_u64, timeout: E2E::COMMAND_TIMEOUT)
    c_new_im = Matter::Controller::ImClient.new(joiner_client, E2E::COMMAND_TIMEOUT)
    c_nocs_before_restart = c_new_im.read_attribute(session: c_new_session, peer: third_peer,
      endpoint_id: 0_u16, cluster_id: Matter::Cluster::OperationalCredentials::CLUSTER_ID,
      attribute_id: Matter::Cluster::OperationalCredentials::ATTR_NOCS)
    c_nocs_before_restart_data = c_nocs_before_restart.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any)
    c_new_credentials_before_restart = Array(Matter::Cluster::OperationalCredentials::Tlv::NOC)
      .from_tlv(c_nocs_before_restart_data.to_slice).first
    c_new_credentials_before_restart.noc.should eq(c_rotated_credentials.noc)
    c_new_credentials_before_restart.icac.should eq(c_rotated_credentials.icac)
    c_new_credentials_before_restart.icac.should_not be_nil
    c_cross_signed_before_restart = jfa_command("matter_joint_fabric_third",
      MatterJointFabricAdministrator::Device::CommandRequest.new("inspect-anchor-identity", 0xA104_u64,
        nonce: Random::Secure.hex(8))).inspected_cross_signed_icac.as(Bytes)
    b_admin_c_icac_before_restart = candidate_admin_icac(joiner_client, joiner_peer,
      joiner_bootstrap.fabric, 0xB102_u64, 0xA104_u64)
    b_admin_c_icac_before_restart.should eq(c_cross_signed_before_restart)
    joiner.restart!
    joiner_client.close
    joiner_client = Matter::Controller::Client.new(
      unsecured_source_node_id: joiner_bootstrap.fabric.controller_node_id)
    persisted_cross_signed = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("inspect-follow-up-stage", 0xA104_u64))
    persisted_cross_signed.inspected_follow_up_stage.should eq(
      Matter::Controller::AnchorTransfer::AdministratorFollowUp::Stage::CrossSigned.value)
    b_admin_c_icac_after_restart = candidate_admin_icac(joiner_client, joiner_peer,
      joiner_bootstrap.fabric, 0xB102_u64, 0xA104_u64)
    b_admin_c_icac_after_restart.should eq(c_cross_signed_before_restart)
    c_old_after_restart = jfa_command("matter_joint_fabric_third",
      MatterJointFabricAdministrator::Device::CommandRequest.new("inspect-fabric", 0xA104_u64,
        anchor_bootstrap.fabric.fabric_id, anchor_bootstrap.fabric.root_public_key,
        Random::Secure.hex(8)))
    c_old_after_restart.fabric_present.should be_true
    c_new_after_restart = jfa_command("matter_joint_fabric_third",
      MatterJointFabricAdministrator::Device::CommandRequest.new("inspect-fabric", 0xA104_u64,
        joiner_bootstrap.fabric.fabric_id, joiner_bootstrap.fabric.root_public_key,
        Random::Secure.hex(8)))
    c_new_after_restart.fabric_present.should be_true
    c_cross_signed_after_restart = jfa_command("matter_joint_fabric_third",
      MatterJointFabricAdministrator::Device::CommandRequest.new("inspect-anchor-identity", 0xA104_u64,
        nonce: Random::Secure.hex(8))).inspected_cross_signed_icac.as(Bytes)
    c_cross_signed_after_restart.should eq(c_cross_signed_before_restart)
    # The resumed command must remove only C's old fabric, not replay either
    # participant cross-sign, rotate B's credentials, or recopy the Datastore.
    transferred = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("transfer-anchor", 0xA102_u64))
    transferred.status.should eq("ok"), transferred.error.to_s
    completed_third_follow_up = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("inspect-follow-up-stage", 0xA104_u64))
    completed_third_follow_up.inspected_follow_up_stage.should eq(
      Matter::Controller::AnchorTransfer::AdministratorFollowUp::Stage::Completed.value)
    completed_stage = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("inspect-transfer-stage", 0xA102_u64))
    completed_stage.inspected_transfer_stage.should eq(Matter::Controller::AnchorTransfer::Stage::Completed.value)
    promoted_noc_after_transfer = administrator_noc(joiner_client, joiner_peer,
      joiner_bootstrap.fabric, 0xB102_u64)
    promoted_noc_after_transfer.noc.should eq(promoted_noc_before_restart.noc)
    promoted_noc_after_transfer.icac.should eq(promoted_noc_before_restart.icac)
    c_resumed_session = Matter::Controller::Pairing::CasePairing.new.pair(joiner_client, third_peer,
      joiner_bootstrap.fabric, peer_node_id: 0xA104_u64, timeout: E2E::COMMAND_TIMEOUT)
    c_resumed_im = Matter::Controller::ImClient.new(joiner_client, E2E::COMMAND_TIMEOUT)
    c_nocs_after_resume = c_resumed_im.read_attribute(session: c_resumed_session, peer: third_peer,
      endpoint_id: 0_u16, cluster_id: Matter::Cluster::OperationalCredentials::CLUSTER_ID,
      attribute_id: Matter::Cluster::OperationalCredentials::ATTR_NOCS)
    c_nocs_after_resume_data = c_nocs_after_resume.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any)
    c_new_credentials_after_resume = Array(Matter::Cluster::OperationalCredentials::Tlv::NOC)
      .from_tlv(c_nocs_after_resume_data.to_slice).first
    c_new_credentials_after_resume.noc.should eq(c_new_credentials_before_restart.noc)
    c_new_credentials_after_resume.icac.should eq(c_new_credentials_before_restart.icac)
    assert_joiner_vvs(joiner_client, joiner_peer, joiner_bootstrap.fabric,
      signed_statement, joiner_bootstrap.fabric.intermediate_cert.as(Bytes))
    watch_deadline = Time.instant + 90.seconds
    loop do
      observed = jfa_command("matter_joint_fabric_anchor",
        MatterJointFabricAdministrator::Device::CommandRequest.new("inspect-new-anchor", 0xA102_u64,
          nonce: Random::Secure.hex(8)))
      observed.status.should eq("ok"), observed.error.to_s
      break if observed.subscription_committed == true
      raise Matter::TimeoutError.new("Old Anchor did not subscribe to the new Anchor Datastore") if Time.instant >= watch_deadline
      sleep 1.second
    end
    promoted_session = Matter::Controller::Pairing::CasePairing.new.pair(joiner_client, joiner_peer,
      joiner_bootstrap.fabric, peer_node_id: 0xB102_u64, timeout: E2E::COMMAND_TIMEOUT)
    promoted_im = Matter::Controller::ImClient.new(joiner_client, E2E::COMMAND_TIMEOUT)
    noc_after_resume = promoted_im.read_attribute(session: promoted_session, peer: joiner_peer,
      endpoint_id: 0_u16, cluster_id: Matter::Cluster::OperationalCredentials::CLUSTER_ID,
      attribute_id: Matter::Cluster::OperationalCredentials::ATTR_NOCS)
    noc_after_resume_data = noc_after_resume.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any)
    Array(Matter::Cluster::OperationalCredentials::Tlv::NOC)
      .from_tlv(noc_after_resume_data.to_slice).first.noc.should eq(transfer_anchor_noc)
    promoted_name = promoted_im.read_attribute(session: promoted_session, peer: joiner_peer,
      endpoint_id: MatterJointFabricAdministrator::Device::ANCHOR_JFA_ENDPOINT_ID,
      cluster_id: Matter::Cluster::JointFabricDatastore::CLUSTER_ID,
      attribute_id: Matter::Cluster::JointFabricDatastore::ATTR_FRIENDLY_NAME)
    promoted_name_data = promoted_name.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any)
    String.from_tlv(promoted_name_data.to_slice).should eq(copied_anchor_name)
    promoted_admins = promoted_im.read_attribute(session: promoted_session, peer: joiner_peer,
      endpoint_id: 1_u16, cluster_id: Matter::Cluster::JointFabricDatastore::CLUSTER_ID,
      attribute_id: Matter::Cluster::JointFabricDatastore::ATTR_ADMIN_LIST)
    promoted_data = promoted_admins.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any)
    promoted_entries = Array(Matter::Cluster::JointFabricDatastore::DatastoreAdministratorInformationEntryStruct)
      .from_tlv(promoted_data.to_slice)
    b_admin_c_icac_after_resume = promoted_entries.find!(&.node_id.==(0xA104_u64)).icac
    c_cross_signed_after_resume = jfa_command("matter_joint_fabric_third",
      MatterJointFabricAdministrator::Device::CommandRequest.new("inspect-anchor-identity", 0xA104_u64,
        nonce: Random::Secure.hex(8))).inspected_cross_signed_icac.as(Bytes)
    c_cross_signed_after_resume.should eq(c_cross_signed_before_restart)
    b_admin_c_icac_after_resume.should eq(c_cross_signed_before_restart)
    promoted_ids = promoted_entries.map(&.node_id)
    promoted_ids.should contain(0xB102_u64)
    promoted_ids.should contain(0xA102_u64)
    promoted_ids.should contain(0xA104_u64)
    promoted_ids.should_not contain(0xA103_u64)
    anchor_id_report = promoted_im.read_attribute(session: promoted_session, peer: joiner_peer,
      endpoint_id: 1_u16, cluster_id: Matter::Cluster::JointFabricDatastore::CLUSTER_ID,
      attribute_id: Matter::Cluster::JointFabricDatastore::ATTR_ANCHOR_NODE_ID)
    anchor_id_report.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any).as_u64.should eq(0xB102_u64)
    old_fabric = jfa_command("matter_joint_fabric_anchor",
      MatterJointFabricAdministrator::Device::CommandRequest.new("inspect-fabric", 0xA102_u64,
        anchor_bootstrap.fabric.fabric_id, anchor_bootstrap.fabric.root_public_key,
        Random::Secure.hex(8)))
    old_fabric.status.should eq("ok"), old_fabric.error.to_s
    old_fabric.fabric_present.should be_false
    new_fabric = jfa_command("matter_joint_fabric_anchor",
      MatterJointFabricAdministrator::Device::CommandRequest.new("inspect-fabric", 0xA102_u64,
        joiner_bootstrap.fabric.fabric_id, joiner_bootstrap.fabric.root_public_key,
        Random::Secure.hex(8)))
    new_fabric.fabric_present.should be_true
    third_old_fabric = jfa_command("matter_joint_fabric_third",
      MatterJointFabricAdministrator::Device::CommandRequest.new("inspect-fabric", 0xA104_u64,
        anchor_bootstrap.fabric.fabric_id, anchor_bootstrap.fabric.root_public_key,
        Random::Secure.hex(8)))
    third_old_fabric.fabric_present.should be_false
    third_new_fabric = jfa_command("matter_joint_fabric_third",
      MatterJointFabricAdministrator::Device::CommandRequest.new("inspect-fabric", 0xA104_u64,
        joiner_bootstrap.fabric.fabric_id, joiner_bootstrap.fabric.root_public_key,
        Random::Secure.hex(8)))
    third_new_fabric.fabric_present.should be_true

    before_removal_groups = promoted_im.read_attribute(session: promoted_session, peer: joiner_peer,
      endpoint_id: 1_u16, cluster_id: Matter::Cluster::JointFabricDatastore::CLUSTER_ID,
      attribute_id: Matter::Cluster::JointFabricDatastore::ATTR_GROUP_LIST)
    before_removal_group_data = before_removal_groups.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any)
    before_removal_group = Array(Matter::Cluster::JointFabricDatastore::DatastoreGroupInformationEntryStruct)
      .from_tlv(before_removal_group_data.to_slice).find!(&.group_cat.==(0xFFFF_u16))
    before_removal_cat_version = before_removal_group.group_cat_version ||
                                 raise Matter::ProtocolError.new("Administrator group CAT version is absent")
    before_removal_cat_version.should eq(transfer_admin_cat_version)

    # C's user has not consented. B rejects the request before creating a
    # removal journal or sending any removal command; C stays on the fabric.
    denied_removal = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("remove-administrator", 0xA104_u64))
    denied_removal.status.should eq("error")
    denied_removal.error.to_s.should contain("Outgoing Administrator user consent is not recorded")
    after_denial_admins = promoted_im.read_attribute(session: promoted_session, peer: joiner_peer,
      endpoint_id: 1_u16, cluster_id: Matter::Cluster::JointFabricDatastore::CLUSTER_ID,
      attribute_id: Matter::Cluster::JointFabricDatastore::ATTR_ADMIN_LIST)
    after_denial_data = after_denial_admins.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any)
    after_denial_ids = Array(Matter::Cluster::JointFabricDatastore::DatastoreAdministratorInformationEntryStruct)
      .from_tlv(after_denial_data.to_slice).map(&.node_id)
    after_denial_ids.sort!.should eq(promoted_ids.sort!)
    still_joined = jfa_command("matter_joint_fabric_third",
      MatterJointFabricAdministrator::Device::CommandRequest.new("inspect-fabric", 0xA104_u64,
        joiner_bootstrap.fabric.fabric_id, joiner_bootstrap.fabric.root_public_key,
        Random::Secure.hex(8)))
    still_joined.fabric_present.should be_true
    before_removal_groups_again = promoted_im.read_attribute(session: promoted_session, peer: joiner_peer,
      endpoint_id: 1_u16, cluster_id: Matter::Cluster::JointFabricDatastore::CLUSTER_ID,
      attribute_id: Matter::Cluster::JointFabricDatastore::ATTR_GROUP_LIST)
    before_removal_groups_again_data = before_removal_groups_again.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any)
    Array(Matter::Cluster::JointFabricDatastore::DatastoreGroupInformationEntryStruct)
      .from_tlv(before_removal_groups_again_data.to_slice).find!(&.group_cat.==(0xFFFF_u16))
      .group_cat_version.should eq(before_removal_cat_version)

    # The former Anchor consents out of band; B removes its new-fabric NOC,
    # removes A from the Datastore, and increments the Administrator CAT.
    interrupted = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("remove-administrator", 0xA102_u64,
        interrupt_after_remove_fabric: true))
    interrupted.status.should eq("error")
    interrupted.error.to_s.should contain("Injected lost RemoveFabric acknowledgement")
    # Reload the candidate process from disk while its removal journal is in
    # the uncertain RemovingFabric stage. The next command must reconcile the
    # persisted journal rather than replay the remote RemoveFabric command.
    joiner.restart!
    joiner_client.close
    joiner_client = Matter::Controller::Client.new(
      unsecured_source_node_id: joiner_bootstrap.fabric.controller_node_id)
    uncertain_retry = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("remove-administrator", 0xA102_u64))
    uncertain_retry.status.should eq("error")
    uncertain_retry.error.to_s.should contain("needs reconciliation")
    proof_nonce = Random::Secure.hex(16)
    absent = jfa_command("matter_joint_fabric_anchor",
      MatterJointFabricAdministrator::Device::CommandRequest.new("inspect-fabric", 0xA102_u64,
        joiner_bootstrap.fabric.fabric_id, joiner_bootstrap.fabric.root_public_key,
        proof_nonce))
    absent.fabric_present.should be_false
    reconciled = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("reconcile-fabric-removed", 0xA102_u64,
        nonce: proof_nonce))
    reconciled.status.should eq("ok"), reconciled.error.to_s
    before_no_effect_im = Matter::Controller::ImClient.new(joiner_client, E2E::COMMAND_TIMEOUT)
    before_no_effect_session = Matter::Controller::Pairing::CasePairing.new.pair(joiner_client, joiner_peer,
      joiner_bootstrap.fabric, peer_node_id: 0xB102_u64, timeout: E2E::COMMAND_TIMEOUT)
    before_no_effect_report = before_no_effect_im.read_attribute(session: before_no_effect_session, peer: joiner_peer,
      endpoint_id: 1_u16, cluster_id: Matter::Cluster::JointFabricDatastore::CLUSTER_ID,
      attribute_id: Matter::Cluster::JointFabricDatastore::ATTR_ADMIN_LIST)
    before_no_effect_data = before_no_effect_report.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any)
    outgoing_admin = Array(Matter::Cluster::JointFabricDatastore::DatastoreAdministratorInformationEntryStruct)
      .from_tlv(before_no_effect_data.to_slice).find!(&.node_id.==(0xA102_u64))
    outgoing_admin.icac.empty?.should be_false
    # The next RemoveAdmin attempt is interrupted before the Datastore changes.
    no_effect = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("remove-administrator", 0xA102_u64,
        interrupt_before_remove_admin: true))
    no_effect.status.should eq("error")
    no_effect.error.to_s.should contain("Injected interruption before RemoveAdmin")
    joiner.restart!
    joiner_client.close
    joiner_client = Matter::Controller::Client.new(
      unsecured_source_node_id: joiner_bootstrap.fabric.controller_node_id)
    promoted_im = Matter::Controller::ImClient.new(joiner_client, E2E::COMMAND_TIMEOUT)
    no_effect_retry = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("remove-administrator", 0xA102_u64))
    no_effect_retry.status.should eq("error")
    no_effect_retry.error.to_s.should contain("needs reconciliation")
    promoted_session = Matter::Controller::Pairing::CasePairing.new.pair(joiner_client, joiner_peer,
      joiner_bootstrap.fabric, peer_node_id: 0xB102_u64, timeout: E2E::COMMAND_TIMEOUT)
    present_report = promoted_im.read_attribute(session: promoted_session, peer: joiner_peer,
      endpoint_id: 1_u16, cluster_id: Matter::Cluster::JointFabricDatastore::CLUSTER_ID,
      attribute_id: Matter::Cluster::JointFabricDatastore::ATTR_ADMIN_LIST)
    present_attribute = present_report.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB)
    present_version = present_attribute.data_version || raise Matter::ProtocolError.new("AdminList DataVersion is absent")
    present_admin = Array(Matter::Cluster::JointFabricDatastore::DatastoreAdministratorInformationEntryStruct)
      .from_tlv(present_attribute.data.as(TLV::Any).to_slice).find!(&.node_id.==(0xA102_u64))
    present_admin.icac.should eq(outgoing_admin.icac)
    # An unrelated committed change advances the cluster-wide DataVersion.
    # Reconciliation still compares the journaled Administrator entry itself.
    unrelated_group = promoted_im.invoke(session: promoted_session, peer: joiner_peer,
      endpoint_id: 1_u16, cluster_id: Matter::Cluster::JointFabricDatastore::CLUSTER_ID,
      command_id: Matter::Cluster::JointFabricDatastore::CMD_ADD_GROUP,
      fields: Matter::Cluster::JointFabricDatastore::AddGroupRequest.new(
        0x7A01_u16, "No-effect recovery probe", nil, nil, nil,
        Matter::Cluster::JointFabricDatastore::DatastoreAccessControlEntryPrivilegeEnum::View).to_slice)
    Matter::Controller::JointCommissioning.assert_status_success(unrelated_group)
    advanced_report = promoted_im.read_attribute(session: promoted_session, peer: joiner_peer,
      endpoint_id: 1_u16, cluster_id: Matter::Cluster::JointFabricDatastore::CLUSTER_ID,
      attribute_id: Matter::Cluster::JointFabricDatastore::ATTR_ADMIN_LIST)
    advanced_attribute = advanced_report.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB)
    advanced_attribute.data_version.should_not eq(present_version)
    advanced_admin = Array(Matter::Cluster::JointFabricDatastore::DatastoreAdministratorInformationEntryStruct)
      .from_tlv(advanced_attribute.data.as(TLV::Any).to_slice).find!(&.node_id.==(0xA102_u64))
    advanced_admin.icac.should eq(outgoing_admin.icac)
    unchanged_groups = promoted_im.read_attribute(session: promoted_session, peer: joiner_peer,
      endpoint_id: 1_u16, cluster_id: Matter::Cluster::JointFabricDatastore::CLUSTER_ID,
      attribute_id: Matter::Cluster::JointFabricDatastore::ATTR_GROUP_LIST)
    unchanged_data = unchanged_groups.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any)
    Array(Matter::Cluster::JointFabricDatastore::DatastoreGroupInformationEntryStruct)
      .from_tlv(unchanged_data.to_slice).find!(&.group_cat.==(0xFFFF_u16)).group_cat_version
      .should eq(before_removal_cat_version)
    incorrect_outcome = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("reconcile-datastore-removed", 0xA102_u64))
    incorrect_outcome.status.should eq("error")
    no_effect_reconciled = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("reconcile-datastore-no-effect", 0xA102_u64))
    no_effect_reconciled.status.should eq("ok"), no_effect_reconciled.error.to_s
    # RemoveAdmin commits to the new Anchor Datastore, but the simulated
    # acknowledgement is lost before the journal advances. Restart B at this
    # second uncertain boundary and prove the AdminList change survived.
    interrupted_datastore = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("remove-administrator", 0xA102_u64,
        interrupt_after_remove_admin: true))
    interrupted_datastore.status.should eq("error")
    interrupted_datastore.error.to_s.should contain("Injected lost RemoveAdmin acknowledgement")
    joiner.restart!
    joiner_client.close
    joiner_client = Matter::Controller::Client.new(
      unsecured_source_node_id: joiner_bootstrap.fabric.controller_node_id)
    promoted_im = Matter::Controller::ImClient.new(joiner_client, E2E::COMMAND_TIMEOUT)
    uncertain_datastore_retry = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("remove-administrator", 0xA102_u64))
    uncertain_datastore_retry.status.should eq("error")
    uncertain_datastore_retry.error.to_s.should contain("needs reconciliation")
    promoted_session = Matter::Controller::Pairing::CasePairing.new.pair(joiner_client, joiner_peer,
      joiner_bootstrap.fabric, peer_node_id: 0xB102_u64, timeout: E2E::COMMAND_TIMEOUT)
    persisted_admins = promoted_im.read_attribute(session: promoted_session, peer: joiner_peer,
      endpoint_id: 1_u16, cluster_id: Matter::Cluster::JointFabricDatastore::CLUSTER_ID,
      attribute_id: Matter::Cluster::JointFabricDatastore::ATTR_ADMIN_LIST)
    persisted_data = persisted_admins.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any)
    persisted_ids = Array(Matter::Cluster::JointFabricDatastore::DatastoreAdministratorInformationEntryStruct)
      .from_tlv(persisted_data.to_slice).map(&.node_id)
    persisted_ids.should_not contain(0xA102_u64)
    reconciled_datastore = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("reconcile-datastore-removed", 0xA102_u64))
    reconciled_datastore.status.should eq("ok"), reconciled_datastore.error.to_s
    interrupted_before_noc = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("remove-administrator", 0xA102_u64,
        interrupt_before_anchor_noc: true))
    interrupted_before_noc.status.should eq("error")
    interrupted_before_noc.error.to_s.should contain("Injected interruption before Anchor UpdateNOC")
    joiner.restart!
    joiner_client.close
    joiner_client = Matter::Controller::Client.new(
      unsecured_source_node_id: joiner_bootstrap.fabric.controller_node_id)
    no_effect_retry = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("remove-administrator", 0xA102_u64))
    no_effect_retry.status.should eq("error")
    no_effect_retry.error.to_s.should contain("needs reconciliation")
    no_effect_proof = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("reconcile-anchor-rotation-no-effect", 0xA102_u64,
        nonce: Random::Secure.hex(32)))
    no_effect_proof.status.should eq("ok"), no_effect_proof.error.to_s
    interrupted_anchor_rotation = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("remove-administrator", 0xA102_u64,
        interrupt_after_anchor_rotation: true))
    interrupted_anchor_rotation.status.should eq("error")
    interrupted_anchor_rotation.error.to_s.should contain("Injected lost Anchor rotation acknowledgement")
    joiner.restart!
    joiner_client.close
    joiner_client = Matter::Controller::Client.new(
      unsecured_source_node_id: joiner_bootstrap.fabric.controller_node_id)
    anchor_rotation_retry = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("remove-administrator", 0xA102_u64))
    anchor_rotation_retry.status.should eq("error")
    anchor_rotation_retry.error.to_s.should contain("needs reconciliation")
    anchor_rotation_nonce = Random::Secure.hex(32)
    reconciled_anchor_rotation = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("reconcile-anchor-rotated", 0xA102_u64,
        nonce: anchor_rotation_nonce))
    reconciled_anchor_rotation.status.should eq("ok"), reconciled_anchor_rotation.error.to_s

    interrupted_participant_rotation = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("remove-administrator", 0xA102_u64,
        interrupt_after_participant_rotation: true))
    interrupted_participant_rotation.status.should eq("error")
    interrupted_participant_rotation.error.to_s.should contain("Injected lost participant rotation acknowledgement")
    joiner.restart!
    joiner_client.close
    joiner_client = Matter::Controller::Client.new(
      unsecured_source_node_id: joiner_bootstrap.fabric.controller_node_id)
    promoted_im = Matter::Controller::ImClient.new(joiner_client, E2E::COMMAND_TIMEOUT)
    participant_rotation_retry = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("remove-administrator", 0xA102_u64))
    participant_rotation_retry.status.should eq("error")
    participant_rotation_retry.error.to_s.should contain("needs reconciliation")
    participant_rotation_nonce = Random::Secure.hex(32)
    reconciled_participant_rotation = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("reconcile-participant-rotated", 0xA102_u64,
        nonce: participant_rotation_nonce))
    reconciled_participant_rotation.status.should eq("ok"), reconciled_participant_rotation.error.to_s
    removed = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("remove-administrator", 0xA102_u64))
    removed.status.should eq("ok"), removed.error.to_s
    promoted_session = Matter::Controller::Pairing::CasePairing.new.pair(joiner_client, joiner_peer,
      joiner_bootstrap.fabric, peer_node_id: 0xB102_u64, timeout: E2E::COMMAND_TIMEOUT)
    final_admins = promoted_im.read_attribute(session: promoted_session, peer: joiner_peer,
      endpoint_id: 1_u16, cluster_id: Matter::Cluster::JointFabricDatastore::CLUSTER_ID,
      attribute_id: Matter::Cluster::JointFabricDatastore::ATTR_ADMIN_LIST)
    final_data = final_admins.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any)
    final_ids = Array(Matter::Cluster::JointFabricDatastore::DatastoreAdministratorInformationEntryStruct)
      .from_tlv(final_data.to_slice).map(&.node_id)
    final_ids.sort!.should eq([0xA104_u64, 0xB102_u64])
    final_groups = promoted_im.read_attribute(session: promoted_session, peer: joiner_peer,
      endpoint_id: 1_u16, cluster_id: Matter::Cluster::JointFabricDatastore::CLUSTER_ID,
      attribute_id: Matter::Cluster::JointFabricDatastore::ATTR_GROUP_LIST)
    final_group_data = final_groups.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any)
    administrator_group = Array(Matter::Cluster::JointFabricDatastore::DatastoreGroupInformationEntryStruct)
      .from_tlv(final_group_data.to_slice).find!(&.group_cat.==(0xFFFF_u16))
    administrator_group.group_cat_version.should eq(before_removal_cat_version + 1_u16)
    # Retrying after a completed journal is idempotent and cannot rotate CATs again.
    repeated = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("remove-administrator", 0xA102_u64))
    repeated.status.should eq("ok"), repeated.error.to_s
  ensure
    if previous_ssl_cert_file
      ENV["SSL_CERT_FILE"] = previous_ssl_cert_file
    else
      ENV.delete("SSL_CERT_FILE")
    end
    mirror.try(&.terminate)
    mirror.try(&.wait)
    mirror_log.try(&.close)
    b_controller_client.try(&.close)
    anchor_client.try(&.close)
    joiner_client.try(&.close)
    third_client.try(&.close)
    anchor_store.try(&.backend.close)
    joiner_store.try(&.backend.close)
    third_store.try(&.backend.close)
  end
end
