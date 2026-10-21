require "../spec_helper"
require "../../src/matter/commissioning/joint_fabric_administrator_service"

describe Matter::Commissioning::JointFabricAdministratorService do
  crypto = Matter::Crypto::StandardCrypto.new
  root_key = crypto.create_key_pair
  icac_key = crypto.create_key_pair
  fabric_id = 0x1234_u64
  root = Matter::Crypto::MatterCertificate::Builder.root(root_key, 1_u64, Bytes[0x01], crypto)
  anchor_icac = Matter::Crypto::MatterCertificate::Builder.intermediate(
    icac_key.public_key, fabric_id, 3_u64, root_key, 1_u64, Bytes[0x06], crypto, anchor: true
  )

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
    service.icaccsr_request(cluster).should eq(Matter::InteractionModel::Status.cluster_failure(
      Matter::Cluster::JointFabricAdministrator::ICACCSRResponseStatusCodeEnum::VIDNotVerified))
    cluster.request_session_id = 3_u64
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
    cluster.request_session_id = 4_u64
    service.add_icac(cluster, Matter::Cluster::JointFabricAdministrator::AddICACRequest.new(cross_signed)).should eq(
      Matter::InteractionModel::Status.unsupported_access)
    cluster.request_session_id = 3_u64
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
    service.transfer_anchor_complete(cluster).should eq(Matter::InteractionModel::Status.unsupported_access)
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
    invalid = Matter::Cluster::JointFabricAdministrator::OpenJointCommissioningWindowRequest.new(
      180_u16, Bytes.new(96, 0_u8), 3839_u16, 2000_u32, Bytes.new(16, 0_u8))
    service.open_joint_commissioning_window(cluster, invalid).should eq(Matter::InteractionModel::Status.invalid_command)
    opened.should eq(0)
    service.open_joint_commissioning_window(cluster, valid).should eq(Matter::InteractionModel::Status.success)
    service.open_joint_commissioning_window(cluster, valid).should eq(Matter::InteractionModel::Status.cluster_failure(
      Matter::Cluster::JointFabricAdministrator::ICACCSRResponseStatusCodeEnum::Busy))
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
    certificate = Matter::Crypto::MatterCertificate::Builder.intermediate(
      icac_key.public_key, fabric_id, 2_u64, root_key, 1_u64, Bytes[0x02], crypto)
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
    service = Matter::Commissioning::JointFabricAdministratorService.new(
      icac_key, root, fabric_id,
      -> { true }, ->(_index : UInt8) { true },
      ->(_request : Matter::Cluster::JointFabricAdministrator::OpenJointCommissioningWindowRequest) { Matter::InteractionModel::Status.success },
      ->(_node : UInt64) { true }, -> { false }, -> { nil }, -> { nil }, crypto,
      verify_anchor_initiator: ->(_node : UInt64, _fabric : UInt8, _peer : Socket::IPAddress) { true },
      resolve_accessing_fabric: ->(index : UInt8) {
        index == 2_u8 ? Matter::Commissioning::JointFabricAdministratorService::FabricIdentity.new(anchor_root, anchor_fabric_id) : nil
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
    service.on_failsafe_expired
    cluster.administrator_fabric_index.should eq(1_u8)
  end
end
