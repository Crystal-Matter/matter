require "../cluster/joint_fabric_datastore"
require "../cluster/operational_credentials"
require "./im_client"

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

        def initialize(@outgoing_node_id : UInt64, @stage : Stage = Stage::Ready,
                       @active_node_id : UInt64? = nil,
                       @rotated_nodes : Array(UInt64) = [] of UInt64,
                       @administrator_cat_version : UInt16? = nil)
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

        private def advance(stage : Stage) : Nil
          @journal.stage = stage
          @save.call(@journal)
        end
      end
    end
  end
end
