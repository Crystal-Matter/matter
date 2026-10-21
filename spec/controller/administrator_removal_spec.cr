require "../spec_helper"
require "../../src/matter/controller/administrator_removal"

private alias RemovalStage = Matter::Controller::AdministratorRemoval::Stage

private def removal_datastore : Matter::Cluster::JointFabricDatastore
  datastore = Matter::Cluster::JointFabricDatastore.new(Matter::DataType::EndpointNumber.new(1_u16))
  datastore.anchor_node_id = 0x100_u64
  datastore.admin_list = [
    Matter::Cluster::JointFabricDatastore::DatastoreAdministratorInformationEntryStruct.new(
      0x300_u64, "Outgoing", 0xFFF2_u16, Bytes[1]),
    Matter::Cluster::JointFabricDatastore::DatastoreAdministratorInformationEntryStruct.new(
      0x200_u64, "Remaining", 0xFFF2_u16, Bytes[2]),
  ]
  datastore.group_list = [Matter::Cluster::JointFabricDatastore::DatastoreGroupInformationEntryStruct.new(
    1_u64, "Administrators", nil, 0xFFFF_u16, 1_u16,
    Matter::Cluster::JointFabricDatastore::DatastoreAccessControlEntryPrivilegeEnum::Administer)]
  datastore.status = Matter::Cluster::JointFabricDatastore::DatastoreStatusEntryStruct.new(
    Matter::Cluster::JointFabricDatastore::DatastoreStateEnum::Committed, 0_u32, 0_u8)
  datastore
end

private class FakeAdministratorRemovalPort < Matter::Controller::AdministratorRemoval::Port
  getter events = [] of String
  property? interrupt_participant = false
  property fail_at : String?

  def remove_outgoing_fabric! : Nil
    @events << "RemoveFabric"
    raise Matter::TransportError.new("RemoveFabric interrupted") if @fail_at == "RemoveFabric"
  end

  def remove_datastore_admin! : Nil
    @events << "RemoveAdmin"
    raise Matter::TransportError.new("RemoveAdmin interrupted") if @fail_at == "RemoveAdmin"
  end

  def rotate_anchor! : Nil
    @events << "Anchor UpdateNOC"
    raise Matter::TransportError.new("Anchor UpdateNOC interrupted") if @fail_at == "Anchor UpdateNOC"
  end

  def rotate_participant!(node_id : UInt64) : Nil
    @events << "Participant #{node_id.to_s(16)} UpdateNOC"
    raise Matter::TransportError.new("participant interrupted") if interrupt_participant? || @fail_at == "Participant #{node_id.to_s(16)} UpdateNOC"
  end
end

describe Matter::Controller::AdministratorRemoval::Workflow do
  it "requires both consents and applies the Matter 1.6 removal order" do
    datastore = Matter::Cluster::JointFabricDatastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    datastore.anchor_node_id = 0x100_u64
    datastore.admin_list = [
      Matter::Cluster::JointFabricDatastore::DatastoreAdministratorInformationEntryStruct.new(
        0x300_u64, "Outgoing", 0xFFF2_u16, Bytes[1, 2, 3]),
      Matter::Cluster::JointFabricDatastore::DatastoreAdministratorInformationEntryStruct.new(
        0x200_u64, "Remaining B", 0xFFF2_u16, Bytes[4, 5, 6]),
      Matter::Cluster::JointFabricDatastore::DatastoreAdministratorInformationEntryStruct.new(
        0x400_u64, "Remaining C", 0xFFF2_u16, Bytes[7, 8, 9]),
    ]
    datastore.group_list = [Matter::Cluster::JointFabricDatastore::DatastoreGroupInformationEntryStruct.new(
      1_u64, "Administrators", nil, 0xFFFF_u16, 1_u16,
      Matter::Cluster::JointFabricDatastore::DatastoreAccessControlEntryPrivilegeEnum::Administer)]
    datastore.status = Matter::Cluster::JointFabricDatastore::DatastoreStatusEntryStruct.new(
      Matter::Cluster::JointFabricDatastore::DatastoreStateEnum::Committed, 0_u32, 0_u8)
    port = FakeAdministratorRemovalPort.new
    journal = Matter::Controller::AdministratorRemoval::Journal.new(0x300_u64,
      administrator_cat_version: 2_u16)
    saved = [] of Matter::Controller::AdministratorRemoval::Stage
    outgoing_consent = false
    workflow = Matter::Controller::AdministratorRemoval::Workflow.new(datastore, 0x100_u64, [0x200_u64, 0x400_u64], port,
      -> { true }, -> { outgoing_consent },
      ->(state : Matter::Controller::AdministratorRemoval::Journal) { saved << state.stage; nil }, journal)

    expect_raises(Matter::CommissioningError, /both parties/) { workflow.run }
    port.events.should be_empty
    outgoing_consent = true
    workflow.run

    port.events.should eq(["RemoveFabric", "RemoveAdmin", "Anchor UpdateNOC",
                           "Participant 200 UpdateNOC", "Participant 400 UpdateNOC"])
    workflow.journal.stage.should eq(Matter::Controller::AdministratorRemoval::Stage::Completed)
    workflow.journal.rotated_nodes.should eq([0x200_u64, 0x400_u64])
    workflow.run
    port.events.size.should eq(5)
    saved.first.should eq(Matter::Controller::AdministratorRemoval::Stage::RemovingFabric)
  end

  it "refuses to finish removal while a Datastore Administrator would retain the old CAT" do
    datastore = Matter::Cluster::JointFabricDatastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    datastore.admin_list = [
      Matter::Cluster::JointFabricDatastore::DatastoreAdministratorInformationEntryStruct.new(
        0x300_u64, "Outgoing", 0xFFF2_u16, Bytes[1]),
      Matter::Cluster::JointFabricDatastore::DatastoreAdministratorInformationEntryStruct.new(
        0x200_u64, "Remaining", 0xFFF2_u16, Bytes[2]),
    ]
    datastore.group_list = [Matter::Cluster::JointFabricDatastore::DatastoreGroupInformationEntryStruct.new(
      1_u64, "Administrators", nil, 0xFFFF_u16, 1_u16,
      Matter::Cluster::JointFabricDatastore::DatastoreAccessControlEntryPrivilegeEnum::Administer)]
    datastore.status = Matter::Cluster::JointFabricDatastore::DatastoreStatusEntryStruct.new(
      Matter::Cluster::JointFabricDatastore::DatastoreStateEnum::Committed, 0_u32, 0_u8)
    port = FakeAdministratorRemovalPort.new
    journal = Matter::Controller::AdministratorRemoval::Journal.new(0x300_u64,
      administrator_cat_version: 2_u16)
    workflow = Matter::Controller::AdministratorRemoval::Workflow.new(datastore, 0x100_u64,
      [] of UInt64, port, -> { true }, -> { true },
      ->(_state : Matter::Controller::AdministratorRemoval::Journal) { nil }, journal)

    expect_raises(Matter::ConfigurationError, /differ from Datastore AdminList/) { workflow.run }
    port.events.should be_empty
    workflow.journal.stage.should eq(Matter::Controller::AdministratorRemoval::Stage::Ready)
  end

  it "journals an uncertain participant rotation and resumes after reconciliation" do
    datastore = Matter::Cluster::JointFabricDatastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    journal = Matter::Controller::AdministratorRemoval::Journal.new(0x300_u64, Matter::Controller::AdministratorRemoval::Stage::AnchorRotated)
    port = FakeAdministratorRemovalPort.new
    port.interrupt_participant = true
    workflow = Matter::Controller::AdministratorRemoval::Workflow.new(datastore, 0x100_u64, [0x200_u64], port,
      -> { true }, -> { true }, ->(_state : Matter::Controller::AdministratorRemoval::Journal) { nil }, journal)

    expect_raises(Matter::TransportError, /interrupted/) { workflow.run }
    workflow.journal.stage.should eq(Matter::Controller::AdministratorRemoval::Stage::RotatingParticipant)
    workflow.journal.active_node_id.should eq(0x200_u64)
    expect_raises(Matter::CommissioningError, /reconciliation/) { workflow.run }
    workflow.reconcile!(Matter::Controller::AdministratorRemoval::Stage::AnchorRotated, 0x200_u64,
      participant_completed: true)
    workflow.run
    workflow.journal.stage.should eq(Matter::Controller::AdministratorRemoval::Stage::Completed)
    port.events.should eq(["Participant 200 UpdateNOC"])
  end

  it "reconciles a persisted RemoveFabric journal without an operational session" do
    journal = Matter::Controller::AdministratorRemoval::Journal.new(0x300_u64,
      Matter::Controller::AdministratorRemoval::Stage::RemovingFabric)
    saved = [] of Matter::Controller::AdministratorRemoval::Stage
    save = ->(state : Matter::Controller::AdministratorRemoval::Journal) { saved << state.stage; nil }

    journal = Matter::Controller::AdministratorRemoval::Workflow.reconcile_journal!(journal,
      Matter::Controller::AdministratorRemoval::Stage::FabricRemoved, save)
    journal.stage.should eq(Matter::Controller::AdministratorRemoval::Stage::FabricRemoved)
    saved.should eq([Matter::Controller::AdministratorRemoval::Stage::FabricRemoved])
    expect_raises(Matter::ConfigurationError, /Invalid Administrator removal reconciliation/) do
      Matter::Controller::AdministratorRemoval::Workflow.reconcile_journal!(journal,
        Matter::Controller::AdministratorRemoval::Stage::Completed, save)
    end
  end

  it "recovers each interrupted removal command from a persisted journal" do
    boundaries = {
      {"RemoveFabric", RemovalStage::Ready, RemovalStage::RemovingFabric, RemovalStage::FabricRemoved},
      {"RemoveAdmin", RemovalStage::FabricRemoved, RemovalStage::RemovingDatastore, RemovalStage::DatastoreRemoved},
      {"Anchor UpdateNOC", RemovalStage::DatastoreRemoved, RemovalStage::RotatingAnchor, RemovalStage::AnchorRotated},
      {"Participant 200 UpdateNOC", RemovalStage::AnchorRotated, RemovalStage::RotatingParticipant, RemovalStage::AnchorRotated},
    }
    boundaries.each do |command, before, uncertain, after|
      {false, true}.each do |completed|
        port = FakeAdministratorRemovalPort.new
        port.fail_at = command
        stored = Matter::Controller::AdministratorRemoval::Journal.new(
          0x300_u64, before, administrator_cat_version: 2_u16)
        save = ->(item : Matter::Controller::AdministratorRemoval::Journal) {
          stored = Matter::Controller::AdministratorRemoval::Journal.from_document(item.to_document)
          nil
        }
        workflow = Matter::Controller::AdministratorRemoval::Workflow.new(
          removal_datastore, 0x100_u64, [0x200_u64], port,
          -> { true }, -> { true }, save, stored)

        expect_raises(Matter::TransportError, /interrupted/) { workflow.run }
        stored.stage.should eq(uncertain)
        restarted = Matter::Controller::AdministratorRemoval::Workflow.new(
          removal_datastore, 0x100_u64, [0x200_u64], port,
          -> { true }, -> { true }, save,
          Matter::Controller::AdministratorRemoval::Journal.from_document(stored.to_document))
        expect_raises(Matter::CommissioningError, /reconciliation/) { restarted.run }
        if command.starts_with?("Participant")
          restarted.reconcile!(after, 0x200_u64, participant_completed: completed)
        else
          restarted.reconcile!(completed ? after : before)
        end
        port.fail_at = nil
        restarted.run

        restarted.journal.stage.should eq(RemovalStage::Completed)
        port.events.count(command).should eq(completed ? 1 : 2)
      end
    end
  end

  it "resumes from each persisted stable removal boundary without replaying earlier commands" do
    boundaries = {
      {RemovalStage::FabricRemoved, ["RemoveAdmin", "Anchor UpdateNOC", "Participant 200 UpdateNOC"]},
      {RemovalStage::DatastoreRemoved, ["Anchor UpdateNOC", "Participant 200 UpdateNOC"]},
      {RemovalStage::AnchorRotated, ["Participant 200 UpdateNOC"]},
      {RemovalStage::Completed, [] of String},
    }
    boundaries.each do |stable, expected|
      port = FakeAdministratorRemovalPort.new
      stored = Matter::Controller::AdministratorRemoval::Journal.new(
        0x300_u64, stable, administrator_cat_version: 2_u16)
      restarted = Matter::Controller::AdministratorRemoval::Workflow.new(
        removal_datastore, 0x100_u64, [0x200_u64], port,
        -> { true }, -> { true },
        ->(item : Matter::Controller::AdministratorRemoval::Journal) {
          stored = Matter::Controller::AdministratorRemoval::Journal.from_document(item.to_document)
          nil
        }, Matter::Controller::AdministratorRemoval::Journal.from_document(stored.to_document))

      restarted.run
      port.events.should eq(expected)
      stored.stage.should eq(RemovalStage::Completed)
      restarted.run
      port.events.should eq(expected)
    end
  end

  it "rejects a RemoveFabric session bound to another CASE peer" do
    session = Matter::Session::SecureContext.new(
      1_u16, 2_u16, Matter::Session::SessionType::Unicast,
      Bytes.new(16, 1_u8), Bytes.new(16, 2_u8),
      peer_node_id: Matter::DataType::NodeId.new(0x999_u64),
      case_session: true)
    client = Matter::Controller::Client.new
    port = Matter::Controller::AdministratorRemoval::ImPort.new(
      Matter::Controller::ImClient.new(client), session,
      Socket::IPAddress.new("127.0.0.1", 5540), 1_u64, Bytes[1], 0x300_u64,
      Matter::Cluster::JointFabricDatastore.new(Matter::DataType::EndpointNumber.new(1_u16)),
      -> { nil }, -> { nil }, ->(_node_id : UInt64) { nil })

    expect_raises(Matter::AuthenticationError, /CASE peer differs/) { port.remove_outgoing_fabric! }
  ensure
    client.try(&.close)
  end
end
