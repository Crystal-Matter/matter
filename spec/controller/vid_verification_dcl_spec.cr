require "../spec_helper"
require "../../src/matter/controller/vid_verification_dcl"

private alias VidTrust = Matter::Controller::VidVerification

private def dcl_test_certificate(key : Matter::Crypto::Key, issuer_key : Matter::Crypto::Key,
                                 subject : OpenSSL::X509::Name, issuer_cert : OpenSSL::X509::Certificate?,
                                 serial : Int32, ca : Bool) : Bytes
  cert = OpenSSL::X509::Certificate.new
  cert.version = 2
  cert.serial = OpenSSL::BN.new(serial)
  cert.not_before = OpenSSL::ASN1::Time.days_from_now(-1)
  cert.not_after = OpenSSL::ASN1::Time.days_from_now(365)
  cert.subject = subject
  cert.issuer = issuer_cert.try(&.subject) || subject
  cert.public_key = OpenSSL::PKey::EC.from_public_bytes(key.public_key, Matter::Crypto::CRYPTO_EC_CURVE_NIST)
  cert.add_extension(OpenSSL::X509::Extension.new("basicConstraints", "critical,CA:#{ca ? "TRUE" : "FALSE"}"))
  cert.add_extension(OpenSSL::X509::Extension.new("keyUsage", "critical,#{ca ? "keyCertSign,cRLSign" : "digitalSignature"}"))
  context = LibCrypto::MatterX509V3Context.new
  context_pointer = pointerof(context).as(LibCrypto::X509V3_CTX*)
  LibCrypto.x509v3_set_ctx(context_pointer, issuer_cert || cert, cert, nil, nil, 0)
  { {"subjectKeyIdentifier", "hash"}, {"authorityKeyIdentifier", "keyid:always"} }.each do |name, value|
    nid = LibCrypto.obj_sn2nid(name)
    extension = LibCrypto.x509v3_ext_conf_nid(nil, context_pointer, nid, value)
    raise "Failed to build #{name}" if extension.null?
    begin
      cert.add_extension(OpenSSL::X509::Extension.new(extension))
    ensure
      LibCrypto.x509_extension_free(extension)
    end
  end
  private_key = OpenSSL::PKey::EC.from_private_bytes(issuer_key.private_bits.as(Bytes), Matter::Crypto::CRYPTO_EC_CURVE_NIST)
  cert.sign(private_key, OpenSSL::Digest.new("SHA256"))
  cert.to_der
end

private def dcl_test_skid(der : Bytes) : Bytes
  cert = OpenSSL::X509::Certificate.from_der(der)
  pointer = LibCrypto.x509_get0_subject_key_id(cert)
  Slice.new(LibCrypto.asn1_string_get0_data(pointer).as(UInt8*), LibCrypto.asn1_string_length(pointer)).dup
end

# Re-encode a signed Matter TLV certificate with the DCL X.509 key identifier.
# The generic operational Builder uses its own key-identifier convention.
private def dcl_test_matter_vvsc(key : Matter::Crypto::Key, skid : Bytes,
                                 crypto : Matter::Crypto::StandardCrypto) : Bytes
  certificate = Matter::Crypto::MatterCertificate::Builder.root(key, 5_u64, Bytes[0x05], crypto)
  fields = TLV::Any.from_slice(certificate).as_structure
  constraints = TLV::Structure.new
  constraints[Matter::Crypto::MatterCertificate::Asn1::BASIC_CONSTRAINT_IS_CA] =
    TLV::Any.new(false, Matter::Crypto::MatterCertificate::Asn1::BASIC_CONSTRAINT_IS_CA)
  fields[10_u8] = TLV::Any.new(TLV::List{
    TLV::Any.new(constraints, Matter::Crypto::MatterCertificate::Asn1::Extension::BasicConstraints.value),
    TLV::Any.new(1_u16, Matter::Crypto::MatterCertificate::Asn1::Extension::KeyUsage.value),
    TLV::Any.new(skid, Matter::Crypto::MatterCertificate::Asn1::Extension::SubjectKeyIdentifier.value),
    TLV::Any.new(skid, Matter::Crypto::MatterCertificate::Asn1::Extension::AuthorityKeyIdentifier.value),
  }, 10_u8)
  tbs = Matter::Crypto::MatterCertificate::Asn1.to_unsigned_asn1(TLV::Any.new(fields, nil))
  fields[11_u8] = TLV::Any.new(crypto.sign_ecdsa(key, tbs), 11_u8)
  TLV::Any.new(fields, nil).to_slice
end

private class TestDclSource < VidTrust::DclSource
  property roots = [] of VidTrust::DclCertificate
  property intermediates = [] of VidTrust::DclCertificate
  property signers = [] of VidTrust::DclCertificate

  def roots_for(vendor_id : UInt16) : Array(VidTrust::DclCertificate)
    @roots
  end

  def intermediates_for(vendor_id : UInt16) : Array(VidTrust::DclCertificate)
    @intermediates
  end

  def signers_for(vendor_id : UInt16, skid : Bytes) : Array(VidTrust::DclCertificate)
    @signers
  end
end

describe VidTrust::DclOperationalTrustAnchors do
  it "fails closed when the DCL has no operational root or signer" do
    trust = VidTrust::DclOperationalTrustAnchors.new(TestDclSource.new)
    trust.trusted_root?(0x1234_u16, Bytes.empty).should be_false
    trust.verify_statement?(0x1234_u16, Bytes.new(20), Bytes[1], Bytes.new(64), nil).should be_false
  end

  it "binds an operational Matter root to a VID-scoped DCL X.509 root" do
    crypto = Matter::Crypto::StandardCrypto.new
    root_key = crypto.create_key_pair
    matter_root = Matter::Crypto::MatterCertificate::Builder.root(root_key, 1_u64, Bytes[0x01], crypto)
    name = OpenSSL::X509::Name.parse("CN=Operational Root")
    der = dcl_test_certificate(root_key, root_key, name, nil, 1, true)
    source = TestDclSource.new
    source.roots = [VidTrust::DclCertificate.new(der, 0x1234_u16,
      VidTrust::DclCertificate::Type::OperationalPKI, true)]
    trust = VidTrust::DclOperationalTrustAnchors.new(source)
    trust.trusted_root?(0x1234_u16, matter_root).should be_true
    trust.trusted_root?(0x4321_u16, matter_root).should be_false
    source.roots.clear
    trust.trusted_root?(0x1234_u16, matter_root).should be_false
  end

  it "verifies a VVS only through an active VID Signer chain" do
    crypto = Matter::Crypto::StandardCrypto.new
    root_key = crypto.create_key_pair
    middle_key = crypto.create_key_pair
    leaf_key = crypto.create_key_pair
    root_name = OpenSSL::X509::Name.parse("CN=VVSC Root")
    middle_name = OpenSSL::X509::Name.parse("CN=VVSC Intermediate")
    leaf_name = OpenSSL::X509::Name.parse("CN=VVSC Leaf")
    root = dcl_test_certificate(root_key, root_key, root_name, nil, 1, false)
    middle = dcl_test_certificate(middle_key, root_key, middle_name,
      OpenSSL::X509::Certificate.from_der(root), 2, false)
    leaf = dcl_test_certificate(leaf_key, middle_key, leaf_name,
      OpenSSL::X509::Certificate.from_der(middle), 3, false)
    leaf_skid = dcl_test_skid(leaf)
    source = TestDclSource.new
    kind = VidTrust::DclCertificate::Type::VIDSignerPKI
    source.roots = [VidTrust::DclCertificate.new(root, 0x1234_u16, kind, true)]
    source.intermediates = [VidTrust::DclCertificate.new(middle, 0x1234_u16, kind, false)]
    source.signers = [VidTrust::DclCertificate.new(leaf, 0x1234_u16, kind, false)]
    tbs = Bytes[0x21, 0x12, 0x34]
    signature = crypto.sign_ecdsa(leaf_key, tbs)
    trust = VidTrust::DclOperationalTrustAnchors.new(source)
    trust.verify_statement?(0x1234_u16, leaf_skid, tbs, signature, nil).should be_true
    matter_vvsc = dcl_test_matter_vvsc(leaf_key, leaf_skid, crypto)
    trust.verify_statement?(0x1234_u16, leaf_skid, tbs, signature, matter_vvsc).should be_true
    trust.verify_statement?(0x1234_u16, leaf_skid, tbs, signature, leaf).should be_false
    unrelated_vvsc = dcl_test_matter_vvsc(crypto.create_key_pair, leaf_skid, crypto)
    trust.verify_statement?(0x1234_u16, leaf_skid, tbs, signature, unrelated_vvsc).should be_false
    wrong_skid_vvsc = dcl_test_matter_vvsc(leaf_key, Bytes.new(20, 0xFF_u8), crypto)
    trust.verify_statement?(0x1234_u16, leaf_skid, tbs, signature, wrong_skid_vvsc).should be_false
    trust.verify_statement?(0x4321_u16, leaf_skid, tbs, signature, matter_vvsc).should be_false
    tampered = signature.dup
    tampered[0] ^= 1_u8
    trust.verify_statement?(0x1234_u16, leaf_skid, tbs, tampered, matter_vvsc).should be_false
    source.intermediates.clear
    trust.verify_statement?(0x1234_u16, leaf_skid, tbs, signature, matter_vvsc).should be_false
  end
end

describe VidTrust::HttpDclSource do
  it "reads active DCL certificate records and uses the VID/SKID query" do
    crypto = Matter::Crypto::StandardCrypto.new
    key = crypto.create_key_pair
    der = dcl_test_certificate(key, key, OpenSSL::X509::Name.parse("CN=DCL Root"), nil, 1, false)
    pem = "-----BEGIN CERTIFICATE-----\n#{Base64.strict_encode(der)}\n-----END CERTIFICATE-----"
    record = {"pemCert" => pem, "vid" => "4660", "certificateType" => "VIDSignerPKI", "isRoot" => true}
    seen = [] of String
    fetch = ->(url : String) {
      seen << url
      {"nocRootCertificates"         => {"certs" => [record]},
       "nocIcaCertificates"          => {"certs" => [record]},
       "nocCertificatesByVidAndSkid" => {"certs" => [record]}}.to_json
    }
    source = VidTrust::HttpDclSource.new("https://dcl.example/", fetch)
    skid = dcl_test_skid(der)
    source.roots_for(0x1234_u16).first.vendor_id.should eq 0x1234_u16
    source.intermediates_for(0x1234_u16).first.root?.should be_true
    source.signers_for(0x1234_u16, skid).first.certificate.to_der.should eq der
    seen.should eq [
      "https://dcl.example/dcl/pki/noc-vid-root-certificates/4660",
      "https://dcl.example/dcl/pki/noc-vid-ica-certificates/4660",
      "https://dcl.example/dcl/pki/noc-vid-certificates/4660/#{skid.hexstring.upcase.scan(/../).join(":")}",
    ]

    non_root = record.reject { |field, _value| field == "isRoot" }
    non_root_source = VidTrust::HttpDclSource.new("https://dcl.example", ->(_url : String) {
      {"nocIcaCertificates" => {"certs" => [non_root]}}.to_json
    })
    non_root_source.intermediates_for(0x1234_u16).first.root?.should be_false
  end

  it "rejects malformed and oversized DCL responses" do
    source = VidTrust::HttpDclSource.new("https://dcl.example", ->(_url : String) { "{}" })
    expect_raises(Matter::AuthenticationError) { source.roots_for(0x1234_u16) }
    oversized = VidTrust::HttpDclSource.new("https://dcl.example", ->(_url : String) { "x" * 1_048_577 })
    expect_raises(Matter::AuthenticationError) { oversized.roots_for(0x1234_u16) }
    expect_raises(Matter::ConfigurationError) { VidTrust::HttpDclSource.new("http://dcl.example") }
  end
end
