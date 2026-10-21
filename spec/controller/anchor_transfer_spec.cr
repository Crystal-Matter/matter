require "../spec_helper"
require "../../src/matter/controller/anchor_transfer"

private alias TransferDatastore = Matter::Cluster::JointFabricDatastore

private class FakeAnchorPort < Matter::Controller::AnchorTransfer::Port
  getter calls = [] of String
  property result = Matter::Cluster::JointFabricAdministrator::TransferAnchorResponseStatusEnum::OK

  def request : Matter::Cluster::JointFabricAdministrator::TransferAnchorResponseStatusEnum
    @calls << "request"
    @result
  end

  def complete : Nil
    @calls << "complete"
  end
end

private class FakeAnchorMigration < Matter::Controller::AnchorTransfer::Migration
  getter calls = [] of String
  property? fail_copy = false
  property? fail_follow_up = false

  def copy_datastore! : Nil
    @calls << "copy"
    raise Matter::TransportError.new("copy interrupted") if fail_copy?
  end

  def rotate_credentials! : Nil
    @calls << "rotate"
  end

  def promote_candidate! : Nil
    @calls << "promote"
  end

  def follow_up_administrators! : Nil
    @calls << "follow-up"
    raise Matter::TransportError.new("follow-up interrupted") if fail_follow_up?
  end
end

private class FakeAnchorReadImClient < Matter::Controller::ImClient
  property? change_status_between_reads = false
  @status_reads = 0

  def initialize(@source : Matter::Cluster::JointFabricDatastore)
    super(Matter::Controller::Client.new)
    @source.joint_fabric_index = 1_u8
    @source.access_mode = @source.status.state.delete_pending? ? Matter::Cluster::JointFabricDatastore::AccessMode::Frozen : Matter::Cluster::JointFabricDatastore::AccessMode::Active
    @source.request_is_case_session = true
  end

  def close : Nil
    @client.close
  end

  def reset_status_reads : Nil
    @status_reads = 0
  end

  def read_attribute(session : Matter::Session::SecureContext, peer : Socket::IPAddress,
                     endpoint_id : UInt16, cluster_id : UInt32, attribute_id : UInt32,
                     fabric_filtered : Bool = true) : Matter::InteractionModel::ReportDataMessage
    if attribute_id == Matter::Cluster::JointFabricDatastore::ATTR_STATUS
      @status_reads += 1
      if change_status_between_reads? && @status_reads == 2
        @source.status = Matter::Cluster::JointFabricDatastore::DatastoreStatusEntryStruct.new(
          Matter::Cluster::JointFabricDatastore::DatastoreStateEnum::Committed, 1_u32, 0_u8)
      end
    end
    value = @source.read_attribute(attribute_id, 1_u8).as(TLV::Any)
    path = Matter::InteractionModel::AttributePath.new(endpoint: endpoint_id, cluster: cluster_id, attribute: attribute_id)
    data = Matter::InteractionModel::AttributeDataIB.new(path: path, data: value)
    Matter::InteractionModel::ReportDataMessage.new(attribute_reports: [Matter::InteractionModel::AttributeReportIB.new(attribute_data: data)])
  end
end

private class FakeRotationImClient < Matter::Controller::ImClient
  getter commands = [] of UInt32
  getter arm_seconds = [] of UInt16
  getter noc_request : Matter::Cluster::OperationalCredentials::Tlv::AddNocRequest?
  getter update_request : Matter::Cluster::OperationalCredentials::Tlv::UpdateNocRequest?
  property? reject_noc = false
  property? reject_complete = false

  def initialize(@csr_public_key : Bytes)
    super(Matter::Controller::Client.new)
  end

  def close : Nil
    @client.close
  end

  def invoke(session : Matter::Session::SecureContext, peer : Socket::IPAddress,
             endpoint_id : UInt16, cluster_id : UInt32, command_id : UInt32,
             fields : Bytes = Bytes.empty) : Matter::InteractionModel::InvokeResponseMessage
    @commands << command_id
    response_id = command_id
    value = nil.as(TLV::Any?)
    if cluster_id == Matter::Cluster::GeneralCommissioning::CLUSTER_ID &&
       command_id == Matter::Cluster::GeneralCommissioning::CMD_ARM_FAIL_SAFE
      @arm_seconds << Matter::Cluster::GeneralCommissioning::ArmFailSafeRequest.from_slice(fields).expiry_length_seconds
      response_id = Matter::Cluster::GeneralCommissioning::CMD_ARM_FAIL_SAFE_RESPONSE
      value = TLV::Any.from_slice(Matter::Cluster::GeneralCommissioning::ArmFailSafeResponse.new(
        Matter::Commissioning::ErrorCode::OK).to_slice)
    elsif cluster_id == Matter::Cluster::GeneralCommissioning::CLUSTER_ID &&
          command_id == Matter::Cluster::GeneralCommissioning::CMD_COMMISSIONING_COMPLETE
      response_id = Matter::Cluster::GeneralCommissioning::CMD_COMMISSIONING_COMPLETE_RESPONSE
      value = TLV::Any.from_slice(Matter::Cluster::GeneralCommissioning::CommissioningCompleteResponse.new(
        reject_complete? ? Matter::Commissioning::ErrorCode::NoFailSafe : Matter::Commissioning::ErrorCode::OK).to_slice)
    elsif cluster_id == Matter::Cluster::OperationalCredentials::CLUSTER_ID &&
          command_id == Matter::Cluster::OperationalCredentials::CMD_CSR_REQUEST
      response_id = Matter::Cluster::OperationalCredentials::CMD_CSR_REQUEST_RESPONSE
      der = Bytes[0x30, 0x03, 0x42, 0x00] + @csr_public_key
      elements = Matter::Cluster::OperationalCredentials::CSRElements.new(der, Bytes.new(32))
      value = TLV::Any.from_slice(Matter::Cluster::OperationalCredentials::Tlv::CsrResponse.new(
        elements.to_slice, Bytes.empty).to_slice)
    elsif cluster_id == Matter::Cluster::OperationalCredentials::CLUSTER_ID &&
          command_id == Matter::Cluster::OperationalCredentials::CMD_ADD_NOC
      @noc_request = Matter::Cluster::OperationalCredentials::Tlv::AddNocRequest.from_slice(fields)
      response_id = Matter::Cluster::OperationalCredentials::CMD_ADD_NOC_RESPONSE
      status = reject_noc? ? Matter::Cluster::OperationalCredentials::Tlv::NodeOperationalCertificateStatus::InvalidNoc : Matter::Cluster::OperationalCredentials::Tlv::NodeOperationalCertificateStatus::Ok
      value = TLV::Any.from_slice(Matter::Cluster::OperationalCredentials::Tlv::TlvNocResponse.new(status, 2_u8).to_slice)
    elsif cluster_id == Matter::Cluster::OperationalCredentials::CLUSTER_ID &&
          command_id == Matter::Cluster::OperationalCredentials::CMD_UPDATE_NOC
      @update_request = Matter::Cluster::OperationalCredentials::Tlv::UpdateNocRequest.from_slice(fields)
      response_id = Matter::Cluster::OperationalCredentials::CMD_ADD_NOC_RESPONSE
      value = TLV::Any.from_slice(Matter::Cluster::OperationalCredentials::Tlv::TlvNocResponse.new(
        Matter::Cluster::OperationalCredentials::Tlv::NodeOperationalCertificateStatus::Ok, 1_u8).to_slice)
    end
    path = Matter::InteractionModel::CommandPath.new(endpoint: endpoint_id, cluster: cluster_id, command: response_id)
    if data = value
      ib = Matter::InteractionModel::CommandDataIBTlv.new(path, data)
      Matter::InteractionModel::InvokeResponseMessage.new(invoke_responses: [Matter::InteractionModel::InvokeResponseIB.new(command_data: ib)])
    else
      status = Matter::InteractionModel::CommandStatusIB.new(path,
        Matter::InteractionModel::StatusIB.new(Matter::InteractionModel::StatusCode::Success.value))
      Matter::InteractionModel::InvokeResponseMessage.new(invoke_responses: [Matter::InteractionModel::InvokeResponseIB.new(command_status: status)])
    end
  end
end

private class FakeCredentialTransition < Matter::Controller::AnchorTransfer::CredentialTransition
  getter target_node_id : UInt64
  property? fail_transition = false

  def initialize(@label : String, @events : Array(String), @target_node_id : UInt64 = 0x100_u64)
  end

  def transition! : UInt8
    @events << @label
    raise Matter::TransportError.new("Administrator rotation interrupted") if fail_transition?
    2_u8
  end
end

private class FakeFollowUpImClient < Matter::Controller::ImClient
  getter commands = [] of UInt32
  getter peer_icac_key = Matter::Crypto::Key.generate_key_pair
  property? old_present = true
  property? reject_icac = false
  property? reject_complete = false

  def initialize(@old_fabric_id : UInt64, @old_root_public_key : Bytes)
    super(Matter::Controller::Client.new)
  end

  def close : Nil
    @client.close
  end

  def read_attribute(session : Matter::Session::SecureContext, peer : Socket::IPAddress,
                     endpoint_id : UInt16, cluster_id : UInt32, attribute_id : UInt32,
                     fabric_filtered : Bool = true) : Matter::InteractionModel::ReportDataMessage
    descriptors = if old_present?
                    [Matter::Cluster::OperationalCredentials::Tlv::FabricDescriptor.new(
                      @old_root_public_key, 0xFFF1_u16, @old_fabric_id, 0x300_u64,
                      "old", 1_u8)]
                  else
                    [] of Matter::Cluster::OperationalCredentials::Tlv::FabricDescriptor
                  end
    path = Matter::InteractionModel::AttributePath.new(endpoint: endpoint_id,
      cluster: cluster_id, attribute: attribute_id)
    data = Matter::InteractionModel::AttributeDataIB.new(path: path,
      data: TLV::Any.from_slice(descriptors.to_tlv))
    Matter::InteractionModel::ReportDataMessage.new(attribute_reports: [
      Matter::InteractionModel::AttributeReportIB.new(attribute_data: data),
    ])
  end

  def invoke(session : Matter::Session::SecureContext, peer : Socket::IPAddress,
             endpoint_id : UInt16, cluster_id : UInt32, command_id : UInt32,
             fields : Bytes = Bytes.empty) : Matter::InteractionModel::InvokeResponseMessage
    @commands << command_id
    response_id = command_id
    value = nil.as(TLV::Any?)
    case {cluster_id, command_id}
    when {Matter::Cluster::GeneralCommissioning::CLUSTER_ID, Matter::Cluster::GeneralCommissioning::CMD_ARM_FAIL_SAFE}
      response_id = Matter::Cluster::GeneralCommissioning::CMD_ARM_FAIL_SAFE_RESPONSE
      value = TLV::Any.from_slice(Matter::Cluster::GeneralCommissioning::ArmFailSafeResponse.new(
        Matter::Commissioning::ErrorCode::OK).to_slice)
    when {Matter::Cluster::JointFabricAdministrator::CLUSTER_ID, Matter::Cluster::JointFabricAdministrator::CMD_ICACCSR_REQUEST}
      response_id = Matter::Cluster::JointFabricAdministrator::CMD_ICACCSR_REQUEST_RESPONSE
      csr = Matter::Crypto::Pkcs10.create(@peer_icac_key, Matter::Crypto::StandardCrypto.new)
      value = TLV::Any.from_slice(Matter::Cluster::JointFabricAdministrator::ICACCSRResponse.new(
        Matter::Cluster::JointFabricAdministrator::ICACCSRResponseStatusCodeEnum::OK, csr).to_slice)
    when {Matter::Cluster::JointFabricAdministrator::CLUSTER_ID, Matter::Cluster::JointFabricAdministrator::CMD_ADD_ICAC}
      response_id = Matter::Cluster::JointFabricAdministrator::CMD_ADD_ICAC_RESPONSE
      status = reject_icac? ? Matter::Cluster::JointFabricAdministrator::ICACResponseStatusEnum::InvalidICAC : Matter::Cluster::JointFabricAdministrator::ICACResponseStatusEnum::OK
      value = TLV::Any.from_slice(Matter::Cluster::JointFabricAdministrator::ICACResponse.new(status).to_slice)
    when {Matter::Cluster::GeneralCommissioning::CLUSTER_ID, Matter::Cluster::GeneralCommissioning::CMD_COMMISSIONING_COMPLETE}
      response_id = Matter::Cluster::GeneralCommissioning::CMD_COMMISSIONING_COMPLETE_RESPONSE
      status = reject_complete? ? Matter::Commissioning::ErrorCode::NoFailSafe : Matter::Commissioning::ErrorCode::OK
      value = TLV::Any.from_slice(Matter::Cluster::GeneralCommissioning::CommissioningCompleteResponse.new(status).to_slice)
    when {Matter::Cluster::OperationalCredentials::CLUSTER_ID, Matter::Cluster::OperationalCredentials::CMD_REMOVE_FABRIC}
      request = Matter::Cluster::OperationalCredentials::Tlv::RemoveFabricRequest.from_slice(fields)
      request.fabric_index.should eq(1_u8)
      @old_present = false
      response_id = Matter::Cluster::OperationalCredentials::CMD_ADD_NOC_RESPONSE
      response = Matter::Cluster::OperationalCredentials::Tlv::TlvNocResponse.new(
        Matter::Cluster::OperationalCredentials::Tlv::NodeOperationalCertificateStatus::Ok, 1_u8)
      value = TLV::Any.from_slice(response.to_slice)
    end
    path = Matter::InteractionModel::CommandPath.new(endpoint: endpoint_id,
      cluster: cluster_id, command: response_id)
    if data = value
      ib = Matter::InteractionModel::CommandDataIBTlv.new(path, data)
      Matter::InteractionModel::InvokeResponseMessage.new(invoke_responses: [
        Matter::InteractionModel::InvokeResponseIB.new(command_data: ib),
      ])
    else
      status = Matter::InteractionModel::CommandStatusIB.new(path,
        Matter::InteractionModel::StatusIB.new(Matter::InteractionModel::StatusCode::Success.value))
      Matter::InteractionModel::InvokeResponseMessage.new(invoke_responses: [
        Matter::InteractionModel::InvokeResponseIB.new(command_status: status),
      ])
    end
  end
end

private def committed_anchor_store : Matter::Cluster::JointFabricDatastore
  store = Matter::Cluster::JointFabricDatastore.new(Matter::DataType::EndpointNumber.new(0_u16))
  store.status = Matter::Cluster::JointFabricDatastore::DatastoreStatusEntryStruct.new(
    Matter::Cluster::JointFabricDatastore::DatastoreStateEnum::Committed, 0_u32, 0_u8)
  store
end

describe Matter::Controller::AnchorTransfer::Workflow do
  it "reads a frozen old Anchor snapshot over authenticated IM" do
    source = committed_anchor_store
    source.status = Matter::Cluster::JointFabricDatastore::DatastoreStatusEntryStruct.new(
      Matter::Cluster::JointFabricDatastore::DatastoreStateEnum::DeletePending, 0_u32, 0_u8)
    source.anchor_node_id = 0x100_u64
    source.friendly_name = "old anchor"
    im = FakeAnchorReadImClient.new(source)
    session = Matter::Session::SecureContext.new(session_id: 1_u16, peer_session_id: 1_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16), decryption_key: Bytes.new(16))

    snapshot = Matter::Controller::AnchorTransfer::Snapshot.read_remote(im, session,
      Socket::IPAddress.new("127.0.0.1", 5540), 1_u16)

    snapshot.anchor_node_id.should eq(0x100_u64)
    snapshot.friendly_name.should eq("old anchor")
    snapshot.status.state.should eq(Matter::Cluster::JointFabricDatastore::DatastoreStateEnum::DeletePending)
    im.change_status_between_reads = true
    im.reset_status_reads
    expect_raises(Matter::CommissioningError, /not frozen|changed/) do
      Matter::Controller::AnchorTransfer::Snapshot.read_remote(im, session,
        Socket::IPAddress.new("127.0.0.1", 5540), 1_u16)
    end
  ensure
    im.try(&.close)
  end

  it "copies all datastore lists and promotes candidate Node ID" do
    source = committed_anchor_store
    source.anchor_root_ca = Bytes[0x15, 0x18]
    source.anchor_node_id = 0x100_u64
    source.group_key_set_list = [Matter::Cluster::JointFabricDatastore::DatastoreGroupKeySetStruct.new(
      1_u16, Matter::Cluster::JointFabricDatastore::DatastoreGroupKeySecurityPolicyEnum::TrustFirst,
      Bytes.new(16, 1_u8), 0_u64, nil, nil, nil, nil)]
    candidate = committed_anchor_store

    Matter::Controller::AnchorTransfer::Snapshot.copy!(source, candidate, 0x200_u64)

    candidate.anchor_node_id.should eq(0x200_u64)
    candidate.anchor_root_ca.should eq(source.anchor_root_ca)
    candidate.group_key_set_list.should eq(source.group_key_set_list)
    candidate.status.state.should eq(Matter::Cluster::JointFabricDatastore::DatastoreStateEnum::Committed)
  end

  it "replaces the candidate's old fabric identity throughout the copied Datastore" do
    old_id = 0xA103_u64
    new_id = 0xB102_u64
    status = TransferDatastore::DatastoreStatusEntryStruct.new(TransferDatastore::DatastoreStateEnum::Committed, 1_u32, 0_u8)
    source = committed_anchor_store
    source.admin_list = [
      TransferDatastore::DatastoreAdministratorInformationEntryStruct.new(old_id, "candidate", 1_u16, Bytes[1]),
      TransferDatastore::DatastoreAdministratorInformationEntryStruct.new(0xA102_u64, "other", 1_u16, Bytes[2]),
    ]
    source.node_list = [TransferDatastore::DatastoreNodeInformationEntryStruct.new(old_id, "candidate", status)]
    source.node_key_set_list = [TransferDatastore::DatastoreNodeKeySetEntryStruct.new(old_id, 1_u16, status)]
    source.endpoint_group_id_list = [TransferDatastore::DatastoreEndpointGroupIDEntryStruct.new(old_id, 1_u16, 1_u16, status)]
    source.node_endpoint_list = [TransferDatastore::DatastoreEndpointEntryStruct.new(1_u16, old_id, "endpoint")]
    source.endpoint_binding_list = [TransferDatastore::DatastoreEndpointBindingEntryStruct.new(
      old_id, 1_u16, 1_u16, TransferDatastore::DatastoreBindingTargetStruct.new(old_id), status)]
    acl = TransferDatastore::DatastoreAccessControlEntryStruct.new(
      TransferDatastore::DatastoreAccessControlEntryPrivilegeEnum::Administer,
      TransferDatastore::DatastoreAccessControlEntryAuthModeEnum::CASE, [old_id], nil)
    source.node_acl_list = [TransferDatastore::DatastoreACLEntryStruct.new(old_id, 1_u16, acl, status)]
    candidate = committed_anchor_store
    replacement = TransferDatastore::DatastoreAdministratorInformationEntryStruct.new(new_id, "new Anchor", 2_u16, Bytes[3])

    Matter::Controller::AnchorTransfer::Snapshot.copy!(source, candidate, new_id, old_id, replacement)

    candidate.anchor_node_id.should eq(new_id)
    candidate.admin_list.map(&.node_id).should eq([new_id, 0xA102_u64])
    candidate.admin_list.first.icac.should eq(Bytes[3])
    candidate.node_list.first.node_id.should eq(new_id)
    candidate.node_key_set_list.first.node_id.should eq(new_id)
    candidate.endpoint_group_id_list.first.node_id.should eq(new_id)
    candidate.node_endpoint_list.first.node_id.should eq(new_id)
    candidate.endpoint_binding_list.first.node_id.should eq(new_id)
    candidate.endpoint_binding_list.first.binding.node.should eq(new_id)
    candidate.node_acl_list.first.node_id.should eq(new_id)
    candidate.node_acl_list.first.acl_entry.subjects.should eq([new_id])
  end

  it "round-trips a transfer journal for restart recovery" do
    journal = Matter::Controller::AnchorTransfer::Journal.new(
      0x200_u64, Matter::Controller::AnchorTransfer::Stage::Copying)
    loaded = Matter::Controller::AnchorTransfer::Journal.from_document(journal.to_document)
    loaded.candidate_node_id.should eq(0x200_u64)
    loaded.stage.should eq(Matter::Controller::AnchorTransfer::Stage::Copying)
    loaded.rotated_administrator_node_ids.should be_empty
    loaded.active_rotation_node_id.should be_nil

    legacy = Matter::Storage::Document.new
    legacy["candidate_node_id"] = 0x200_u64
    legacy["stage"] = "Copying"
    restored = Matter::Controller::AnchorTransfer::Journal.from_document(legacy)
    restored.rotated_administrator_node_ids.should be_empty
    restored.active_rotation_node_id.should be_nil
  end

  it "orders the accepted transfer and saves every boundary" do
    store = committed_anchor_store
    port = FakeAnchorPort.new
    migration = FakeAnchorMigration.new
    saved = [] of Matter::Controller::AnchorTransfer::Stage
    journal = Matter::Controller::AnchorTransfer::Journal.new(0x200_u64)
    workflow = Matter::Controller::AnchorTransfer::Workflow.new(
      store, port, migration, -> { true }, ->(state : Matter::Controller::AnchorTransfer::Journal) { saved << state.stage; nil }, journal)

    workflow.run

    port.calls.should eq(["request", "complete"])
    migration.calls.should eq(["copy", "rotate", "promote", "follow-up"])
    saved.should eq([
      Matter::Controller::AnchorTransfer::Stage::Requesting,
      Matter::Controller::AnchorTransfer::Stage::Requested,
      Matter::Controller::AnchorTransfer::Stage::Copying,
      Matter::Controller::AnchorTransfer::Stage::Copied,
      Matter::Controller::AnchorTransfer::Stage::Rotating,
      Matter::Controller::AnchorTransfer::Stage::Rotated,
      Matter::Controller::AnchorTransfer::Stage::Promoting,
      Matter::Controller::AnchorTransfer::Stage::Promoted,
      Matter::Controller::AnchorTransfer::Stage::Completing,
      Matter::Controller::AnchorTransfer::Stage::Transferred,
      Matter::Controller::AnchorTransfer::Stage::FollowingUp,
      Matter::Controller::AnchorTransfer::Stage::Completed,
    ])
    workflow.run
    port.calls.size.should eq(2)
  end

  it "blocks request when an individual entry is pending or consent is absent" do
    store = committed_anchor_store
    pending = Matter::Cluster::JointFabricDatastore::DatastoreStatusEntryStruct.new(
      Matter::Cluster::JointFabricDatastore::DatastoreStateEnum::DeletePending, 0_u32, 0_u8)
    store.node_list = [Matter::Cluster::JointFabricDatastore::DatastoreNodeInformationEntryStruct.new(0x100_u64, "device", pending)]
    port = FakeAnchorPort.new
    migration = FakeAnchorMigration.new
    journal = Matter::Controller::AnchorTransfer::Journal.new(0x200_u64)
    workflow = Matter::Controller::AnchorTransfer::Workflow.new(
      store, port, migration, -> { true }, ->(_state : Matter::Controller::AnchorTransfer::Journal) { nil }, journal)
    expect_raises(Matter::CommissioningError, /pending/) { workflow.run }
    port.calls.should be_empty

    store.node_list = [] of Matter::Cluster::JointFabricDatastore::DatastoreNodeInformationEntryStruct
    denied = Matter::Controller::AnchorTransfer::Workflow.new(
      store, port, migration, -> { false }, ->(_state : Matter::Controller::AnchorTransfer::Journal) { nil }, journal)
    expect_raises(Matter::CommissioningError, /consent/) { denied.run }
    port.calls.should be_empty
  end

  it "requires reconciliation after an uncertain copy and resumes after it" do
    store = committed_anchor_store
    port = FakeAnchorPort.new
    migration = FakeAnchorMigration.new
    migration.fail_copy = true
    journal = Matter::Controller::AnchorTransfer::Journal.new(0x200_u64)
    workflow = Matter::Controller::AnchorTransfer::Workflow.new(
      store, port, migration, -> { true }, ->(_state : Matter::Controller::AnchorTransfer::Journal) { nil }, journal)

    expect_raises(Matter::TransportError, /copy interrupted/) { workflow.run }
    workflow.journal.stage.should eq(Matter::Controller::AnchorTransfer::Stage::Copying)
    expect_raises(Matter::CommissioningError, /reconciliation/) { workflow.run }
    expect_raises(Matter::ConfigurationError, /Invalid Anchor transfer reconciliation/) do
      workflow.reconcile!(Matter::Controller::AnchorTransfer::Stage::Promoted)
    end
    workflow.reconcile!(Matter::Controller::AnchorTransfer::Stage::Requested)
    migration.fail_copy = false
    workflow.run
    port.calls.should eq(["request", "complete"])
    workflow.journal.stage.should eq(Matter::Controller::AnchorTransfer::Stage::Completed)
  end

  it "records an observed completed Administrator rotation before stage recovery" do
    journal = Matter::Controller::AnchorTransfer::Journal.new(0x200_u64,
      Matter::Controller::AnchorTransfer::Stage::Rotating)
    journal.active_rotation_node_id = 0x300_u64
    journal.rotated_administrator_node_ids = [0x100_u64]
    saved = [] of Matter::Controller::AnchorTransfer::Journal
    workflow = Matter::Controller::AnchorTransfer::Workflow.new(
      committed_anchor_store, FakeAnchorPort.new, FakeAnchorMigration.new,
      -> { true }, ->(state : Matter::Controller::AnchorTransfer::Journal) {
      saved << Matter::Controller::AnchorTransfer::Journal.from_document(state.to_document)
      nil
    }, journal)

    expect_raises(Matter::CommissioningError, /rotation needs reconciliation/) do
      workflow.reconcile!(Matter::Controller::AnchorTransfer::Stage::Copied)
    end
    expect_raises(Matter::ConfigurationError, /Invalid Administrator rotation reconciliation/) do
      workflow.reconcile_rotation!(0x400_u64, completed: true)
    end
    workflow.reconcile_rotation!(0x300_u64, completed: true)

    workflow.journal.rotated_administrator_node_ids.should eq([0x100_u64, 0x300_u64])
    workflow.journal.active_rotation_node_id.should be_nil
    saved.last.rotated_administrator_node_ids.should eq([0x100_u64, 0x300_u64])
    workflow.reconcile!(Matter::Controller::AnchorTransfer::Stage::Copied)
  end

  it "journals TransferAnchorComplete separately from participant follow-up" do
    store = committed_anchor_store
    port = FakeAnchorPort.new
    migration = FakeAnchorMigration.new
    migration.fail_follow_up = true
    journal = Matter::Controller::AnchorTransfer::Journal.new(0x200_u64)
    workflow = Matter::Controller::AnchorTransfer::Workflow.new(
      store, port, migration, -> { true },
      ->(_state : Matter::Controller::AnchorTransfer::Journal) { nil }, journal)

    expect_raises(Matter::TransportError, /follow-up interrupted/) { workflow.run }
    port.calls.should eq(["request", "complete"])
    workflow.journal.stage.should eq(Matter::Controller::AnchorTransfer::Stage::FollowingUp)
    expect_raises(Matter::TransportError, /follow-up interrupted/) { workflow.run }
    workflow.journal.stage.should eq(Matter::Controller::AnchorTransfer::Stage::FollowingUp)
    migration.fail_follow_up = false
    workflow.run
    port.calls.should eq(["request", "complete"])
    workflow.journal.stage.should eq(Matter::Controller::AnchorTransfer::Stage::Completed)
  end
end

describe Matter::Controller::AnchorTransfer::AdministratorRotation do
  it "disarms the old CASE fail-safe when AddNOC is rejected" do
    bootstrap = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(0x1234_u64, 0x200_u64, 0xFFF2_u16)
    im = FakeRotationImClient.new(Matter::Crypto::Key.generate_key_pair.public_key)
    im.reject_noc = true
    client = Matter::Controller::Client.new
    session = Matter::Session::SecureContext.new(session_id: 1_u16, peer_session_id: 1_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16), decryption_key: Bytes.new(16))
    rotation = Matter::Controller::AnchorTransfer::AdministratorRotation.new(
      client, im, session, Socket::IPAddress.new("127.0.0.1", 5540), 0x300_u64,
      bootstrap, 2_u16, 1_u16)

    expect_raises(Matter::CommissioningError, /AddNOC failed/) { rotation.transition! }
    im.arm_seconds.should eq([900_u16, 0_u16])
  ensure
    im.try(&.close)
    client.try(&.close)
  end

  it "reports a rejected CommissioningComplete response" do
    bootstrap = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(0x1234_u64, 0x200_u64, 0xFFF2_u16)
    im = FakeRotationImClient.new(Matter::Crypto::Key.generate_key_pair.public_key)
    im.reject_complete = true
    client = Matter::Controller::Client.new
    session = Matter::Session::SecureContext.new(session_id: 1_u16, peer_session_id: 1_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16), decryption_key: Bytes.new(16))
    rotation = Matter::Controller::AnchorTransfer::AdministratorRotation.new(
      client, im, session, Socket::IPAddress.new("127.0.0.1", 5540), 0x300_u64,
      bootstrap, 2_u16, 2_u16, anchor_target: true,
      case_opener: ->(_fabric : Matter::Controller::FabricInfo, _node : UInt64) { session })

    expect_raises(Matter::CommissioningError, /CommissioningComplete failed: NoFailSafe/) { rotation.transition! }
    im.arm_seconds.should eq([900_u16, 0_u16])
  ensure
    im.try(&.close)
    client.try(&.close)
  end

  it "adds a new Anchor root and CAT NOC before completing on new CASE" do
    bootstrap = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      0x1234_u64, 0x200_u64, 0xFFF2_u16)
    target_key = Matter::Crypto::Key.generate_key_pair
    im = FakeRotationImClient.new(target_key.public_key)
    client = Matter::Controller::Client.new
    session = Matter::Session::SecureContext.new(session_id: 1_u16, peer_session_id: 1_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16), decryption_key: Bytes.new(16))
    opener = ->(_fabric : Matter::Controller::FabricInfo, _node : UInt64) { session }
    rotation = Matter::Controller::AnchorTransfer::AdministratorRotation.new(
      client, im, session, Socket::IPAddress.new("127.0.0.1", 5540), 0x300_u64,
      bootstrap, 2_u16, 2_u16, anchor_target: true, case_opener: opener)

    rotation.transition!.should eq(2_u8)

    im.commands.should eq([
      Matter::Cluster::GeneralCommissioning::CMD_ARM_FAIL_SAFE,
      Matter::Cluster::OperationalCredentials::CMD_ADD_TRUSTED_ROOT_CERTIFICATE,
      Matter::Cluster::OperationalCredentials::CMD_CSR_REQUEST,
      Matter::Cluster::OperationalCredentials::CMD_ADD_NOC,
      Matter::Cluster::GeneralCommissioning::CMD_COMMISSIONING_COMPLETE,
    ])
    noc = im.noc_request.as(Matter::Cluster::OperationalCredentials::Tlv::AddNocRequest)
    noc.case_admin_subject.should eq(0xFFFF_FFFD_FFFE_0001_u64)
    subjects = Matter::Crypto::MatterCertificate.subject_ids_from_tlv(noc.noc_value)
    subjects.should contain(0x300_u64)
    subjects.should contain(0xFFFF_FFFD_FFFF_0002_u64)
    subjects.should contain(0xFFFF_FFFD_FFFE_0002_u64)
  ensure
    im.try(&.close)
    client.try(&.close)
  end

  it "updates the candidate's existing Anchor fabric without adding its root again" do
    bootstrap = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      0x1234_u64, 0x200_u64, 0xFFF2_u16)
    im = FakeRotationImClient.new(Matter::Crypto::Key.generate_key_pair.public_key)
    client = Matter::Controller::Client.new
    session = Matter::Session::SecureContext.new(session_id: 1_u16, peer_session_id: 1_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16), decryption_key: Bytes.new(16))
    opener = ->(_fabric : Matter::Controller::FabricInfo, _node : UInt64) { session }
    rotation = Matter::Controller::AnchorTransfer::AdministratorRotation.new(
      client, im, session, Socket::IPAddress.new("127.0.0.1", 5540), 0x300_u64,
      bootstrap, 2_u16, 2_u16, anchor_target: true,
      existing_fabric: true, existing_fabric_index: 3_u8, case_opener: opener)

    rotation.transition!.should eq(1_u8)
    im.commands.should eq([
      Matter::Cluster::GeneralCommissioning::CMD_ARM_FAIL_SAFE,
      Matter::Cluster::OperationalCredentials::CMD_CSR_REQUEST,
      Matter::Cluster::OperationalCredentials::CMD_UPDATE_NOC,
      Matter::Cluster::GeneralCommissioning::CMD_COMMISSIONING_COMPLETE,
    ])
    request = im.update_request.as(Matter::Cluster::OperationalCredentials::Tlv::UpdateNocRequest)
    request.fabric_index.should eq(3_u8)
    Matter::Crypto::MatterCertificate.subject_ids_from_tlv(request.noc_value)
      .should contain(0xFFFF_FFFD_FFFE_0002_u64)
  ensure
    im.try(&.close)
    client.try(&.close)
  end
end

describe Matter::Controller::AnchorTransfer::RotationMigration do
  it "cannot reconcile a resumed rotation that omits a Datastore Administrator" do
    source = committed_anchor_store
    candidate = committed_anchor_store
    candidate.admin_list = [
      TransferDatastore::DatastoreAdministratorInformationEntryStruct.new(0x100_u64, "old Anchor", 1_u16, Bytes[1]),
      TransferDatastore::DatastoreAdministratorInformationEntryStruct.new(0x300_u64, "omitted peer", 1_u16, Bytes[2]),
      TransferDatastore::DatastoreAdministratorInformationEntryStruct.new(0x200_u64, "candidate", 1_u16, Bytes[3]),
    ]
    im = FakeAnchorReadImClient.new(source)
    session = Matter::Session::SecureContext.new(session_id: 1_u16, peer_session_id: 1_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16), decryption_key: Bytes.new(16))
    events = [] of String
    old_anchor = FakeCredentialTransition.new("old Anchor", events, 0x100_u64)
    candidate_rotation = FakeCredentialTransition.new("candidate", events, 0x200_u64)
    bootstrap = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(0x1234_u64, 0x200_u64, 0xFFF2_u16)
    migration = Matter::Controller::AnchorTransfer::RotationMigration.new(
      im, session, Socket::IPAddress.new("127.0.0.1", 5540), 1_u16,
      candidate, 0x200_u64, bootstrap,
      [old_anchor.as(Matter::Controller::AnchorTransfer::CredentialTransition)],
      candidate_rotation, -> { nil }, -> { nil }, finalize_administrators: -> { nil })
    journal = Matter::Controller::AnchorTransfer::Journal.new(0x200_u64,
      Matter::Controller::AnchorTransfer::Stage::Rotating)
    journal.rotated_administrator_node_ids = [0x100_u64]
    workflow = Matter::Controller::AnchorTransfer::Workflow.new(source,
      FakeAnchorPort.new, migration, -> { true },
      ->(_state : Matter::Controller::AnchorTransfer::Journal) { nil }, journal)

    expect_raises(Matter::ConfigurationError, /every other Datastore Administrator/) do
      workflow.reconcile!(Matter::Controller::AnchorTransfer::Stage::Rotated)
    end
    workflow.journal.stage.should eq(Matter::Controller::AnchorTransfer::Stage::Rotating)
  ensure
    im.try(&.close)
  end

  it "resumes a three-Administrator rotation without replaying completed credentials" do
    source = committed_anchor_store
    candidate = committed_anchor_store
    candidate.admin_list = [
      TransferDatastore::DatastoreAdministratorInformationEntryStruct.new(0x100_u64, "old Anchor", 1_u16, Bytes[1]),
      TransferDatastore::DatastoreAdministratorInformationEntryStruct.new(0x300_u64, "peer", 1_u16, Bytes[2]),
      TransferDatastore::DatastoreAdministratorInformationEntryStruct.new(0x200_u64, "candidate", 1_u16, Bytes[3]),
    ]
    candidate.anchor_node_id = 0x200_u64
    bootstrap = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(0x1234_u64, 0x200_u64, 0xFFF2_u16)
    candidate.anchor_root_ca = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      0x4321_u64, 0x100_u64, 0xFFF1_u16).fabric.root_cert
    im = FakeAnchorReadImClient.new(source)
    session = Matter::Session::SecureContext.new(session_id: 1_u16, peer_session_id: 1_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16), decryption_key: Bytes.new(16))
    events = [] of String
    old_anchor = FakeCredentialTransition.new("old Anchor", events, 0x100_u64)
    peer = FakeCredentialTransition.new("peer", events, 0x300_u64)
    peer.fail_transition = true
    candidate_rotation = FakeCredentialTransition.new("candidate", events, 0x200_u64)
    rotations = [old_anchor.as(Matter::Controller::AnchorTransfer::CredentialTransition),
                 peer.as(Matter::Controller::AnchorTransfer::CredentialTransition)]
    saved = [] of Matter::Controller::AnchorTransfer::Journal
    persist = -> { events << "persist"; nil }
    save = ->(state : Matter::Controller::AnchorTransfer::Journal) {
      saved << Matter::Controller::AnchorTransfer::Journal.from_document(state.to_document)
      nil
    }
    build_migration = -> {
      Matter::Controller::AnchorTransfer::RotationMigration.new(
        im, session, Socket::IPAddress.new("127.0.0.1", 5540), 1_u16,
        candidate, 0x200_u64, bootstrap, rotations, candidate_rotation,
        persist, -> { events << "advertise"; nil },
        finalize_administrators: -> { events << "follow-up"; nil })
    }
    journal = Matter::Controller::AnchorTransfer::Journal.new(0x200_u64,
      Matter::Controller::AnchorTransfer::Stage::Copied)
    workflow = Matter::Controller::AnchorTransfer::Workflow.new(source,
      FakeAnchorPort.new, build_migration.call, -> { true }, save, journal)

    expect_raises(Matter::TransportError, /rotation interrupted/) { workflow.run }
    workflow.journal.stage.should eq(Matter::Controller::AnchorTransfer::Stage::Rotating)
    workflow.journal.rotated_administrator_node_ids.should eq([0x100_u64])
    workflow.journal.active_rotation_node_id.should eq(0x300_u64)
    saved.last.active_rotation_node_id.should eq(0x300_u64)

    restored = Matter::Controller::AnchorTransfer::Journal.from_document(workflow.journal.to_document)
    peer.fail_transition = false
    resumed = Matter::Controller::AnchorTransfer::Workflow.new(source,
      FakeAnchorPort.new, build_migration.call, -> { true }, save, restored)
    expect_raises(Matter::CommissioningError, /reconciliation/) { resumed.run }
    resumed.reconcile_rotation!(0x300_u64, completed: false)
    expect_raises(Matter::CommissioningError, /Administrators remain unrotated/) do
      resumed.reconcile!(Matter::Controller::AnchorTransfer::Stage::Rotated)
    end
    resumed.reconcile!(Matter::Controller::AnchorTransfer::Stage::Copied)
    resumed.run

    events.count("old Anchor").should eq(1)
    events.count("peer").should eq(2)
    events.count("candidate").should eq(1)
    resumed.journal.rotated_administrator_node_ids.should eq([0x100_u64, 0x300_u64])
    resumed.journal.stage.should eq(Matter::Controller::AnchorTransfer::Stage::Completed)
  ensure
    im.try(&.close)
  end

  it "refuses a transfer snapshot when rotations omit an Administrator" do
    source = committed_anchor_store
    source.status = TransferDatastore::DatastoreStatusEntryStruct.new(
      TransferDatastore::DatastoreStateEnum::DeletePending, 0_u32, 0_u8)
    source.admin_list = [
      TransferDatastore::DatastoreAdministratorInformationEntryStruct.new(0x100_u64, "old Anchor", 1_u16, Bytes[1]),
      TransferDatastore::DatastoreAdministratorInformationEntryStruct.new(0x300_u64, "uncovered", 1_u16, Bytes[2]),
      TransferDatastore::DatastoreAdministratorInformationEntryStruct.new(0x200_u64, "candidate", 1_u16, Bytes[3]),
    ]
    im = FakeAnchorReadImClient.new(source)
    bootstrap = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(0x1234_u64, 0x200_u64, 0xFFF2_u16)
    session = Matter::Session::SecureContext.new(session_id: 1_u16, peer_session_id: 1_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16), decryption_key: Bytes.new(16))
    events = [] of String
    other = FakeCredentialTransition.new("old Anchor", events, 0x100_u64)
    candidate = FakeCredentialTransition.new("candidate", events, 0x200_u64)
    migration = Matter::Controller::AnchorTransfer::RotationMigration.new(
      im, session, Socket::IPAddress.new("127.0.0.1", 5540), 1_u16,
      committed_anchor_store, 0x200_u64, bootstrap,
      [other.as(Matter::Controller::AnchorTransfer::CredentialTransition)], candidate,
      -> { events << "persist"; nil }, -> { events << "advertise"; nil },
      finalize_administrators: -> { events << "follow-up"; nil })

    expect_raises(Matter::ConfigurationError, /every other Datastore Administrator/) { migration.copy_datastore! }
    events.should be_empty
  ensure
    im.try(&.close)
  end

  it "blocks peer rotation when cross-signing and old-fabric removal are not installed" do
    source = committed_anchor_store
    source.admin_list = [
      TransferDatastore::DatastoreAdministratorInformationEntryStruct.new(0x100_u64, "other", 1_u16, Bytes[1]),
      TransferDatastore::DatastoreAdministratorInformationEntryStruct.new(0x200_u64, "candidate", 1_u16, Bytes[2]),
    ]
    source.status = Matter::Cluster::JointFabricDatastore::DatastoreStatusEntryStruct.new(
      Matter::Cluster::JointFabricDatastore::DatastoreStateEnum::DeletePending, 0_u32, 0_u8)
    source.anchor_root_ca = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      0x4321_u64, 0x100_u64, 0xFFF1_u16).fabric.root_cert
    im = FakeAnchorReadImClient.new(source)
    bootstrap = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      0x1234_u64, 0x200_u64, 0xFFF2_u16)
    session = Matter::Session::SecureContext.new(session_id: 1_u16, peer_session_id: 1_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16), decryption_key: Bytes.new(16))
    events = [] of String
    other = FakeCredentialTransition.new("other", events)
    candidate = FakeCredentialTransition.new("candidate", events, 0x200_u64)
    migration = Matter::Controller::AnchorTransfer::RotationMigration.new(
      im, session, Socket::IPAddress.new("127.0.0.1", 5540), 1_u16,
      committed_anchor_store, 0x200_u64, bootstrap,
      [other.as(Matter::Controller::AnchorTransfer::CredentialTransition)], candidate,
      -> { nil }, -> { nil })
    migration.copy_datastore!

    expect_raises(Matter::ConfigurationError, /follow-up/) { migration.preflight! }
    events.should be_empty
    expect_raises(Matter::ConfigurationError, /follow-up/) { migration.follow_up_administrators! }
  ensure
    im.try(&.close)
  end

  it "rotates all three Administrators with newer CAT versions before promotion" do
    old_store = committed_anchor_store
    old_store.group_list = [
      TransferDatastore::DatastoreGroupInformationEntryStruct.new(1_u64, "administrators", nil,
        0xFFFF_u16, 1_u16, TransferDatastore::DatastoreAccessControlEntryPrivilegeEnum::Administer),
      TransferDatastore::DatastoreGroupInformationEntryStruct.new(2_u64, "anchor", nil,
        0xFFFE_u16, 1_u16, TransferDatastore::DatastoreAccessControlEntryPrivilegeEnum::Administer),
    ]
    old_store.admin_list = [
      TransferDatastore::DatastoreAdministratorInformationEntryStruct.new(0x100_u64, "other", 1_u16, Bytes[1]),
      TransferDatastore::DatastoreAdministratorInformationEntryStruct.new(0x300_u64, "peer", 1_u16, Bytes[2]),
      TransferDatastore::DatastoreAdministratorInformationEntryStruct.new(0x200_u64, "candidate", 1_u16, Bytes[3]),
    ]
    old_store.status = Matter::Cluster::JointFabricDatastore::DatastoreStatusEntryStruct.new(
      Matter::Cluster::JointFabricDatastore::DatastoreStateEnum::DeletePending, 0_u32, 0_u8)
    old_store.anchor_node_id = 0x100_u64
    old_store.anchor_root_ca = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      0x4321_u64, 0x100_u64, 0xFFF1_u16).fabric.root_cert
    im = FakeAnchorReadImClient.new(old_store)
    candidate = committed_anchor_store
    bootstrap = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(0x1234_u64, 0x200_u64, 0xFFF2_u16)
    events = [] of String
    other = FakeCredentialTransition.new("other", events)
    peer = FakeCredentialTransition.new("peer", events, 0x300_u64)
    anchor = FakeCredentialTransition.new("anchor", events, 0x200_u64)
    session = Matter::Session::SecureContext.new(session_id: 1_u16, peer_session_id: 1_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16), decryption_key: Bytes.new(16))
    migration = Matter::Controller::AnchorTransfer::RotationMigration.new(
      im, session, Socket::IPAddress.new("127.0.0.1", 5540), 1_u16,
      candidate, 0x200_u64, bootstrap,
      [other.as(Matter::Controller::AnchorTransfer::CredentialTransition),
       peer.as(Matter::Controller::AnchorTransfer::CredentialTransition)], anchor,
      -> { events << "persist"; nil }, -> { events << "advertise"; nil },
      administrator_cat_version: 2_u16, anchor_cat_version: 2_u16,
      finalize_administrators: -> { events << "follow-up"; nil })

    migration.copy_datastore!
    candidate.group_list.map(&.group_cat_version).should eq([2_u16, 2_u16])
    migration.rotate_credentials!
    migration.promote_candidate!
    migration.follow_up_administrators!

    events.should eq(["persist", "other", "persist", "peer", "persist", "anchor", "persist", "advertise", "follow-up"])
    candidate.anchor_node_id.should eq(0x200_u64)
    candidate.anchor_root_ca.should eq(bootstrap.fabric.root_cert)
    candidate.anchor_vendor_id.should eq(bootstrap.fabric.admin_vendor_id)
  ensure
    im.try(&.close)
  end
end

describe Matter::Controller::AnchorTransfer::AdministratorFollowUp do
  it "replays a persisted ICAC into the Datastore when a completed exchange is reconciled" do
    bootstrap = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      0x1234_u64, 0x200_u64, 0xFFF2_u16)
    new_fabric = bootstrap.fabric
    old_fabric = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      0x4321_u64, 0x100_u64, 0xFFF1_u16).fabric
    peer_key = Matter::Crypto::Key.generate_key_pair
    crypto = Matter::Crypto::StandardCrypto.new
    icac = Matter::Crypto::MatterCertificate::Builder.intermediate(
      peer_key.public_key, new_fabric.fabric_id, 3_u64,
      new_fabric.certificate_authority_key, 1_u64, Bytes[1], crypto)
    journal = Matter::Controller::AnchorTransfer::AdministratorFollowUp::Journal.new(
      0x300_u64, Matter::Controller::AnchorTransfer::AdministratorFollowUp::Stage::CrossSigning, icac)
    restored = Matter::Controller::AnchorTransfer::AdministratorFollowUp::Journal.from_document(journal.to_document)
    committed = nil.as(Bytes?)
    im = FakeFollowUpImClient.new(old_fabric.fabric_id, old_fabric.root_public_key)
    client = Matter::Controller::Client.new
    runner = Matter::Controller::AnchorTransfer::AdministratorFollowUp.new(
      client, im, Socket::IPAddress.new("127.0.0.1", 5540), 0x300_u64,
      new_fabric, old_fabric.fabric_id, old_fabric.root_public_key,
      1_u16, peer_key.public_key, 3_u64,
      ->(_state : Matter::Controller::AnchorTransfer::AdministratorFollowUp::Journal) { nil },
      restored, consent: -> { true },
      on_committed_icac: ->(_node_id : UInt64, certificate : Bytes) { committed = certificate; nil })

    runner.reconcile_cross_sign!(true)
    committed.should eq(icac)
    runner.journal.stage.should eq(Matter::Controller::AnchorTransfer::AdministratorFollowUp::Stage::CrossSigned)
    runner.journal.pending_icac.should be_nil
  ensure
    im.try(&.close)
    client.try(&.close)
  end

  it "rejects a failed CommissioningComplete response after ICAC exchange" do
    new_fabric = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      0x1234_u64, 0x200_u64, 0xFFF2_u16).fabric
    old_fabric = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      0x4321_u64, 0x100_u64, 0xFFF1_u16).fabric
    im = FakeFollowUpImClient.new(old_fabric.fabric_id, old_fabric.root_public_key)
    im.reject_complete = true
    client = Matter::Controller::Client.new
    session = Matter::Session::SecureContext.new(session_id: 1_u16, peer_session_id: 1_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16), decryption_key: Bytes.new(16))
    runner = Matter::Controller::AnchorTransfer::AdministratorFollowUp.new(
      client, im, Socket::IPAddress.new("127.0.0.1", 5540), 0x300_u64,
      new_fabric, old_fabric.fabric_id, old_fabric.root_public_key,
      1_u16, im.peer_icac_key.public_key, 3_u64,
      ->(_state : Matter::Controller::AnchorTransfer::AdministratorFollowUp::Journal) { nil },
      consent: -> { true },
      case_opener: ->(_identity : Matter::Controller::FabricInfo, _node : UInt64) { session },
      endpoint_resolver: ->(_im : Matter::Controller::ImClient, _session : Matter::Session::SecureContext, _peer : Socket::IPAddress) { 1_u16 })

    expect_raises(Matter::CommissioningError, /CommissioningComplete failed: NoFailSafe/) { runner.run }
    im.commands.should_not contain(Matter::Cluster::OperationalCredentials::CMD_REMOVE_FABRIC)
  ensure
    im.try(&.close)
    client.try(&.close)
  end

  it "cross-signs under the new Anchor root, commits, then removes the old fabric" do
    new_fabric = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      0x1234_u64, 0x200_u64, 0xFFF2_u16).fabric
    old_fabric = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      0x4321_u64, 0x100_u64, 0xFFF1_u16).fabric
    im = FakeFollowUpImClient.new(old_fabric.fabric_id, old_fabric.root_public_key)
    client = Matter::Controller::Client.new
    session = Matter::Session::SecureContext.new(session_id: 1_u16, peer_session_id: 1_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16), decryption_key: Bytes.new(16))
    saved = [] of Matter::Controller::AnchorTransfer::AdministratorFollowUp::Stage
    pending = [] of Bool
    committed_icac = nil.as(Bytes?)
    consented = false
    runner = Matter::Controller::AnchorTransfer::AdministratorFollowUp.new(
      client, im, Socket::IPAddress.new("127.0.0.1", 5540), 0x300_u64,
      new_fabric, old_fabric.fabric_id, old_fabric.root_public_key,
      1_u16, im.peer_icac_key.public_key, 3_u64,
      ->(state : Matter::Controller::AnchorTransfer::AdministratorFollowUp::Journal) {
        saved << state.stage
        pending << !state.pending_icac.nil?
        nil
      },
      consent: -> { consented },
      case_opener: ->(_identity : Matter::Controller::FabricInfo, _node : UInt64) { session },
      endpoint_resolver: ->(_im : Matter::Controller::ImClient, _session : Matter::Session::SecureContext, _peer : Socket::IPAddress) { 1_u16 },
      on_committed_icac: ->(_node_id : UInt64, certificate : Bytes) { committed_icac = certificate; nil })

    expect_raises(Matter::CommissioningError, /user consent/) { runner.run }
    im.commands.should be_empty
    consented = true
    runner.run

    im.commands.should eq([
      Matter::Cluster::GeneralCommissioning::CMD_ARM_FAIL_SAFE,
      Matter::Cluster::JointFabricAdministrator::CMD_ANNOUNCE_JOINT_FABRIC_ADMINISTRATOR,
      Matter::Cluster::JointFabricAdministrator::CMD_ICACCSR_REQUEST,
      Matter::Cluster::JointFabricAdministrator::CMD_ADD_ICAC,
      Matter::Cluster::GeneralCommissioning::CMD_COMMISSIONING_COMPLETE,
      Matter::Cluster::OperationalCredentials::CMD_REMOVE_FABRIC,
    ])
    saved.should eq([
      Matter::Controller::AnchorTransfer::AdministratorFollowUp::Stage::CrossSigning,
      Matter::Controller::AnchorTransfer::AdministratorFollowUp::Stage::CrossSigning,
      Matter::Controller::AnchorTransfer::AdministratorFollowUp::Stage::CrossSigned,
      Matter::Controller::AnchorTransfer::AdministratorFollowUp::Stage::RemovingOld,
      Matter::Controller::AnchorTransfer::AdministratorFollowUp::Stage::Completed,
    ])
    pending.should eq([false, true, false, false, false])
    Matter::Controller::JointCommissioning.validate_cross_signed_icac(
      committed_icac.as(Bytes), new_fabric, im.peer_icac_key.public_key, 3_u64)
  ensure
    im.try(&.close)
    client.try(&.close)
  end

  it "retries an interrupted old-fabric removal without repeating cross-signing" do
    new_fabric = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      0x1234_u64, 0x200_u64, 0xFFF2_u16).fabric
    old_fabric = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      0x4321_u64, 0x100_u64, 0xFFF1_u16).fabric
    im = FakeFollowUpImClient.new(old_fabric.fabric_id, old_fabric.root_public_key)
    client = Matter::Controller::Client.new
    session = Matter::Session::SecureContext.new(session_id: 1_u16, peer_session_id: 1_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16), decryption_key: Bytes.new(16))
    journal = Matter::Controller::AnchorTransfer::AdministratorFollowUp::Journal.new(0x300_u64, Matter::Controller::AnchorTransfer::AdministratorFollowUp::Stage::RemovingOld)
    saved = [] of Matter::Controller::AnchorTransfer::AdministratorFollowUp::Stage
    runner = Matter::Controller::AnchorTransfer::AdministratorFollowUp.new(client, im, Socket::IPAddress.new("127.0.0.1", 5540),
      0x300_u64, new_fabric, old_fabric.fabric_id, old_fabric.root_public_key,
      1_u16, Matter::Crypto::Key.generate_key_pair.public_key, 3_u64,
      ->(state : Matter::Controller::AnchorTransfer::AdministratorFollowUp::Journal) { saved << state.stage; nil }, journal,
      consent: -> { true },
      case_opener: ->(_identity : Matter::Controller::FabricInfo, _node : UInt64) { session },
      endpoint_resolver: ->(_im : Matter::Controller::ImClient, _session : Matter::Session::SecureContext, _peer : Socket::IPAddress) { 1_u16 })

    runner.run

    im.commands.should eq([Matter::Cluster::OperationalCredentials::CMD_REMOVE_FABRIC])
    saved.should eq([Matter::Controller::AnchorTransfer::AdministratorFollowUp::Stage::Completed])
    runner.run
    im.commands.size.should eq(1)
  ensure
    im.try(&.close)
    client.try(&.close)
  end
end
