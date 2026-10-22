require "../spec_helper"
require "../../src/matter/cluster/thread_border_router_management"

private alias BorderRouter = Matter::Cluster::ThreadBorderRouterManagement
private alias RouterStatus = Matter::InteractionModel::StatusCode

private def router_tlv(type : UInt8, bytes : Bytes) : Bytes
  Bytes[type, bytes.size.to_u8] + bytes
end

private def router_dataset(timestamp : UInt64 = 1_u64) : Bytes
  stamp = Bytes.new(8) { |index| ((timestamp >> ((7 - index) * 8)) & 0xff).to_u8 }
  router_tlv(14_u8, stamp) +
    router_tlv(0_u8, Bytes[0, 0, 15]) +
    router_tlv(53_u8, Bytes[0, 4, 0, 0, 0, 1]) +
    router_tlv(2_u8, Bytes[1, 2, 3, 4, 5, 6, 7, 8]) +
    router_tlv(5_u8, Bytes.new(16, 0xaa_u8)) +
    router_tlv(7_u8, Bytes.new(8, 0xfd_u8)) +
    router_tlv(3_u8, "Home".to_slice) +
    router_tlv(1_u8, Bytes[0x12, 0x34]) +
    router_tlv(4_u8, Bytes.new(16, 0xbb_u8)) +
    router_tlv(12_u8, Bytes[0, 1, 0, 0])
end

private class RouterBackend < BorderRouter::Backend
  property name = "Test Border Router"
  property agent_id = Bytes.new(16, 0xaa_u8)
  property version = 4_u16
  property? enabled = false
  property active : Bytes? = nil
  property pending : Bytes? = nil
  property? activation_result = true
  property? pending_result = true
  property? dataset_valid = true
  property on_activation : Proc(Nil)?
  getter rollback_count = 0

  def border_router_name : String
    @name
  end

  def border_agent_id : Bytes
    @agent_id
  end

  def thread_version : UInt16
    @version
  end

  def interface_enabled? : Bool
    @enabled
  end

  def active_dataset : Bytes?
    @active
  end

  def pending_dataset : Bytes?
    @pending
  end

  def valid_dataset?(dataset : Bytes, pending : Bool) : Bool
    @dataset_valid
  end

  def activate_active_dataset(dataset : Bytes, deadline : Time::Span) : Bool
    deadline.should be > Time::Span.zero
    @on_activation.try(&.call)
    return false unless @activation_result
    @active = dataset.dup
    @enabled = true
    true
  end

  def apply_pending_dataset(dataset : Bytes) : Bool
    return false unless @pending_result
    @pending = dataset.dup
    true
  end

  def restore(active : Bytes?, pending : Bytes?, interface_enabled : Bool) : Nil
    @rollback_count += 1
    @active = active.try(&.dup)
    @pending = pending.try(&.dup)
    @enabled = interface_enabled
  end
end

private def router(feature_map = BorderRouter::Feature::None)
  backend = RouterBackend.new
  commissioning = Matter::Cluster::GeneralCommissioning.new(endpoint(0))
  cluster = BorderRouter.new(endpoint(1), backend, commissioning, feature_map: feature_map)
  {cluster, backend, commissioning}
end

describe BorderRouter do
  it "advertises six Matter 1.6 attributes and feature-gated timed commands" do
    cluster, _, _ = router
    cluster.cluster_id.id.should eq(0x0452_u32)
    cluster.cluster_revision.should eq(1_u16)
    cluster.attributes.map(&.id.id).should eq([
      BorderRouter::ATTR_BORDER_ROUTER_NAME,
      BorderRouter::ATTR_BORDER_AGENT_ID,
      BorderRouter::ATTR_THREAD_VERSION,
      BorderRouter::ATTR_INTERFACE_ENABLED,
      BorderRouter::ATTR_ACTIVE_DATASET_TIMESTAMP,
      BorderRouter::ATTR_PENDING_DATASET_TIMESTAMP,
    ])
    read(cluster, BorderRouter::ATTR_ACTIVE_DATASET_TIMESTAMP).should be_nil
    read(cluster, BorderRouter::ATTR_PENDING_DATASET_TIMESTAMP).should be_nil
    accepted_command_ids(cluster).should_not contain(BorderRouter::CMD_SET_PENDING_DATASET_REQUEST)
    generated_command_ids(cluster).should contain(BorderRouter::CMD_GET_ACTIVE_DATASET_REQUEST_RESPONSE)
    [BorderRouter::CMD_SET_ACTIVE_DATASET_REQUEST, BorderRouter::CMD_GET_ACTIVE_DATASET_REQUEST].each do |id|
      cluster.get_command_metadata(id).as(Matter::Cluster::CommandMetadata).access
        .should eq(Matter::InteractionModel::EntryPrivilege::Manage)
    end
    cluster.get_command_metadata(BorderRouter::CMD_SET_ACTIVE_DATASET_REQUEST).as(Matter::Cluster::CommandMetadata).timed?.should be_true
    pc, _, _ = router(BorderRouter::Feature::PanChange)
    accepted_command_ids(pc).should contain(BorderRouter::CMD_SET_PENDING_DATASET_REQUEST)
    pc.get_command_metadata(BorderRouter::CMD_SET_PENDING_DATASET_REQUEST).as(Matter::Cluster::CommandMetadata).timed?.should be_true
  end

  it "returns empty datasets over CASE but never exposes them over PASE" do
    cluster, backend, _ = router
    [BorderRouter::CMD_GET_ACTIVE_DATASET_REQUEST, BorderRouter::CMD_GET_PENDING_DATASET_REQUEST].each do |id|
      expect_status(invoke(cluster, id), RouterStatus::UnsupportedAccess)
      response = invoke(cluster, id, is_case_session: true).as(Matter::Cluster::CommandResponse)
      BorderRouter::DatasetResponse.from_tlv(response.response.as(TLV::Any)).dataset.should be_empty
    end
    backend.active = router_dataset
    cluster.refresh_host_state
    read(cluster, BorderRouter::ATTR_ACTIVE_DATASET_TIMESTAMP).should eq(1_u64)
    response = invoke(cluster, BorderRouter::CMD_GET_ACTIVE_DATASET_REQUEST, is_case_session: true).as(Matter::Cluster::CommandResponse)
    BorderRouter::DatasetResponse.from_tlv(response.response.as(TLV::Any)).dataset.should eq(router_dataset)
    cluster.save_state.should be_nil
  end

  it "fails closed if the host changes to an invalid dataset without refreshing attributes" do
    cluster, backend, _ = router
    backend.active = Bytes.new(BorderRouter::MAX_DATASET_SIZE + 1, 0xaa_u8)
    expect_status(invoke(cluster, BorderRouter::CMD_GET_ACTIVE_DATASET_REQUEST, is_case_session: true), RouterStatus::Failure)
    backend.pending = Bytes[51, 8, 0, 0, 0, 0, 0, 0, 0, 1]
    expect_status(invoke(cluster, BorderRouter::CMD_GET_PENDING_DATASET_REQUEST, is_case_session: true), RouterStatus::Failure)
  end

  it "requires CASE, fail-safe, valid dataset and empty current active dataset" do
    cluster, backend, commissioning = router
    request = BorderRouter::SetActiveDatasetRequest.new(router_dataset, 9_u64)
    expect_status(invoke(cluster, BorderRouter::CMD_SET_ACTIVE_DATASET_REQUEST, request), RouterStatus::UnsupportedAccess)
    expect_status(invoke(cluster, BorderRouter::CMD_SET_ACTIVE_DATASET_REQUEST, request, is_case_session: true), RouterStatus::FailsafeRequired)
    commissioning.arm_fail_safe(60_u16)
    [Bytes.empty, router_dataset[0, 10],
     router_dataset + router_tlv(14_u8, Bytes.new(8)),
     router_dataset + router_tlv(200_u8, Bytes[1]) + router_tlv(200_u8, Bytes[2])].each do |bad|
      expect_status(invoke(cluster, BorderRouter::CMD_SET_ACTIVE_DATASET_REQUEST,
        BorderRouter::SetActiveDatasetRequest.new(bad), is_case_session: true), RouterStatus::InvalidCommand)
    end
    backend.dataset_valid = false
    expect_status(invoke(cluster, BorderRouter::CMD_SET_ACTIVE_DATASET_REQUEST, request, is_case_session: true), RouterStatus::InvalidCommand)
    backend.dataset_valid = true
    backend.active.should be_nil
    expect_success(invoke(cluster, BorderRouter::CMD_SET_ACTIVE_DATASET_REQUEST, request, is_case_session: true))
    backend.active.should eq(router_dataset)
    read(cluster, BorderRouter::ATTR_INTERFACE_ENABLED).should be_true
    read(cluster, BorderRouter::ATTR_ACTIVE_DATASET_TIMESTAMP).should eq(1_u64)
    commissioning.breadcrumb.should eq(9_u64)
    expect_status(invoke(cluster, BorderRouter::CMD_SET_ACTIVE_DATASET_REQUEST, request, is_case_session: true), RouterStatus::InvalidInState)
  end

  it "reports busy during a host activation and rejects invalid host identity" do
    cluster, backend, commissioning = router
    commissioning.arm_fail_safe(60_u16)
    request = BorderRouter::SetActiveDatasetRequest.new(router_dataset)
    backend.on_activation = -> {
      expect_status(cluster.handle_set_active_dataset_request(request), RouterStatus::Busy)
      nil
    }
    expect_success(invoke(cluster, BorderRouter::CMD_SET_ACTIVE_DATASET_REQUEST, request, is_case_session: true))
    backend.name = ""
    expect_raises(Matter::ConfigurationError) { cluster.refresh_host_state }
    backend.name = "Test Border Router"
    backend.agent_id = Bytes.new(15)
    expect_raises(Matter::ConfigurationError) { cluster.refresh_host_state }
  end

  it "rolls back an activation that fails, expires, or remains uncommitted" do
    cluster, backend, commissioning = router
    request = BorderRouter::SetActiveDatasetRequest.new(router_dataset)
    commissioning.arm_fail_safe(60_u16)
    backend.activation_result = false
    expect_status(invoke(cluster, BorderRouter::CMD_SET_ACTIVE_DATASET_REQUEST, request, is_case_session: true), RouterStatus::Failure)
    backend.active.should be_nil
    backend.activation_result = true
    backend.on_activation = -> { commissioning.failsafe.expire }
    expect_status(invoke(cluster, BorderRouter::CMD_SET_ACTIVE_DATASET_REQUEST, request, is_case_session: true), RouterStatus::Timeout)
    backend.active.should be_nil
    commissioning.arm_fail_safe(60_u16)
    backend.on_activation = nil
    expect_success(invoke(cluster, BorderRouter::CMD_SET_ACTIVE_DATASET_REQUEST, request, is_case_session: true))
    commissioning.failsafe.expire
    backend.active.should be_nil
    read(cluster, BorderRouter::ATTR_ACTIVE_DATASET_TIMESTAMP).should be_nil
    backend.rollback_count.should be >= 3
  end

  it "chains the device's existing fail-safe callbacks" do
    backend = RouterBackend.new
    commissioning = Matter::Cluster::GeneralCommissioning.new(endpoint(0))
    expired = 0
    succeeded = 0
    commissioning.on_failsafe_expired = -> { expired += 1; nil }
    commissioning.on_failsafe_success = -> { succeeded += 1; nil }
    cluster = BorderRouter.new(endpoint(1), backend, commissioning)
    commissioning.arm_fail_safe(60_u16)
    request = BorderRouter::SetActiveDatasetRequest.new(router_dataset)
    expect_success(invoke(cluster, BorderRouter::CMD_SET_ACTIVE_DATASET_REQUEST, request, is_case_session: true))
    commissioning.failsafe.expire
    expired.should eq(1)
    backend.active.should be_nil
    succeeded.should eq(0)
  end

  it "only offers SetPending with PANChange and a valid pending timestamp/delay" do
    cluster, backend, _ = router(BorderRouter::Feature::PanChange)
    active = router_dataset
    backend.active = active
    cluster.refresh_host_state
    pending = router_tlv(51_u8, Bytes[0, 0, 0, 0, 0, 0, 0, 2]) + router_tlv(52_u8, Bytes[0, 0, 0, 10]) + active
    bad = pending[0, pending.size - 1]
    expect_status(invoke(cluster, BorderRouter::CMD_SET_PENDING_DATASET_REQUEST,
      BorderRouter::SetPendingDatasetRequest.new(bad), is_case_session: true), RouterStatus::InvalidCommand)
    expect_success(invoke(cluster, BorderRouter::CMD_SET_PENDING_DATASET_REQUEST,
      BorderRouter::SetPendingDatasetRequest.new(pending), is_case_session: true))
    backend.pending.should eq(pending)
    read(cluster, BorderRouter::ATTR_PENDING_DATASET_TIMESTAMP).should eq(2_u64)
    backend.pending_result = false
    newer = pending.dup
    newer[9] = 3_u8
    expect_status(invoke(cluster, BorderRouter::CMD_SET_PENDING_DATASET_REQUEST,
      BorderRouter::SetPendingDatasetRequest.new(newer), is_case_session: true), RouterStatus::Failure)
    backend.pending.should eq(pending)
  end
end
