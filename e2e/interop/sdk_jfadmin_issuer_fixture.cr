require "../../src/matter/controller"
require "base64"
require "json"

# Test-only import of an SDK JFC issuer into the Crystal JFA's private
# bootstrap store. The JFC INI and this store must never be uploaded as logs.
module SdkJfadminIssuerFixture
  extend self

  def decode(record : JSON::Any, name : String) : Bytes
    Base64.decode(record[name].as_s)
  end

  def key_pair(record : JSON::Any, name : String) : {Bytes, Bytes}
    serialized = decode(record, name)
    unless serialized.size == 97 && serialized[0] == 0x04_u8
      raise Matter::ConfigurationError.new("Invalid SDK #{name} keypair")
    end
    public_key = serialized[0, 65]
    private_key = serialized[65, 32]
    key = Matter::Crypto::Key.new(Matter::Crypto::KeyType::EC, Matter::Crypto::CurveType::P256)
    key.private_bits = private_key
    unless key.public_key == public_key
      raise Matter::ConfigurationError.new("SDK #{name} keypair does not match")
    end
    {public_key, private_key}
  end

  def write(source_path : String, target_path : String) : Nil
    record = JSON.parse(File.read(source_path))
    root_public, root_private = key_pair(record, "root_keypair")
    icac_public, icac_private = key_pair(record, "icac_keypair")
    root = decode(record, "root_certificate")
    icac = if record["icac_certificate"]?
             decode(record, "icac_certificate")
           else
             root_key = Matter::Crypto::Key.new(Matter::Crypto::KeyType::EC, Matter::Crypto::CurveType::P256)
             root_key.private_bits = root_private
             root_id = Matter::Crypto::MatterCertificate.from_slice(root).subject.rcac_id ||
                       raise Matter::ConfigurationError.new("SDK issuer root has no RCAC ID")
             crypto = Matter::Crypto::StandardCrypto.new
             Matter::Crypto::MatterCertificate::Builder.intermediate(
               icac_public, nil, 3_u64, root_key, root_id,
               crypto.random_bytes(16), crypto,
               anchor: true, issuer_certificate: root)
           end
    unless Matter::Crypto::MatterCertificate.public_key_from_tlv(root) == root_public &&
           Matter::Crypto::MatterCertificate.public_key_from_tlv(icac) == icac_public
      raise Matter::ConfigurationError.new("SDK issuer certificates do not match private keys")
    end
    dummy = Matter::Crypto::StandardCrypto.new.create_key_pair
    fabric = Matter::Controller::FabricInfo.new(
      fabric_id: 1_u64, controller_node_id: 1_u64,
      ipk_value: Bytes.new(16), root_cert: root, root_public_key: root_public,
      controller_noc: Bytes.empty, controller_private_key: dummy.private_key,
      root_private_key: root_private, intermediate_cert: icac,
      intermediate_private_key: icac_private)
    Matter::Controller::StateStore.new(Matter::Storage::YamlFile.new(target_path)).save(
      Matter::Controller::State.new(fabric: fabric, commissioner_node_id: 1_u64))
  end
end

unless ARGV.size == 2
  STDERR.puts "Usage: sdk_jfadmin_issuer_fixture <private-sdk-issuer.json> <private-bootstrap.yml>"
  exit 2
end
SdkJfadminIssuerFixture.write(ARGV[0], ARGV[1])
