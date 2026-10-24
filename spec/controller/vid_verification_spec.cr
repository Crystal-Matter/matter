require "../spec_helper"
require "../../src/matter/controller/vid_verification"
require "../../src/matter/controller/joint_commissioning"

# Matter 1.6 Core Appendix F.5 vectors, copied from connectedhomeip v1.6.0.0
# src/crypto/tests/TestChipCryptoPAL.cpp:3433-3438,3462-3469,3585-3597.
private VID_SDK_BINDING = "0104d59f3eb0b9c216a46f040affdfd55817ca8a3dc921aa624da5168ba90766d73bf08e480cd0f5cc94653a92d77719d9b004747d5f7da39dedb67ec54f7cbc6ade1122334455667788fff1"
private VID_SDK_VVS     = "21fac0e7d0089473f15c2dfefe546fffa0b00a8bb2323284af7738f9b321d00bbf2bff942c8215c498dfddb1b66b34fbd7db318ad754829cd5ca1d9cf53beb2c93571af35257eead6714f68e910f7bb7ac9a909a72"
private VID_SDK_TBS     = "01c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0145f2ef39e3e4ffcf5649c0909cbc8e4050104d59f3eb0b9c216a46f040affdfd55817ca8a3dc921aa624da5168ba90766d73bf08e480cd0f5cc94653a92d77719d9b004747d5f7da39dedb67ec54f7cbc6ade1122334455667788fff121fac0e7d0089473f15c2dfefe546fffa0b00a8bb2323284af7738f9b321d00bbf2bff942c8215c498dfddb1b66b34fbd7db318ad754829cd5ca1d9cf53beb2c93571af35257eead6714f68e910f7bb7ac9a909a72"

private class VidTestTrust < Matter::Controller::VidVerification::OperationalTrustAnchors
  property? allow_root = true
  property? allow_statement = false
  getter statement_tbs : Bytes?

  def trusted_root?(vendor_id : UInt16, root_certificate : Bytes) : Bool
    @allow_root && vendor_id == 0x1234_u16
  end

  def verify_statement?(vendor_id : UInt16, signer_skid : Bytes, statement_tbs : Bytes,
                        signature : Bytes, vvsc : Bytes?) : Bool
    @statement_tbs = statement_tbs.dup
    @allow_statement
  end
end

private class VidSdkVectorCrypto < Matter::Crypto::StandardCrypto
  getter signed_tbs : Bytes?

  def random_bytes(length : Int32) : Bytes
    return "c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0".hexbytes if length == 32
    super
  end

  def verify_ecdsa(public_key : Matter::Crypto::Key, data : Bytes, signature : Bytes,
                   dsa_encoding : String = "ieee-p1363") : Nil
    @signed_tbs = data.dup
    super
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
    if statement = @descriptor.vid_verification_statement
      io.write statement
    end
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
  it "matches the official Matter 1.6 Appendix F.5 fabric-binding bytes" do
    binding = VID_SDK_BINDING.hexbytes
    descriptor = Matter::Cluster::OperationalCredentials::Tlv::FabricDescriptor.new(
      binding[1, 65], 0xFFF1_u16, 0x1122_3344_5566_7788_u64, 0x2222_u64, "sdk-vector", 5_u8)
    Matter::Controller::VidVerification.binding_message(descriptor).should eq(binding)
  end

  it "signs the SDK Appendix F.5 VID message including the supplied statement" do
    crypto = Matter::Crypto::StandardCrypto.new
    root_key = crypto.create_key_pair
    node_key = crypto.create_key_pair
    root = Matter::Crypto::MatterCertificate::Builder.root(root_key, 1_u64, Bytes[0x01], crypto)
    noc = Matter::Crypto::MatterCertificate::Builder.node(node_key.public_key,
      0x1122_3344_5566_7788_u64, 0x2222_u64, root_key, 1_u64, Bytes[0x02], crypto)
    statement = VID_SDK_VVS.hexbytes
    descriptor = Matter::Cluster::OperationalCredentials::Tlv::FabricDescriptor.new(
      root_key.public_key, 0xFFF1_u16, 0x1122_3344_5566_7788_u64,
      0x2222_u64, "sdk-vector", 5_u8, statement)
    noc_entry = Matter::Cluster::OperationalCredentials::Tlv::NOC.new(noc, nil, 5_u8)
    client = Matter::Controller::Client.new
    im = VidTestIm.new(client, descriptor, noc_entry, root, node_key)
    session = Matter::Session::SecureContext.new(
      session_id: 1_u16, peer_session_id: 2_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16), decryption_key: Bytes.new(16),
      attestation_challenge: "145f2ef39e3e4ffcf5649c0909cbc8e4".hexbytes)
    trust = VidTestTrust.new
    trust.allow_statement = true
    vector_crypto = VidSdkVectorCrypto.new
    Matter::Controller::VidVerification.verify(im, session,
      Socket::IPAddress.new("127.0.0.1", 5540), 5_u8, trust, vector_crypto)

    # The published fixture has no corresponding root private key. Replace only
    # its 65-byte root public key to make a valid, locally signed NOC chain.
    expected_tbs = VID_SDK_TBS.hexbytes
    expected_tbs[51, 65].copy_from(root_key.public_key)
    vector_crypto.signed_tbs.should eq(expected_tbs)

    expected_statement_tbs = IO::Memory.new
    expected_statement_tbs.write_byte 0x21_u8
    expected_statement_tbs.write expected_tbs[50, 76]
    expected_statement_tbs.write statement[1, 20]
    trust.statement_tbs.should eq(expected_statement_tbs.to_slice)
  ensure
    client.try(&.close)
  end

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

  it "separates explicit root trust from statement signer trust" do
    root_trust = VidTestTrust.new
    signer_trust = VidTestTrust.new
    signer_trust.allow_root = false
    signer_trust.allow_statement = true
    trust = Matter::Controller::VidVerification::CompositeOperationalTrustAnchors.new(root_trust, signer_trust)

    trust.trusted_root?(0x1234_u16, Bytes[0x01]).should be_true
    trust.verify_statement?(0x1234_u16, Bytes.empty, Bytes.empty, Bytes.empty, nil).should be_true

    root_trust.allow_root = false
    root_trust.allow_statement = true
    signer_trust.allow_root = true
    signer_trust.allow_statement = false
    trust.trusted_root?(0x1234_u16, Bytes[0x01]).should be_false
    trust.verify_statement?(0x1234_u16, Bytes.empty, Bytes.empty, Bytes.empty, nil).should be_false
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

    both = Matter::Cluster::OperationalCredentials::Tlv::NOC.new(noc, icac, 1_u8, Bytes[0x01])
    im_both = VidTestIm.new(client, descriptor, both, root, node_key)
    expect_raises(Matter::AuthenticationError, /ICAC and VVSC/) do
      Matter::Controller::VidVerification.verify(im_both, session, peer, 1_u8, trust)
    end

    trust.allow_root = false
    expect_raises(Matter::AuthenticationError) do
      Matter::Controller::VidVerification.verify(im, session, peer, 1_u8, trust)
    end
  ensure
    client.try(&.close)
  end
end
