require "../spec_helper"
require "../../src/matter/controller/administrator_removal"

private class RotationProofIm < Matter::Controller::ImClient
  getter challenges = [] of Bytes
  property? tamper_signature = false
  property? omit_statement = false
  property replay_challenge : Bytes?

  def initialize(client : Matter::Controller::Client,
                 @descriptor : Matter::Cluster::OperationalCredentials::Tlv::FabricDescriptor,
                 @noc : Matter::Cluster::OperationalCredentials::Tlv::NOC,
                 @root : Bytes, @node_key : Matter::Crypto::Key)
    super(client)
  end

  def read_attribute(session : Matter::Session::SecureContext, peer : Socket::IPAddress,
                     endpoint_id : UInt16, cluster_id : UInt32, attribute_id : UInt32,
                     fabric_filtered : Bool = true) : Matter::InteractionModel::ReportDataMessage
    value = case attribute_id
            when Matter::Cluster::OperationalCredentials::ATTR_NOCS
              [@noc].to_tlv
            when Matter::Cluster::OperationalCredentials::ATTR_FABRICS
              [@descriptor].to_tlv
            else
              [@root].to_tlv
            end
    path = Matter::InteractionModel::AttributePath.new(endpoint: endpoint_id, cluster: cluster_id, attribute: attribute_id)
    data = Matter::InteractionModel::AttributeDataIB.new(path: path, data: TLV::Any.from_slice(value))
    Matter::InteractionModel::ReportDataMessage.new(attribute_reports: [Matter::InteractionModel::AttributeReportIB.new(attribute_data: data)])
  end

  def invoke(session : Matter::Session::SecureContext, peer : Socket::IPAddress,
             endpoint_id : UInt16, cluster_id : UInt32, command_id : UInt32,
             fields : Bytes = Bytes.empty) : Matter::InteractionModel::InvokeResponseMessage
    request = Matter::Cluster::OperationalCredentials::Tlv::SignVIDVerificationRequest.from_slice(fields)
    @challenges << request.client_challenge.dup
    io = IO::Memory.new
    io.write_byte 1_u8
    io.write(@replay_challenge || request.client_challenge)
    io.write session.attestation_challenge.as(Bytes)
    io.write_byte request.fabric_index
    io.write Matter::Controller::VidVerification.binding_message(@descriptor)
    if statement = @descriptor.vid_verification_statement
      io.write statement unless omit_statement?
    end
    signature = Matter::Crypto::StandardCrypto.new.sign_ecdsa(@node_key, io.to_slice)
    signature[0] ^= 1_u8 if tamper_signature?
    response = Matter::Cluster::OperationalCredentials::Tlv::SignVIDVerificationResponse.new(request.fabric_index, 1_u8, signature)
    path = Matter::InteractionModel::CommandPath.new(endpoint: endpoint_id, cluster: cluster_id,
      command: Matter::Cluster::OperationalCredentials::CMD_SIGN_VID_VERIFICATION_REQUEST_RESPONSE)
    data = Matter::InteractionModel::CommandDataIBTlv.new(path, TLV::Any.from_slice(response.to_slice))
    Matter::InteractionModel::InvokeResponseMessage.new(
      invoke_responses: [Matter::InteractionModel::InvokeResponseIB.new(command_data: data)])
  end
end

describe Matter::Controller::AdministratorRemoval::RotationInspection do
  it "authenticates the new CAT against the journaled fabric and nonce before resolving a lost acknowledgment" do
    crypto = Matter::Crypto::StandardCrypto.new
    root_key = crypto.create_key_pair
    icac_key = crypto.create_key_pair
    node_key = crypto.create_key_pair
    root = Matter::Crypto::MatterCertificate::Builder.root(root_key, 1_u64, Bytes[1], crypto)
    icac = Matter::Crypto::MatterCertificate::Builder.intermediate(icac_key.public_key,
      0x1111_u64, 2_u64, root_key, 1_u64, Bytes[2], crypto)
    descriptor = Matter::Cluster::OperationalCredentials::Tlv::FabricDescriptor.new(
      root_key.public_key, 0x1234_u16, 0x1111_u64, 0x2222_u64, "anchor", 1_u8)
    client = Matter::Controller::Client.new
    session = Matter::Session::SecureContext.new(
      session_id: 1_u16, peer_session_id: 2_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16), decryption_key: Bytes.new(16),
      peer_node_id: Matter::DataType::NodeId.new(0x2222_u64), case_session: true,
      attestation_challenge: Bytes.new(16, 0xA5_u8))
    peer = Socket::IPAddress.new("127.0.0.1", 5540)
    nonce = Bytes.new(32, 0x6A_u8)
    proof = Matter::Controller::AdministratorRemoval::RotationInspection

    old_noc = Matter::Crypto::MatterCertificate::Builder.node(node_key.public_key,
      0x1111_u64, 0x2222_u64, icac_key, 1_u64, Bytes[3], crypto,
      case_authenticated_tag: 0xFFFF_0001_u32, issuer_icac_id: 2_u64)
    old_im = RotationProofIm.new(client, descriptor,
      Matter::Cluster::OperationalCredentials::Tlv::NOC.new(old_noc, icac, 1_u8), root, node_key)
    expect_raises(Matter::AuthenticationError, /journaled Administrator CAT/) do
      proof.verify_completed!(old_im, session, peer, root, 0x1111_u64, root_key.public_key,
        0x2222_u64, 2_u16, nonce)
    end

    new_noc = Matter::Crypto::MatterCertificate::Builder.node(node_key.public_key,
      0x1111_u64, 0x2222_u64, icac_key, 1_u64, Bytes[4], crypto,
      case_authenticated_tags: [0xFFFF_0002_u32, 0xFFFE_0001_u32], issuer_icac_id: 2_u64)
    im = RotationProofIm.new(client, descriptor,
      Matter::Cluster::OperationalCredentials::Tlv::NOC.new(new_noc, icac, 1_u8), root, node_key)
    proof.verify_completed!(im, session, peer, root, 0x1111_u64, root_key.public_key,
      0x2222_u64, 2_u16, nonce, anchor_cat_version: 1_u16)
    im.challenges.should eq([nonce])
    expect_raises(Matter::AuthenticationError, /Anchor CAT/) do
      proof.verify_completed!(im, session, peer, root, 0x1111_u64, root_key.public_key,
        0x2222_u64, 2_u16, nonce, anchor_cat_version: 2_u16)
    end
    statement = Bytes.new(85, 0x21_u8)
    vvs_descriptor = Matter::Cluster::OperationalCredentials::Tlv::FabricDescriptor.new(
      root_key.public_key, 0x1234_u16, 0x1111_u64, 0x2222_u64, "anchor", 1_u8, statement)
    vvs_im = RotationProofIm.new(client, vvs_descriptor,
      Matter::Cluster::OperationalCredentials::Tlv::NOC.new(new_noc, icac, 1_u8), root, node_key)
    proof.verify_completed!(vvs_im, session, peer, root, 0x1111_u64, root_key.public_key,
      0x2222_u64, 2_u16, nonce)
    vvs_im.omit_statement = true
    expect_raises(Matter::AuthenticationError) do
      proof.verify_completed!(vvs_im, session, peer, root, 0x1111_u64, root_key.public_key,
        0x2222_u64, 2_u16, nonce)
    end
    expect_raises(Matter::AuthenticationError, /journaled Node ID/) do
      proof.verify_completed!(im, session, peer, root, 0x1111_u64, root_key.public_key,
        0x3333_u64, 2_u16, nonce)
    end
    expect_raises(Matter::AuthenticationError, /journaled fabric identity/) do
      proof.verify_completed!(im, session, peer, root, 0x9999_u64, root_key.public_key,
        0x2222_u64, 2_u16, nonce)
    end
    wrong_root = Matter::Crypto::MatterCertificate::Builder.root(crypto.create_key_pair,
      1_u64, Bytes[9], crypto)
    expect_raises(Matter::AuthenticationError, /trusted root/) do
      proof.verify_completed!(im, session, peer, wrong_root, 0x1111_u64, root_key.public_key,
        0x2222_u64, 2_u16, nonce)
    end
    im.replay_challenge = Bytes.new(32, 0x2B_u8)
    expect_raises(Matter::AuthenticationError) do
      proof.verify_completed!(im, session, peer, root, 0x1111_u64, root_key.public_key,
        0x2222_u64, 2_u16, nonce)
    end
    im.replay_challenge = nil
    im.tamper_signature = true
    expect_raises(Matter::AuthenticationError) do
      proof.verify_completed!(im, session, peer, root, 0x1111_u64, root_key.public_key,
        0x2222_u64, 2_u16, nonce)
    end
  ensure
    client.try(&.close)
  end
end
