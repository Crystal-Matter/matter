require "../spec_helper"

private RCAC_ID   = 0x0102030405060708_u64
private FABRIC_ID = 0x1111111111111111_u64
private NODE_ID   = 0x2222222222222222_u64

describe Matter::Crypto::MatterCertificate::Builder do
  crypto = Matter::Crypto::StandardCrypto.new
  root_key = crypto.create_key_pair
  node_key = crypto.create_key_pair

  root = Matter::Crypto::MatterCertificate::Builder.root(root_key, RCAC_ID, Bytes[0x01], crypto)
  node = Matter::Crypto::MatterCertificate::Builder.node(
    node_key.public_key, FABRIC_ID, NODE_ID, root_key, RCAC_ID, Bytes[0x02], crypto
  )

  it "issues a self-signed root" do
    Matter::Crypto::MatterCertificate::Validation.verify_signature(root, root_key.public_key)
    Matter::Crypto::MatterCertificate::Validation.certificate_authority?(root).should be_true
  end

  it "puts DER-positive serial bytes on the wire for SDK certificate verification" do
    high_bit_serial = Bytes[0xff, 0x80, 0x01]
    expected = Bytes[0x00, 0xff, 0x80, 0x01]
    issued = [
      Matter::Crypto::MatterCertificate::Builder.root(root_key, RCAC_ID, high_bit_serial, crypto),
      Matter::Crypto::MatterCertificate::Builder.node(
        node_key.public_key, FABRIC_ID, NODE_ID, root_key, RCAC_ID, high_bit_serial, crypto),
      Matter::Crypto::MatterCertificate::Builder.intermediate(
        node_key.public_key, FABRIC_ID, 3_u64, root_key, RCAC_ID, high_bit_serial, crypto),
    ]

    issued.each do |certificate|
      fields = TLV::Any.from_slice(certificate).as_structure
      fields[Matter::Crypto::MatterCertificate::Asn1::Field::SerialNumber.value].as_bytes.should eq(expected)
      Matter::Crypto::MatterCertificate::Validation.verify_signature(certificate, root_key.public_key)
    end
  end

  it "issues a node certificate that chains to the root" do
    Matter::Crypto::MatterCertificate::Validation.verify_chain(node, nil, root_key.public_key)
    Matter::Crypto::MatterCertificate.node_id_from_tlv(node).should eq(NODE_ID)
    Matter::Crypto::MatterCertificate.public_key_from_tlv(node).should eq(node_key.public_key)
    Matter::Crypto::MatterCertificate::Validation.certificate_authority?(node).should be_false
  end

  it "issues a node certificate no other root can vouch for" do
    other = crypto.create_key_pair

    expect_raises(Matter::AuthenticationError) do
      Matter::Crypto::MatterCertificate::Validation.verify_chain(node, nil, other.public_key)
    end
  end

  it "names the root as the issuer of the node certificate" do
    Matter::Crypto::MatterCertificate::Validation.verify_issued_by(node, root)
  end

  it "uses a supplied RCAC subject for intermediate issuance and rejects a mismatched authority" do
    intermediate_key = crypto.create_key_pair
    issued = Matter::Crypto::MatterCertificate::Builder.intermediate(
      intermediate_key.public_key, FABRIC_ID, 3_u64, root_key, RCAC_ID,
      Bytes[0x03], crypto, issuer_certificate: root)
    Matter::Crypto::MatterCertificate::Validation.verify_issued_by(issued, root)

    default_issued = Matter::Crypto::MatterCertificate::Builder.intermediate(
      intermediate_key.public_key, FABRIC_ID, 3_u64, root_key, RCAC_ID,
      Bytes[0x04], crypto)
    Matter::Crypto::MatterCertificate::Validation.verify_issued_by(default_issued, root)

    expect_raises(Matter::CertificateError, /signing key or RCAC ID/) do
      Matter::Crypto::MatterCertificate::Builder.intermediate(
        intermediate_key.public_key, FABRIC_ID, 3_u64, root_key, RCAC_ID + 1_u64,
        Bytes[0x05], crypto, issuer_certificate: root)
    end
    expect_raises(Matter::CertificateError, /signing key or RCAC ID/) do
      Matter::Crypto::MatterCertificate::Builder.intermediate(
        intermediate_key.public_key, FABRIC_ID, 3_u64, crypto.create_key_pair, RCAC_ID,
        Bytes[0x06], crypto, issuer_certificate: root)
    end
  end

  it "reads back through the typed certificate struct" do
    parsed = Matter::Crypto::MatterCertificate.from_slice(node)
    parsed.noc?.should be_true
    parsed.fabric_id.should eq(FABRIC_ID)
    parsed.node_id.should eq(NODE_ID)
  end
end
