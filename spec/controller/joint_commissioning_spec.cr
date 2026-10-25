require "../spec_helper"
require "../../src/matter/controller/joint_commissioning"

private class JointTestTrust < Matter::Controller::VidVerification::OperationalTrustAnchors
  def trusted_root?(vendor_id : UInt16, root_certificate : Bytes) : Bool
    false
  end

  def verify_statement?(vendor_id : UInt16, signer_skid : Bytes, statement_tbs : Bytes,
                        signature : Bytes, vvsc : Bytes?) : Bool
    false
  end
end

private class JointRecoveryPort < Matter::Controller::JointCommissioning::RecoveryPort
  property observed : Array(Matter::Cluster::OperationalCredentials::Tlv::FabricDescriptor)

  def initialize(@observed, @on_read : Proc(Nil)? = nil)
  end

  def fabrics(fabric : Matter::Controller::FabricInfo, node_id : UInt64,
              peer : Socket::IPAddress) : Array(Matter::Cluster::OperationalCredentials::Tlv::FabricDescriptor)
    @on_read.try(&.call)
    @observed
  end
end

private class JointDescriptorIm < Matter::Controller::ImClient
  def initialize(client : Matter::Controller::Client)
    super(client)
  end

  def read_attribute(session : Matter::Session::SecureContext, peer : Socket::IPAddress,
                     endpoint_id : UInt16, cluster_id : UInt32, attribute_id : UInt32,
                     fabric_filtered : Bool = true) : Matter::InteractionModel::ReportDataMessage
    value = if cluster_id == Matter::Cluster::JointFabricAdministrator::CLUSTER_ID
              2_u8.to_tlv
            elsif cluster_id == Matter::Cluster::JointFabricDatastore::CLUSTER_ID
              group = Matter::Cluster::JointFabricDatastore::DatastoreGroupInformationEntryStruct
              privilege = Matter::Cluster::JointFabricDatastore::DatastoreAccessControlEntryPrivilegeEnum::Administer
              [group.new(1_u64, "Administrators", nil, 0xFFFF_u16, 1_u16, privilege),
               group.new(2_u64, "Anchor", nil, 0xFFFE_u16, 1_u16, privilege)].to_tlv
            elsif endpoint_id == 0_u16
              case attribute_id
              when Matter::Cluster::Descriptor::ATTR_PARTS_LIST
                [1_u16].to_tlv
              when Matter::Cluster::Descriptor::ATTR_DEVICE_TYPE_LIST
                [Matter::Cluster::Descriptor::DeviceTypeStruct.new(Matter::DeviceType::ROOT_NODE, 1_u16)].to_tlv
              else
                [Matter::Cluster::Descriptor::CLUSTER_ID].to_tlv
              end
            else
              case attribute_id
              when Matter::Cluster::Descriptor::ATTR_PARTS_LIST
                ([] of UInt16).to_tlv
              when Matter::Cluster::Descriptor::ATTR_DEVICE_TYPE_LIST
                [Matter::Cluster::Descriptor::DeviceTypeStruct.new(Matter::DeviceType::JOINT_FABRIC_ADMINISTRATOR, 1_u16)].to_tlv
              else
                [Matter::Cluster::Descriptor::CLUSTER_ID,
                 Matter::Cluster::JointFabricAdministrator::CLUSTER_ID].to_tlv
              end
            end
    path = Matter::InteractionModel::AttributePath.new(endpoint: endpoint_id, cluster: cluster_id, attribute: attribute_id)
    data = Matter::InteractionModel::AttributeDataIB.new(path: path, data: TLV::Any.from_slice(value))
    Matter::InteractionModel::ReportDataMessage.new(
      attribute_reports: [Matter::InteractionModel::AttributeReportIB.new(attribute_data: data)])
  end
end

# The official SDK locates a JFA from a wildcard AdministratorFabricIndex
# report. A participant can expose that path even when Descriptor traversal
# does not enumerate its Administrator endpoint to this fabric.
private class JointSparseDescriptorIm < JointDescriptorIm
  def initialize(client : Matter::Controller::Client, @extra_endpoint : UInt16? = nil)
    super(client)
  end

  def read_attribute(session : Matter::Session::SecureContext, peer : Socket::IPAddress,
                     endpoint_id : UInt16, cluster_id : UInt32, attribute_id : UInt32,
                     fabric_filtered : Bool = true) : Matter::InteractionModel::ReportDataMessage
    if endpoint_id == 0_u16 && cluster_id == Matter::Cluster::Descriptor::CLUSTER_ID &&
       attribute_id == Matter::Cluster::Descriptor::ATTR_PARTS_LIST
      path = Matter::InteractionModel::AttributePath.new(endpoint: 0_u16, cluster: cluster_id, attribute: attribute_id)
      data = Matter::InteractionModel::AttributeDataIB.new(path: path, data: TLV::Any.from_slice(([] of UInt16).to_tlv))
      return Matter::InteractionModel::ReportDataMessage.new(
        attribute_reports: [Matter::InteractionModel::AttributeReportIB.new(attribute_data: data)])
    end
    super
  end

  def read(session : Matter::Session::SecureContext, peer : Socket::IPAddress,
           attribute_paths : Array(Matter::InteractionModel::AttributePath) = [] of Matter::InteractionModel::AttributePath,
           event_paths : Array(Matter::InteractionModel::EventPath) = [] of Matter::InteractionModel::EventPath,
           event_filters : Array(Matter::InteractionModel::EventFilterIB)? = nil,
           fabric_filtered : Bool = true) : Matter::InteractionModel::ReportDataMessage
    path = attribute_paths.first?
    if path && path.endpoint.nil? && path.cluster == Matter::Cluster::JointFabricAdministrator::CLUSTER_ID &&
       path.attribute == Matter::Cluster::JointFabricAdministrator::ATTR_ADMINISTRATOR_FABRIC_INDEX
      concrete = Matter::InteractionModel::AttributePath.new(endpoint: 1_u16, cluster: path.cluster, attribute: path.attribute)
      data = Matter::InteractionModel::AttributeDataIB.new(path: concrete, data: TLV::Any.from_slice(2_u8.to_tlv))
      reports = [Matter::InteractionModel::AttributeReportIB.new(attribute_data: data)]
      if endpoint = @extra_endpoint
        extra_path = Matter::InteractionModel::AttributePath.new(endpoint: endpoint, cluster: path.cluster, attribute: path.attribute)
        extra_data = Matter::InteractionModel::AttributeDataIB.new(path: extra_path, data: TLV::Any.from_slice(2_u8.to_tlv))
        reports << Matter::InteractionModel::AttributeReportIB.new(attribute_data: extra_data)
      end
      return Matter::InteractionModel::ReportDataMessage.new(
        attribute_reports: reports)
    end
    super
  end
end

# A removed Administrator can remain in Descriptor PartsList with a null
# AdministratorFabricIndex while another Administrator is still active.
private class JointStaleDescriptorIm < JointDescriptorIm
  def read_attribute(session : Matter::Session::SecureContext, peer : Socket::IPAddress,
                     endpoint_id : UInt16, cluster_id : UInt32, attribute_id : UInt32,
                     fabric_filtered : Bool = true) : Matter::InteractionModel::ReportDataMessage
    value = if cluster_id == Matter::Cluster::Descriptor::CLUSTER_ID &&
               endpoint_id == 0_u16 && attribute_id == Matter::Cluster::Descriptor::ATTR_PARTS_LIST
              [1_u16, 2_u16].to_tlv
            elsif cluster_id == Matter::Cluster::JointFabricAdministrator::CLUSTER_ID && endpoint_id == 1_u16
              nil.to_tlv
            end
    if value
      path = Matter::InteractionModel::AttributePath.new(endpoint: endpoint_id, cluster: cluster_id, attribute: attribute_id)
      data = Matter::InteractionModel::AttributeDataIB.new(path: path, data: TLV::Any.from_slice(value))
      return Matter::InteractionModel::ReportDataMessage.new(
        attribute_reports: [Matter::InteractionModel::AttributeReportIB.new(attribute_data: data)])
    end
    super
  end
end

private alias JointAsn1 = Matter::Crypto::MatterCertificate::Asn1

private def joint_root_with_extra_subject(root : Bytes, key : Matter::Crypto::Key,
                                          crypto : Matter::Crypto::CryptoBase) : Bytes
  fields = TLV::Any.from_slice(root).as_structure
  subject = fields[JointAsn1::Field::Subject.value].as_list.dup
  subject << TLV::Any.new("Extended Anchor Root", JointAsn1::Dn::CommonName.value)
  fields[JointAsn1::Field::Subject.value] = TLV::Any.new(subject, JointAsn1::Field::Subject.value)
  fields[JointAsn1::Field::Issuer.value] = TLV::Any.new(subject.dup, JointAsn1::Field::Issuer.value)
  signature = crypto.sign_ecdsa(key, JointAsn1.to_unsigned_asn1(TLV::Any.new(fields, nil)))
  fields[JointAsn1::Field::Signature.value] = TLV::Any.new(signature, JointAsn1::Field::Signature.value)
  TLV::Any.new(fields, nil).to_slice
end

describe Matter::Controller::JointCommissioning do
  crypto = Matter::Crypto::StandardCrypto.new
  root_key = crypto.create_key_pair
  joining_icac_key = crypto.create_key_pair
  fabric_id = 0x1234_u64
  root = Matter::Crypto::MatterCertificate::Builder.root(root_key, 1_u64, Bytes[0x01], crypto)

  it "cross-signs only a CSR from the authenticated joining ICAC key" do
    csr = Matter::Crypto::Pkcs10.create(joining_icac_key, crypto)
    icac = Matter::Controller::JointCommissioning.cross_sign_icac(
      root, root_key, fabric_id, joining_icac_key.public_key, csr, 2_u64, crypto
    )
    parsed = Matter::Crypto::MatterCertificate.from_slice(icac)
    parsed.subject.fabric_id.should eq(fabric_id)
    parsed.subject.icac_id.should eq(2_u64)
    parsed.ec_public_key.should eq(joining_icac_key.public_key)
    Matter::Crypto::MatterCertificate::Validation.verify_signature(icac, root_key.public_key)
    Matter::Crypto::MatterCertificate::Validation.verify_issued_by(icac, root)

    other = crypto.create_key_pair
    expect_raises(Matter::CertificateError) do
      Matter::Controller::JointCommissioning.cross_sign_icac(
        root, root_key, fabric_id, other.public_key, csr, 2_u64, crypto
      )
    end
  end

  it "cross-signs an ICAC under the complete subject DN of an external Anchor root" do
    csr = Matter::Crypto::Pkcs10.create(joining_icac_key, crypto)
    external_root = joint_root_with_extra_subject(root, root_key, crypto)
    Matter::Crypto::MatterCertificate::Validation.verify_root(external_root)
    Matter::Crypto::MatterCertificate::Validation.verify_signature(external_root, root_key.public_key)
    Matter::Crypto::MatterCertificate::Validation.verify_issued_by(external_root, external_root)

    icac = Matter::Controller::JointCommissioning.cross_sign_icac(
      external_root, root_key, fabric_id, joining_icac_key.public_key, csr, 2_u64, crypto)
    Matter::Crypto::MatterCertificate::Validation.verify_issued_by(icac, external_root)
    fields = TLV::Any.from_slice(icac).as_structure
    root_fields = TLV::Any.from_slice(external_root).as_structure
    fields[JointAsn1::Field::Issuer.value].as_list.map(&.to_slice)
      .should eq(root_fields[JointAsn1::Field::Subject.value].as_list.map(&.to_slice))
  end

  it "rejects a modified ICAC CSR signature" do
    csr = Matter::Crypto::Pkcs10.create(joining_icac_key, crypto).dup
    csr[csr.size - 1] ^= 1_u8
    expect_raises(Matter::AuthenticationError) do
      Matter::Crypto::Pkcs10.verify(csr, joining_icac_key.public_key, crypto)
    end
  end

  it "registers an Administrator once and accepts an exact retry" do
    datastore = Matter::Cluster::JointFabricDatastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    request = Matter::Cluster::JointFabricDatastore::AddAdminRequest.new(
      9_u64, "Joining Administrator", 0x1234_u16, Bytes[1, 2, 3]
    )
    Matter::Controller::JointCommissioning.add_admin_once(datastore, request)
    Matter::Controller::JointCommissioning.add_admin_once(datastore, request)
    datastore.admin_list.size.should eq(1)
    conflicting = Matter::Cluster::JointFabricDatastore::AddAdminRequest.new(
      9_u64, "Another Administrator", 0x1234_u16, Bytes[1, 2, 3]
    )
    expect_raises(Matter::CommissioningError) do
      Matter::Controller::JointCommissioning.add_admin_once(datastore, conflicting)
    end
  end

  it "resumes post-commissioning registration after a storage failure" do
    controller_key = crypto.create_key_pair
    fabric = Matter::Controller::FabricInfo.new(
      fabric_id: fabric_id,
      controller_node_id: 5_u64,
      ipk_value: Bytes.new(16),
      root_cert: root,
      root_public_key: root_key.public_key,
      controller_noc: Bytes.empty,
      controller_private_key: controller_key.private_key
    )
    state = Matter::Controller::State.new
    state.install_fabric(fabric)
    state.record_node(fabric_id, Matter::Controller::NodeInfo.new(9_u64), root_key.public_key, 5_u64)
    pending = Matter::Controller::JointCommissioning::PendingRegistration.new(
      fabric_id, 5_u64, root_key.public_key, 9_u64, 0x1234_u16, "Joining Administrator", Bytes[1, 2, 3]
    )
    datastore = Matter::Cluster::JointFabricDatastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    fail_persist = true
    saved_pending = pending.as(Matter::Controller::JointCommissioning::PendingRegistration?)
    hooks = Matter::Controller::JointCommissioning::CommissionerHooks.new(
      1_u8, 1_u16, "Joining Administrator", 1_u16, 1_u16, 2_u64,
      JointTestTrust.new,
      ->(_im : Matter::Controller::ImClient, _session : Matter::Session::SecureContext, _peer : Socket::IPAddress, _joiner : Matter::Controller::JointCommissioning::VerifiedJoiner) { true },
      ->(_joiner : Matter::Controller::JointCommissioning::VerifiedJoiner) { true },
      ->(_fabric : Matter::Controller::FabricInfo, _node : UInt64, _key : Bytes, _cat : UInt32) { Bytes.empty },
      ->(request : Matter::Cluster::JointFabricDatastore::AddAdminRequest) {
        Matter::Controller::JointCommissioning.add_admin_once(datastore, request); nil
      },
      ->(_node : UInt64, _icac : Bytes) {
        raise Matter::CommissioningError.new("storage unavailable") if fail_persist
        nil
      },
      ->(value : Matter::Controller::JointCommissioning::PendingRegistration?) { saved_pending = value; nil },
      pending
    )
    expect_raises(Matter::CommissioningError) { hooks.resume_pending(state) }
    datastore.admin_list.size.should eq(1)
    saved_pending.should_not be_nil
    fail_persist = false
    hooks.resume_pending(state).should be_true
    datastore.admin_list.size.should eq(1)
    saved_pending.should be_nil
    hooks.resume_pending(state).should be_false
  end

  it "discovers the Administrator endpoint and reads its existing fabric index" do
    client = Matter::Controller::Client.new
    im = JointDescriptorIm.new(client)
    session = Matter::Session::SecureContext.new(
      session_id: 1_u16, peer_session_id: 2_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16), decryption_key: Bytes.new(16)
    )
    peer = Socket::IPAddress.new("127.0.0.1", 5540)
    endpoint = Matter::Controller::JointCommissioning.discover_administrator_endpoint(im, session, peer)
    endpoint.should eq(1_u16)
    Matter::Controller::JointCommissioning.read_administrator_fabric_index(im, session, peer, endpoint).should eq(2_u8)
    Matter::Controller::JointCommissioning.read_joint_cat_versions(im, session, peer, endpoint).should eq({1_u16, 1_u16})
    client.close
  end

  it "skips a stale Descriptor Administrator with a null fabric index" do
    client = Matter::Controller::Client.new
    im = JointStaleDescriptorIm.new(client)
    session = Matter::Session::SecureContext.new(
      session_id: 1_u16, peer_session_id: 2_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16), decryption_key: Bytes.new(16)
    )
    peer = Socket::IPAddress.new("127.0.0.1", 5540)
    Matter::Controller::JointCommissioning.discover_administrator_endpoint(im, session, peer).should eq(2_u16)
    expect_raises(Matter::AuthenticationError, /AdministratorFabricIndex is invalid/) do
      Matter::Controller::JointCommissioning.read_administrator_fabric_index(im, session, peer, 1_u16)
    end
    Matter::Controller::JointCommissioning.read_administrator_fabric_index(im, session, peer, 2_u16).should eq(2_u8)
    client.close
  end

  it "discovers an SDK Administrator from a wildcard JFA attribute when Descriptor traversal misses it" do
    client = Matter::Controller::Client.new
    im = JointSparseDescriptorIm.new(client)
    session = Matter::Session::SecureContext.new(
      session_id: 1_u16, peer_session_id: 2_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16), decryption_key: Bytes.new(16)
    )
    peer = Socket::IPAddress.new("127.0.0.1", 5540)
    Matter::Controller::JointCommissioning.discover_administrator_endpoint(im, session, peer).should eq(1_u16)
    client.close
  end

  it "rejects ambiguous wildcard Administrator endpoints" do
    client = Matter::Controller::Client.new
    im = JointSparseDescriptorIm.new(client, 2_u16)
    session = Matter::Session::SecureContext.new(
      session_id: 1_u16, peer_session_id: 2_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16), decryption_key: Bytes.new(16)
    )
    peer = Socket::IPAddress.new("127.0.0.1", 5540)
    expect_raises(Matter::AuthenticationError, /no Joint Fabric Administrator endpoint/) do
      Matter::Controller::JointCommissioning.discover_administrator_endpoint(im, session, peer)
    end
    client.close
  end

  it "requires a stored RCAC before outbound Anchor verification" do
    key = crypto.create_key_pair
    noc = Matter::Crypto::MatterCertificate::Builder.node(
      key.public_key, fabric_id, 5_u64, root_key, 1_u64, Bytes[0x09], crypto
    )
    fabric = Matter::Fabric.new(fabric_id: fabric_id, fabric_index: 1_u8,
      node_id: 5_u64, root_public_key: root_key.public_key,
      operational_cert: noc, operational_key: key, ipk: Bytes.new(16))
    expect_raises(Matter::ConfigurationError) do
      Matter::Controller::JointCommissioning.verify_anchor_from_fabric(
        fabric, 9_u64, Socket::IPAddress.new("127.0.0.1", 5540), JointTestTrust.new
      )
    end
  end

  it "uses a supplied client's source port for outbound Anchor verification without closing it" do
    node_key = crypto.create_key_pair
    noc = Matter::Crypto::MatterCertificate::Builder.node(
      node_key.public_key, fabric_id, 5_u64, root_key, 1_u64, Bytes[0x10], crypto
    )
    fabric = Matter::Fabric.new(fabric_id, 1_u8, 5_u64, root_key.public_key,
      noc, node_key, Bytes.new(16), root_cert: root)
    client = Matter::Controller::Client.new(unsecured_source_node_id: fabric.node_id)
    listener = UDPSocket.new(Socket::Family::INET6)
    listener.bind("::1", 0)
    listener.read_timeout = 2.seconds
    peer = Socket::IPAddress.new("::1", listener.local_address.port)
    adopted = false
    result = Channel(Exception?).new(1)
    spawn do
      Matter::Controller::JointCommissioning.verify_anchor_from_fabric(
        fabric, 9_u64, peer, JointTestTrust.new,
        timeout: 100.milliseconds, client: client,
        on_verified_session: ->(_session : Matter::Session::SecureContext) { adopted = true }
      )
      result.send(nil)
    rescue ex
      result.send(ex)
    end
    _, sender = listener.receive(Bytes.new(1280))
    sender.port.should eq(client.transport.port)
    result.receive.should be_a(Matter::TimeoutError)
    adopted.should be_false
    client.transport.as(Matter::Transport::UDPTransport).socket.closed?.should be_false
  ensure
    listener.try(&.close)
    client.try(&.close)
  end

  it "bootstraps an Anchor ICAC and Administrator identity with both CATs" do
    bootstrap = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      0x1234_u64, 5_u64, 0xFFF1_u16, crypto: crypto
    )
    fabric = bootstrap.fabric
    icac = fabric.intermediate_cert.as(Bytes)
    String.new(icac).includes?("jf-anchor-icac").should be_true
    Matter::Crypto::MatterCertificate::Validation.verify_chain(
      fabric.controller_noc, icac, fabric.root_public_key
    )
    subjects = Matter::Crypto::MatterCertificate.subject_ids_from_tlv(fabric.controller_noc)
    subjects.should contain(0xFFFF_FFFD_FFFF_0001_u64)
    subjects.should contain(0xFFFF_FFFD_FFFE_0001_u64)
    administrator_key = crypto.create_key_pair
    noc = bootstrap.issue_anchor_administrator_noc(9_u64, administrator_key.public_key, crypto: crypto)
    Matter::Crypto::MatterCertificate::Validation.verify_chain(noc, icac, fabric.root_public_key)
    Matter::Controller::JointCommissioning.require_administrator_cat!(noc, 1_u16)
    expect_raises(Matter::AuthenticationError, /current Administrator CAT/) do
      Matter::Controller::JointCommissioning.require_administrator_cat!(noc, 2_u16)
    end
  end

  it "accepts an explicitly provisioned IPK without retaining the caller's buffer" do
    ipk = "temporary ipk 01".to_slice.dup
    fabric = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      0x1234_u64, 5_u64, 0xFFF1_u16, crypto: crypto, ipk_value: ipk).fabric
    fabric.ipk_value.should eq(ipk)
    ipk[0] = 0_u8
    fabric.ipk_value[0].should eq('t'.ord.to_u8)
    expect_raises(Matter::ConfigurationError, /IPK must be 16 bytes/) do
      Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
        0x1234_u64, 5_u64, 0xFFF1_u16, crypto: crypto, ipk_value: Bytes[1])
    end
  end

  it "wires persistent registration and an Administrator CAT NOC through the high-level workflow" do
    joint = Matter::Controller::JointCommissioning
    bootstrap = joint.bootstrap_anchor_fabric(0x4567_u64, 5_u64, 0xFFF1_u16, crypto: crypto)
    fabric = bootstrap.fabric
    store = Matter::Controller::StateStore.new(Matter::Storage::Memory.new)
    state = store.load
    state.install_fabric(fabric)
    state.record_node(fabric.fabric_id, Matter::Controller::NodeInfo.new(9_u64),
      fabric.root_public_key, fabric.controller_node_id)
    store.save(state)
    pending = Matter::Controller::JointCommissioning::PendingRegistration.new(fabric.fabric_id, fabric.controller_node_id,
      fabric.root_public_key, 9_u64, 0xFFF2_u16, "Joining Administrator", Bytes[1, 2, 3])
    key = "#{fabric.fabric_id.to_s(16)}-#{fabric.root_public_key.hexstring}-#{fabric.controller_node_id.to_s(16)}"
    store.backend.write("joint_commissioning", "pending-#{key}", pending.to_document)
    datastore = Matter::Cluster::JointFabricDatastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    workflow = Matter::Controller::JointCommissioning::Workflow.new(store, fabric.fabric_id, fabric.root_public_key,
      fabric.controller_node_id, 1_u8, 1_u16, "Joining Administrator", 1_u16, 1_u16,
      2_u64, JointTestTrust.new,
      ->(_im : Matter::Controller::ImClient, _session : Matter::Session::SecureContext, _peer : Socket::IPAddress, _joiner : Matter::Controller::JointCommissioning::VerifiedJoiner) { true },
      ->(_joiner : Matter::Controller::JointCommissioning::VerifiedJoiner) { true },
      ->(request : Matter::Cluster::JointFabricDatastore::AddAdminRequest) {
        joint.add_admin_once(datastore, request); nil
      },
      ->(_fabric : Matter::Controller::FabricInfo, _node : UInt64, _peer : Socket::IPAddress, _endpoint : UInt16, _key : Bytes, _icac_id : UInt64) { Bytes.empty })
    workflow.resume_pending.should be_true
    workflow.stored_icac(9_u64).should eq(Bytes[1, 2, 3])
    datastore.admin_list.size.should eq(1)
    workflow.resume_pending.should be_false
    orphan = Matter::Controller::JointCommissioning::PendingRegistration.new(
      fabric.fabric_id, fabric.controller_node_id, fabric.root_public_key,
      11_u64, 0xFFF2_u16, "Unfinished", Bytes[4, 5, 6])
    store.backend.write("joint_commissioning", "pending-#{key}", orphan.to_document)
    expect_raises(Matter::CommissioningError, /still pending/) do
      workflow.commission(12_u64, "invalid manual code")
    end
    store.backend.delete("joint_commissioning", "pending-#{key}")

    registrar_client = Matter::Controller::Client.new
    registrar = Matter::Controller::JointCommissioning::RemoteDatastoreRegistrar.new(
      store, registrar_client, fabric.fabric_id, fabric.root_public_key,
      fabric.controller_node_id, 5_u64, 1_u16)
    registrar.callback.should be_a(Proc(Matter::Cluster::JointFabricDatastore::AddAdminRequest, Nil))

    joining_key = crypto.create_key_pair
    noc = joint.issue_administrator_noc(fabric, 10_u64, joining_key.public_key, 0xFFFF_0001_u32, crypto)
    Matter::Crypto::MatterCertificate::Validation.verify_chain(noc,
      fabric.intermediate_cert.as(Bytes), fabric.root_public_key)
    Matter::Crypto::MatterCertificate.subject_ids_from_tlv(noc).should contain(0xFFFF_FFFD_FFFF_0001_u64)
    cross_signed = Matter::Crypto::MatterCertificate::Builder.intermediate(
      joining_key.public_key, fabric.fabric_id, 2_u64,
      fabric.certificate_authority_key, 1_u64, Bytes[0x0A], crypto)
    joint.validate_cross_signed_icac(cross_signed, fabric, joining_key.public_key, 2_u64)
    expect_raises(Matter::CertificateError) do
      joint.validate_cross_signed_icac(cross_signed, fabric, joining_key.public_key, 4_u64)
    end
    registrar_client.close
    workflow.close
  end

  it "regenerates colliding Joint Fabric IDs and rejects invalid or locally used IDs before PASE" do
    joint = Matter::Controller::JointCommissioning
    candidates = [9_u64, 0_u64, Matter::DataType::NodeId::JOINT_FABRIC_EXCLUSIVE_MAXIMUM, 11_u64]
    joint.allocate_node_id([9_u64], -> { candidates.shift }).should eq(11_u64)
    expect_raises(Matter::ConfigurationError, /Anchor fabric identity/) do
      joint.bootstrap_anchor_fabric(0x4570_u64,
        Matter::DataType::NodeId::JOINT_FABRIC_EXCLUSIVE_MAXIMUM, 0xFFF1_u16, crypto: crypto)
    end

    fabric = joint.bootstrap_anchor_fabric(0x4570_u64, 5_u64, 0xFFF1_u16, crypto: crypto).fabric
    store = Matter::Controller::StateStore.new(Matter::Storage::Memory.new)
    state = store.load
    state.install_fabric(fabric)
    state.record_node(fabric.fabric_id, Matter::Controller::NodeInfo.new(9_u64),
      fabric.root_public_key, fabric.controller_node_id)
    store.save(state)
    datastore = Matter::Cluster::JointFabricDatastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    workflow = Matter::Controller::JointCommissioning::Workflow.new(store, fabric.fabric_id, fabric.root_public_key,
      fabric.controller_node_id, 1_u8, 1_u16, "Joining Administrator", 1_u16, 1_u16,
      2_u64, JointTestTrust.new,
      ->(_im : Matter::Controller::ImClient, _session : Matter::Session::SecureContext, _peer : Socket::IPAddress, _joiner : Matter::Controller::JointCommissioning::VerifiedJoiner) { true },
      ->(_joiner : Matter::Controller::JointCommissioning::VerifiedJoiner) { true },
      ->(request : Matter::Cluster::JointFabricDatastore::AddAdminRequest) {
        joint.add_admin_once(datastore, request); nil
      },
      ->(_fabric : Matter::Controller::FabricInfo, _node : UInt64, _peer : Socket::IPAddress, _endpoint : UInt16, _key : Bytes, _icac_id : UInt64) { Bytes.empty })
    [0_u64, Matter::DataType::NodeId::JOINT_FABRIC_EXCLUSIVE_MAXIMUM,
     UInt64::MAX, fabric.controller_node_id, 9_u64].each do |node_id|
      expect_raises(Matter::CommissioningError, /Joint Fabric Node ID/) do
        workflow.commission(node_id, "invalid manual code")
      end
    end
    workflow.close
  end

  it "recovers an acknowledged completion when controller node storage failed" do
    joint = Matter::Controller::JointCommissioning
    fabric = joint.bootstrap_anchor_fabric(0x4568_u64, 5_u64, 0xFFF1_u16, crypto: crypto).fabric
    store = Matter::Controller::StateStore.new(Matter::Storage::Memory.new)
    state = store.load
    state.install_fabric(fabric)
    store.save(state)
    pending = Matter::Controller::JointCommissioning::PendingRegistration.new(fabric.fabric_id, fabric.controller_node_id,
      fabric.root_public_key, 9_u64, 0xFFF2_u16, "Joining Administrator", Bytes[1, 2, 3],
      "127.0.0.1", 5540, true)
    key = "#{fabric.fabric_id.to_s(16)}-#{fabric.root_public_key.hexstring}-#{fabric.controller_node_id.to_s(16)}"
    store.backend.write("joint_commissioning", "pending-#{key}", pending.to_document)
    datastore = Matter::Cluster::JointFabricDatastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    workflow = Matter::Controller::JointCommissioning::Workflow.new(store, fabric.fabric_id, fabric.root_public_key,
      fabric.controller_node_id, 1_u8, 1_u16, "Joining Administrator", 1_u16, 1_u16,
      2_u64, JointTestTrust.new,
      ->(_im : Matter::Controller::ImClient, _session : Matter::Session::SecureContext, _peer : Socket::IPAddress, _joiner : Matter::Controller::JointCommissioning::VerifiedJoiner) { true },
      ->(_joiner : Matter::Controller::JointCommissioning::VerifiedJoiner) { true },
      ->(request : Matter::Cluster::JointFabricDatastore::AddAdminRequest) {
        joint.add_admin_once(datastore, request); nil
      },
      ->(_fabric : Matter::Controller::FabricInfo, _node : UInt64, _peer : Socket::IPAddress, _endpoint : UInt16, _key : Bytes, _icac_id : UInt64) { Bytes.empty })

    # A retry of the same commissioned Node ID reconciles the saved result
    # and must not reopen PASE or send AddNOC again.
    workflow.commission(9_u64, "invalid manual code")
    store.load.nodes_for(fabric.fabric_id, fabric.root_public_key,
      fabric.controller_node_id)[9_u64].address.should eq("127.0.0.1")
    datastore.admin_list.size.should eq(1)
    workflow.resume_pending.should be_false
  end

  it "reconciles a deferred Anchor result only with a fresh matching nonce and ICAC" do
    joint = Matter::Controller::JointCommissioning
    fabric = joint.bootstrap_anchor_fabric(0x4569_u64, 5_u64, 0xFFF1_u16, crypto: crypto).fabric
    store = Matter::Controller::StateStore.new(Matter::Storage::Memory.new)
    state = store.load
    state.install_fabric(fabric)
    state.add_pending_handoff(Matter::Controller::PendingCommissioningHandoff.new(
      fabric.fabric_id, fabric.root_public_key, fabric.controller_node_id,
      9_u64, "127.0.0.1", 5540, Time.utc.to_unix + 60, "fresh-nonce"))
    store.save(state)
    joiner_key = crypto.create_key_pair
    pending = Matter::Controller::JointCommissioning::PendingRegistration.new(fabric.fabric_id, fabric.controller_node_id,
      fabric.root_public_key, 9_u64, 0xFFF2_u16, "Joining Administrator", Bytes.empty,
      "127.0.0.1", 5540, handoff_nonce: "fresh-nonce",
      joiner_icac_public_key: joiner_key.public_key)
    key = "#{fabric.fabric_id.to_s(16)}-#{fabric.root_public_key.hexstring}-#{fabric.controller_node_id.to_s(16)}"
    store.backend.write("joint_commissioning", "pending-#{key}", pending.to_document)
    icac = Matter::Crypto::MatterCertificate::Builder.intermediate(
      joiner_key.public_key, fabric.fabric_id, 2_u64,
      fabric.certificate_authority_key, 1_u64, Bytes[0x0B], crypto)
    result_nonce = "wrong-nonce"
    datastore = Matter::Cluster::JointFabricDatastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    workflow = Matter::Controller::JointCommissioning::Workflow.new(store, fabric.fabric_id, fabric.root_public_key,
      fabric.controller_node_id, 1_u8, 1_u16, "Joining Administrator", 1_u16, 1_u16,
      2_u64, JointTestTrust.new,
      ->(_im : Matter::Controller::ImClient, _session : Matter::Session::SecureContext, _peer : Socket::IPAddress, _joiner : Matter::Controller::JointCommissioning::VerifiedJoiner) { true },
      ->(_joiner : Matter::Controller::JointCommissioning::VerifiedJoiner) { true },
      ->(request : Matter::Cluster::JointFabricDatastore::AddAdminRequest) {
        joint.add_admin_once(datastore, request); nil
      },
      ->(_fabric : Matter::Controller::FabricInfo, _node : UInt64, _peer : Socket::IPAddress, _endpoint : UInt16, _key : Bytes, _icac_id : UInt64) { Bytes.empty },
      handoff_result: ->(_nonce : String) {
        Matter::Controller::JointCommissioning::Workflow::HandoffResult.new(result_nonce, icac).as(Matter::Controller::JointCommissioning::Workflow::HandoffResult?)
      })
    expect_raises(Matter::AuthenticationError, /nonce mismatch/) { workflow.resume_pending }
    store.load.nodes.should be_empty
    result_nonce = "fresh-nonce"
    workflow.resume_pending.should be_true
    store.load.pending_handoffs.should be_empty
    store.load.nodes[9_u64].address.should eq("127.0.0.1")
    datastore.admin_list.first.icac.should eq(icac)
  ensure
    workflow.try(&.close)
  end

  it "recovers an acknowledged JFA completion after the original fail-safe deadline" do
    joint = Matter::Controller::JointCommissioning
    fabric = joint.bootstrap_anchor_fabric(0x4570_u64, 5_u64, 0xFFF1_u16, crypto: crypto).fabric
    store = Matter::Controller::StateStore.new(Matter::Storage::Memory.new)
    state = store.load
    state.install_fabric(fabric)
    state.add_pending_handoff(Matter::Controller::PendingCommissioningHandoff.new(
      fabric.fabric_id, fabric.root_public_key, fabric.controller_node_id,
      9_u64, "127.0.0.1", 5540, Time.utc.to_unix - 1, "acknowledged-nonce"))
    store.save(state)
    joiner_key = crypto.create_key_pair
    icac = Matter::Crypto::MatterCertificate::Builder.intermediate(
      joiner_key.public_key, fabric.fabric_id, 2_u64,
      fabric.certificate_authority_key, 1_u64, Bytes[0x0C], crypto)
    pending = Matter::Controller::JointCommissioning::PendingRegistration.new(fabric.fabric_id, fabric.controller_node_id,
      fabric.root_public_key, 9_u64, 0xFFF2_u16, "Joining Administrator", icac,
      "127.0.0.1", 5540, true, "acknowledged-nonce", joiner_key.public_key)
    key = "#{fabric.fabric_id.to_s(16)}-#{fabric.root_public_key.hexstring}-#{fabric.controller_node_id.to_s(16)}"
    store.backend.write("joint_commissioning", "pending-#{key}", pending.to_document)
    expect_raises(Matter::AuthenticationError, /deadline/) do
      state.complete_pending_handoff(fabric.fabric_id, fabric.root_public_key,
        fabric.controller_node_id, 9_u64, "acknowledged-nonce")
    end
    expect_raises(Matter::AuthenticationError, /nonce/) do
      state.recover_acknowledged_handoff(fabric.fabric_id, fabric.root_public_key,
        fabric.controller_node_id, 9_u64, "wrong-nonce")
    end
    datastore = Matter::Cluster::JointFabricDatastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    workflow = Matter::Controller::JointCommissioning::Workflow.new(store, fabric.fabric_id, fabric.root_public_key,
      fabric.controller_node_id, 1_u8, 1_u16, "Joining Administrator", 1_u16, 1_u16,
      2_u64, JointTestTrust.new,
      ->(_im : Matter::Controller::ImClient, _session : Matter::Session::SecureContext, _peer : Socket::IPAddress, _joiner : Matter::Controller::JointCommissioning::VerifiedJoiner) { true },
      ->(_joiner : Matter::Controller::JointCommissioning::VerifiedJoiner) { true },
      ->(request : Matter::Cluster::JointFabricDatastore::AddAdminRequest) {
        joint.add_admin_once(datastore, request); nil
      },
      ->(_fabric : Matter::Controller::FabricInfo, _node : UInt64, _peer : Socket::IPAddress, _endpoint : UInt16, _key : Bytes, _icac_id : UInt64) { Bytes.empty })
    workflow.resume_pending.should be_true
    store.load.pending_handoffs.should be_empty
    store.load.nodes[9_u64].address.should eq("127.0.0.1")
    datastore.admin_list.first.icac.should eq(icac)
  ensure
    workflow.try(&.close)
  end

  it "retries an interrupted AddICAC only after authenticated original-fabric absence proof" do
    joint = Matter::Controller::JointCommissioning
    anchor = joint.bootstrap_anchor_fabric(0x4581_u64, 5_u64, 0xFFF1_u16, crypto: crypto).fabric
    original = joint.bootstrap_anchor_fabric(0x4582_u64, 6_u64, 0xFFF2_u16, crypto: crypto).fabric
    path = File.join(Dir.tempdir, "matter-jcm-recovery-#{Random::Secure.hex(6)}.yaml")
    backend = Matter::Storage::YamlFile.new(path)
    store = Matter::Controller::StateStore.new(backend)
    state = store.load
    state.install_fabric(anchor)
    store.save(state)
    make_pending = ->(deadline : Int64?) {
      Matter::Controller::JointCommissioning::PendingRegistration.new(anchor.fabric_id, anchor.controller_node_id,
        anchor.root_public_key, 9_u64, 0xFFF2_u16, "Joining Administrator", Bytes[1, 2, 3],
        "127.0.0.1", 5540, fail_safe_deadline_unix: deadline,
        fail_safe_max_seconds: 900_u16,
        original_fabric_id: original.fabric_id, original_root_public_key: original.root_public_key,
        original_node_id: 17_u64)
    }
    key = "#{anchor.fabric_id.to_s(16)}-#{anchor.root_public_key.hexstring}-#{anchor.controller_node_id.to_s(16)}"
    backend.write("joint_commissioning", "pending-#{key}", make_pending.call(Time.utc.to_unix + 60).to_document)
    backend.close

    reopened = Matter::Controller::StateStore.new(Matter::Storage::YamlFile.new(path))
    build_workflow = ->(source : Matter::Controller::StateStore) {
      Matter::Controller::JointCommissioning::Workflow.new(source, anchor.fabric_id, anchor.root_public_key,
        anchor.controller_node_id, 1_u8, 1_u16, "Joining Administrator", 1_u16, 1_u16,
        2_u64, JointTestTrust.new,
        ->(_im : Matter::Controller::ImClient, _session : Matter::Session::SecureContext, _peer : Socket::IPAddress, _joiner : Matter::Controller::JointCommissioning::VerifiedJoiner) { true },
        ->(_joiner : Matter::Controller::JointCommissioning::VerifiedJoiner) { true },
        ->(_request : Matter::Cluster::JointFabricDatastore::AddAdminRequest) { nil },
        ->(_fabric : Matter::Controller::FabricInfo, _node : UInt64, _peer : Socket::IPAddress, _endpoint : UInt16, _key : Bytes, _icac_id : UInt64) { Bytes.empty })
    }
    workflow = build_workflow.call(reopened)
    peer = Socket::IPAddress.new("127.0.0.1", 5540)
    descriptor = Matter::Cluster::OperationalCredentials::Tlv::FabricDescriptor
    original_entry = descriptor.new(original.root_public_key, 0xFFF2_u16,
      original.fabric_id, 17_u64, "original", 1_u8)
    anchor_entry = descriptor.new(anchor.root_public_key, 0xFFF1_u16,
      anchor.fabric_id, 9_u64, "anchor", 2_u8)
    expect_raises(Matter::CommissioningError, /still pending/) { workflow.commission(9_u64, "invalid manual code") }
    expect_raises(Matter::CommissioningError, /deadline has not passed/) do
      workflow.recover_abandoned_pending(original, 17_u64, peer, JointRecoveryPort.new([original_entry]))
    end
    workflow.close
    reopened.backend.write("joint_commissioning", "pending-#{key}", make_pending.call(nil).to_document)
    workflow = build_workflow.call(reopened)
    expect_raises(Matter::CommissioningError, /lacks a durable fail-safe deadline/) do
      workflow.recover_abandoned_pending(original, 17_u64, peer, JointRecoveryPort.new([original_entry]))
    end
    workflow.close
    original_pending = make_pending.call(Time.utc.to_unix - 1)
    reopened.backend.write("joint_commissioning", "pending-#{key}", original_pending.to_document)
    workflow = build_workflow.call(reopened)
    expect_raises(Matter::AuthenticationError, /differs/) do
      workflow.recover_abandoned_pending(original, 18_u64, peer, JointRecoveryPort.new([original_entry]))
    end
    expect_raises(Matter::AuthenticationError, /Original fabric is absent/) do
      workflow.recover_abandoned_pending(original, 17_u64, peer,
        JointRecoveryPort.new([] of Matter::Cluster::OperationalCredentials::Tlv::FabricDescriptor))
    end
    expect_raises(Matter::CommissioningError, /still present/) do
      workflow.recover_abandoned_pending(original, 17_u64, peer, JointRecoveryPort.new([original_entry, anchor_entry]))
    end
    replacement = make_pending.call(Time.utc.to_unix - 1)
    replacement.icac = Bytes[8, 9, 10]
    replacing_port = JointRecoveryPort.new([original_entry], -> {
      reopened.backend.write("joint_commissioning", "pending-#{key}", replacement.to_document)
      nil
    })
    expect_raises(Matter::CommissioningError, /changed during recovery/) do
      workflow.recover_abandoned_pending(original, 17_u64, peer, replacing_port)
    end
    reopened.backend.read("joint_commissioning", "pending-#{key}").should eq(replacement.to_document)
    reopened.backend.write("joint_commissioning", "pending-#{key}", original_pending.to_document)
    workflow.recover_abandoned_pending(original, 17_u64, peer, JointRecoveryPort.new([original_entry])).should be_true
    reopened.backend.read("joint_commissioning", "pending-#{key}").should be_nil
    expect_raises(ArgumentError, /11 digits/) { workflow.commission(9_u64, "invalid manual code") }
  ensure
    workflow.try(&.close)
    File.delete(path) if path && File.exists?(path)
  end

  it "abandons an expired deferred JCM handoff only with authenticated absence proof" do
    joint = Matter::Controller::JointCommissioning
    anchor = joint.bootstrap_anchor_fabric(0x4583_u64, 5_u64, 0xFFF1_u16, crypto: crypto).fabric
    original = joint.bootstrap_anchor_fabric(0x4584_u64, 6_u64, 0xFFF2_u16, crypto: crypto).fabric
    path = File.join(Dir.tempdir, "matter-deferred-jcm-recovery-#{Random::Secure.hex(6)}.yaml")
    store = Matter::Controller::StateStore.new(Matter::Storage::YamlFile.new(path))
    nonce = "abandoned-handoff"
    state = store.load
    state.install_fabric(anchor)
    state.add_pending_handoff(Matter::Controller::PendingCommissioningHandoff.new(
      anchor.fabric_id, anchor.root_public_key, anchor.controller_node_id,
      9_u64, "127.0.0.1", 5540, Time.utc.to_unix - 1, nonce))
    store.save(state)
    key = "#{anchor.fabric_id.to_s(16)}-#{anchor.root_public_key.hexstring}-#{anchor.controller_node_id.to_s(16)}"
    make_pending = ->(deadline : Int64?) {
      Matter::Controller::JointCommissioning::PendingRegistration.new(anchor.fabric_id, anchor.controller_node_id,
        anchor.root_public_key, 9_u64, 0xFFF2_u16, "Joining Administrator", Bytes.empty,
        "127.0.0.1", 5540, handoff_nonce: nonce,
        fail_safe_deadline_unix: deadline, fail_safe_max_seconds: 900_u16,
        original_fabric_id: original.fabric_id, original_root_public_key: original.root_public_key,
        original_node_id: 17_u64)
    }
    store.backend.write("joint_commissioning", "pending-#{key}", make_pending.call(Time.utc.to_unix - 1).to_document)
    store.backend.close

    reopened = Matter::Controller::StateStore.new(Matter::Storage::YamlFile.new(path))
    build_workflow = -> {
      Matter::Controller::JointCommissioning::Workflow.new(reopened, anchor.fabric_id, anchor.root_public_key,
        anchor.controller_node_id, 1_u8, 1_u16, "Joining Administrator", 1_u16, 1_u16,
        2_u64, JointTestTrust.new,
        ->(_im : Matter::Controller::ImClient, _session : Matter::Session::SecureContext, _peer : Socket::IPAddress, _joiner : Matter::Controller::JointCommissioning::VerifiedJoiner) { true },
        ->(_joiner : Matter::Controller::JointCommissioning::VerifiedJoiner) { true },
        ->(_request : Matter::Cluster::JointFabricDatastore::AddAdminRequest) { nil },
        ->(_fabric : Matter::Controller::FabricInfo, _node : UInt64, _peer : Socket::IPAddress, _endpoint : UInt16, _key : Bytes, _icac_id : UInt64) { Bytes.empty })
    }
    workflow = build_workflow.call
    peer = Socket::IPAddress.new("127.0.0.1", 5540)
    descriptor = Matter::Cluster::OperationalCredentials::Tlv::FabricDescriptor
    original_entry = descriptor.new(original.root_public_key, 0xFFF2_u16,
      original.fabric_id, 17_u64, "original", 1_u8)
    anchor_entry = descriptor.new(anchor.root_public_key, 0xFFF1_u16,
      anchor.fabric_id, 9_u64, "anchor", 2_u8)
    expect_raises(Matter::CommissioningError, /still present/) do
      workflow.recover_abandoned_pending(original, 17_u64, peer, JointRecoveryPort.new([original_entry, anchor_entry]))
    end
    reopened.load.pending_handoffs.size.should eq(1)
    expect_raises(Matter::AuthenticationError, /differs/) do
      workflow.recover_abandoned_pending(original, 18_u64, peer, JointRecoveryPort.new([original_entry]))
    end
    replacing_port = JointRecoveryPort.new([original_entry], -> {
      changed = reopened.load
      changed.pending_handoffs[0] = Matter::Controller::PendingCommissioningHandoff.new(
        anchor.fabric_id, anchor.root_public_key, anchor.controller_node_id,
        9_u64, "127.0.0.1", 5540, Time.utc.to_unix - 1, "other-handoff")
      reopened.save(changed)
      nil
    })
    expect_raises(Matter::CommissioningError, /handoff changed during recovery/) do
      workflow.recover_abandoned_pending(original, 17_u64, peer, replacing_port)
    end
    reopened.backend.read("joint_commissioning", "pending-#{key}").should_not be_nil
    restored = reopened.load
    restored.pending_handoffs[0] = Matter::Controller::PendingCommissioningHandoff.new(
      anchor.fabric_id, anchor.root_public_key, anchor.controller_node_id,
      9_u64, "127.0.0.1", 5540, Time.utc.to_unix - 1, nonce)
    reopened.save(restored)
    workflow.recover_abandoned_pending(original, 17_u64, peer, JointRecoveryPort.new([original_entry])).should be_true
    reopened.load.pending_handoffs.should be_empty
    reopened.backend.read("joint_commissioning", "pending-#{key}").should be_nil
    workflow.close

    state = reopened.load
    state.add_pending_handoff(Matter::Controller::PendingCommissioningHandoff.new(
      anchor.fabric_id, anchor.root_public_key, anchor.controller_node_id,
      9_u64, "127.0.0.1", 5540, Time.utc.to_unix - 1, nonce))
    reopened.save(state)
    legacy = make_pending.call(nil)
    reopened.backend.write("joint_commissioning", "pending-#{key}", legacy.to_document)
    workflow = build_workflow.call
    expect_raises(Matter::CommissioningError, /lacks a durable fail-safe deadline/) do
      workflow.recover_abandoned_pending(original, 17_u64, peer, JointRecoveryPort.new([original_entry]))
    end
    reopened.load.pending_handoffs.size.should eq(1)
    reopened.backend.read("joint_commissioning", "pending-#{key}").should eq(legacy.to_document)
  ensure
    workflow.try(&.close)
    File.delete(path) if path && File.exists?(path)
  end
end
