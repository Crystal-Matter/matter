require "../../src/matter/controller"
require "../../src/matter/controller/joint_commissioning"

private alias SdkDatastore = Matter::Cluster::JointFabricDatastore
private alias SwitchGroups = Matter::Cluster::Groups

# An independent Crystal controller commissions the official SDK JFA as an
# Anchor, then reads its Joint Fabric identity and exercises Datastore key-set,
# group, pending-node, administrator, and live-node endpoint/group commands over CASE. The SDK JFC ->
# Crystal device smoke runs separately, using a fresh JFA store for this direction.
module SdkJfaInverseDriver
  extend self

  FABRIC_ID            =   0xA200_u64
  CONTROLLER_ID        =   0xA201_u64
  SDK_JFA_ID           =   0xA202_u64
  TEST_VENDOR_ID       =   0xFFF1_u16
  SDK_JFA_PORT         =         5533
  SDK_DISCRIMINATOR    =     3840_u16
  SDK_PASSCODE         = 11022033_u32
  JFA_ENDPOINT         =        1_u16
  TIMEOUT              = 90.seconds
  SDK_PAA_CERT         = "credentials/development/paa-root-certs/Chip-Test-PAA-FFF1-Cert.der"
  SDK_CD_CERT_GLOB     = "credentials/development/cd-certs/CSA_Matter_CD_Signing_Key_*.cert.der"
  TEST_GROUP_ID        = 0x1234_u16
  TEST_KEY_SET_ID      = 0x1235_u16
  TEST_NODE_ID         = 0xA203_u64
  TEST_ADMIN_ID        = 0xA204_u64
  TEST_LIVE_NODE_ID    = 0xA205_u64
  SWITCH_ENDPOINT      =      1_u16
  TEST_ADMIN_VENDOR_ID = 0xFFF2_u16
  # SDK v1.6.0.0 examples/platform/linux/CommissionerMain.cpp installs this
  # test-only IPK when its commissioned JFA enters commissioner mode.
  SDK_EXAMPLE_IPK = "temporary ipk 01".to_slice

  private def sdk_attestation_trust(sdk_root : String) : Matter::Controller::AttestationTrustStore
    trust = Matter::Controller::AttestationTrustStore.matter_test_fixture
    trust.paa_certificates << File.read(File.join(sdk_root, SDK_PAA_CERT)).to_slice.dup
    signer_paths = Dir.glob(File.join(sdk_root, SDK_CD_CERT_GLOB))
    raise Matter::ConfigurationError.new("No SDK development CD signers found") if signer_paths.empty?
    signer_paths.each do |path|
      signer = OpenSSL::X509::Certificate.from_der(File.read(path).to_slice)
      extension = signer.extensions.find { |entry| entry.oid == "subjectKeyIdentifier" } ||
                  raise Matter::ConfigurationError.new("SDK CD signer has no subject key identifier")
      ski = extension.value.gsub(/[^0-9A-Fa-f]/, "").upcase
      unless ski.matches?(/\A[0-9A-F]{40}\z/)
        raise Matter::ConfigurationError.new("SDK CD signer has invalid subject key identifier")
      end
      trust.cd_signers[ski] = signer.public_key.as(OpenSSL::PKey::EC).public_key_bytes
    end
    trust
  end

  private def store(path : String) : Matter::Controller::StateStore
    Matter::Controller::StateStore.new(Matter::Storage::YamlFile.new(path))
  end

  private def attribute(im : Matter::Controller::ImClient,
                        session : Matter::Session::SecureContext,
                        peer : Socket::IPAddress, cluster : UInt32,
                        id : UInt32) : TLV::Any
    report = im.read_attribute(session: session, peer: peer,
      endpoint_id: JFA_ENDPOINT, cluster_id: cluster, attribute_id: id)
    data = report.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data || raise Matter::ProtocolError.new("SDK JFA attribute read returned a status")
    data.data || raise Matter::ProtocolError.new("SDK JFA attribute read omitted data")
  end

  private def group_list(im : Matter::Controller::ImClient,
                         session : Matter::Session::SecureContext,
                         peer : Socket::IPAddress) : Array(SdkDatastore::DatastoreGroupInformationEntryStruct)
    data = attribute(im, session, peer,
      SdkDatastore::CLUSTER_ID, SdkDatastore::ATTR_GROUP_LIST)
    Array(SdkDatastore::DatastoreGroupInformationEntryStruct).from_tlv(data.to_slice)
  end

  private def key_set_list(im : Matter::Controller::ImClient,
                           session : Matter::Session::SecureContext,
                           peer : Socket::IPAddress) : Array(SdkDatastore::DatastoreGroupKeySetStruct)
    data = attribute(im, session, peer,
      SdkDatastore::CLUSTER_ID, SdkDatastore::ATTR_GROUP_KEY_SET_LIST)
    Array(SdkDatastore::DatastoreGroupKeySetStruct).from_tlv(data.to_slice)
  end

  private def node_list(im : Matter::Controller::ImClient,
                        session : Matter::Session::SecureContext,
                        peer : Socket::IPAddress) : Array(SdkDatastore::DatastoreNodeInformationEntryStruct)
    data = attribute(im, session, peer,
      SdkDatastore::CLUSTER_ID, SdkDatastore::ATTR_NODE_LIST)
    Array(SdkDatastore::DatastoreNodeInformationEntryStruct).from_tlv(data.to_slice)
  end

  private def admin_list(im : Matter::Controller::ImClient,
                         session : Matter::Session::SecureContext,
                         peer : Socket::IPAddress) : Array(SdkDatastore::DatastoreAdministratorInformationEntryStruct)
    data = attribute(im, session, peer,
      SdkDatastore::CLUSTER_ID, SdkDatastore::ATTR_ADMIN_LIST)
    Array(SdkDatastore::DatastoreAdministratorInformationEntryStruct).from_tlv(data.to_slice)
  end

  private def endpoint_list(im : Matter::Controller::ImClient,
                            session : Matter::Session::SecureContext,
                            peer : Socket::IPAddress) : Array(SdkDatastore::DatastoreEndpointEntryStruct)
    data = attribute(im, session, peer,
      SdkDatastore::CLUSTER_ID, SdkDatastore::ATTR_NODE_ENDPOINT_LIST)
    Array(SdkDatastore::DatastoreEndpointEntryStruct).from_tlv(data.to_slice)
  end

  private def endpoint_group_list(im : Matter::Controller::ImClient,
                                  session : Matter::Session::SecureContext,
                                  peer : Socket::IPAddress) : Array(SdkDatastore::DatastoreEndpointGroupIDEntryStruct)
    data = attribute(im, session, peer,
      SdkDatastore::CLUSTER_ID, SdkDatastore::ATTR_ENDPOINT_GROUP_ID_LIST)
    Array(SdkDatastore::DatastoreEndpointGroupIDEntryStruct).from_tlv(data.to_slice)
  end

  private def switch_group_ids(im : Matter::Controller::ImClient,
                               session : Matter::Session::SecureContext,
                               peer : Socket::IPAddress) : Array(UInt16)
    response = im.invoke(session: session, peer: peer,
      endpoint_id: SWITCH_ENDPOINT, cluster_id: SwitchGroups::CLUSTER_ID,
      command_id: SwitchGroups::CMD_GET_GROUP_MEMBERSHIP,
      fields: SwitchGroups::GetGroupMembershipRequest.new([] of Matter::DataType::GroupId).to_slice)
    entry = Matter::Controller::ImClient.single_invoke_response!(response, "Switch group membership")
    data = entry.command_data || raise Matter::ProtocolError.new("Switch group membership returned no data")
    unless data.command_path.command == SwitchGroups::CMD_GET_GROUP_MEMBERSHIP_RESPONSE
      raise Matter::ProtocolError.new("Switch group membership returned a different command")
    end
    fields = data.command_fields || raise Matter::ProtocolError.new("Switch group membership omitted fields")
    SwitchGroups::GetGroupMembershipResponse.from_slice(fields.to_slice).group_list.map(&.id)
  end

  private def invoke_datastore(im : Matter::Controller::ImClient,
                               session : Matter::Session::SecureContext,
                               peer : Socket::IPAddress,
                               command_id : UInt32, fields : Bytes) : Nil
    response = im.invoke(session: session, peer: peer,
      endpoint_id: JFA_ENDPOINT,
      cluster_id: SdkDatastore::CLUSTER_ID,
      command_id: command_id, fields: fields)
    Matter::Controller::JointCommissioning.assert_status_success(response)
  end

  def run(path : String, address : String, sdk_root : String,
          switch_pin : UInt32, switch_discriminator : UInt16) : Nil
    bootstrap = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      FABRIC_ID, CONTROLLER_ID, TEST_VENDOR_ID, ipk_value: SDK_EXAMPLE_IPK)
    state_store = store(path)
    state_store.save(Matter::Controller::State.new(fabric: bootstrap.fabric,
      commissioner_node_id: CONTROLLER_ID))
    peer = Socket::IPAddress.new(address, SDK_JFA_PORT)
    client = Matter::Controller::Client.new(counter_lease: state_store.counter_lease(CONTROLLER_ID))
    begin
      issuer = ->(fabric_id : UInt64, node_id : UInt64, public_key : Bytes) do
        unless fabric_id == FABRIC_ID && node_id == SDK_JFA_ID
          raise Matter::ConfigurationError.new("Unexpected SDK JFA commissioning identity")
        end
        bootstrap.issue_anchor_administrator_noc(node_id, public_key)
      end
      code = Matter::SetupPayload.generate_manual_code(SDK_DISCRIMINATOR, SDK_PASSCODE)
      Matter::Controller::Commissioning::Commissioner.new(state_store, client,
        timeout: TIMEOUT, certificate_issuer: issuer,
        attestation_verifier: Matter::Controller::DeviceAttestationVerifier.new(
          sdk_attestation_trust(sdk_root))).pairing_code(
        SDK_JFA_ID, code, peer)
      puts "Crystal commissioned official SDK JFA as Anchor"

      fabric = state_store.load.fabric || raise Matter::ConfigurationError.new("Anchor fabric missing")
      session = Matter::Controller::Pairing::CasePairing.new.pair(client, peer, fabric,
        peer_node_id: SDK_JFA_ID, timeout: TIMEOUT)
      im = Matter::Controller::ImClient.new(client, TIMEOUT)
      admin_index = attribute(im, session, peer,
        Matter::Cluster::JointFabricAdministrator::CLUSTER_ID,
        Matter::Cluster::JointFabricAdministrator::ATTR_ADMINISTRATOR_FABRIC_INDEX)
      unless admin_index.as_u8 == 1_u8
        raise Matter::ProtocolError.new("SDK JFA did not activate its Anchor fabric")
      end

      root = attribute(im, session, peer,
        Matter::Cluster::JointFabricDatastore::CLUSTER_ID,
        Matter::Cluster::JointFabricDatastore::ATTR_ANCHOR_ROOT_CA)
      unless Bytes.from_tlv(root.to_slice) == fabric.root_cert
        raise Matter::AuthenticationError.new("SDK Datastore AnchorRootCA differs from commissioned root")
      end
      anchor_id = attribute(im, session, peer,
        Matter::Cluster::JointFabricDatastore::CLUSTER_ID,
        Matter::Cluster::JointFabricDatastore::ATTR_ANCHOR_NODE_ID)
      unless anchor_id.as_u64 == SDK_JFA_ID
        raise Matter::ProtocolError.new("SDK Datastore AnchorNodeID differs from commissioned JFA")
      end
      entries = admin_list(im, session, peer)
      unless entries.any? { |entry| entry.node_id == SDK_JFA_ID && entry.vendor_id == TEST_VENDOR_ID }
        raise Matter::ProtocolError.new("SDK Datastore AdminList omitted Anchor JFA")
      end
      puts "PASS: Crystal CASE read official SDK JFA and Datastore Anchor identity"

      initial_key_sets = key_set_list(im, session, peer)
      unless initial_key_sets.any?(&.group_key_set_id.==(SdkDatastore::IPK_KEY_SET_ID))
        raise Matter::ProtocolError.new("SDK Datastore GroupKeySetList omitted reserved IPK key set")
      end
      if initial_key_sets.any?(&.group_key_set_id.==(TEST_KEY_SET_ID))
        raise Matter::ProtocolError.new("SDK Datastore test GroupKeySetID already exists")
      end
      first_key_set = SdkDatastore::DatastoreGroupKeySetStruct.new(TEST_KEY_SET_ID,
        SdkDatastore::DatastoreGroupKeySecurityPolicyEnum::TrustFirst,
        Bytes.new(16, 0x11_u8), 2_220_000_u64, nil, nil, nil, nil)
      invoke_datastore(im, session, peer, SdkDatastore::CMD_ADD_KEY_SET,
        SdkDatastore::AddKeySetRequest.new(first_key_set).to_slice)
      added_key_set = key_set_list(im, session, peer).find(&.group_key_set_id.==(TEST_KEY_SET_ID)) ||
                      raise Matter::ProtocolError.new("SDK Datastore AddKeySet did not update GroupKeySetList")
      unless added_key_set == first_key_set
        raise Matter::ProtocolError.new("SDK Datastore AddKeySet returned different epoch fields")
      end
      rotated_key_set = SdkDatastore::DatastoreGroupKeySetStruct.new(TEST_KEY_SET_ID,
        SdkDatastore::DatastoreGroupKeySecurityPolicyEnum::TrustFirst,
        Bytes.new(16, 0x22_u8), 2_220_001_u64, nil, nil, nil, nil)
      invoke_datastore(im, session, peer, SdkDatastore::CMD_UPDATE_KEY_SET,
        SdkDatastore::UpdateKeySetRequest.new(rotated_key_set).to_slice)
      updated_key_set = key_set_list(im, session, peer).find(&.group_key_set_id.==(TEST_KEY_SET_ID)) ||
                        raise Matter::ProtocolError.new("SDK Datastore UpdateKeySet removed the key set")
      unless updated_key_set == rotated_key_set
        raise Matter::ProtocolError.new("SDK Datastore UpdateKeySet did not replace the epoch key and time")
      end
      invoke_datastore(im, session, peer, SdkDatastore::CMD_REMOVE_KEY_SET,
        SdkDatastore::RemoveKeySetRequest.new(TEST_KEY_SET_ID).to_slice)
      final_key_sets = key_set_list(im, session, peer)
      if final_key_sets.any?(&.group_key_set_id.==(TEST_KEY_SET_ID)) ||
         final_key_sets.map(&.group_key_set_id).sort! != initial_key_sets.map(&.group_key_set_id).sort!
        raise Matter::ProtocolError.new("SDK Datastore RemoveKeySet did not restore GroupKeySetList")
      end
      puts "PASS: Crystal controller added, updated, and removed an SDK JFA Datastore key set over CASE"

      initial_groups = group_list(im, session, peer)
      if initial_groups.any?(&.group_id.==(TEST_GROUP_ID.to_u64))
        raise Matter::ProtocolError.new("SDK Datastore test GroupID already exists")
      end
      invoke_datastore(im, session, peer, SdkDatastore::CMD_ADD_GROUP,
        SdkDatastore::AddGroupRequest.new(TEST_GROUP_ID, "Crystal SDK group", nil, nil, nil,
          SdkDatastore::DatastoreAccessControlEntryPrivilegeEnum::View).to_slice)
      added = group_list(im, session, peer).find(&.group_id.==(TEST_GROUP_ID.to_u64)) ||
              raise Matter::ProtocolError.new("SDK Datastore AddGroup did not update GroupList")
      unless added.friendly_name == "Crystal SDK group" &&
             added.group_key_set_id.nil? && added.group_cat.nil? &&
             added.group_cat_version.nil? &&
             added.group_permission == SdkDatastore::DatastoreAccessControlEntryPrivilegeEnum::View
        raise Matter::ProtocolError.new("SDK Datastore AddGroup returned different group fields")
      end
      invoke_datastore(im, session, peer, SdkDatastore::CMD_UPDATE_GROUP,
        SdkDatastore::UpdateGroupRequest.new(TEST_GROUP_ID, "Crystal SDK group updated", nil, nil, nil, nil).to_slice)
      updated = group_list(im, session, peer).find(&.group_id.==(TEST_GROUP_ID.to_u64)) ||
                raise Matter::ProtocolError.new("SDK Datastore UpdateGroup removed the group")
      unless updated.friendly_name == "Crystal SDK group updated" &&
             updated.group_permission == SdkDatastore::DatastoreAccessControlEntryPrivilegeEnum::View
        raise Matter::ProtocolError.new("SDK Datastore UpdateGroup did not preserve group fields")
      end
      invoke_datastore(im, session, peer, SdkDatastore::CMD_REMOVE_GROUP,
        SdkDatastore::RemoveGroupRequest.new(TEST_GROUP_ID).to_slice)
      final_groups = group_list(im, session, peer)
      if final_groups.any?(&.group_id.==(TEST_GROUP_ID.to_u64)) ||
         final_groups.map(&.group_id).sort! != initial_groups.map(&.group_id).sort!
        raise Matter::ProtocolError.new("SDK Datastore RemoveGroup did not restore GroupList")
      end
      puts "PASS: Crystal controller added, updated, and removed an SDK JFA Datastore group over CASE"

      initial_nodes = node_list(im, session, peer)
      if initial_nodes.any?(&.node_id.==(TEST_NODE_ID))
        raise Matter::ProtocolError.new("SDK Datastore test NodeID already exists")
      end
      invoke_datastore(im, session, peer, SdkDatastore::CMD_ADD_PENDING_NODE,
        SdkDatastore::AddPendingNodeRequest.new(TEST_NODE_ID, "Crystal pending node").to_slice)
      added_node = node_list(im, session, peer).find(&.node_id.==(TEST_NODE_ID)) ||
                   raise Matter::ProtocolError.new("SDK Datastore AddPendingNode did not update NodeList")
      unless added_node.friendly_name == "Crystal pending node" &&
             added_node.commissioning_status_entry.state == SdkDatastore::DatastoreStateEnum::Pending
        raise Matter::ProtocolError.new("SDK Datastore AddPendingNode returned different node fields")
      end
      invoke_datastore(im, session, peer, SdkDatastore::CMD_UPDATE_NODE,
        SdkDatastore::UpdateNodeRequest.new(TEST_NODE_ID, "Crystal pending node updated").to_slice)
      updated_node = node_list(im, session, peer).find(&.node_id.==(TEST_NODE_ID)) ||
                     raise Matter::ProtocolError.new("SDK Datastore UpdateNode removed the node")
      unless updated_node.friendly_name == "Crystal pending node updated" &&
             updated_node.commissioning_status_entry.state == SdkDatastore::DatastoreStateEnum::Pending
        raise Matter::ProtocolError.new("SDK Datastore UpdateNode did not preserve pending state")
      end
      invoke_datastore(im, session, peer, SdkDatastore::CMD_REMOVE_NODE,
        SdkDatastore::RemoveNodeRequest.new(TEST_NODE_ID).to_slice)
      final_nodes = node_list(im, session, peer)
      if final_nodes.any?(&.node_id.==(TEST_NODE_ID)) ||
         final_nodes.map(&.node_id).sort! != initial_nodes.map(&.node_id).sort!
        raise Matter::ProtocolError.new("SDK Datastore RemoveNode did not restore NodeList")
      end
      puts "PASS: Crystal controller added, updated, and removed an SDK JFA Datastore pending node over CASE"

      if entries.any?(&.node_id.==(TEST_ADMIN_ID))
        raise Matter::ProtocolError.new("SDK Datastore test Administrator NodeID already exists")
      end
      test_icac = fabric.intermediate_cert ||
                  raise Matter::ConfigurationError.new("Anchor ICAC is missing")
      invoke_datastore(im, session, peer, SdkDatastore::CMD_ADD_ADMIN,
        SdkDatastore::AddAdminRequest.new(TEST_ADMIN_ID, "Crystal SDK administrator",
          TEST_ADMIN_VENDOR_ID, test_icac).to_slice)
      added_admin = admin_list(im, session, peer).find(&.node_id.==(TEST_ADMIN_ID)) ||
                    raise Matter::ProtocolError.new("SDK Datastore AddAdmin did not update AdminList")
      unless added_admin.friendly_name == "Crystal SDK administrator" &&
             added_admin.vendor_id == TEST_ADMIN_VENDOR_ID && added_admin.icac == test_icac
        raise Matter::ProtocolError.new("SDK Datastore AddAdmin returned different administrator fields")
      end
      invoke_datastore(im, session, peer, SdkDatastore::CMD_UPDATE_ADMIN,
        SdkDatastore::UpdateAdminRequest.new(TEST_ADMIN_ID,
          friendly_name: "Crystal SDK administrator updated").to_slice)
      updated_admin = admin_list(im, session, peer).find(&.node_id.==(TEST_ADMIN_ID)) ||
                      raise Matter::ProtocolError.new("SDK Datastore UpdateAdmin removed the administrator")
      unless updated_admin.friendly_name == "Crystal SDK administrator updated" &&
             updated_admin.vendor_id == TEST_ADMIN_VENDOR_ID && updated_admin.icac == test_icac
        raise Matter::ProtocolError.new("SDK Datastore UpdateAdmin did not preserve vendor and ICAC")
      end
      invoke_datastore(im, session, peer, SdkDatastore::CMD_REMOVE_ADMIN,
        SdkDatastore::RemoveAdminRequest.new(TEST_ADMIN_ID).to_slice)
      final_admins = admin_list(im, session, peer)
      if final_admins.any?(&.node_id.==(TEST_ADMIN_ID)) ||
         final_admins.map(&.node_id).sort! != entries.map(&.node_id).sort!
        raise Matter::ProtocolError.new("SDK Datastore RemoveAdmin did not restore AdminList")
      end
      puts "PASS: Crystal controller added, updated, and removed an SDK JFA Datastore administrator over CASE"

      # RefreshNode needs a real operational peer: the SDK JFA reads its
      # Descriptor and Access Control state before it can name an endpoint.
      switch_peer = Socket::IPAddress.new(address, Matter::Device::DEFAULT_PORT)
      switch_code = Matter::SetupPayload.generate_manual_code(switch_discriminator, switch_pin)
      Matter::Controller::Commissioning::Commissioner.new(state_store, client,
        timeout: TIMEOUT,
        attestation_verifier: Matter::Controller::DeviceAttestationVerifier.new(
          Matter::Controller::AttestationTrustStore.matter_test_fixture)).pairing_code(
        TEST_LIVE_NODE_ID, switch_code, switch_peer,
        fabric_id: FABRIC_ID, root_public_key: fabric.root_public_key,
        controller_node_id: CONTROLLER_ID)
      switch_session = Matter::Controller::Pairing::CasePairing.new.pair(client,
        switch_peer, fabric, peer_node_id: TEST_LIVE_NODE_ID, timeout: TIMEOUT)

      initial_endpoints = endpoint_list(im, session, peer)
      if initial_endpoints.any?(&.node_id.==(TEST_LIVE_NODE_ID))
        raise Matter::ProtocolError.new("SDK Datastore live NodeID already has endpoints")
      end
      invoke_datastore(im, session, peer, SdkDatastore::CMD_ADD_PENDING_NODE,
        SdkDatastore::AddPendingNodeRequest.new(TEST_LIVE_NODE_ID, "Crystal live switch").to_slice)
      invoke_datastore(im, session, peer, SdkDatastore::CMD_REFRESH_NODE,
        SdkDatastore::RefreshNodeRequest.new(TEST_LIVE_NODE_ID).to_slice)
      deadline = Time.instant + 120.seconds
      loop do
        live_node = node_list(im, session, peer).find(&.node_id.==(TEST_LIVE_NODE_ID))
        discovered = endpoint_list(im, session, peer).any? do |entry|
          entry.node_id == TEST_LIVE_NODE_ID && entry.endpoint_id == SWITCH_ENDPOINT
        end
        break if live_node &&
                 live_node.commissioning_status_entry.state == SdkDatastore::DatastoreStateEnum::Committed &&
                 discovered
        if Time.instant >= deadline
          raise Matter::TimeoutError.new("SDK JFA did not commit the live switch and discover its endpoint")
        end
        sleep 1.second
      end
      invoke_datastore(im, session, peer, SdkDatastore::CMD_UPDATE_ENDPOINT_FOR_NODE,
        SdkDatastore::UpdateEndpointForNodeRequest.new(
          SWITCH_ENDPOINT, TEST_LIVE_NODE_ID, "Crystal live endpoint").to_slice)
      updated_endpoint = endpoint_list(im, session, peer).find do |entry|
        entry.node_id == TEST_LIVE_NODE_ID && entry.endpoint_id == SWITCH_ENDPOINT
      end || raise Matter::ProtocolError.new("SDK Datastore lost the live endpoint")
      unless updated_endpoint.friendly_name == "Crystal live endpoint"
        raise Matter::ProtocolError.new("SDK Datastore UpdateEndpointForNode did not rename the endpoint")
      end

      # RefreshNode synchronizes Access Control; grant the JFA after that sync.
      acl_report = im.read_attribute(session: switch_session, peer: switch_peer,
        endpoint_id: Matter::Node::ROOT_ENDPOINT_ID,
        cluster_id: Matter::Cluster::AccessControl::CLUSTER_ID,
        attribute_id: Matter::Cluster::AccessControl::ATTR_ACL)
      acl_data = acl_report.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
        .first.attribute_data || raise Matter::ProtocolError.new("Switch ACL read returned a status")
      acl_value = acl_data.data || raise Matter::ProtocolError.new("Switch ACL read omitted data")
      acl = Array(Matter::Cluster::AccessControl::AccessControlEntry).from_tlv(acl_value.to_slice)
      anchor_admin_subject = Matter::DataType::NodeId.from_case_authenticated_tag(
        Matter::DataType::CaseAuthenticatedTag.create(
          SdkDatastore::ADMINISTRATOR_CAT, 1_u16)).id
      acl << Matter::Cluster::AccessControl::AccessControlEntry.new(
        Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer,
        Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
        [anchor_admin_subject, SDK_JFA_ID], nil)
      acl_write = im.write_attribute(session: switch_session, peer: switch_peer,
        endpoint_id: Matter::Node::ROOT_ENDPOINT_ID,
        cluster_id: Matter::Cluster::AccessControl::CLUSTER_ID,
        attribute_id: Matter::Cluster::AccessControl::ATTR_ACL,
        value: acl.to_tlv)
      unless acl_write.write_responses.first.status.status == Matter::InteractionModel::StatusCode::Success.value
        raise Matter::ProtocolError.new("Switch did not grant SDK Anchor administrator access")
      end
      acl_readback = im.read_attribute(session: switch_session, peer: switch_peer,
        endpoint_id: Matter::Node::ROOT_ENDPOINT_ID,
        cluster_id: Matter::Cluster::AccessControl::CLUSTER_ID,
        attribute_id: Matter::Cluster::AccessControl::ATTR_ACL)
      acl_readback_data = acl_readback.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
        .first.attribute_data || raise Matter::ProtocolError.new("Switch ACL readback returned a status")
      acl_readback_value = acl_readback_data.data || raise Matter::ProtocolError.new("Switch ACL readback omitted data")
      acl_entries = Array(Matter::Cluster::AccessControl::AccessControlEntry).from_tlv(acl_readback_value.to_slice)
      unless acl_entries.any? { |entry| entry.subjects.try(&.includes?(SDK_JFA_ID)) }
        raise Matter::ProtocolError.new("Switch ACL did not retain SDK JFA node grant")
      end

      # The SDK JFA sends Groups commands to this live switch and updates the
      # Datastore status after the target acknowledges them.
      initial_endpoint_groups = endpoint_group_list(im, session, peer)
      if initial_endpoint_groups.any?(&.group_id.==(TEST_GROUP_ID)) ||
         switch_group_ids(im, switch_session, switch_peer).includes?(TEST_GROUP_ID)
        raise Matter::ProtocolError.new("Live switch test group already exists")
      end
      invoke_datastore(im, session, peer, SdkDatastore::CMD_ADD_GROUP,
        SdkDatastore::AddGroupRequest.new(TEST_GROUP_ID, "Crystal live group", nil, nil, nil,
          SdkDatastore::DatastoreAccessControlEntryPrivilegeEnum::View).to_slice)
      invoke_datastore(im, session, peer, SdkDatastore::CMD_ADD_GROUP_ID_TO_ENDPOINT_FOR_NODE,
        SdkDatastore::AddGroupIDToEndpointForNodeRequest.new(
          TEST_LIVE_NODE_ID, SWITCH_ENDPOINT, TEST_GROUP_ID).to_slice)
      group_deadline = Time.instant + 90.seconds
      loop do
        membership = endpoint_group_list(im, session, peer).find do |entry|
          entry.node_id == TEST_LIVE_NODE_ID && entry.endpoint_id == SWITCH_ENDPOINT &&
            entry.group_id == TEST_GROUP_ID
        end
        break if membership && membership.status_entry.state == SdkDatastore::DatastoreStateEnum::Committed &&
                 switch_group_ids(im, switch_session, switch_peer).includes?(TEST_GROUP_ID)
        if Time.instant >= group_deadline
          raise Matter::TimeoutError.new("SDK JFA did not commit live switch group membership: " +
                                         "Datastore=#{membership.try(&.status_entry.state)}, switch=#{switch_group_ids(im, switch_session, switch_peer).inspect}")
        end
        sleep 1.second
      end
      invoke_datastore(im, session, peer, SdkDatastore::CMD_REMOVE_GROUP_ID_FROM_ENDPOINT_FOR_NODE,
        SdkDatastore::RemoveGroupIDFromEndpointForNodeRequest.new(
          TEST_LIVE_NODE_ID, SWITCH_ENDPOINT, TEST_GROUP_ID).to_slice)
      removal_deadline = Time.instant + 90.seconds
      loop do
        membership = endpoint_group_list(im, session, peer).any? do |entry|
          entry.node_id == TEST_LIVE_NODE_ID && entry.endpoint_id == SWITCH_ENDPOINT &&
            entry.group_id == TEST_GROUP_ID
        end
        break if !membership && !switch_group_ids(im, switch_session, switch_peer).includes?(TEST_GROUP_ID)
        if Time.instant >= removal_deadline
          raise Matter::TimeoutError.new("SDK JFA did not remove the live switch group membership")
        end
        sleep 1.second
      end
      invoke_datastore(im, session, peer, SdkDatastore::CMD_REMOVE_GROUP,
        SdkDatastore::RemoveGroupRequest.new(TEST_GROUP_ID).to_slice)
      final_endpoint_groups = endpoint_group_list(im, session, peer)
      endpoint_baseline_preserved = initial_endpoint_groups.all? do |original|
        final_endpoint_groups.any? do |entry|
          entry.node_id == original.node_id &&
            entry.endpoint_id == original.endpoint_id &&
            entry.group_id == original.group_id
        end
      end
      if group_list(im, session, peer).map(&.group_id).sort! != initial_groups.map(&.group_id).sort! ||
         final_endpoint_groups.size != initial_endpoint_groups.size ||
         !endpoint_baseline_preserved
        raise Matter::ProtocolError.new("SDK Datastore live group cleanup changed baseline lists")
      end
      puts "PASS: Crystal controller propagated and removed an SDK JFA Datastore group on a live switch"

      invoke_datastore(im, session, peer, SdkDatastore::CMD_REMOVE_NODE,
        SdkDatastore::RemoveNodeRequest.new(TEST_LIVE_NODE_ID).to_slice)
      if node_list(im, session, peer).map(&.node_id).sort! != initial_nodes.map(&.node_id).sort!
        raise Matter::ProtocolError.new("SDK Datastore live-node cleanup did not restore baseline NodeList")
      end
      final_endpoints = endpoint_list(im, session, peer)
      baseline_preserved = initial_endpoints.all? do |original|
        final_endpoints.any? do |entry|
          entry.node_id == original.node_id &&
            entry.endpoint_id == original.endpoint_id &&
            entry.friendly_name == original.friendly_name
        end
      end
      unless baseline_preserved
        raise Matter::ProtocolError.new("SDK Datastore live-node update changed a baseline endpoint")
      end
      puts "PASS: Crystal controller refreshed and renamed a live SDK JFA Datastore endpoint over CASE"
    ensure
      client.close
    end
  end
end

unless ARGV.size == 5
  STDERR.puts "Usage: sdk_jfa_inverse_driver <private-controller-state.yml> <sdk-jfa-ipv6-address> <sdk-root> <switch-pin> <switch-discriminator>"
  exit 2
end
SdkJfaInverseDriver.run(ARGV[0], ARGV[1], ARGV[2], ARGV[3].to_u32, ARGV[4].to_u16)
