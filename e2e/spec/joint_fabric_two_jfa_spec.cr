require "./e2e_helper"
require "../../src/matter/controller"
require "../../examples/support/joint_fabric_administrator_device"

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

# Two separately bootstrapped Joint Fabric Administrators, each carrying its
# own Anchor ICAC and CATs. Their controller states and trust roots are written
# into the shared e2e volume before commissioning the device processes.
describe "two provisioned Joint Fabric Administrators" do
  anchor = E2E::Device["matter_joint_fabric_anchor"]
  joiner = E2E::Device["matter_joint_fabric_joiner"]

  it "joint-commissions a second Administrator into the Anchor fabric" do
    anchor_bootstrap = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      0xA100_u64, 0xA101_u64, 0xFFF1_u16)
    joiner_bootstrap = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      0xB100_u64, 0xB101_u64, 0xFFF1_u16)

    anchor_store = Matter::Controller::StateStore.new(Matter::Storage::YamlFile.new(
      File.join(E2E::LOG_DIR, "matter_joint_fabric_anchor.bootstrap.yml")))
    joiner_store = Matter::Controller::StateStore.new(Matter::Storage::YamlFile.new(
      File.join(E2E::LOG_DIR, "matter_joint_fabric_joiner.bootstrap.yml")))
    anchor_store.save(Matter::Controller::State.new(fabric: anchor_bootstrap.fabric,
      commissioner_node_id: anchor_bootstrap.fabric.controller_node_id))
    joiner_store.save(Matter::Controller::State.new(fabric: joiner_bootstrap.fabric,
      commissioner_node_id: joiner_bootstrap.fabric.controller_node_id))

    File.write(File.join(E2E::LOG_DIR, "matter_joint_fabric_anchor.trust-root.tlv"),
      joiner_bootstrap.fabric.root_cert)
    File.write(File.join(E2E::LOG_DIR, "matter_joint_fabric_joiner.trust-root.tlv"),
      anchor_bootstrap.fabric.root_cert)

    anchor_client = Matter::Controller::Client.new(
      unsecured_source_node_id: anchor_bootstrap.fabric.controller_node_id)
    joiner_client = Matter::Controller::Client.new(
      unsecured_source_node_id: joiner_bootstrap.fabric.controller_node_id)
    anchor_peer = Socket::IPAddress.new(anchor.address, E2E::DEVICE_PORT)
    joiner_peer = Socket::IPAddress.new(joiner.address, E2E::DEVICE_PORT)

    anchor_issuer = ->(fabric_id : UInt64, node_id : UInt64, key : Bytes) do
      raise Matter::ConfigurationError.new("Wrong Anchor fabric") unless fabric_id == anchor_bootstrap.fabric.fabric_id
      anchor_bootstrap.issue_anchor_administrator_noc(node_id, key)
    end
    joiner_issuer = ->(fabric_id : UInt64, node_id : UInt64, key : Bytes) do
      raise Matter::ConfigurationError.new("Wrong joining fabric") unless fabric_id == joiner_bootstrap.fabric.fabric_id
      joiner_bootstrap.issue_anchor_administrator_noc(node_id, key)
    end
    Matter::Controller::Commissioning::Commissioner.new(anchor_store, anchor_client,
      timeout: E2E::COMMAND_TIMEOUT, certificate_issuer: anchor_issuer).pairing_code(
      0xA102_u64, anchor.pairing_code, anchor_peer)
    Matter::Controller::Commissioning::Commissioner.new(joiner_store, joiner_client,
      timeout: E2E::COMMAND_TIMEOUT, certificate_issuer: joiner_issuer).pairing_code(
      0xB102_u64, joiner.pairing_code, joiner_peer)

    [{anchor_client, anchor_peer, anchor_bootstrap.fabric, 0xA102_u64},
     {joiner_client, joiner_peer, joiner_bootstrap.fabric, 0xB102_u64}].each do |client, peer, fabric, node_id|
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

    trust = Matter::Controller::VidVerification::StaticOperationalTrustAnchors.new(
      {joiner_bootstrap.fabric.admin_vendor_id => [joiner_bootstrap.fabric.root_cert]})
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
          peer.address, peer.port, endpoint, icac_public_key, icac_id)
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
      handoff_result: handoff_result)
    workflow.commission(0xA103_u64,
      Matter::SetupPayload.generate_manual_code(discriminator, passcode), joiner_peer,
      defer_completion: true)
    cross_signed_icac = workflow.stored_icac(0xA103_u64).as(Bytes)

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

    joined_session = Matter::Controller::Pairing::CasePairing.new.pair(anchor_client, joiner_peer,
      anchor_bootstrap.fabric, peer_node_id: 0xA103_u64, timeout: E2E::COMMAND_TIMEOUT)
    index_report = anchor_im.read_attribute(session: joined_session, peer: joiner_peer,
      endpoint_id: 1_u16,
      cluster_id: Matter::Cluster::JointFabricAdministrator::CLUSTER_ID,
      attribute_id: Matter::Cluster::JointFabricAdministrator::ATTR_ADMINISTRATOR_FABRIC_INDEX)
    index_report.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any).as_u8.should eq(2_u8)

    before_transfer = jfa_command("matter_joint_fabric_anchor",
      MatterJointFabricAdministrator::Device::CommandRequest.new("inspect-new-anchor", 0xA102_u64,
        nonce: Random::Secure.hex(8)))
    before_transfer.subscription_committed.should be_false

    # B becomes the new Anchor. The device runs the controller-side transfer
    # with its own reachable operational identity, and every JFA follows up
    # before the journal can reach Completed.
    transferred = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("transfer-anchor", 0xA102_u64))
    transferred.status.should eq("ok"), transferred.error.to_s
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
    promoted_admins = promoted_im.read_attribute(session: promoted_session, peer: joiner_peer,
      endpoint_id: 1_u16, cluster_id: Matter::Cluster::JointFabricDatastore::CLUSTER_ID,
      attribute_id: Matter::Cluster::JointFabricDatastore::ATTR_ADMIN_LIST)
    promoted_data = promoted_admins.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any)
    promoted_ids = Array(Matter::Cluster::JointFabricDatastore::DatastoreAdministratorInformationEntryStruct)
      .from_tlv(promoted_data.to_slice).map(&.node_id)
    promoted_ids.should contain(0xB102_u64)
    promoted_ids.should contain(0xA102_u64)
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

    # The former Anchor consents out of band; B removes its new-fabric NOC,
    # removes A from the Datastore, and increments the Administrator CAT.
    interrupted = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("remove-administrator", 0xA102_u64,
        interrupt_after_remove_fabric: true))
    interrupted.status.should eq("error")
    interrupted.error.to_s.should contain("Injected lost RemoveFabric acknowledgement")
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
    removed = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("remove-administrator", 0xA102_u64))
    removed.status.should eq("ok"), removed.error.to_s
    # Retrying after a completed journal is idempotent and cannot rotate CATs again.
    repeated = jfa_command("matter_joint_fabric_joiner",
      MatterJointFabricAdministrator::Device::CommandRequest.new("remove-administrator", 0xA102_u64))
    repeated.status.should eq("ok"), repeated.error.to_s
  ensure
    anchor_client.try(&.close)
    joiner_client.try(&.close)
    anchor_store.try(&.backend.close)
    joiner_store.try(&.backend.close)
  end
end
