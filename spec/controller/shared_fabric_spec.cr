require "../spec_helper"
require "../../src/matter/controller"

private alias SharedAclEntry = Matter::Cluster::AccessControl::AccessControlEntry

private class SharedFabricImClient < Matter::Controller::ImClient
  getter entries : Array(SharedAclEntry)
  getter writes : Int32 = 0

  def initialize(@entries : Array(SharedAclEntry))
    super(Matter::Controller::Client.new)
  end

  def close : Nil
    @client.close
  end

  def read_attribute(
    session : Matter::Session::SecureContext,
    peer : Socket::IPAddress,
    endpoint_id : UInt16,
    cluster_id : UInt32,
    attribute_id : UInt32,
  ) : Matter::InteractionModel::ReportDataMessage
    path = Matter::InteractionModel::AttributePath.new(endpoint: endpoint_id, cluster: cluster_id, attribute: attribute_id)
    data = Matter::InteractionModel::AttributeDataIB.new(path: path, data: TLV::Any.from_slice(@entries.to_tlv))
    Matter::InteractionModel::ReportDataMessage.new(attribute_reports: [Matter::InteractionModel::AttributeReportIB.new(attribute_data: data)])
  end

  def write_attribute(
    session : Matter::Session::SecureContext,
    peer : Socket::IPAddress,
    endpoint_id : UInt16,
    cluster_id : UInt32,
    attribute_id : UInt32,
    value : Bytes,
    timed_request : Bool = false,
    suppress_response : Bool = false,
  ) : Matter::InteractionModel::WriteResponseMessage
    @entries = Array(SharedAclEntry).from_tlv(value)
    @writes += 1
    path = Matter::InteractionModel::AttributePath.new(endpoint: endpoint_id, cluster: cluster_id, attribute: attribute_id)
    status = Matter::InteractionModel::StatusIB.new(Matter::InteractionModel::StatusCode::Success.value)
    Matter::InteractionModel::WriteResponseMessage.new([Matter::InteractionModel::AttributeStatusIB.new(path, status)])
  end
end

private def shared_fabric_authority : Matter::Controller::FabricInfo
  crypto = Matter::Crypto::StandardCrypto.new
  root_key = crypto.create_key_pair
  controller_key = crypto.create_key_pair
  root = Matter::Crypto::MatterCertificate::Builder.root(root_key, 1_u64, crypto.random_bytes(8), crypto)
  noc = Matter::Crypto::MatterCertificate::Builder.node(
    public_key: controller_key.public_key,
    fabric_id: 0x1234_u64,
    node_id: 0x100_u64,
    issuer_key: root_key,
    issuer_rcac_id: 1_u64,
    serial: crypto.random_bytes(8),
    crypto: crypto
  )

  Matter::Controller::FabricInfo.new(
    fabric_id: 0x1234_u64,
    controller_node_id: 0x100_u64,
    ipk_value: crypto.random_bytes(16),
    root_cert: root,
    root_public_key: root_key.public_key,
    controller_noc: noc,
    controller_private_key: controller_key.private_key,
    root_private_key: root_key.private_key
  )
end

describe Matter::Controller::SharedFabric do
  it "accepts a longer JCM fail-safe within the device's cumulative limit" do
    store = Matter::Controller::StateStore.new(Matter::Storage::Memory.new)
    Matter::Controller::Commissioning::Commissioner.new(store, fail_safe_expiry_seconds: 900_u16).close
    expect_raises(Matter::ConfigurationError, /fail-safe expiry/) do
      Matter::Controller::Commissioning::Commissioner.new(store, fail_safe_expiry_seconds: 901_u16)
    end
  end

  it "creates an anchor controller NOC carrying the Anchor CAT" do
    store = Matter::Controller::StateStore.new(Matter::Storage::Memory.new)
    client = Matter::Controller::Client.new
    commissioner = Matter::Controller::Commissioning::Commissioner.new(
      store, client, controller_cats: [0xFFFE_0001_u32]
    )
    fabric = commissioner.create_fabric(controller_node_id: 0x101_u64)
    subjects = Matter::Crypto::MatterCertificate.subject_ids_from_tlv(fabric.controller_noc)

    subjects.first.should eq(0x101_u64)
    subjects.size.should eq(2)
    icac = fabric.intermediate_cert.as(Bytes)
    Matter::Crypto::MatterCertificate.from_slice(fabric.controller_noc).issuer.icac_id.should eq(3_u64)
    Matter::Crypto::MatterCertificate::Validation.verify_chain(fabric.controller_noc, icac, fabric.root_public_key)
    fabric.intermediate_authority_key.public_key.should eq(Matter::Crypto::MatterCertificate.public_key_from_tlv(icac))
    Matter::Controller::SharedFabric.install(store, fabric)
    saved = store.load.fabric.as(Matter::Controller::FabricInfo)
    saved.controller_noc.should eq(fabric.controller_noc)
    saved.intermediate_private_key.should eq(fabric.intermediate_private_key)
  ensure
    client.try(&.close)
  end

  it "issues an independent controller identity on the same fabric" do
    authority = shared_fabric_authority
    delegated = Matter::Controller::SharedFabric.delegate(authority, 0x101_u64)

    delegated.fabric_id.should eq(authority.fabric_id)
    delegated.ipk_value.should eq(authority.ipk_value)
    delegated.root_public_key.should eq(authority.root_public_key)
    delegated.controller_node_id.should eq(0x101_u64)
    delegated.controller_private_key.should_not eq(authority.controller_private_key)
    delegated.root_private_key.should be_nil

    Matter::Crypto::MatterCertificate::Validation.verify_chain(
      delegated.controller_noc, nil, authority.root_public_key
    )
    certificate = Matter::Crypto::MatterCertificate.from_slice(delegated.controller_noc)
    certificate.node_id.should eq(0x101_u64)
    certificate.fabric_id.should eq(authority.fabric_id)
  end

  it "installs an issued identity into an empty controller store" do
    delegated = Matter::Controller::SharedFabric.delegate(shared_fabric_authority, 0x101_u64)
    store = Matter::Controller::StateStore.new(Matter::Storage::Memory.new)

    Matter::Controller::SharedFabric.install(store, delegated)
    loaded = store.load
    loaded.fabric.as(Matter::Controller::FabricInfo).controller_noc.should eq(delegated.controller_noc)
    loaded.commissioner_node_id.should eq(0x101_u64)

    expect_raises(Matter::ConfigurationError) do
      Matter::Controller::SharedFabric.install(store, delegated)
    end
  end

  it "installs another fabric without replacing the selected identity or peers" do
    first = Matter::Controller::SharedFabric.delegate(shared_fabric_authority, 0x101_u64)
    second = Matter::Controller::SharedFabric.delegate(shared_fabric_authority, 0x102_u64)
    store = Matter::Controller::StateStore.new(Matter::Storage::Memory.new)

    Matter::Controller::SharedFabric.install(store, first)
    state = store.load
    state.record_node(first.fabric_id, Matter::Controller::NodeInfo.new(0x200_u64, "192.0.2.1"), first.root_public_key)
    store.save(state)
    Matter::Controller::SharedFabric.install(store, second)

    loaded = store.load
    loaded.fabrics.size.should eq(2)
    loaded.fabric.as(Matter::Controller::FabricInfo).controller_node_id.should eq(first.controller_node_id)
    loaded.nodes[0x200_u64].address.should eq("192.0.2.1")
    loaded.nodes_for(second.fabric_id, second.root_public_key).should be_empty
  end

  it "stores two controller identities on one logical fabric" do
    authority = shared_fabric_authority
    first = Matter::Controller::SharedFabric.delegate(authority, 0x101_u64)
    second = Matter::Controller::SharedFabric.delegate(authority, 0x102_u64)
    store = Matter::Controller::StateStore.new(Matter::Storage::Memory.new)
    Matter::Controller::SharedFabric.install(store, first)
    Matter::Controller::SharedFabric.install(store, second)

    state = store.load
    expect_raises(Matter::ConfigurationError, /ambiguous/) do
      state.fabric_for(first.fabric_id, first.root_public_key)
    end
    state.select_fabric(second.fabric_id, second.root_public_key, second.controller_node_id)
    state.fabric.as(Matter::Controller::FabricInfo).controller_node_id.should eq(second.controller_node_id)
    state.record_node(second.fabric_id, Matter::Controller::NodeInfo.new(0x200_u64), second.root_public_key, second.controller_node_id)
    state.nodes_for(first.fabric_id, first.root_public_key, first.controller_node_id).should be_empty
  end

  it "rejects a controller private key that does not belong to its NOC" do
    delegated = Matter::Controller::SharedFabric.delegate(shared_fabric_authority, 0x101_u64)
    wrong_key = Matter::Crypto::StandardCrypto.new.create_key_pair
    invalid = Matter::Controller::FabricInfo.new(
      fabric_id: delegated.fabric_id,
      controller_node_id: delegated.controller_node_id,
      ipk_value: delegated.ipk_value,
      root_cert: delegated.root_cert,
      root_public_key: delegated.root_public_key,
      controller_noc: delegated.controller_noc,
      controller_private_key: wrong_key.private_key
    )

    expect_raises(Matter::AuthenticationError) do
      Matter::Controller::SharedFabric.install(
        Matter::Controller::StateStore.new(Matter::Storage::Memory.new), invalid
      )
    end
  end

  it "issues device certificates through an authority kept outside the delegated store" do
    authority = shared_fabric_authority
    issuer = Matter::Controller::SharedFabric.issuer(authority)
    device_key = Matter::Crypto::StandardCrypto.new.create_key_pair
    noc = issuer.call(authority.fabric_id, 0x200_u64, device_key.public_key)

    Matter::Crypto::MatterCertificate::Validation.verify_chain(noc, nil, authority.root_public_key)
    certificate = Matter::Crypto::MatterCertificate.from_slice(noc)
    certificate.node_id.should eq(0x200_u64)
    certificate.ec_public_key.should eq(device_key.public_key)

    expect_raises(Matter::CertificateError) do
      issuer.call(0x999_u64, 0x200_u64, device_key.public_key)
    end
  end

  it "requires a separate issuer before commissioning from a delegated store" do
    delegated = Matter::Controller::SharedFabric.delegate(shared_fabric_authority, 0x101_u64)
    store = Matter::Controller::StateStore.new(Matter::Storage::Memory.new)
    Matter::Controller::SharedFabric.install(store, delegated)
    client = Matter::Controller::Client.new
    commissioner = Matter::Controller::Commissioning::Commissioner.new(store, client)
    pairing_code = Matter::SetupPayload.generate_manual_code(0xF00_u16, 20202021_u32)

    expect_raises(Matter::ConfigurationError, /certificate issuer/) do
      commissioner.pairing_code(0x200_u64, pairing_code)
    end
  ensure
    client.try(&.close)
  end

  it "rejects duplicate controller IDs and a missing signing key" do
    authority = shared_fabric_authority
    expect_raises(Matter::ConfigurationError) do
      Matter::Controller::SharedFabric.delegate(authority, authority.controller_node_id)
    end
    delegated = Matter::Controller::SharedFabric.delegate(authority, 0x101_u64)
    expect_raises(Matter::ConfigurationError) do
      Matter::Controller::SharedFabric.delegate(delegated, 0x102_u64)
    end
  end

  it "adds an administrator ACL entry while preserving existing entries" do
    admin = SharedAclEntry.new(
      privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer,
      auth_mode: Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
      subjects: [0x100_u64],
      targets: nil,
      fabric_index: 1_u8
    )
    im = SharedFabricImClient.new([admin])
    session = Matter::Session::SecureContext.new(
      session_id: 1_u16,
      peer_session_id: 1_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16),
      decryption_key: Bytes.new(16)
    )
    peer = Socket::IPAddress.new("127.0.0.1", 5540)

    Matter::Controller::SharedFabric.grant_admin(im, session, peer, 0x101_u64)
    im.entries.size.should eq(2)
    im.entries[0].subjects.should eq([0x100_u64])
    im.entries[1].subjects.should eq([0x101_u64])
    im.entries[1].fabric_index.should be_nil

    Matter::Controller::SharedFabric.grant_admin(im, session, peer, 0x101_u64)
    im.writes.should eq(1)
  ensure
    im.try(&.close)
  end
end
