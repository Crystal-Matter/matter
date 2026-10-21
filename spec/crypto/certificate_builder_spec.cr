require "../spec_helper"

private RCAC_ID   = 0x0102030405060708_u64
private FABRIC_ID = 0x1111111111111111_u64
private NODE_ID   = 0x2222222222222222_u64

# connectedhomeip v1.6.0.0 CHIPCert_test_vectors.cpp, sTestCert_Root01.
private SDK_ROOT_PUBLIC_KEY = "043b88460ec9687a5d0f3b4b3b13fcd299c2f6d5051d003ee49c9924cf98f4f780eb20fd37c8d358347f5f87d08c3213e540af11bab9137e49354f0c5b6343de63".hexbytes
private SDK_ROOT_SKID       = "cc1308af82cfee505eb23b57bfe86a311665535f".hexbytes

describe Matter::Crypto::MatterCertificate::Builder do
  crypto = Matter::Crypto::StandardCrypto.new
  root_key = crypto.create_key_pair
  node_key = crypto.create_key_pair

  root = Matter::Crypto::MatterCertificate::Builder.root(root_key, RCAC_ID, Bytes[0x01], crypto)
  node = Matter::Crypto::MatterCertificate::Builder.node(
    node_key.public_key, FABRIC_ID, NODE_ID, root_key, RCAC_ID, Bytes[0x02], crypto
  )

  it "derives the SDK v1.6 subject key identifier from the full P-256 public key" do
    Matter::Crypto::MatterCertificate::Builder.key_identifier(SDK_ROOT_PUBLIC_KEY, crypto).should eq SDK_ROOT_SKID
  end

  it "writes SHA-1 key identifiers into generated root, intermediate, and node chains" do
    intermediate_key = crypto.create_key_pair
    intermediate = Matter::Crypto::MatterCertificate::Builder.intermediate(
      intermediate_key.public_key, FABRIC_ID, 3_u64, root_key, RCAC_ID, Bytes[0x03], crypto,
      issuer_certificate: root)
    intermediate_node = Matter::Crypto::MatterCertificate::Builder.node(
      node_key.public_key, FABRIC_ID, NODE_ID, intermediate_key, RCAC_ID, Bytes[0x04], crypto,
      issuer_icac_id: 3_u64, issuer_certificate: intermediate)

    Matter::Crypto::MatterCertificate::Validation.verify_root(root)
    Matter::Crypto::MatterCertificate::Validation.verify_chain(
      intermediate_node, intermediate, root_key.public_key, root)

    {root, intermediate, intermediate_node}.zip({root_key.public_key, intermediate_key.public_key, node_key.public_key},
      {root_key.public_key, root_key.public_key, intermediate_key.public_key}).each do |certificate, subject_key, issuer_key|
      extensions = TLV::Any.from_slice(certificate).as_structure[
        Matter::Crypto::MatterCertificate::Asn1::Field::Extensions.value].as_list
      subject_extension = extensions.find! do |extension|
        extension.header.ids == Matter::Crypto::MatterCertificate::Asn1::Extension::SubjectKeyIdentifier.value
      end
      authority_extension = extensions.find! do |extension|
        extension.header.ids == Matter::Crypto::MatterCertificate::Asn1::Extension::AuthorityKeyIdentifier.value
      end
      subject_extension.as_bytes.should eq OpenSSL::Digest.new("SHA1").update(subject_key).final
      authority_extension.as_bytes.should eq OpenSSL::Digest.new("SHA1").update(issuer_key).final
    end
  end

  it "continues issuing under a persisted root with the old Crystal key identifier" do
    legacy_id = crypto.compute_sha256(root_key.public_key)[0, 20]
    root_fields = TLV::Any.from_slice(root).as_structure
    root_extensions = root_fields[Matter::Crypto::MatterCertificate::Asn1::Field::Extensions.value].as_list
    {Matter::Crypto::MatterCertificate::Asn1::Extension::SubjectKeyIdentifier,
     Matter::Crypto::MatterCertificate::Asn1::Extension::AuthorityKeyIdentifier}.each do |tag|
      index = root_extensions.index! { |extension| extension.header.ids == tag.value }
      root_extensions[index] = TLV::Any.new(legacy_id, tag.value)
    end
    transcript = Matter::Crypto::MatterCertificate::Asn1.to_unsigned_asn1(TLV::Any.new(root_fields, nil))
    signature_tag = Matter::Crypto::MatterCertificate::Asn1::Field::Signature.value
    root_fields[signature_tag] = TLV::Any.new(crypto.sign_ecdsa(root_key, transcript), signature_tag)
    legacy_root = TLV::Any.new(root_fields, nil).to_slice

    renewed_node = Matter::Crypto::MatterCertificate::Builder.node(
      node_key.public_key, FABRIC_ID, NODE_ID, root_key, RCAC_ID, Bytes[0x07], crypto,
      issuer_certificate: legacy_root)
    Matter::Crypto::MatterCertificate::Validation.verify_chain(renewed_node, nil,
      root_key.public_key, legacy_root)

    expect_raises(Matter::CertificateError, /signing key or ID/) do
      Matter::Crypto::MatterCertificate::Builder.node(
        node_key.public_key, FABRIC_ID, NODE_ID, crypto.create_key_pair, RCAC_ID,
        Bytes[0x08], crypto, issuer_certificate: legacy_root)
    end
  end

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
