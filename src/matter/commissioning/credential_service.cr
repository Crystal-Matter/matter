require "log"
require "openssl"

require "../error"
require "../fabric"
require "../fabric_table"
require "../crypto/key"
require "../crypto/crypto"
require "../crypto/certificate"
require "../crypto/certificate_validation"
require "../certificate/attestation_certificate_manager"
require "../certificate/certification_declaration"
require "../interaction_model/status_code"
require "./credential_journal"
require "./fabric_removal_journal"

module Matter
  module Commissioning
    # NodeOperationalCertStatus: the result of every command that changes the
    # operational credentials (Matter Core §11.17.6.10)
    enum NocStatus : UInt8
      Ok                    =  0 # Operation successful
      InvalidPublicKey      =  1 # Public key in NOC doesn't match CSR
      InvalidNodeOpId       =  2 # Node Operational ID in NOC is invalid
      InvalidNoc            =  3 # NOC certificate validation failed
      MissingCsr            =  4 # CSR not found for this session
      TableFull             =  5 # Fabric table is at capacity
      InvalidAdminSubject   =  6 # CaseAdminSubject is invalid
      InsufficientPrivilege =  8 # Insufficient privilege
      FabricConflict        =  9 # Fabric with same ID already exists
      LabelConflict         = 10 # Label already in use by another fabric
      InvalidFabricIndex    = 11 # Specified fabric index doesn't exist
    end

    # AddTrustedRootCertificate reports Interaction Model status, unlike
    # AddNOC's NOCResponse. Keep its rejection reason typed until the cluster
    # maps it to the status mandated by Core §11.18.6.13.
    enum RootInstallFailure
      FailsafeRequired
      Constraint
      InvalidCertificate
    end

    # What a credential command decided; the cluster encodes it as an NOCResponse.
    struct NocOutcome
      getter status : NocStatus
      getter fabric_index : UInt8?
      getter debug_text : String?
      getter root_install_failure : RootInstallFailure?

      def initialize(@status : NocStatus, @fabric_index : UInt8? = nil, @debug_text : String? = nil,
                     @root_install_failure : RootInstallFailure? = nil)
      end

      def ok? : Bool
        @status.ok?
      end
    end

    # Credentials received while the failsafe is armed (CSR, root cert, NOC)
    # that are only committed once commissioning completes
    class PendingCredentials
      property csr_session_id : UInt64?
      property? is_for_update_noc : Bool
      property? root_cert_set : Bool
      property root_certificate : Bytes?
      property? noc_added_or_updated : Bool

      def initialize
        @csr_session_id = nil
        @is_for_update_noc = false
        @root_cert_set = false
        @root_certificate = nil
        @noc_added_or_updated = false
      end

      def reset
        @csr_session_id = nil
        @is_for_update_noc = false
        @root_cert_set = false
        @root_certificate = nil
        @noc_added_or_updated = false
      end

      def csr_exists?(session_id : UInt64) : Bool
        @csr_session_id == session_id
      end

      def set_csr(session_id : UInt64, is_for_update : Bool)
        @csr_session_id = session_id
        @is_for_update_noc = is_for_update
      end
    end

    # The state a credential change touches outside the fabric table,
    # implemented by `Cluster::OperationalCredentials`.
    module CredentialTarget
      # Bump the cluster data version after a credential change
      abstract def credentials_changed : Nil

      # A fabric was added: grant its administrator an ACL entry and record it
      # in the armed failsafe, before the application is notified
      abstract def fabric_committed(fabric : Fabric, case_admin_subject : UInt64) : Nil

      # A fabric was removed: drop the data scoped to it
      abstract def fabric_forgotten(fabric_index : UInt8) : Nil
    end

    # The Operational Credentials domain behind `Cluster::OperationalCredentials`:
    # device attestation, the CSR / root certificate / NOC flow of commissioning,
    # and fabric membership.
    #
    # Matter Core Spec §11.17 - Node Operational Credentials Cluster
    class CredentialService
      Log = ::Log.for("matter.commissioning.credential_service")

      enum CredentialMutation
        SetAttestationCredentials
        SetAttestationFromManager
        CreateCsr
        AddTrustedRootCertificate
        AddNoc
        UpdateNoc
        UpdateFabricLabel
        RemoveFabric
        ResetPending
        RollbackPending
        CommitPending
      end

      private struct NocUpdateSnapshot
        getter fabric_index : UInt8
        getter noc : Bytes
        getter icac : Bytes?
        getter key : Crypto::Key
        getter node_id : UInt64
        getter cats : Array(DataType::CaseAuthenticatedTag)

        def initialize(@fabric_index, @noc, @icac, @key, @node_id, @cats)
        end
      end

      # Uncompressed P-256 public key: 0x04 || x (32) || y (32)
      PUBLIC_KEY_SIZE          =         65
      PUBLIC_KEY_UNCOMPRESSED  =    0x04_u8
      CERTIFICATE_TLV_PREFIX   =    0x15_u8 # Matter TLV structure tag
      CERTIFICATE_DER_PREFIX   =    0x30_u8 # DER SEQUENCE tag
      CERTIFICATE_MIN_SIZE     =         50
      CERTIFICATE_MAX_SIZE     =       1024
      DER_MAX_LENGTH_BYTES     =          4
      DER_LONG_FORM_FLAG       =    0x80_u8
      DER_LENGTH_MASK          =    0x7F_u8
      ATTESTATION_TIMESTAMP    =      0_u32 # matter.js sends 0; the spec allows it
      DEFAULT_TEST_VENDOR_ID   = 0xFFF1_u16
      DEFAULT_TEST_PRODUCT_ID  = 0x8000_u16
      CERTIFICATE_LOG_PREFIX   =        100 # bytes of a certificate logged at trace
      CERTIFICATE_ERROR_PREFIX =        200 # bytes of a certificate logged on a parse failure
      ATTESTATION_LOG_PREFIX   =         32 # bytes of the signed payload logged at trace

      # TLV structure signed in an AttestationResponse
      struct AttestationElements
        include TLV::Serializable

        @[TLV::Field(tag: 1)]
        property certification_declaration : Bytes

        @[TLV::Field(tag: 2)]
        property attestation_nonce : Bytes

        @[TLV::Field(tag: 3, fixed_size: true)]
        property timestamp : UInt32

        def initialize(@certification_declaration : Bytes, @attestation_nonce : Bytes, @timestamp : UInt32)
        end
      end

      # TLV structure signed in a CSRResponse
      struct CSRElements
        include TLV::Serializable

        @[TLV::Field(tag: 1)]
        property csr : Bytes

        @[TLV::Field(tag: 2)]
        property csr_nonce : Bytes

        def initialize(@csr : Bytes, @csr_nonce : Bytes)
        end
      end

      getter fabric_table : FabricTable

      # Credentials received under the armed failsafe
      getter pending : PendingCredentials

      # Device attestation credentials
      getter dac : Bytes?
      getter pai : Bytes?

      # Whether the failsafe is armed; every credential change requires it
      property? failsafe_armed : Bool = true

      # Reads a session's attestation challenge, installed by the protocol layer
      property session_lookup : Proc(UInt64, Bytes?)?

      # A new fabric was added via AddNOC: the application persists it and
      # starts advertising operationally
      property on_fabric_added : Proc(Fabric, Nil)?

      # A fabric was removed via RemoveFabric
      property on_fabric_removed : Proc(UInt8, Nil)?

      # Persist fabric-scoped state that must be erased before its index can be
      # assigned to another fabric. Failure aborts removal while the index is
      # still reserved.
      property on_before_fabric_removed : Proc(UInt8, Nil)?

      # Restore live cluster objects if removal is aborted.
      property on_fabric_removal_rollback : Proc(UInt8, Nil)?
      property on_fabric_removal_quarantine : Proc(UInt8, Nil)?
      property on_fabric_removal_snapshot : Proc(Storage::Document)?
      property on_fabric_removal_app_snapshot_keys : Proc(Array(String))?

      # A fabric's operational identity changed via UpdateNOC or rollback.
      property on_fabric_updated : Proc(Fabric, Nil)?

      # Rejects public credential changes before pending state or an undo
      # journal is written. Startup and expiry rollback remain available.
      property on_before_credential_change : Proc(CredentialMutation, Nil)?

      # An application may impose additional AddNOC policy before the fabric
      # journal or table changes. A nil result accepts the ordinary NOC path.
      property on_validate_add_noc : Proc(Bytes, UInt64, UInt64, NocOutcome?)?

      # Device-installed protocol guards run independently of application policy.
      @add_noc_guards = [] of Proc(Bytes, UInt64, UInt64, NocOutcome?)

      def register_add_noc_guard(guard : Proc(Bytes, UInt64, UInt64, NocOutcome?)) : Nil
        @add_noc_guards << guard
      end

      # The device's reentrant protocol mutex, installed before transport starts.
      property protocol_lock : Mutex? = nil

      @attestation_key : Crypto::Key?
      @pending_noc_key : Crypto::Key?
      @pending_added_fabric_index : UInt8?
      @pending_noc_update : NocUpdateSnapshot?
      @attestation_cert_manager : Certificate::AttestationCertificateManager?

      def initialize(@target : CredentialTarget, @fabric_table : FabricTable)
        @pending = PendingCredentials.new
        # A generated key stands in until the device installs its own
        @attestation_key = Crypto::Key.generate_key_pair
        @vendor_id = DEFAULT_TEST_VENDOR_ID
        @product_id = DEFAULT_TEST_PRODUCT_ID
      end

      # ======================================================================
      # Attestation credentials
      # ======================================================================

      # Install factory attestation credentials
      def set_attestation_credentials(dac : Bytes, pai : Bytes, attestation_key : Crypto::Key) : Nil
        protocol_lock = @protocol_lock
        protocol_lock.try(&.lock)
        @on_before_credential_change.try(&.call(CredentialMutation::SetAttestationCredentials))
        @dac = dac
        @pai = pai
        @attestation_key = attestation_key
      ensure
        protocol_lock.try(&.unlock)
      end

      # Generate the DAC and PAI of a vendor / product from the certificate manager
      def set_attestation_from_manager(vendor_id : UInt16, product_id : UInt16) : Nil
        protocol_lock = @protocol_lock
        protocol_lock.try(&.lock)
        @on_before_credential_change.try(&.call(CredentialMutation::SetAttestationFromManager))
        @vendor_id = vendor_id
        @product_id = product_id

        cert_manager = @attestation_cert_manager || Certificate::AttestationCertificateManager.new(vendor_id, product_id)
        @attestation_cert_manager = cert_manager

        dac_cert, dac_key = cert_manager.get_dac_cert(product_id)

        @dac = dac_cert
        @pai = cert_manager.pai_cert
        @attestation_key = dac_key
        Log.debug { "set_attestation_from_manager: Set attestation_key to DAC key" }
        Log.debug { "  Public key (full #{PUBLIC_KEY_SIZE} bytes): #{dac_key.public_key.hexstring}" }
      ensure
        protocol_lock.try(&.unlock)
      end

      # ======================================================================
      # AttestationRequest (0x00)
      # ======================================================================

      # Build the attestation elements and the signature over them
      def attest(nonce : Bytes, session_id : UInt64?) : Tuple(Bytes, Bytes)
        elements = build_attestation_elements(nonce)
        {elements, sign_attestation(elements, session_id)}
      end

      # ======================================================================
      # CSRRequest (0x04)
      # ======================================================================

      # Generate a fresh operational key pair and the CSR that proves possession
      # of it, or nil when the failsafe rules forbid one.
      #
      # Returns the NOCSR elements and their attestation signature.
      def create_csr(
        nonce : Bytes,
        session_id : UInt64,
        is_for_update_noc : Bool,
        pase_session : Bool,
      ) : Tuple(Bytes, Bytes)?
        protocol_lock = @protocol_lock
        protocol_lock.try(&.lock)
        @on_before_credential_change.try(&.call(CredentialMutation::CreateCsr))
        return unless failsafe_armed?

        # An UpdateNOC needs the fabric of a CASE session to update
        return if is_for_update_noc && pase_session

        # The CSR of a failsafe that already added or updated a NOC is useless
        return if @pending.noc_added_or_updated?

        pending_noc_key = Crypto::Key.generate_key_pair
        @pending_noc_key = pending_noc_key

        elements = build_csr_elements(nonce, pending_noc_key)
        signature = sign_attestation(elements, session_id)

        @pending.set_csr(session_id, is_for_update_noc)

        {elements, signature}
      ensure
        protocol_lock.try(&.unlock)
      end

      # ======================================================================
      # AddTrustedRootCertificate (0x0B)
      # ======================================================================

      # Store the root certificate the NOC of this commissioning will chain to
      def add_trusted_root_certificate(root_certificate : Bytes) : NocOutcome
        protocol_lock = @protocol_lock
        protocol_lock.try(&.lock)
        @on_before_credential_change.try(&.call(CredentialMutation::AddTrustedRootCertificate))
        Log.debug { "Received AddTrustedRootCertificate: #{root_certificate.size} bytes" }
        Log.trace { "Root cert hex (first #{CERTIFICATE_LOG_PREFIX}): #{certificate_prefix(root_certificate, CERTIFICATE_LOG_PREFIX)}" }

        unless failsafe_armed?
          return NocOutcome.new(NocStatus::InvalidNoc, debug_text: "Failsafe not armed",
            root_install_failure: RootInstallFailure::FailsafeRequired)
        end

        # Reusing an installed root is idempotent and still chooses that root
        # for the next AddNOC, even when another installed root is last in the
        # attribute list (Core §11.18.6.13).
        if @fabric_table.all_fabrics.any? { |fabric| fabric.root_cert == root_certificate }
          @pending.root_cert_set = true
          @pending.root_certificate = root_certificate
          return NocOutcome.new(NocStatus::Ok)
        end

        if @pending.root_cert_set?
          return NocOutcome.new(NocStatus::InvalidNoc, debug_text: "Root certificate already set in this failsafe context",
            root_install_failure: RootInstallFailure::Constraint)
        end

        if @pending.noc_added_or_updated?
          return NocOutcome.new(NocStatus::InvalidNoc, debug_text: "Cannot set root certificate after AddNOC/UpdateNOC",
            root_install_failure: RootInstallFailure::Constraint)
        end

        unless valid_certificate_format?(root_certificate)
          return NocOutcome.new(NocStatus::InvalidNoc, debug_text: "Invalid root certificate format",
            root_install_failure: RootInstallFailure::InvalidCertificate)
        end

        begin
          Crypto::MatterCertificate::Validation.verify_root(root_certificate)
        rescue ex : Matter::AuthenticationError
          return NocOutcome.new(NocStatus::InvalidNoc, debug_text: "Invalid root certificate: #{ex.message}",
            root_install_failure: RootInstallFailure::InvalidCertificate)
        end

        @pending.root_cert_set = true
        @pending.root_certificate = root_certificate
        Log.info { "AddTrustedRootCertificate succeeded, root_cert_set=true" }
        @target.credentials_changed

        NocOutcome.new(NocStatus::Ok)
      ensure
        protocol_lock.try(&.unlock)
      end

      # ======================================================================
      # AddNOC (0x06)
      # ======================================================================

      # Join the fabric the NOC belongs to
      def add_noc(
        noc : Bytes,
        icac : Bytes?,
        ipk : Bytes,
        case_admin_subject : UInt64,
        admin_vendor_id : UInt16,
        session_id : UInt64,
      ) : NocOutcome
        protocol_lock = @protocol_lock
        protocol_lock.try(&.lock)
        @on_before_credential_change.try(&.call(CredentialMutation::AddNoc))
        unless failsafe_armed?
          return NocOutcome.new(NocStatus::InvalidNoc, debug_text: "Failsafe not armed")
        end

        if @pending.noc_added_or_updated?
          return NocOutcome.new(NocStatus::InvalidNoc, debug_text: "AddNOC/UpdateNOC already called in this failsafe")
        end

        unless @pending.csr_exists?(session_id)
          return NocOutcome.new(NocStatus::MissingCsr, debug_text: "CSR not found for this session")
        end

        unless @pending.root_cert_set?
          return NocOutcome.new(NocStatus::InvalidNoc, debug_text: "Root certificate not set")
        end

        if @fabric_table.full?
          return NocOutcome.new(NocStatus::TableFull, debug_text: "Fabric table is full")
        end

        unless DataType::NodeId.valid_case_subject?(case_admin_subject)
          return NocOutcome.new(NocStatus::InvalidAdminSubject, debug_text: "CaseAdminSubject is not a valid CASE ACL subject")
        end

        begin
          Log.debug { "Received NOC certificate: #{noc.size} bytes" }
          Log.trace { "NOC hex (first #{CERTIFICATE_LOG_PREFIX}): #{certificate_prefix(noc, CERTIFICATE_LOG_PREFIX)}" }
          fabric_id = fabric_id_from_noc(noc)
          node_id = node_id_from_noc(noc)
        rescue ex : Matter::CertificateError
          Log.error(exception: ex) do
            "Failed to parse NOC (#{noc.size} bytes): #{certificate_prefix(noc, CERTIFICATE_ERROR_PREFIX)}"
          end
          return NocOutcome.new(NocStatus::InvalidNoc, debug_text: "Failed to parse NOC: #{ex.message}")
        end

        # The compressed fabric ID is computed from the root public key, not
        # from the certificate it is carried in.
        root_cert = @pending.root_certificate || return NocOutcome.new(NocStatus::InvalidNoc, debug_text: "Root certificate not set")
        root_public_key = public_key_from_certificate(root_cert)
        Log.debug { "Extracted root public key: #{root_public_key.size} bytes, first byte: 0x#{root_public_key[0].to_s(16)}" }

        if @fabric_table.find_by_fabric_identity(fabric_id, root_public_key)
          return NocOutcome.new(NocStatus::FabricConflict, debug_text: "Fabric already exists")
        end

        Log.debug { "AddNOC: IPK received (#{ipk.size} bytes)" }
        Log.trace { "AddNOC: IPK hex: #{ipk.hexstring}" }
        Log.info { "AddNOC: fabric_id=0x#{fabric_id.to_s(16)}, node_id=0x#{node_id.to_s(16)}" }

        # Some controllers send an empty ICAC instead of omitting the field
        icac = nil if icac && icac.empty?
        if intermediate = icac
          Log.debug { "AddNOC: ICAC present (#{intermediate.size} bytes)" }
          Log.trace { "AddNOC: ICAC hex (first #{CERTIFICATE_LOG_PREFIX}): #{certificate_prefix(intermediate, CERTIFICATE_LOG_PREFIX)}" }
        else
          Log.warn { "AddNOC: NO ICAC provided - CASE may fail if controller expects 3-tier PKI" }
        end

        # The certificate has to have been issued by the root added in this
        # same failsafe. Without this the node id and CASE authenticated tags
        # it names are whatever the commissioner chose to write.
        begin
          Crypto::MatterCertificate::Validation.verify_chain(noc, icac, root_public_key, root_cert)
        rescue ex : Matter::AuthenticationError
          Log.error(exception: ex) { "AddNOC: NOC does not chain to the trusted root" }
          return NocOutcome.new(NocStatus::InvalidNoc, debug_text: "NOC is not issued by the trusted root: #{ex.message}")
        end

        unless Crypto::MatterCertificate.public_key_from_tlv(noc) == @pending_noc_key.as(Crypto::Key).public_key
          return NocOutcome.new(NocStatus::InvalidPublicKey, debug_text: "NOC public key does not match CSR")
        end

        @add_noc_guards.each do |guard|
          if rejected = guard.call(noc, case_admin_subject, session_id)
            return rejected
          end
        end

        if validator = @on_validate_add_noc
          if rejected = validator.call(noc, case_admin_subject, session_id)
            return rejected
          end
        end

        # Flush the undo record before FabricTable writes a provisional
        # identity. A process loss in either window leaves recoverable state.
        next_index = @fabric_table.next_available_index
        return NocOutcome.new(NocStatus::TableFull) unless next_index
        CredentialJournal.begin_add(@fabric_table.backend, next_index)
        @pending_added_fabric_index = next_index

        fabric = @fabric_table.add_fabric_auto_index(
          fabric_id: fabric_id,
          node_id: node_id,
          root_public_key: root_public_key,
          operational_cert: noc,
          operational_key: @pending_noc_key.as(Crypto::Key),
          ipk: ipk,
          vendor_id: admin_vendor_id,
          label: "",
          intermediate_cert: icac,
          root_cert: root_cert,
          fabric_index: next_index
        )

        unless fabric
          CredentialJournal.clear(@fabric_table.backend)
          @pending_added_fabric_index = nil
          return NocOutcome.new(NocStatus::TableFull, debug_text: "Failed to add fabric")
        end

        @pending.noc_added_or_updated = true
        @pending_added_fabric_index = fabric.fabric_index

        # The administrator gets its ACL entry and the failsafe learns the
        # fabric, so CommissioningComplete may arrive on the new CASE session.
        @target.fabric_committed(fabric, case_admin_subject)

        if callback = @on_fabric_added
          begin
            callback.call(fabric)
            Log.debug { "AddNOC: on_fabric_added callback completed successfully" }
          rescue ex
            Log.error(exception: ex) { "AddNOC: on_fabric_added callback raised (fabric_index=#{fabric.fabric_index} fabric_id=0x#{fabric.fabric_id.to_s(16)} node_id=0x#{fabric.node_id.to_s(16)})" }
          end
        end

        NocOutcome.new(NocStatus::Ok, fabric.fabric_index)
      ensure
        protocol_lock.try(&.unlock)
      end

      # ======================================================================
      # UpdateNOC (0x07)
      # ======================================================================

      # Replace the operational certificate and key of the accessing fabric
      def update_noc(
        noc : Bytes,
        icac : Bytes?,
        session_fabric_index : UInt8,
        session_id : UInt64,
      ) : NocOutcome
        protocol_lock = @protocol_lock
        protocol_lock.try(&.lock)
        @on_before_credential_change.try(&.call(CredentialMutation::UpdateNoc))
        unless failsafe_armed?
          return NocOutcome.new(NocStatus::InvalidNoc, debug_text: "Failsafe not armed")
        end

        if @pending.noc_added_or_updated?
          return NocOutcome.new(NocStatus::InvalidNoc, debug_text: "AddNOC/UpdateNOC already called in this failsafe")
        end

        unless @pending.csr_exists?(session_id) && @pending.is_for_update_noc?
          return NocOutcome.new(NocStatus::MissingCsr, debug_text: "CSR for update not found")
        end

        if @pending.root_cert_set?
          return NocOutcome.new(NocStatus::InvalidNoc, debug_text: "Cannot set root certificate for NOC update")
        end

        fabric = @fabric_table.get_fabric(session_fabric_index)
        unless fabric
          return NocOutcome.new(NocStatus::InvalidFabricIndex, debug_text: "Session fabric not found")
        end

        begin
          if fabric_id_from_noc(noc) != fabric.fabric_id
            return NocOutcome.new(NocStatus::InvalidNoc, debug_text: "Fabric ID mismatch")
          end

          node_id = node_id_from_noc(noc)
        rescue ex : Matter::CertificateError
          Log.error(exception: ex) do
            "Failed to parse NOC (#{noc.size} bytes): #{certificate_prefix(noc, CERTIFICATE_ERROR_PREFIX)}"
          end
          return NocOutcome.new(NocStatus::InvalidNoc, debug_text: "Failed to parse NOC: #{ex.message}")
        end

        begin
          Crypto::MatterCertificate::Validation.verify_chain(noc, icac, fabric.root_public_key, fabric.root_cert)
        rescue ex : Matter::AuthenticationError
          return NocOutcome.new(NocStatus::InvalidNoc, debug_text: "NOC is not issued by the fabric root: #{ex.message}")
        end

        unless Crypto::MatterCertificate.public_key_from_tlv(noc) == @pending_noc_key.as(Crypto::Key).public_key
          return NocOutcome.new(NocStatus::InvalidPublicKey, debug_text: "NOC public key does not match CSR")
        end

        snapshot = NocUpdateSnapshot.new(
          fabric.fabric_index, fabric.operational_cert, fabric.intermediate_cert,
          fabric.operational_key, fabric.node_id, fabric.cats.dup)

        CredentialJournal.begin_update(@fabric_table.backend, fabric)
        @pending_noc_update = snapshot

        fabric.operational_cert = noc
        fabric.intermediate_cert = icac
        fabric.operational_key = @pending_noc_key.as(Crypto::Key)
        fabric.node_id = node_id
        fabric.cats = Crypto::MatterCertificate.subject_ids_from_tlv(noc).compact_map do |subject_id|
          cat_node = DataType::NodeId.new(subject_id)
          cat_node.extract_as_case_authenticated_tag if cat_node.case_authenticated_tag?
        end

        begin
          @fabric_table.update_fabric(fabric)
        rescue ex
          restore_noc_update(fabric, snapshot)
          raise ex
        end

        @pending.noc_added_or_updated = true
        @target.credentials_changed
        notify_fabric_updated(fabric)

        NocOutcome.new(NocStatus::Ok, fabric.fabric_index)
      ensure
        protocol_lock.try(&.unlock)
      end

      # ======================================================================
      # UpdateFabricLabel (0x09)
      # ======================================================================

      # Name the accessing fabric, which must be unique across the device
      def update_fabric_label(label : String, fabric_index : UInt8?) : NocOutcome
        protocol_lock = @protocol_lock
        protocol_lock.try(&.lock)
        @on_before_credential_change.try(&.call(CredentialMutation::UpdateFabricLabel))
        unless fabric_index
          return NocOutcome.new(NocStatus::InvalidFabricIndex, debug_text: "Invalid fabric index")
        end

        fabric = @fabric_table.get_fabric(fabric_index)
        unless fabric
          return NocOutcome.new(NocStatus::InvalidFabricIndex, debug_text: "Fabric not found")
        end

        conflict = @fabric_table.all_fabrics.any? do |existing|
          existing.fabric_index != fabric_index && existing.label == label
        end
        if conflict
          return NocOutcome.new(NocStatus::LabelConflict, debug_text: "Label already in use")
        end

        fabric.label = label
        @fabric_table.update_fabric(fabric)
        @target.credentials_changed

        NocOutcome.new(NocStatus::Ok, fabric.fabric_index)
      ensure
        protocol_lock.try(&.unlock)
      end

      # ======================================================================
      # RemoveFabric (0x0A)
      # ======================================================================

      # Leave a fabric, dropping every piece of data scoped to it
      def remove_fabric(fabric_index : UInt8) : NocOutcome
        protocol_lock = @protocol_lock
        protocol_lock.try(&.lock)
        @on_before_credential_change.try(&.call(CredentialMutation::RemoveFabric))
        Log.debug { "RemoveFabric: fabric_index=#{fabric_index}" }

        if fabric_index == DataType::NO_FABRIC
          Log.warn { "RemoveFabric: fabric_index 0 (NO_FABRIC) is invalid" }
          return NocOutcome.new(NocStatus::InvalidFabricIndex, fabric_index, "Invalid fabric index (NO_FABRIC)")
        end

        unless @fabric_table.get_fabric(fabric_index)
          # Some commissioners (notably iOS) clean up a previously commissioned
          # state by removing a fabric while re-commissioning. With no fabrics
          # to remove this is idempotent, so let the commissioner move on.
          if @fabric_table.empty?
            Log.info { "RemoveFabric: fabric #{fabric_index} not found but device has no fabrics; treating as success" }
            return NocOutcome.new(NocStatus::Ok, fabric_index)
          end

          Log.warn { "RemoveFabric: fabric #{fabric_index} not found" }
          return NocOutcome.new(NocStatus::InvalidFabricIndex, fabric_index, "Fabric not found")
        end

        begin
          FabricRemovalJournal.start(@fabric_table.backend, fabric_index,
            @on_fabric_removal_snapshot.try(&.call),
            @on_fabric_removal_app_snapshot_keys.try(&.call) || [] of String)
        rescue ex
          @fabric_table.quarantine(fabric_index)
          @on_fabric_removal_quarantine.try(&.call(fabric_index))
          raise ex
        end
        begin
          @on_before_fabric_removed.try(&.call(fabric_index))
        rescue ex
          begin
            FabricRemovalJournal.restore_documents(@fabric_table.backend)
            @on_fabric_removal_rollback.try(&.call(fabric_index))
            FabricRemovalJournal.clear(@fabric_table.backend)
          rescue error
            @fabric_table.quarantine(fabric_index)
            @on_fabric_removal_quarantine.try(&.call(fabric_index))
            Log.error(exception: error) { "Could not roll back fabric removal #{fabric_index}" }
          end
          raise ex
        end

        begin
          unless @fabric_table.remove_fabric(fabric_index)
            raise StorageError.new("Fabric #{fabric_index} disappeared during removal")
          end
        rescue ex
          # A file backend can change its in-memory tree before a failed
          # flush. Do not trust this process to decide whether deletion stuck.
          @fabric_table.quarantine(fabric_index)
          @on_fabric_removal_quarantine.try(&.call(fabric_index))
          @on_fabric_removal_rollback.try(&.call(fabric_index))
          raise ex
        end

        begin
          FabricRemovalJournal.clear(@fabric_table.backend)
        rescue ex
          @fabric_table.quarantine(fabric_index)
          @on_fabric_removal_quarantine.try(&.call(fabric_index))
          raise ex
        end

        # Every fabric-scoped datum goes with the fabric (ACL entries, bindings)
        @target.fabric_forgotten(fabric_index)

        if callback = @on_fabric_removed
          begin
            callback.call(fabric_index)
            Log.debug { "RemoveFabric: on_fabric_removed callback completed successfully" }
          rescue ex
            Log.error(exception: ex) { "RemoveFabric: on_fabric_removed callback raised (fabric_index=#{fabric_index})" }
          end
        end

        @target.credentials_changed

        NocOutcome.new(NocStatus::Ok, fabric_index)
      ensure
        protocol_lock.try(&.unlock)
      end

      # ======================================================================
      # Failsafe transitions
      # ======================================================================

      # A new failsafe was armed, the previous one expired, or commissioning
      # completed: either way nothing stays pending.
      def reset_pending : Nil
        protocol_lock = @protocol_lock
        protocol_lock.try(&.lock)
        @on_before_credential_change.try(&.call(CredentialMutation::ResetPending))
        pending_root = @pending.root_certificate
        root_will_disappear = pending_root && @fabric_table.all_fabrics.none? { |fabric| fabric.root_cert == pending_root }
        @pending.reset
        @pending_noc_key = nil
        @pending_added_fabric_index = nil
        @pending_noc_update = nil
        @target.credentials_changed if root_will_disappear
      ensure
        protocol_lock.try(&.unlock)
      end

      # Undo the NOC change made under an expired fail-safe. The table write
      # persists the restored CASE identity before the next session arrives.
      def rollback_pending : Nil
        protocol_lock = @protocol_lock
        protocol_lock.try(&.lock)
        @on_before_credential_change.try(&.call(CredentialMutation::RollbackPending))
        if index = @pending_added_fabric_index
          if @fabric_table.get_fabric(index)
            remove_fabric(index)
          else
            # A fabric write can fail after the journal has reached disk but
            # before FabricTable accepted the new in-memory entry.
            @fabric_table.backend.delete(FabricTable::COLLECTION, index.to_s)
            @target.fabric_forgotten(index)
          end
        elsif snapshot = @pending_noc_update
          if fabric = @fabric_table.get_fabric(snapshot.fabric_index)
            restore_noc_update(fabric, snapshot)
            @fabric_table.update_fabric(fabric)
            @target.credentials_changed
            notify_fabric_updated(fabric)
          end
        end
        CredentialJournal.clear(@fabric_table.backend)
        reset_pending
      ensure
        protocol_lock.try(&.unlock)
      end

      private def restore_noc_update(fabric : Fabric, snapshot : NocUpdateSnapshot) : Nil
        fabric.operational_cert = snapshot.noc
        fabric.intermediate_cert = snapshot.icac
        fabric.operational_key = snapshot.key
        fabric.node_id = snapshot.node_id
        fabric.cats = snapshot.cats
      end

      # CommissioningComplete is acknowledged only after the durable undo
      # record is removed. A crash before this point rolls back on restart;
      # a crash after it preserves the committed identity.
      def commit_pending(journal_cleared : Bool = false) : Nil
        protocol_lock = @protocol_lock
        protocol_lock.try(&.lock)
        @on_before_credential_change.try(&.call(CredentialMutation::CommitPending))
        CredentialJournal.clear(@fabric_table.backend) unless journal_cleared
        reset_pending
      ensure
        protocol_lock.try(&.unlock)
      end

      private def notify_fabric_updated(fabric : Fabric) : Nil
        @on_fabric_updated.try(&.call(fabric))
      rescue ex
        Log.error(exception: ex) { "Failed to publish updated fabric #{fabric.fabric_index}" }
      end

      # ======================================================================
      # Certificates
      # ======================================================================

      # Fabric ID of a Matter TLV NOC
      def fabric_id_from_noc(noc : Bytes) : UInt64
        certificate_id(noc, "fabricId", &.fabric_id)
      end

      # Node ID of a Matter TLV NOC
      def node_id_from_noc(noc : Bytes) : UInt64
        certificate_id(noc, "nodeId", &.node_id)
      end

      private def certificate_id(noc : Bytes, name : String, & : Crypto::MatterCertificate -> UInt64?) : UInt64
        cert = Crypto::MatterCertificate.from_slice(noc)
        Log.debug { "Parsed NOC certificate: fabric_id=#{cert.fabric_id}, node_id=#{cert.node_id}" }

        value = yield cert
        unless value
          raise Matter::CertificateError.new("#{name} not found in NOC certificate subject")
        end
        value
      rescue ex
        raise Matter::CertificateError.new("Failed to parse NOC certificate: #{ex.message}", cause: ex)
      end

      # Public key of a certificate in either Matter TLV or X.509 DER form,
      # uncompressed (0x04 || x || y)
      def public_key_from_certificate(certificate : Bytes) : Bytes
        case certificate[0]
        when CERTIFICATE_TLV_PREFIX
          validate_public_key(Crypto::MatterCertificate.public_key_from_tlv(certificate))
        when CERTIFICATE_DER_PREFIX
          public_key_from_der(certificate)
        else
          raise Matter::CertificateError.new("Unknown certificate format: first byte 0x#{certificate[0].to_s(16)}")
        end
      end

      private def public_key_from_der(certificate : Bytes) : Bytes
        x509 = OpenSSL::X509::Certificate.from_der(certificate)
        pkey = x509.public_key

        unless pkey.is_a?(OpenSSL::PKey::EC)
          raise Matter::CertificateError.new("Certificate does not contain an EC public key")
        end

        validate_public_key(pkey.public_key_bytes)
      rescue ex
        Log.error(exception: ex) { "Failed to extract public key from DER certificate (cert_hex=#{certificate.hexstring})" }
        raise Matter::CertificateError.new("Failed to extract public key from DER certificate: #{ex.message}", cause: ex)
      end

      private def validate_public_key(public_key : Bytes) : Bytes
        if public_key.size != PUBLIC_KEY_SIZE
          raise Matter::CertificateError.new("Invalid public key size: expected #{PUBLIC_KEY_SIZE} bytes, got #{public_key.size}")
        end

        if public_key[0] != PUBLIC_KEY_UNCOMPRESSED
          raise Matter::CertificateError.new("Invalid public key format: expected uncompressed point (0x#{PUBLIC_KEY_UNCOMPRESSED.to_s(16)}), got 0x#{public_key[0].to_s(16)}")
        end

        public_key
      end

      # Whether a certificate is plausibly a Matter TLV or X.509 DER certificate
      def valid_certificate_format?(certificate : Bytes) : Bool
        return false if certificate.empty?

        # Matter certificates are on the order of a few hundred bytes
        return false if certificate.size < CERTIFICATE_MIN_SIZE || certificate.size > CERTIFICATE_MAX_SIZE

        case certificate[0]
        when CERTIFICATE_DER_PREFIX
          return false if certificate.size < 2

          length_byte = certificate[1]
          if length_byte >= DER_LONG_FORM_FLAG
            length_bytes = length_byte & DER_LENGTH_MASK
            return false if length_bytes > DER_MAX_LENGTH_BYTES
            return false if certificate.size < 2 + length_bytes
          end
          true
        when CERTIFICATE_TLV_PREFIX
          # Enough for a tag and some content; the full parse happens on use
          certificate.size >= 2
        else
          false
        end
      end

      # ======================================================================
      # Signing
      # ======================================================================

      private def build_attestation_elements(nonce : Bytes) : Bytes
        declaration = Certificate::CertificationDeclaration.generate(@vendor_id, @product_id)

        AttestationElements.new(
          certification_declaration: declaration,
          attestation_nonce: nonce,
          timestamp: ATTESTATION_TIMESTAMP
        ).to_slice
      end

      private def build_csr_elements(nonce : Bytes, key : Crypto::Key) : Bytes
        csr = build_csr_der(key)

        Log.debug { "CSR generated: bytes=#{csr.size} csr_nonce_bytes=#{nonce.size}" }
        Log.trace { "CSR hex: #{csr.hexstring}" }
        Log.trace { "CSR public key (#{PUBLIC_KEY_SIZE} bytes): #{key.public_key.hexstring}" }

        CSRElements.new(csr: csr, csr_nonce: nonce).to_slice
      end

      # Sign with the attestation key over (data || attestation challenge), as
      # the spec requires, in IEEE P1363 (r||s) form
      private def sign_attestation(data : Bytes, session_id : UInt64? = nil) : Bytes
        unless key = @attestation_key
          raise Matter::ClusterError.new("Attestation key not configured")
        end

        Log.debug { "Signing attestation: session_id=#{session_id || "none"} key_type=#{key.type}" }
        Log.trace { "Attestation public key (#{PUBLIC_KEY_SIZE} bytes): #{key.public_key.hexstring}" }

        attestation_challenge = if session_id && (lookup = @session_lookup)
                                  lookup.call(session_id)
                                end

        data_to_sign = if challenge = attestation_challenge
                         Log.trace { "Attestation challenge: #{challenge.hexstring}" }
                         io = IO::Memory.new
                         io.write(data)
                         io.write(challenge)
                         io.to_slice
                       else
                         Log.trace { "Attestation challenge: nil" }
                         data
                       end

        Log.debug { "Attestation data_to_sign: #{data_to_sign.size} bytes" }
        Log.trace { "Attestation data_to_sign first#{ATTESTATION_LOG_PREFIX}: #{data_to_sign[0, [ATTESTATION_LOG_PREFIX, data_to_sign.size].min].hexstring}" }
        if data_to_sign.size > ATTESTATION_LOG_PREFIX
          Log.trace { "Attestation data_to_sign last#{ATTESTATION_LOG_PREFIX}: #{data_to_sign[-ATTESTATION_LOG_PREFIX, ATTESTATION_LOG_PREFIX].hexstring}" }
        end

        signature = Crypto.sign_ecdsa(key, data_to_sign, "ieee-p1363")
        Log.debug { "Attestation signature generated: #{signature.size} bytes" }
        Log.trace { "Attestation signature hex: #{signature.hexstring}" }
        signature
      end

      # ======================================================================
      # CSR (PKCS#10 / RFC 2986)
      # ======================================================================

      # DER prelude of a CertificationRequestInfo: INTEGER 0 (version)
      CSR_VERSION = Bytes[0x02, 0x01, 0x00]

      # Subject, in the shape matter.js emits:
      # SEQUENCE { SET { SEQUENCE { OID(organizationName), UTF8String("CSR") } } }
      CSR_SUBJECT = Bytes[0x30, 0x0e, 0x31, 0x0c, 0x30, 0x0a, 0x06, 0x03, 0x55, 0x04, 0x0a, 0x0c, 0x03, 0x43, 0x53, 0x52]

      # Context tag [0] for the (empty) attribute set
      CSR_ATTRIBUTES = Bytes[0xa0, 0x00]

      # SEQUENCE { OID ecdsa-with-SHA256 }
      CSR_SIGNATURE_ALGORITHM = Bytes[0x30, 0x0a, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02]

      DER_SEQUENCE   = 0x30_u8
      DER_BIT_STRING = 0x03_u8
      DER_NO_PADDING = 0x00_u8

      private def build_csr_der(key : Crypto::Key) : Bytes
        csr_info_io = IO::Memory.new
        csr_info_io.write CSR_VERSION
        csr_info_io.write CSR_SUBJECT
        csr_info_io.write Crypto::StandardCrypto.new.build_ec_public_key_der(key.public_key)
        csr_info_io.write CSR_ATTRIBUTES

        # PKCS#10 requires the CertificationRequestInfo to be a SEQUENCE, and
        # the signature proves possession of the key it carries.
        csr_info = der_sequence(csr_info_io.to_slice)
        signature = Crypto.sign_ecdsa(key, csr_info, "der")

        csr_io = IO::Memory.new
        csr_io.write csr_info
        csr_io.write CSR_SIGNATURE_ALGORITHM
        csr_io.write_byte DER_BIT_STRING
        write_der_length(csr_io, signature.size + 1)
        csr_io.write_byte DER_NO_PADDING
        csr_io.write signature

        der_sequence(csr_io.to_slice)
      end

      private def der_sequence(content : Bytes) : Bytes
        io = IO::Memory.new
        io.write_byte DER_SEQUENCE
        write_der_length(io, content.size)
        io.write content
        io.to_slice
      end

      private def write_der_length(io : IO, length : Int) : Nil
        if length < DER_LONG_FORM_FLAG
          io.write_byte length.to_u8
          return
        end

        bytes = [] of UInt8
        remaining = length
        while remaining > 0
          bytes.unshift(remaining.to_u8)
          remaining >>= 8
        end
        io.write_byte (DER_LONG_FORM_FLAG | bytes.size).to_u8
        bytes.each { |byte| io.write_byte byte }
      end

      private def certificate_prefix(certificate : Bytes, size : Int32) : String
        certificate[0, [size, certificate.size].min].hexstring
      end
    end
  end
end
