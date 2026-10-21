require "../spec_helper"
require "../../examples/support/joint_fabric_administrator_device"

class InspectableJointFabricAdministratorDevice < MatterJointFabricAdministrator::Device
  def advertised_joint_role : Matter::MDNS::JointFabricRole?
    commissioning_info_for(Matter::MDNS::CommissioningMode::Basic).joint_fabric_role
  end

  def install_test_fabric(fabric : Matter::Fabric) : Nil
    fabric_added(fabric)
  end

  def remove_test_fabric(index : UInt8) : Nil
    fabric_removed(index)
  end

  def select_anchor_administrator_fabric_for_spec(index : UInt8) : Nil
    select_anchor_administrator_fabric(index)
  end
end

describe MatterJointFabricAdministrator::Device do
  it "treats a legacy non-Anchor role record as transfer-complete" do
    document = Matter::Storage::Document.new
    document["anchor"] = false
    role = MatterJointFabricAdministrator::Device::JointFabricRoleState.from_document(document)
    role.anchor?.should be_false
    role.transfer_complete?.should be_true
  end

  it "exposes both mandatory JFA clusters on device type 0x0130" do
    device = MatterJointFabricAdministrator::Device.new(storage: Matter::Storage::Memory.new,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    endpoint = device.node.endpoint(1_u16).as(Matter::Endpoint)
    endpoint.primary_device_type.as(Matter::DeviceType).device_type_id.id.should eq(0x0130_u32)
    endpoint.has_cluster?(Matter::Cluster::JointFabricDatastore::CLUSTER_ID).should be_true
    endpoint.has_cluster?(Matter::Cluster::JointFabricAdministrator::CLUSTER_ID).should be_true
    endpoint.validate.should be_empty
  end

  it "advertises only availability until provisioned as an Anchor" do
    device = InspectableJointFabricAdministratorDevice.new(storage: Matter::Storage::Memory.new,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    device.advertised_joint_role.should eq(Matter::MDNS::JointFabricRole::Available)
  end

  it "persists the new Anchor fabric selection before participant follow-up" do
    backend = Matter::Storage::Memory.new
    device = InspectableJointFabricAdministratorDevice.new(storage: backend,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    device.joint_fabric_administrator.administrator_fabric_index = 2_u8
    device.select_anchor_administrator_fabric_for_spec(1_u8)
    device.joint_fabric_administrator.administrator_fabric_index.should eq(1_u8)

    restored = InspectableJointFabricAdministratorDevice.new(storage: backend,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    restored.joint_fabric_administrator.administrator_fabric_index.should eq(1_u8)
  end

  it "persists its propagation identity and removes it with the Anchor fabric" do
    crypto = Matter::Crypto::StandardCrypto.new
    root_key = crypto.create_key_pair
    icac_key = crypto.create_key_pair
    noc_key = crypto.create_key_pair
    fabric_id = 0x1234_u64
    node_id = 0x10_u64
    root = Matter::Crypto::MatterCertificate::Builder.root(root_key, 1_u64, Bytes[1], crypto)
    icac = Matter::Crypto::MatterCertificate::Builder.intermediate(
      icac_key.public_key, fabric_id, 2_u64, root_key, 1_u64, Bytes[2], crypto, anchor: true)
    noc = Matter::Crypto::MatterCertificate::Builder.node(
      noc_key.public_key, fabric_id, node_id, icac_key, 1_u64, Bytes[3], crypto,
      issuer_icac_id: 2_u64, issuer_certificate: icac,
      case_authenticated_tag: 0xFFFE_0001_u32)
    backend = Matter::Storage::Memory.new
    device = InspectableJointFabricAdministratorDevice.new(storage: backend,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    fabric = Matter::Fabric.new(fabric_id, 1_u8, node_id, root_key.public_key, noc, noc_key,
      Bytes.new(16, 1_u8), intermediate_cert: icac, root_cert: root,
      cats: [Matter::DataType::CaseAuthenticatedTag.new(0xFFFE_0001_u32)])

    bootstrap_path = File.join(Dir.tempdir, "matter-jfa-bootstrap-#{Random::Secure.hex(6)}.yml")
    bootstrap_store = Matter::Controller::StateStore.new(Matter::Storage::YamlFile.new(bootstrap_path))
    bootstrap_identity = Matter::Controller::FabricInfo.new(fabric_id, node_id, fabric.ipk,
      root, root_key.public_key, noc, noc_key.private_key,
      root_private_key: root_key.private_key,
      intermediate_cert: icac, intermediate_private_key: icac_key.private_key)
    bootstrap_store.save(Matter::Controller::State.new(fabric: bootstrap_identity))
    bootstrap_store.backend.close

    previous = ENV["MATTER_JFA_PROVISIONED_ANCHOR"]?
    previous_bootstrap = ENV["MATTER_JFA_BOOTSTRAP_STATE_PATH"]?
    ENV["MATTER_JFA_PROVISIONED_ANCHOR"] = "1"
    ENV["MATTER_JFA_BOOTSTRAP_STATE_PATH"] = bootstrap_path
    wrong_key = crypto.create_key_pair
    wrong_backend = Matter::Storage::Memory.new
    wrong_device = InspectableJointFabricAdministratorDevice.new(storage: wrong_backend,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    wrong_state = MatterJointFabricAdministrator::Device::IcacKeyState.new(wrong_key.private_key, wrong_key.public_key)
    wrong_device.persistence.write_app_document(MatterJointFabricAdministrator::Device::APP_KEY_DOCUMENT, wrong_state.to_document)
    wrong_device.install_test_fabric(fabric)
    wrong_device.advertised_joint_role.should eq(Matter::MDNS::JointFabricRole::Available)
    Matter::Controller::StateStore.new(wrong_backend).load.fabrics.should be_empty

    device.install_test_fabric(fabric)
    expected_role = Matter::MDNS::JointFabricRole::Administrator |
                    Matter::MDNS::JointFabricRole::Anchor |
                    Matter::MDNS::JointFabricRole::Datastore
    device.advertised_joint_role.should eq(expected_role)
    admin_subject = 0xFFFF_FFFD_FFFF_0001_u64
    device.access_control.acl(1_u8).flat_map(&.subjects).should contain(admin_subject)
    admins = device.joint_fabric_datastore.admin_list
    admins.size.should eq(1)
    admins.first.node_id.should eq(node_id)
    admins.first.icac.should eq(icac)
    state_store = Matter::Controller::StateStore.new(backend)
    anchor_identity = state_store.load.fabric_for(fabric_id, root_key.public_key, node_id)
    anchor_identity.controller_noc.should eq(noc)
    anchor_identity.controller_node_id.should eq(node_id)
    anchor_identity.root_private_key.should eq(root_key.private_key)
    anchor_identity.intermediate_private_key.should eq(icac_key.private_key)
    ENV["MATTER_JFA_BOOTSTRAP_STATE_PATH"] = "#{bootstrap_path}.removed"
    device.install_test_fabric(fabric)
    device.access_control.acl(1_u8).count(&.subjects.includes?(admin_subject)).should eq(1)
    state_store.load.fabric_for(fabric_id, root_key.public_key, node_id).root_private_key
      .should eq(root_key.private_key)
    installed_key = device.persistence.app_document(MatterJointFabricAdministrator::Device::APP_KEY_DOCUMENT)
    MatterJointFabricAdministrator::Device::IcacKeyState.from_document(installed_key.as(Matter::Storage::Document)).private_key.should eq(icac_key.private_key)

    device.joint_fabric_datastore.begin_anchor_transfer.should be_true
    device.advertised_joint_role.should be_nil

    watch = MatterJointFabricAdministrator::Device::TransferWatchState.new(
      0x44_u64, fabric_id, root_key.public_key, nil)
    device.persistence.write_app_document(MatterJointFabricAdministrator::Device::APP_TRANSFER_WATCH_DOCUMENT,
      watch.to_document)
    device.persistence.save_cluster(device.joint_fabric_datastore).should be_true
    device.persistence.flush
    restarted = InspectableJointFabricAdministratorDevice.new(storage: backend,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    restarted.install_test_fabric(fabric)
    administrator = restarted.joint_fabric_administrator
    administrator.request_is_case_session = true
    administrator.request_peer_subject_ids = [0x44_u64, 0xFFFF_FFFD_FFFF_0001_u64]
    administrator.request_peer_node_id = 0x44_u64
    administrator.request_fabric_index = 1_u8
    service = administrator.service.as(Matter::Commissioning::JointFabricAdministratorService)
    frozen_datastore = restarted.joint_fabric_datastore
    frozen_datastore.request_is_case_session = true
    frozen_datastore.read_attribute(Matter::Cluster::JointFabricDatastore::ATTR_ANCHOR_NODE_ID, 1_u8).should be_a(TLV::Any)
    service.transfer_anchor_complete(administrator).should eq(Matter::InteractionModel::Status.success)
    frozen_datastore.read_attribute(Matter::Cluster::JointFabricDatastore::ATTR_ANCHOR_NODE_ID, 1_u8)
      .as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAccess)

    after_transfer = InspectableJointFabricAdministratorDevice.new(storage: backend,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    after_transfer.install_test_fabric(fabric)
    inactive_datastore = after_transfer.joint_fabric_datastore
    inactive_datastore.request_is_case_session = true
    inactive_datastore.read_attribute(Matter::Cluster::JointFabricDatastore::ATTR_ANCHOR_NODE_ID, 1_u8)
      .as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAccess)
    request = Matter::Cluster::JointFabricDatastore::AddPendingNodeRequest.new(0x99_u64, "Rejected")
    inactive_datastore.invoke_command(Matter::Cluster::JointFabricDatastore::CMD_ADD_PENDING_NODE,
      request.to_tlv(nil), is_case_session: true, fabric_index: 1_u8)
      .as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAccess)

    device.remove_test_fabric(1_u8)
    state_store.load.fabrics.should be_empty
    device.advertised_joint_role.should eq(Matter::MDNS::JointFabricRole::Available)
    device.joint_fabric_datastore.anchor_root_ca.should be_empty
    device.joint_fabric_datastore.status.state.should eq(Matter::Cluster::JointFabricDatastore::DatastoreStateEnum::Pending)
    device.persistence.app_document(MatterJointFabricAdministrator::Device::APP_KEY_DOCUMENT).should be_nil
  ensure
    if previous
      ENV["MATTER_JFA_PROVISIONED_ANCHOR"] = previous
    else
      ENV.delete("MATTER_JFA_PROVISIONED_ANCHOR")
    end
    if previous_bootstrap
      ENV["MATTER_JFA_BOOTSTRAP_STATE_PATH"] = previous_bootstrap
    else
      ENV.delete("MATTER_JFA_BOOTSTRAP_STATE_PATH")
    end
    File.delete?(bootstrap_path) if bootstrap_path
  end
end
