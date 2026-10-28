require "../cluster/joint_fabric_administrator"
require "../cluster/joint_fabric_datastore"
require "../datatype/node_id"
require "../crypto/certificate_validation"
require "../crypto/pkcs10"
require "../setup_payload"
require "./remote_icac_csr_provider"

module Matter
  module Commissioning
    # Security-sensitive state behind the Joint Fabric Administrator cluster.
    # The host supplies policy and persistence callbacks because consent,
    # fail-safe lifetime, discovery and fabric storage are application state.
    class JointFabricAdministratorService
      include Cluster::JointFabricAdministrator::Service

      alias Admin = Cluster::JointFabricAdministrator
      alias WindowRequest = Admin::OpenJointCommissioningWindowRequest

      record FabricIdentity, root_certificate : Bytes, fabric_id : UInt64

      getter cross_signed_icac : Bytes?
      getter announced_administrator_endpoint : UInt16?

      @committed_icac : Bytes?
      @last_csr_public_key : Bytes?
      @csr_requester_node_id : UInt64?
      @csr_requester_fabric_index : UInt8?
      @icac_attempt_fabric_indices = Set(UInt8?).new
      @icac_pending_commit : Bool = false
      @transfer_requester_node_id : UInt64?
      @transfer_requester_fabric_index : UInt8?
      @verified_initiator_node_id : UInt64?
      @verified_initiator_fabric_index : UInt8?
      @administrator_cluster : Admin?
      @authenticated_icac_public_key : Bytes?

      MAX_ICAC_BYTES = 400

      def initialize(
        @icac_private_key : Crypto::Key?,
        @root_certificate : Bytes,
        @fabric_id : UInt64,
        @failsafe_armed : Proc(Bool),
        @vendor_id_verified : Proc(UInt8, Bool),
        @open_window : Proc(WindowRequest, InteractionModel::Status),
        @transfer_authorized : Proc(UInt64, Bool),
        @datastore_busy : Proc(Bool),
        @begin_transfer : Proc(Nil),
        @complete_transfer : Proc(Nil),
        @crypto : Crypto::CryptoBase = Crypto::StandardCrypto.new,
        @administrator_cat_version : UInt16 = 1_u16,
        @anchor_cat_version : UInt16 = 1_u16,
        initial_icac : Bytes? = nil,
        @persist_icac : Proc(Bytes?, Nil)? = nil,
        # The peer address is only a reachability hint. Its UDP source port is
        # ephemeral and must not be used as an operational port. The callback
        # still has to CASE-authenticate the expected Node ID on this fabric.
        @verify_anchor_initiator : Proc(UInt64, UInt8, Socket::IPAddress, Bool)? = nil,
        @resolve_accessing_fabric : Proc(UInt8, FabricIdentity?)? = nil,
        existing_icac_certificate : Bytes? = nil,
        @failsafe_fabric_matches : Proc(UInt8?, Bool)? = nil,
        @on_transfer_requested : Proc(UInt64, UInt8, Nil)? = nil,
        initial_transfer_requester : Tuple(UInt64, UInt8)? = nil,
        @icac_csr_provider : RemoteIcacCsrProvider? = nil,
      )
        @authenticated_icac_public_key = nil
        if @icac_private_key.nil? == @icac_csr_provider.nil?
          raise Matter::ConfigurationError.new("Configure exactly one JFA ICAC CSR signer")
        end
        if requester = initial_transfer_requester
          @transfer_requester_node_id = requester[0]
          @transfer_requester_fabric_index = requester[1]
        end
        @cross_signed_icac = initial_icac.try(&.dup)
        @committed_icac = initial_icac.try(&.dup)
        root = Crypto::MatterCertificate.from_slice(@root_certificate)
        unless Crypto::MatterCertificate::Validation.certificate_authority?(@root_certificate)
          raise Matter::ConfigurationError.new("Joint Fabric root is not a CA")
        end
        Crypto::MatterCertificate::Validation.verify_signature(@root_certificate, root.ec_public_key)
        if existing_icac = existing_icac_certificate
          expected_key = @icac_private_key.try(&.public_key) || Crypto::MatterCertificate.public_key_from_tlv(existing_icac)
          unless Crypto::MatterCertificate.public_key_from_tlv(existing_icac) == expected_key
            raise Matter::ConfigurationError.new("JFA CSR key differs from its existing ICAC key")
          end
          Crypto::MatterCertificate::Validation.verify_issued_by(existing_icac, @root_certificate)
          Crypto::MatterCertificate::Validation.verify_signature(existing_icac, root.ec_public_key)
          @authenticated_icac_public_key = expected_key
        end
        if @icac_csr_provider && existing_icac_certificate.nil?
          raise Matter::ConfigurationError.new("Remote JFA CSR signer requires an authenticated existing ICAC")
        end
      end

      # A new fail-safe period permits a new cross-signing attempt.
      def reset_failsafe : Nil
        # ArmFailSafe may extend an existing window; that must not allow a
        # second AddICAC or replace the pre-window rollback snapshot.
        return if @icac_pending_commit
        @last_csr_public_key = nil
        @csr_requester_node_id = nil
        @csr_requester_fabric_index = nil
        @icac_attempt_fabric_indices.clear
        @verified_initiator_node_id = nil
        @verified_initiator_fabric_index = nil
      end

      # A new ICAC is provisional until CommissioningComplete. The fail-safe
      # restores the certificate that was installed before this attempt.
      def on_failsafe_expired : Nil
        @cross_signed_icac = @committed_icac.try(&.dup)
        if cluster = @administrator_cluster
          cluster.rollback_provisional_administrator_fabric_index
        end
        @administrator_cluster = nil
        @icac_pending_commit = false
        reset_failsafe
      end

      def on_commissioning_complete : Nil
        write_pending_completion
        confirm_pending_completion
      end

      # Write the post-commit ICAC and AdministratorFabricIndex while the
      # caller's backend transaction also clears the device NOC undo journal.
      # A failed transaction leaves this service and cluster provisional so
      # CommissioningComplete can be retried or the fail-safe can roll back.
      def write_pending_completion : Nil
        if @icac_pending_commit
          certificate = @cross_signed_icac
          cluster = @administrator_cluster ||
                    raise Matter::ConfigurationError.new("Pending ICAC has no Administrator cluster")
          cluster.with_pending_provisional_commit do
            @persist_icac.try(&.call(certificate))
          end
        end
      end

      # Called only after the backend transaction has returned successfully.
      # This phase changes live state but performs no new durable writes.
      def confirm_pending_completion : Nil
        if @icac_pending_commit
          certificate = @cross_signed_icac
          cluster = @administrator_cluster ||
                    raise Matter::ConfigurationError.new("Pending ICAC has no Administrator cluster")
          @committed_icac = certificate.try(&.dup)
          cluster.commit_provisional_administrator_fabric_index
          @icac_pending_commit = false
          @administrator_cluster = nil
        end
        reset_failsafe
      end

      def icaccsr_request(cluster : Admin) : Admin::ICACCSRResponse | InteractionModel::Status
        return InteractionModel::Status.invalid_command unless cluster.request_is_case_session?
        return InteractionModel::Status.failsafe_required unless @failsafe_armed.call
        return InteractionModel::Status.constraint_error if icac_attempted_on_fabric?(cluster)
        fabric_index = cluster.administrator_fabric_index
        accessing_fabric_index = cluster.request_fabric_index
        unless verified_initiator?(cluster) && accessing_fabric_index && @vendor_id_verified.call(accessing_fabric_index)
          return InteractionModel::Status.cluster_failure(Admin::ICACCSRResponseStatusCodeEnum::VIDNotVerified)
        end
        unless fabric_index
          return InteractionModel::Status.cluster_failure(Admin::ICACCSRResponseStatusCodeEnum::InvalidAdministratorFabricIndex)
        end
        return InteractionModel::Status.unsupported_access unless anchor_principal?(cluster)
        return InteractionModel::Status.unsupported_access unless failsafe_fabric_matches?(cluster)

        public_key = @icac_private_key.try(&.public_key) || @authenticated_icac_public_key ||
                     raise Matter::ConfigurationError.new("JFA ICAC public key is unavailable")
        csr = if provider = @icac_csr_provider
                provider.request
              elsif key = @icac_private_key
                Crypto::Pkcs10.create(key, @crypto)
              else
                raise Matter::ConfigurationError.new("JFA ICAC CSR signer is unavailable")
              end
        Crypto::Pkcs10.verify(csr, public_key, @crypto)
        @last_csr_public_key = public_key
        @csr_requester_node_id = cluster.request_peer_node_id
        @csr_requester_fabric_index = cluster.request_fabric_index
        Admin::ICACCSRResponse.new(Admin::ICACCSRResponseStatusCodeEnum::OK,
          csr)
      rescue Matter::Error
        InteractionModel::Status.cluster_failure(Admin::ICACCSRResponseStatusCodeEnum::Busy)
      end

      def add_icac(cluster : Admin, request : Admin::AddICACRequest) : Admin::ICACResponse | InteractionModel::Status
        return InteractionModel::Status.invalid_command unless cluster.request_is_case_session?
        return InteractionModel::Status.failsafe_required unless @failsafe_armed.call
        return InteractionModel::Status.invalid_command if request.icac_value.size > MAX_ICAC_BYTES
        return InteractionModel::Status.constraint_error if icac_attempted_on_fabric?(cluster)
        unless anchor_principal?(cluster)
          # A malformed/non-matching ICAC can be rejected without revealing a
          # CSR or mutating credentials. Certification exercises this path on a
          # fresh Administrator before it has joined a joint fabric.
          @icac_attempt_fabric_indices.add(cluster.request_fabric_index)
          return Admin::ICACResponse.new(unprivileged_icac_status(cluster, request.icac_value))
        end
        return InteractionModel::Status.unsupported_access unless failsafe_fabric_matches?(cluster)
        unless @csr_requester_node_id && @csr_requester_node_id == cluster.request_peer_node_id &&
               @csr_requester_fabric_index == cluster.request_fabric_index
          return InteractionModel::Status.unsupported_access
        end
        # An authenticated AddICAC consumes this fabric's one attempt even if
        # its certificate or CSR public key is invalid.
        @icac_attempt_fabric_indices.add(cluster.request_fabric_index)
        csr_key = @last_csr_public_key
        return Admin::ICACResponse.new(Admin::ICACResponseStatusEnum::InvalidPublicKey) unless csr_key
        accessing_index = cluster.request_fabric_index
        identity = if resolver = @resolve_accessing_fabric
                     accessing_index.try { |index| resolver.call(index) }
                   else
                     FabricIdentity.new(@root_certificate, @fabric_id)
                   end
        return Admin::ICACResponse.new(Admin::ICACResponseStatusEnum::InvalidICAC) unless identity && accessing_index

        certificate = Crypto::MatterCertificate.from_slice(request.icac_value)
        unless certificate.ec_public_key == csr_key
          return Admin::ICACResponse.new(Admin::ICACResponseStatusEnum::InvalidPublicKey)
        end
        unless certificate.subject.icac_id &&
               Crypto::MatterCertificate::Validation.certificate_authority?(request.icac_value)
          return Admin::ICACResponse.new(Admin::ICACResponseStatusEnum::InvalidICAC)
        end
        Crypto::MatterCertificate::Validation.verify_intermediate_profile(request.icac_value,
          identity.fabric_id)
        root_key = Crypto::MatterCertificate.public_key_from_tlv(identity.root_certificate)
        Crypto::MatterCertificate::Validation.verify_issued_by(request.icac_value, identity.root_certificate)
        Crypto::MatterCertificate::Validation.verify_signature(request.icac_value, root_key)
        cluster.begin_provisional_administrator_fabric_index(accessing_index)
        @administrator_cluster = cluster
        @cross_signed_icac = request.icac_value.dup
        @icac_pending_commit = true
        Admin::ICACResponse.new(Admin::ICACResponseStatusEnum::OK)
      rescue Matter::Error
        Admin::ICACResponse.new(Admin::ICACResponseStatusEnum::InvalidICAC)
      end

      def open_joint_commissioning_window(cluster : Admin, request : WindowRequest) : InteractionModel::Status
        return InteractionModel::Status.invalid_command unless cluster.request_is_case_session?
        return InteractionModel::Status.cluster_failure(Admin::ICACCSRResponseStatusCodeEnum::InvalidAdministratorFabricIndex) unless cluster.administrator_fabric_index
        return InteractionModel::Status.unsupported_access unless administrator_control_principal?(cluster)
        return InteractionModel::Status.invalid_command unless valid_window_parameters?(request)
        return InteractionModel::Status.unsupported_access unless cluster.jcm_add_noc_guard_ready?
        result = @open_window.call(request)
        if result.status == InteractionModel::StatusCode::Busy
          InteractionModel::Status.cluster_failure(Admin::ICACCSRResponseStatusCodeEnum::Busy)
        elsif result.status == InteractionModel::StatusCode::ConstraintError ||
              result.cluster_status == Commissioning::WindowStatusCode::PAKEParameterError.value
          InteractionModel::Status.invalid_command
        else
          result
        end
      end

      def transfer_anchor_request(cluster : Admin) : Admin::TransferAnchorResponse | InteractionModel::Status
        return InteractionModel::Status.invalid_command unless cluster.request_is_case_session?
        node_id = cluster.request_peer_node_id
        fabric_index = cluster.request_fabric_index
        return InteractionModel::Status.unsupported_access unless node_id && fabric_index
        return InteractionModel::Status.unsupported_access unless administrator_control_principal?(cluster)
        unless @transfer_authorized.call(node_id)
          return Admin::TransferAnchorResponse.new(Admin::TransferAnchorResponseStatusEnum::TransferAnchorStatusNoUserConsent)
        end
        if @datastore_busy.call
          return Admin::TransferAnchorResponse.new(Admin::TransferAnchorResponseStatusEnum::TransferAnchorStatusDatastoreBusy)
        end
        # The participant journal must bind the incoming transfer to the
        # authenticated CASE requester before the Datastore enters transfer.
        @on_transfer_requested.try(&.call(node_id, fabric_index))
        @begin_transfer.call
        @transfer_requester_node_id = node_id
        @transfer_requester_fabric_index = fabric_index
        Admin::TransferAnchorResponse.new(Admin::TransferAnchorResponseStatusEnum::OK)
      end

      def transfer_anchor_complete(cluster : Admin) : InteractionModel::Status
        return InteractionModel::Status.invalid_command unless cluster.request_is_case_session?
        return InteractionModel::Status.unsupported_access unless administrator_principal?(cluster)
        requester = @transfer_requester_node_id
        return InteractionModel::Status.unsupported_access unless requester &&
                                                                  cluster.request_peer_node_id == requester &&
                                                                  cluster.request_fabric_index == @transfer_requester_fabric_index
        @complete_transfer.call
        # Retain the authenticated requester for an idempotent retry if the
        # response is lost, including after the host restores it on restart.
        InteractionModel::Status.success
      end

      def announce_joint_fabric_administrator(cluster : Admin, request : Admin::AnnounceJointFabricAdministratorRequest) : InteractionModel::Status
        return InteractionModel::Status.invalid_command unless cluster.request_is_case_session?
        return InteractionModel::Status.unsupported_access unless anchor_principal?(cluster)
        @announced_administrator_endpoint = request.endpoint_id
        node_id = cluster.request_peer_node_id
        fabric_index = cluster.request_fabric_index
        peer_address = cluster.request_peer_address
        verifier = @verify_anchor_initiator
        if node_id && fabric_index && peer_address && verifier && verifier.call(node_id, fabric_index, peer_address)
          @verified_initiator_node_id = node_id
          @verified_initiator_fabric_index = fabric_index
        else
          @verified_initiator_node_id = nil
          @verified_initiator_fabric_index = nil
        end
        InteractionModel::Status.success
      end

      # Operational VID verification belongs to the authenticated Anchor on
      # this fabric, not to one transient CASE session. The SDK may establish
      # a fresher CASE session between Announce and ICACCSRRequest.
      private def verified_initiator?(cluster : Admin) : Bool
        node_id = @verified_initiator_node_id
        !!node_id && node_id == cluster.request_peer_node_id &&
          @verified_initiator_fabric_index == cluster.request_fabric_index
      end

      private def icac_attempted_on_fabric?(cluster : Admin) : Bool
        @icac_attempt_fabric_indices.includes?(cluster.request_fabric_index)
      end

      private def failsafe_fabric_matches?(cluster : Admin) : Bool
        matcher = @failsafe_fabric_matches
        !!matcher && matcher.call(cluster.request_fabric_index)
      end

      private def valid_window_parameters?(request : WindowRequest) : Bool
        request.commissioning_timeout > 0 && request.commissioning_timeout < UInt16::MAX &&
          request.pake_passcode_verifier.size == 97 && request.discriminator <= SetupPayload::MAX_DISCRIMINATOR &&
          request.iterations >= 1000 && request.iterations <= 100_000 &&
          request.salt.size >= 16 && request.salt.size <= 32
      end

      private def unprivileged_icac_status(cluster : Admin, icac : Bytes) : Admin::ICACResponseStatusEnum
        identity = if resolver = @resolve_accessing_fabric
                     cluster.request_fabric_index.try { |index| resolver.call(index) }
                   else
                     FabricIdentity.new(@root_certificate, @fabric_id)
                   end
        return Admin::ICACResponseStatusEnum::InvalidICAC unless identity
        certificate = Crypto::MatterCertificate.from_slice(icac)
        return Admin::ICACResponseStatusEnum::InvalidICAC unless certificate.subject.icac_id &&
                                                                 Crypto::MatterCertificate::Validation.certificate_authority?(icac)
        Crypto::MatterCertificate::Validation.verify_intermediate_profile(icac, identity.fabric_id)
        root_key = Crypto::MatterCertificate.public_key_from_tlv(identity.root_certificate)
        Crypto::MatterCertificate::Validation.verify_issued_by(icac, identity.root_certificate)
        Crypto::MatterCertificate::Validation.verify_signature(icac, root_key)
        Admin::ICACResponseStatusEnum::InvalidPublicKey
      rescue Matter::Error
        Admin::ICACResponseStatusEnum::InvalidICAC
      end

      private def administrator_principal?(cluster : Admin) : Bool
        cat_subject?(cluster.request_peer_subject_ids, Cluster::JointFabricDatastore::ADMINISTRATOR_CAT,
          @administrator_cat_version)
      end

      # A JFA may remain commissioned on its bootstrap fabric after joining a
      # different Joint Fabric. An Administrator CAT on that other fabric must
      # not control this JFA endpoint's commissioning window or Anchor role.
      private def administrator_control_principal?(cluster : Admin) : Bool
        index = cluster.administrator_fabric_index
        !!index && cluster.request_fabric_index == index && administrator_principal?(cluster)
      end

      private def anchor_principal?(cluster : Admin) : Bool
        icac = cluster.request_peer_icac
        !!icac &&
          cat_subject?(cluster.request_peer_subject_ids, Cluster::JointFabricDatastore::ANCHOR_CAT, @anchor_cat_version) &&
          Crypto::MatterCertificate.anchor_icac?(icac)
      end

      # CAT authorization follows the same minimum-version rule as Access
      # Control. During Anchor transfer, the new Anchor has the next version
      # before participants retire the old fabric.
      private def cat_subject?(subjects : Array(UInt64)?, identity : UInt16, minimum_version : UInt16) : Bool
        return false unless subjects
        subjects.any? do |subject|
          cat = DataType::NodeId.case_authenticated_tag_from_subject?(subject)
          cat && cat.identity_value == identity && cat.version >= minimum_version
        end
      end
    end
  end
end
