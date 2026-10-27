require "./cluster"
require "./operational_credentials/types"
require "../commissioning"
require "../fabric"
require "../fabric_table"
require "../crypto/key"
require "../datatype/vendor_id"

module Matter
  module Cluster
    # Operational Credentials Cluster (0x003E)
    #
    # Functionality to manage operational certificates and fabric membership.
    # This cluster is required for Matter commissioning and fabric management.
    #
    # The domain behind it - attestation, the CSR / root certificate / NOC flow
    # and fabric membership - is `Commissioning::CredentialService`; this
    # cluster is its wire front.
    #
    # Matter Specification: Core 1.4 § 11.17 - Operational Credentials Cluster
    #
    # Commands:
    # - AttestationRequest (0x00): Request device attestation
    # - CertificateChainRequest (0x02): Request DAC/PAI certificate
    # - CSRRequest (0x04): Request Certificate Signing Request for NOC
    # - AddNOC (0x06): Add a Node Operational Certificate
    # - UpdateNOC (0x07): Update existing NOC
    # - UpdateFabricLabel (0x09): Update fabric label
    # - RemoveFabric (0x0A): Remove a fabric
    # - AddTrustedRootCertificate (0x0B): Add trusted root CA cert
    #
    # Attributes:
    # - NOCs (0x00): List of NOC certificates
    # - Fabrics (0x01): List of fabric descriptors
    # - SupportedFabrics (0x02): Maximum supported fabrics
    # - CommissionedFabrics (0x03): Current number of fabrics
    # - TrustedRootCertificates (0x04): List of trusted root certs
    # - CurrentFabricIndex (0x05): Fabric index of current session
    class OperationalCredentials < Base
      include Commissioning::CredentialTarget

      Log = ::Log.for("matter.cluster.operational_credentials")

      cluster 0x003E, revision: 2

      # Certificate Chain Type
      enum CertificateChainType : UInt8
        DACCertificate = 1 # Device Attestation Certificate
        PAICertificate = 2 # Product Attestation Intermediate Certificate
      end

      # Status codes and the pending-credential state, owned by the service
      alias NodeOperationalCertStatus = Commissioning::NocStatus
      alias PendingCredentials = Commissioning::PendingCredentials
      alias AttestationElements = Commissioning::CredentialService::AttestationElements
      alias CSRElements = Commissioning::CredentialService::CSRElements

      # NOCs, Fabrics, SupportedFabrics, CommissionedFabrics and
      # CurrentFabricIndex are computed from the fabric table and the session.
      attribute 0x0000, :nocs, Array(Tlv::NOC), computed: true, read_access: :administer, fabric_scoped: true
      attribute 0x0001, :fabrics, Array(Tlv::FabricDescriptor), computed: true, fabric_scoped: true
      attribute 0x0002, :supported_fabrics, UInt8, computed: true, fixed: true
      attribute 0x0003, :commissioned_fabrics, UInt8, computed: true
      attribute 0x0004, :trusted_root_certificates, Array(Bytes), default: [] of Bytes
      attribute 0x0005, :current_fabric_index, UInt8, computed: true

      command 0x00, :attestation_request, request: Tlv::AttestationRequest, response: Tlv::AttestationResponse, response_id: 0x01, access: :administer
      command 0x02, :certificate_chain_request, request: Tlv::CertificateChainRequest, response: Tlv::CertificateChainResponse, response_id: 0x03, access: :administer
      command 0x04, :csr_request, request: Tlv::CsrRequest, response: Tlv::CsrResponse, response_id: 0x05, access: :administer
      command 0x06, :add_noc, request: Tlv::AddNocRequest, response: Tlv::TlvNocResponse, response_id: 0x08, access: :administer
      command 0x07, :update_noc, request: Tlv::UpdateNocRequest, response: Tlv::TlvNocResponse, response_id: 0x08, access: :administer
      command 0x09, :update_fabric_label, request: Tlv::UpdateFabricLabelRequest, response: Tlv::TlvNocResponse, response_id: 0x08, access: :administer
      command 0x0A, :remove_fabric, request: Tlv::RemoveFabricRequest, response: Tlv::TlvNocResponse, response_id: 0x08, access: :administer
      command 0x0B, :add_trusted_root_certificate, request: Tlv::AddTrustedRootCertificateRequest, access: :administer
      command 0x0C, :set_vid_verification_statement, request: Tlv::SetVIDVerificationStatementRequest, access: :administer
      command 0x0D, :sign_vid_verification_request, request: Tlv::SignVIDVerificationRequest, response: Tlv::SignVIDVerificationResponse, response_id: 0x0E, access: :administer

      struct NOCStruct
        property noc : Bytes          # Node Operational Certificate (DER encoded)
        property icac : Bytes?        # Intermediate CA Certificate (DER encoded, optional)
        property fabric_index : UInt8 # Index of the fabric

        def initialize(@noc : Bytes, @icac : Bytes?, @fabric_index : UInt8)
        end
      end

      # Fabric Descriptor Struct
      struct FabricDescriptorStruct
        property root_public_key : Bytes # Root public key (65 bytes - uncompressed P-256)
        property vendor_id : UInt16      # Vendor ID
        property fabric_id : UInt64      # Fabric ID
        property node_id : UInt64        # Node ID
        property label : String          # Fabric label
        property fabric_index : UInt8    # Index of the fabric

        def initialize(@root_public_key : Bytes, @vendor_id : UInt16,
                       @fabric_id : UInt64, @node_id : UInt64,
                       @label : String, @fabric_index : UInt8)
        end
      end

      # AttestationRequest command (0x00)
      struct AttestationRequestCommand
        property attestation_nonce : Bytes # Must be exactly 32 bytes

        def initialize(@attestation_nonce : Bytes)
          raise ArgumentError.new("attestation_nonce must be 32 bytes") if @attestation_nonce.size != 32
        end
      end

      # AttestationResponse
      struct AttestationResponse
        property attestation_elements : Bytes
        property attestation_signature : Bytes

        def initialize(@attestation_elements : Bytes, @attestation_signature : Bytes)
        end
      end

      # CertificateChainRequest command (0x02)
      struct CertificateChainRequestCommand
        property certificate_type : CertificateChainType

        def initialize(@certificate_type : CertificateChainType)
        end
      end

      # CertificateChainResponse
      struct CertificateChainResponse
        property certificate : Bytes # Max 600 bytes

        def initialize(@certificate : Bytes)
        end
      end

      # CSRRequest command (0x04)
      struct CSRRequestCommand
        property csr_nonce : Bytes         # Must be exactly 32 bytes
        property is_for_update_noc : Bool? # Optional, default false

        def initialize(@csr_nonce : Bytes, @is_for_update_noc : Bool? = false)
          raise ArgumentError.new("csr_nonce must be 32 bytes") if @csr_nonce.size != 32
        end
      end

      # CSRResponse
      struct CSRResponse
        property nocsr_elements : Bytes
        property attestation_signature : Bytes

        def initialize(@nocsr_elements : Bytes, @attestation_signature : Bytes)
        end
      end

      # AddTrustedRootCertificate command (0x0B)
      struct AddTrustedRootCertificateCommand
        property root_ca_certificate : Bytes # Max 400 bytes DER-encoded

        def initialize(@root_ca_certificate : Bytes)
        end
      end

      # AddNOC command (0x06)
      struct AddNOCCommand
        property noc_value : Bytes           # Max 400 bytes
        property icac_value : Bytes?         # Optional, max 400 bytes
        property ipk_value : Bytes           # Must be 16 bytes (IPK)
        property case_admin_subject : UInt64 # Node ID of admin
        property admin_vendor_id : UInt16    # Vendor ID of admin

        def initialize(
          @noc_value : Bytes,
          @icac_value : Bytes?,
          @ipk_value : Bytes,
          @case_admin_subject : UInt64,
          @admin_vendor_id : UInt16,
        )
          raise ArgumentError.new("ipk_value must be 16 bytes") if @ipk_value.size != 16
        end
      end

      # UpdateNOC command (0x07)
      struct UpdateNOCCommand
        property noc_value : Bytes   # Max 400 bytes
        property icac_value : Bytes? # Optional, max 400 bytes

        def initialize(@noc_value : Bytes, @icac_value : Bytes?)
        end
      end

      # UpdateFabricLabel command (0x09)
      struct UpdateFabricLabelCommand
        property label : String # Max 32 characters

        def initialize(@label : String)
          raise ArgumentError.new("label must be <= 32 characters") if @label.size > 32
        end
      end

      # RemoveFabric command (0x0A)
      struct RemoveFabricCommand
        property fabric_index : UInt8

        def initialize(@fabric_index : UInt8)
        end
      end

      # NOCResponse - Generic response for AddNOC, UpdateNOC, UpdateFabricLabel, RemoveFabric
      struct NOCResponse
        property status_code : NodeOperationalCertStatus
        property fabric_index : UInt8? # Present on success
        property debug_text : String?  # Optional debug info

        def initialize(
          @status_code : NodeOperationalCertStatus,
          @fabric_index : UInt8? = nil,
          @debug_text : String? = nil,
        )
        end

        def success?
          @status_code == NodeOperationalCertStatus::Ok
        end
      end

      # ========================================================================
      # State
      # ========================================================================

      # Clusters this one has to reach for a fabric change; both hold state that
      # is scoped to the fabric being added or removed.
      @access_control_cluster : AccessControl?
      property general_commissioning_cluster : GeneralCommissioning?

      # The credential domain behind the eight commands. Built on first use: the
      # service publishes back onto this cluster, and an object cannot hand
      # itself out of its own constructor.
      @credentials : Commissioning::CredentialService? = nil
      @vid_failsafe_snapshot = Hash(UInt8, Tuple(UInt16, Bytes?, Bytes?)).new

      def credentials : Commissioning::CredentialService
        @credentials ||= Commissioning::CredentialService.new(self, @fabric_table)
      end

      delegate fabric_table, failsafe_armed?, :failsafe_armed=,
        session_lookup, :session_lookup=,
        on_fabric_added, :on_fabric_added=,
        on_fabric_removed, :on_fabric_removed=,
        on_before_fabric_removed, :on_before_fabric_removed=,
        on_fabric_removal_rollback, :on_fabric_removal_rollback=,
        on_fabric_removal_quarantine, :on_fabric_removal_quarantine=,
        on_fabric_removal_snapshot, :on_fabric_removal_snapshot=,
        on_fabric_removal_app_snapshot_keys, :on_fabric_removal_app_snapshot_keys=,
        on_fabric_updated, :on_fabric_updated=,
        set_attestation_credentials, set_attestation_from_manager,
        restore_root_cert,
        to: credentials

      def initialize(
        @fabric_table : FabricTable,
        endpoint_id : DataType::EndpointNumber = DataType::EndpointNumber::ROOT,
        @access_control_cluster : AccessControl? = nil,
        @general_commissioning_cluster : GeneralCommissioning? = nil,
      )
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
      end

      # Overload for tests that pass fabric_table and acl_cluster directly
      def initialize(
        fabric_table : FabricTable,
        access_control_cluster : AccessControl,
      )
        initialize(
          fabric_table,
          DataType::EndpointNumber::ROOT,
          access_control_cluster
        )
      end

      # ========================================================================
      # Attributes
      # ========================================================================

      # NOCs attribute (0x00): the operational certificates of every fabric
      def nocs : Array(Tlv::NOC)
        visible_fabrics.map do |fabric|
          Tlv::NOC.new(noc: fabric.operational_cert, icac: fabric.intermediate_cert,
            fabric_index: fabric.fabric_index, vvsc: fabric.vvsc)
        end
      end

      # Fabrics attribute (0x01): a descriptor per fabric
      def fabrics : Array(Tlv::FabricDescriptor)
        visible_fabrics.map do |fabric|
          Tlv::FabricDescriptor.new(
            root_public_key: fabric.root_public_key,
            vendor_id: fabric.vendor_id,
            fabric_id: fabric.fabric_id,
            node_id: fabric.node_id,
            label: fabric.label,
            fabric_index: fabric.fabric_index,
            vid_verification_statement: fabric.vid_verification_statement
          )
        end
      end

      private def visible_fabrics : Array(Fabric)
        all = fabric_table.all_fabrics
        if request_fabric_filtered? && (index = request_fabric_index)
          all.select { |fabric| fabric.fabric_index == index }
        else
          all
        end
      end

      # SupportedFabrics attribute (0x02) - Maximum supported fabrics
      def supported_fabrics : UInt8
        fabric_table.max_fabrics
      end

      # CommissionedFabrics attribute (0x03) - Current number of fabrics
      def commissioned_fabrics : UInt8
        fabric_table.size.to_u8
      end

      # CurrentFabricIndex attribute (0x05): the accessing fabric, none outside one
      def current_fabric_index(fabric_index : UInt8? = nil) : UInt8
        fabric_index || DataType::NO_FABRIC
      end

      # Get fabric descriptor by index (for tests)
      def get_fabric_by_index(index : UInt8) : Tlv::FabricDescriptor?
        fabrics.find { |fabric| fabric.fabric_index == index }
      end

      # Check if there's capacity for more fabrics (for tests)
      def has_fabric_capacity? : Bool
        !fabric_table.full?
      end

      # Get NOC by fabric index (for tests)
      def get_noc_by_fabric_index(index : UInt8) : Tlv::NOC?
        nocs.find { |noc| noc.fabric_index == index }
      end

      # ========================================================================
      # Command handlers (DSL dispatch)
      # ========================================================================

      def attestation_request(request : Tlv::AttestationRequest) : Tlv::AttestationResponse
        elements, signature = credentials.attest(request.attestation_nonce, request_session_id)
        Tlv::AttestationResponse.new(elements, signature)
      end

      def certificate_chain_request(request : Tlv::CertificateChainRequest) : Tlv::CertificateChainResponse
        certificate = case request.certificate_type
                      when Tlv::CertificateChainType::DacCertificate
                        credentials.dac
                      when Tlv::CertificateChainType::PaiCertificate
                        credentials.pai
                      end

        Tlv::CertificateChainResponse.new(certificate || Bytes.new(0))
      end

      def csr_request(request : Tlv::CsrRequest) : InteractionModel::Status | Tlv::CsrResponse
        result = credentials.create_csr(
          nonce: request.csr_nonce,
          session_id: request_session_id || 0_u64,
          is_for_update_noc: request.is_for_update_noc || false,
          pase_session: !request_is_case_session?
        )

        # A CSRResponse payload cannot carry an error; a refusal has to travel
        # as a StatusIB in the InvokeResponse.
        unless result
          return InteractionModel::Status.cluster_failure(NodeOperationalCertStatus::MissingCsr)
        end

        elements, signature = result
        Tlv::CsrResponse.new(elements, signature)
      end

      def add_noc(request : Tlv::AddNocRequest) : InteractionModel::Status | Tlv::TlvNocResponse
        return InteractionModel::Status.invalid_command unless DataType::VendorId.valid_operational?(request.admin_vendor_id)
        noc_response credentials.add_noc(
          noc: request.noc_value,
          icac: request.icac_value,
          ipk: request.ipk_value,
          case_admin_subject: request.case_admin_subject,
          admin_vendor_id: request.admin_vendor_id,
          session_id: request_session_id || 0_u64
        )
      end

      def update_noc(request : Tlv::UpdateNocRequest) : InteractionModel::Status | Tlv::TlvNocResponse
        fabric_index = request_fabric_index
        return InteractionModel::Status.unsupported_access unless request_is_case_session? && fabric_index

        noc_response credentials.update_noc(
          noc: request.noc_value,
          icac: request.icac_value,
          session_fabric_index: fabric_index,
          session_id: request_session_id || 0_u64
        )
      end

      def update_fabric_label(request : Tlv::UpdateFabricLabelRequest) : InteractionModel::Status | Tlv::TlvNocResponse
        fabric_index = request_fabric_index
        return InteractionModel::Status.unsupported_access unless request_is_case_session? && fabric_index

        noc_response credentials.update_fabric_label(
          request.label,
          fabric_index
        )
      end

      def remove_fabric(request : Tlv::RemoveFabricRequest) : Tlv::TlvNocResponse
        noc_response credentials.remove_fabric(request.fabric_index)
      end

      # AddTrustedRootCertificate has no command response. The IM status reports
      # its fail-safe, sequencing, and certificate validation outcome.
      def add_trusted_root_certificate(request : Tlv::AddTrustedRootCertificateRequest) : InteractionModel::Status
        outcome = credentials.add_trusted_root_certificate(request.root_certificate)
        return InteractionModel::Status.success if outcome.ok?

        Log.warn { "AddTrustedRootCertificate failed: #{outcome.debug_text}" }
        case outcome.root_install_failure
        when Commissioning::RootInstallFailure::FailsafeRequired
          InteractionModel::Status.failsafe_required
        when Commissioning::RootInstallFailure::Constraint
          InteractionModel::Status.constraint_error
        else
          InteractionModel::Status.invalid_command
        end
      end

      # Wire command name is fixed by the Matter specification.
      # ameba:disable Naming/AccessorMethodName
      def set_vid_verification_statement(request : Tlv::SetVIDVerificationStatementRequest) : InteractionModel::Status
        index = request_fabric_index
        return InteractionModel::Status.unsupported_access unless index
        fabric = @fabric_table.get_fabric(index)
        return InteractionModel::Status.constraint_error unless fabric
        return InteractionModel::Status.invalid_command if request.vendor_id.nil? &&
                                                           request.vid_verification_statement.nil? && request.vvsc.nil?
        if vendor_id = request.vendor_id
          return InteractionModel::Status.constraint_error unless DataType::VendorId.valid_operational?(vendor_id)
        end
        if statement = request.vid_verification_statement
          return InteractionModel::Status.constraint_error unless statement.empty? || statement.size == 85
        end
        if vvsc = request.vvsc
          return InteractionModel::Status.constraint_error if vvsc.size > 400
          return InteractionModel::Status.invalid_command if fabric.intermediate_cert
        end

        if credentials.failsafe_armed? && credentials.pending.noc_added_or_updated?
          @vid_failsafe_snapshot[index] ||= {
            fabric.vendor_id,
            fabric.vid_verification_statement.try(&.dup),
            fabric.vvsc.try(&.dup),
          }
        end

        if vendor_id = request.vendor_id
          fabric.vendor_id = vendor_id
        end
        if statement = request.vid_verification_statement
          fabric.vid_verification_statement = statement.empty? ? nil : statement.dup
        end
        if vvsc = request.vvsc
          fabric.vvsc = vvsc.empty? ? nil : vvsc.dup
        end
        @fabric_table.update_fabric(fabric)
        increment_version
        notify_changed(ATTR_FABRICS) unless request.vendor_id.nil? && request.vid_verification_statement.nil?
        notify_changed(ATTR_NOCS) unless request.vvsc.nil?
        InteractionModel::Status.success
      end

      # ameba:enable Naming/AccessorMethodName

      def sign_vid_verification_request(request : Tlv::SignVIDVerificationRequest) : Tlv::SignVIDVerificationResponse | InteractionModel::Status
        return InteractionModel::Status.constraint_error unless request.client_challenge.size == 32
        fabric = @fabric_table.get_fabric(request.fabric_index)
        return InteractionModel::Status.constraint_error unless fabric
        session_id = request_session_id
        return InteractionModel::Status.failure unless session_id
        challenge = credentials.session_lookup.try(&.call(session_id))
        return InteractionModel::Status.failure unless challenge

        version = 1_u8
        tbs = IO::Memory.new
        tbs.write_byte version
        tbs.write request.client_challenge
        tbs.write challenge
        tbs.write_byte request.fabric_index
        tbs.write_byte version
        tbs.write fabric.root_public_key
        tbs.write_bytes fabric.fabric_id, IO::ByteFormat::BigEndian
        tbs.write_bytes fabric.vendor_id, IO::ByteFormat::BigEndian
        if statement = fabric.vid_verification_statement
          tbs.write statement
        end
        signature = Crypto.sign_ecdsa(fabric.operational_key, tbs.to_slice)
        Tlv::SignVIDVerificationResponse.new(request.fabric_index, version, signature)
      end

      private def noc_response(outcome : Commissioning::NocOutcome) : Tlv::TlvNocResponse
        Tlv::TlvNocResponse.new(
          status_code: Tlv::NodeOperationalCertificateStatus.from_value(outcome.status.value.to_i64),
          fabric_index: outcome.fabric_index,
          debug_text: outcome.debug_text
        )
      end

      # ========================================================================
      # Struct command handlers
      #
      # The same service calls with the hand-written request structs, for
      # callers that hold the cluster rather than a wire message.
      # ========================================================================

      # AttestationRequest command (0x00)
      def handle_attestation_request(
        cmd : AttestationRequestCommand,
        session_id : UInt64,
      ) : AttestationResponse
        elements, signature = credentials.attest(cmd.attestation_nonce, session_id)
        AttestationResponse.new(attestation_elements: elements, attestation_signature: signature)
      end

      # CertificateChainRequest command (0x02)
      def handle_certificate_chain_request(
        cmd : CertificateChainRequestCommand,
      ) : CertificateChainResponse | InteractionModel::Status
        certificate = case cmd.certificate_type
                      when CertificateChainType::DACCertificate
                        credentials.dac
                      when CertificateChainType::PAICertificate
                        credentials.pai
                      end

        unless certificate
          Log.error { "CertificateChainRequest: #{cmd.certificate_type} not available" }
          return InteractionModel::Status.failure
        end

        CertificateChainResponse.new(certificate: certificate)
      end

      # CSRRequest command (0x04)
      def handle_csr_request(
        cmd : CSRRequestCommand,
        session_id : UInt64,
        is_pase_session : Bool,
        failsafe_armed : Bool,
      ) : CSRResponse?
        credentials.failsafe_armed = failsafe_armed
        result = credentials.create_csr(
          nonce: cmd.csr_nonce,
          session_id: session_id,
          is_for_update_noc: cmd.is_for_update_noc || false,
          pase_session: is_pase_session
        )
        return unless result

        elements, signature = result
        CSRResponse.new(nocsr_elements: elements, attestation_signature: signature)
      end

      # AddTrustedRootCertificate command (0x0B)
      #
      # Answers nil on success: the command has no response on the wire.
      def handle_add_trusted_root_certificate(
        cmd : AddTrustedRootCertificateCommand,
        failsafe_armed : Bool,
      ) : NOCResponse?
        return unless failsafe_armed

        credentials.failsafe_armed = failsafe_armed
        outcome = credentials.add_trusted_root_certificate(cmd.root_ca_certificate)
        return if outcome.ok?

        struct_response(outcome)
      end

      # AddNOC command (0x06)
      def handle_add_noc(
        cmd : AddNOCCommand,
        session_id : UInt64,
        failsafe_armed : Bool,
      ) : NOCResponse
        credentials.failsafe_armed = failsafe_armed
        struct_response credentials.add_noc(
          noc: cmd.noc_value,
          icac: cmd.icac_value,
          ipk: cmd.ipk_value,
          case_admin_subject: cmd.case_admin_subject,
          admin_vendor_id: cmd.admin_vendor_id,
          session_id: session_id
        )
      end

      # UpdateNOC command (0x07)
      def handle_update_noc(
        cmd : UpdateNOCCommand,
        session_id : UInt64,
        session_fabric_index : UInt8,
        failsafe_armed : Bool,
      ) : NOCResponse
        credentials.failsafe_armed = failsafe_armed
        struct_response credentials.update_noc(
          noc: cmd.noc_value,
          icac: cmd.icac_value,
          session_fabric_index: session_fabric_index,
          session_id: session_id
        )
      end

      # UpdateFabricLabel command (0x09)
      def handle_update_fabric_label(
        cmd : UpdateFabricLabelCommand,
        session_fabric_index : UInt8,
      ) : NOCResponse
        struct_response credentials.update_fabric_label(cmd.label, session_fabric_index)
      end

      # RemoveFabric command (0x0A)
      def handle_remove_fabric(cmd : RemoveFabricCommand) : NOCResponse
        struct_response credentials.remove_fabric(cmd.fabric_index)
      end

      private def struct_response(outcome : Commissioning::NocOutcome) : NOCResponse
        NOCResponse.new(
          status_code: outcome.status,
          fabric_index: outcome.fabric_index,
          debug_text: outcome.debug_text
        )
      end

      # ========================================================================
      # Failsafe transitions
      # ========================================================================

      # Failsafe timer expired - drop everything that was pending
      def on_failsafe_expired
        credentials.rollback_pending
        restored_vid_metadata = false
        @vid_failsafe_snapshot.each do |index, previous|
          next unless fabric = @fabric_table.get_fabric(index)
          fabric.vendor_id = previous[0]
          fabric.vid_verification_statement = previous[1]
          fabric.vvsc = previous[2]
          @fabric_table.update_fabric(fabric)
          restored_vid_metadata = true
        end
        @vid_failsafe_snapshot.clear
        if restored_vid_metadata
          increment_version
          notify_changed(ATTR_FABRICS)
          notify_changed(ATTR_NOCS)
        end
      end

      # Failsafe disarmed successfully - the credentials are committed
      def on_failsafe_success(journal_cleared : Bool = false)
        credentials.commit_pending(journal_cleared: journal_cleared)
        @vid_failsafe_snapshot.clear
      end

      # A new failsafe was armed: state from a previous commissioning session
      # must not interfere with this one. Called by GeneralCommissioning.
      def on_failsafe_armed
        Log.info { "Resetting failsafe context for new commissioning session" }
        @vid_failsafe_snapshot.clear
        credentials.reset_pending
      end

      # ========================================================================
      # Credential target (`Commissioning::CredentialTarget`)
      # ========================================================================

      # Bump the data version after a credential change
      def credentials_changed : Nil
        increment_version
        notify_changed(ATTR_NOCS)
        notify_changed(ATTR_FABRICS)
        notify_changed(ATTR_COMMISSIONED_FABRICS)
        notify_changed(ATTR_TRUSTED_ROOT_CERTIFICATES)
      end

      # A fabric was added: the Matter spec requires an ACL entry granting the
      # commissioning administrator the Administer privilege, and the armed
      # failsafe has to learn the fabric so that CommissioningComplete can
      # arrive on the new fabric's CASE session.
      def fabric_committed(fabric : Fabric, case_admin_subject : UInt64) : Nil
        if acl_cluster = @access_control_cluster
          acl_cluster.acl << AccessControl::AccessControlEntry.new(
            privilege: AccessControl::AccessControlEntryPrivilege::Administer,
            auth_mode: AccessControl::AccessControlEntryAuthMode::CASE,
            subjects: [case_admin_subject],
            targets: nil, # nil means all targets
            fabric_index: fabric.fabric_index
          )
          acl_cluster.increment_version
          persist_acl(acl_cluster, fabric.fabric_index)
        end

        @general_commissioning_cluster.try(&.record_added_fabric(fabric.fabric_index))
        credentials_changed
      end

      # A fabric was removed: so is every piece of data scoped to it
      def fabric_forgotten(fabric_index : UInt8) : Nil
        if access_control = @access_control_cluster
          access_control.with_persistence_guard do
            access_control.remove_fabric_acl(fabric_index)
            # The credential journal may only be cleared after the removed
            # fabric's ACL is durable. Otherwise a crash can resurrect an ACL
            # under the same local fabric index on a later commission.
            persist_acl(access_control, fabric_index)
          end
        end
      end

      private def persist_acl(access_control : AccessControl, fabric_index : UInt8) : Nil
        access_control.with_persistence_guard do
          state = access_control.save_state ||
                  raise StorageError.new("Could not encode ACL for fabric #{fabric_index}")
          @fabric_table.backend.write(Storage::Collections::CLUSTERS,
            access_control.persistence_key, state)
        end
      end
    end
  end
end
