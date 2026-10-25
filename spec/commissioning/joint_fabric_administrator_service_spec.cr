require "../spec_helper"
require "../../src/matter/commissioning/joint_fabric_administrator_service"

private def jfa_icac_install_status(certificate : Bytes, root : Bytes,
                                    icac_key : Matter::Crypto::Key,
                                    anchor_icac : Bytes) : Matter::Cluster::JointFabricAdministrator::ICACResponseStatusEnum
  service = Matter::Commissioning::JointFabricAdministratorService.new(
    icac_key, root, 0x1234_u64,
    -> { true }, ->(_index : UInt8) { true },
    ->(_request : Matter::Cluster::JointFabricAdministrator::OpenJointCommissioningWindowRequest) { Matter::InteractionModel::Status.success },
    ->(_node : UInt64) { true }, -> { false }, -> { nil }, -> { nil },
    verify_anchor_initiator: ->(_node : UInt64, _fabric : UInt8, _peer : Socket::IPAddress) { true },
    failsafe_fabric_matches: ->(index : UInt8?) { index == 2_u8 })
  cluster = Matter::Cluster::JointFabricAdministrator.new(Matter::DataType::EndpointNumber.new(1_u16))
  cluster.administrator_fabric_index = 1_u8
  cluster.request_is_case_session = true
  cluster.request_peer_subject_ids = [0xFFFF_FFFD_FFFE_0001_u64]
  cluster.request_peer_icac = anchor_icac
  cluster.request_peer_node_id = 7_u64
  cluster.request_fabric_index = 2_u8
  cluster.request_session_id = 3_u64
  cluster.request_peer_address = Socket::IPAddress.new("127.0.0.1", 5540)
  service.announce_joint_fabric_administrator(cluster,
    Matter::Cluster::JointFabricAdministrator::AnnounceJointFabricAdministratorRequest.new(1_u16))
  service.icaccsr_request(cluster).as(Matter::Cluster::JointFabricAdministrator::ICACCSRResponse).status_code.should eq(
    Matter::Cluster::JointFabricAdministrator::ICACCSRResponseStatusCodeEnum::OK)
  service.add_icac(cluster, Matter::Cluster::JointFabricAdministrator::AddICACRequest.new(certificate))
    .as(Matter::Cluster::JointFabricAdministrator::ICACResponse).status_code
end

private def jfa_resign_certificate(certificate : Bytes, issuer_key : Matter::Crypto::Key,
                                   & : TLV::Structure -> Nil) : Bytes
  fields = TLV::Any.from_slice(certificate).as_structure
  yield fields
  signature = Matter::Crypto::StandardCrypto.new.sign_ecdsa(issuer_key,
    Matter::Crypto::MatterCertificate::Asn1.to_unsigned_asn1(TLV::Any.new(fields, nil)))
  fields[Matter::Crypto::MatterCertificate::Asn1::Field::Signature.value] =
    TLV::Any.new(signature, Matter::Crypto::MatterCertificate::Asn1::Field::Signature.value)
  TLV::Any.new(fields, nil).to_slice
end

class StubRemoteIcacCsrProvider < Matter::Commissioning::RemoteIcacCsrProvider
  def initialize(@csr : Bytes, root_public_key : Bytes)
    super("/tmp/unused-jfa-csr", 0x1234_u64, root_public_key)
  end

  def request : Bytes
    @csr
  end
end

describe Matter::Commissioning::JointFabricAdministratorService do
  crypto = Matter::Crypto::StandardCrypto.new
  root_key = crypto.create_key_pair
  icac_key = crypto.create_key_pair
  fabric_id = 0x1234_u64
  root = Matter::Crypto::MatterCertificate::Builder.root(root_key, 1_u64, Bytes[0x01], crypto)
  anchor_icac = Matter::Crypto::MatterCertificate::Builder.intermediate(
    icac_key.public_key, fabric_id, 3_u64, root_key, 1_u64, Bytes[0x06], crypto, anchor: true
  )

  it "rejects expired, non-signing, and wrong-fabric cross-signed ICACs" do
    # The official SDK issues ICACs whose subject contains ICAC ID alone.
    certificate = Matter::Crypto::MatterCertificate::Builder.intermediate(
      icac_key.public_key, nil, 2_u64, root_key, 1_u64, Bytes[0x02], crypto)
    ok = Matter::Cluster::JointFabricAdministrator::ICACResponseStatusEnum::OK
    invalid = Matter::Cluster::JointFabricAdministrator::ICACResponseStatusEnum::InvalidICAC
    jfa_icac_install_status(certificate, root, icac_key, anchor_icac).should eq(ok)

    Timecop.travel(Time.utc + 11.years) do
      jfa_icac_install_status(certificate, root, icac_key, anchor_icac).should eq(invalid)
    end

    usage_tag = Matter::Crypto::MatterCertificate::Asn1::Extension::KeyUsage.value
    non_signing = jfa_resign_certificate(certificate, root_key) do |fields|
      extensions = fields[Matter::Crypto::MatterCertificate::Asn1::Field::Extensions.value].as_list
      index = extensions.index { |extension| extension.header.ids == usage_tag }.as(Int32)
      extensions[index] = TLV::Any.new(1_u16, usage_tag)
    end
    jfa_icac_install_status(non_signing, root, icac_key, anchor_icac).should eq(invalid)

    wrong_fabric = Matter::Crypto::MatterCertificate::Builder.intermediate(
      icac_key.public_key, fabric_id + 1_u64, 2_u64, root_key, 1_u64, Bytes[0x03], crypto)
    jfa_icac_install_status(wrong_fabric, root, icac_key, anchor_icac).should eq(invalid)
  end

  it "checks remote CSR proof and pinned existing ICAC before returning bytes" do
    provider = StubRemoteIcacCsrProvider.new(Matter::Crypto::Pkcs10.create(icac_key, crypto), root_key.public_key)
    service = Matter::Commissioning::JointFabricAdministratorService.new(
      nil, root, fabric_id,
      -> { true }, ->(_index : UInt8) { true },
      ->(_request : Matter::Cluster::JointFabricAdministrator::OpenJointCommissioningWindowRequest) { Matter::InteractionModel::Status.success },
      ->(_node : UInt64) { true }, -> { false }, -> { nil }, -> { nil }, crypto,
      verify_anchor_initiator: ->(_node : UInt64, _fabric : UInt8, _peer : Socket::IPAddress) { true },
      failsafe_fabric_matches: ->(_index : UInt8?) { true },
      existing_icac_certificate: anchor_icac,
      icac_csr_provider: provider
    )
    cluster = Matter::Cluster::JointFabricAdministrator.new(Matter::DataType::EndpointNumber.new(1_u16))
    cluster.administrator_fabric_index = 1_u8
    cluster.request_is_case_session = true
    cluster.request_peer_subject_ids = [0xFFFF_FFFD_FFFE_0001_u64]
    cluster.request_peer_icac = anchor_icac
    cluster.request_peer_node_id = 7_u64
    cluster.request_fabric_index = 2_u8
    cluster.request_session_id = 3_u64
    cluster.request_peer_address = Socket::IPAddress.new("127.0.0.1", 5540)
    service.announce_joint_fabric_administrator(cluster,
      Matter::Cluster::JointFabricAdministrator::AnnounceJointFabricAdministratorRequest.new(1_u16))
    response = service.icaccsr_request(cluster).as(Matter::Cluster::JointFabricAdministrator::ICACCSRResponse)
    response.icaccsr.should eq(provider.request)

    bad_provider = StubRemoteIcacCsrProvider.new(Matter::Crypto::Pkcs10.create(crypto.create_key_pair, crypto), root_key.public_key)
    bad_service = Matter::Commissioning::JointFabricAdministratorService.new(
      nil, root, fabric_id,
      -> { true }, ->(_index : UInt8) { true },
      ->(_request : Matter::Cluster::JointFabricAdministrator::OpenJointCommissioningWindowRequest) { Matter::InteractionModel::Status.success },
      ->(_node : UInt64) { true }, -> { false }, -> { nil }, -> { nil }, crypto,
      verify_anchor_initiator: ->(_node : UInt64, _fabric : UInt8, _peer : Socket::IPAddress) { true },
      failsafe_fabric_matches: ->(_index : UInt8?) { true },
      existing_icac_certificate: anchor_icac,
      icac_csr_provider: bad_provider
    )
    bad_service.announce_joint_fabric_administrator(cluster,
      Matter::Cluster::JointFabricAdministrator::AnnounceJointFabricAdministratorRequest.new(1_u16))
    bad_service.icaccsr_request(cluster).should eq(Matter::InteractionModel::Status.cluster_failure(
      Matter::Cluster::JointFabricAdministrator::ICACCSRResponseStatusCodeEnum::Busy))
  end

  it "rejects a CSR key unrelated to the existing Administrator ICAC" do
    other = crypto.create_key_pair
    existing_icac = Matter::Crypto::MatterCertificate::Builder.intermediate(
      other.public_key, fabric_id, 2_u64, root_key, 1_u64, Bytes[0x05], crypto
    )
    expect_raises(Matter::ConfigurationError) do
      Matter::Commissioning::JointFabricAdministratorService.new(
        icac_key, root, fabric_id,
        -> { true }, ->(_index : UInt8) { true },
        ->(_request : Matter::Cluster::JointFabricAdministrator::OpenJointCommissioningWindowRequest) { Matter::InteractionModel::Status.success },
        ->(_node : UInt64) { true }, -> { false }, -> { nil }, -> { nil }, crypto,
        existing_icac_certificate: existing_icac
      )
    end
  end

  it "requires CASE, fail-safe and VID verification before an ICAC CSR" do
    armed = false
    verified = false
    failsafe_owner_matches = false
    service = Matter::Commissioning::JointFabricAdministratorService.new(
      icac_key, root, fabric_id,
      -> { armed }, ->(_index : UInt8) { verified },
      ->(_request : Matter::Cluster::JointFabricAdministrator::OpenJointCommissioningWindowRequest) { Matter::InteractionModel::Status.success },
      ->(_node : UInt64) { true }, -> { false }, -> { nil }, -> { nil }, crypto,
      verify_anchor_initiator: ->(_node : UInt64, _fabric : UInt8, _peer : Socket::IPAddress) { true },
      failsafe_fabric_matches: ->(index : UInt8?) { failsafe_owner_matches && index == 2_u8 }
    )
    cluster = Matter::Cluster::JointFabricAdministrator.new(Matter::DataType::EndpointNumber.new(1_u16))
    cluster.administrator_fabric_index = 1_u8
    cluster.request_is_case_session = true
    cluster.request_peer_subject_ids = [0xFFFF_FFFD_FFFE_0001_u64]
    cluster.request_peer_icac = anchor_icac
    cluster.request_peer_node_id = 7_u64
    cluster.request_fabric_index = 2_u8
    cluster.request_session_id = 3_u64
    cluster.request_peer_address = Socket::IPAddress.new("127.0.0.1", 5540)
    service.icaccsr_request(cluster).should eq(Matter::InteractionModel::Status.failsafe_required)
    armed = true
    service.icaccsr_request(cluster).should eq(Matter::InteractionModel::Status.cluster_failure(
      Matter::Cluster::JointFabricAdministrator::ICACCSRResponseStatusCodeEnum::VIDNotVerified))
    verified = true
    service.announce_joint_fabric_administrator(cluster,
      Matter::Cluster::JointFabricAdministrator::AnnounceJointFabricAdministratorRequest.new(1_u16))
    cluster.request_session_id = 4_u64
    service.icaccsr_request(cluster).should eq(Matter::InteractionModel::Status.unsupported_access)
    cluster.request_peer_node_id = 8_u64
    service.icaccsr_request(cluster).should eq(Matter::InteractionModel::Status.cluster_failure(
      Matter::Cluster::JointFabricAdministrator::ICACCSRResponseStatusCodeEnum::VIDNotVerified))
    cluster.request_peer_node_id = 7_u64
    cluster.request_fabric_index = 3_u8
    service.icaccsr_request(cluster).should eq(Matter::InteractionModel::Status.cluster_failure(
      Matter::Cluster::JointFabricAdministrator::ICACCSRResponseStatusCodeEnum::VIDNotVerified))
    cluster.request_fabric_index = 2_u8
    cluster.administrator_fabric_index = nil
    service.icaccsr_request(cluster).should eq(Matter::InteractionModel::Status.cluster_failure(
      Matter::Cluster::JointFabricAdministrator::ICACCSRResponseStatusCodeEnum::InvalidAdministratorFabricIndex))
    cluster.administrator_fabric_index = 1_u8
    service.icaccsr_request(cluster).should eq(Matter::InteractionModel::Status.unsupported_access)
    failsafe_owner_matches = true
    response = service.icaccsr_request(cluster).as(Matter::Cluster::JointFabricAdministrator::ICACCSRResponse)
    response.status_code.should eq(Matter::Cluster::JointFabricAdministrator::ICACCSRResponseStatusCodeEnum::OK)
    Matter::Crypto::Pkcs10.verify(response.icaccsr.as(Bytes), icac_key.public_key, crypto)

    cross_signed = Matter::Crypto::MatterCertificate::Builder.intermediate(
      icac_key.public_key, fabric_id, 2_u64, root_key, 1_u64, Bytes[0x02], crypto
    )
    service.add_icac(cluster, Matter::Cluster::JointFabricAdministrator::AddICACRequest.new(Bytes.new(401, 0_u8)))
      .should eq(Matter::InteractionModel::Status.invalid_command)
    cluster.request_session_id = 5_u64
    cluster.request_peer_node_id = 8_u64
    service.add_icac(cluster, Matter::Cluster::JointFabricAdministrator::AddICACRequest.new(cross_signed)).should eq(
      Matter::InteractionModel::Status.unsupported_access)
    cluster.request_peer_node_id = 7_u64
    cluster.request_fabric_index = 3_u8
    service.add_icac(cluster, Matter::Cluster::JointFabricAdministrator::AddICACRequest.new(cross_signed)).should eq(
      Matter::InteractionModel::Status.unsupported_access)
    cluster.request_fabric_index = 2_u8
    failsafe_owner_matches = false
    service.add_icac(cluster, Matter::Cluster::JointFabricAdministrator::AddICACRequest.new(cross_signed)).should eq(
      Matter::InteractionModel::Status.unsupported_access)
    failsafe_owner_matches = true
    installed = service.add_icac(cluster, Matter::Cluster::JointFabricAdministrator::AddICACRequest.new(cross_signed))
    installed.as(Matter::Cluster::JointFabricAdministrator::ICACResponse).status_code.should eq(
      Matter::Cluster::JointFabricAdministrator::ICACResponseStatusEnum::OK)
    service.cross_signed_icac.should eq(cross_signed)
    service.reset_failsafe
    service.icaccsr_request(cluster).should eq(Matter::InteractionModel::Status.constraint_error)
  end

  it "requires an authenticated Administrator CAT before transferring the Anchor" do
    started = false
    consented = false
    busy = false
    requesters = [] of Tuple(UInt64, UInt8)
    service = Matter::Commissioning::JointFabricAdministratorService.new(
      icac_key, root, fabric_id,
      -> { true }, ->(_index : UInt8) { true },
      ->(_request : Matter::Cluster::JointFabricAdministrator::OpenJointCommissioningWindowRequest) { Matter::InteractionModel::Status.success },
      ->(_node : UInt64) { consented }, -> { busy }, -> { started = true; nil }, -> { nil }, crypto,
      on_transfer_requested: ->(node : UInt64, index : UInt8) { requesters << {node, index}; nil }
    )
    cluster = Matter::Cluster::JointFabricAdministrator.new(Matter::DataType::EndpointNumber.new(1_u16))
    cluster.request_is_case_session = true
    cluster.request_peer_node_id = 0x44_u64
    cluster.request_fabric_index = 1_u8
    cluster.administrator_fabric_index = 1_u8
    cluster.request_peer_subject_ids = [0x44_u64]
    service.transfer_anchor_request(cluster).should eq(Matter::InteractionModel::Status.unsupported_access)
    started.should be_false
    requesters.should be_empty
    cluster.request_peer_subject_ids = [0x44_u64, 0xFFFF_FFFD_FFFF_0000_u64]
    service.transfer_anchor_request(cluster).should eq(Matter::InteractionModel::Status.unsupported_access)
    requesters.should be_empty
    cluster.request_peer_subject_ids = [0x44_u64, 0xFFFF_FFFD_FFFF_0002_u64]
    denied = service.transfer_anchor_request(cluster).as(Matter::Cluster::JointFabricAdministrator::TransferAnchorResponse)
    denied.status_code.should eq(Matter::Cluster::JointFabricAdministrator::TransferAnchorResponseStatusEnum::TransferAnchorStatusNoUserConsent)
    requesters.should be_empty
    consented = true
    busy = true
    unavailable = service.transfer_anchor_request(cluster).as(Matter::Cluster::JointFabricAdministrator::TransferAnchorResponse)
    unavailable.status_code.should eq(Matter::Cluster::JointFabricAdministrator::TransferAnchorResponseStatusEnum::TransferAnchorStatusDatastoreBusy)
    requesters.should be_empty
    busy = false
    result = service.transfer_anchor_request(cluster).as(Matter::Cluster::JointFabricAdministrator::TransferAnchorResponse)
    result.status_code.should eq(Matter::Cluster::JointFabricAdministrator::TransferAnchorResponseStatusEnum::OK)
    started.should be_true
    requesters.should eq([{0x44_u64, 1_u8}])
    cluster.request_fabric_index = 2_u8
    service.transfer_anchor_complete(cluster).should eq(Matter::InteractionModel::Status.unsupported_access)
    cluster.request_fabric_index = 1_u8
    service.transfer_anchor_complete(cluster).should eq(Matter::InteractionModel::Status.success)
    service.transfer_anchor_complete(cluster).should eq(Matter::InteractionModel::Status.success)
  end

  it "completes a transfer after restoring its authenticated requester on restart" do
    completions = 0
    make_service = -> {
      Matter::Commissioning::JointFabricAdministratorService.new(
        icac_key, root, fabric_id,
        -> { true }, ->(_index : UInt8) { true },
        ->(_request : Matter::Cluster::JointFabricAdministrator::OpenJointCommissioningWindowRequest) { Matter::InteractionModel::Status.success },
        ->(_node : UInt64) { true }, -> { false }, -> { nil },
        -> { completions += 1; nil }, crypto,
        initial_transfer_requester: {0x44_u64, 1_u8})
    }
    cluster = Matter::Cluster::JointFabricAdministrator.new(Matter::DataType::EndpointNumber.new(1_u16))
    cluster.request_is_case_session = true
    cluster.request_peer_subject_ids = [0x44_u64, 0xFFFF_FFFD_FFFF_0001_u64]
    cluster.request_peer_node_id = 0x44_u64
    cluster.request_fabric_index = 2_u8
    restored = make_service.call
    restored.transfer_anchor_complete(cluster).should eq(Matter::InteractionModel::Status.unsupported_access)
    cluster.request_fabric_index = 1_u8
    restored.transfer_anchor_complete(cluster).should eq(Matter::InteractionModel::Status.success)
    # Simulate the acknowledgement being lost and the service restarting.
    make_service.call.transfer_anchor_complete(cluster).should eq(Matter::InteractionModel::Status.success)
    completions.should eq(2)
  end

  it "returns the JFA statuses required for OpenJointCommissioningWindow" do
    opened = 0
    service = Matter::Commissioning::JointFabricAdministratorService.new(
      icac_key, root, fabric_id,
      -> { true }, ->(_index : UInt8) { true },
      ->(_request : Matter::Cluster::JointFabricAdministrator::OpenJointCommissioningWindowRequest) {
        opened += 1
        opened == 1 ? Matter::InteractionModel::Status.success : Matter::InteractionModel::Status.busy
      },
      ->(_node : UInt64) { true }, -> { false }, -> { nil }, -> { nil }, crypto
    )
    cluster = Matter::Cluster::JointFabricAdministrator.new(Matter::DataType::EndpointNumber.new(1_u16))
    cluster.request_is_case_session = true
    cluster.request_peer_subject_ids = [0xFFFF_FFFD_FFFF_0001_u64]
    valid = Matter::Cluster::JointFabricAdministrator::OpenJointCommissioningWindowRequest.new(
      180_u16, Bytes.new(97, 0_u8), 3839_u16, 2000_u32, Bytes.new(16, 0_u8))

    service.open_joint_commissioning_window(cluster, valid).should eq(Matter::InteractionModel::Status.cluster_failure(
      Matter::Cluster::JointFabricAdministrator::ICACCSRResponseStatusCodeEnum::InvalidAdministratorFabricIndex))
    cluster.administrator_fabric_index = 1_u8
    cluster.request_fabric_index = 1_u8
    invalid = Matter::Cluster::JointFabricAdministrator::OpenJointCommissioningWindowRequest.new(
      180_u16, Bytes.new(96, 0_u8), 3839_u16, 2000_u32, Bytes.new(16, 0_u8))
    service.open_joint_commissioning_window(cluster, invalid).should eq(Matter::InteractionModel::Status.invalid_command)
    opened.should eq(0)
    service.open_joint_commissioning_window(cluster, valid).should eq(Matter::InteractionModel::Status.success)
    service.open_joint_commissioning_window(cluster, valid).should eq(Matter::InteractionModel::Status.cluster_failure(
      Matter::Cluster::JointFabricAdministrator::ICACCSRResponseStatusCodeEnum::Busy))
  end

  it "rejects a different fabric's Administrator CAT for JFA control commands" do
    fabrics = Matter::FabricTable.new(Matter::Storage::Memory.new)
    {1_u8, 2_u8}.each do |index|
      fabrics.add_fabric(Matter::Fabric.new(
        fabric_id: index.to_u64,
        fabric_index: index,
        node_id: 0x10_u64,
        root_public_key: Random::Secure.random_bytes(65),
        operational_cert: Random::Secure.random_bytes(200),
        operational_key: Matter::Crypto::Key.generate_key_pair,
        ipk: Random::Secure.random_bytes(16)
      )).should be_true
    end
    opened = 0
    transferred = 0
    service = Matter::Commissioning::JointFabricAdministratorService.new(
      icac_key, root, fabric_id,
      -> { true }, ->(_index : UInt8) { true },
      ->(_request : Matter::Cluster::JointFabricAdministrator::OpenJointCommissioningWindowRequest) {
        opened += 1
        Matter::InteractionModel::Status.success
      },
      ->(_node : UInt64) { true }, -> { false }, -> { transferred += 1; nil }, -> { nil }, crypto
    )
    cluster = Matter::Cluster::JointFabricAdministrator.new(Matter::DataType::EndpointNumber.new(1_u16))
    cluster.administrator_fabric_index = 1_u8
    cluster.request_is_case_session = true
    cluster.request_peer_node_id = 0x44_u64
    cluster.request_peer_subject_ids = [0x44_u64, 0xFFFF_FFFD_FFFF_0001_u64]
    cluster.request_fabric_index = fabrics.get_fabric(2_u8).as(Matter::Fabric).fabric_index
    valid = Matter::Cluster::JointFabricAdministrator::OpenJointCommissioningWindowRequest.new(
      180_u16, Bytes.new(97, 0_u8), 3839_u16, 2000_u32, Bytes.new(16, 0_u8))

    service.open_joint_commissioning_window(cluster, valid).should eq(Matter::InteractionModel::Status.unsupported_access)
    service.transfer_anchor_request(cluster).should eq(Matter::InteractionModel::Status.unsupported_access)
    opened.should eq(0)
    transferred.should eq(0)

    cluster.request_fabric_index = fabrics.get_fabric(1_u8).as(Matter::Fabric).fabric_index
    service.open_joint_commissioning_window(cluster, valid).should eq(Matter::InteractionModel::Status.success)
    service.transfer_anchor_request(cluster).as(Matter::Cluster::JointFabricAdministrator::TransferAnchorResponse).status_code.should eq(
      Matter::Cluster::JointFabricAdministrator::TransferAnchorResponseStatusEnum::OK)
    opened.should eq(1)
    transferred.should eq(1)

    restored = Matter::Cluster::JointFabricAdministrator.new(Matter::DataType::EndpointNumber.new(1_u16))
    restored.restore_state(cluster.save_state.as(Matter::Storage::Document))
    restored.administrator_fabric_index.should eq(1_u8)
    restored.request_is_case_session = true
    restored.request_peer_node_id = 0x44_u64
    restored.request_peer_subject_ids = [0x44_u64, 0xFFFF_FFFD_FFFF_0001_u64]
    restored.request_fabric_index = fabrics.get_fabric(2_u8).as(Matter::Fabric).fabric_index
    service.open_joint_commissioning_window(restored, valid).should eq(Matter::InteractionModel::Status.unsupported_access)
    service.transfer_anchor_request(restored).should eq(Matter::InteractionModel::Status.unsupported_access)
    opened.should eq(1)
    transferred.should eq(1)
    restored.request_fabric_index = fabrics.get_fabric(1_u8).as(Matter::Fabric).fabric_index
    service.open_joint_commissioning_window(restored, valid).should eq(Matter::InteractionModel::Status.success)
    opened.should eq(2)
  end

  it "limits the ICAC exchange and Administrator announcement to an authenticated Anchor CAT" do
    service = Matter::Commissioning::JointFabricAdministratorService.new(
      icac_key, root, fabric_id,
      -> { true }, ->(_index : UInt8) { true },
      ->(_request : Matter::Cluster::JointFabricAdministrator::OpenJointCommissioningWindowRequest) { Matter::InteractionModel::Status.success },
      ->(_node : UInt64) { true }, -> { false }, -> { nil }, -> { nil }, crypto
    )
    cluster = Matter::Cluster::JointFabricAdministrator.new(Matter::DataType::EndpointNumber.new(1_u16))
    cluster.request_is_case_session = true
    cluster.administrator_fabric_index = 1_u8
    cluster.request_peer_subject_ids = [0xFFFF_FFFD_FFFF_0001_u64]
    service.icaccsr_request(cluster).should eq(Matter::InteractionModel::Status.cluster_failure(
      Matter::Cluster::JointFabricAdministrator::ICACCSRResponseStatusCodeEnum::VIDNotVerified))
    announce = Matter::Cluster::JointFabricAdministrator::AnnounceJointFabricAdministratorRequest.new(2_u16)
    service.announce_joint_fabric_administrator(cluster, announce).should eq(Matter::InteractionModel::Status.unsupported_access)
    cluster.request_peer_subject_ids = [0xFFFF_FFFD_FFFE_0001_u64]
    ordinary_icac = Matter::Crypto::MatterCertificate::Builder.intermediate(
      icac_key.public_key, fabric_id, 4_u64, root_key, 1_u64, Bytes[0x07], crypto
    )
    cluster.request_peer_icac = ordinary_icac
    service.announce_joint_fabric_administrator(cluster, announce).should eq(Matter::InteractionModel::Status.unsupported_access)
    cluster.request_peer_icac = anchor_icac
    service.announce_joint_fabric_administrator(cluster, announce).should eq(Matter::InteractionModel::Status.success)
    cluster.request_peer_subject_ids = [0xFFFF_FFFD_FFFE_0002_u64]
    service.announce_joint_fabric_administrator(cluster, announce).should eq(Matter::InteractionModel::Status.success)
    cluster.request_peer_subject_ids = [0xFFFF_FFFD_FFFE_0000_u64]
    service.announce_joint_fabric_administrator(cluster, announce).should eq(Matter::InteractionModel::Status.unsupported_access)
  end

  it "returns status-only failures before Anchor authentication without issuing a CSR or installing an ICAC" do
    armed = false
    service = Matter::Commissioning::JointFabricAdministratorService.new(
      icac_key, root, fabric_id,
      -> { armed }, ->(_index : UInt8) { false },
      ->(_request : Matter::Cluster::JointFabricAdministrator::OpenJointCommissioningWindowRequest) { Matter::InteractionModel::Status.success },
      ->(_node : UInt64) { true }, -> { false }, -> { nil }, -> { nil }, crypto
    )
    cluster = Matter::Cluster::JointFabricAdministrator.new(Matter::DataType::EndpointNumber.new(1_u16))
    cluster.request_is_case_session = true
    cluster.request_fabric_index = 1_u8
    cluster.request_peer_subject_ids = [7_u64]
    service.icaccsr_request(cluster).should eq(Matter::InteractionModel::Status.failsafe_required)
    armed = true
    service.icaccsr_request(cluster).should eq(Matter::InteractionModel::Status.cluster_failure(
      Matter::Cluster::JointFabricAdministrator::ICACCSRResponseStatusCodeEnum::VIDNotVerified))
    cluster.administrator_fabric_index = 1_u8
    service.icaccsr_request(cluster).should eq(Matter::InteractionModel::Status.cluster_failure(
      Matter::Cluster::JointFabricAdministrator::ICACCSRResponseStatusCodeEnum::VIDNotVerified))
    # The SDK's same-root ICAC omits a Fabric ID in its subject.
    certificate = Matter::Crypto::MatterCertificate::Builder.intermediate(
      icac_key.public_key, nil, 2_u64, root_key, 1_u64, Bytes[0x02], crypto)
    service.add_icac(cluster, Matter::Cluster::JointFabricAdministrator::AddICACRequest.new(certificate))
      .as(Matter::Cluster::JointFabricAdministrator::ICACResponse).status_code.should eq(
      Matter::Cluster::JointFabricAdministrator::ICACResponseStatusEnum::InvalidPublicKey)
    service.cross_signed_icac.should be_nil
    service.icaccsr_request(cluster).should eq(Matter::InteractionModel::Status.constraint_error)
    # A status-only attempt on another fabric must not consume this fabric's
    # sole AddICAC attempt during the same fail-safe period.
    cluster.request_fabric_index = 2_u8
    service.icaccsr_request(cluster).should eq(Matter::InteractionModel::Status.cluster_failure(
      Matter::Cluster::JointFabricAdministrator::ICACCSRResponseStatusCodeEnum::VIDNotVerified))
    service.add_icac(cluster, Matter::Cluster::JointFabricAdministrator::AddICACRequest.new(certificate))
      .as(Matter::Cluster::JointFabricAdministrator::ICACResponse).status_code.should eq(
      Matter::Cluster::JointFabricAdministrator::ICACResponseStatusEnum::InvalidPublicKey)
    cluster.request_fabric_index = 1_u8
    service.icaccsr_request(cluster).should eq(Matter::InteractionModel::Status.constraint_error)
    service.reset_failsafe
    other_key = crypto.create_key_pair
    foreign_certificate = Matter::Crypto::MatterCertificate::Builder.intermediate(
      icac_key.public_key, fabric_id, 3_u64, other_key, 9_u64, Bytes[0x03], crypto)
    service.add_icac(cluster, Matter::Cluster::JointFabricAdministrator::AddICACRequest.new(foreign_certificate))
      .as(Matter::Cluster::JointFabricAdministrator::ICACResponse).status_code.should eq(
      Matter::Cluster::JointFabricAdministrator::ICACResponseStatusEnum::InvalidICAC)
    service.cross_signed_icac.should be_nil
  end

  it "rolls back a provisional cross-signed ICAC and persists it only after completion" do
    saved = nil.as(Bytes?)
    service = Matter::Commissioning::JointFabricAdministratorService.new(
      icac_key, root, fabric_id,
      -> { true }, ->(_index : UInt8) { true },
      ->(_request : Matter::Cluster::JointFabricAdministrator::OpenJointCommissioningWindowRequest) { Matter::InteractionModel::Status.success },
      ->(_node : UInt64) { true }, -> { false }, -> { nil }, -> { nil }, crypto,
      verify_anchor_initiator: ->(_node : UInt64, _fabric : UInt8, _peer : Socket::IPAddress) { true },
      persist_icac: ->(value : Bytes?) { saved = value; nil },
      failsafe_fabric_matches: ->(index : UInt8?) { index == 2_u8 }
    )
    cluster = Matter::Cluster::JointFabricAdministrator.new(Matter::DataType::EndpointNumber.new(1_u16))
    cluster.administrator_fabric_index = 1_u8
    cluster.request_is_case_session = true
    cluster.request_peer_subject_ids = [0xFFFF_FFFD_FFFE_0001_u64]
    cluster.request_peer_icac = anchor_icac
    cluster.request_peer_node_id = 7_u64
    cluster.request_fabric_index = 2_u8
    cluster.request_session_id = 3_u64
    cluster.request_peer_address = Socket::IPAddress.new("127.0.0.1", 5540)
    service.announce_joint_fabric_administrator(cluster,
      Matter::Cluster::JointFabricAdministrator::AnnounceJointFabricAdministratorRequest.new(1_u16))
    cross_signed = Matter::Crypto::MatterCertificate::Builder.intermediate(
      icac_key.public_key, fabric_id, 2_u64, root_key, 1_u64, Bytes[0x02], crypto
    )
    service.icaccsr_request(cluster)
    service.add_icac(cluster, Matter::Cluster::JointFabricAdministrator::AddICACRequest.new(cross_signed))
    service.on_failsafe_expired
    service.cross_signed_icac.should be_nil
    saved.should be_nil

    service.announce_joint_fabric_administrator(cluster,
      Matter::Cluster::JointFabricAdministrator::AnnounceJointFabricAdministratorRequest.new(1_u16))
    service.icaccsr_request(cluster)
    service.add_icac(cluster, Matter::Cluster::JointFabricAdministrator::AddICACRequest.new(cross_signed))
    service.on_commissioning_complete
    saved.should eq(cross_signed)
    service.on_failsafe_expired
    service.cross_signed_icac.should eq(cross_signed)
  end

  it "accepts an ICAC issued by the accessing Anchor fabric and switches AdministratorFabricIndex" do
    anchor_key = crypto.create_key_pair
    anchor_root = Matter::Crypto::MatterCertificate::Builder.root(anchor_key, 1_u64, Bytes[0x03], crypto)
    anchor_fabric_id = 0x5678_u64
    saved_icac = anchor_icac
    interrupt_before_icac_write = false
    interrupt_after_icac_write = false
    service = Matter::Commissioning::JointFabricAdministratorService.new(
      icac_key, root, fabric_id,
      -> { true }, ->(_index : UInt8) { true },
      ->(_request : Matter::Cluster::JointFabricAdministrator::OpenJointCommissioningWindowRequest) { Matter::InteractionModel::Status.success },
      ->(_node : UInt64) { true }, -> { false }, -> { nil }, -> { nil }, crypto,
      verify_anchor_initiator: ->(_node : UInt64, _fabric : UInt8, _peer : Socket::IPAddress) { true },
      resolve_accessing_fabric: ->(index : UInt8) {
        index == 2_u8 ? Matter::Commissioning::JointFabricAdministratorService::FabricIdentity.new(anchor_root, anchor_fabric_id) : nil
      },
      initial_icac: saved_icac,
      persist_icac: ->(value : Bytes?) {
        saved_icac = value.as(Bytes)
        raise Matter::StorageError.new("Interrupted after ICAC write") if interrupt_after_icac_write
        nil
      },
      failsafe_fabric_matches: ->(index : UInt8?) { index == 2_u8 }
    )
    cluster = Matter::Cluster::JointFabricAdministrator.new(Matter::DataType::EndpointNumber.new(1_u16))
    cluster.administrator_fabric_index = 1_u8
    cluster.request_is_case_session = true
    cluster.request_peer_subject_ids = [0xFFFF_FFFD_FFFE_0001_u64]
    cluster.request_peer_icac = anchor_icac
    cluster.request_peer_node_id = 7_u64
    cluster.request_fabric_index = 2_u8
    cluster.request_session_id = 3_u64
    cluster.request_peer_address = Socket::IPAddress.new("127.0.0.1", 5540)
    service.announce_joint_fabric_administrator(cluster,
      Matter::Cluster::JointFabricAdministrator::AnnounceJointFabricAdministratorRequest.new(1_u16))
    service.icaccsr_request(cluster)
    cross_signed = Matter::Crypto::MatterCertificate::Builder.intermediate(
      icac_key.public_key, anchor_fabric_id, 2_u64, anchor_key, 1_u64, Bytes[0x04], crypto
    )
    outcome = service.add_icac(cluster, Matter::Cluster::JointFabricAdministrator::AddICACRequest.new(cross_signed))
    outcome.as(Matter::Cluster::JointFabricAdministrator::ICACResponse).status_code.should eq(
      Matter::Cluster::JointFabricAdministrator::ICACResponseStatusEnum::OK)
    cluster.administrator_fabric_index.should eq(2_u8)
    # A crash may persist the attribute while the fail-safe and the service's
    # provisional ICAC are still in memory. Restoring that document must roll
    # back the uncommitted fabric selection before serving reads.
    restarted = Matter::Cluster::JointFabricAdministrator.new(Matter::DataType::EndpointNumber.new(1_u16))
    restarted.restore_state(cluster.save_state.as(Matter::Storage::Document))
    restarted.administrator_fabric_index.should eq(1_u8)
    path = File.join(Dir.tempdir, "matter-jfa-icac-commit-#{Random::Secure.hex(6)}.yml")
    backend = Matter::Storage::YamlFile.new(path)
    backend.open
    backend.write(Matter::Storage::Collections::APP, "icac",
      Matter::Storage::Document{"certificate" => anchor_icac})
    restarted_service = Matter::Commissioning::JointFabricAdministratorService.new(
      icac_key, root, fabric_id,
      -> { true }, ->(_index : UInt8) { true },
      ->(_request : Matter::Cluster::JointFabricAdministrator::OpenJointCommissioningWindowRequest) { Matter::InteractionModel::Status.success },
      ->(_node : UInt64) { true }, -> { false }, -> { nil }, -> { nil }, crypto,
      verify_anchor_initiator: ->(_node : UInt64, _fabric : UInt8, _peer : Socket::IPAddress) { true },
      resolve_accessing_fabric: ->(index : UInt8) {
        index == 2_u8 ? Matter::Commissioning::JointFabricAdministratorService::FabricIdentity.new(anchor_root, anchor_fabric_id) : nil
      },
      initial_icac: saved_icac,
      persist_icac: ->(value : Bytes?) {
        raise Matter::StorageError.new("Interrupted before ICAC write") if interrupt_before_icac_write
        saved_icac = value.as(Bytes)
        backend.transaction do
          backend.write(Matter::Storage::Collections::APP, "icac",
            Matter::Storage::Document{"certificate" => saved_icac.as(Bytes)})
          backend.write(Matter::Storage::Collections::CLUSTERS, restarted.persistence_key,
            restarted.save_state.as(Matter::Storage::Document))
        end
        raise Matter::StorageError.new("Interrupted after ICAC write") if interrupt_after_icac_write
        nil
      },
      failsafe_fabric_matches: ->(index : UInt8?) { index == 2_u8 }
    )
    restarted_service.cross_signed_icac.should eq(anchor_icac)
    restarted.request_is_case_session = true
    restarted.request_peer_subject_ids = [0xFFFF_FFFD_FFFE_0001_u64]
    restarted.request_peer_icac = anchor_icac
    restarted.request_peer_node_id = 7_u64
    restarted.request_fabric_index = 2_u8
    restarted.request_session_id = 3_u64
    restarted.request_peer_address = Socket::IPAddress.new("127.0.0.1", 5540)
    restarted_service.announce_joint_fabric_administrator(restarted,
      Matter::Cluster::JointFabricAdministrator::AnnounceJointFabricAdministratorRequest.new(1_u16))
    restarted_service.icaccsr_request(restarted).as(Matter::Cluster::JointFabricAdministrator::ICACCSRResponse).status_code.should eq(
      Matter::Cluster::JointFabricAdministrator::ICACCSRResponseStatusCodeEnum::OK)
    retried = restarted_service.add_icac(restarted, Matter::Cluster::JointFabricAdministrator::AddICACRequest.new(cross_signed))
    retried.as(Matter::Cluster::JointFabricAdministrator::ICACResponse).status_code.should eq(
      Matter::Cluster::JointFabricAdministrator::ICACResponseStatusEnum::OK)
    restarted_service.on_failsafe_expired
    restarted.administrator_fabric_index.should eq(1_u8)
    restarted_service.cross_signed_icac.should eq(anchor_icac)
    saved_icac.should eq(anchor_icac)

    restarted_service.announce_joint_fabric_administrator(restarted,
      Matter::Cluster::JointFabricAdministrator::AnnounceJointFabricAdministratorRequest.new(1_u16))
    restarted_service.icaccsr_request(restarted).as(Matter::Cluster::JointFabricAdministrator::ICACCSRResponse).status_code.should eq(
      Matter::Cluster::JointFabricAdministrator::ICACCSRResponseStatusCodeEnum::OK)
    committed = restarted_service.add_icac(restarted, Matter::Cluster::JointFabricAdministrator::AddICACRequest.new(cross_signed))
    committed.as(Matter::Cluster::JointFabricAdministrator::ICACResponse).status_code.should eq(
      Matter::Cluster::JointFabricAdministrator::ICACResponseStatusEnum::OK)
    # An interruption before the atomic write keeps both previous documents.
    backend.write(Matter::Storage::Collections::CLUSTERS, restarted.persistence_key,
      restarted.save_state.as(Matter::Storage::Document))
    interrupt_before_icac_write = true
    expect_raises(Matter::StorageError, "Interrupted before ICAC write") { restarted_service.on_commissioning_complete }
    backend.read(Matter::Storage::Collections::APP, "icac")
      .as(Matter::Storage::Document)["certificate"].should eq(anchor_icac)
    before_commit = Matter::Cluster::JointFabricAdministrator.new(Matter::DataType::EndpointNumber.new(1_u16))
    before_commit.restore_state(backend.read(Matter::Storage::Collections::CLUSTERS,
      restarted.persistence_key).as(Matter::Storage::Document))
    before_commit.administrator_fabric_index.should eq(1_u8)
    restarted.administrator_fabric_index.should eq(2_u8)
    interrupt_before_icac_write = false
    interrupt_after_icac_write = true
    expect_raises(Matter::StorageError, "Interrupted after ICAC write") { restarted_service.on_commissioning_complete }
    saved_icac.should eq(cross_signed)
    # A process loss here leaves the callback's transaction on disk while the
    # service has not cleared its in-memory provisional marker.
    reopened = Matter::Storage::YamlFile.new(path)
    reopened.open
    reopened.read(Matter::Storage::Collections::APP, "icac")
      .as(Matter::Storage::Document)["certificate"].should eq(cross_signed)
    interrupted_commit = Matter::Cluster::JointFabricAdministrator.new(Matter::DataType::EndpointNumber.new(1_u16))
    interrupted_commit.restore_state(reopened.read(Matter::Storage::Collections::CLUSTERS,
      restarted.persistence_key).as(Matter::Storage::Document))
    interrupted_commit.administrator_fabric_index.should eq(2_u8)
    reopened.close
    interrupt_after_icac_write = false
    restarted_service.on_commissioning_complete
    saved_icac.should eq(cross_signed)
    after_commit = Matter::Cluster::JointFabricAdministrator.new(Matter::DataType::EndpointNumber.new(1_u16))
    after_commit.restore_state(restarted.save_state.as(Matter::Storage::Document))
    after_commit.administrator_fabric_index.should eq(2_u8)

    service.on_failsafe_expired
    cluster.administrator_fabric_index.should eq(1_u8)
  ensure
    backend.try(&.close) if backend.try(&.open?)
    File.delete?(path) if path
  end
end
