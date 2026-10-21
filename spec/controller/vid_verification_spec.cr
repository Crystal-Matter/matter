require "../spec_helper"
require "../../src/matter/controller/vid_verification"
require "../../src/matter/controller/joint_commissioning"

private class VidTestTrust < Matter::Controller::VidVerification::OperationalTrustAnchors
  property? allow_root = true

  def trusted_root?(vendor_id : UInt16, root_certificate : Bytes) : Bool
    @allow_root && vendor_id == 0x1234_u16
  end

  def verify_statement?(vendor_id : UInt16, signer_skid : Bytes, statement_tbs : Bytes,
                        signature : Bytes, vvsc : Bytes?) : Bool
    false
  end
end

private class VidTestIm < Matter::Controller::ImClient
  getter non_filtered_reads = 0

  def initialize(
    client : Matter::Controller::Client,
    @descriptor : Matter::Cluster::OperationalCredentials::Tlv::FabricDescriptor,
    @noc : Matter::Cluster::OperationalCredentials::Tlv::NOC,
    @root : Bytes,
    @node_key : Matter::Crypto::Key,
  )
    super(client)
  end

  def read_attribute(session : Matter::Session::SecureContext, peer : Socket::IPAddress,
                     endpoint_id : UInt16, cluster_id : UInt32, attribute_id : UInt32,
                     fabric_filtered : Bool = true) : Matter::InteractionModel::ReportDataMessage
    @non_filtered_reads += 1 unless fabric_filtered
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
    io = IO::Memory.new
    io.write_byte 1_u8
    io.write request.client_challenge
    io.write session.attestation_challenge.as(Bytes)
    io.write_byte request.fabric_index
    io.write Matter::Controller::VidVerification.binding_message(@descriptor)
    signature = Matter::Crypto::StandardCrypto.new.sign_ecdsa(@node_key, io.to_slice)
    response = Matter::Cluster::OperationalCredentials::Tlv::SignVIDVerificationResponse.new(request.fabric_index, 1_u8, signature)
    path = Matter::InteractionModel::CommandPath.new(endpoint: endpoint_id, cluster: cluster_id,
      command: Matter::Cluster::OperationalCredentials::CMD_SIGN_VID_VERIFICATION_REQUEST_RESPONSE)
    data = Matter::InteractionModel::CommandDataIBTlv.new(path, TLV::Any.from_slice(response.to_slice))
    Matter::InteractionModel::InvokeResponseMessage.new(
      invoke_responses: [Matter::InteractionModel::InvokeResponseIB.new(command_data: data)])
  end
end

describe Matter::Controller::VidVerification do
  it "accepts only an explicitly provisioned Vendor ID and exact root" do
    crypto = Matter::Crypto::StandardCrypto.new
    key = crypto.create_key_pair
    root = Matter::Crypto::MatterCertificate::Builder.root(key, 1_u64, Bytes[0x01], crypto)
    trust = Matter::Controller::VidVerification::StaticOperationalTrustAnchors.new(
      {0x1234_u16 => [root]}
    )
    trust.trusted_root?(0x1234_u16, root).should be_true
    trust.trusted_root?(0x4321_u16, root).should be_false
    other = Matter::Crypto::MatterCertificate::Builder.root(crypto.create_key_pair, 1_u64, Bytes[0x02], crypto)
    trust.trusted_root?(0x1234_u16, other).should be_false
  end

  it "checks challenge, NOC chain and an externally trusted VID binding" do
    crypto = Matter::Crypto::StandardCrypto.new
    root_key = crypto.create_key_pair
    icac_key = crypto.create_key_pair
    node_key = crypto.create_key_pair
    root = Matter::Crypto::MatterCertificate::Builder.root(root_key, 1_u64, Bytes[0x01], crypto)
    icac = Matter::Crypto::MatterCertificate::Builder.intermediate(icac_key.public_key,
      0x1111_u64, 2_u64, root_key, 1_u64, Bytes[0x02], crypto)
    noc = Matter::Crypto::MatterCertificate::Builder.node(node_key.public_key,
      0x1111_u64, 0x2222_u64, icac_key, 1_u64, Bytes[0x03], crypto,
      case_authenticated_tag: 0xFFFF_0001_u32, issuer_icac_id: 2_u64)
    descriptor = Matter::Cluster::OperationalCredentials::Tlv::FabricDescriptor.new(
      root_key.public_key, 0x1234_u16, 0x1111_u64, 0x2222_u64, "joiner", 1_u8)
    noc_entry = Matter::Cluster::OperationalCredentials::Tlv::NOC.new(noc, icac, 1_u8)
    client = Matter::Controller::Client.new
    im = VidTestIm.new(client, descriptor, noc_entry, root, node_key)
    session = Matter::Session::SecureContext.new(
      session_id: 1_u16, peer_session_id: 2_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16), decryption_key: Bytes.new(16),
      attestation_challenge: Bytes.new(16, 0xA5_u8)
    )
    peer = Socket::IPAddress.new("127.0.0.1", 5540)
    trust = VidTestTrust.new
    verified = Matter::Controller::VidVerification.verify(im, session, peer, 1_u8, trust)
    verified.descriptor.vendor_id.should eq(0x1234_u16)
    im.non_filtered_reads.should eq(3)
    joiner = Matter::Controller::JointCommissioning.verify_joiner(im, session, peer, 1_u8, trust)
    joiner.icac_public_key.should eq(icac_key.public_key)
    trust.allow_root = false
    expect_raises(Matter::AuthenticationError) do
      Matter::Controller::VidVerification.verify(im, session, peer, 1_u8, trust)
    end
  ensure
    client.try(&.close)
  end
end
