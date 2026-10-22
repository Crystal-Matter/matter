require "../spec_helper"
require "../../examples/support/joint_fabric_administrator_device"

class InspectableJointFabricAdministratorDevice < MatterJointFabricAdministrator::Device
  def prepare_for_start : Nil
    before_start
  end

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

  def migration_verifier_for_spec : Matter::Controller::DeviceAttestationVerifier
    migration_attestation_verifier
  end

  def anchor_profile_for_spec(fabric : Matter::Fabric) : Bool
    compliant_anchor_fabric?(fabric)
  end

  def anchor_verification_peer_for_spec(source : Socket::IPAddress) : Socket::IPAddress
    scanner = Matter::Controller::Scanner.new
    resolve_anchor_verification_peer(scanner, 0_u64, 1_u64, source, 0.seconds)
  ensure
    scanner.try(&.close)
  end

  def anchor_verification_client_for_spec(node_id : UInt64) : Matter::Controller::Client
    anchor_verification_client(node_id)
  end
end

describe MatterJointFabricAdministrator::Device do
  it "decodes a legacy command YAML without the new removal interruption flag" do
    path = File.join(Dir.tempdir, "matter-jfa-legacy-command-#{Random::Secure.hex(6)}.yml")
    request = MatterJointFabricAdministrator::Device::CommandRequest.new("inspect-fabric", 0xA102_u64,
      fabric_id: 0xA100_u64, root_public_key: Bytes[1_u8], nonce: "legacy-command")
    document = request.to_document
    document.delete("interrupt_after_remove_admin")
    backend = Matter::Storage::YamlFile.new(path)
    backend.open
    backend.write(MatterJointFabricAdministrator::Device::COMMAND_RPC_COLLECTION, "request", document)
    backend.close

    reopened = Matter::Storage::YamlFile.new(path)
    reopened.open
    stored = reopened.read(MatterJointFabricAdministrator::Device::COMMAND_RPC_COLLECTION, "request") ||
             raise Matter::StorageError.new("Legacy JFA command was not saved")
    restored = MatterJointFabricAdministrator::Device::CommandRequest.from_document(stored)
    restored.operation.should eq("inspect-fabric")
    restored.node_id.should eq(0xA102_u64)
    restored.interrupt_after_remove_admin?.should be_false
  ensure
    backend.try(&.close) if backend.try(&.open?)
    reopened.try(&.close) if reopened.try(&.open?)
    File.delete?(path) if path
  end

  it "retains the link-local interface scope in an Anchor ICAC exchange handoff" do
    peer = Socket::IPAddress.new("fe80::1234%1", 5540)
    request = MatterJointFabricAdministrator::Device::AnchorExchangeRequest.new(
      0xA100_u64, Bytes[1], 0xB200_u64, peer, 1_u16, Bytes.new(65, 1_u8), 3_u64)

    restored = MatterJointFabricAdministrator::Device::AnchorExchangeRequest.from_document(request.to_document)
    restored.peer_address.should eq("fe80::1234%1")
    reconstructed = Socket::IPAddress.new(restored.peer_address, restored.peer_port)
    reconstructed.zone_id.should eq(peer.zone_id)
  end

  it "durably repairs a legacy Anchor Datastore IPK before serving it after restart" do
    crypto = Matter::Crypto::StandardCrypto.new
    root_key = crypto.create_key_pair
    icac_key = crypto.create_key_pair
    noc_key = crypto.create_key_pair
    fabric_id = 0xA100_u64
    node_id = 0xA102_u64
    root = Matter::Crypto::MatterCertificate::Builder.root(root_key, 1_u64, Bytes[1], crypto)
    icac = Matter::Crypto::MatterCertificate::Builder.intermediate(
      icac_key.public_key, fabric_id, 2_u64, root_key, 1_u64, Bytes[2], crypto, anchor: true)
    noc = Matter::Crypto::MatterCertificate::Builder.node(
      noc_key.public_key, fabric_id, node_id, icac_key, 1_u64, Bytes[3], crypto,
      issuer_icac_id: 2_u64, issuer_certificate: icac,
      case_authenticated_tag: 0xFFFE_0001_u32)
    fabric = Matter::Fabric.new(fabric_id, 1_u8, node_id, root_key.public_key, noc, noc_key,
      Bytes.new(16, 0xA5_u8), intermediate_cert: icac, root_cert: root,
      cats: [Matter::DataType::CaseAuthenticatedTag.new(0xFFFE_0001_u32)])
    path = File.join(Dir.tempdir, "matter-jfa-legacy-ipk-#{Random::Secure.hex(6)}.yml")
    previous_anchor = ENV["MATTER_JFA_PROVISIONED_ANCHOR"]?
    previous_csr = ENV["MATTER_JFA_ICAC_CSR_MAILBOX_PATH"]?
    ENV["MATTER_JFA_PROVISIONED_ANCHOR"] = "1"
    ENV["MATTER_JFA_ICAC_CSR_MAILBOX_PATH"] = "#{path}.csr"

    first = InspectableJointFabricAdministratorDevice.new(storage: Matter::Storage::YamlFile.new(path),
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    first.fabric_table.add_fabric(fabric).should be_true
    legacy = first.joint_fabric_datastore
    legacy.configure_anchor(root, node_id, fabric.vendor_id, "Legacy Anchor").success?.should be_true
    legacy.group_key_set_list.first.epoch_key0.should be_nil
    first.persistence.save_cluster(legacy).should be_true
    first.shutdown!

    repaired = InspectableJointFabricAdministratorDevice.new(storage: Matter::Storage::YamlFile.new(path),
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    repaired.prepare_for_start
    served = repaired.joint_fabric_datastore
    served.request_is_case_session = true
    key_sets = Array(Matter::Cluster::JointFabricDatastore::DatastoreGroupKeySetStruct).from_tlv(
      served.read_attribute(Matter::Cluster::JointFabricDatastore::ATTR_GROUP_KEY_SET_LIST, 1_u8).as(TLV::Any).to_slice)
    key_sets.find!(&.group_key_set_id.==(0_u16)).epoch_key0.should eq(fabric.ipk)

    # Opening a second backend immediately models a process loss before the
    # normal debounced cluster-state save or graceful shutdown.
    after_crash = InspectableJointFabricAdministratorDevice.new(storage: Matter::Storage::YamlFile.new(path),
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    after_crash.joint_fabric_datastore.group_key_set_list
      .find!(&.group_key_set_id.==(0_u16)).epoch_key0.should eq(fabric.ipk)
  ensure
    first.try(&.shutdown!)
    repaired.try(&.shutdown!)
    after_crash.try(&.shutdown!)
    File.delete?(path) if path
    if previous_anchor
      ENV["MATTER_JFA_PROVISIONED_ANCHOR"] = previous_anchor
    else
      ENV.delete("MATTER_JFA_PROVISIONED_ANCHOR")
    end
    if previous_csr
      ENV["MATTER_JFA_ICAC_CSR_MAILBOX_PATH"] = previous_csr
    else
      ENV.delete("MATTER_JFA_ICAC_CSR_MAILBOX_PATH")
    end
  end

  it "starts Anchor verification from the operational listener without taking ownership of it" do
    device = InspectableJointFabricAdministratorDevice.new(storage: Matter::Storage::Memory.new,
      ip_addresses: [Socket::IPAddress.new("::1", 0)], port: 0)
    client = device.anchor_verification_client_for_spec(9_u64)
    client.transport.should be(device.transport)
    client.transport.port.should eq(device.port)
    client.close
    device.transport.socket.closed?.should be_false
  ensure
    client.try(&.close)
    device.try(&.shutdown!)
  end

  it "uses the authenticated Anchor CASE source when operational discovery misses" do
    previous = ENV["MATTER_JFA_ANCHOR_OPERATIONAL_PORT"]?
    ENV.delete("MATTER_JFA_ANCHOR_OPERATIONAL_PORT")
    device = InspectableJointFabricAdministratorDevice.new(storage: Matter::Storage::Memory.new,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    source = Socket::IPAddress.new("127.0.0.2", 44551)
    device.anchor_verification_peer_for_spec(source).should eq(source)
    expect_raises(Matter::TransportError, /operational port is unavailable/) do
      device.anchor_verification_peer_for_spec(Socket::IPAddress.new("127.0.0.2", 0))
    end
  ensure
    if previous
      ENV["MATTER_JFA_ANCHOR_OPERATIONAL_PORT"] = previous
    else
      ENV.delete("MATTER_JFA_ANCHOR_OPERATIONAL_PORT")
    end
  end

  it "keeps a fixture DUT out of SDK discovery until its gate opens" do
    gate = File.join(Dir.tempdir, "matter-jfa-discovery-#{Random::Secure.hex(6)}")
    previous = ENV["MATTER_JFA_DISCOVERY_GATE_PATH"]?
    ENV["MATTER_JFA_DISCOVERY_GATE_PATH"] = gate
    device = InspectableJointFabricAdministratorDevice.new(storage: Matter::Storage::Memory.new,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    device.start
    device.responder.advertised_commissioning_info.should be_nil
    File.write(gate, "ready")
    sleep 1.2.seconds
    device.responder.advertised_commissioning_info.should_not be_nil
  ensure
    device.try(&.shutdown!)
    File.delete(gate) if gate && File.exists?(gate)
    if previous
      ENV["MATTER_JFA_DISCOVERY_GATE_PATH"] = previous
    else
      ENV.delete("MATTER_JFA_DISCOVERY_GATE_PATH")
    end
  end

  it "does not expose an unprovisioned second JFA to wildcard commissioning reads" do
    previous = ENV["MATTER_JFA_KEEP_BOOTSTRAP_DATASTORE"]?
    ENV.delete("MATTER_JFA_KEEP_BOOTSTRAP_DATASTORE")
    device = InspectableJointFabricAdministratorDevice.new(storage: Matter::Storage::Memory.new,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    device.prepare_for_start
    device.endpoint_ids.should eq([1_u16])
    device.node.clusters.keys.should_not contain({2_u16, Matter::Cluster::JointFabricAdministrator::CLUSTER_ID})

    ENV["MATTER_JFA_KEEP_BOOTSTRAP_DATASTORE"] = "1"
    retained = InspectableJointFabricAdministratorDevice.new(storage: Matter::Storage::Memory.new,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    retained.prepare_for_start
    retained.endpoint_ids.should eq([1_u16, 2_u16])
  ensure
    if previous
      ENV["MATTER_JFA_KEEP_BOOTSTRAP_DATASTORE"] = previous
    else
      ENV.delete("MATTER_JFA_KEEP_BOOTSTRAP_DATASTORE")
    end
  end

  it "serves JFA status commands on a newly commissioned non-Anchor fabric" do
    crypto = Matter::Crypto::StandardCrypto.new
    root_key = crypto.create_key_pair
    icac_key = crypto.create_key_pair
    noc_key = crypto.create_key_pair
    fabric_id = 0xCAFE_u64
    root = Matter::Crypto::MatterCertificate::Builder.root(root_key, 1_u64, Bytes[1], crypto)
    icac = Matter::Crypto::MatterCertificate::Builder.intermediate(
      icac_key.public_key, fabric_id, 2_u64, root_key, 1_u64, Bytes[2], crypto)
    noc = Matter::Crypto::MatterCertificate::Builder.node(
      noc_key.public_key, fabric_id, 3_u64, icac_key, 1_u64, Bytes[3], crypto,
      issuer_icac_id: 2_u64, issuer_certificate: icac)
    fabric = Matter::Fabric.new(fabric_id, 1_u8, 3_u64, root_key.public_key, noc, noc_key,
      Bytes.new(16, 1_u8), intermediate_cert: icac, root_cert: root)
    device = InspectableJointFabricAdministratorDevice.new(storage: Matter::Storage::Memory.new,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)

    device.install_test_fabric(fabric)
    administrator = device.joint_fabric_administrator
    administrator.administrator_fabric_index.should be_nil
    administrator.request_is_case_session = true
    administrator.request_fabric_index = 1_u8
    administrator.icaccsr_request.should eq(Matter::InteractionModel::Status.failsafe_required)
    device.advertised_joint_role.should eq(Matter::MDNS::JointFabricRole::Available)
  end

  it "accepts an SDK-issued Anchor ICAC without a private organizational unit" do
    crypto = Matter::Crypto::StandardCrypto.new
    root_key = crypto.create_key_pair
    icac_key = crypto.create_key_pair
    noc_key = crypto.create_key_pair
    root = Matter::Crypto::MatterCertificate::Builder.root(root_key, 1_u64, Bytes[1], crypto)
    icac = Matter::Crypto::MatterCertificate::Builder.intermediate(
      icac_key.public_key, 0xA100_u64, 2_u64, root_key, 1_u64, Bytes[2], crypto)
    noc = Matter::Crypto::MatterCertificate::Builder.node(
      noc_key.public_key, 0xA100_u64, 3_u64, icac_key, 1_u64, Bytes[3], crypto,
      issuer_icac_id: 2_u64, issuer_certificate: icac,
      case_authenticated_tag: 0xFFFE_0001_u32)
    fabric = Matter::Fabric.new(0xA100_u64, 1_u8, 3_u64, root_key.public_key,
      noc, noc_key, Bytes.new(16, 1_u8), intermediate_cert: icac, root_cert: root,
      cats: [Matter::DataType::CaseAuthenticatedTag.new(0xFFFE_0001_u32)])
    previous = ENV["MATTER_JFA_PROVISIONED_ANCHOR"]?
    ENV["MATTER_JFA_PROVISIONED_ANCHOR"] = "1"
    device = InspectableJointFabricAdministratorDevice.new(storage: Matter::Storage::Memory.new,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    device.anchor_profile_for_spec(fabric).should be_true
    rotated_noc = Matter::Crypto::MatterCertificate::Builder.node(
      noc_key.public_key, 0xA100_u64, 3_u64, icac_key, 2_u64, Bytes[4], crypto,
      issuer_icac_id: 2_u64, issuer_certificate: icac,
      case_authenticated_tag: 0xFFFE_0002_u32)
    rotated = Matter::Fabric.new(0xA100_u64, 1_u8, 3_u64, root_key.public_key,
      rotated_noc, noc_key, Bytes.new(16, 1_u8), intermediate_cert: icac, root_cert: root,
      cats: [Matter::DataType::CaseAuthenticatedTag.new(0xFFFE_0002_u32)])
    device.anchor_profile_for_spec(rotated).should be_true
    expect_raises(ArgumentError, /version number must not be 0/) do
      Matter::DataType::CaseAuthenticatedTag.new(0xFFFE_0000_u32)
    end
  ensure
    if previous
      ENV["MATTER_JFA_PROVISIONED_ANCHOR"] = previous
    else
      ENV.delete("MATTER_JFA_PROVISIONED_ANCHOR")
    end
  end

  it "keeps the bootstrap and joined Administrator services bound to distinct fabrics" do
    crypto = Matter::Crypto::StandardCrypto.new
    b_root_key = crypto.create_key_pair
    b_icac_key = crypto.create_key_pair
    b_noc_key = crypto.create_key_pair
    b_root = Matter::Crypto::MatterCertificate::Builder.root(b_root_key, 1_u64, Bytes[1], crypto)
    b_icac = Matter::Crypto::MatterCertificate::Builder.intermediate(
      b_icac_key.public_key, 0xB100_u64, 2_u64, b_root_key, 1_u64, Bytes[2], crypto, anchor: true)
    b_noc = Matter::Crypto::MatterCertificate::Builder.node(
      b_noc_key.public_key, 0xB100_u64, 0xB102_u64, b_icac_key, 1_u64, Bytes[3], crypto,
      issuer_icac_id: 2_u64, issuer_certificate: b_icac,
      case_authenticated_tag: 0xFFFE_0001_u32)
    b_fabric = Matter::Fabric.new(0xB100_u64, 1_u8, 0xB102_u64, b_root_key.public_key,
      b_noc, b_noc_key, Bytes.new(16, 1_u8), intermediate_cert: b_icac, root_cert: b_root,
      cats: [Matter::DataType::CaseAuthenticatedTag.new(0xFFFE_0001_u32)])
    bootstrap_path = File.join(Dir.tempdir, "matter-jfa-concurrent-#{Random::Secure.hex(6)}.yml")
    bootstrap_store = Matter::Controller::StateStore.new(Matter::Storage::YamlFile.new(bootstrap_path))
    bootstrap_store.save(Matter::Controller::State.new(fabric: Matter::Controller::FabricInfo.new(
      0xB100_u64, 0xB102_u64, b_fabric.ipk, b_root, b_root_key.public_key,
      b_noc, b_noc_key.private_key, root_private_key: b_root_key.private_key,
      intermediate_cert: b_icac, intermediate_private_key: b_icac_key.private_key)))
    bootstrap_store.backend.close

    a_root_key = crypto.create_key_pair
    a_operational_icac_key = crypto.create_key_pair
    a_noc_key = crypto.create_key_pair
    a_root = Matter::Crypto::MatterCertificate::Builder.root(a_root_key, 3_u64, Bytes[4], crypto)
    a_icac = Matter::Crypto::MatterCertificate::Builder.intermediate(
      a_operational_icac_key.public_key, 0xA100_u64, 4_u64, a_root_key, 3_u64, Bytes[5], crypto)
    committed_a_icac = Matter::Crypto::MatterCertificate::Builder.intermediate(
      b_icac_key.public_key, 0xA100_u64, 4_u64, a_root_key, 3_u64, Bytes[7], crypto)
    a_noc = Matter::Crypto::MatterCertificate::Builder.node(
      a_noc_key.public_key, 0xA100_u64, 0xA103_u64, a_operational_icac_key, 2_u64, Bytes[6], crypto,
      issuer_icac_id: 4_u64, issuer_certificate: a_icac,
      case_authenticated_tag: 0xFFFF_0001_u32)
    a_fabric = Matter::Fabric.new(0xA100_u64, 2_u8, 0xA103_u64, a_root_key.public_key,
      a_noc, a_noc_key, Bytes.new(16, 2_u8), intermediate_cert: a_icac, root_cert: a_root,
      cats: [Matter::DataType::CaseAuthenticatedTag.new(0xFFFF_0001_u32)])

    previous_provisioned = ENV["MATTER_JFA_PROVISIONED_ANCHOR"]?
    previous_bootstrap = ENV["MATTER_JFA_BOOTSTRAP_STATE_PATH"]?
    previous_keep = ENV["MATTER_JFA_KEEP_BOOTSTRAP_DATASTORE"]?
    ENV["MATTER_JFA_PROVISIONED_ANCHOR"] = "1"
    ENV["MATTER_JFA_BOOTSTRAP_STATE_PATH"] = bootstrap_path
    ENV["MATTER_JFA_KEEP_BOOTSTRAP_DATASTORE"] = "1"
    backend = Matter::Storage::Memory.new
    device = InspectableJointFabricAdministratorDevice.new(storage: backend,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    device.install_test_fabric(b_fabric)
    device.bootstrap_joint_fabric_administrator.administrator_fabric_index.should eq(1_u8)
    device.bootstrap_joint_fabric_administrator.service.should be_a(Matter::Commissioning::JointFabricAdministratorService)
    device.persistence.write_app_document(MatterJointFabricAdministrator::Device::APP_ICAC_DOCUMENT,
      MatterJointFabricAdministrator::Device::IcacCertificateState.new(committed_a_icac).to_document)
    device.install_test_fabric(a_fabric)
    device.joint_fabric_administrator.administrator_fabric_index.should eq(2_u8)
    device.joint_fabric_administrator.service.as(Matter::Commissioning::JointFabricAdministratorService)
      .cross_signed_icac.should eq(committed_a_icac)
    device.access_control.acl(2_u8).flat_map(&.subjects).should contain(0xFFFF_FFFD_FFFF_0001_u64)
    device.bootstrap_joint_fabric_administrator.administrator_fabric_index.should eq(1_u8)
    device.bootstrap_joint_fabric_administrator.service.should be_a(Matter::Commissioning::JointFabricAdministratorService)
    device.bootstrap_joint_fabric_datastore.joint_fabric_index.should eq(1_u8)
    device.joint_fabric_datastore.joint_fabric_index.should eq(2_u8)
    device.joint_fabric_datastore.access_mode.should eq(Matter::Cluster::JointFabricDatastore::AccessMode::Inactive)

    wrong_joined = InspectableJointFabricAdministratorDevice.new(storage: Matter::Storage::Memory.new,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    wrong_joined.install_test_fabric(b_fabric)
    unrelated_key = crypto.create_key_pair
    wrong_joined.persistence.write_app_document(MatterJointFabricAdministrator::Device::APP_KEY_DOCUMENT,
      MatterJointFabricAdministrator::Device::IcacKeyState.new(
        unrelated_key.private_key, unrelated_key.public_key).to_document)
    wrong_joined.persistence.write_app_document(MatterJointFabricAdministrator::Device::APP_ICAC_DOCUMENT,
      MatterJointFabricAdministrator::Device::IcacCertificateState.new(committed_a_icac).to_document)
    expect_raises(Matter::ConfigurationError, "Joined JFA ICAC private key is unavailable") do
      wrong_joined.install_test_fabric(a_fabric)
    end
    wrong_joined.access_control.acl(2_u8).flat_map(&.subjects)
      .should_not contain(0xFFFF_FFFD_FFFF_0001_u64)

    # The official SDK JFC owns the ICAC signer remotely. Its cross-signed
    # ICAC reuses the commissioned ICAC key but can have a different ICAC ID.
    remote_icac = Matter::Crypto::MatterCertificate::Builder.intermediate(
      a_operational_icac_key.public_key, 0xA100_u64, 5_u64, a_root_key, 3_u64, Bytes[8], crypto)
    previous_remote = ENV["MATTER_JFA_ICAC_CSR_MAILBOX_PATH"]?
    ENV["MATTER_JFA_ICAC_CSR_MAILBOX_PATH"] = File.join(Dir.tempdir, "remote-jfa-csr-#{Random::Secure.hex(6)}")
    remote_joined = InspectableJointFabricAdministratorDevice.new(storage: Matter::Storage::Memory.new,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    remote_joined.install_test_fabric(b_fabric)
    remote_joined.persistence.write_app_document(MatterJointFabricAdministrator::Device::APP_ICAC_DOCUMENT,
      MatterJointFabricAdministrator::Device::IcacCertificateState.new(remote_icac).to_document)
    remote_joined.install_test_fabric(a_fabric)
    remote_joined.joint_fabric_administrator.administrator_fabric_index.should eq(2_u8)
    remote_joined.joint_fabric_administrator.service.as(Matter::Commissioning::JointFabricAdministratorService)
      .cross_signed_icac.should eq(remote_icac)

    wrong_remote = InspectableJointFabricAdministratorDevice.new(storage: Matter::Storage::Memory.new,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    wrong_remote.install_test_fabric(b_fabric)
    wrong_remote.persistence.write_app_document(MatterJointFabricAdministrator::Device::APP_ICAC_DOCUMENT,
      MatterJointFabricAdministrator::Device::IcacCertificateState.new(committed_a_icac).to_document)
    wrong_remote.install_test_fabric(a_fabric)
    wrong_remote.joint_fabric_administrator.administrator_fabric_index.should eq(1_u8)
    if previous_remote
      ENV["MATTER_JFA_ICAC_CSR_MAILBOX_PATH"] = previous_remote
    else
      ENV.delete("MATTER_JFA_ICAC_CSR_MAILBOX_PATH")
    end

    restored = InspectableJointFabricAdministratorDevice.new(storage: backend,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    restored.install_test_fabric(b_fabric)
    restored.install_test_fabric(a_fabric)
    restored.joint_fabric_administrator.administrator_fabric_index.should eq(2_u8)
    restored.bootstrap_joint_fabric_administrator.administrator_fabric_index.should eq(1_u8)
    restored.bootstrap_joint_fabric_administrator.service.should be_a(Matter::Commissioning::JointFabricAdministratorService)
    restored.remove_test_fabric(2_u8)
    restored.bootstrap_joint_fabric_administrator.service.should be_a(Matter::Commissioning::JointFabricAdministratorService)
    restored.advertised_joint_role.should eq(
      Matter::MDNS::JointFabricRole::Administrator |
      Matter::MDNS::JointFabricRole::Anchor |
      Matter::MDNS::JointFabricRole::Datastore)
    restored.persistence.app_document(MatterJointFabricAdministrator::Device::APP_KEY_DOCUMENT).should_not be_nil
    device.remove_test_fabric(1_u8)
    device.joint_fabric_administrator.administrator_fabric_index.should eq(2_u8)
    device.joint_fabric_administrator.service.should be_a(Matter::Commissioning::JointFabricAdministratorService)
    device.persistence.app_document(MatterJointFabricAdministrator::Device::APP_KEY_DOCUMENT).should_not be_nil
  ensure
    if previous_provisioned
      ENV["MATTER_JFA_PROVISIONED_ANCHOR"] = previous_provisioned
    else
      ENV.delete("MATTER_JFA_PROVISIONED_ANCHOR")
    end
    if previous_bootstrap
      ENV["MATTER_JFA_BOOTSTRAP_STATE_PATH"] = previous_bootstrap
    else
      ENV.delete("MATTER_JFA_BOOTSTRAP_STATE_PATH")
    end
    if previous_keep
      ENV["MATTER_JFA_KEEP_BOOTSTRAP_DATASTORE"] = previous_keep
    else
      ENV.delete("MATTER_JFA_KEEP_BOOTSTRAP_DATASTORE")
    end
    File.delete?(bootstrap_path) if bootstrap_path
  end

  it "fails closed without migration attestation trust and accepts explicit production trust" do
    previous = ENV["MATTER_JFA_MIGRATION_TEST_TRUST"]?
    ENV.delete("MATTER_JFA_MIGRATION_TEST_TRUST")
    device = InspectableJointFabricAdministratorDevice.new(storage: Matter::Storage::Memory.new,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)], port: 0)
    expect_raises(Matter::ConfigurationError, /not configured/) do
      device.migration_verifier_for_spec
    end
    expect_raises(Matter::ConfigurationError, /revocation source/) do
      device.migration_attestation_trust = Matter::Controller::AttestationTrustStore.new(
        [Bytes[1]], {"signer" => Bytes[2]})
    end
    fixture = Matter::Controller::AttestationTrustStore.matter_test_fixture
    production_trust = Matter::Controller::AttestationTrustStore.new(
      fixture.paa_certificates, fixture.cd_signers,
      revocation_check: fixture.revocation_check)
    device.migration_attestation_trust = production_trust
    device.migration_verifier_for_spec.should be_a(Matter::Controller::DeviceAttestationVerifier)
    production_trust.allow_test_attestation?.should be_false
  ensure
    if previous
      ENV["MATTER_JFA_MIGRATION_TEST_TRUST"] = previous
    else
      ENV.delete("MATTER_JFA_MIGRATION_TEST_TRUST")
    end
  end

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
    device.node.endpoint(2_u16).as(Matter::Endpoint)
      .has_cluster?(Matter::Cluster::JointFabricDatastore::CLUSTER_ID).should be_true
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
    previous_bootstrap_datastore = ENV["MATTER_JFA_KEEP_BOOTSTRAP_DATASTORE"]?
    ENV["MATTER_JFA_PROVISIONED_ANCHOR"] = "1"
    ENV["MATTER_JFA_BOOTSTRAP_STATE_PATH"] = bootstrap_path
    ENV["MATTER_JFA_KEEP_BOOTSTRAP_DATASTORE"] = "1"
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
    bootstrap_datastore = device.bootstrap_joint_fabric_datastore
    bootstrap_datastore.joint_fabric_index.should eq(1_u8)
    bootstrap_datastore.admin_list.first.node_id.should eq(node_id)
    bootstrap_administrator = device.bootstrap_joint_fabric_administrator
    bootstrap_administrator.administrator_fabric_index.should eq(1_u8)
    bootstrap_administrator.service.should be_a(Matter::Commissioning::JointFabricAdministratorService)
    bootstrap_datastore.request_is_case_session = true
    bootstrap_datastore.read_attribute(Matter::Cluster::JointFabricDatastore::ATTR_NODE_LIST, 1_u8)
      .should be_a(TLV::Any)
    bootstrap_datastore.read_attribute(Matter::Cluster::JointFabricDatastore::ATTR_NODE_LIST, 2_u8)
      .as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAccess)
    state_store = Matter::Controller::StateStore.new(backend)
    anchor_identity = state_store.load.fabric_for(fabric_id, root_key.public_key, node_id)
    anchor_identity.controller_noc.should eq(noc)
    anchor_identity.controller_node_id.should eq(node_id)
    anchor_identity.root_private_key.should eq(root_key.private_key)
    anchor_identity.intermediate_private_key.should eq(icac_key.private_key)
    ENV["MATTER_JFA_BOOTSTRAP_STATE_PATH"] = "#{bootstrap_path}.removed"
    device.install_test_fabric(fabric)
    device.access_control.acl(1_u8).count { |entry| entry.subjects.try(&.includes?(admin_subject)) || false }.should eq(1)
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
    device.bootstrap_joint_fabric_datastore.joint_fabric_index.should be_nil
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
    if previous_bootstrap_datastore
      ENV["MATTER_JFA_KEEP_BOOTSTRAP_DATASTORE"] = previous_bootstrap_datastore
    else
      ENV.delete("MATTER_JFA_KEEP_BOOTSTRAP_DATASTORE")
    end
    File.delete?(bootstrap_path) if bootstrap_path
  end
end
