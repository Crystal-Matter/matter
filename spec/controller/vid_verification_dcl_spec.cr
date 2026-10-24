require "../spec_helper"
require "../../src/matter/controller/vid_verification_dcl"

private alias VidTrust = Matter::Controller::VidVerification

private def dcl_test_certificate(key : Matter::Crypto::Key, issuer_key : Matter::Crypto::Key,
                                 subject : OpenSSL::X509::Name, issuer_cert : OpenSSL::X509::Certificate?,
                                 serial : Int32, ca : Bool, unknown_critical : Bool = false,
                                 subject_skid : Bytes? = nil, path_len : Int32? = nil) : Bytes
  cert = OpenSSL::X509::Certificate.new
  cert.version = 2
  cert.serial = OpenSSL::BN.new(serial)
  cert.not_before = OpenSSL::ASN1::Time.days_from_now(-1)
  cert.not_after = OpenSSL::ASN1::Time.days_from_now(365)
  cert.subject = subject
  cert.issuer = issuer_cert.try(&.subject) || subject
  cert.public_key = OpenSSL::PKey::EC.from_public_bytes(key.public_key, Matter::Crypto::CRYPTO_EC_CURVE_NIST)
  constraints = "critical,CA:#{ca ? "TRUE" : "FALSE"}"
  constraints += ",pathlen:#{path_len}" if path_len
  cert.add_extension(OpenSSL::X509::Extension.new("basicConstraints", constraints))
  cert.add_extension(OpenSSL::X509::Extension.new("keyUsage", "critical,#{ca ? "keyCertSign,cRLSign" : "digitalSignature"}"))
  context = LibCrypto::MatterX509V3Context.new
  context_pointer = pointerof(context).as(LibCrypto::X509V3_CTX*)
  LibCrypto.x509v3_set_ctx(context_pointer, issuer_cert || cert, cert, nil, nil, 0)
  skid_value = subject_skid.try(&.hexstring.upcase.scan(/../).join(":")) || "hash"
  { {"subjectKeyIdentifier", skid_value}, {"authorityKeyIdentifier", "keyid:always"} }.each do |name, value|
    nid = LibCrypto.obj_sn2nid(name)
    extension = LibCrypto.x509v3_ext_conf_nid(nil, context_pointer, nid, value)
    raise "Failed to build #{name}" if extension.null?
    begin
      cert.add_extension(OpenSSL::X509::Extension.new(extension))
    ensure
      LibCrypto.x509_extension_free(extension)
    end
  end
  if unknown_critical
    cert.add_extension(OpenSSL::X509::Extension.new("extendedKeyUsage", "critical,serverAuth"))
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

private def dcl_test_matter_skid(certificate : Bytes) : Bytes
  extensions = TLV::Any.from_slice(certificate).as_structure[Matter::Crypto::MatterCertificate::Asn1::Field::Extensions.value].as_list
  extensions.find! { |item| item.header.ids == Matter::Crypto::MatterCertificate::Asn1::Extension::SubjectKeyIdentifier.value }.as_bytes
end

private def dcl_test_matter_name(oid : String, identifier : String) : OpenSSL::X509::Name
  OpenSSL::X509::Name.new.tap(&.add_entry(oid, identifier))
end

# Re-encode a signed Matter TLV certificate with the VID signer profile.
private def dcl_test_matter_vvsc(key : Matter::Crypto::Key, skid : Bytes,
                                 issuer_key : Matter::Crypto::Key, issuer_skid : Bytes,
                                 crypto : Matter::Crypto::StandardCrypto) : Bytes
  certificate = Matter::Crypto::MatterCertificate::Builder.root(key, 5_u64, Bytes[0x05], crypto)
  fields = TLV::Any.from_slice(certificate).as_structure
  fields[3_u8] = TLV::Any.new(TLV::List{
    TLV::Any.new(2_u64, Matter::Crypto::MatterCertificate::Asn1::Dn::IcacId.value),
    TLV::Any.new("Intermediate CA", Matter::Crypto::MatterCertificate::Asn1::Dn::CommonName.value),
  }, 3_u8)
  fields[6_u8] = TLV::Any.new(TLV::List{
    TLV::Any.new(3_u64, Matter::Crypto::MatterCertificate::Asn1::Dn::VvsId.value),
    TLV::Any.new("VID signer", Matter::Crypto::MatterCertificate::Asn1::Dn::CommonName.value),
  }, 6_u8)
  constraints = TLV::Structure.new
  constraints[Matter::Crypto::MatterCertificate::Asn1::BASIC_CONSTRAINT_IS_CA] =
    TLV::Any.new(false, Matter::Crypto::MatterCertificate::Asn1::BASIC_CONSTRAINT_IS_CA)
  fields[10_u8] = TLV::Any.new(TLV::List{
    TLV::Any.new(constraints, Matter::Crypto::MatterCertificate::Asn1::Extension::BasicConstraints.value),
    TLV::Any.new(1_u16, Matter::Crypto::MatterCertificate::Asn1::Extension::KeyUsage.value),
    TLV::Any.new(skid, Matter::Crypto::MatterCertificate::Asn1::Extension::SubjectKeyIdentifier.value),
    TLV::Any.new(issuer_skid, Matter::Crypto::MatterCertificate::Asn1::Extension::AuthorityKeyIdentifier.value),
  }, 10_u8)
  tbs = Matter::Crypto::MatterCertificate::Asn1.to_unsigned_asn1(TLV::Any.new(fields, nil))
  fields[11_u8] = TLV::Any.new(crypto.sign_ecdsa(issuer_key, tbs), 11_u8)
  TLV::Any.new(fields, nil).to_slice
end

private def dcl_test_reissue_vvsc(certificate : Bytes, issuer_key : Matter::Crypto::Key,
                                  crypto : Matter::Crypto::StandardCrypto,
                                  & : TLV::Structure ->) : Bytes
  fields = TLV::Any.from_slice(certificate).as_structure
  yield fields
  tbs = Matter::Crypto::MatterCertificate::Asn1.to_unsigned_asn1(TLV::Any.new(fields, nil))
  fields[11_u8] = TLV::Any.new(crypto.sign_ecdsa(issuer_key, tbs), 11_u8)
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
  it "uses active VID-scoped HTTPS DCL records for an operational root" do
    crypto = Matter::Crypto::StandardCrypto.new
    root_key = crypto.create_key_pair
    matter_root = Matter::Crypto::MatterCertificate::Builder.root(root_key, 1_u64, Bytes[0x01], crypto)
    name = dcl_test_matter_name("1.3.6.1.4.1.37244.1.4", "0000000000000001")
    der = dcl_test_certificate(root_key, root_key, name, nil, 1, true)
    pem = "-----BEGIN CERTIFICATE-----\n#{Base64.strict_encode(der)}\n-----END CERTIFICATE-----"
    mode = "wrong-vid"
    fetch = ->(_url : String) do
      vid = mode == "wrong-vid" ? 0xFFF2 : 0xFFF1
      records = mode == "removed" ? [] of JSON::Any : [JSON.parse({
        "pemCert" => pem, "vid" => vid, "certificateType" => "OperationalPKI", "isRoot" => true,
      }.to_json)]
      {"nocRootCertificates" => {"certs" => records}}.to_json
    end
    trust = VidTrust::DclOperationalTrustAnchors.new(
      VidTrust::HttpDclSource.new("https://127.0.0.1", fetch))
    trust.trusted_root?(0xFFF1_u16, matter_root).should be_false
    mode = "removed"
    trust.trusted_root?(0xFFF1_u16, matter_root).should be_false
    mode = "active"
    trust.trusted_root?(0xFFF1_u16, matter_root).should be_true
  end

  it "fails closed when the DCL has no operational root or signer" do
    trust = VidTrust::DclOperationalTrustAnchors.new(TestDclSource.new)
    trust.trusted_root?(0x1234_u16, Bytes.empty).should be_false
    trust.verify_statement?(0x1234_u16, Bytes.new(20), Bytes[1], Bytes.new(64), nil).should be_false
  end

  it "binds an operational Matter root to a VID-scoped DCL X.509 root" do
    crypto = Matter::Crypto::StandardCrypto.new
    root_key = crypto.create_key_pair
    matter_root = Matter::Crypto::MatterCertificate::Builder.root(root_key, 1_u64, Bytes[0x01], crypto)
    name = dcl_test_matter_name("1.3.6.1.4.1.37244.1.4", "0000000000000001")
    name.add_entry("CN", "Operational Root")
    der = dcl_test_certificate(root_key, root_key, name, nil, 1, true)
    dcl_test_skid(der).should eq(dcl_test_matter_skid(matter_root))
    source = TestDclSource.new
    source.roots = [VidTrust::DclCertificate.new(der, 0x1234_u16,
      VidTrust::DclCertificate::Type::OperationalPKI, true)]
    trust = VidTrust::DclOperationalTrustAnchors.new(source)
    trust.trusted_root?(0x1234_u16, matter_root).should be_true
    wrong_id_root = dcl_test_certificate(root_key, root_key,
      dcl_test_matter_name("1.3.6.1.4.1.37244.1.4", "0000000000000002"), nil, 4, true)
    source.roots = [VidTrust::DclCertificate.new(wrong_id_root, 0x1234_u16,
      VidTrust::DclCertificate::Type::OperationalPKI, true)]
    trust.trusted_root?(0x1234_u16, matter_root).should be_false
    source.roots = [VidTrust::DclCertificate.new(der, 0x1234_u16,
      VidTrust::DclCertificate::Type::OperationalPKI, true)]
    generic_root = dcl_test_certificate(root_key, root_key, OpenSSL::X509::Name.parse("CN=Generic CA"),
      nil, 3, true)
    source.roots = [VidTrust::DclCertificate.new(generic_root, 0x1234_u16,
      VidTrust::DclCertificate::Type::OperationalPKI, true)]
    trust.trusted_root?(0x1234_u16, matter_root).should be_false
    source.roots = [VidTrust::DclCertificate.new(der, 0x1234_u16,
      VidTrust::DclCertificate::Type::OperationalPKI, true)]
    same_key_wrong_skid = dcl_test_certificate(root_key, root_key, name, nil, 2, true,
      subject_skid: Bytes.new(20, 0xFF_u8))
    source.roots = [VidTrust::DclCertificate.new(same_key_wrong_skid, 0x1234_u16,
      VidTrust::DclCertificate::Type::OperationalPKI, true)]
    trust.trusted_root?(0x1234_u16, matter_root).should be_false
    source.roots = [VidTrust::DclCertificate.new(der, 0x1234_u16,
      VidTrust::DclCertificate::Type::OperationalPKI, true)]
    trust.trusted_root?(0x4321_u16, matter_root).should be_false
    source.roots.clear
    trust.trusted_root?(0x1234_u16, matter_root).should be_false
  end

  it "verifies a VVS only through a Matter Root/ICA CA chain and a VID signer leaf" do
    crypto = Matter::Crypto::StandardCrypto.new
    root_key = crypto.create_key_pair
    middle_key = crypto.create_key_pair
    leaf_key = crypto.create_key_pair
    root_name = dcl_test_matter_name("1.3.6.1.4.1.37244.1.4", "0000000000000001")
    middle_name = dcl_test_matter_name("1.3.6.1.4.1.37244.1.3", "0000000000000002")
    leaf_name = dcl_test_matter_name("1.3.6.1.4.1.37244.1.7", "0000000000000003")
    root_name.add_entry("CN", "Root CA")
    middle_name.add_entry("CN", "Intermediate CA")
    leaf_name.add_entry("CN", "VID signer")
    root = dcl_test_certificate(root_key, root_key, root_name, nil, 1, true)
    middle = dcl_test_certificate(middle_key, root_key, middle_name,
      OpenSSL::X509::Certificate.from_der(root), 2, true)
    leaf = dcl_test_certificate(leaf_key, middle_key, leaf_name,
      OpenSSL::X509::Certificate.from_der(middle), 3, false)
    leaf_skid = dcl_test_skid(leaf)
    source = TestDclSource.new
    source.roots = [VidTrust::DclCertificate.new(root, 0x1234_u16,
      VidTrust::DclCertificate::Type::OperationalPKI, true)]
    source.intermediates = [VidTrust::DclCertificate.new(middle, 0x1234_u16,
      VidTrust::DclCertificate::Type::OperationalPKI, false)]
    source.signers = [VidTrust::DclCertificate.new(leaf, 0x1234_u16,
      VidTrust::DclCertificate::Type::VIDSignerPKI, false)]
    tbs = Bytes[0x21, 0x12, 0x34]
    signature = crypto.sign_ecdsa(leaf_key, tbs)
    trust = VidTrust::DclOperationalTrustAnchors.new(source)
    trust.verify_statement?(0x1234_u16, leaf_skid, tbs, signature, nil).should be_true
    source.roots = [VidTrust::DclCertificate.new(root, 0x1234_u16,
      VidTrust::DclCertificate::Type::VIDSignerPKI, true)]
    trust.verify_statement?(0x1234_u16, leaf_skid, tbs, signature, nil).should be_false
    source.roots = [VidTrust::DclCertificate.new(root, 0x1234_u16,
      VidTrust::DclCertificate::Type::OperationalPKI, true)]
    source.intermediates = [VidTrust::DclCertificate.new(middle, 0x1234_u16,
      VidTrust::DclCertificate::Type::VIDSignerPKI, false)]
    trust.verify_statement?(0x1234_u16, leaf_skid, tbs, signature, nil).should be_false
    source.intermediates = [VidTrust::DclCertificate.new(middle, 0x1234_u16,
      VidTrust::DclCertificate::Type::OperationalPKI, false)]
    non_ca_root = dcl_test_certificate(root_key, root_key, root_name, nil, 6, false)
    non_ca_middle = dcl_test_certificate(middle_key, root_key, middle_name,
      OpenSSL::X509::Certificate.from_der(non_ca_root), 7, false)
    non_ca_leaf = dcl_test_certificate(leaf_key, middle_key, leaf_name,
      OpenSSL::X509::Certificate.from_der(non_ca_middle), 8, false)
    source.roots = [VidTrust::DclCertificate.new(non_ca_root, 0x1234_u16,
      VidTrust::DclCertificate::Type::OperationalPKI, true)]
    source.intermediates = [VidTrust::DclCertificate.new(non_ca_middle, 0x1234_u16,
      VidTrust::DclCertificate::Type::OperationalPKI, false)]
    source.signers = [VidTrust::DclCertificate.new(non_ca_leaf, 0x1234_u16,
      VidTrust::DclCertificate::Type::VIDSignerPKI, false)]
    trust.verify_statement?(0x1234_u16, dcl_test_skid(non_ca_leaf), tbs, signature, nil).should be_false
    source.roots = [VidTrust::DclCertificate.new(root, 0x1234_u16,
      VidTrust::DclCertificate::Type::OperationalPKI, true)]
    source.intermediates = [VidTrust::DclCertificate.new(middle, 0x1234_u16,
      VidTrust::DclCertificate::Type::OperationalPKI, false)]
    source.signers = [VidTrust::DclCertificate.new(leaf, 0x1234_u16,
      VidTrust::DclCertificate::Type::VIDSignerPKI, false)]
    constrained_root = dcl_test_certificate(root_key, root_key, root_name, nil, 11, true,
      path_len: 0)
    constrained_middle = dcl_test_certificate(middle_key, root_key, middle_name,
      OpenSSL::X509::Certificate.from_der(constrained_root), 12, true)
    constrained_leaf = dcl_test_certificate(leaf_key, middle_key, leaf_name,
      OpenSSL::X509::Certificate.from_der(constrained_middle), 13, false)
    source.roots = [VidTrust::DclCertificate.new(constrained_root, 0x1234_u16,
      VidTrust::DclCertificate::Type::OperationalPKI, true)]
    source.intermediates = [VidTrust::DclCertificate.new(constrained_middle, 0x1234_u16,
      VidTrust::DclCertificate::Type::OperationalPKI, false)]
    source.signers = [VidTrust::DclCertificate.new(constrained_leaf, 0x1234_u16,
      VidTrust::DclCertificate::Type::VIDSignerPKI, false)]
    trust.verify_statement?(0x1234_u16, dcl_test_skid(constrained_leaf), tbs, signature, nil).should be_false
    direct_constrained_leaf = dcl_test_certificate(leaf_key, root_key, leaf_name,
      OpenSSL::X509::Certificate.from_der(constrained_root), 14, false)
    source.intermediates.clear
    source.signers = [VidTrust::DclCertificate.new(direct_constrained_leaf, 0x1234_u16,
      VidTrust::DclCertificate::Type::VIDSignerPKI, false)]
    trust.verify_statement?(0x1234_u16, dcl_test_skid(direct_constrained_leaf), tbs, signature, nil).should be_true
    source.roots = [VidTrust::DclCertificate.new(root, 0x1234_u16,
      VidTrust::DclCertificate::Type::OperationalPKI, true)]
    source.intermediates = [VidTrust::DclCertificate.new(middle, 0x1234_u16,
      VidTrust::DclCertificate::Type::OperationalPKI, false)]
    source.signers = [VidTrust::DclCertificate.new(leaf, 0x1234_u16,
      VidTrust::DclCertificate::Type::VIDSignerPKI, false)]
    critical_leaf = dcl_test_certificate(leaf_key, middle_key, leaf_name,
      OpenSSL::X509::Certificate.from_der(middle), 5, false, unknown_critical: true)
    source.signers = [VidTrust::DclCertificate.new(critical_leaf, 0x1234_u16,
      VidTrust::DclCertificate::Type::VIDSignerPKI, false)]
    trust.verify_statement?(0x1234_u16, dcl_test_skid(critical_leaf), tbs, signature, nil).should be_false
    source.signers = [VidTrust::DclCertificate.new(leaf, 0x1234_u16,
      VidTrust::DclCertificate::Type::VIDSignerPKI, false)]
    matter_vvsc = dcl_test_matter_vvsc(leaf_key, leaf_skid, middle_key, dcl_test_skid(middle), crypto)
    trust.verify_statement?(0x1234_u16, leaf_skid, tbs, signature, matter_vvsc).should be_true
    source.signers.clear
    trust.verify_statement?(0x1234_u16, leaf_skid, tbs, signature, matter_vvsc).should be_true
    trust.verify_statement?(0x1234_u16, leaf_skid, tbs, signature, nil).should be_false
    local_signer_key = crypto.create_key_pair
    local_signer_skid = crypto.compute_sha1(local_signer_key.public_key)
    local_vvsc = dcl_test_matter_vvsc(local_signer_key, local_signer_skid,
      middle_key, dcl_test_skid(middle), crypto)
    local_signature = crypto.sign_ecdsa(local_signer_key, tbs)
    trust.verify_statement?(0x1234_u16, local_signer_skid, tbs, local_signature, local_vvsc).should be_true
    source.signers = [VidTrust::DclCertificate.new(leaf, 0x1234_u16,
      VidTrust::DclCertificate::Type::VIDSignerPKI, false)]
    altered_fields = TLV::Any.from_slice(matter_vvsc).as_structure
    altered_signature = altered_fields[11_u8].as_bytes.dup
    altered_signature[0] ^= 1_u8
    altered_fields[11_u8] = TLV::Any.new(altered_signature, 11_u8)
    altered_vvsc = TLV::Any.new(altered_fields, nil).to_slice
    trust.verify_statement?(0x1234_u16, leaf_skid, tbs, signature, altered_vvsc).should be_false
    alternate_id_vvsc = dcl_test_reissue_vvsc(matter_vvsc, middle_key, crypto) do |fields|
      fields[6_u8] = TLV::Any.new(TLV::List{
        TLV::Any.new(4_u64, Matter::Crypto::MatterCertificate::Asn1::Dn::VvsId.value),
        TLV::Any.new("VID signer", Matter::Crypto::MatterCertificate::Asn1::Dn::CommonName.value),
      }, 6_u8)
    end
    trust.verify_statement?(0x1234_u16, leaf_skid, tbs, signature, alternate_id_vvsc).should be_true
    alternate_name_vvsc = dcl_test_reissue_vvsc(matter_vvsc, middle_key, crypto) do |fields|
      fields[6_u8] = TLV::Any.new(TLV::List{
        TLV::Any.new(3_u64, Matter::Crypto::MatterCertificate::Asn1::Dn::VvsId.value),
        TLV::Any.new("Other signer", Matter::Crypto::MatterCertificate::Asn1::Dn::CommonName.value),
      }, 6_u8)
    end
    trust.verify_statement?(0x1234_u16, leaf_skid, tbs, signature, alternate_name_vvsc).should be_true
    wrong_issuer_name_vvsc = dcl_test_reissue_vvsc(matter_vvsc, middle_key, crypto) do |fields|
      fields[3_u8] = TLV::Any.new(TLV::List{
        TLV::Any.new(2_u64, Matter::Crypto::MatterCertificate::Asn1::Dn::IcacId.value),
        TLV::Any.new("Other CA", Matter::Crypto::MatterCertificate::Asn1::Dn::CommonName.value),
      }, 3_u8)
    end
    trust.verify_statement?(0x1234_u16, leaf_skid, tbs, signature, wrong_issuer_name_vvsc).should be_false
    unknown_name_vvsc = dcl_test_reissue_vvsc(matter_vvsc, middle_key, crypto) do |fields|
      fields[6_u8] = TLV::Any.new(TLV::List{
        TLV::Any.new(3_u64, Matter::Crypto::MatterCertificate::Asn1::Dn::VvsId.value),
        TLV::Any.new("VID signer", Matter::Crypto::MatterCertificate::Asn1::Dn::CommonName.value),
        TLV::Any.new("ignored", 24_u8),
      }, 6_u8)
    end
    trust.verify_statement?(0x1234_u16, leaf_skid, tbs, signature, unknown_name_vvsc).should be_false
    duplicate_id_vvsc = dcl_test_reissue_vvsc(matter_vvsc, middle_key, crypto) do |fields|
      fields[6_u8] = TLV::Any.new(TLV::List{
        TLV::Any.new(3_u64, Matter::Crypto::MatterCertificate::Asn1::Dn::VvsId.value),
        TLV::Any.new(3_u64, Matter::Crypto::MatterCertificate::Asn1::Dn::VvsId.value),
      }, 6_u8)
    end
    trust.verify_statement?(0x1234_u16, leaf_skid, tbs, signature, duplicate_id_vvsc).should be_false
    expired_vvsc = dcl_test_reissue_vvsc(matter_vvsc, middle_key, crypto) do |fields|
      fields[5_u8] = TLV::Any.new(1_u32, 5_u8)
    end
    trust.verify_statement?(0x1234_u16, leaf_skid, tbs, signature, expired_vvsc).should be_false
    ca_vvsc = dcl_test_reissue_vvsc(matter_vvsc, middle_key, crypto) do |fields|
      extensions = fields[10_u8].as_list
      basic = TLV::Structure.new
      basic[Matter::Crypto::MatterCertificate::Asn1::BASIC_CONSTRAINT_IS_CA] =
        TLV::Any.new(true, Matter::Crypto::MatterCertificate::Asn1::BASIC_CONSTRAINT_IS_CA)
      extensions[0] = TLV::Any.new(basic, Matter::Crypto::MatterCertificate::Asn1::Extension::BasicConstraints.value)
    end
    trust.verify_statement?(0x1234_u16, leaf_skid, tbs, signature, ca_vvsc).should be_false
    mixed_name = dcl_test_matter_name("1.3.6.1.4.1.37244.1.7", "0000000000000003")
    mixed_name.add_entry("1.3.6.1.4.1.37244.1.5", "0000000000000004")
    mixed_leaf = dcl_test_certificate(leaf_key, middle_key, mixed_name,
      OpenSSL::X509::Certificate.from_der(middle), 9, false)
    source.signers = [VidTrust::DclCertificate.new(mixed_leaf, 0x1234_u16,
      VidTrust::DclCertificate::Type::VIDSignerPKI, false)]
    trust.verify_statement?(0x1234_u16, dcl_test_skid(mixed_leaf), tbs, signature, nil).should be_false
    cn_leaf = dcl_test_certificate(leaf_key, middle_key, OpenSSL::X509::Name.parse("CN=Generic signer"),
      OpenSSL::X509::Certificate.from_der(middle), 4, false)
    source.signers = [VidTrust::DclCertificate.new(cn_leaf, 0x1234_u16,
      VidTrust::DclCertificate::Type::VIDSignerPKI, false)]
    trust.verify_statement?(0x1234_u16, dcl_test_skid(cn_leaf), tbs, signature, nil).should be_false
    source.signers = [VidTrust::DclCertificate.new(leaf, 0x1234_u16,
      VidTrust::DclCertificate::Type::VIDSignerPKI, false)]
    trust.verify_statement?(0x1234_u16, leaf_skid, tbs, signature, leaf).should be_false
    unrelated_vvsc = dcl_test_matter_vvsc(crypto.create_key_pair, leaf_skid,
      middle_key, dcl_test_skid(middle), crypto)
    trust.verify_statement?(0x1234_u16, leaf_skid, tbs, signature, unrelated_vvsc).should be_false
    wrong_skid_vvsc = dcl_test_matter_vvsc(leaf_key, Bytes.new(20, 0xFF_u8),
      middle_key, dcl_test_skid(middle), crypto)
    trust.verify_statement?(0x1234_u16, leaf_skid, tbs, signature, wrong_skid_vvsc).should be_false
    trust.verify_statement?(0x4321_u16, leaf_skid, tbs, signature, matter_vvsc).should be_false
    tampered = signature.dup
    tampered[0] ^= 1_u8
    trust.verify_statement?(0x1234_u16, leaf_skid, tbs, tampered, matter_vvsc).should be_false
    source.intermediates.clear
    trust.verify_statement?(0x1234_u16, leaf_skid, tbs, signature, matter_vvsc).should be_false
    direct_vvsc = dcl_test_reissue_vvsc(matter_vvsc, root_key, crypto) do |fields|
      fields[3_u8] = TLV::Any.new(TLV::List{
        TLV::Any.new(1_u64, Matter::Crypto::MatterCertificate::Asn1::Dn::RcacId.value),
        TLV::Any.new("Root CA", Matter::Crypto::MatterCertificate::Asn1::Dn::CommonName.value),
      }, 3_u8)
      extensions = fields[10_u8].as_list
      extensions[3] = TLV::Any.new(dcl_test_skid(root),
        Matter::Crypto::MatterCertificate::Asn1::Extension::AuthorityKeyIdentifier.value)
    end
    source.signers.clear
    trust.verify_statement?(0x1234_u16, leaf_skid, tbs, signature, direct_vvsc).should be_true
    direct_leaf = dcl_test_certificate(leaf_key, root_key, leaf_name,
      OpenSSL::X509::Certificate.from_der(root), 10, false)
    source.signers = [VidTrust::DclCertificate.new(direct_leaf, 0x1234_u16,
      VidTrust::DclCertificate::Type::VIDSignerPKI, false)]
    trust.verify_statement?(0x1234_u16, dcl_test_skid(direct_leaf), tbs, signature, nil).should be_true
  end
end

describe VidTrust::HttpDclSource do
  it "rejects an explicitly aged gateway response before trusting its signer records" do
    payload = {"nocCertificatesByVidAndSkid" => {"certs" => [] of String}}.to_json
    stale = VidTrust::HttpDclSource.new("https://dcl.example", ->(_url : String) {
      VidTrust::HttpDclSource::Response.new(200, "7", payload)
    })
    expect_raises(Matter::AuthenticationError) do
      stale.signers_for(0x1234_u16, Bytes.new(20, 1_u8))
    end

    fresh = VidTrust::HttpDclSource.new("https://dcl.example", ->(_url : String) {
      VidTrust::HttpDclSource::Response.new(200, "0", payload)
    })
    fresh.signers_for(0x1234_u16, Bytes.new(20, 1_u8)).should be_empty
    unavailable = VidTrust::HttpDclSource.new("https://dcl.example", ->(_url : String) {
      VidTrust::HttpDclSource::Response.new(503, nil, payload)
    })
    expect_raises(Matter::AuthenticationError) do
      unavailable.signers_for(0x1234_u16, Bytes.new(20, 1_u8))
    end
  end

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
    ["https://trusted.example@evil.example", "https://dcl.example/path", "https://dcl.example?x=1",
     "https://dcl.example/#frag", "https://dcl.example:8443"].each do |gateway|
      expect_raises(Matter::ConfigurationError) { VidTrust::HttpDclSource.new(gateway) }
    end
  end
end
