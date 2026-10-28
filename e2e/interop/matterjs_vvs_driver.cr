require "../../src/matter/controller"
require "../../src/matter/controller/vid_verification_dcl"
require "json"
require "base64"

# A deliberately opt-in live peer test. matter.js owns the device's NOC,
# FabricDescriptor, and SignVIDVerificationRequest response. This process owns
# only the test VID signer, its DCL-shaped trust record, and the controller.
module MatterjsVvsDriver
  extend self

  NODE_ID     = 0xA501_u64
  VENDOR_ID   = 0xFFF1_u16
  TIMEOUT     = 90.seconds
  ROOT_ID_OID = "1.3.6.1.4.1.37244.1.4"
  ICA_ID_OID  = "1.3.6.1.4.1.37244.1.3"

  private def state(path : String) : Matter::Controller::StateStore
    Matter::Controller::StateStore.new(Matter::Storage::YamlFile.new(path))
  end

  private def peer(port : Int32) : Socket::IPAddress
    Socket::IPAddress.new("127.0.0.1", port)
  end

  private def client(store : Matter::Controller::StateStore) : Matter::Controller::Client
    saved = store.load
    Matter::Controller::Client.new(counter_lease: store.counter_lease(saved.commissioner_node_id))
  end

  private def read_list(type : T.class, im : Matter::Controller::ImClient,
                        session : Matter::Session::SecureContext, address : Socket::IPAddress,
                        attribute : UInt32) : Array(T) forall T
    report = im.read_attribute(session: session, peer: address, endpoint_id: 0_u16,
      cluster_id: Matter::Cluster::OperationalCredentials::CLUSTER_ID,
      attribute_id: attribute, fabric_filtered: false)
    data = report.attribute_reports.try(&.find(&.attribute_data)).try(&.attribute_data).try(&.data) ||
           raise Matter::ProtocolError.new("OperationalCredentials read omitted #{attribute}")
    Array(T).from_tlv(data.to_slice)
  end

  private def ca_cert(key : Matter::Crypto::Key, issuer_key : Matter::Crypto::Key,
                      identifier : UInt64, oid : String, common_name : String,
                      issuer_cert : OpenSSL::X509::Certificate? = nil,
                      path_length : Int32 = 0) : Bytes
    name = OpenSSL::X509::Name.new
    name.add_entry(oid, identifier.to_s(16).upcase.rjust(16, '0'))
    name.add_entry("CN", common_name)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = OpenSSL::BN.new(identifier.to_i)
    cert.not_before = OpenSSL::ASN1::Time.days_from_now(-1)
    cert.not_after = OpenSSL::ASN1::Time.days_from_now(1)
    cert.subject = name
    cert.issuer = issuer_cert.try(&.subject) || name
    cert.public_key = OpenSSL::PKey::EC.from_public_bytes(key.public_key,
      Matter::Crypto::CRYPTO_EC_CURVE_NIST)
    cert.add_extension(OpenSSL::X509::Extension.new("basicConstraints", "critical,CA:TRUE,pathlen:#{path_length}"))
    cert.add_extension(OpenSSL::X509::Extension.new("keyUsage", "critical,keyCertSign,cRLSign"))
    context = LibCrypto::MatterX509V3Context.new
    pointer = pointerof(context).as(LibCrypto::X509V3_CTX*)
    LibCrypto.x509v3_set_ctx(pointer, issuer_cert || cert, cert, nil, nil, 0)
    { {"subjectKeyIdentifier", "hash"}, {"authorityKeyIdentifier", "keyid:always"} }.each do |extension, value|
      nid = LibCrypto.obj_sn2nid(extension)
      raw = LibCrypto.x509v3_ext_conf_nid(nil, pointer, nid, value)
      raise Matter::CertificateError.new("Could not create #{extension}") if raw.null?
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

  private def skid(der : Bytes) : Bytes
    cert = OpenSSL::X509::Certificate.from_der(der)
    raw = LibCrypto.x509_get0_subject_key_id(cert)
    Slice.new(LibCrypto.asn1_string_get0_data(raw).as(UInt8*),
      LibCrypto.asn1_string_length(raw)).dup
  end

  private def vvsc(signer : Matter::Crypto::Key, issuer : Matter::Crypto::Key,
                   issuer_skid : Bytes, crypto : Matter::Crypto::StandardCrypto) : Bytes
    cert = Matter::Crypto::MatterCertificate::Builder.root(signer, 5_u64, Bytes[0x05], crypto)
    fields = TLV::Any.from_slice(cert).as_structure
    fields[3_u8] = TLV::Any.new(TLV::List{
      TLV::Any.new(2_u64, Matter::Crypto::MatterCertificate::Asn1::Dn::IcacId.value),
      TLV::Any.new("VVS test intermediate", Matter::Crypto::MatterCertificate::Asn1::Dn::CommonName.value),
    }, 3_u8)
    fields[6_u8] = TLV::Any.new(TLV::List{
      TLV::Any.new(3_u64, Matter::Crypto::MatterCertificate::Asn1::Dn::VvsId.value),
      TLV::Any.new("VVS test signer", Matter::Crypto::MatterCertificate::Asn1::Dn::CommonName.value),
    }, 6_u8)
    constraints = TLV::Structure.new
    constraints[Matter::Crypto::MatterCertificate::Asn1::BASIC_CONSTRAINT_IS_CA] =
      TLV::Any.new(false, Matter::Crypto::MatterCertificate::Asn1::BASIC_CONSTRAINT_IS_CA)
    signer_skid = crypto.compute_sha1(signer.public_key)
    fields[10_u8] = TLV::Any.new(TLV::List{
      TLV::Any.new(constraints, Matter::Crypto::MatterCertificate::Asn1::Extension::BasicConstraints.value),
      TLV::Any.new(1_u16, Matter::Crypto::MatterCertificate::Asn1::Extension::KeyUsage.value),
      TLV::Any.new(signer_skid, Matter::Crypto::MatterCertificate::Asn1::Extension::SubjectKeyIdentifier.value),
      TLV::Any.new(issuer_skid, Matter::Crypto::MatterCertificate::Asn1::Extension::AuthorityKeyIdentifier.value),
    }, 10_u8)
    tbs = Matter::Crypto::MatterCertificate::Asn1.to_unsigned_asn1(TLV::Any.new(fields, nil))
    fields[11_u8] = TLV::Any.new(crypto.sign_ecdsa(issuer, tbs), 11_u8)
    TLV::Any.new(fields, nil).to_slice
  end

  def provision(state_path : String, trust_path : String, code : String, port : Int32) : Nil
    store = state(state_path)
    address = peer(port)
    client = client(store)
    begin
      commissioner = Matter::Controller::Commissioning::Commissioner.new(store, client,
        timeout: TIMEOUT,
        attestation_verifier: Matter::Controller::DeviceAttestationVerifier.new(
          Matter::Controller::AttestationTrustStore.matter_test_fixture))
      commissioner.pairing_code(NODE_ID, code, address)
      fabric = store.load.fabric.as(Matter::Controller::FabricInfo)
      session = Matter::Controller::Pairing::CasePairing.new.pair(client, address,
        fabric, peer_node_id: NODE_ID, timeout: TIMEOUT)
      im = Matter::Controller::ImClient.new(client, TIMEOUT)
      descriptors = read_list(Matter::Cluster::OperationalCredentials::Tlv::FabricDescriptor,
        im, session, address, Matter::Cluster::OperationalCredentials::ATTR_FABRICS)
      descriptor = descriptors.find { |item| item.fabric_id == fabric.fabric_id && item.node_id == NODE_ID } ||
                   raise Matter::AuthenticationError.new("matter.js did not expose the commissioned fabric")
      raise Matter::AuthenticationError.new("Unexpected vendor on matter.js fabric") unless descriptor.vendor_id == VENDOR_ID

      crypto = Matter::Crypto::StandardCrypto.new
      issuer = crypto.create_key_pair
      intermediate = crypto.create_key_pair
      signer = crypto.create_key_pair
      root_der = ca_cert(issuer, issuer, 1_u64, ROOT_ID_OID, "VVS test root", path_length: 1)
      intermediate_der = ca_cert(intermediate, issuer, 2_u64, ICA_ID_OID,
        "VVS test intermediate", OpenSSL::X509::Certificate.from_der(root_der))
      unrelated = crypto.create_key_pair
      wrong_root_der = ca_cert(unrelated, unrelated, 3_u64, ROOT_ID_OID,
        "Unrelated test root", path_length: 1)
      signer_skid = crypto.compute_sha1(signer.public_key)
      matter_vvsc = vvsc(signer, intermediate, skid(intermediate_der), crypto)
      statement_tbs = IO::Memory.new
      statement_tbs.write_byte Matter::Controller::VidVerification::STATEMENT_VERSION
      statement_tbs.write Matter::Controller::VidVerification.binding_message(descriptor)
      statement_tbs.write signer_skid
      signature = crypto.sign_ecdsa(signer, statement_tbs.to_slice)
      statement = IO::Memory.new
      statement.write_byte Matter::Controller::VidVerification::STATEMENT_VERSION
      statement.write signer_skid
      statement.write signature
      signed_statement = statement.to_slice
      raise Matter::ProtocolError.new("VVS has wrong length") unless signed_statement.size == Matter::Controller::VidVerification::STATEMENT_SIZE

      request = Matter::Cluster::OperationalCredentials::Tlv::SetVIDVerificationStatementRequest.new(
        VENDOR_ID, signed_statement, matter_vvsc)
      result = im.invoke(session: session, peer: address, endpoint_id: 0_u16,
        cluster_id: Matter::Cluster::OperationalCredentials::CLUSTER_ID,
        command_id: Matter::Cluster::OperationalCredentials::CMD_SET_VID_VERIFICATION_STATEMENT,
        fields: request.to_slice)
      status = result.invoke_responses.first?.try(&.command_status).try(&.status.status)
      raise Matter::ProtocolError.new("matter.js rejected SetVIDVerificationStatement: #{status}") unless status == Matter::InteractionModel::StatusCode::Success.value

      installed = read_list(Matter::Cluster::OperationalCredentials::Tlv::FabricDescriptor,
        im, session, address, Matter::Cluster::OperationalCredentials::ATTR_FABRICS)
        .find { |item| item.fabric_index == descriptor.fabric_index }
      noc = read_list(Matter::Cluster::OperationalCredentials::Tlv::NOC,
        im, session, address, Matter::Cluster::OperationalCredentials::ATTR_NOCS)
        .find { |item| item.fabric_index == descriptor.fabric_index }
      unless installed && installed.vid_verification_statement == signed_statement && noc && noc.vvsc == matter_vvsc
        raise Matter::AuthenticationError.new("VVS/VVSC was not read back from matter.js on the commissioned fabric")
      end
      File.write(trust_path, {
        "mode"             => "active",
        "root_der"         => Base64.strict_encode(root_der),
        "intermediate_der" => Base64.strict_encode(intermediate_der),
        "wrong_root_der"   => Base64.strict_encode(wrong_root_der),
        "fabric_index"     => descriptor.fabric_index,
      }.to_json)
      puts "PASS: matter.js accepted VVS/VVSC over CASE and returned exact bytes on fabric #{descriptor.fabric_index}"
    ensure
      client.close
    end
  end

  def verify(state_path : String, trust_path : String, gateway : String,
             port : Int32, expected : String) : Nil
    store = state(state_path)
    fabric = store.load.fabric.as(Matter::Controller::FabricInfo)
    address = peer(port)
    index = JSON.parse(File.read(trust_path))["fabric_index"].as_i.to_u8
    client = client(store)
    begin
      # A new client forces a new CASE exchange and a fresh SignVID challenge.
      session = Matter::Controller::Pairing::CasePairing.new.pair(client, address,
        fabric, peer_node_id: NODE_ID, timeout: TIMEOUT)
      im = Matter::Controller::ImClient.new(client, TIMEOUT)
      source = if mapped_port = ENV["MATTER_VVS_TEST_DCL_PORT"]?
                 # Unprivileged macOS test runners cannot bind port 443. Keep
                 # the production source URL and HTTPS fetch/parser, but map
                 # only this fixture transport to its high local port.
                 fetch = ->(url : String) { String.new(Matter::Controller::DclAttestationRevocation.fetch_https(
                   url.sub("https://127.0.0.1/", "https://127.0.0.1:#{mapped_port}/"))) }
                 Matter::Controller::VidVerification::HttpDclSource.new(gateway, fetch)
               else
                 Matter::Controller::VidVerification::HttpDclSource.new(gateway)
               end
      trust = Matter::Controller::VidVerification::DclOperationalTrustAnchors.new(
        source)
      begin
        verified = Matter::Controller::VidVerification.verify(im, session, address, index, trust)
        raise Matter::AuthenticationError.new("Wrong fabric verified") unless verified.descriptor.fabric_id == fabric.fabric_id
        unless verified.descriptor.vid_verification_statement && verified.noc.vvsc
          raise Matter::AuthenticationError.new("Verified fabric omitted the over-wire VVS or VVSC")
        end
      rescue ex : Matter::AuthenticationError
        unless expected == "deny" && ex.message.to_s.includes?("Vendor statement has no trusted signer")
          raise ex
        end
        puts "PASS: matter.js VVS-bearing fabric denied: #{ex.message}"
        return
      end
      raise Matter::AuthenticationError.new("Untrusted VVS was accepted") if expected == "deny"
      puts "PASS: matter.js VVS-bearing fabric verified over fresh CASE and HTTPS DCL fixture"
    ensure
      client.close
    end
  end
end

case ARGV.shift?
when "provision"
  MatterjsVvsDriver.provision(ARGV[0], ARGV[1], ARGV[2], ARGV[3].to_i)
when "verify"
  MatterjsVvsDriver.verify(ARGV[0], ARGV[1], ARGV[2], ARGV[3].to_i, ARGV[4])
else
  STDERR.puts "Usage: matterjs_vvs_driver {provision STATE TRUST CODE PORT|verify STATE TRUST GATEWAY PORT accept|deny}"
  exit 2
end
