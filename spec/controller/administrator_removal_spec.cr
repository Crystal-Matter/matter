require "../spec_helper"
require "../../src/matter/controller/administrator_removal"

private class WrongRemovalResponseImClient < Matter::Controller::ImClient
  def read_attribute(session : Matter::Session::SecureContext, peer : Socket::IPAddress,
                     endpoint_id : UInt16, cluster_id : UInt32, attribute_id : UInt32,
                     fabric_filtered : Bool = true) : Matter::InteractionModel::ReportDataMessage
    descriptor = Matter::Cluster::OperationalCredentials::Tlv::FabricDescriptor.new(
      Bytes[1], 1_u16, 1_u64, 0x300_u64, "outgoing", 1_u8)
    path = Matter::InteractionModel::AttributePath.new(endpoint: endpoint_id, cluster: cluster_id,
      attribute: attribute_id)
    data = Matter::InteractionModel::AttributeDataIB.new(path: path,
      data: TLV::Any.from_slice([descriptor].to_tlv))
    Matter::InteractionModel::ReportDataMessage.new(attribute_reports: [
      Matter::InteractionModel::AttributeReportIB.new(attribute_data: data),
    ])
  end

  def invoke(session : Matter::Session::SecureContext, peer : Socket::IPAddress,
             endpoint_id : UInt16, cluster_id : UInt32, command_id : UInt32,
             fields : Bytes = Bytes.empty) : Matter::InteractionModel::InvokeResponseMessage
    response = Matter::Cluster::OperationalCredentials::Tlv::TlvNocResponse.new(
      Matter::Cluster::OperationalCredentials::Tlv::NodeOperationalCertificateStatus::Ok, 1_u8)
    path = Matter::InteractionModel::CommandPath.new(endpoint: endpoint_id, cluster: cluster_id,
      command: Matter::Cluster::OperationalCredentials::CMD_CSR_REQUEST_RESPONSE)
    data = Matter::InteractionModel::CommandDataIBTlv.new(path, TLV::Any.from_slice(response.to_slice))
    Matter::InteractionModel::InvokeResponseMessage.new(invoke_responses: [
      Matter::InteractionModel::InvokeResponseIB.new(command_data: data),
    ])
  end
end

private alias RemovalStage = Matter::Controller::AdministratorRemoval::Stage

private def removal_datastore : Matter::Cluster::JointFabricDatastore
  datastore = Matter::Cluster::JointFabricDatastore.new(Matter::DataType::EndpointNumber.new(1_u16))
  crypto = Matter::Crypto::StandardCrypto.new
  root_key = crypto.create_key_pair
  datastore.anchor_root_ca = Matter::Crypto::MatterCertificate::Builder.root(root_key, 1_u64, Bytes[1], crypto)
  datastore.anchor_node_id = 0x100_u64
  datastore.joint_fabric_index = 1_u8
  datastore.admin_list = [
    Matter::Cluster::JointFabricDatastore::DatastoreAdministratorInformationEntryStruct.new(
      0x100_u64, "Anchor", 0xFFF2_u16, Bytes[0]),
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

private def removal_root_public_key(datastore : Matter::Cluster::JointFabricDatastore) : Bytes
  Matter::Crypto::MatterCertificate.public_key_from_tlv(datastore.anchor_root_ca)
end

private def removal_remaining_admin_entries(datastore : Matter::Cluster::JointFabricDatastore) : Array(Bytes)
  datastore.admin_list.reject(&.node_id.==(0x300_u64)).map(&.to_slice)
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
  it "keeps a failed post-RemoveFabric journal write uncertain before any next command" do
    datastore = removal_datastore
    port = FakeAdministratorRemovalPort.new
    journal = Matter::Controller::AdministratorRemoval::Journal.new(0x300_u64,
      administrator_cat_version: 2_u16)
    durable = Matter::Controller::AdministratorRemoval::Journal.from_document(journal.to_document)
    failed = false
    save = ->(state : Matter::Controller::AdministratorRemoval::Journal) {
      if state.stage.fabric_removed? && !failed
        failed = true
        raise Matter::StorageError.new("Journal flush failed")
      end
      durable = Matter::Controller::AdministratorRemoval::Journal.from_document(state.to_document)
      nil
    }
    workflow = Matter::Controller::AdministratorRemoval::Workflow.new(datastore,
      0x100_u64, [0x200_u64], port, -> { true }, -> { true }, save, journal)

    expect_raises(Matter::StorageError, /Journal flush failed/) { workflow.run }
    durable.stage.should eq(RemovalStage::RemovingFabric)
    expect_raises(Matter::CommissioningError, /reconciliation/) { workflow.run }
    port.events.should eq(["RemoveFabric"])
  end

  it "does not publish a preflight snapshot when the first journal write fails" do
    datastore = removal_datastore
    port = FakeAdministratorRemovalPort.new
    journal = Matter::Controller::AdministratorRemoval::Journal.new(0x300_u64,
      administrator_cat_version: 2_u16)
    workflow = Matter::Controller::AdministratorRemoval::Workflow.new(datastore,
      0x100_u64, [0x200_u64], port, -> { true }, -> { true },
      ->(_state : Matter::Controller::AdministratorRemoval::Journal) {
        raise Matter::StorageError.new("Journal flush failed")
      }, journal)

    expect_raises(Matter::StorageError, /Journal flush failed/) { workflow.run }
    workflow.journal.stage.should eq(RemovalStage::Ready)
    workflow.journal.prior_administrator_cat_version.should be_nil
    workflow.journal.outgoing_admin_entry.should be_nil
    workflow.journal.remaining_admin_entries.should be_nil
    port.events.should be_empty
  end

  it "keeps participant rotation uncertain when its completion write fails" do
    datastore = removal_datastore
    remaining_entries = removal_remaining_admin_entries(datastore)
    datastore.admin_list = datastore.admin_list.reject(&.node_id.==(0x300_u64))
    port = FakeAdministratorRemovalPort.new
    journal = Matter::Controller::AdministratorRemoval::Journal.new(0x300_u64,
      RemovalStage::AnchorRotated, remaining_admin_entries: remaining_entries)
    save = ->(state : Matter::Controller::AdministratorRemoval::Journal) {
      if state.stage.anchor_rotated? && state.rotated_nodes.includes?(0x200_u64)
        raise Matter::StorageError.new("Journal flush failed")
      end
      nil
    }
    workflow = Matter::Controller::AdministratorRemoval::Workflow.new(datastore,
      0x100_u64, [0x200_u64], port, -> { true }, -> { true }, save, journal)

    expect_raises(Matter::StorageError, /Journal flush failed/) { workflow.run }
    workflow.journal.stage.should eq(RemovalStage::RotatingParticipant)
    workflow.journal.active_node_id.should eq(0x200_u64)
    workflow.journal.rotated_nodes.should be_empty
    expect_raises(Matter::CommissioningError, /reconciliation/) { workflow.run }
    port.events.should eq(["Participant 200 UpdateNOC"])
  end

  it "saves the exact participant credential before invoking UpdateNOC" do
    datastore = removal_datastore
    entries = removal_remaining_admin_entries(datastore)
    datastore.admin_list = datastore.admin_list.reject(&.node_id.==(0x300_u64))
    credential = Matter::Cluster::OperationalCredentials::Tlv::NOC.new(Bytes[7], Bytes[8], 1_u8).to_slice
    port = FakeAdministratorRemovalPort.new
    port.interrupt_participant = true
    journal = Matter::Controller::AdministratorRemoval::Journal.new(0x300_u64,
      RemovalStage::AnchorRotated, remaining_admin_entries: entries)
    saved = [] of Matter::Controller::AdministratorRemoval::Journal
    workflow = Matter::Controller::AdministratorRemoval::Workflow.new(datastore,
      0x100_u64, [0x200_u64], port, -> { true }, -> { true },
      ->(item : Matter::Controller::AdministratorRemoval::Journal) { saved << item.detached_copy; nil },
      journal, ->(node_id : UInt64) {
      node_id.should eq(0x200_u64)
      credential
    })

    expect_raises(Matter::TransportError, /interrupted/) { workflow.run }
    saved.first.stage.should eq(RemovalStage::RotatingParticipant)
    saved.first.participant_pre_rotation_credential.should eq(credential)
    workflow.journal.participant_pre_rotation_credential.should eq(credential)
    port.events.should eq(["Participant 200 UpdateNOC"])
  end

  it "does not invoke participant UpdateNOC when the credential journal save fails" do
    datastore = removal_datastore
    entries = removal_remaining_admin_entries(datastore)
    datastore.admin_list = datastore.admin_list.reject(&.node_id.==(0x300_u64))
    port = FakeAdministratorRemovalPort.new
    journal = Matter::Controller::AdministratorRemoval::Journal.new(0x300_u64,
      RemovalStage::AnchorRotated, remaining_admin_entries: entries)
    workflow = Matter::Controller::AdministratorRemoval::Workflow.new(datastore,
      0x100_u64, [0x200_u64], port, -> { true }, -> { true },
      ->(_item : Matter::Controller::AdministratorRemoval::Journal) {
        raise Matter::StorageError.new("Journal flush failed")
      }, journal, ->(_node_id : UInt64) { Bytes[1, 2, 3] })

    expect_raises(Matter::StorageError, /Journal flush failed/) { workflow.run }
    workflow.journal.stage.should eq(RemovalStage::AnchorRotated)
    workflow.journal.participant_pre_rotation_credential.should be_nil
    port.events.should be_empty
  end

  it "does not publish a failed reconciliation of participant rotation" do
    journal = Matter::Controller::AdministratorRemoval::Journal.new(0x300_u64,
      RemovalStage::RotatingParticipant, active_node_id: 0x200_u64,
      root_public_key: Bytes[1], outgoing_admin_entry: Bytes[2],
      remaining_admin_entries: [Bytes[3]], anchor_pre_rotation_noc: Bytes[4])
    save = ->(state : Matter::Controller::AdministratorRemoval::Journal) {
      state.rotated_nodes << 0x400_u64
      state.root_public_key.as(Bytes)[0] = 9_u8
      state.outgoing_admin_entry.as(Bytes)[0] = 9_u8
      state.remaining_admin_entries.as(Array(Bytes)).first[0] = 9_u8
      state.anchor_pre_rotation_noc.as(Bytes)[0] = 9_u8
      raise Matter::StorageError.new("Journal flush failed")
    }

    expect_raises(Matter::StorageError, /Journal flush failed/) do
      Matter::Controller::AdministratorRemoval::Workflow.reconcile_journal!(journal,
        RemovalStage::AnchorRotated, save, rotated_node_id: 0x200_u64,
        participant_completed: true)
    end
    journal.stage.should eq(RemovalStage::RotatingParticipant)
    journal.active_node_id.should eq(0x200_u64)
    journal.rotated_nodes.should be_empty
    journal.root_public_key.should eq(Bytes[1])
    journal.outgoing_admin_entry.should eq(Bytes[2])
    journal.remaining_admin_entries.should eq([Bytes[3]])
    journal.anchor_pre_rotation_noc.should eq(Bytes[4])
  end

  it "rewinds an unstarted Anchor NOC rotation only with the journaled committed Datastore" do
    datastore = removal_datastore
    datastore.admin_list = datastore.admin_list.reject(&.node_id.==(0x300_u64))
    group = datastore.group_list.first
    group.group_cat_version = 2_u16
    datastore.group_list = [group]
    journal = Matter::Controller::AdministratorRemoval::Journal.new(0x300_u64,
      RemovalStage::RotatingAnchor, administrator_cat_version: 2_u16,
      prior_administrator_cat_version: 1_u16, fabric_id: 0x1111_u64,
      root_public_key: removal_root_public_key(datastore), anchor_node_id: 0x100_u64,
      outgoing_admin_entry: Bytes[5], remaining_admin_entries: datastore.admin_list.map(&.to_slice),
      anchor_pre_rotation_noc: Bytes[6])
    save = ->(_item : Matter::Controller::AdministratorRemoval::Journal) { nil }

    restored = Matter::Controller::AdministratorRemoval::Workflow.reconcile_anchor_rotation_no_effect!(
      journal, datastore, 1_u8, save)
    restored.stage.should eq(RemovalStage::DatastoreRemoved)
    datastore.group_list.first.group_cat_version.should eq(2_u16)

    journal.stage = RemovalStage::RotatingAnchor
    journal.anchor_pre_rotation_noc = nil
    expect_raises(Matter::ConfigurationError, /bound Anchor rotation/) do
      Matter::Controller::AdministratorRemoval::Workflow.reconcile_anchor_rotation_no_effect!(
        journal, datastore, 1_u8, save)
    end
    journal.anchor_pre_rotation_noc = Bytes[6]
    journal.remaining_admin_entries = [Bytes[9]]
    expect_raises(Matter::CommissioningError, /AdminList/) do
      Matter::Controller::AdministratorRemoval::Workflow.reconcile_anchor_rotation_no_effect!(
        journal, datastore, 1_u8, save)
    end
    journal.stage.should eq(RemovalStage::RotatingAnchor)
    journal.remaining_admin_entries = datastore.admin_list.map(&.to_slice)
    group.group_cat_version = 1_u16
    datastore.group_list = [group]
    expect_raises(Matter::CommissioningError, /CAT/) do
      Matter::Controller::AdministratorRemoval::Workflow.reconcile_anchor_rotation_no_effect!(
        journal, datastore, 1_u8, save)
    end
    journal.stage.should eq(RemovalStage::RotatingAnchor)
  end

  it "rewinds only the active participant with an exact pre-rotation credential and frozen AdminList" do
    datastore = removal_datastore
    datastore.admin_list = datastore.admin_list.reject(&.node_id.==(0x300_u64))
    group = datastore.group_list.first
    group.group_cat_version = 2_u16
    datastore.group_list = [group]
    credential = Matter::Cluster::OperationalCredentials::Tlv::NOC.new(Bytes[7], Bytes[8], 1_u8).to_slice
    journal = Matter::Controller::AdministratorRemoval::Journal.new(0x300_u64,
      RemovalStage::RotatingParticipant, active_node_id: 0x200_u64,
      administrator_cat_version: 2_u16, prior_administrator_cat_version: 1_u16,
      fabric_id: 0x1111_u64, root_public_key: removal_root_public_key(datastore),
      anchor_node_id: 0x100_u64, outgoing_admin_entry: Bytes[5],
      remaining_admin_entries: datastore.admin_list.map(&.to_slice),
      participant_pre_rotation_credential: credential)
    saved = [] of Matter::Controller::AdministratorRemoval::Journal
    save = ->(item : Matter::Controller::AdministratorRemoval::Journal) { saved << item.detached_copy; nil }

    restored = Matter::Controller::AdministratorRemoval::Workflow.reconcile_participant_rotation_no_effect!(
      journal, datastore, 1_u8, credential, save)
    restored.stage.should eq(RemovalStage::AnchorRotated)
    restored.active_node_id.should be_nil
    restored.participant_pre_rotation_credential.should be_nil
    restored.rotated_nodes.should be_empty
    saved.size.should eq(1)

    journal.participant_pre_rotation_credential = nil
    expect_raises(Matter::ConfigurationError) do
      Matter::Controller::AdministratorRemoval::Workflow.reconcile_participant_rotation_no_effect!(
        journal, datastore, 1_u8, credential, save)
    end
    journal.participant_pre_rotation_credential = credential
    expect_raises(Matter::AuthenticationError) do
      Matter::Controller::AdministratorRemoval::Workflow.reconcile_participant_rotation_no_effect!(
        journal, datastore, 1_u8, Bytes[9], save)
    end
    datastore.admin_list = datastore.admin_list.reverse
    expect_raises(Matter::CommissioningError) do
      Matter::Controller::AdministratorRemoval::Workflow.reconcile_participant_rotation_no_effect!(
        journal, datastore, 1_u8, credential, save)
    end
    journal.stage.should eq(RemovalStage::RotatingParticipant)
  end

  it "persists the Anchor fabric binding with an uncertain rotation journal" do
    journal = Matter::Controller::AdministratorRemoval::Journal.new(0x300_u64,
      RemovalStage::RotatingParticipant, active_node_id: 0x200_u64,
      administrator_cat_version: 2_u16, prior_administrator_cat_version: 1_u16, fabric_id: 0x1111_u64,
      root_public_key: Bytes[1, 2, 3], anchor_node_id: 0x100_u64,
      outgoing_admin_entry: Bytes[7, 8], remaining_admin_entries: [Bytes[9], Bytes[10]],
      anchor_pre_rotation_noc: Bytes[11, 12])
    restored = Matter::Controller::AdministratorRemoval::Journal.from_document(journal.to_document)
    restored.fabric_id.should eq(0x1111_u64)
    restored.root_public_key.should eq(Bytes[1, 2, 3])
    restored.prior_administrator_cat_version.should eq(1_u16)
    restored.anchor_node_id.should eq(0x100_u64)
    restored.outgoing_admin_entry.should eq(Bytes[7, 8])
    restored.remaining_admin_entries.should eq([Bytes[9], Bytes[10]])
    restored.anchor_pre_rotation_noc.should eq(Bytes[11, 12])
    restored.active_node_id.should eq(0x200_u64)
    restored.stage.should eq(RemovalStage::RotatingParticipant)
  end

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
    datastore = removal_datastore
    remaining_entries = removal_remaining_admin_entries(datastore)
    datastore.admin_list = datastore.admin_list.reject(&.node_id.==(0x300_u64))
    journal = Matter::Controller::AdministratorRemoval::Journal.new(0x300_u64,
      Matter::Controller::AdministratorRemoval::Stage::AnchorRotated,
      remaining_admin_entries: remaining_entries)
    port = FakeAdministratorRemovalPort.new
    port.interrupt_participant = true
    workflow = Matter::Controller::AdministratorRemoval::Workflow.new(datastore, 0x100_u64, [0x200_u64], port,
      -> { true }, -> { true }, ->(_state : Matter::Controller::AdministratorRemoval::Journal) { nil }, journal)

    expect_raises(Matter::TransportError, /interrupted/) { workflow.run }
    workflow.journal.stage.should eq(Matter::Controller::AdministratorRemoval::Stage::RotatingParticipant)
    workflow.journal.active_node_id.should eq(0x200_u64)
    expect_raises(Matter::CommissioningError, /reconciliation/) { workflow.run }
    expect_raises(Matter::ConfigurationError, /Invalid Administrator removal reconciliation/) do
      workflow.reconcile!(Matter::Controller::AdministratorRemoval::Stage::AnchorRotated, 0x200_u64,
        participant_completed: false)
    end
    workflow.reconcile!(Matter::Controller::AdministratorRemoval::Stage::AnchorRotated, 0x200_u64,
      participant_completed: true)
    workflow.run
    workflow.journal.stage.should eq(Matter::Controller::AdministratorRemoval::Stage::Completed)
    port.events.should eq(["Participant 200 UpdateNOC"])
  end

  it "retains a participant recovery fence across a no-effect rewind and restart" do
    datastore = removal_datastore
    datastore.admin_list = datastore.admin_list.reject(&.node_id.==(0x300_u64))
    datastore.group_list = [Matter::Cluster::JointFabricDatastore::DatastoreGroupInformationEntryStruct.new(
      1_u64, "Administrators", nil, Matter::Cluster::JointFabricDatastore::ADMINISTRATOR_CAT, 2_u16,
      Matter::Cluster::JointFabricDatastore::DatastoreAccessControlEntryPrivilegeEnum::Administer)]
    journal = Matter::Controller::AdministratorRemoval::Journal.new(0x300_u64,
      RemovalStage::RotatingParticipant, active_node_id: 0x200_u64,
      administrator_cat_version: 2_u16, prior_administrator_cat_version: 1_u16,
      fabric_id: 0x1111_u64, root_public_key: removal_root_public_key(datastore),
      anchor_node_id: 0x100_u64,
      remaining_admin_entries: removal_remaining_admin_entries(datastore),
      participant_pre_rotation_credential: Bytes[1, 2, 3],
      participant_recovery_lease_id: "fenced-recovery")
    saved = nil.as(Matter::Controller::AdministratorRemoval::Journal?)
    rewound = Matter::Controller::AdministratorRemoval::Workflow.reconcile_participant_rotation_no_effect!(
      journal, datastore, 1_u8, Bytes[1, 2, 3],
      ->(state : Matter::Controller::AdministratorRemoval::Journal) {
        saved = Matter::Controller::AdministratorRemoval::Journal.from_document(state.to_document)
        nil
      })
    rewound.participant_recovery_lease_id.should eq("fenced-recovery")
    saved.as(Matter::Controller::AdministratorRemoval::Journal)
      .participant_recovery_lease_id.should eq("fenced-recovery")
    port = FakeAdministratorRemovalPort.new
    workflow = Matter::Controller::AdministratorRemoval::Workflow.new(datastore,
      0x100_u64, [0x200_u64], port, -> { true }, -> { true },
      ->(_state : Matter::Controller::AdministratorRemoval::Journal) { nil }, rewound)
    expect_raises(Matter::CommissioningError, /needs durable release/) { workflow.run }
    port.events.should be_empty
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

  it "requires persisted AdminList proof before resuming a lost RemoveAdmin acknowledgement" do
    datastore = removal_datastore
    journal = Matter::Controller::AdministratorRemoval::Journal.new(0x300_u64,
      RemovalStage::RemovingDatastore, administrator_cat_version: 2_u16, prior_administrator_cat_version: 1_u16,
      fabric_id: 0x1111_u64, root_public_key: removal_root_public_key(datastore), anchor_node_id: 0x100_u64,
      outgoing_admin_entry: datastore.admin_list.find!(&.node_id.==(0x300_u64)).to_slice,
      remaining_admin_entries: removal_remaining_admin_entries(datastore))
    stored = Matter::Controller::AdministratorRemoval::Journal.from_document(journal.to_document)
    save = ->(item : Matter::Controller::AdministratorRemoval::Journal) {
      stored = Matter::Controller::AdministratorRemoval::Journal.from_document(item.to_document)
      nil
    }

    expect_raises(Matter::CommissioningError, /still lists outgoing Administrator/) do
      Matter::Controller::AdministratorRemoval::Workflow.reconcile_datastore_removed!(stored, datastore, 1_u8, save)
    end
    stored.stage.should eq(RemovalStage::RemovingDatastore)

    datastore.admin_list = datastore.admin_list.reject(&.node_id.==(0x300_u64))
    Matter::Controller::AdministratorRemoval::Workflow.reconcile_datastore_removed!(stored, datastore, 1_u8, save)
    stored.stage.should eq(RemovalStage::DatastoreRemoved)
    port = FakeAdministratorRemovalPort.new
    resumed = Matter::Controller::AdministratorRemoval::Workflow.new(datastore, 0x100_u64,
      [0x200_u64], port, -> { true }, -> { true }, save,
      Matter::Controller::AdministratorRemoval::Journal.from_document(stored.to_document))
    resumed.run
    resumed.journal.stage.should eq(RemovalStage::Completed)
    port.events.should eq(["Anchor UpdateNOC", "Participant 200 UpdateNOC"])
  end

  it "does not rotate an Administrator added after removal was journaled" do
    datastore = removal_datastore
    remaining_entries = removal_remaining_admin_entries(datastore)
    datastore.admin_list = datastore.admin_list.reject(&.node_id.==(0x300_u64))
    journal = Matter::Controller::AdministratorRemoval::Journal.new(0x300_u64,
      RemovalStage::DatastoreRemoved, administrator_cat_version: 2_u16,
      prior_administrator_cat_version: 1_u16,
      remaining_admin_entries: remaining_entries)
    datastore.admin_list += [Matter::Cluster::JointFabricDatastore::DatastoreAdministratorInformationEntryStruct.new(
      0x400_u64, "New Administrator", 0xFFF2_u16, Bytes[4])]
    port = FakeAdministratorRemovalPort.new
    restarted = Matter::Controller::AdministratorRemoval::Workflow.new(datastore, 0x100_u64,
      [0x200_u64, 0x400_u64], port, -> { true }, -> { true },
      ->(_state : Matter::Controller::AdministratorRemoval::Journal) { nil },
      Matter::Controller::AdministratorRemoval::Journal.from_document(journal.to_document))

    expect_raises(Matter::CommissioningError, /remaining AdminList changed/) { restarted.run }
    port.events.should be_empty
    restarted.journal.stage.should eq(RemovalStage::DatastoreRemoved)
  end

  it "does not resume participant rotation after a journaled Administrator entry changes" do
    datastore = removal_datastore
    remaining_entries = removal_remaining_admin_entries(datastore)
    datastore.admin_list = datastore.admin_list.reject(&.node_id.==(0x300_u64))
    journal = Matter::Controller::AdministratorRemoval::Journal.new(0x300_u64,
      RemovalStage::AnchorRotated, administrator_cat_version: 2_u16,
      prior_administrator_cat_version: 1_u16,
      remaining_admin_entries: remaining_entries)
    changed = datastore.admin_list.find!(&.node_id.==(0x200_u64))
    changed.icac = Bytes[9]
    datastore.admin_list = datastore.admin_list.map { |entry| entry.node_id == changed.node_id ? changed : entry }
    port = FakeAdministratorRemovalPort.new
    restarted = Matter::Controller::AdministratorRemoval::Workflow.new(datastore, 0x100_u64,
      [0x200_u64], port, -> { true }, -> { true },
      ->(_state : Matter::Controller::AdministratorRemoval::Journal) { nil },
      Matter::Controller::AdministratorRemoval::Journal.from_document(journal.to_document))

    expect_raises(Matter::CommissioningError, /remaining AdminList changed/) { restarted.run }
    port.events.should be_empty
    restarted.journal.stage.should eq(RemovalStage::AnchorRotated)
  end

  it "rejects a lost RemoveAdmin acknowledgement from a different Anchor Datastore" do
    datastore = removal_datastore
    datastore.anchor_node_id = 0x999_u64
    datastore.admin_list = datastore.admin_list.reject(&.node_id.==(0x300_u64))
    journal = Matter::Controller::AdministratorRemoval::Journal.new(0x300_u64,
      RemovalStage::RemovingDatastore, administrator_cat_version: 2_u16, prior_administrator_cat_version: 1_u16,
      fabric_id: 0x1111_u64, root_public_key: removal_root_public_key(datastore), anchor_node_id: 0x100_u64,
      outgoing_admin_entry: removal_datastore.admin_list.find!(&.node_id.==(0x300_u64)).to_slice)
    saved = [] of RemovalStage
    save = ->(item : Matter::Controller::AdministratorRemoval::Journal) { saved << item.stage; nil }

    expect_raises(Matter::AuthenticationError, /another Anchor/) do
      Matter::Controller::AdministratorRemoval::Workflow.reconcile_datastore_removed!(journal, datastore, 1_u8, save)
    end
    journal.stage.should eq(RemovalStage::RemovingDatastore)
    saved.should be_empty
  end

  it "rejects a lost RemoveAdmin acknowledgement after premature CAT rotation" do
    datastore = removal_datastore
    datastore.admin_list = datastore.admin_list.reject(&.node_id.==(0x300_u64))
    group = datastore.group_list.first
    group.group_cat_version = 2_u16
    datastore.group_list = [group]
    journal = Matter::Controller::AdministratorRemoval::Journal.new(0x300_u64,
      RemovalStage::RemovingDatastore, administrator_cat_version: 2_u16, prior_administrator_cat_version: 1_u16,
      fabric_id: 0x1111_u64, root_public_key: removal_root_public_key(datastore), anchor_node_id: 0x100_u64,
      outgoing_admin_entry: removal_datastore.admin_list.find!(&.node_id.==(0x300_u64)).to_slice)
    saved = [] of RemovalStage
    save = ->(item : Matter::Controller::AdministratorRemoval::Journal) { saved << item.stage; nil }

    expect_raises(Matter::CommissioningError, /pre-rotation/) do
      Matter::Controller::AdministratorRemoval::Workflow.reconcile_datastore_removed!(journal, datastore, 1_u8, save)
    end
    journal.stage.should eq(RemovalStage::RemovingDatastore)
    saved.should be_empty
  end

  it "rejects a lost RemoveAdmin acknowledgement without a complete fabric binding" do
    datastore = removal_datastore
    datastore.admin_list = datastore.admin_list.reject(&.node_id.==(0x300_u64))
    journal = Matter::Controller::AdministratorRemoval::Journal.new(0x300_u64,
      RemovalStage::RemovingDatastore, administrator_cat_version: 2_u16, prior_administrator_cat_version: 1_u16,
      fabric_id: 0x1111_u64, anchor_node_id: 0x100_u64)
    saved = [] of RemovalStage
    save = ->(item : Matter::Controller::AdministratorRemoval::Journal) { saved << item.stage; nil }

    expect_raises(Matter::ConfigurationError, /bound Datastore/) do
      Matter::Controller::AdministratorRemoval::Workflow.reconcile_datastore_removed!(journal, datastore, 1_u8, save)
    end
    journal.stage.should eq(RemovalStage::RemovingDatastore)
    saved.should be_empty
  end

  it "rejects legacy RemoveAdmin journals without the remaining AdminList snapshot" do
    datastore = removal_datastore
    outgoing = datastore.admin_list.find!(&.node_id.==(0x300_u64))
    journal = Matter::Controller::AdministratorRemoval::Journal.new(outgoing.node_id,
      RemovalStage::RemovingDatastore, administrator_cat_version: 2_u16,
      prior_administrator_cat_version: 1_u16, fabric_id: 0x1111_u64,
      root_public_key: removal_root_public_key(datastore), anchor_node_id: 0x100_u64,
      outgoing_admin_entry: outgoing.to_slice)
    save = ->(_item : Matter::Controller::AdministratorRemoval::Journal) { nil }

    expect_raises(Matter::CommissioningError, /journaled remaining AdminList/) do
      Matter::Controller::AdministratorRemoval::Workflow.reconcile_datastore_no_effect!(journal, datastore, 1_u8, save)
    end
    datastore.admin_list = datastore.admin_list.reject(&.node_id.==(outgoing.node_id))
    expect_raises(Matter::CommissioningError, /journaled remaining AdminList/) do
      Matter::Controller::AdministratorRemoval::Workflow.reconcile_datastore_removed!(journal, datastore, 1_u8, save)
    end
    journal.stage.should eq(RemovalStage::RemovingDatastore)
  end

  it "rejects a lost RemoveAdmin acknowledgement with an invalid remaining AdminList" do
    datastore = removal_datastore
    outgoing = datastore.admin_list.find!(&.node_id.==(0x300_u64))
    datastore.admin_list = datastore.admin_list.reject(&.node_id.==(outgoing.node_id))
    datastore.admin_list = datastore.admin_list + [datastore.admin_list.first]
    journal = Matter::Controller::AdministratorRemoval::Journal.new(outgoing.node_id,
      RemovalStage::RemovingDatastore, administrator_cat_version: 2_u16, prior_administrator_cat_version: 1_u16,
      fabric_id: 0x1111_u64, root_public_key: removal_root_public_key(datastore), anchor_node_id: 0x100_u64,
      outgoing_admin_entry: outgoing.to_slice)
    saved = [] of RemovalStage
    save = ->(item : Matter::Controller::AdministratorRemoval::Journal) { saved << item.stage; nil }

    expect_raises(Matter::CommissioningError, /invalid remaining AdminList/) do
      Matter::Controller::AdministratorRemoval::Workflow.reconcile_datastore_removed!(journal, datastore, 1_u8, save)
    end
    journal.stage.should eq(RemovalStage::RemovingDatastore)
    saved.should be_empty
  end

  it "reconciles a legal Administrator CAT version jump from the journaled prior version" do
    datastore = removal_datastore
    outgoing = datastore.admin_list.find!(&.node_id.==(0x300_u64))
    journal = Matter::Controller::AdministratorRemoval::Journal.new(outgoing.node_id,
      administrator_cat_version: 5_u16, fabric_id: 0x1111_u64,
      root_public_key: removal_root_public_key(datastore), anchor_node_id: 0x100_u64)
    port = FakeAdministratorRemovalPort.new
    port.fail_at = "RemoveAdmin"
    save = ->(_item : Matter::Controller::AdministratorRemoval::Journal) { nil }
    workflow = Matter::Controller::AdministratorRemoval::Workflow.new(datastore, 0x100_u64,
      [0x200_u64], port, -> { true }, -> { true }, save, journal)

    expect_raises(Matter::TransportError, /interrupted/) { workflow.run }
    journal = workflow.journal
    journal.stage.should eq(RemovalStage::RemovingDatastore)
    journal.prior_administrator_cat_version.should eq(1_u16)
    rewound = Matter::Controller::AdministratorRemoval::Workflow.reconcile_datastore_no_effect!(
      Matter::Controller::AdministratorRemoval::Journal.from_document(journal.to_document), datastore, 1_u8, save)
    rewound.stage.should eq(RemovalStage::FabricRemoved)
    datastore.admin_list = datastore.admin_list.reject(&.node_id.==(outgoing.node_id))
    journal = Matter::Controller::AdministratorRemoval::Workflow.reconcile_datastore_removed!(journal, datastore, 1_u8, save)
    journal.stage.should eq(RemovalStage::DatastoreRemoved)
  end

  it "rejects a changed outgoing Administrator entry after a no-effect rewind" do
    datastore = removal_datastore
    journal = Matter::Controller::AdministratorRemoval::Journal.new(0x300_u64,
      administrator_cat_version: 2_u16, fabric_id: 0x1111_u64,
      root_public_key: removal_root_public_key(datastore), anchor_node_id: 0x100_u64)
    port = FakeAdministratorRemovalPort.new
    port.fail_at = "RemoveAdmin"
    save = ->(_item : Matter::Controller::AdministratorRemoval::Journal) { nil }
    workflow = Matter::Controller::AdministratorRemoval::Workflow.new(datastore, 0x100_u64,
      [0x200_u64], port, -> { true }, -> { true }, save, journal)

    expect_raises(Matter::TransportError, /interrupted/) { workflow.run }
    rewound = Matter::Controller::AdministratorRemoval::Workflow.reconcile_datastore_no_effect!(
      workflow.journal, datastore, 1_u8, save)
    outgoing_index = datastore.admin_list.index!(&.node_id.==(0x300_u64))
    changed_admin = datastore.admin_list[outgoing_index]
    changed_admin.icac = Bytes[9]
    changed_admins = datastore.admin_list.dup
    changed_admins[outgoing_index] = changed_admin
    datastore.admin_list = changed_admins
    port.fail_at = nil
    resumed = Matter::Controller::AdministratorRemoval::Workflow.new(datastore, 0x100_u64,
      [0x200_u64], port, -> { true }, -> { true }, save, rewound)

    expect_raises(Matter::CommissioningError, /Outgoing Administrator changed/) { resumed.run }
    resumed.journal.stage.should eq(RemovalStage::FabricRemoved)
    port.events.count("RemoveAdmin").should eq(1)
  end

  it "rejects CAT and committed-state changes after a no-effect rewind" do
    datastore = removal_datastore
    journal = Matter::Controller::AdministratorRemoval::Journal.new(0x300_u64,
      administrator_cat_version: 2_u16, fabric_id: 0x1111_u64,
      root_public_key: removal_root_public_key(datastore), anchor_node_id: 0x100_u64)
    port = FakeAdministratorRemovalPort.new
    port.fail_at = "RemoveAdmin"
    save = ->(_item : Matter::Controller::AdministratorRemoval::Journal) { nil }
    workflow = Matter::Controller::AdministratorRemoval::Workflow.new(datastore, 0x100_u64,
      [0x200_u64], port, -> { true }, -> { true }, save, journal)

    expect_raises(Matter::TransportError, /interrupted/) { workflow.run }
    rewound = Matter::Controller::AdministratorRemoval::Workflow.reconcile_datastore_no_effect!(
      workflow.journal, datastore, 1_u8, save)
    port.fail_at = nil
    resumed = Matter::Controller::AdministratorRemoval::Workflow.new(datastore, 0x100_u64,
      [0x200_u64], port, -> { true }, -> { true }, save, rewound)

    group = datastore.group_list.first
    group.group_cat_version = 2_u16
    datastore.group_list = [group]
    expect_raises(Matter::CommissioningError, /CAT changed/) { resumed.run }
    group.group_cat_version = 1_u16
    datastore.group_list = [group]
    datastore.status = Matter::Cluster::JointFabricDatastore::DatastoreStatusEntryStruct.new(
      Matter::Cluster::JointFabricDatastore::DatastoreStateEnum::Pending, 0_u32, 0_u8)
    expect_raises(Matter::CommissioningError, /not committed/) { resumed.run }
    resumed.journal.stage.should eq(RemovalStage::FabricRemoved)
    port.events.count("RemoveAdmin").should eq(1)
  end

  it "rejects a removed AdminList from a Datastore with another root" do
    datastore = removal_datastore
    outgoing = datastore.admin_list.find!(&.node_id.==(0x300_u64))
    datastore.admin_list = datastore.admin_list.reject(&.node_id.==(outgoing.node_id))
    journal = Matter::Controller::AdministratorRemoval::Journal.new(outgoing.node_id,
      RemovalStage::RemovingDatastore, administrator_cat_version: 2_u16, prior_administrator_cat_version: 1_u16,
      fabric_id: 0x1111_u64, root_public_key: Bytes.new(65, 9_u8), anchor_node_id: 0x100_u64,
      outgoing_admin_entry: outgoing.to_slice)
    saved = [] of RemovalStage
    save = ->(item : Matter::Controller::AdministratorRemoval::Journal) { saved << item.stage; nil }

    expect_raises(Matter::AuthenticationError, /root/) do
      Matter::Controller::AdministratorRemoval::Workflow.reconcile_datastore_removed!(journal, datastore, 1_u8, save)
    end
    journal.stage.should eq(RemovalStage::RemovingDatastore)
    saved.should be_empty
  end

  it "rejects a removed AdminList from another fabric index" do
    datastore = removal_datastore
    outgoing = datastore.admin_list.find!(&.node_id.==(0x300_u64))
    datastore.admin_list = datastore.admin_list.reject(&.node_id.==(outgoing.node_id))
    datastore.joint_fabric_index = 2_u8
    journal = Matter::Controller::AdministratorRemoval::Journal.new(outgoing.node_id,
      RemovalStage::RemovingDatastore, administrator_cat_version: 2_u16,
      prior_administrator_cat_version: 1_u16, fabric_id: 0x1111_u64,
      root_public_key: removal_root_public_key(datastore), anchor_node_id: 0x100_u64,
      outgoing_admin_entry: outgoing.to_slice,
      remaining_admin_entries: removal_remaining_admin_entries(datastore))
    saved = [] of RemovalStage
    save = ->(item : Matter::Controller::AdministratorRemoval::Journal) { saved << item.stage; nil }

    expect_raises(Matter::AuthenticationError, /fabric index/) do
      Matter::Controller::AdministratorRemoval::Workflow.reconcile_datastore_removed!(journal, datastore, 1_u8, save)
    end
    journal.stage.should eq(RemovalStage::RemovingDatastore)
    saved.should be_empty
  end

  it "rejects removal reconciliation if another Administrator disappeared" do
    datastore = removal_datastore
    outgoing = datastore.admin_list.find!(&.node_id.==(0x300_u64))
    journal = Matter::Controller::AdministratorRemoval::Journal.new(outgoing.node_id,
      RemovalStage::RemovingDatastore, administrator_cat_version: 2_u16,
      prior_administrator_cat_version: 1_u16, fabric_id: 0x1111_u64,
      root_public_key: removal_root_public_key(datastore), anchor_node_id: 0x100_u64,
      outgoing_admin_entry: outgoing.to_slice,
      remaining_admin_entries: removal_remaining_admin_entries(datastore))
    datastore.admin_list = datastore.admin_list.reject(&.node_id.in?(outgoing.node_id, 0x200_u64))
    saved = [] of RemovalStage
    save = ->(item : Matter::Controller::AdministratorRemoval::Journal) { saved << item.stage; nil }

    expect_raises(Matter::CommissioningError, /remaining AdminList/) do
      Matter::Controller::AdministratorRemoval::Workflow.reconcile_datastore_removed!(journal, datastore, 1_u8, save)
    end
    journal.stage.should eq(RemovalStage::RemovingDatastore)
    saved.should be_empty
  end

  it "retries a no-effect RemoveAdmin only after a restored Datastore proves its old state" do
    original = removal_datastore
    persisted = original.save_state.as(Matter::Storage::Document)
    journal = Matter::Controller::AdministratorRemoval::Journal.new(0x300_u64,
      RemovalStage::RemovingDatastore, administrator_cat_version: 2_u16, prior_administrator_cat_version: 1_u16,
      fabric_id: 0x1111_u64, root_public_key: removal_root_public_key(original), anchor_node_id: 0x100_u64,
      outgoing_admin_entry: original.admin_list.find!(&.node_id.==(0x300_u64)).to_slice,
      remaining_admin_entries: removal_remaining_admin_entries(original))
    path = File.join(Dir.tempdir, "matter-jfa-remove-admin-#{Random::Secure.hex(6)}.yml")
    backend = Matter::Storage::YamlFile.new(path)
    backend.open
    backend.write(Matter::Storage::Collections::CLUSTERS, "anchor-datastore", persisted)
    backend.write(Matter::Storage::Collections::APP, "removal", journal.to_document)
    backend.close
    reopened = Matter::Storage::YamlFile.new(path)
    reopened.open
    datastore = Matter::Cluster::JointFabricDatastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    datastore.restore_state(reopened.read(Matter::Storage::Collections::CLUSTERS,
      "anchor-datastore").as(Matter::Storage::Document))
    datastore.joint_fabric_index = 1_u8
    datastore.data_version &+= 1
    reopened.write(Matter::Storage::Collections::CLUSTERS, "anchor-datastore",
      datastore.save_state.as(Matter::Storage::Document))
    datastore.restore_state(reopened.read(Matter::Storage::Collections::CLUSTERS,
      "anchor-datastore").as(Matter::Storage::Document))
    datastore.joint_fabric_index = 1_u8
    datastore.data_version.should eq(original.data_version &+ 1_u32)
    restored = Matter::Controller::AdministratorRemoval::Journal.from_document(
      reopened.read(Matter::Storage::Collections::APP, "removal").as(Matter::Storage::Document))
    saved = [] of RemovalStage
    save = ->(item : Matter::Controller::AdministratorRemoval::Journal) { saved << item.stage; nil }

    reconciled = Matter::Controller::AdministratorRemoval::Workflow.reconcile_datastore_no_effect!(restored, datastore, 1_u8, save)
    reconciled.stage.should eq(RemovalStage::FabricRemoved)
    saved.should eq([RemovalStage::FabricRemoved])
    datastore.admin_list.map(&.node_id).should contain(0x300_u64)
    datastore.group_list.find!(&.group_cat.==(0xFFFF_u16)).group_cat_version.should eq(1_u16)
    port = FakeAdministratorRemovalPort.new
    resumed = Matter::Controller::AdministratorRemoval::Workflow.new(datastore, 0x100_u64,
      [0x200_u64], port, -> { true }, -> { true }, save,
      Matter::Controller::AdministratorRemoval::Journal.from_document(reconciled.to_document))
    resumed.run
    port.events.should eq(["RemoveAdmin", "Anchor UpdateNOC", "Participant 200 UpdateNOC"])

    wrong_cat = Matter::Cluster::JointFabricDatastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    wrong_cat.restore_state(persisted)
    wrong_cat.joint_fabric_index = 1_u8
    changed_group = wrong_cat.group_list.first
    changed_group.group_cat_version = 2_u16
    wrong_cat.group_list = [changed_group]
    pending = Matter::Controller::AdministratorRemoval::Journal.from_document(journal.to_document)
    expect_raises(Matter::CommissioningError) do
      Matter::Controller::AdministratorRemoval::Workflow.reconcile_datastore_no_effect!(pending, wrong_cat, 1_u8, save)
    end
    pending.stage.should eq(RemovalStage::RemovingDatastore)

    altered = Matter::Cluster::JointFabricDatastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    altered.restore_state(persisted)
    altered.joint_fabric_index = 1_u8
    outgoing_index = altered.admin_list.index!(&.node_id.==(0x300_u64))
    replaced_admin = altered.admin_list[outgoing_index]
    replaced_admin.icac = Bytes[9]
    changed_admins = altered.admin_list.dup
    changed_admins[outgoing_index] = replaced_admin
    altered.admin_list = changed_admins
    expect_raises(Matter::CommissioningError) do
      Matter::Controller::AdministratorRemoval::Workflow.reconcile_datastore_no_effect!(pending, altered, 1_u8, save)
    end
    pending.stage.should eq(RemovalStage::RemovingDatastore)

    legacy = Matter::Controller::AdministratorRemoval::Journal.from_document(journal.to_document)
    legacy.outgoing_admin_entry = nil
    expect_raises(Matter::CommissioningError) do
      Matter::Controller::AdministratorRemoval::Workflow.reconcile_datastore_no_effect!(legacy, datastore, 1_u8, save)
    end
    legacy.stage.should eq(RemovalStage::RemovingDatastore)

    absent = Matter::Cluster::JointFabricDatastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    absent.restore_state(persisted)
    absent.joint_fabric_index = 1_u8
    absent.admin_list = absent.admin_list.reject(&.node_id.==(0x300_u64))
    expect_raises(Matter::CommissioningError) do
      Matter::Controller::AdministratorRemoval::Workflow.reconcile_datastore_no_effect!(pending, absent, 1_u8, save)
    end
    pending.stage.should eq(RemovalStage::RemovingDatastore)

    wrong_anchor = Matter::Cluster::JointFabricDatastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    wrong_anchor.restore_state(persisted)
    wrong_anchor.joint_fabric_index = 1_u8
    wrong_anchor.anchor_node_id = 0x999_u64
    expect_raises(Matter::AuthenticationError) do
      Matter::Controller::AdministratorRemoval::Workflow.reconcile_datastore_no_effect!(pending, wrong_anchor, 1_u8, save)
    end
    pending.stage.should eq(RemovalStage::RemovingDatastore)

    wrong_index = Matter::Cluster::JointFabricDatastore.new(Matter::DataType::EndpointNumber.new(1_u16))
    wrong_index.restore_state(persisted)
    wrong_index.joint_fabric_index = 2_u8
    expect_raises(Matter::AuthenticationError, /fabric index/) do
      Matter::Controller::AdministratorRemoval::Workflow.reconcile_datastore_no_effect!(pending, wrong_index, 1_u8, save)
    end
    pending.stage.should eq(RemovalStage::RemovingDatastore)
  ensure
    backend.try(&.close) if backend.try(&.open?)
    reopened.try(&.close) if reopened.try(&.open?)
    File.delete?(path) if path
  end

  it "recovers each interrupted removal command from a persisted journal" do
    boundaries = {
      {"RemoveFabric", RemovalStage::Ready, RemovalStage::RemovingFabric, RemovalStage::FabricRemoved},
      {"RemoveAdmin", RemovalStage::FabricRemoved, RemovalStage::RemovingDatastore, RemovalStage::DatastoreRemoved},
      {"Anchor UpdateNOC", RemovalStage::DatastoreRemoved, RemovalStage::RotatingAnchor, RemovalStage::AnchorRotated},
      {"Participant 200 UpdateNOC", RemovalStage::AnchorRotated, RemovalStage::RotatingParticipant, RemovalStage::AnchorRotated},
    }
    boundaries.each do |command, before, uncertain, after|
      # Participant no-effect now requires the credential snapshot and private
      # witness checked by the dedicated reconciliation path below.
      completed_states = command.starts_with?("Participant") ? [true] : [false, true]
      completed_states.each do |completed|
        port = FakeAdministratorRemovalPort.new
        port.fail_at = command
        datastore = removal_datastore
        outgoing_entry = datastore.admin_list.find!(&.node_id.==(0x300_u64)).to_slice
        remaining_entries = removal_remaining_admin_entries(datastore)
        if before.in?(RemovalStage::DatastoreRemoved, RemovalStage::AnchorRotated)
          datastore.admin_list = datastore.admin_list.reject(&.node_id.==(0x300_u64))
        end
        stored = Matter::Controller::AdministratorRemoval::Journal.new(
          0x300_u64, before, administrator_cat_version: 2_u16,
          prior_administrator_cat_version: 1_u16,
          outgoing_admin_entry: outgoing_entry,
          remaining_admin_entries: remaining_entries)
        save = ->(item : Matter::Controller::AdministratorRemoval::Journal) {
          stored = Matter::Controller::AdministratorRemoval::Journal.from_document(item.to_document)
          nil
        }
        workflow = Matter::Controller::AdministratorRemoval::Workflow.new(
          datastore, 0x100_u64, [0x200_u64], port,
          -> { true }, -> { true }, save, stored)

        expect_raises(Matter::TransportError, /interrupted/) { workflow.run }
        stored.stage.should eq(uncertain)
        stored.outgoing_admin_entry.should_not be_nil if command == "RemoveAdmin"
        restarted_datastore = removal_datastore
        if (completed ? after : before).in?(RemovalStage::DatastoreRemoved, RemovalStage::AnchorRotated)
          restarted_datastore.admin_list = restarted_datastore.admin_list.reject(&.node_id.==(0x300_u64))
        end
        restarted = Matter::Controller::AdministratorRemoval::Workflow.new(
          restarted_datastore, 0x100_u64, [0x200_u64], port,
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
      datastore = removal_datastore
      outgoing_entry = datastore.admin_list.find!(&.node_id.==(0x300_u64)).to_slice
      remaining_entries = removal_remaining_admin_entries(datastore)
      if stable.in?(RemovalStage::DatastoreRemoved, RemovalStage::AnchorRotated)
        datastore.admin_list = datastore.admin_list.reject(&.node_id.==(0x300_u64))
      end
      stored = Matter::Controller::AdministratorRemoval::Journal.new(
        0x300_u64, stable, administrator_cat_version: 2_u16,
        prior_administrator_cat_version: 1_u16,
        outgoing_admin_entry: outgoing_entry,
        remaining_admin_entries: remaining_entries)
      restarted = Matter::Controller::AdministratorRemoval::Workflow.new(
        datastore, 0x100_u64, [0x200_u64], port,
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

  it "rejects another response command for outgoing RemoveFabric" do
    session = Matter::Session::SecureContext.new(
      1_u16, 2_u16, Matter::Session::SessionType::Unicast,
      Bytes.new(16, 1_u8), Bytes.new(16, 2_u8),
      peer_node_id: Matter::DataType::NodeId.new(0x300_u64),
      case_session: true)
    client = Matter::Controller::Client.new
    port = Matter::Controller::AdministratorRemoval::ImPort.new(
      WrongRemovalResponseImClient.new(client), session,
      Socket::IPAddress.new("127.0.0.1", 5540), 1_u64, Bytes[1], 0x300_u64,
      removal_datastore, -> { nil }, -> { nil }, ->(_node_id : UInt64) { nil })

    expect_raises(Matter::ProtocolError, /RemoveFabric omitted response/) { port.remove_outgoing_fabric! }
  ensure
    client.try(&.close)
  end
end
