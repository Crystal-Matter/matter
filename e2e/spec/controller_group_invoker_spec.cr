require "./e2e_helper"
require "../../src/matter/controller"

private alias GKM = Matter::Cluster::GroupKeyManagement
private alias IM = Matter::InteractionModel

private def group_e2e_invoke!(im : Matter::Controller::ImClient,
                              session : Matter::Session::SecureContext,
                              peer : Socket::IPAddress, endpoint : UInt16,
                              cluster : UInt32, command : UInt32, fields : Bytes) : Nil
  response = im.invoke(session: session, peer: peer, endpoint_id: endpoint,
    cluster_id: cluster, command_id: command, fields: fields)
  status = response.invoke_responses.first?.try(&.command_status).try(&.status.status)
  unless status == IM::StatusCode::Success.value || response.invoke_responses.any?(&.command_data)
    raise Matter::ProtocolError.new("Official recipient rejected command 0x#{command.to_s(16)}: #{status}")
  end
end

private def group_e2e_write!(im : Matter::Controller::ImClient,
                             session : Matter::Session::SecureContext,
                             peer : Socket::IPAddress, cluster : UInt32,
                             attribute : UInt32, value : Bytes) : Nil
  response = im.write_attribute(session: session, peer: peer, endpoint_id: 0_u16,
    cluster_id: cluster, attribute_id: attribute, value: value)
  unless response.write_responses.all? { |item| item.status.status == IM::StatusCode::Success.value }
    raise Matter::ProtocolError.new("Official recipient rejected attribute 0x#{attribute.to_s(16)}")
  end
end

describe "Crystal controller group Invoke to official connectedhomeip recipient" do
  it "turns an all-clusters-app OnOff server on over authenticated multicast" do
    peer_address = Socket::Addrinfo.udp("official-group-recipient", E2E::DEVICE_PORT,
      family: Socket::Family::INET6).first.ip_address.address
    peer = Socket::IPAddress.new(peer_address, E2E::DEVICE_PORT)
    state_path = File.join(E2E::LOG_DIR, "controller-group-invoker.yml")
    File.delete?(state_path)
    backend = Matter::Storage::YamlFile.new(state_path)
    store = Matter::Controller::StateStore.new(backend)
    state = store.load
    client = Matter::Controller::Client.new(
      unsecured_source_node_id: state.commissioner_node_id,
      initial_unsecured_message_counter: state.unsecured_message_counter)
    node_id = 0x7331_u64
    group_id = 0x7332_u16
    keyset_id = 0x7333_u16
    epoch_key = "a0a1a2a3a4a5a6a7a8a9aaabacadaeaf".hexbytes
    pairing_code = Matter::SetupPayload.generate_manual_code(3841_u16, 20202021_u32)
    sdk_paa = File.read("/credentials/development/paa-root-certs/Chip-Test-PAA-FFF1-Cert.der").to_slice
    cd_signers = {} of String => Bytes
    Dir.glob("/credentials/development/cd-certs/*.der").each do |path|
      cert = OpenSSL::X509::Certificate.from_der(File.read(path).to_slice)
      ski = LibCrypto.x509_get0_subject_key_id(cert)
      next if ski.null?
      ski_bytes = Slice.new(LibCrypto.asn1_string_get0_data(ski), 20).dup
      cd_signers[ski_bytes.hexstring.upcase] = cert.public_key.as(OpenSSL::PKey::EC).public_key_bytes
    end
    sdk_trust = Matter::Controller::AttestationTrustStore.new([sdk_paa], cd_signers,
      allow_test_attestation: true,
      revocation_check: ->(_dac : Bytes, _pai : Bytes, _paa : Bytes) {
        Matter::Controller::RevocationStatus::Good
      })
    Matter::Controller::Commissioning::Commissioner.new(store, client,
      timeout: E2E::COMMAND_TIMEOUT,
      attestation_verifier: Matter::Controller::DeviceAttestationVerifier.new(
        sdk_trust)).pairing_code(
      node_id, pairing_code, peer)

    fabric = store.load.fabric.as(Matter::Controller::FabricInfo)
    session = Matter::Controller::Pairing::CasePairing.new.pair(client, peer, fabric,
      peer_node_id: node_id, timeout: E2E::COMMAND_TIMEOUT)
    im = Matter::Controller::ImClient.new(client, E2E::COMMAND_TIMEOUT)
    keyset = GKM::GroupKeySetStruct.new(keyset_id, GKM::GroupKeySecurityPolicyEnum::TrustFirst,
      epoch_key, 1_110_000_u64)
    group_e2e_invoke!(im, session, peer, 0_u16, GKM::CLUSTER_ID, GKM::CMD_KEY_SET_WRITE,
      GKM::KeySetWriteRequest.new(keyset).to_slice)
    mapping = [GKM::GroupKeyMapStruct.new(group_id, keyset_id, 1_u8)]
    group_e2e_write!(im, session, peer, GKM::CLUSTER_ID, GKM::ATTR_GROUP_KEY_MAP,
      mapping.to_tlv)
    group_e2e_invoke!(im, session, peer, 1_u16, Matter::Cluster::Groups::CLUSTER_ID,
      Matter::Cluster::Groups::CMD_ADD_GROUP,
      Matter::Cluster::Groups::AddGroupRequest.new(Matter::DataType::GroupId.new(group_id), "Crystal sender").to_slice)
    acl = [
      Matter::Cluster::AccessControl::AccessControlEntry.new(
        Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer,
        Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
        [fabric.controller_node_id], nil),
      Matter::Cluster::AccessControl::AccessControlEntry.new(
        Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Operate,
        Matter::Cluster::AccessControl::AccessControlEntryAuthMode::Group,
        [group_id.to_u64], nil),
    ]
    group_e2e_write!(im, session, peer, Matter::Cluster::AccessControl::CLUSTER_ID,
      Matter::Cluster::AccessControl::ATTR_ACL, acl.to_tlv)
    group_e2e_invoke!(im, session, peer, 1_u16, Matter::Cluster::OnOff::CLUSTER_ID,
      Matter::Cluster::OnOff::CMD_OFF, Bytes.empty)

    invoker = Matter::Controller::GroupInvoker.new(client, store)
    invoker.install_epoch_key(fabric.fabric_id, fabric.root_public_key, group_id, epoch_key)
    invoker.invoke(fabric.fabric_id, group_id, Matter::Cluster::OnOff::CLUSTER_ID,
      Matter::Cluster::OnOff::CMD_ON, root_public_key: fabric.root_public_key)
    sleep 1.second
    report = im.read_attribute(session: session, peer: peer, endpoint_id: 1_u16,
      cluster_id: Matter::Cluster::OnOff::CLUSTER_ID,
      attribute_id: Matter::Cluster::OnOff::ATTR_ON_OFF)
    value = report.attribute_reports.as(Array(IM::AttributeReportIB))
      .first.attribute_data.as(IM::AttributeDataIB).data.as(TLV::Any)
    Bool.from_tlv(value.to_slice).should be_true
  ensure
    client.try(&.close)
    backend.try(&.close) if backend.try(&.open?)
  end
end
