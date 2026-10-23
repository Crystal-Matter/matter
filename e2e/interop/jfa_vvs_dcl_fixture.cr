require "../../src/matter/controller/vid_verification_dcl"
require "json"
require "base64"

# A local HTTPS DCL fixture for the live three-Administrator test. Certificate
# records are read from a shared volume by the tests container's Python mirror.
class JfaVvsDclFixture
  ROOT_ID_OID   = "1.3.6.1.4.1.37244.1.4"
  ICA_ID_OID    = "1.3.6.1.4.1.37244.1.3"
  SIGNER_ID_OID = "1.3.6.1.4.1.37244.1.7"

  getter signer_key : Matter::Crypto::Key
  getter signer_skid : Bytes
  getter cert_path : String
  getter server_cert_path : String

  def initialize(@directory : String)
    crypto = Matter::Crypto::StandardCrypto.new
    root_key = crypto.create_key_pair
    ica_key = crypto.create_key_pair
    @signer_key = crypto.create_key_pair
    wrong_root_key = crypto.create_key_pair
    wrong_signer_key = crypto.create_key_pair

    root = certificate(root_key, root_key, name(ROOT_ID_OID, 1_u64, "DCL Root"), nil, 1, true, 1)
    root_cert = OpenSSL::X509::Certificate.from_der(root)
    ica = certificate(ica_key, root_key, name(ICA_ID_OID, 2_u64, "DCL ICA"), root_cert, 2, true, 0)
    ica_cert = OpenSSL::X509::Certificate.from_der(ica)
    @signer_skid = crypto.compute_sha1(@signer_key.public_key)
    signer = certificate(@signer_key, ica_key, name(SIGNER_ID_OID, 3_u64, "VID signer"),
      ica_cert, 3, false, nil, @signer_skid)
    wrong_root = certificate(wrong_root_key, wrong_root_key,
      name(ROOT_ID_OID, 4_u64, "Wrong Root"), nil, 4, true, 1)
    wrong_signer = certificate(wrong_signer_key, ica_key,
      name(SIGNER_ID_OID, 5_u64, "Wrong signer"), ica_cert, 5, false)
    @state = {
      "mode"             => "active",
      "root_der"         => Base64.strict_encode(root),
      "ica_der"          => Base64.strict_encode(ica),
      "signer_der"       => Base64.strict_encode(signer),
      "wrong_root_der"   => Base64.strict_encode(wrong_root),
      "wrong_signer_der" => Base64.strict_encode(wrong_signer),
      "signer_skid"      => @signer_skid.hexstring.upcase.scan(/../).join(":"),
    }
    @state_path = File.join(@directory, "jfa-dcl-state.json")
    write_mode("active")

    tls_ca_key = crypto.create_key_pair
    tls_ca = certificate(tls_ca_key, tls_ca_key,
      OpenSSL::X509::Name.parse("CN=JFA test DCL TLS CA"), nil, 6, true, 0)
    tls_key = crypto.create_key_pair
    tls_name = OpenSSL::X509::Name.parse("CN=tests")
    tls_cert = certificate(tls_key, tls_ca_key, tls_name,
      OpenSSL::X509::Certificate.from_der(tls_ca), 7, false, nil,
      subject_alt_name: "DNS:tests")
    @cert_path = File.join(@directory, "jfa-dcl-tls.crt")
    @server_cert_path = File.join(@directory, "jfa-dcl-server.crt")
    File.write(@cert_path, OpenSSL::X509::Certificate.from_der(tls_ca).to_pem)
    File.write(@server_cert_path, OpenSSL::X509::Certificate.from_der(tls_cert).to_pem)
    File.write(File.join(@directory, "jfa-dcl-tls.key"),
      OpenSSL::PKey::EC.from_private_bytes(tls_key.private_bits.as(Bytes),
        Matter::Crypto::CRYPTO_EC_CURVE_NIST).to_pem)
  end

  def write_mode(mode : String) : Nil
    @state["mode"] = mode
    File.write(@state_path, @state.to_json)
  end

  def state_path : String
    @state_path
  end

  def key_path : String
    File.join(@directory, "jfa-dcl-tls.key")
  end

  private def name(oid : String, identifier : UInt64, common_name : String) : OpenSSL::X509::Name
    OpenSSL::X509::Name.new.tap do |value|
      value.add_entry(oid, identifier.to_s(16).upcase.rjust(16, '0'))
      value.add_entry("CN", common_name)
    end
  end

  private def certificate(key : Matter::Crypto::Key, issuer_key : Matter::Crypto::Key,
                          subject : OpenSSL::X509::Name, issuer : OpenSSL::X509::Certificate?,
                          serial : Int32, ca : Bool, path_len : Int32? = nil,
                          subject_skid : Bytes? = nil, subject_alt_name : String? = nil) : Bytes
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = OpenSSL::BN.new(serial)
    cert.not_before = OpenSSL::ASN1::Time.days_from_now(-1)
    cert.not_after = OpenSSL::ASN1::Time.days_from_now(1)
    cert.subject = subject
    cert.issuer = issuer.try(&.subject) || subject
    cert.public_key = OpenSSL::PKey::EC.from_public_bytes(key.public_key,
      Matter::Crypto::CRYPTO_EC_CURVE_NIST)
    constraints = "critical,CA:#{ca ? "TRUE" : "FALSE"}"
    constraints += ",pathlen:#{path_len}" if path_len
    cert.add_extension(OpenSSL::X509::Extension.new("basicConstraints", constraints))
    usage = ca ? "keyCertSign,cRLSign" : "digitalSignature"
    cert.add_extension(OpenSSL::X509::Extension.new("keyUsage", "critical,#{usage}"))
    if subject_alt_name
      cert.add_extension(OpenSSL::X509::Extension.new("subjectAltName", subject_alt_name))
      cert.add_extension(OpenSSL::X509::Extension.new("extendedKeyUsage", "serverAuth"))
    end
    context = LibCrypto::MatterX509V3Context.new
    context_pointer = pointerof(context).as(LibCrypto::X509V3_CTX*)
    LibCrypto.x509v3_set_ctx(context_pointer, issuer || cert, cert, nil, nil, 0)
    skid_value = subject_skid.try(&.hexstring.upcase.scan(/../).join(":")) || "hash"
    { {"subjectKeyIdentifier", skid_value}, {"authorityKeyIdentifier", "keyid:always"} }.each do |extension, value|
      nid = LibCrypto.obj_sn2nid(extension)
      raw = LibCrypto.x509v3_ext_conf_nid(nil, context_pointer, nid, value)
      raise "Cannot create #{extension}" if raw.null?
      begin
        cert.add_extension(OpenSSL::X509::Extension.new(raw))
      ensure
        LibCrypto.x509_extension_free(raw)
      end
    end
    private_key = OpenSSL::PKey::EC.from_private_bytes(issuer_key.private_bits.as(Bytes),
      Matter::Crypto::CRYPTO_EC_CURVE_NIST)
    cert.sign(private_key, OpenSSL::Digest.new("SHA256"))
    cert.to_der
  end
end
