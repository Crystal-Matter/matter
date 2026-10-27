require "../spec_helper"
require "../../src/matter/commissioning/credential_service"
require "../../src/matter/controller/certificate_util"

# The credential flow on its own: no cluster, no wire.
CSR_NONCE_SIZE =     32
IPK_SIZE       =     16
TEST_SESSION   = 42_u64

private def credential_service(target : RecordingCredentialTarget, max_fabrics : UInt8 = 5_u8) : Matter::Commissioning::CredentialService
  fabric_table = Matter::FabricTable.new(Matter::Storage::Memory.new, max_fabrics: max_fabrics)
  Matter::Commissioning::CredentialService.new(target, fabric_table)
end

# Walks the commissioning credential exchange up to (but not including) AddNOC
private def commission(service : Matter::Commissioning::CredentialService, session_id : UInt64 = TEST_SESSION) : Bytes
  result = service.create_csr(
    nonce: Bytes.new(CSR_NONCE_SIZE, 0x42_u8),
    session_id: session_id,
    is_for_update_noc: false,
    pase_session: true
  )
  service.add_trusted_root_certificate(CommissioningCertificates.root_certificate)
  elements = Matter::Commissioning::CredentialService::CSRElements.from_slice(result.as(Tuple(Bytes, Bytes))[0])
  Matter::Controller::CertificateUtil.extract_uncompressed_public_key_from_csr(elements.csr)
end

private def update_csr(service : Matter::Commissioning::CredentialService) : Bytes
  result = service.create_csr(
    nonce: Bytes.new(CSR_NONCE_SIZE, 0x43_u8),
    session_id: TEST_SESSION,
    is_for_update_noc: true,
    pase_session: false
  )
  elements = Matter::Commissioning::CredentialService::CSRElements.from_slice(result.as(Tuple(Bytes, Bytes))[0])
  Matter::Controller::CertificateUtil.extract_uncompressed_public_key_from_csr(elements.csr)
end

private def commissioned_service : {Matter::Commissioning::CredentialService, UInt8}
  service = credential_service(RecordingCredentialTarget.new)
  public_key = commission(service)
  outcome = service.add_noc(
    noc: TestCertificateAuthority.default.issue(public_key: public_key),
    icac: nil,
    ipk: Bytes.new(IPK_SIZE, 0_u8),
    case_admin_subject: 0x9999_u64,
    admin_vendor_id: 0xFFF1_u16,
    session_id: TEST_SESSION
  )
  service.commit_pending
  {service, outcome.fabric_index.as(UInt8)}
end

module Matter::Commissioning
  describe CredentialService do
    it "rejects direct attestation replacement and pending-state changes while fenced" do
      service = credential_service(RecordingCredentialTarget.new)
      service.on_before_credential_change = ->(_mutation : CredentialService::CredentialMutation) {
        raise Matter::ClusterError.new("Participant recovery lease", Matter::InteractionModel::StatusCode::Busy)
      }

      expect_raises(Matter::ClusterError) do
        service.set_attestation_credentials(Bytes[1], Bytes[2], Matter::Crypto::Key.generate_key_pair)
      end
      expect_raises(Matter::ClusterError) { service.set_attestation_from_manager(0xFFF1_u16, 1_u16) }
      expect_raises(Matter::ClusterError) { service.reset_pending }
      expect_raises(Matter::ClusterError) { service.rollback_pending }
      expect_raises(Matter::ClusterError) { service.commit_pending }
    end

    it "rejects a direct CSR before pending credentials change" do
      service = credential_service(RecordingCredentialTarget.new)
      service.on_before_credential_change = ->(_mutation : CredentialService::CredentialMutation) {
        raise Matter::ClusterError.new("Participant recovery lease", Matter::InteractionModel::StatusCode::Busy)
      }

      expect_raises(Matter::ClusterError) do
        service.create_csr(Bytes.new(CSR_NONCE_SIZE, 0_u8), TEST_SESSION, false, true)
      end
      service.pending.csr_exists?(TEST_SESSION).should be_false
      service.fabric_table.backend.read(CredentialJournal::COLLECTION, CredentialJournal::ID).should be_nil
    end

    it "rejects direct fabric removal before creating a removal journal" do
      service, index = commissioned_service
      backend = service.fabric_table.backend
      service.on_before_credential_change = ->(_mutation : CredentialService::CredentialMutation) {
        raise Matter::ClusterError.new("Participant recovery lease", Matter::InteractionModel::StatusCode::Busy)
      }

      expect_raises(Matter::ClusterError) { service.remove_fabric(index) }
      service.fabric_table.get_fabric(index).should_not be_nil
      backend.read(FabricRemovalJournal::COLLECTION, FabricRemovalJournal::ID).should be_nil
    end

    it "rejects direct root restoration while a recovery lease is held" do
      target = RecordingCredentialTarget.new
      service = credential_service(target)
      service.on_before_credential_change = ->(_mutation : CredentialService::CredentialMutation) {
        raise Matter::ClusterError.new("Participant recovery lease", Matter::InteractionModel::StatusCode::Busy)
      }

      expect_raises(Matter::ClusterError) do
        service.restore_root_cert(CommissioningCertificates.root_certificate)
      end
      target.trusted_root_certificates.should be_empty
    end

    describe "#create_csr" do
      it "generates a CSR and remembers the session it belongs to" do
        service = credential_service(RecordingCredentialTarget.new)

        result = service.create_csr(
          nonce: Bytes.new(CSR_NONCE_SIZE, 0x42_u8),
          session_id: TEST_SESSION,
          is_for_update_noc: false,
          pase_session: true
        )

        result.should_not be_nil
        elements, signature = result.as(Tuple(Bytes, Bytes))
        elements.should_not be_empty
        signature.should_not be_empty
        service.pending.csr_exists?(TEST_SESSION).should be_true
      end

      it "refuses without an armed failsafe" do
        service = credential_service(RecordingCredentialTarget.new)
        service.failsafe_armed = false

        service.create_csr(
          nonce: Bytes.new(CSR_NONCE_SIZE, 0x42_u8),
          session_id: TEST_SESSION,
          is_for_update_noc: false,
          pase_session: true
        ).should be_nil
      end

      it "refuses an UpdateNOC CSR on a PASE session" do
        service = credential_service(RecordingCredentialTarget.new)

        service.create_csr(
          nonce: Bytes.new(CSR_NONCE_SIZE, 0x42_u8),
          session_id: TEST_SESSION,
          is_for_update_noc: true,
          pase_session: true
        ).should be_nil
      end
    end

    describe "#add_trusted_root_certificate" do
      it "stores the root certificate of this failsafe" do
        target = RecordingCredentialTarget.new
        service = credential_service(target)

        outcome = service.add_trusted_root_certificate(CommissioningCertificates.root_certificate)

        outcome.ok?.should be_true
        target.trusted_root_certificates.size.should eq(1)
        target.changes.should eq(1)
      end

      it "refuses a second root certificate in the same failsafe" do
        service = credential_service(RecordingCredentialTarget.new)
        service.add_trusted_root_certificate(CommissioningCertificates.root_certificate)

        outcome = service.add_trusted_root_certificate(CommissioningCertificates.root_certificate)

        outcome.status.should eq(NocStatus::InvalidNoc)
      end

      it "rejects something that is not a certificate" do
        service = credential_service(RecordingCredentialTarget.new)

        outcome = service.add_trusted_root_certificate(Bytes.new(8, 0xFF_u8))

        outcome.status.should eq(NocStatus::InvalidNoc)
      end
    end

    describe "#add_noc" do
      it "joins the fabric of the NOC" do
        target = RecordingCredentialTarget.new
        service = credential_service(target)
        added = [] of Fabric
        service.on_fabric_added = ->(fabric : Fabric) { added << fabric; nil }
        public_key = commission(service)

        outcome = service.add_noc(
          noc: TestCertificateAuthority.default.issue(public_key: public_key),
          icac: nil,
          ipk: Bytes.new(IPK_SIZE, 0_u8),
          case_admin_subject: 0x9999_u64,
          admin_vendor_id: 0xFFF1_u16,
          session_id: TEST_SESSION
        )

        outcome.ok?.should be_true
        service.fabric_table.size.should eq(1)
        added.size.should eq(1)
        target.committed.should eq([{outcome.fabric_index.as(UInt8), 0x9999_u64}])
      end

      it "refuses a node certificate the trusted root did not issue" do
        service = credential_service(RecordingCredentialTarget.new)
        commission(service)

        outcome = service.add_noc(
          noc: CommissioningCertificates.foreign_noc,
          icac: nil,
          ipk: Bytes.new(IPK_SIZE, 0_u8),
          case_admin_subject: 0x9999_u64,
          admin_vendor_id: 0xFFF1_u16,
          session_id: TEST_SESSION
        )

        outcome.ok?.should be_false
        outcome.status.should eq(Matter::Commissioning::NocStatus::InvalidNoc)
        service.fabric_table.size.should eq(0)
      end

      it "refuses a trusted NOC whose public key differs from the CSR" do
        service = credential_service(RecordingCredentialTarget.new)
        commission(service)

        outcome = service.add_noc(
          noc: CommissioningCertificates.noc,
          icac: nil,
          ipk: Bytes.new(IPK_SIZE, 0_u8),
          case_admin_subject: 0x9999_u64,
          admin_vendor_id: 0xFFF1_u16,
          session_id: TEST_SESSION
        )

        outcome.status.should eq(NocStatus::InvalidPublicKey)
        service.fabric_table.size.should eq(0)
      end

      it "requires the CSR of this session" do
        service = credential_service(RecordingCredentialTarget.new)
        commission(service, session_id: 1_u64)

        outcome = service.add_noc(
          noc: CommissioningCertificates.noc,
          icac: nil,
          ipk: Bytes.new(IPK_SIZE, 0_u8),
          case_admin_subject: 0x9999_u64,
          admin_vendor_id: 0xFFF1_u16,
          session_id: 2_u64
        )

        outcome.status.should eq(NocStatus::MissingCsr)
      end

      it "requires a root certificate" do
        service = credential_service(RecordingCredentialTarget.new)
        service.create_csr(
          nonce: Bytes.new(CSR_NONCE_SIZE, 0x42_u8),
          session_id: TEST_SESSION,
          is_for_update_noc: false,
          pase_session: true
        )

        outcome = service.add_noc(
          noc: CommissioningCertificates.noc,
          icac: nil,
          ipk: Bytes.new(IPK_SIZE, 0_u8),
          case_admin_subject: 0x9999_u64,
          admin_vendor_id: 0xFFF1_u16,
          session_id: TEST_SESSION
        )

        outcome.status.should eq(NocStatus::InvalidNoc)
      end

      it "refuses a NOC it cannot parse" do
        service = credential_service(RecordingCredentialTarget.new)
        commission(service)

        outcome = service.add_noc(
          noc: Bytes.new(100, 0_u8),
          icac: nil,
          ipk: Bytes.new(IPK_SIZE, 0_u8),
          case_admin_subject: 0x9999_u64,
          admin_vendor_id: 0xFFF1_u16,
          session_id: TEST_SESSION
        )

        outcome.status.should eq(NocStatus::InvalidNoc)
        outcome.debug_text.should_not be_nil
      end

      it "refuses to join the same fabric twice" do
        service = credential_service(RecordingCredentialTarget.new)
        public_key = commission(service)
        service.add_noc(
          noc: TestCertificateAuthority.default.issue(public_key: public_key),
          icac: nil,
          ipk: Bytes.new(IPK_SIZE, 0_u8),
          case_admin_subject: 0x9999_u64,
          admin_vendor_id: 0xFFF1_u16,
          session_id: TEST_SESSION
        ).ok?.should be_true

        # A second commissioning session, same fabric and root certificate
        service.commit_pending
        commission(service)
        outcome = service.add_noc(
          noc: CommissioningCertificates.noc,
          icac: nil,
          ipk: Bytes.new(IPK_SIZE, 0_u8),
          case_admin_subject: 0x9999_u64,
          admin_vendor_id: 0xFFF1_u16,
          session_id: TEST_SESSION
        )

        outcome.status.should eq(NocStatus::FabricConflict)
      end
    end

    describe "#update_noc" do
      it "accepts a replacement certificate issued to the update CSR key" do
        service, index = commissioned_service
        public_key = update_csr(service)
        replacement = TestCertificateAuthority.default.issue(public_key: public_key)

        outcome = service.update_noc(replacement, nil, index, TEST_SESSION)

        outcome.status.should eq(NocStatus::Ok)
        service.fabric_table.get_fabric(index).as(Fabric).operational_cert.should eq(replacement)
      end

      it "replaces the fabric CATs with those in the validated replacement NOC" do
        service, index = commissioned_service
        public_key = update_csr(service)
        authority = TestCertificateAuthority.default
        replacement = Matter::Crypto::MatterCertificate::Builder.node(
          public_key: public_key,
          fabric_id: TestCertificateAuthority::DEFAULT_FABRIC_ID,
          node_id: TestCertificateAuthority::DEFAULT_NODE_ID,
          issuer_key: authority.key,
          issuer_rcac_id: TestCertificateAuthority::ROOT_CERTIFICATE_ID,
          serial: Bytes[1, 2, 3, 4, 5, 6, 7, 8],
          crypto: Matter::Crypto::StandardCrypto.new,
          case_authenticated_tags: [0xFFFF_0002_u32, 0xFFFE_0002_u32]
        )

        service.update_noc(replacement, nil, index, TEST_SESSION).status.should eq(NocStatus::Ok)
        service.fabric_table.get_fabric(index).as(Fabric).cats.map(&.value)
          .should eq([0xFFFF_0002_u32, 0xFFFE_0002_u32])
      end

      it "refuses a replacement certificate issued by a different root" do
        service, index = commissioned_service
        public_key = update_csr(service)
        original = service.fabric_table.get_fabric(index).as(Fabric).operational_cert

        outcome = service.update_noc(TestCertificateAuthority.new.issue(public_key: public_key), nil, index, TEST_SESSION)

        outcome.status.should eq(NocStatus::InvalidNoc)
        service.fabric_table.get_fabric(index).as(Fabric).operational_cert.should eq(original)
      end

      it "refuses a replacement certificate with a key different from the update CSR" do
        service, index = commissioned_service
        update_csr(service)
        original = service.fabric_table.get_fabric(index).as(Fabric).operational_cert

        outcome = service.update_noc(CommissioningCertificates.noc, nil, index, TEST_SESSION)

        outcome.status.should eq(NocStatus::InvalidPublicKey)
        service.fabric_table.get_fabric(index).as(Fabric).operational_cert.should eq(original)
      end
    end

    describe "#remove_fabric" do
      it "leaves the fabric and drops what was scoped to it" do
        target = RecordingCredentialTarget.new
        service = credential_service(target)
        removed = [] of UInt8
        service.on_fabric_removed = ->(fabric_index : UInt8) { removed << fabric_index; nil }
        public_key = commission(service)
        added = service.add_noc(
          noc: TestCertificateAuthority.default.issue(public_key: public_key),
          icac: nil,
          ipk: Bytes.new(IPK_SIZE, 0_u8),
          case_admin_subject: 0x9999_u64,
          admin_vendor_id: 0xFFF1_u16,
          session_id: TEST_SESSION
        )
        fabric_index = added.fabric_index.as(UInt8)

        outcome = service.remove_fabric(fabric_index)

        outcome.ok?.should be_true
        service.fabric_table.size.should eq(0)
        removed.should eq([fabric_index])
        target.forgotten.should eq([fabric_index])
      end

      it "rejects the reserved fabric index" do
        service = credential_service(RecordingCredentialTarget.new)

        outcome = service.remove_fabric(DataType::NO_FABRIC)

        outcome.status.should eq(NocStatus::InvalidFabricIndex)
      end
    end

    describe "#public_key_from_certificate" do
      it "reads the public key of a Matter TLV certificate" do
        service = credential_service(RecordingCredentialTarget.new)

        key = service.public_key_from_certificate(CommissioningCertificates.root_certificate)

        key.should eq(CommissioningCertificates.root_public_key)
      end

      it "rejects a certificate in an unknown format" do
        service = credential_service(RecordingCredentialTarget.new)

        expect_raises(Matter::CertificateError, /Unknown certificate format/) do
          service.public_key_from_certificate(Bytes[0xFF, 0x01, 0x02])
        end
      end
    end

    describe "#reset_pending" do
      it "forgets the credentials of a failsafe that ended" do
        service = credential_service(RecordingCredentialTarget.new)
        commission(service)

        service.reset_pending

        service.pending.csr_exists?(TEST_SESSION).should be_false
        service.pending.root_cert_set?.should be_false
      end
    end
  end
end
