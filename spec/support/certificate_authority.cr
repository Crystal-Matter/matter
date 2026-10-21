require "../../src/matter/crypto/certificate_builder"

# A fabric certificate authority for specs. The device checks that a node
# certificate was issued by the root it was given, so fixtures have to be
# signed rather than filled in. `default` is the authority most specs share;
# a spec that needs two roots makes another with `new`.
class TestCertificateAuthority
  ROOT_CERTIFICATE_ID = 1_u64
  SERIAL_BYTES        =     8

  DEFAULT_FABRIC_ID = 0x1234567890_u64
  DEFAULT_NODE_ID   =     0xABCDEF_u64

  @@default : TestCertificateAuthority?

  def self.default : TestCertificateAuthority
    @@default ||= new
  end

  getter key : Matter::Crypto::Key
  getter node_key : Matter::Crypto::Key

  def initialize(@crypto : Matter::Crypto::CryptoBase = Matter::Crypto::StandardCrypto.new)
    @key = @crypto.create_key_pair
    @node_key = @crypto.create_key_pair
  end

  def root_public_key : Bytes
    @key.public_key
  end

  # Public key of the node the fixture certificates are issued to
  def node_public_key : Bytes
    @node_key.public_key
  end

  def root_certificate(rcac_id : UInt64 = ROOT_CERTIFICATE_ID) : Bytes
    Matter::Crypto::MatterCertificate::Builder.root(@key, rcac_id, serial, @crypto)
  end

  def issue(
    fabric_id : UInt64 = DEFAULT_FABRIC_ID,
    node_id : UInt64 = DEFAULT_NODE_ID,
    public_key : Bytes = node_public_key,
    rcac_id : UInt64 = ROOT_CERTIFICATE_ID,
  ) : Bytes
    Matter::Crypto::MatterCertificate::Builder.node(
      public_key: public_key,
      fabric_id: fabric_id,
      node_id: node_id,
      issuer_key: @key,
      issuer_rcac_id: rcac_id,
      serial: serial,
      crypto: @crypto
    )
  end

  # A node certificate signed by a root this authority is not
  def foreign_noc(fabric_id : UInt64 = DEFAULT_FABRIC_ID, node_id : UInt64 = DEFAULT_NODE_ID) : Bytes
    TestCertificateAuthority.new(@crypto).issue(fabric_id, node_id, node_public_key)
  end

  private def serial : Bytes
    @crypto.random_bytes(SERIAL_BYTES)
  end
end
