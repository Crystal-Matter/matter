require "../cluster/joint_fabric_datastore"
require "../cluster/general_commissioning"
require "../cluster/operational_credentials"
require "./im_client"
require "./vid_verification"

module Matter
  module Controller
    # Matter 1.6 Core 12.2.7 ordering for consented Administrator removal.
    # Each external operation is journaled before execution. An interrupted
    # operation needs inspection before it can be marked complete and resumed.
    module AdministratorRemoval
      alias Datastore = Cluster::JointFabricDatastore

      enum Stage : UInt8
        Ready
        RemovingFabric
        FabricRemoved
        RemovingDatastore
        DatastoreRemoved
        RotatingAnchor
        AnchorRotated
        RotatingParticipant
        Completed
      end

      struct Journal
        include Storage::Record

        getter outgoing_node_id : UInt64
        property stage : Stage
        property active_node_id : UInt64?
        property rotated_nodes : Array(UInt64)
        property administrator_cat_version : UInt16?
        property fabric_id : UInt64?
        property root_public_key : Bytes?
        property anchor_node_id : UInt64?
        property outgoing_admin_entry : Bytes?

        def initialize(@outgoing_node_id : UInt64, @stage : Stage = Stage::Ready,
                       @active_node_id : UInt64? = nil,
                       @rotated_nodes : Array(UInt64) = [] of UInt64,
                       @administrator_cat_version : UInt16? = nil,
                       @fabric_id : UInt64? = nil,
                       @root_public_key : Bytes? = nil,
                       @anchor_node_id : UInt64? = nil,
                       @outgoing_admin_entry : Bytes? = nil)
        end
      end

      abstract class Port
        abstract def remove_outgoing_fabric! : Nil
        abstract def remove_datastore_admin! : Nil
        abstract def rotate_anchor! : Nil
        abstract def rotate_participant!(node_id : UInt64) : Nil
      end

      # The caller supplies authenticated CASE and credential rotation
      # operations. This adapter performs the first two wire/local commands.
      class ImPort < Port
        alias Rotation = Proc(UInt64, Nil)
        alias Persist = Proc(Nil)

        def initialize(@im : ImClient, @session : Session::SecureContext?,
                       @peer : Socket::IPAddress?, @old_fabric_id : UInt64,
                       @old_root_public_key : Bytes, @outgoing_node_id : UInt64,
                       @datastore : Datastore, @persist : Persist,
                       @rotate_anchor : Persist, @rotate_participant : Rotation)
        end

        def remove_outgoing_fabric! : Nil
          session = @session || raise Matter::ConfigurationError.new("Outgoing Administrator CASE session is unavailable")
          unless session.case_session? && session.peer_node_id.try(&.id) == @outgoing_node_id
            raise Matter::AuthenticationError.new("Outgoing Administrator CASE peer differs from selected Node ID")
          end
          peer = @peer || raise Matter::ConfigurationError.new("Outgoing Administrator peer is unavailable")
          index = outgoing_fabric_index
          response = @im.invoke(session, peer, 0_u16,
            Cluster::OperationalCredentials::CLUSTER_ID,
            Cluster::OperationalCredentials::CMD_REMOVE_FABRIC,
            Cluster::OperationalCredentials::Tlv::RemoveFabricRequest.new(index).to_slice)
          fields = response.invoke_responses.find(&.command_data).try(&.command_data).try(&.command_fields)
          raise Matter::ProtocolError.new("RemoveFabric omitted response") unless fields
          result = Cluster::OperationalCredentials::Tlv::TlvNocResponse.from_slice(fields.to_slice)
          unless result.status_code.ok?
            raise Matter::CommissioningError.new("Outgoing Administrator RemoveFabric failed: #{result.status_code}")
          end
          # CredentialService#remove_fabric invokes fabric_forgotten to erase
          # the outgoing Administrator's fabric-scoped data on success.
        end

        def remove_datastore_admin! : Nil
          outcome = @datastore.remove_admin(Datastore::RemoveAdminRequest.new(@outgoing_node_id))
          unless outcome.success? || outcome.status == InteractionModel::StatusCode::NotFound
            raise Matter::CommissioningError.new("Datastore RemoveAdmin failed: #{outcome}")
          end
          @persist.call
        end

        def rotate_anchor! : Nil
          @rotate_anchor.call
        end

        def rotate_participant!(node_id : UInt64) : Nil
          @rotate_participant.call(node_id)
        end

        private def outgoing_fabric_index : UInt8
          session = @session || raise Matter::ConfigurationError.new("Outgoing Administrator CASE session is unavailable")
          peer = @peer || raise Matter::ConfigurationError.new("Outgoing Administrator peer is unavailable")
          report = @im.read_attribute(session, peer, 0_u16,
            Cluster::OperationalCredentials::CLUSTER_ID,
            Cluster::OperationalCredentials::ATTR_FABRICS,
            fabric_filtered: false)
          data = report.attribute_reports.try(&.find(&.attribute_data)).try(&.attribute_data).try(&.data)
          raise Matter::ProtocolError.new("Outgoing Fabrics read omitted data") unless data
          descriptors = Array(Cluster::OperationalCredentials::Tlv::FabricDescriptor).from_tlv(data.to_slice)
          descriptor = descriptors.find do |entry|
            entry.fabric_id == @old_fabric_id && entry.root_public_key == @old_root_public_key
          end
          descriptor.try(&.fabric_index) || raise Matter::AuthenticationError.new("Outgoing Administrator is not on the selected Joint Fabric")
        end
      end

      class Workflow
        alias SaveJournal = Proc(Journal, Nil)
        alias Consent = Proc(Bool)

        getter journal : Journal

        def initialize(@datastore : Datastore, @anchor_node_id : UInt64,
                       @remaining_nodes : Array(UInt64), @port : Port,
                       @anchor_consent : Consent, @outgoing_consent : Consent,
                       @save : SaveJournal, @journal : Journal)
          unless @journal.outgoing_node_id != 0_u64 && @anchor_node_id != 0_u64 &&
                 @journal.outgoing_node_id != @anchor_node_id
            raise Matter::ConfigurationError.new("Invalid outgoing Administrator identity")
          end
        end

        def run : Nil
          return if @journal.stage.completed?
          if @journal.stage.in?(Stage::RemovingFabric, Stage::RemovingDatastore,
               Stage::RotatingAnchor, Stage::RotatingParticipant)
            raise Matter::CommissioningError.new("Administrator removal stage #{@journal.stage} needs reconciliation")
          end
          if @journal.stage.ready?
            preflight!
            advance(Stage::RemovingFabric)
            @port.remove_outgoing_fabric!
            advance(Stage::FabricRemoved)
          end
          if @journal.stage.fabric_removed?
            administrator = @datastore.admin_list.find(&.node_id.==(@journal.outgoing_node_id)) ||
                            raise Matter::CommissioningError.new("Outgoing Administrator is absent before RemoveAdmin")
            @journal.outgoing_admin_entry = administrator.to_slice
            advance(Stage::RemovingDatastore)
            @port.remove_datastore_admin!
            advance(Stage::DatastoreRemoved)
          end
          if @journal.stage.datastore_removed?
            advance(Stage::RotatingAnchor)
            @port.rotate_anchor!
            advance(Stage::AnchorRotated)
          end
          if @journal.stage.anchor_rotated?
            @remaining_nodes.each do |node_id|
              next if @journal.rotated_nodes.includes?(node_id)
              @journal.active_node_id = node_id
              advance(Stage::RotatingParticipant)
              @port.rotate_participant!(node_id)
              @journal.rotated_nodes << node_id
              @journal.active_node_id = nil
              advance(Stage::AnchorRotated)
            end
            advance(Stage::Completed)
          end
        end

        def preflight! : Nil
          unless @anchor_consent.call && @outgoing_consent.call
            raise Matter::CommissioningError.new("Administrator removal requires both parties' consent")
          end
          unless @datastore.status.state.committed? &&
                 @datastore.admin_list.any?(&.node_id.==(@journal.outgoing_node_id))
            raise Matter::CommissioningError.new("Outgoing Administrator is absent or Datastore is uncommitted")
          end
          current_version = @datastore.group_list.find(&.group_cat.==(0xFFFF_u16)).try(&.group_cat_version)
          next_version = @journal.administrator_cat_version
          unless current_version && next_version && next_version > current_version
            raise Matter::ConfigurationError.new("Administrator removal requires a newer Administrator CAT version")
          end
          if @remaining_nodes.includes?(@journal.outgoing_node_id) ||
             @remaining_nodes.includes?(@anchor_node_id) ||
             @remaining_nodes.uniq.size != @remaining_nodes.size
            raise Matter::ConfigurationError.new("Invalid remaining Administrator list")
          end
          expected_nodes = @datastore.admin_list.map(&.node_id).reject do |node_id|
            node_id == @anchor_node_id || node_id == @journal.outgoing_node_id
          end
          unless @remaining_nodes.sort == expected_nodes.uniq.sort! &&
                 expected_nodes.size == expected_nodes.uniq.size
            raise Matter::ConfigurationError.new("Remaining Administrators differ from Datastore AdminList")
          end
        end

        # The caller must inspect the peer's fabric state, Datastore, or NOC
        # before resolving an uncertain external operation.
        def reconcile!(stable_stage : Stage, rotated_node_id : UInt64? = nil,
                       participant_completed : Bool? = nil) : Nil
          @journal = self.class.reconcile_journal!(@journal, stable_stage, @save,
            rotated_node_id: rotated_node_id, participant_completed: participant_completed)
        end

        # Reconcile a persisted journal after out-of-band inspection, even
        # when the old CASE session and its Port are no longer available.
        def self.reconcile_journal!(journal : Journal, stable_stage : Stage, save : SaveJournal,
                                    rotated_node_id : UInt64? = nil,
                                    participant_completed : Bool? = nil) : Journal
          valid = case journal.stage
                  when Stage::RemovingFabric      then stable_stage.in?(Stage::Ready, Stage::FabricRemoved)
                  when Stage::RemovingDatastore   then stable_stage.in?(Stage::FabricRemoved, Stage::DatastoreRemoved)
                  when Stage::RotatingAnchor      then stable_stage.in?(Stage::DatastoreRemoved, Stage::AnchorRotated)
                  when Stage::RotatingParticipant then stable_stage == Stage::AnchorRotated && rotated_node_id == journal.active_node_id && !participant_completed.nil?
                  else                                 false
                  end
          raise Matter::ConfigurationError.new("Invalid Administrator removal reconciliation") unless valid
          if node_id = rotated_node_id
            if participant_completed
              journal.rotated_nodes << node_id unless journal.rotated_nodes.includes?(node_id)
            end
            journal.active_node_id = nil
          end
          journal.stage = stable_stage
          save.call(journal)
          journal
        end

        # The Anchor can resolve a lost local RemoveAdmin acknowledgement from
        # its restored, durably saved Datastore. It must not infer success from
        # the journal alone or rerun an operation with an uncertain outcome.
        def self.reconcile_datastore_removed!(journal : Journal, datastore : Datastore,
                                              save : SaveJournal) : Journal
          unless journal.stage.removing_datastore? && journal.outgoing_node_id != 0_u64
            raise Matter::ConfigurationError.new("Administrator removal is not awaiting Datastore reconciliation")
          end
          unless datastore.status.state.committed?
            raise Matter::CommissioningError.new("Anchor Datastore is not committed")
          end
          if datastore.admin_list.any?(&.node_id.==(journal.outgoing_node_id))
            raise Matter::CommissioningError.new("Anchor Datastore still lists outgoing Administrator")
          end
          reconcile_journal!(journal, Stage::DatastoreRemoved, save)
        end

        # A persisted RemovingDatastore journal can be rewound only when the
        # restored Anchor Datastore proves that RemoveAdmin had no effect.
        def self.reconcile_datastore_no_effect!(journal : Journal, datastore : Datastore,
                                                save : SaveJournal) : Journal
          unless journal.stage.removing_datastore? && journal.outgoing_node_id != 0_u64 &&
                 journal.fabric_id && journal.root_public_key && journal.anchor_node_id
            raise Matter::ConfigurationError.new("Administrator removal is not awaiting bound Datastore reconciliation")
          end
          unless datastore.anchor_node_id == journal.anchor_node_id
            raise Matter::AuthenticationError.new("Removal Datastore belongs to another Anchor")
          end
          unless datastore.status.state.committed?
            raise Matter::CommissioningError.new("Anchor Datastore is not committed")
          end
          matching_admins = datastore.admin_list.select(&.node_id.==(journal.outgoing_node_id))
          unless matching_admins.size == 1
            raise Matter::CommissioningError.new("Outgoing Administrator is not uniquely present")
          end
          target_version = journal.administrator_cat_version
          current_version = datastore.group_list.find(&.group_cat.==(0xFFFF_u16)).try(&.group_cat_version)
          unless target_version && target_version > 0_u16 && current_version == target_version - 1_u16 &&
                 journal.outgoing_admin_entry == matching_admins.first.to_slice &&
                 journal.rotated_nodes.empty? && journal.active_node_id.nil?
            raise Matter::CommissioningError.new("Anchor Datastore differs from the pre-removal snapshot")
          end
          reconcile_journal!(journal, Stage::FabricRemoved, save)
        end

        private def advance(stage : Stage) : Nil
          @journal.stage = stage
          @save.call(@journal)
        end
      end

      # Resolve a lost rotation acknowledgement only after the target proves
      # possession of the newly installed NOC on a fresh CASE session. The
      # caller supplies a unique 32-byte challenge and a locally trusted root.
      # A matching NOC can still be provisional: CommissioningComplete must
      # either durably commit it or report that no fail-safe remains armed.
      # An old NOC is inconclusive while a fail-safe may still be armed.
      module RotationInspection
        extend self

        ADMINISTRATOR_CAT_PREFIX = 0xFFFF_FFFD_FFFF_0000_u64
        ANCHOR_CAT_PREFIX        = 0xFFFF_FFFD_FFFE_0000_u64

        def verify_completed!(im : ImClient, session : Session::SecureContext,
                              peer : Socket::IPAddress, root_certificate : Bytes,
                              fabric_id : UInt64, root_public_key : Bytes,
                              node_id : UInt64, administrator_cat_version : UInt16,
                              challenge : Bytes, anchor_cat_version : UInt16? = nil) : Nil
          verify_current_noc!(im, session, peer, root_certificate, fabric_id,
            root_public_key, node_id, administrator_cat_version, challenge, anchor_cat_version)
          result = im.invoke(session: session, peer: peer, endpoint_id: 0_u16,
            cluster_id: Cluster::GeneralCommissioning::CLUSTER_ID,
            command_id: Cluster::GeneralCommissioning::CMD_COMMISSIONING_COMPLETE)
          command = result.invoke_responses.find do |entry|
            entry.command_data.try(&.command_path.command) ==
              Cluster::GeneralCommissioning::CMD_COMMISSIONING_COMPLETE_RESPONSE
          end.try(&.command_data)
          fields = command.try(&.command_fields).try(&.to_slice) ||
                   raise Matter::ProtocolError.new("Rotation CommissioningComplete response missing")
          completion = Cluster::GeneralCommissioning::CommissioningCompleteResponse.from_slice(fields)
          unless completion.error_code.ok? || completion.error_code == ::Matter::Commissioning::ErrorCode::NoFailSafe
            raise Matter::CommissioningError.new("Rotation CommissioningComplete failed: #{completion.error_code}")
          end
          # Confirm the same NOC/CAT is still installed after completion. A
          # fresh challenge prevents a cached pre-commit response from being
          # accepted as post-commit proof.
          final_challenge = Crypto::StandardCrypto.new.random_bytes(VidVerification::CHALLENGE_SIZE)
          verify_current_noc!(im, session, peer, root_certificate, fabric_id,
            root_public_key, node_id, administrator_cat_version, final_challenge, anchor_cat_version)
        end

        private def verify_current_noc!(im : ImClient, session : Session::SecureContext,
                                        peer : Socket::IPAddress, root_certificate : Bytes,
                                        fabric_id : UInt64, root_public_key : Bytes,
                                        node_id : UInt64, administrator_cat_version : UInt16,
                                        challenge : Bytes, anchor_cat_version : UInt16? = nil) : Nil
          unless session.case_session? && session.peer_node_id.try(&.id) == node_id
            raise Matter::AuthenticationError.new("Rotation CASE peer differs from journaled Node ID")
          end
          unless administrator_cat_version > 0_u16 && challenge.size == VidVerification::CHALLENGE_SIZE
            raise Matter::ConfigurationError.new("Rotation proof requires CAT version and 32-byte challenge")
          end

          # Find the fabric by its full identity before invoking the signed
          # proof. Never use a fabric index supplied by an untrusted peer.
          report = im.read_attribute(session, peer, 0_u16,
            Cluster::OperationalCredentials::CLUSTER_ID,
            Cluster::OperationalCredentials::ATTR_FABRICS, fabric_filtered: false)
          data = report.attribute_reports.try(&.find(&.attribute_data)).try(&.attribute_data).try(&.data)
          raise Matter::ProtocolError.new("Rotation Fabrics read omitted data") unless data
          descriptors = Array(Cluster::OperationalCredentials::Tlv::FabricDescriptor).from_tlv(data.to_slice)
          matches = descriptors.select do |item|
            item.fabric_id == fabric_id && item.root_public_key == root_public_key && item.node_id == node_id
          end
          unless matches.size == 1
            raise Matter::AuthenticationError.new("Rotation target has no unique journaled fabric identity")
          end
          descriptor = matches.first
          nocs = read_list(Cluster::OperationalCredentials::Tlv::NOC, im, session, peer,
            Cluster::OperationalCredentials::ATTR_NOCS)
          roots = read_list(Bytes, im, session, peer,
            Cluster::OperationalCredentials::ATTR_TRUSTED_ROOT_CERTIFICATES)
          matching_nocs = nocs.select(&.fabric_index.==(descriptor.fabric_index))
          unless matching_nocs.size == 1 && roots.includes?(root_certificate)
            raise Matter::AuthenticationError.new("Rotation target has no unique NOC or trusted root")
          end
          noc = matching_nocs.first
          if noc.icac && noc.vvsc
            raise Matter::AuthenticationError.new("Rotation NOC entry contains both ICAC and VVSC")
          end
          unless Crypto::MatterCertificate.public_key_from_tlv(root_certificate) == root_public_key
            raise Matter::AuthenticationError.new("Rotation root certificate differs from journaled root key")
          end
          Crypto::MatterCertificate::Validation.verify_signature(root_certificate, root_public_key)
          Crypto::MatterCertificate::Validation.verify_chain(noc.noc, noc.icac, root_public_key, root_certificate)
          certificate = Crypto::MatterCertificate.from_slice(noc.noc)
          unless certificate.fabric_id == fabric_id && certificate.node_id == node_id
            raise Matter::AuthenticationError.new("Rotation NOC differs from journaled fabric identity")
          end
          request = Cluster::OperationalCredentials::Tlv::SignVIDVerificationRequest.new(
            descriptor.fabric_index, challenge)
          response_message = im.invoke(session: session, peer: peer, endpoint_id: 0_u16,
            cluster_id: Cluster::OperationalCredentials::CLUSTER_ID,
            command_id: Cluster::OperationalCredentials::CMD_SIGN_VID_VERIFICATION_REQUEST,
            fields: request.to_slice)
          command = response_message.invoke_responses.find do |entry|
            entry.command_data.try(&.command_path.command) ==
              Cluster::OperationalCredentials::CMD_SIGN_VID_VERIFICATION_REQUEST_RESPONSE
          end.try(&.command_data)
          fields = command.try(&.command_fields).try(&.to_slice) ||
                   raise Matter::ProtocolError.new("Rotation signature response missing")
          response = Cluster::OperationalCredentials::Tlv::SignVIDVerificationResponse.from_slice(fields)
          unless response.fabric_index == descriptor.fabric_index &&
                 response.fabric_binding_version == VidVerification::VERSION
            raise Matter::AuthenticationError.new("Rotation signature identifies another fabric or version")
          end
          signed = IO::Memory.new
          signed.write_byte VidVerification::VERSION
          signed.write challenge
          attestation_challenge = session.attestation_challenge ||
                                  raise Matter::AuthenticationError.new("Rotation CASE attestation challenge is absent")
          signed.write attestation_challenge
          signed.write_byte descriptor.fabric_index
          signed.write VidVerification.binding_message(descriptor)
          if statement = descriptor.vid_verification_statement
            signed.write statement
          end
          noc_key = Crypto::Key.new(Crypto::KeyType::EC, Crypto::CurveType::P256)
          noc_key.public_bits = certificate.ec_public_key
          Crypto::StandardCrypto.new.verify_ecdsa(noc_key, signed.to_slice, response.signature)

          subjects = Crypto::MatterCertificate.subject_ids_from_tlv(noc.noc)
          versions = subjects.compact_map do |subject|
            if subject & 0xFFFF_FFFF_FFFF_0000_u64 == ADMINISTRATOR_CAT_PREFIX
              (subject & 0xFFFF_u64).to_u16
            end
          end
          unless versions == [administrator_cat_version]
            raise Matter::AuthenticationError.new("Rotation NOC does not carry the journaled Administrator CAT version")
          end
          if anchor_cat_version
            anchor_versions = subjects.compact_map do |subject|
              if subject & 0xFFFF_FFFF_FFFF_0000_u64 == ANCHOR_CAT_PREFIX
                (subject & 0xFFFF_u64).to_u16
              end
            end
            unless anchor_versions == [anchor_cat_version]
              raise Matter::AuthenticationError.new("Rotation NOC does not carry the selected Anchor CAT version")
            end
          end
        end

        private def read_list(type : T.class, im : ImClient, session : Session::SecureContext,
                              peer : Socket::IPAddress, attribute_id : UInt32) : Array(T) forall T
          report = im.read_attribute(session, peer, 0_u16,
            Cluster::OperationalCredentials::CLUSTER_ID, attribute_id, fabric_filtered: false)
          data = report.attribute_reports.try(&.find(&.attribute_data)).try(&.attribute_data).try(&.data)
          raise Matter::ProtocolError.new("Rotation attribute #{attribute_id} omitted data") unless data
          Array(T).from_tlv(data.to_slice)
        end
      end
    end
  end
end
