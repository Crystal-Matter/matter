require "../../src/matter/controller"
require "../../src/matter/controller/joint_commissioning"

# An independent Crystal controller commissions the official SDK JFA as an
# Anchor, then reads its Joint Fabric clusters over a newly established CASE
# session. The SDK JFC -> Crystal device smoke runs separately in the same CI
# job, using a fresh JFA store for this inverse direction.
module SdkJfaInverseDriver
  extend self

  FABRIC_ID         =   0xA200_u64
  CONTROLLER_ID     =   0xA201_u64
  SDK_JFA_ID        =   0xA202_u64
  TEST_VENDOR_ID    =   0xFFF1_u16
  SDK_JFA_PORT      =         5533
  SDK_DISCRIMINATOR =     3840_u16
  SDK_PASSCODE      = 11022033_u32
  JFA_ENDPOINT      =        1_u16
  TIMEOUT           = 90.seconds
  SDK_PAA_CERT      = "credentials/development/paa-root-certs/Chip-Test-PAA-FFF1-Cert.der"
  SDK_CD_CERT_GLOB  = "credentials/development/cd-certs/CSA_Matter_CD_Signing_Key_*.cert.der"

  private def sdk_attestation_trust(sdk_root : String) : Matter::Controller::AttestationTrustStore
    trust = Matter::Controller::AttestationTrustStore.matter_test_fixture
    trust.paa_certificates << File.read(File.join(sdk_root, SDK_PAA_CERT)).to_slice.dup
    signer_paths = Dir.glob(File.join(sdk_root, SDK_CD_CERT_GLOB))
    raise Matter::ConfigurationError.new("No SDK development CD signers found") if signer_paths.empty?
    signer_paths.each do |path|
      signer = OpenSSL::X509::Certificate.from_der(File.read(path).to_slice)
      extension = signer.extensions.find { |entry| entry.oid == "subjectKeyIdentifier" } ||
                  raise Matter::ConfigurationError.new("SDK CD signer has no subject key identifier")
      ski = extension.value.gsub(/[^0-9A-Fa-f]/, "").upcase
      unless ski.matches?(/\A[0-9A-F]{40}\z/)
        raise Matter::ConfigurationError.new("SDK CD signer has invalid subject key identifier")
      end
      trust.cd_signers[ski] = signer.public_key.as(OpenSSL::PKey::EC).public_key_bytes
    end
    trust
  end

  private def store(path : String) : Matter::Controller::StateStore
    Matter::Controller::StateStore.new(Matter::Storage::YamlFile.new(path))
  end

  private def attribute(im : Matter::Controller::ImClient,
                        session : Matter::Session::SecureContext,
                        peer : Socket::IPAddress, cluster : UInt32,
                        id : UInt32) : TLV::Any
    report = im.read_attribute(session: session, peer: peer,
      endpoint_id: JFA_ENDPOINT, cluster_id: cluster, attribute_id: id)
    data = report.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
      .first.attribute_data || raise Matter::ProtocolError.new("SDK JFA attribute read returned a status")
    data.data || raise Matter::ProtocolError.new("SDK JFA attribute read omitted data")
  end

  def run(path : String, address : String, sdk_root : String) : Nil
    bootstrap = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      FABRIC_ID, CONTROLLER_ID, TEST_VENDOR_ID)
    state_store = store(path)
    state_store.save(Matter::Controller::State.new(fabric: bootstrap.fabric,
      commissioner_node_id: CONTROLLER_ID))
    peer = Socket::IPAddress.new(address, SDK_JFA_PORT)
    client = Matter::Controller::Client.new(unsecured_source_node_id: CONTROLLER_ID)
    begin
      issuer = ->(fabric_id : UInt64, node_id : UInt64, public_key : Bytes) do
        unless fabric_id == FABRIC_ID && node_id == SDK_JFA_ID
          raise Matter::ConfigurationError.new("Unexpected SDK JFA commissioning identity")
        end
        bootstrap.issue_anchor_administrator_noc(node_id, public_key)
      end
      code = Matter::SetupPayload.generate_manual_code(SDK_DISCRIMINATOR, SDK_PASSCODE)
      Matter::Controller::Commissioning::Commissioner.new(state_store, client,
        timeout: TIMEOUT, certificate_issuer: issuer,
        attestation_verifier: Matter::Controller::DeviceAttestationVerifier.new(
          sdk_attestation_trust(sdk_root))).pairing_code(
        SDK_JFA_ID, code, peer)
      puts "Crystal commissioned official SDK JFA as Anchor"

      fabric = state_store.load.fabric || raise Matter::ConfigurationError.new("Anchor fabric missing")
      session = Matter::Controller::Pairing::CasePairing.new.pair(client, peer, fabric,
        peer_node_id: SDK_JFA_ID, timeout: TIMEOUT)
      im = Matter::Controller::ImClient.new(client, TIMEOUT)
      admin_index = attribute(im, session, peer,
        Matter::Cluster::JointFabricAdministrator::CLUSTER_ID,
        Matter::Cluster::JointFabricAdministrator::ATTR_ADMINISTRATOR_FABRIC_INDEX)
      unless admin_index.as_u8 == 1_u8
        raise Matter::ProtocolError.new("SDK JFA did not activate its Anchor fabric")
      end

      root = attribute(im, session, peer,
        Matter::Cluster::JointFabricDatastore::CLUSTER_ID,
        Matter::Cluster::JointFabricDatastore::ATTR_ANCHOR_ROOT_CA)
      unless Bytes.from_tlv(root.to_slice) == fabric.root_cert
        raise Matter::AuthenticationError.new("SDK Datastore AnchorRootCA differs from commissioned root")
      end
      anchor_id = attribute(im, session, peer,
        Matter::Cluster::JointFabricDatastore::CLUSTER_ID,
        Matter::Cluster::JointFabricDatastore::ATTR_ANCHOR_NODE_ID)
      unless anchor_id.as_u64 == SDK_JFA_ID
        raise Matter::ProtocolError.new("SDK Datastore AnchorNodeID differs from commissioned JFA")
      end
      admins = attribute(im, session, peer,
        Matter::Cluster::JointFabricDatastore::CLUSTER_ID,
        Matter::Cluster::JointFabricDatastore::ATTR_ADMIN_LIST)
      entries = Array(Matter::Cluster::JointFabricDatastore::DatastoreAdministratorInformationEntryStruct)
        .from_tlv(admins.to_slice)
      unless entries.any? { |entry| entry.node_id == SDK_JFA_ID && entry.vendor_id == TEST_VENDOR_ID }
        raise Matter::ProtocolError.new("SDK Datastore AdminList omitted Anchor JFA")
      end
      puts "PASS: Crystal CASE read official SDK JFA and Datastore Anchor identity"
    ensure
      client.close
    end
  end
end

unless ARGV.size == 3
  STDERR.puts "Usage: sdk_jfa_inverse_driver <private-controller-state.yml> <sdk-jfa-ipv6-address> <sdk-root>"
  exit 2
end
SdkJfaInverseDriver.run(ARGV[0], ARGV[1], ARGV[2])
