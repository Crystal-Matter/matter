require "../node"
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
        property prior_administrator_cat_version : UInt16?
        property fabric_id : UInt64?
        property root_public_key : Bytes?
        property anchor_node_id : UInt64?
        property outgoing_admin_entry : Bytes?
        property remaining_admin_entries : Array(Bytes)?
        property anchor_pre_rotation_noc : Bytes?
        property participant_pre_rotation_credential : Bytes?
        property participant_recovery_lease_id : String?

        def initialize(@outgoing_node_id : UInt64, @stage : Stage = Stage::Ready,
                       @active_node_id : UInt64? = nil,
                       @rotated_nodes : Array(UInt64) = [] of UInt64,
                       @administrator_cat_version : UInt16? = nil,
                       @prior_administrator_cat_version : UInt16? = nil,
                       @fabric_id : UInt64? = nil,
                       @root_public_key : Bytes? = nil,
                       @anchor_node_id : UInt64? = nil,
                       @outgoing_admin_entry : Bytes? = nil,
                       @remaining_admin_entries : Array(Bytes)? = nil,
                       @anchor_pre_rotation_noc : Bytes? = nil,
                       @participant_pre_rotation_credential : Bytes? = nil,
                       @participant_recovery_lease_id : String? = nil)
        end

        # A save callback may fail after touching its input. Every mutable
        # field must be detached before a proposed transition is passed to it.
        def detached_copy : Journal
          Journal.new(@outgoing_node_id, @stage,
            active_node_id: @active_node_id,
            rotated_nodes: @rotated_nodes.dup,
            administrator_cat_version: @administrator_cat_version,
            prior_administrator_cat_version: @prior_administrator_cat_version,
            fabric_id: @fabric_id,
            root_public_key: @root_public_key.try(&.dup),
            anchor_node_id: @anchor_node_id,
            outgoing_admin_entry: @outgoing_admin_entry.try(&.dup),
            remaining_admin_entries: @remaining_admin_entries.try { |entries| entries.map(&.dup) },
            anchor_pre_rotation_noc: @anchor_pre_rotation_noc.try(&.dup),
            participant_pre_rotation_credential: @participant_pre_rotation_credential.try(&.dup),
            participant_recovery_lease_id: @participant_recovery_lease_id)
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
          response = @im.invoke(session, peer, Node::ROOT_ENDPOINT_ID,
            Cluster::OperationalCredentials::CLUSTER_ID,
            Cluster::OperationalCredentials::CMD_REMOVE_FABRIC,
            Cluster::OperationalCredentials::Tlv::RemoveFabricRequest.new(index).to_slice)
          entry = ImClient.single_invoke_response!(response, "RemoveFabric")
          fields = entry.command_data.try do |command|
            command.command_fields if command.command_path.command == Cluster::OperationalCredentials::CMD_ADD_NOC_RESPONSE
          end
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
          report = @im.read_attribute(session, peer, Node::ROOT_ENDPOINT_ID,
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
        alias CaptureParticipantCredential = Proc(UInt64, Bytes)

        getter journal : Journal

        def initialize(@datastore : Datastore, @anchor_node_id : UInt64,
                       @remaining_nodes : Array(UInt64), @port : Port,
                       @anchor_consent : Consent, @outgoing_consent : Consent,
                       @save : SaveJournal, @journal : Journal,
                       @capture_participant_credential : CaptureParticipantCredential? = nil)
          unless @journal.outgoing_node_id != DataType::NodeId::UNSPECIFIED && @anchor_node_id != DataType::NodeId::UNSPECIFIED &&
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
          if @journal.stage.in?(Stage::DatastoreRemoved, Stage::AnchorRotated)
            verify_remaining_admins_after_restart!
          end
          if @journal.stage.ready?
            before_preflight = @journal.detached_copy
            begin
              preflight!
              advance(Stage::RemovingFabric)
            rescue ex
              @journal = before_preflight
              raise ex
            end
            @port.remove_outgoing_fabric!
            advance(Stage::FabricRemoved)
          end
          if @journal.stage.fabric_removed?
            verify_pre_removal_snapshot!
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
            if @journal.participant_recovery_lease_id
              raise Matter::CommissioningError.new("Participant recovery fence needs durable release before retry")
            end
            @remaining_nodes.each do |node_id|
              next if @journal.rotated_nodes.includes?(node_id)
              pending = @journal.detached_copy
              pending.participant_pre_rotation_credential = @capture_participant_credential.try(&.call(node_id))
              pending.active_node_id = node_id
              pending.stage = Stage::RotatingParticipant
              @save.call(pending)
              @journal = pending
              @port.rotate_participant!(node_id)
              completed = @journal.detached_copy
              completed.rotated_nodes << node_id
              completed.active_node_id = nil
              completed.participant_pre_rotation_credential = nil
              completed.participant_recovery_lease_id = nil
              completed.stage = Stage::AnchorRotated
              @save.call(completed)
              @journal = completed
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
          current_version = @datastore.group_list.find(&.group_cat.==(Cluster::JointFabricDatastore::ADMINISTRATOR_CAT)).try(&.group_cat_version)
          next_version = @journal.administrator_cat_version
          unless current_version && next_version && next_version > current_version
            raise Matter::ConfigurationError.new("Administrator removal requires a newer Administrator CAT version")
          end
          if prior_version = @journal.prior_administrator_cat_version
            unless prior_version == current_version
              raise Matter::CommissioningError.new("Administrator CAT changed since removal was prepared")
            end
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
          @journal.prior_administrator_cat_version = current_version
          record_pre_removal_snapshot!
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
          if !journal.stage.rotating_participant? && (rotated_node_id || !participant_completed.nil?)
            raise Matter::ConfigurationError.new("Invalid Administrator removal reconciliation")
          end
          valid = case journal.stage
                  when Stage::RemovingFabric      then stable_stage.in?(Stage::Ready, Stage::FabricRemoved)
                  when Stage::RemovingDatastore   then stable_stage.in?(Stage::FabricRemoved, Stage::DatastoreRemoved)
                  when Stage::RotatingAnchor      then stable_stage.in?(Stage::DatastoreRemoved, Stage::AnchorRotated)
                  when Stage::RotatingParticipant then stable_stage == Stage::AnchorRotated && rotated_node_id == journal.active_node_id && participant_completed == true
                  else                                 false
                  end
          raise Matter::ConfigurationError.new("Invalid Administrator removal reconciliation") unless valid
          updated = journal.detached_copy
          if node_id = rotated_node_id
            if participant_completed
              updated.rotated_nodes << node_id unless updated.rotated_nodes.includes?(node_id)
            end
            updated.active_node_id = nil
            updated.participant_pre_rotation_credential = nil
            updated.participant_recovery_lease_id = nil
          end
          updated.stage = stable_stage
          save.call(updated)
          updated
        end

        # The Anchor can resolve a lost local RemoveAdmin acknowledgement from
        # its restored, durably saved Datastore. It must not infer success from
        # the journal alone or rerun an operation with an uncertain outcome.
        def self.reconcile_datastore_removed!(journal : Journal, datastore : Datastore,
                                              expected_fabric_index : UInt8, save : SaveJournal) : Journal
          fabric_id = journal.fabric_id
          root_public_key = journal.root_public_key
          anchor_node_id = journal.anchor_node_id
          outgoing_admin_entry = journal.outgoing_admin_entry
          bound = journal.stage.removing_datastore? &&
                  DataType::NodeId.valid_joint_fabric?(journal.outgoing_node_id) &&
                  fabric_id && fabric_id != Fabric::RESERVED_FABRIC_ID &&
                  root_public_key && !root_public_key.empty? &&
                  anchor_node_id && DataType::NodeId.valid_joint_fabric?(anchor_node_id) &&
                  outgoing_admin_entry && !outgoing_admin_entry.empty?
          raise Matter::ConfigurationError.new("Administrator removal is not awaiting bound Datastore reconciliation") unless bound
          unless datastore.anchor_node_id == anchor_node_id
            raise Matter::AuthenticationError.new("Removal Datastore belongs to another Anchor")
          end
          unless datastore.joint_fabric_index == expected_fabric_index
            raise Matter::AuthenticationError.new("Removal Datastore belongs to another fabric index")
          end
          verify_anchor_root!(journal, datastore)
          unless datastore.status.state.committed?
            raise Matter::CommissioningError.new("Anchor Datastore is not committed")
          end
          if datastore.admin_list.any?(&.node_id.==(journal.outgoing_node_id))
            raise Matter::CommissioningError.new("Anchor Datastore still lists outgoing Administrator")
          end
          target_version = journal.administrator_cat_version
          prior_version = journal.prior_administrator_cat_version
          current_version = datastore.group_list.find(&.group_cat.==(Datastore::ADMINISTRATOR_CAT)).try(&.group_cat_version)
          unless prior_version && target_version && target_version > prior_version && current_version == prior_version &&
                 journal.rotated_nodes.empty? && journal.active_node_id.nil?
            raise Matter::CommissioningError.new("Anchor Datastore differs from the pre-rotation snapshot")
          end
          admin_ids = datastore.admin_list.map(&.node_id)
          unless admin_ids.count(anchor_node_id) == 1 &&
                 admin_ids.uniq.size == admin_ids.size &&
                 admin_ids.all? { |node_id| DataType::NodeId.valid_joint_fabric?(node_id) }
            raise Matter::CommissioningError.new("Anchor Datastore has an invalid remaining AdminList")
          end
          unless journal.remaining_admin_entries == datastore.admin_list.map(&.to_slice)
            raise Matter::CommissioningError.new("Anchor Datastore differs from the journaled remaining AdminList")
          end
          reconcile_journal!(journal, Stage::DatastoreRemoved, save)
        end

        # A persisted RemovingDatastore journal can be rewound only when the
        # restored Anchor Datastore proves that RemoveAdmin had no effect.
        def self.reconcile_datastore_no_effect!(journal : Journal, datastore : Datastore,
                                                expected_fabric_index : UInt8, save : SaveJournal) : Journal
          unless journal.stage.removing_datastore? && journal.outgoing_node_id != DataType::NodeId::UNSPECIFIED &&
                 journal.fabric_id && journal.root_public_key && journal.anchor_node_id
            raise Matter::ConfigurationError.new("Administrator removal is not awaiting bound Datastore reconciliation")
          end
          unless datastore.anchor_node_id == journal.anchor_node_id
            raise Matter::AuthenticationError.new("Removal Datastore belongs to another Anchor")
          end
          unless datastore.joint_fabric_index == expected_fabric_index
            raise Matter::AuthenticationError.new("Removal Datastore belongs to another fabric index")
          end
          verify_anchor_root!(journal, datastore)
          unless datastore.status.state.committed?
            raise Matter::CommissioningError.new("Anchor Datastore is not committed")
          end
          matching_admins = datastore.admin_list.select(&.node_id.==(journal.outgoing_node_id))
          unless matching_admins.size == 1
            raise Matter::CommissioningError.new("Outgoing Administrator is not uniquely present")
          end
          target_version = journal.administrator_cat_version
          prior_version = journal.prior_administrator_cat_version
          current_version = datastore.group_list.find(&.group_cat.==(Cluster::JointFabricDatastore::ADMINISTRATOR_CAT)).try(&.group_cat_version)
          unless prior_version && target_version && target_version > prior_version && current_version == prior_version &&
                 journal.outgoing_admin_entry == matching_admins.first.to_slice &&
                 journal.rotated_nodes.empty? && journal.active_node_id.nil?
            raise Matter::CommissioningError.new("Anchor Datastore differs from the pre-removal snapshot")
          end
          unless journal.remaining_admin_entries == datastore.admin_list.reject(&.node_id.==(journal.outgoing_node_id)).map(&.to_slice)
            raise Matter::CommissioningError.new("Anchor Datastore differs from the journaled remaining AdminList")
          end
          reconcile_journal!(journal, Stage::FabricRemoved, save)
        end

        # The caller must first prove, on a fresh CASE session, that the
        # Anchor still holds its exact durable old NOC and has no armed
        # fail-safe or pending credential journal. Datastore CAT/ACL updates
        # can already be durable when UpdateNOC had no effect. Keep those
        # updates and retry the idempotent local preparation and NOC rotation.
        def self.reconcile_anchor_rotation_no_effect!(journal : Journal, datastore : Datastore,
                                                      expected_fabric_index : UInt8, save : SaveJournal) : Journal
          unless journal.stage.rotating_anchor? &&
                 DataType::NodeId.valid_joint_fabric?(journal.outgoing_node_id) &&
                 journal.fabric_id && journal.fabric_id != Fabric::RESERVED_FABRIC_ID &&
                 journal.root_public_key && journal.root_public_key.as(Bytes).size > 0 &&
                 journal.anchor_node_id && DataType::NodeId.valid_joint_fabric?(journal.anchor_node_id.as(UInt64)) &&
                 journal.outgoing_admin_entry && journal.remaining_admin_entries &&
                 journal.anchor_pre_rotation_noc && journal.anchor_pre_rotation_noc.as(Bytes).size > 0
            raise Matter::ConfigurationError.new("Administrator removal is not awaiting bound Anchor rotation reconciliation")
          end
          unless datastore.anchor_node_id == journal.anchor_node_id &&
                 datastore.joint_fabric_index == expected_fabric_index
            raise Matter::AuthenticationError.new("Rotation Datastore belongs to another Anchor fabric")
          end
          verify_anchor_root!(journal, datastore)
          unless datastore.status.state.committed?
            raise Matter::CommissioningError.new("Anchor Datastore is not committed")
          end
          previous = journal.prior_administrator_cat_version
          target = journal.administrator_cat_version
          current = datastore.group_list.find(&.group_cat.==(Datastore::ADMINISTRATOR_CAT)).try(&.group_cat_version)
          unless previous && target && target > previous && current == target &&
                 journal.rotated_nodes.empty? && journal.active_node_id.nil?
            raise Matter::CommissioningError.new("Anchor Datastore CAT differs from the pending rotation")
          end
          admins = datastore.admin_list
          unless admins.map(&.to_slice) == journal.remaining_admin_entries &&
                 admins.none?(&.node_id.==(journal.outgoing_node_id)) &&
                 admins.count(&.node_id.==(journal.anchor_node_id)) == 1 &&
                 admins.map(&.node_id).uniq!.size == admins.size
            raise Matter::CommissioningError.new("Anchor Datastore AdminList differs from the pending rotation")
          end
          reconcile_journal!(journal, Stage::DatastoreRemoved, save)
        end

        # A trusted host must establish that the participant's old credential
        # is durable and its fail-safe and credential undo journal are clear.
        # The caller also verifies a fresh signed CASE proof of this exact
        # credential before calling this journal-only transition.
        def self.reconcile_participant_rotation_no_effect!(journal : Journal, datastore : Datastore,
                                                           expected_fabric_index : UInt8,
                                                           observed_credential : Bytes,
                                                           save : SaveJournal) : Journal
          target_node_id = journal.active_node_id
          snapshot = journal.participant_pre_rotation_credential
          unless journal.stage.rotating_participant? && target_node_id &&
                 DataType::NodeId.valid_joint_fabric?(target_node_id) &&
                 journal.fabric_id && journal.fabric_id != Fabric::RESERVED_FABRIC_ID &&
                 journal.root_public_key && journal.anchor_node_id &&
                 journal.prior_administrator_cat_version && journal.administrator_cat_version &&
                 journal.remaining_admin_entries && snapshot
            raise Matter::ConfigurationError.new("Administrator removal lacks a bound participant credential snapshot")
          end
          if snapshot.empty?
            raise Matter::ConfigurationError.new("Administrator removal has an empty participant credential snapshot")
          end
          unless snapshot == observed_credential
            raise Matter::AuthenticationError.new("Participant credential differs from pre-rotation journal")
          end
          unless datastore.status.state.committed? &&
                 datastore.joint_fabric_index == expected_fabric_index &&
                 datastore.anchor_node_id == journal.anchor_node_id
            raise Matter::AuthenticationError.new("Participant rotation Datastore belongs to another Anchor fabric")
          end
          verify_anchor_root!(journal, datastore)
          unless datastore.admin_list.map(&.to_slice) == journal.remaining_admin_entries
            raise Matter::CommissioningError.new("Participant rotation AdminList differs from frozen removal journal")
          end
          administrators = datastore.admin_list.map(&.node_id)
          participants = administrators.reject(&.==(journal.anchor_node_id))
          active_index = participants.index(target_node_id)
          unless active_index && administrators.count(target_node_id) == 1 &&
                 administrators.count(journal.anchor_node_id) == 1 &&
                 administrators.uniq.size == administrators.size &&
                 journal.rotated_nodes == participants.first(active_index) &&
                 datastore.admin_list.none?(&.node_id.==(journal.outgoing_node_id))
            raise Matter::CommissioningError.new("Participant rotation order differs from frozen removal journal")
          end
          previous = journal.prior_administrator_cat_version.as(UInt16)
          target = journal.administrator_cat_version.as(UInt16)
          current = datastore.group_list.find(&.group_cat.==(Datastore::ADMINISTRATOR_CAT)).try(&.group_cat_version)
          unless target > previous && current == target
            raise Matter::CommissioningError.new("Participant rotation CAT differs from frozen removal journal")
          end
          updated = journal.detached_copy
          updated.stage = Stage::AnchorRotated
          updated.active_node_id = nil
          updated.participant_pre_rotation_credential = nil unless updated.participant_recovery_lease_id
          save.call(updated)
          updated
        end

        private def self.verify_anchor_root!(journal : Journal, datastore : Datastore) : Nil
          root = datastore.anchor_root_ca
          Crypto::MatterCertificate::Validation.verify_root(root)
          unless Crypto::MatterCertificate.public_key_from_tlv(root) == journal.root_public_key
            raise Matter::AuthenticationError.new("Removal Datastore root differs from journaled fabric root")
          end
        end

        private def advance(stage : Stage) : Nil
          updated = @journal.detached_copy
          updated.stage = stage
          @save.call(updated)
          @journal = updated
        end

        private def record_pre_removal_snapshot! : Nil
          administrator = @datastore.admin_list.find(&.node_id.==(@journal.outgoing_node_id)) ||
                          raise Matter::CommissioningError.new("Outgoing Administrator is absent before removal")
          outgoing_entry = administrator.to_slice
          remaining_entries = @datastore.admin_list.reject(&.node_id.==(@journal.outgoing_node_id)).map(&.to_slice)
          if previous = @journal.outgoing_admin_entry
            unless previous == outgoing_entry
              raise Matter::CommissioningError.new("Outgoing Administrator changed since removal was prepared")
            end
          end
          if previous = @journal.remaining_admin_entries
            unless previous == remaining_entries
              raise Matter::CommissioningError.new("Anchor Datastore remaining AdminList changed during removal")
            end
          end
          @journal.outgoing_admin_entry = outgoing_entry
          @journal.remaining_admin_entries = remaining_entries
        end

        private def verify_pre_removal_snapshot! : Nil
          unless @datastore.status.state.committed?
            raise Matter::CommissioningError.new("Anchor Datastore is not committed before RemoveAdmin")
          end
          prior_version = @journal.prior_administrator_cat_version
          target_version = @journal.administrator_cat_version
          current_version = @datastore.group_list.find(&.group_cat.==(Datastore::ADMINISTRATOR_CAT)).try(&.group_cat_version)
          unless prior_version && target_version && target_version > prior_version && current_version == prior_version
            raise Matter::CommissioningError.new("Administrator CAT changed since removal was prepared")
          end
          administrator = @datastore.admin_list.find(&.node_id.==(@journal.outgoing_node_id)) ||
                          raise Matter::CommissioningError.new("Outgoing Administrator is absent before RemoveAdmin")
          unless @journal.outgoing_admin_entry == administrator.to_slice
            raise Matter::CommissioningError.new("Outgoing Administrator changed since removal was prepared")
          end
          remaining_entries = @datastore.admin_list.reject(&.node_id.==(@journal.outgoing_node_id)).map(&.to_slice)
          unless @journal.remaining_admin_entries == remaining_entries
            raise Matter::CommissioningError.new("Anchor Datastore remaining AdminList changed during removal")
          end
        end

        # A resumed removal must rotate exactly the Administrators captured
        # before RemoveAdmin. The host may have rebuilt @remaining_nodes from
        # a Datastore that changed while this workflow was stopped. Compare
        # entries in journaled list order: even a reorder is a concurrent
        # Datastore change that this removal has not reconciled.
        private def verify_remaining_admins_after_restart! : Nil
          expected_entries = @journal.remaining_admin_entries ||
                             raise Matter::CommissioningError.new("Administrator removal lacks the journaled remaining AdminList")
          unless @datastore.status.state.committed? &&
                 @datastore.admin_list.map(&.to_slice) == expected_entries
            raise Matter::CommissioningError.new("Administrator removal remaining AdminList changed after restart")
          end
          node_ids = @datastore.admin_list.map(&.node_id)
          expected_participants = node_ids.reject(&.==(@anchor_node_id))
          unless node_ids.count(@anchor_node_id) == 1 &&
                 node_ids.uniq.size == node_ids.size &&
                 @remaining_nodes.sort == expected_participants.sort
            raise Matter::CommissioningError.new("Administrator removal remaining participant set changed after restart")
          end
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

        # An old CAT alone does not prove no effect: an armed fail-safe can
        # install a new NOC later. The local caller must separately establish
        # that fail-safe and credential-journal state are both clear, and must
        # pass the exact pre-rotation NOC saved in the removal journal and
        # checked against its durable fabric record.
        def verify_no_effect!(im : ImClient, session : Session::SecureContext,
                              peer : Socket::IPAddress, root_certificate : Bytes,
                              fabric_id : UInt64, root_public_key : Bytes,
                              node_id : UInt64, prior_administrator_cat_version : UInt16,
                              challenge : Bytes, durable_old_noc : Bytes,
                              anchor_cat_version : UInt16? = nil) : Nil
          observed = verify_current_credential!(im, session, peer, root_certificate, fabric_id,
            root_public_key, node_id, prior_administrator_cat_version, challenge, anchor_cat_version)
          unless observed.noc == durable_old_noc
            raise Matter::AuthenticationError.new("Rotation target does not hold the durable NOC")
          end
        end

        def capture_pre_rotation_credential!(im : ImClient, session : Session::SecureContext,
                                             peer : Socket::IPAddress, root_certificate : Bytes,
                                             fabric_id : UInt64, root_public_key : Bytes,
                                             node_id : UInt64, prior_administrator_cat_version : UInt16,
                                             challenge : Bytes) : Bytes
          verify_current_credential!(im, session, peer, root_certificate, fabric_id,
            root_public_key, node_id, prior_administrator_cat_version, challenge).to_slice
        end

        def verify_participant_no_effect!(im : ImClient, session : Session::SecureContext,
                                          peer : Socket::IPAddress, root_certificate : Bytes,
                                          fabric_id : UInt64, root_public_key : Bytes,
                                          node_id : UInt64, prior_administrator_cat_version : UInt16,
                                          challenge : Bytes, credential : Bytes) : Nil
          observed = verify_current_credential!(im, session, peer, root_certificate, fabric_id,
            root_public_key, node_id, prior_administrator_cat_version, challenge)
          unless observed.to_slice == credential
            raise Matter::AuthenticationError.new("Participant CASE credential differs from journaled pre-rotation credential")
          end
        end

        def verify_completed!(im : ImClient, session : Session::SecureContext,
                              peer : Socket::IPAddress, root_certificate : Bytes,
                              fabric_id : UInt64, root_public_key : Bytes,
                              node_id : UInt64, administrator_cat_version : UInt16,
                              challenge : Bytes, anchor_cat_version : UInt16? = nil,
                              exact_cats : Array(DataType::CaseAuthenticatedTag)? = nil) : Nil
          before_noc = verify_current_credential!(im, session, peer, root_certificate, fabric_id,
            root_public_key, node_id, administrator_cat_version, challenge, anchor_cat_version,
            exact_cats)
          result = im.invoke(session: session, peer: peer, endpoint_id: Node::ROOT_ENDPOINT_ID,
            cluster_id: Cluster::GeneralCommissioning::CLUSTER_ID,
            command_id: Cluster::GeneralCommissioning::CMD_COMMISSIONING_COMPLETE)
          ImClient.single_invoke_response!(result, "Rotation CommissioningComplete")
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
          after_noc = verify_current_credential!(im, session, peer, root_certificate, fabric_id,
            root_public_key, node_id, administrator_cat_version, final_challenge, anchor_cat_version,
            exact_cats)
          unless after_noc.to_slice == before_noc.to_slice
            raise Matter::AuthenticationError.new("Rotation NOC changed during completion")
          end
          nil
        end

        private def verify_current_credential!(im : ImClient, session : Session::SecureContext,
                                               peer : Socket::IPAddress, root_certificate : Bytes,
                                               fabric_id : UInt64, root_public_key : Bytes,
                                               node_id : UInt64, administrator_cat_version : UInt16,
                                               challenge : Bytes, anchor_cat_version : UInt16? = nil,
                                               exact_cats : Array(DataType::CaseAuthenticatedTag)? = nil) : Cluster::OperationalCredentials::Tlv::NOC
          unless session.case_session? && session.peer_node_id.try(&.id) == node_id
            raise Matter::AuthenticationError.new("Rotation CASE peer differs from journaled Node ID")
          end
          unless administrator_cat_version > 0_u16 && challenge.size == VidVerification::CHALLENGE_SIZE
            raise Matter::ConfigurationError.new("Rotation proof requires CAT version and 32-byte challenge")
          end

          # Find the fabric by its full identity before invoking the signed
          # proof. Never use a fabric index supplied by an untrusted peer.
          report = im.read_attribute(session, peer, Node::ROOT_ENDPOINT_ID,
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
          response_message = im.invoke(session: session, peer: peer, endpoint_id: Node::ROOT_ENDPOINT_ID,
            cluster_id: Cluster::OperationalCredentials::CLUSTER_ID,
            command_id: Cluster::OperationalCredentials::CMD_SIGN_VID_VERIFICATION_REQUEST,
            fields: request.to_slice)
          ImClient.single_invoke_response!(response_message, "Rotation SignVIDVerificationRequest")
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
          if expected = exact_cats
            observed_cats = subjects.compact_map do |subject|
              DataType::NodeId.case_authenticated_tag_from_subject?(subject)
            end.sort_by!(&.value)
            unless observed_cats == expected.sort_by(&.value)
              raise Matter::AuthenticationError.new("Rotation NOC carries unexpected CATs")
            end
          end
          versions = subjects.compact_map do |subject|
            cat = DataType::NodeId.case_authenticated_tag_from_subject?(subject)
            cat.version if cat && cat.identity_value == Cluster::JointFabricDatastore::ADMINISTRATOR_CAT
          end
          unless versions == [administrator_cat_version]
            raise Matter::AuthenticationError.new("Rotation NOC does not carry the journaled Administrator CAT version")
          end
          if anchor_cat_version
            anchor_versions = subjects.compact_map do |subject|
              cat = DataType::NodeId.case_authenticated_tag_from_subject?(subject)
              cat.version if cat && cat.identity_value == Cluster::JointFabricDatastore::ANCHOR_CAT
            end
            unless anchor_versions == [anchor_cat_version]
              raise Matter::AuthenticationError.new("Rotation NOC does not carry the selected Anchor CAT version")
            end
          end
          noc
        end

        private def read_list(type : T.class, im : ImClient, session : Session::SecureContext,
                              peer : Socket::IPAddress, attribute_id : UInt32) : Array(T) forall T
          report = im.read_attribute(session, peer, Node::ROOT_ENDPOINT_ID,
            Cluster::OperationalCredentials::CLUSTER_ID, attribute_id, fabric_filtered: false)
          data = report.attribute_reports.try(&.find(&.attribute_data)).try(&.attribute_data).try(&.data)
          raise Matter::ProtocolError.new("Rotation attribute #{attribute_id} omitted data") unless data
          Array(T).from_tlv(data.to_slice)
        end
      end
    end
  end
end
