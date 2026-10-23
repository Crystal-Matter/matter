require "./e2e_helper"
require "../../src/matter/controller"
require "../../examples/support/joint_fabric_administrator_device"
require "../interop/jfa_vvs_dcl_fixture"

# The joining Administrator's original fabric has an ICAC, so its VVS signer
# must be provisioned out of band rather than carried as a VVSC in NOCStruct.

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
    {"removed", "wrong-root", "wrong-vid", "wrong-signer"}.each do |mode|
      dcl_fixture.write_mode(mode)
      expect_raises(Matter::AuthenticationError, /trusted signer/) do
        Matter::Controller::VidVerification.verify(joiner_im, joiner_session, joiner_peer,
          descriptor.fabric_index, trust)
      end
    end
    dcl_fixture.write_mode("active")
    Matter::Controller::VidVerification.verify(joiner_im, joiner_session, joiner_peer,
      descriptor.fabric_index, trust)
    registrar = Matter::Controller::JointCommissioning::RemoteDatastoreRegistrar.new(
      anchor_store, anchor_client, anchor_bootstrap.fabric.fabric_id,
      anchor_bootstrap.fabric.root_public_key, anchor_bootstrap.fabric.controller_node_id,
      0xA102_u64, 1_u16)
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
      1_u8, 1_u16, "Joining Administrator", 1_u16, 1_u16, 3_u64, trust,
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
    migrated = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("migrate-device", 0xB201_u64,
        fabric_id: anchor_bootstrap.fabric.fabric_id,
        root_public_key: anchor_bootstrap.fabric.root_public_key,
        nonce: Random::Secure.hex(8), anchor_node_id: 0xA201_u64,
        peer_address: migration_target.address, peer_port: E2E::DEVICE_PORT))
    migrated.status.should eq("ok"), migrated.error.to_s
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

    # B becomes the new Anchor, but the command channel loses the result after
    # TransferAnchorComplete and before participant follow-up. Restart B with
    # its persisted FollowingUp journal while A and C still use A's fabric.
    interrupted_transfer = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("transfer-anchor", 0xA102_u64,
        interrupt_before_transfer_follow_up: true))
    interrupted_transfer.status.should eq("error")
    interrupted_transfer.error.to_s.should contain("Injected interruption before Anchor transfer follow-up")
    third_before_follow_up = jfa_command("matter_joint_fabric_third",
      MatterJointFabricAdministrator::Device::CommandRequest.new("inspect-fabric", 0xA104_u64,
        anchor_bootstrap.fabric.fabric_id, anchor_bootstrap.fabric.root_public_key,
        Random::Secure.hex(8)))
    third_before_follow_up.fabric_present.should be_true
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
    promoted_groups_before_resume_data = promoted_groups_before_resume.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any)
    transfer_admin_cat_version = Array(Matter::Cluster::JointFabricDatastore::DatastoreGroupInformationEntryStruct)
      .from_tlv(promoted_groups_before_resume_data.to_slice).find!(&.group_cat.==(0xFFFF_u16))
      .group_cat_version
    noc_before_resume = promoted_im.read_attribute(session: promoted_session, peer: joiner_peer,
      endpoint_id: 0_u16, cluster_id: Matter::Cluster::OperationalCredentials::CLUSTER_ID,
      attribute_id: Matter::Cluster::OperationalCredentials::ATTR_NOCS)
    noc_before_resume_data = noc_before_resume.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any)
    transfer_anchor_noc = Array(Matter::Cluster::OperationalCredentials::Tlv::NOC)
      .from_tlv(noc_before_resume_data.to_slice).first.noc
    # The resumed command must perform only pending follow-up, not rotate B's
    # credentials or recopy the frozen Datastore.
    transferred = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("transfer-anchor", 0xA102_u64))
    transferred.status.should eq("ok"), transferred.error.to_s
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
    promoted_admins = promoted_im.read_attribute(session: promoted_session, peer: joiner_peer,
      endpoint_id: 1_u16, cluster_id: Matter::Cluster::JointFabricDatastore::CLUSTER_ID,
      attribute_id: Matter::Cluster::JointFabricDatastore::ATTR_ADMIN_LIST)
    promoted_data = promoted_admins.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any)
    promoted_ids = Array(Matter::Cluster::JointFabricDatastore::DatastoreAdministratorInformationEntryStruct)
      .from_tlv(promoted_data.to_slice).map(&.node_id)
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
    removed = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("remove-administrator", 0xA102_u64,
        interrupt_after_remove_admin: true))
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
