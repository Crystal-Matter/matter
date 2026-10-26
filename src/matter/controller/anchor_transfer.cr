require "../cluster/joint_fabric_administrator"
require "../cluster/joint_fabric_datastore"
require "../cluster/general_commissioning"
require "../cluster/operational_credentials"
require "./certificate_util"
require "./im_client"
require "./joint_commissioning"
require "./pairing/case_pairing"

module Matter
  module Controller
    # Candidate-side ordering for Matter 1.6 Core 12.2.6. Every stage is saved
    # before a network or credential operation. A crash inside such a stage
    # requires explicit reconciliation; replaying an uncertain transfer could
    # change the trust root twice.
    module AnchorTransfer
      Log = ::Log.for("matter.controller.anchor_transfer")
      alias Datastore = Cluster::JointFabricDatastore
      alias Administrator = Cluster::JointFabricAdministrator

      enum Stage : UInt8
        Ready
        Requesting
        Requested
        Copying
        Copied
        Rotating
        Rotated
        Promoting
        Promoted
        Completing
        Transferred
        FollowingUp
        Completed
      end

      class Journal
        include Storage::Record

        getter candidate_node_id : UInt64
        property stage : Stage
        property active_rotation_node_id : UInt64? = nil
        property rotated_administrator_node_ids = [] of UInt64

        def initialize(@candidate_node_id : UInt64, @stage : Stage = Stage::Ready)
        end
      end

      # A host-supplied witness for an acknowledgement lost after the old
      # Anchor completed the command. The host must authenticate its source;
      # this is not a Matter wire message or a readable inactive Datastore.
      struct CompletionWitness
        getter nonce : String
        getter old_anchor_node_id : UInt64
        getter old_fabric_id : UInt64
        getter old_root_public_key : Bytes
        getter requester_node_id : UInt64
        getter new_anchor_node_id : UInt64
        getter? transfer_complete : Bool

        def initialize(@nonce : String, @old_anchor_node_id : UInt64,
                       @old_fabric_id : UInt64, @old_root_public_key : Bytes,
                       @requester_node_id : UInt64, @new_anchor_node_id : UInt64,
                       @transfer_complete : Bool)
        end
      end

      # Applies a datastore snapshot obtained from the old Anchor, including
      # every persisted list. The caller must still fetch that snapshot over
      # an authenticated channel (attribute reads or BDX) before calling this.
      module Snapshot
        extend self

        # Read the frozen old Anchor Datastore over the candidate's CASE
        # session. Every read is fabric filtered to the Joint Fabric.
        def read_remote(im : ImClient, session : Session::SecureContext,
                        peer : Socket::IPAddress, endpoint_id : UInt16,
                        require_frozen : Bool? = true) : Datastore
          source = Datastore.new(DataType::EndpointNumber.new(endpoint_id))
          source.status = Datastore::DatastoreStatusEntryStruct.from_slice(read(im, session, peer,
            endpoint_id, Datastore::ATTR_STATUS))
          expected_state = case require_frozen
                           when true  then Datastore::DatastoreStateEnum::DeletePending
                           when false then Datastore::DatastoreStateEnum::Committed
                           end
          unless expected_state ? source.status.state == expected_state : source.status.state.in?(Datastore::DatastoreStateEnum::Committed, Datastore::DatastoreStateEnum::DeletePending)
            raise Matter::CommissioningError.new("Old Anchor Datastore has an invalid state for transfer")
          end
          source.anchor_root_ca = Bytes.from_tlv(read(im, session, peer, endpoint_id, Datastore::ATTR_ANCHOR_ROOT_CA))
          source.anchor_node_id = UInt64.from_tlv(read(im, session, peer, endpoint_id, Datastore::ATTR_ANCHOR_NODE_ID))
          source.anchor_vendor_id = UInt16.from_tlv(read(im, session, peer, endpoint_id, Datastore::ATTR_ANCHOR_VENDOR_ID))
          source.friendly_name = String.from_tlv(read(im, session, peer, endpoint_id, Datastore::ATTR_FRIENDLY_NAME))
          source.group_key_set_list = Array(Datastore::DatastoreGroupKeySetStruct).from_tlv(read(im, session, peer,
            endpoint_id, Datastore::ATTR_GROUP_KEY_SET_LIST))
          source.group_list = Array(Datastore::DatastoreGroupInformationEntryStruct).from_tlv(read(im, session, peer,
            endpoint_id, Datastore::ATTR_GROUP_LIST))
          source.node_list = Array(Datastore::DatastoreNodeInformationEntryStruct).from_tlv(read(im, session, peer,
            endpoint_id, Datastore::ATTR_NODE_LIST))
          source.admin_list = Array(Datastore::DatastoreAdministratorInformationEntryStruct).from_tlv(read(im, session, peer,
            endpoint_id, Datastore::ATTR_ADMIN_LIST))
          source.endpoint_group_id_list = Array(Datastore::DatastoreEndpointGroupIDEntryStruct).from_tlv(read(im, session, peer,
            endpoint_id, Datastore::ATTR_ENDPOINT_GROUP_ID_LIST))
          source.endpoint_binding_list = Array(Datastore::DatastoreEndpointBindingEntryStruct).from_tlv(read(im, session, peer,
            endpoint_id, Datastore::ATTR_ENDPOINT_BINDING_LIST))
          source.node_key_set_list = Array(Datastore::DatastoreNodeKeySetEntryStruct).from_tlv(read(im, session, peer,
            endpoint_id, Datastore::ATTR_NODE_KEY_SET_LIST))
          source.node_acl_list = Array(Datastore::DatastoreACLEntryStruct).from_tlv(read(im, session, peer,
            endpoint_id, Datastore::ATTR_NODE_ACL_LIST))
          source.node_endpoint_list = Array(Datastore::DatastoreEndpointEntryStruct).from_tlv(read(im, session, peer,
            endpoint_id, Datastore::ATTR_NODE_ENDPOINT_LIST))
          final_status = Datastore::DatastoreStatusEntryStruct.from_slice(read(im, session, peer,
            endpoint_id, Datastore::ATTR_STATUS))
          unless final_status.state == source.status.state &&
                 final_status.update_timestamp == source.status.update_timestamp
            raise Matter::CommissioningError.new("Old Anchor Datastore changed during transfer read")
          end
          source
        end

        def copy!(source : Datastore, candidate : Datastore, candidate_node_id : UInt64,
                  candidate_old_node_id : UInt64? = nil,
                  candidate_administrator : Datastore::DatastoreAdministratorInformationEntryStruct? = nil) : Nil
          raise Matter::ConfigurationError.new("Candidate Node ID must be nonzero") if candidate_node_id == 0_u64
          unless source.status.state.in?(Datastore::DatastoreStateEnum::Committed,
                   Datastore::DatastoreStateEnum::DeletePending)
            raise Matter::CommissioningError.new("Source Anchor Datastore cannot be copied while pending")
          end
          if old_id = candidate_old_node_id
            administrator = candidate_administrator ||
                            raise Matter::ConfigurationError.new("Candidate's new Administrator identity is required")
            unless administrator.node_id == candidate_node_id &&
                   source.admin_list.count(&.node_id.==(old_id)) == 1 &&
                   (old_id == candidate_node_id || source.admin_list.none?(&.node_id.==(candidate_node_id)))
              raise Matter::ConfigurationError.new("Candidate Administrator identity cannot be remapped safely")
            end
          end
          candidate.anchor_root_ca = source.anchor_root_ca.dup
          candidate.anchor_node_id = candidate_node_id
          candidate.anchor_vendor_id = source.anchor_vendor_id
          candidate.friendly_name = source.friendly_name.dup
          candidate.group_key_set_list = copy_list(Datastore::DatastoreGroupKeySetStruct, source.group_key_set_list)
          candidate.group_list = copy_list(Datastore::DatastoreGroupInformationEntryStruct, source.group_list)
          candidate.node_list = copy_list(Datastore::DatastoreNodeInformationEntryStruct, source.node_list)
          candidate.admin_list = copy_list(Datastore::DatastoreAdministratorInformationEntryStruct, source.admin_list)
          candidate.endpoint_group_id_list = copy_list(Datastore::DatastoreEndpointGroupIDEntryStruct, source.endpoint_group_id_list)
          candidate.endpoint_binding_list = copy_list(Datastore::DatastoreEndpointBindingEntryStruct, source.endpoint_binding_list)
          candidate.node_key_set_list = copy_list(Datastore::DatastoreNodeKeySetEntryStruct, source.node_key_set_list)
          candidate.node_acl_list = copy_list(Datastore::DatastoreACLEntryStruct, source.node_acl_list)
          candidate.node_endpoint_list = copy_list(Datastore::DatastoreEndpointEntryStruct, source.node_endpoint_list)
          if old_id = candidate_old_node_id
            remap_candidate_identity!(candidate, old_id, candidate_node_id,
              candidate_administrator.as(Datastore::DatastoreAdministratorInformationEntryStruct))
          end
          candidate.status = Datastore::DatastoreStatusEntryStruct.new(
            Datastore::DatastoreStateEnum::Committed,
            source.status.update_timestamp, 0_u8)
        end

        private def copy_list(type : T.class, entries : Array(T)) : Array(T) forall T
          Array(T).from_tlv(entries.to_tlv)
        end

        private def remap_candidate_identity!(candidate : Datastore, old_id : UInt64, new_id : UInt64,
                                              administrator : Datastore::DatastoreAdministratorInformationEntryStruct) : Nil
          candidate.admin_list = candidate.admin_list.map { |entry| entry.node_id == old_id ? administrator : entry }
          candidate.node_list = candidate.node_list.map do |entry|
            entry.node_id = new_id if entry.node_id == old_id
            entry
          end
          candidate.node_key_set_list = candidate.node_key_set_list.map do |entry|
            entry.node_id = new_id if entry.node_id == old_id
            entry
          end
          candidate.endpoint_group_id_list = candidate.endpoint_group_id_list.map do |entry|
            entry.node_id = new_id if entry.node_id == old_id
            entry
          end
          candidate.node_endpoint_list = candidate.node_endpoint_list.map do |entry|
            entry.node_id = new_id if entry.node_id == old_id
            entry
          end
          candidate.endpoint_binding_list = candidate.endpoint_binding_list.map do |entry|
            entry.node_id = new_id if entry.node_id == old_id
            binding = entry.binding
            binding.node = new_id if binding.node == old_id
            entry.binding = binding
            entry
          end
          candidate.node_acl_list = candidate.node_acl_list.map do |entry|
            entry.node_id = new_id if entry.node_id == old_id
            acl = entry.acl_entry
            acl.subjects = acl.subjects.try(&.map { |subject| subject == old_id ? new_id : subject })
            entry.acl_entry = acl
            entry
          end
        end

        private def read(im : ImClient, session : Session::SecureContext,
                         peer : Socket::IPAddress, endpoint_id : UInt16,
                         attribute_id : UInt32) : Bytes
          response = im.read_attribute(session, peer, endpoint_id, Datastore::CLUSTER_ID, attribute_id)
          data = response.attribute_reports.try(&.find(&.attribute_data)).try(&.attribute_data).try(&.data)
          raise Matter::ProtocolError.new("Anchor Datastore attribute #{attribute_id} read returned no data") unless data
          data.to_slice
        end
      end

      abstract class Port
        abstract def request : Administrator::TransferAnchorResponseStatusEnum
        abstract def complete : Nil
      end

      # Uses the authenticated Administrator CAT CASE session of the candidate.
      # The caller must retain that session until TransferAnchorComplete.
      class ImPort < Port
        def initialize(@im : ImClient, @session : Session::SecureContext,
                       @peer : Socket::IPAddress, @endpoint_id : UInt16)
        end

        def request : Administrator::TransferAnchorResponseStatusEnum
          response = @im.invoke(@session, @peer, @endpoint_id,
            Administrator::CLUSTER_ID, Administrator::CMD_TRANSFER_ANCHOR_REQUEST)
          fields = response.invoke_responses.find(&.command_data).try(&.command_data).try(&.command_fields)
          raise Matter::ProtocolError.new("TransferAnchorRequest returned no response") unless fields
          Administrator::TransferAnchorResponse.from_slice(fields.to_slice).status_code
        end

        def complete : Nil
          response = @im.invoke(@session, @peer, @endpoint_id,
            Administrator::CLUSTER_ID, Administrator::CMD_TRANSFER_ANCHOR_COMPLETE)
          success = response.invoke_responses.any? do |entry|
            entry.command_status.try(&.status.status) == InteractionModel::StatusCode::Success.value
          end
          raise Matter::ProtocolError.new("TransferAnchorComplete failed") unless success
        end
      end

      # Datastore copy, credential rotation, DNS-SD promotion and participant
      # follow-up are separate Matter procedures. The final participant phase
      # happens after TransferAnchorComplete; its journal stage distinguishes
      # network transfer from migration of every other Administrator.
      abstract class Migration
        def preflight! : Nil
        end

        def bind_journal!(_journal : Journal, _save : Proc(Journal, Nil)) : Nil
        end

        def rotation_complete? : Bool
          true
        end

        abstract def copy_datastore! : Nil
        abstract def rotate_credentials! : Nil
        abstract def promote_candidate! : Nil
        abstract def follow_up_administrators! : Nil
      end

      # Concrete old-Anchor acquisition; the two credential operations remain
      # required callbacks because they touch every other Administrator and
      # the candidate's PKI and DNS-SD provider.
      class NetworkMigration < Migration
        alias Operation = Proc(Nil)

        def initialize(@im : ImClient, @session : Session::SecureContext,
                       @peer : Socket::IPAddress, @source_endpoint : UInt16,
                       @candidate : Datastore, @candidate_node_id : UInt64,
                       @rotate_credentials : Operation, @promote_candidate : Operation,
                       @follow_up_administrators : Operation)
        end

        def copy_datastore! : Nil
          source = Snapshot.read_remote(@im, @session, @peer, @source_endpoint)
          Snapshot.copy!(source, @candidate, @candidate_node_id)
        end

        def rotate_credentials! : Nil
          @rotate_credentials.call
        end

        def promote_candidate! : Nil
          @promote_candidate.call
        end

        def follow_up_administrators! : Nil
          @follow_up_administrators.call
        end
      end

      # Adds the candidate Anchor's new root and Administrator NOC to one JFA.
      # A new root creates a distinct operational fabric; CASE on that fabric
      # must succeed before CommissioningComplete commits the credentials.
      abstract class CredentialTransition
        # The Datastore Node ID whose credentials this transition updates.
        # An unnamed transition cannot prove that every JFA is migrated.
        def target_node_id : UInt64?
          nil
        end

        abstract def transition! : UInt8
      end

      class AdministratorRotation < CredentialTransition
        alias CaseOpener = Proc(FabricInfo, UInt64, Session::SecureContext)

        ADMINISTRATOR_CAT_ID =                0xFFFF_u32
        ANCHOR_CAT_ID        =                0xFFFE_u32
        ANCHOR_SUBJECT_BASE  = 0xFFFF_FFFD_FFFE_0000_u64
        FAIL_SAFE_SECONDS    =                   900_u16
        CSR_NONCE_BYTES      =                        32

        getter target_node_id : UInt64

        def initialize(@client : Client, @im : ImClient,
                       @old_session : Session::SecureContext,
                       @peer : Socket::IPAddress, @target_node_id : UInt64,
                       @bootstrap : JointCommissioning::AnchorBootstrap,
                       @administrator_cat_version : UInt16,
                       @anchor_cat_version : UInt16,
                       @anchor_target : Bool = false,
                       @existing_fabric : Bool = false,
                       @existing_fabric_index : UInt8? = nil,
                       @case_opener : CaseOpener? = nil,
                       @crypto : Crypto::CryptoBase = Crypto::StandardCrypto.new)
          if @target_node_id == 0_u64 || @administrator_cat_version == 0_u16 ||
             @anchor_cat_version == 0_u16
            raise Matter::ConfigurationError.new("Invalid Anchor transfer Administrator identity or CAT version")
          end
          if @existing_fabric && @existing_fabric_index.nil?
            raise Matter::ConfigurationError.new("UpdateNOC requires the existing fabric index")
          end
        end

        # Returns the new FabricIndex assigned by the target Administrator.
        # A failed exchange tries to disarm the old CASE fail-safe. Failure to
        # disarm is logged; the original exception remains the recovery signal.
        def transition! : UInt8
          armed = false
          completed = false
          begin
            arm_fail_safe(FAIL_SAFE_SECONDS)
            armed = true
            nonce = @crypto.random_bytes(CSR_NONCE_BYTES)
            csr_response = @im.invoke(@old_session, @peer, 0_u16,
              Cluster::OperationalCredentials::CLUSTER_ID,
              Cluster::OperationalCredentials::CMD_CSR_REQUEST,
              Cluster::OperationalCredentials::Tlv::CsrRequest.new(nonce, @existing_fabric).to_slice)
            csr_fields = command_fields(csr_response, Cluster::OperationalCredentials::CMD_CSR_REQUEST_RESPONSE)
            csr_elements = Cluster::OperationalCredentials::CSRElements.from_slice(
              Cluster::OperationalCredentials::Tlv::CsrResponse.from_slice(csr_fields).nocsr_elements)
            public_key = CertificateUtil.extract_uncompressed_public_key_from_csr(csr_elements.csr)

            unless @existing_fabric
              root = @bootstrap.fabric.root_cert
              invoke_status!("AddTrustedRootCertificate",
                Cluster::OperationalCredentials::CLUSTER_ID,
                Cluster::OperationalCredentials::CMD_ADD_TRUSTED_ROOT_CERTIFICATE,
                Cluster::OperationalCredentials::Tlv::AddTrustedRootCertificateRequest.new(root).to_slice)
            end

            tags = [ADMINISTRATOR_CAT_ID << 16 | @administrator_cat_version.to_u32]
            tags << (ANCHOR_CAT_ID << 16 | @anchor_cat_version.to_u32) if @anchor_target
            noc = @bootstrap.issue_noc(@target_node_id, public_key, tags, @crypto)
            Crypto::MatterCertificate::Validation.verify_chain(noc,
              @bootstrap.fabric.intermediate_cert, @bootstrap.fabric.root_public_key, @bootstrap.fabric.root_cert)
            response = if @existing_fabric
                         @im.invoke(@old_session, @peer, 0_u16,
                           Cluster::OperationalCredentials::CLUSTER_ID,
                           Cluster::OperationalCredentials::CMD_UPDATE_NOC,
                           Cluster::OperationalCredentials::Tlv::UpdateNocRequest.new(
                             noc, @bootstrap.fabric.intermediate_cert).to_slice)
                       else
                         add_noc = Cluster::OperationalCredentials::Tlv::AddNocRequest.new(
                           noc, @bootstrap.fabric.intermediate_cert,
                           @bootstrap.fabric.ipk_value,
                           controller_anchor_cat_subject,
                           @bootstrap.fabric.admin_vendor_id)
                         @im.invoke(@old_session, @peer, 0_u16,
                           Cluster::OperationalCredentials::CLUSTER_ID,
                           Cluster::OperationalCredentials::CMD_ADD_NOC, add_noc.to_slice)
                       end
            result = Cluster::OperationalCredentials::Tlv::TlvNocResponse.from_slice(
              command_fields(response, Cluster::OperationalCredentials::CMD_ADD_NOC_RESPONSE))
            unless result.status_code.ok? && (new_index = result.fabric_index)
              raise Matter::CommissioningError.new("Anchor transfer #{@existing_fabric ? "UpdateNOC" : "AddNOC"} failed: #{result.status_code}")
            end

            new_session = if opener = @case_opener
                            opener.call(@bootstrap.fabric, @target_node_id)
                          else
                            Pairing::CasePairing.new(@crypto).pair(@client, @peer,
                              @bootstrap.fabric, peer_node_id: @target_node_id)
                          end
            complete_response = @im.invoke(new_session, @peer, 0_u16,
              Cluster::GeneralCommissioning::CLUSTER_ID,
              Cluster::GeneralCommissioning::CMD_COMMISSIONING_COMPLETE)
            complete_fields = command_fields(complete_response,
              Cluster::GeneralCommissioning::CMD_COMMISSIONING_COMPLETE_RESPONSE)
            complete = Cluster::GeneralCommissioning::CommissioningCompleteResponse.from_slice(complete_fields)
            unless complete.error_code.ok?
              raise Matter::CommissioningError.new("CommissioningComplete failed: #{complete.error_code} #{complete.debug_text}")
            end
            completed = true
            new_index
          rescue ex
            if armed && !completed
              begin
                arm_fail_safe(0_u16)
              rescue error
                Log.error(exception: error) { "Could not disarm Administrator fail-safe after Anchor transfer error" }
              end
            end
            raise ex
          end
        end

        private def arm_fail_safe(seconds : UInt16) : Nil
          response = @im.invoke(@old_session, @peer, 0_u16,
            Cluster::GeneralCommissioning::CLUSTER_ID,
            Cluster::GeneralCommissioning::CMD_ARM_FAIL_SAFE,
            Cluster::GeneralCommissioning::ArmFailSafeRequest.new(seconds, 0_u64).to_slice)
          fields = command_fields(response, Cluster::GeneralCommissioning::CMD_ARM_FAIL_SAFE_RESPONSE)
          outcome = Cluster::GeneralCommissioning::ArmFailSafeResponse.from_slice(fields)
          unless outcome.error_code.ok?
            raise Matter::CommissioningError.new("ArmFailSafe failed: #{outcome.error_code}")
          end
        end

        # AddNOC grants the controller that will open the first CASE session
        # on the new fabric. Its actual Anchor CAT may still have the prior
        # version while the target JFA NOC is already issued with the next
        # version. Using the target's future version would deny the controller
        # access before it can send CommissioningComplete.
        private def controller_anchor_cat_subject : UInt64
          subjects = Crypto::MatterCertificate.subject_ids_from_tlv(@bootstrap.fabric.controller_noc)
          mask = 0xFFFF_FFFF_FFFF_0000_u64
          subjects.find { |subject| (subject & mask) == ANCHOR_SUBJECT_BASE } ||
            raise Matter::ConfigurationError.new("Anchor controller NOC lacks Anchor CAT")
        end

        private def invoke_status!(name : String, cluster_id : UInt32,
                                   command_id : UInt32, fields : Bytes) : Nil
          response = @im.invoke(@old_session, @peer, 0_u16,
            cluster_id, command_id, fields)
          invoke_response_ok!(response, name)
        end

        private def invoke_response_ok!(response : InteractionModel::InvokeResponseMessage,
                                        name : String) : Nil
          unless response.invoke_responses.any? { |entry| entry.command_status.try(&.status.status) == InteractionModel::StatusCode::Success.value }
            raise Matter::CommissioningError.new("#{name} failed")
          end
        end

        private def command_fields(response : InteractionModel::InvokeResponseMessage,
                                   command_id : UInt32) : Bytes
          command = response.invoke_responses.find do |entry|
            entry.command_data.try(&.command_path.command) == command_id
          end.try(&.command_data)
          fields = command.try(&.command_fields)
          unless fields
            if status = response.invoke_responses.find(&.command_status).try(&.command_status)
              raise Matter::CommissioningError.new("Anchor transfer command #{command_id} failed with IM status #{status.status.status}")
            end
            raise Matter::ProtocolError.new("Missing Anchor transfer response for command #{command_id}")
          end
          fields.to_slice
        end
      end

      # B's step-5 handoff for one other JFA. This runs only after B has
      # advertised its Anchor role and A acknowledged TransferAnchorComplete.
      # The target verifies B's Anchor CAT, Anchor ICAC and VID during Announce;
      # its AddICAC remains provisional until CommissioningComplete succeeds.
      class AdministratorFollowUp
        enum Stage : UInt8
          Ready
          CrossSigning
          CrossSigned
          RemovingOld
          Completed
        end

        struct Journal
          include Storage::Record

          getter target_node_id : UInt64
          property stage : Stage
          property pending_icac : Bytes?

          def initialize(@target_node_id : UInt64, @stage : Stage = Stage::Ready,
                         @pending_icac : Bytes? = nil)
          end
        end

        alias SaveJournal = Proc(Journal, Nil)
        alias CommitIcac = Proc(UInt64, Bytes, Nil)
        alias CaseOpener = Proc(FabricInfo, UInt64, Session::SecureContext)
        alias EndpointResolver = Proc(ImClient, Session::SecureContext, Socket::IPAddress, UInt16)

        FAIL_SAFE_SECONDS = 900_u16

        getter journal : Journal
        @journal : Journal

        def initialize(@client : Client, @im : ImClient,
                       @peer : Socket::IPAddress, @target_node_id : UInt64,
                       @new_anchor_fabric : FabricInfo,
                       @old_fabric_id : UInt64, @old_root_public_key : Bytes,
                       @administrator_endpoint : UInt16,
                       @peer_icac_public_key : Bytes, @icac_id : UInt64,
                       @save : SaveJournal,
                       journal : Journal? = nil,
                       @consent : Proc(Bool) = -> { false },
                       @case_opener : CaseOpener? = nil,
                       @endpoint_resolver : EndpointResolver? = nil,
                       @on_committed_icac : CommitIcac? = nil,
                       @crypto : Crypto::CryptoBase = Crypto::StandardCrypto.new)
          @journal = journal || Journal.new(@target_node_id)
          unless @journal.target_node_id == @target_node_id && @target_node_id != 0_u64 && @icac_id != 0_u64
            raise Matter::ConfigurationError.new("Invalid Anchor follow-up identity")
          end
          if @new_anchor_fabric.fabric_id == @old_fabric_id &&
             @new_anchor_fabric.root_public_key == @old_root_public_key
            raise Matter::ConfigurationError.new("New and old Anchor fabrics are the same")
          end
        end

        def run : Nil
          return if @journal.stage.completed?
          unless @consent.call
            raise Matter::CommissioningError.new("Anchor participant follow-up requires local user consent")
          end
          if @journal.stage.cross_signing?
            raise Matter::CommissioningError.new("Anchor follow-up for 0x#{@target_node_id.to_s(16)} needs reconciliation")
          end
          session = if opener = @case_opener
                      opener.call(@new_anchor_fabric, @target_node_id)
                    else
                      Pairing::CasePairing.new(@crypto).pair(@client, @peer,
                        @new_anchor_fabric, peer_node_id: @target_node_id)
                    end
          endpoint = if resolver = @endpoint_resolver
                       resolver.call(@im, session, @peer)
                     else
                       JointCommissioning.discover_administrator_endpoint(@im, session, @peer)
                     end
          unless endpoint == @administrator_endpoint
            raise Matter::AuthenticationError.new("Target JFA endpoint changed during Anchor follow-up")
          end
          old_index = find_old_fabric(session)
          unless old_index
            if @journal.stage.ready? || @journal.stage.cross_signing?
              raise Matter::CommissioningError.new("Old Anchor fabric is absent before participant cross-signing")
            end
            advance(Stage::Completed)
            return
          end
          if @journal.stage.ready?
            advance(Stage::CrossSigning)
            arm_fail_safe(session, FAIL_SAFE_SECONDS)
            begin
              response = @im.invoke(session, @peer, @administrator_endpoint,
                Administrator::CLUSTER_ID,
                Administrator::CMD_ANNOUNCE_JOINT_FABRIC_ADMINISTRATOR,
                Administrator::AnnounceJointFabricAdministratorRequest.new(@administrator_endpoint).to_slice)
              JointCommissioning.assert_status_success(response)
              icac = JointCommissioning.exchange_icac(@im, session, @peer,
                @administrator_endpoint, @new_anchor_fabric.root_cert,
                @new_anchor_fabric.certificate_authority_key,
                @new_anchor_fabric.fabric_id, @peer_icac_public_key, @icac_id, @crypto)
              @journal.pending_icac = icac
              @save.call(@journal)
              response = @im.invoke(session, @peer, 0_u16,
                Cluster::GeneralCommissioning::CLUSTER_ID,
                Cluster::GeneralCommissioning::CMD_COMMISSIONING_COMPLETE)
              assert_commissioning_complete!(response)
              @on_committed_icac.try(&.call(@target_node_id, icac))
            rescue ex
              begin
                arm_fail_safe(session, 0_u16)
              rescue error
                Log.error(exception: error) do
                  "Could not disarm participant fail-safe after cross-sign error"
                end
              end
              raise ex
            end
            @journal.pending_icac = nil
            advance(Stage::CrossSigned)
          end
          if @journal.stage.cross_signed? || @journal.stage.removing_old?
            advance(Stage::RemovingOld) unless @journal.stage.removing_old?
            remove_old_fabric(session, old_index)
            advance(Stage::Completed)
          end
        end

        # An uncertain AddICAC/CommissioningComplete requires inspecting the
        # target's fail-safe and JFA state. RemoveFabric is safe to retry after
        # checking the old fabric still exists, so it can resume automatically.
        def reconcile_cross_sign!(committed : Bool) : Nil
          unless @journal.stage.cross_signing?
            raise Matter::ConfigurationError.new("No uncertain cross-sign exchange to reconcile")
          end
          if committed
            if callback = @on_committed_icac
              icac = @journal.pending_icac ||
                     raise Matter::CommissioningError.new("Cross-sign reconciliation lacks the persisted ICAC")
              JointCommissioning.validate_cross_signed_icac(icac, @new_anchor_fabric,
                @peer_icac_public_key, @icac_id)
              callback.call(@target_node_id, icac)
            end
            @journal.pending_icac = nil
            advance(Stage::CrossSigned)
          else
            @journal.pending_icac = nil
            advance(Stage::Ready)
          end
        end

        private def find_old_fabric(session : Session::SecureContext) : UInt8?
          report = @im.read_attribute(session, @peer, 0_u16,
            Cluster::OperationalCredentials::CLUSTER_ID,
            Cluster::OperationalCredentials::ATTR_FABRICS,
            fabric_filtered: false)
          data = report.attribute_reports.try(&.find(&.attribute_data)).try(&.attribute_data).try(&.data)
          raise Matter::ProtocolError.new("Participant Fabrics read omitted data") unless data
          descriptors = Array(Cluster::OperationalCredentials::Tlv::FabricDescriptor).from_tlv(data.to_slice)
          old = descriptors.find do |descriptor|
            descriptor.fabric_id == @old_fabric_id &&
              descriptor.root_public_key == @old_root_public_key
          end
          old.try(&.fabric_index)
        end

        private def remove_old_fabric(session : Session::SecureContext, index : UInt8) : Nil
          response = @im.invoke(session, @peer, 0_u16,
            Cluster::OperationalCredentials::CLUSTER_ID,
            Cluster::OperationalCredentials::CMD_REMOVE_FABRIC,
            Cluster::OperationalCredentials::Tlv::RemoveFabricRequest.new(index).to_slice)
          fields = response.invoke_responses.find(&.command_data).try(&.command_data).try(&.command_fields)
          raise Matter::ProtocolError.new("RemoveFabric returned no response") unless fields
          result = Cluster::OperationalCredentials::Tlv::TlvNocResponse.from_slice(fields.to_slice)
          unless result.status_code.ok?
            raise Matter::CommissioningError.new("RemoveFabric of old Anchor failed: #{result.status_code}")
          end
        end

        private def arm_fail_safe(session : Session::SecureContext, seconds : UInt16) : Nil
          response = @im.invoke(session, @peer, 0_u16,
            Cluster::GeneralCommissioning::CLUSTER_ID,
            Cluster::GeneralCommissioning::CMD_ARM_FAIL_SAFE,
            Cluster::GeneralCommissioning::ArmFailSafeRequest.new(seconds, 0_u64).to_slice)
          fields = response.invoke_responses.find(&.command_data).try(&.command_data).try(&.command_fields)
          raise Matter::ProtocolError.new("ArmFailSafe returned no response") unless fields
          outcome = Cluster::GeneralCommissioning::ArmFailSafeResponse.from_slice(fields.to_slice)
          raise Matter::CommissioningError.new("ArmFailSafe failed: #{outcome.error_code}") unless outcome.error_code.ok?
        end

        private def assert_commissioning_complete!(response : InteractionModel::InvokeResponseMessage) : Nil
          response.invoke_responses.each do |entry|
            if status = entry.command_status
              raise Matter::CommissioningError.new("CommissioningComplete failed: IM status #{status.status.status}")
            end
            command = entry.command_data
            next unless command && command.command_path.command == Cluster::GeneralCommissioning::CMD_COMMISSIONING_COMPLETE_RESPONSE
            fields = command.command_fields || raise Matter::ProtocolError.new("CommissioningComplete response omitted fields")
            result = Cluster::GeneralCommissioning::CommissioningCompleteResponse.from_slice(fields.to_slice)
            unless result.error_code.ok?
              raise Matter::CommissioningError.new("CommissioningComplete failed: #{result.error_code} #{result.debug_text}")
            end
            return
          end
          raise Matter::ProtocolError.new("CommissioningComplete response omitted command data")
        end

        private def advance(stage : Stage) : Nil
          @journal.stage = stage
          @save.call(@journal)
        end
      end

      # Concrete candidate migration: copy the frozen remote Datastore, add
      # the new root and Administrator CAT NOC to every other JFA, then issue
      # the candidate an Anchor CAT NOC and publish its new role. Persist and
      # advertise callbacks are mandatory application boundaries.
      class RotationMigration < Migration
        alias Operation = Proc(Nil)
        FIRST_IPK_EPOCH_START_TIME = 1_u64

        @rotation_journal : Journal? = nil
        @save_rotation_journal : Proc(Journal, Nil)? = nil

        def initialize(@old_anchor_im : ImClient,
                       @old_anchor_session : Session::SecureContext,
                       @old_anchor_peer : Socket::IPAddress,
                       @old_anchor_endpoint : UInt16,
                       @candidate_store : Datastore,
                       @candidate_node_id : UInt64,
                       @bootstrap : JointCommissioning::AnchorBootstrap,
                       @other_administrators : Array(CredentialTransition),
                       @candidate_rotation : CredentialTransition,
                       @persist : Operation,
                       @advertise : Operation,
                       @administrator_cat_version : UInt16? = nil,
                       @anchor_cat_version : UInt16? = nil,
                       @finalize_administrators : Operation? = nil,
                       @candidate_old_node_id : UInt64? = nil,
                       @candidate_administrator : Datastore::DatastoreAdministratorInformationEntryStruct? = nil)
          raise Matter::ConfigurationError.new("Candidate Node ID must be nonzero") if @candidate_node_id == 0_u64
        end

        def copy_datastore! : Nil
          source = Snapshot.read_remote(@old_anchor_im, @old_anchor_session,
            @old_anchor_peer, @old_anchor_endpoint)
          Snapshot.copy!(source, @candidate_store, @candidate_node_id,
            @candidate_old_node_id, @candidate_administrator)
          validate_participants!
          # The snapshot belongs to the old Anchor fabric. The promoted Anchor
          # must advertise the IPK of its newly bootstrapped fabric after restart.
          keys = @bootstrap.fabric.ipk_epoch_keys
          ipk_key_set = Datastore::DatastoreGroupKeySetStruct.new(0_u16,
            Datastore::DatastoreGroupKeySecurityPolicyEnum::TrustFirst,
            keys[0].dup, FIRST_IPK_EPOCH_START_TIME,
            keys[1]?.try(&.dup), keys[1]? ? FIRST_IPK_EPOCH_START_TIME + 1_u64 : nil,
            keys[2]?.try(&.dup), keys[2]? ? FIRST_IPK_EPOCH_START_TIME + 2_u64 : nil)
          key_sets = @candidate_store.group_key_set_list
          if index = key_sets.index(&.group_key_set_id.==(0_u16))
            key_sets[index] = ipk_key_set
          else
            key_sets.unshift(ipk_key_set)
          end
          @candidate_store.group_key_set_list = key_sets
          @candidate_store.group_list = @candidate_store.group_list.map do |group|
            group.group_cat_version = @administrator_cat_version if group.group_cat == 0xFFFF_u16 && @administrator_cat_version
            group.group_cat_version = @anchor_cat_version if group.group_cat == 0xFFFE_u16 && @anchor_cat_version
            group
          end
          @persist.call
        end

        def preflight! : Nil
          if !@other_administrators.empty? && @finalize_administrators.nil?
            raise Matter::ConfigurationError.new("Anchor transfer requires Administrator follow-up for cross-signing and old-fabric removal")
          end
        end

        def bind_journal!(journal : Journal, save : Proc(Journal, Nil)) : Nil
          @rotation_journal = journal
          @save_rotation_journal = save
        end

        def rotation_complete? : Bool
          journal = @rotation_journal || return false
          validate_participants!
          expected = @other_administrators.compact_map(&.target_node_id).sort!
          actual = journal.rotated_administrator_node_ids.sort
          actual == expected
        end

        def rotate_credentials! : Nil
          validate_participants!
          old_root = @candidate_store.anchor_root_ca
          if old_root.empty? ||
             Crypto::MatterCertificate.public_key_from_tlv(old_root) == @bootstrap.fabric.root_public_key
            raise Matter::CommissioningError.new("Anchor transfer requires a distinct new trusted root")
          end
          unless @candidate_store.status.state == Datastore::DatastoreStateEnum::Committed &&
                 @candidate_store.anchor_node_id == @candidate_node_id
            raise Matter::CommissioningError.new("Candidate Datastore copy is not committed")
          end
          @other_administrators.each do |administrator|
            node_id = administrator.target_node_id ||
                      raise Matter::ConfigurationError.new("Anchor transfer requires identified Administrator rotations")
            if journal = @rotation_journal
              next if journal.rotated_administrator_node_ids.includes?(node_id)
              if journal.active_rotation_node_id
                raise Matter::CommissioningError.new("Administrator rotation needs reconciliation before retry")
              end
              journal.active_rotation_node_id = node_id
              save_rotation_journal.call(journal)
            end
            administrator.transition!
            @persist.call
            if journal = @rotation_journal
              journal.rotated_administrator_node_ids << node_id
              journal.active_rotation_node_id = nil
              save_rotation_journal.call(journal)
            end
          end
        end

        def promote_candidate! : Nil
          @candidate_rotation.transition!
          @candidate_store.anchor_root_ca = @bootstrap.fabric.root_cert.dup
          @candidate_store.anchor_node_id = @candidate_node_id
          @candidate_store.anchor_vendor_id = @bootstrap.fabric.admin_vendor_id
          @persist.call
          @advertise.call
        end

        def follow_up_administrators! : Nil
          validate_participants!
          if @other_administrators.empty?
            @finalize_administrators.try(&.call)
          else
            callback = @finalize_administrators ||
                       raise Matter::ConfigurationError.new("Anchor transfer Administrator follow-up is unavailable")
            callback.call
          end
        end

        private def validate_participants! : Nil
          unless @candidate_rotation.target_node_id == @candidate_node_id
            raise Matter::ConfigurationError.new("Anchor transfer candidate rotation targets the wrong Administrator")
          end
          administrators = @candidate_store.admin_list.map(&.node_id)
          unless administrators.count(@candidate_node_id) == 1 && administrators.uniq.size == administrators.size
            raise Matter::ConfigurationError.new("Transferred Datastore must contain one candidate Anchor and unique Administrator Node IDs")
          end
          expected = administrators.reject(&.==(@candidate_node_id)).sort!
          actual_ids = @other_administrators.map(&.target_node_id)
          if actual_ids.any?(Nil)
            raise Matter::ConfigurationError.new("Anchor transfer requires identified Administrator rotations")
          end
          actual = actual_ids.compact.sort!
          unless actual == expected
            raise Matter::ConfigurationError.new("Anchor transfer rotations must cover every other Datastore Administrator")
          end
        end

        private def save_rotation_journal : Proc(Journal, Nil)
          @save_rotation_journal || raise Matter::ConfigurationError.new("Anchor transfer rotation journal is unbound")
        end
      end

      class Workflow
        alias SaveJournal = Proc(Journal, Nil)
        alias Consent = Proc(Bool)

        getter journal : Journal

        def initialize(@source : Datastore, @port : Port, @migration : Migration,
                       @consent : Consent, @save : SaveJournal,
                       @journal : Journal)
          raise Matter::ConfigurationError.new("Anchor transfer requires a candidate Node ID") if @journal.candidate_node_id == 0_u64
          @migration.bind_journal!(@journal, @save)
        end

        # The source snapshot must come from a fresh authenticated read. A
        # CommitFailed entry is allowed by 12.2.6; Pending and DeletePending
        # forbid transfer even if the aggregate Status is stale.
        def preflight! : Nil
          if @source.status.state != Datastore::DatastoreStateEnum::Committed || pending_entries?
            raise Matter::CommissioningError.new("Anchor Datastore has pending entries")
          end
          @migration.preflight!
          raise Matter::CommissioningError.new("Candidate user did not consent to Anchor transfer") unless @consent.call
        end

        def run : Nil
          if in_progress?(@journal.stage)
            raise Matter::CommissioningError.new("Anchor transfer stage #{@journal.stage} needs reconciliation before retry")
          end
          return if @journal.stage.completed?

          if @journal.stage.ready?
            preflight!
            advance(Stage::Requesting)
            status = @port.request
            unless status.ok?
              advance(Stage::Ready)
              raise Matter::CommissioningError.new("TransferAnchorRequest refused: #{status}")
            end
            advance(Stage::Requested)
          end
          if @journal.stage.requested?
            advance(Stage::Copying)
            @migration.copy_datastore!
            advance(Stage::Copied)
          end
          if @journal.stage.copied?
            advance(Stage::Rotating)
            @migration.rotate_credentials!
            advance(Stage::Rotated)
          end
          if @journal.stage.rotated?
            advance(Stage::Promoting)
            @migration.promote_candidate!
            advance(Stage::Promoted)
          end
          if @journal.stage.promoted?
            advance(Stage::Completing)
            @port.complete
            advance(Stage::Transferred)
          end
          if @journal.stage.transferred? || @journal.stage.following_up?
            advance(Stage::FollowingUp) unless @journal.stage.following_up?
            @migration.follow_up_administrators!
            advance(Stage::Completed)
          end
        end

        # The application must first inspect the old and new Anchors and prove
        # the interrupted stage either finished or did not run. Only a stable
        # state is accepted for the next run.
        def reconcile!(stable_stage : Stage) : Nil
          if @journal.active_rotation_node_id
            raise Matter::CommissioningError.new("Administrator rotation needs reconciliation before transfer stage reconciliation")
          end
          if @journal.stage.rotating? && stable_stage.rotated? && !@migration.rotation_complete?
            raise Matter::CommissioningError.new("Cannot complete Anchor transfer rotation while Administrators remain unrotated")
          end
          valid = case @journal.stage
                  when Stage::Requesting  then stable_stage.in?(Stage::Ready, Stage::Requested)
                  when Stage::Copying     then stable_stage.in?(Stage::Requested, Stage::Copied)
                  when Stage::Rotating    then stable_stage.in?(Stage::Copied, Stage::Rotated)
                  when Stage::Promoting   then stable_stage.in?(Stage::Rotated, Stage::Promoted)
                  when Stage::Completing  then stable_stage.in?(Stage::Promoted, Stage::Transferred)
                  when Stage::FollowingUp then stable_stage.in?(Stage::Transferred, Stage::Completed)
                  else                         false
                  end
          unless valid
            raise Matter::ConfigurationError.new("Invalid Anchor transfer reconciliation")
          end
          advance(stable_stage)
        end

        # A lost TransferAnchorRequest response is resolved from a fresh CASE
        # read of the old Anchor's Datastore. A frozen store also requires a
        # trusted witness naming the requester: another Administrator could
        # have frozen it concurrently. Never resend to a frozen store.
        def reconcile_request!(remote_state : Datastore::DatastoreStateEnum,
                               witnessed_requester_node_id : UInt64? = nil) : Nil
          @journal = self.class.reconcile_request_journal!(@journal, remote_state, @save,
            witnessed_requester_node_id)
        end

        # Use this variant when the old CASE session and migration objects no
        # longer exist, after the application verifies an external witness.
        def self.reconcile_request_journal!(journal : Journal,
                                            remote_state : Datastore::DatastoreStateEnum,
                                            save : SaveJournal,
                                            witnessed_requester_node_id : UInt64? = nil) : Journal
          unless journal.stage.requesting?
            raise Matter::ConfigurationError.new("Anchor transfer is not awaiting request reconciliation")
          end
          stable_stage = case remote_state
                         when Datastore::DatastoreStateEnum::DeletePending
                           unless witnessed_requester_node_id == journal.candidate_node_id
                             raise Matter::AuthenticationError.new("Frozen Anchor Datastore lacks a matching transfer requester witness")
                           end
                           Stage::Requested
                         when Datastore::DatastoreStateEnum::Committed then Stage::Ready
                         else
                           raise Matter::CommissioningError.new("Old Anchor Datastore cannot reconcile TransferAnchorRequest")
                         end
          journal.stage = stable_stage
          save.call(journal)
          journal
        end

        # An inactive old Datastore cannot be read after Complete. Accept only
        # a fresh host-authenticated witness of the exact old and new roles.
        # A missing or mismatched witness leaves the Completing journal intact.
        def self.reconcile_completion_journal!(journal : Journal,
                                               witness : CompletionWitness,
                                               save : SaveJournal,
                                               expected_nonce : String,
                                               old_anchor_node_id : UInt64,
                                               old_fabric_id : UInt64,
                                               old_root_public_key : Bytes,
                                               new_anchor_node_id : UInt64) : Journal
          unless journal.stage.completing?
            raise Matter::ConfigurationError.new("Anchor transfer is not awaiting completion reconciliation")
          end
          raise Matter::AuthenticationError.new("Old Anchor completion witness has no nonce") if expected_nonce.empty?
          unless witness.nonce == expected_nonce &&
                 witness.transfer_complete? &&
                 witness.old_anchor_node_id == old_anchor_node_id &&
                 witness.old_fabric_id == old_fabric_id &&
                 witness.old_root_public_key == old_root_public_key &&
                 witness.requester_node_id == journal.candidate_node_id &&
                 witness.new_anchor_node_id == new_anchor_node_id &&
                 old_anchor_node_id != 0_u64 && new_anchor_node_id != 0_u64
            raise Matter::AuthenticationError.new("Old Anchor completion witness does not match the pending transfer")
          end
          journal.stage = Stage::Transferred
          begin
            save.call(journal)
          rescue ex
            journal.stage = Stage::Completing
            raise ex
          end
          journal
        end

        # Resolve a credential rotation only after inspecting the peer's NOC
        # and CAT. A completed rotation is never repeated on resume.
        def reconcile_rotation!(node_id : UInt64, completed : Bool) : Nil
          unless @journal.stage.rotating? && @journal.active_rotation_node_id == node_id
            raise Matter::ConfigurationError.new("Invalid Administrator rotation reconciliation")
          end
          if completed && !@journal.rotated_administrator_node_ids.includes?(node_id)
            @journal.rotated_administrator_node_ids << node_id
          end
          @journal.active_rotation_node_id = nil
          @save.call(@journal)
        end

        private def advance(stage : Stage) : Nil
          @journal.stage = stage
          @save.call(@journal)
        end

        private def in_progress?(stage : Stage) : Bool
          stage.in?(Stage::Requesting, Stage::Copying, Stage::Rotating,
            Stage::Promoting, Stage::Completing)
        end

        private def pending_entries? : Bool
          pending = ->(status : Datastore::DatastoreStatusEntryStruct) {
            status.state.in?(Datastore::DatastoreStateEnum::Pending, Datastore::DatastoreStateEnum::DeletePending)
          }
          @source.node_list.any? { |entry| pending.call(entry.commissioning_status_entry) } ||
            @source.node_key_set_list.any? { |entry| pending.call(entry.status_entry) } ||
            @source.endpoint_group_id_list.any? { |entry| pending.call(entry.status_entry) } ||
            @source.endpoint_binding_list.any? { |entry| pending.call(entry.status_entry) } ||
            @source.node_acl_list.any? { |entry| pending.call(entry.status_entry) }
        end
      end
    end
  end
end
