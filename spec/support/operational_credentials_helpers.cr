# Fixtures shared by the operational_credentials_*_spec.cr files:
# certificate/NOC builders and the request TLV encoders.
require "../spec_helper"
require "../../src/matter/cluster/operational_credentials"
require "../../src/matter/crypto/certificate"
require "../../src/matter/controller/certificate_util"

def csr_public_key(result : Matter::Cluster::CommandResponse) : Bytes
  response = Matter::Cluster::OperationalCredentials::Tlv::CsrResponse.from_slice(result.response.as(TLV::Any).to_slice)
  elements = Matter::Commissioning::CredentialService::CSRElements.from_slice(response.nocsr_elements)
  Matter::Controller::CertificateUtil.extract_uncompressed_public_key_from_csr(elements.csr)
end

def csr_public_key(result : Matter::Cluster::OperationalCredentials::CSRResponse) : Bytes
  elements = Matter::Commissioning::CredentialService::CSRElements.from_slice(result.nocsr_elements)
  Matter::Controller::CertificateUtil.extract_uncompressed_public_key_from_csr(elements.csr)
end

# Helper functions for TLV encoding command data
def build_op_creds_cluster(endpoint_id : Matter::DataType::EndpointNumber = endpoint(0))
  fabric_table = Matter::FabricTable.new(Matter::Storage::Memory.new)
  Matter::Cluster::OperationalCredentials.new(fabric_table, endpoint_id, nil)
end

def create_attestation_request_tlv(nonce : Bytes) : TLV::Any
  Matter::Cluster::OperationalCredentials::Tlv::AttestationRequest.new(
    attestation_nonce: nonce
  ).to_tlv(nil)
end

def create_certificate_chain_request_tlv(cert_type : UInt8) : TLV::Any
  Matter::Cluster::OperationalCredentials::Tlv::CertificateChainRequest.new(
    certificate_type: Matter::Cluster::OperationalCredentials::Tlv::CertificateChainType.new(cert_type)
  ).to_tlv(nil)
end

def create_csr_request_tlv(nonce : Bytes, is_for_update : Bool? = nil) : TLV::Any
  Matter::Cluster::OperationalCredentials::Tlv::CsrRequest.new(
    csr_nonce: nonce,
    is_for_update_noc: is_for_update
  ).to_tlv(nil)
end

def create_add_noc_request_tlv(noc : Bytes, icac : Bytes?, ipk : Bytes, admin_subject : UInt64, admin_vendor : UInt16) : TLV::Any
  Matter::Cluster::OperationalCredentials::Tlv::AddNocRequest.new(
    noc_value: noc,
    icac_value: icac,
    ipk_value: ipk,
    case_admin_subject: admin_subject,
    admin_vendor_id: admin_vendor
  ).to_tlv(nil)
end

def create_update_noc_request_tlv(noc : Bytes, icac : Bytes?, fabric_index : UInt8) : TLV::Any
  Matter::Cluster::OperationalCredentials::Tlv::UpdateNocRequest.new(
    noc_value: noc,
    fabric_index: fabric_index,
    icac_value: icac
  ).to_tlv(nil)
end

def create_add_trusted_root_cert_request_tlv(cert : Bytes) : TLV::Any
  Matter::Cluster::OperationalCredentials::Tlv::AddTrustedRootCertificateRequest.new(
    root_certificate: cert
  ).to_tlv(nil)
end

def create_remove_fabric_request_tlv(fabric_index : UInt8) : TLV::Any
  Matter::Cluster::OperationalCredentials::Tlv::RemoveFabricRequest.new(
    fabric_index: fabric_index
  ).to_tlv(nil)
end

# A node certificate for `node_id` on `fabric_id`, issued by the test authority
def create_mock_noc(node_id : UInt64, fabric_id : UInt64) : Bytes
  TestCertificateAuthority.default.issue(fabric_id, node_id)
end

# The same, for a node holding `public_key`
def create_mock_noc_with_key(node_id : UInt64, fabric_id : UInt64, public_key : Bytes,
                             rcac_id : UInt64 = TestCertificateAuthority::ROOT_CERTIFICATE_ID) : Bytes
  TestCertificateAuthority.default.issue(fabric_id, node_id, public_key, rcac_id)
end

# Helper to create UpdateFabricLabel request TLV
def create_update_fabric_label_request(label : String, fabric_index : UInt8) : TLV::Any
  Matter::Cluster::OperationalCredentials::Tlv::UpdateFabricLabelRequest.new(
    label: label,
    fabric_index: fabric_index
  ).to_tlv(nil)
end

module OpCredsTestHelpers
  extend self

  # Helper to create a fabric table with storage
  def create_fabric_table(max_fabrics : UInt8 = 10_u8)
    storage = Matter::Storage::Memory.new
    Matter::FabricTable.new(storage, max_fabrics: max_fabrics)
  end

  # Helper to create test credentials
  def create_test_fabric(fabric_id : UInt64, fabric_index : UInt8, label : String = "Test")
    key = Matter::Crypto::Key.generate_key_pair
    Matter::Fabric.new(
      fabric_id: fabric_id,
      fabric_index: fabric_index,
      node_id: 0x1000_u64 + fabric_index,
      root_public_key: Bytes.new(65, 0_u8),
      operational_cert: Bytes.new(100, 0_u8),
      operational_key: key,
      ipk: Bytes.new(16, 0_u8),
      vendor_id: 0xFFF1_u16,
      label: label
    )
  end

  # A node certificate issued by the test authority
  def create_test_noc(
    fabric_id : UInt64 = TestCertificateAuthority::DEFAULT_FABRIC_ID,
    node_id : UInt64 = TestCertificateAuthority::DEFAULT_NODE_ID,
  ) : Bytes
    TestCertificateAuthority.default.issue(fabric_id, node_id)
  end

  # The root certificate those node certificates chain to
  def create_test_root_cert : Bytes
    TestCertificateAuthority.default.root_certificate
  end
end
