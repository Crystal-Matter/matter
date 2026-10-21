require "../spec_helper"
require "../../src/matter/controller/pairing/case_pairing"
require "../../src/matter/controller/joint_commissioning"

private def case_test_fabric : Matter::Controller::FabricInfo
  authority = TestCertificateAuthority.default
  Matter::Controller::FabricInfo.new(
    fabric_id: TestCertificateAuthority::DEFAULT_FABRIC_ID,
    controller_node_id: 0x1234_u64,
    ipk_value: Bytes.new(16, 0_u8),
    root_cert: authority.root_certificate,
    root_public_key: authority.root_public_key,
    controller_noc: authority.issue(node_id: 0x1234_u64),
    controller_private_key: authority.node_key.private_key
  )
end

private def case_sigma2(noc : Bytes, key : Matter::Crypto::Key,
                        icac : Bytes? = nil) : Matter::Session::Case::Definitions::EncryptedDataSigma2
  signed = Matter::Session::Case::Definitions::SignedData.new(
    responder_noc: noc,
    responder_icac: icac,
    responder_public_key: Bytes.new(65, 1_u8),
    initiator_public_key: Bytes.new(65, 2_u8)
  )
  signature = Matter::Crypto::StandardCrypto.new.sign_ecdsa(key, signed.to_slice)
  Matter::Session::Case::Definitions::EncryptedDataSigma2.new(noc, icac, signature, Bytes.new(16, 0_u8))
end

private def case_resign_certificate(certificate : Bytes, issuer_key : Matter::Crypto::Key,
                                    & : TLV::Structure -> Nil) : Bytes
  fields = TLV::Any.from_slice(certificate).as_structure
  yield fields
  unsigned = Matter::Crypto::MatterCertificate::Asn1.to_unsigned_asn1(TLV::Any.new(fields, nil))
  signature = Matter::Crypto::StandardCrypto.new.sign_ecdsa(issuer_key, unsigned)
  fields[Matter::Crypto::MatterCertificate::Asn1::Field::Signature.value] =
    TLV::Any.new(signature, Matter::Crypto::MatterCertificate::Asn1::Field::Signature.value)
  TLV::Any.new(fields, nil).to_slice
end

describe Matter::Controller::Pairing::CasePairing do
  it "accepts a trusted Sigma2 NOC naming the requested peer" do
    authority = TestCertificateAuthority.default
    noc = authority.issue
    encrypted = case_sigma2(noc, authority.node_key)

    verified = Matter::Controller::Pairing::CasePairing.new.verify_sigma2_signature(
      encrypted, Bytes.new(65, 1_u8), Bytes.new(65, 2_u8),
      case_test_fabric, TestCertificateAuthority::DEFAULT_NODE_ID
    )
    verified.subject_ids.should contain(TestCertificateAuthority::DEFAULT_NODE_ID)
    verified.icac.should be_nil
  end

  it "retains authenticated Anchor CAT and ICAC from Sigma2" do
    bootstrap = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      0x1234_u64, 0x100_u64, 0xFFF1_u16)
    responder_key = Matter::Crypto::Key.generate_key_pair
    noc = bootstrap.issue_anchor_administrator_noc(0x200_u64, responder_key.public_key)
    icac = bootstrap.fabric.intermediate_cert.as(Bytes)
    encrypted = case_sigma2(noc, responder_key, icac)

    verified = Matter::Controller::Pairing::CasePairing.new.verify_sigma2_signature(
      encrypted, Bytes.new(65, 1_u8), Bytes.new(65, 2_u8),
      bootstrap.fabric, 0x200_u64)
    verified.subject_ids.should contain(0xFFFF_FFFD_FFFE_0001_u64)
    verified.icac.should eq(icac)
  end

  it "rejects a valid signature from a NOC issued by another root" do
    authority = TestCertificateAuthority.new
    encrypted = case_sigma2(authority.issue, authority.node_key)

    expect_raises(Matter::AuthenticationError) do
      Matter::Controller::Pairing::CasePairing.new.verify_sigma2_signature(
        encrypted, Bytes.new(65, 1_u8), Bytes.new(65, 2_u8),
        case_test_fabric, TestCertificateAuthority::DEFAULT_NODE_ID
      )
    end
  end

  it "rejects a trusted NOC naming another node" do
    authority = TestCertificateAuthority.default
    encrypted = case_sigma2(authority.issue(node_id: 0x9999_u64), authority.node_key)

    expect_raises(Matter::AuthenticationError, /does not match/) do
      Matter::Controller::Pairing::CasePairing.new.verify_sigma2_signature(
        encrypted, Bytes.new(65, 1_u8), Bytes.new(65, 2_u8),
        case_test_fabric, TestCertificateAuthority::DEFAULT_NODE_ID
      )
    end
  end

  it "rejects an expired NOC even when its CASE signature is valid" do
    authority = TestCertificateAuthority.default
    encrypted = case_sigma2(authority.issue, authority.node_key)

    Timecop.travel(Time.utc + 11.years) do
      expect_raises(Matter::AuthenticationError, /validity interval/) do
        Matter::Controller::Pairing::CasePairing.new.verify_sigma2_signature(
          encrypted, Bytes.new(65, 1_u8), Bytes.new(65, 2_u8),
          case_test_fabric, TestCertificateAuthority::DEFAULT_NODE_ID
        )
      end
    end
  end

  it "accepts Matter's zero NotAfter as unbounded validity" do
    authority = TestCertificateAuthority.default
    noc = case_resign_certificate(authority.issue, authority.key) do |fields|
      fields[Matter::Crypto::MatterCertificate::Asn1::Field::NotAfter.value] =
        TLV::Any.new(0_u32, Matter::Crypto::MatterCertificate::Asn1::Field::NotAfter.value)
    end
    encrypted = case_sigma2(noc, authority.node_key)

    Timecop.travel(Time.utc + 11.years) do
      verified = Matter::Controller::Pairing::CasePairing.new.verify_sigma2_signature(
        encrypted, Bytes.new(65, 1_u8), Bytes.new(65, 2_u8),
        case_test_fabric, TestCertificateAuthority::DEFAULT_NODE_ID)
      verified.subject_ids.should contain(TestCertificateAuthority::DEFAULT_NODE_ID)
    end
  end

  it "rejects an ICAC for another fabric even when the chain signatures are valid" do
    authority = TestCertificateAuthority.default
    intermediate_key = Matter::Crypto::Key.generate_key_pair
    other_fabric_id = TestCertificateAuthority::DEFAULT_FABRIC_ID + 1_u64
    icac = Matter::Crypto::MatterCertificate::Builder.intermediate(
      public_key: intermediate_key.public_key,
      fabric_id: other_fabric_id,
      icac_id: 2_u64,
      issuer_key: authority.key,
      issuer_rcac_id: TestCertificateAuthority::ROOT_CERTIFICATE_ID,
      serial: Bytes.new(TestCertificateAuthority::SERIAL_BYTES, 1_u8)
    )
    noc = Matter::Crypto::MatterCertificate::Builder.node(
      public_key: authority.node_public_key,
      fabric_id: TestCertificateAuthority::DEFAULT_FABRIC_ID,
      node_id: TestCertificateAuthority::DEFAULT_NODE_ID,
      issuer_key: intermediate_key,
      issuer_rcac_id: TestCertificateAuthority::ROOT_CERTIFICATE_ID,
      issuer_icac_id: 2_u64,
      serial: Bytes.new(TestCertificateAuthority::SERIAL_BYTES, 2_u8)
    )

    expect_raises(Matter::AuthenticationError, /different fabrics/) do
      Matter::Controller::Pairing::CasePairing.new.verify_sigma2_signature(
        case_sigma2(noc, authority.node_key, icac), Bytes.new(65, 1_u8), Bytes.new(65, 2_u8),
        case_test_fabric, TestCertificateAuthority::DEFAULT_NODE_ID
      )
    end
  end

  it "rejects an ICAC without keyCertSign usage" do
    authority = TestCertificateAuthority.default
    intermediate_key = Matter::Crypto::Key.generate_key_pair
    icac = Matter::Crypto::MatterCertificate::Builder.intermediate(
      public_key: intermediate_key.public_key,
      fabric_id: TestCertificateAuthority::DEFAULT_FABRIC_ID,
      icac_id: 2_u64, issuer_key: authority.key,
      issuer_rcac_id: TestCertificateAuthority::ROOT_CERTIFICATE_ID,
      serial: Bytes.new(TestCertificateAuthority::SERIAL_BYTES, 1_u8))
    restricted_icac = case_resign_certificate(icac, authority.key) do |fields|
      extensions = fields[Matter::Crypto::MatterCertificate::Asn1::Field::Extensions.value].as_list
      usage_tag = Matter::Crypto::MatterCertificate::Asn1::Extension::KeyUsage.value
      index = extensions.index { |extension| extension.header.ids == usage_tag }.as(Int32)
      extensions[index] = TLV::Any.new(1_u16, usage_tag)
    end
    noc = Matter::Crypto::MatterCertificate::Builder.node(
      public_key: authority.node_public_key,
      fabric_id: TestCertificateAuthority::DEFAULT_FABRIC_ID,
      node_id: TestCertificateAuthority::DEFAULT_NODE_ID,
      issuer_key: intermediate_key,
      issuer_rcac_id: TestCertificateAuthority::ROOT_CERTIFICATE_ID,
      issuer_icac_id: 2_u64,
      serial: Bytes.new(TestCertificateAuthority::SERIAL_BYTES, 2_u8))

    expect_raises(Matter::AuthenticationError, /cannot sign certificates/) do
      Matter::Controller::Pairing::CasePairing.new.verify_sigma2_signature(
        case_sigma2(noc, authority.node_key, restricted_icac),
        Bytes.new(65, 1_u8), Bytes.new(65, 2_u8),
        case_test_fabric, TestCertificateAuthority::DEFAULT_NODE_ID)
    end
  end

  it "requires the NOC issuer DN to reproduce the full Anchor ICAC subject" do
    authority = TestCertificateAuthority.default
    icac_key = Matter::Crypto::Key.generate_key_pair
    icac = Matter::Crypto::MatterCertificate::Builder.intermediate(
      public_key: icac_key.public_key,
      fabric_id: TestCertificateAuthority::DEFAULT_FABRIC_ID,
      icac_id: 2_u64,
      issuer_key: authority.key,
      issuer_rcac_id: TestCertificateAuthority::ROOT_CERTIFICATE_ID,
      serial: Bytes.new(TestCertificateAuthority::SERIAL_BYTES, 1_u8),
      anchor: true)
    issuer_options = {
      public_key:     authority.node_public_key,
      fabric_id:      TestCertificateAuthority::DEFAULT_FABRIC_ID,
      node_id:        TestCertificateAuthority::DEFAULT_NODE_ID,
      issuer_key:     icac_key,
      issuer_rcac_id: TestCertificateAuthority::ROOT_CERTIFICATE_ID,
      issuer_icac_id: 2_u64,
      serial:         Bytes.new(TestCertificateAuthority::SERIAL_BYTES, 2_u8),
    }
    complete = Matter::Crypto::MatterCertificate::Builder.node(**issuer_options, issuer_certificate: icac)
    Matter::Crypto::MatterCertificate::Validation.verify_chain(
      complete, icac, authority.root_public_key, authority.root_certificate)

    missing_org_unit = Matter::Crypto::MatterCertificate::Builder.node(**issuer_options)
    expect_raises(Matter::AuthenticationError, /issuer name/) do
      Matter::Crypto::MatterCertificate::Validation.verify_chain(
        missing_org_unit, icac, authority.root_public_key, authority.root_certificate)
    end
  end

  it "rejects a NOC without digitalSignature usage or serverAuth purpose" do
    authority = TestCertificateAuthority.default
    noc = authority.issue
    usage_tag = Matter::Crypto::MatterCertificate::Asn1::Extension::KeyUsage.value
    purposes_tag = Matter::Crypto::MatterCertificate::Asn1::Extension::ExtendedKeyUsage.value

    no_signature_usage = case_resign_certificate(noc, authority.key) do |fields|
      extensions = fields[Matter::Crypto::MatterCertificate::Asn1::Field::Extensions.value].as_list
      index = extensions.index { |extension| extension.header.ids == usage_tag }.as(Int32)
      extensions[index] = TLV::Any.new(0_u16, usage_tag)
    end
    no_server_auth = case_resign_certificate(noc, authority.key) do |fields|
      extensions = fields[Matter::Crypto::MatterCertificate::Asn1::Field::Extensions.value].as_list
      index = extensions.index { |extension| extension.header.ids == purposes_tag }.as(Int32)
      extensions[index] = TLV::Any.new(TLV::List{TLV::Any.new(2_u8, nil)}, purposes_tag, as_array: true)
    end
    [no_signature_usage, no_server_auth].each do |invalid|
      expect_raises(Matter::AuthenticationError, /invalid NOC profile/) do
        Matter::Crypto::MatterCertificate::Validation.verify_chain(
          invalid, nil, authority.root_public_key, authority.root_certificate)
      end
    end
  end
end
