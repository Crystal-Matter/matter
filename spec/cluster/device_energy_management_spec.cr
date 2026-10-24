require "../spec_helper"
require "../../src/matter/cluster/device_energy_management"

private alias DEM = Matter::Cluster::DeviceEnergyManagement
private alias DEMStatus = Matter::InteractionModel::Status
private alias DEMCode = Matter::InteractionModel::StatusCode

private def dem_capability : DEM::PowerAdjustCapability
  DEM::PowerAdjustCapability.new([
    DEM::PowerAdjust.new(1_000_i64, 4_000_i64, 1_u32, 3_600_u32),
  ], DEM::PowerAdjustReason::NoAdjustment)
end

private def dem : DEM
  build(DEM, esa_type: DEM::ESAType::WaterHeating, can_generate: false,
    abs_min_power: 0_i64, abs_max_power: 5_000_i64,
    power_adjustment_capability: dem_capability)
end

private def dem_request(power : Int64 = 2_000_i64, duration : UInt32 = 60_u32,
                        cause : DEM::AdjustmentCause = DEM::AdjustmentCause::LocalOptimization)
  DEM::PowerAdjustRequest.new(power, duration, cause)
end

describe DEM do
  it "advertises the rev4 PA profile and its typed wire schema" do
    cluster = dem
    cluster.cluster_id.id.should eq(0x0098_u32)
    cluster.cluster_revision.should eq(4_u16)
    cluster.feature_map.should eq(DEM::Feature::PowerAdjustment)
    cluster.attributes.map(&.id.id).should eq([
      DEM::ATTR_ESA_TYPE, DEM::ATTR_ESA_CAN_GENERATE, DEM::ATTR_ESA_STATE,
      DEM::ATTR_ABS_MIN_POWER, DEM::ATTR_ABS_MAX_POWER,
      DEM::ATTR_POWER_ADJUSTMENT_CAPABILITY, DEM::ATTR_OPT_OUT_STATE,
    ])
    cluster.commands.map(&.id.id).should eq([
      DEM::CMD_POWER_ADJUST_REQUEST, DEM::CMD_CANCEL_POWER_ADJUST_REQUEST,
    ])
    cluster.events.map(&.id.id).should eq([
      DEM::EVENT_POWER_ADJUST_START, DEM::EVENT_POWER_ADJUST_END,
    ])
    read_status(cluster, 0x0006_u32).status.should eq(DEMCode::UnsupportedAttribute)
    DEM::PowerAdjustRequest.from_tlv(dem_request.to_tlv(nil)).power.should eq(2_000_i64)
    capability = DEM::PowerAdjustCapability.from_tlv(dem_capability.to_tlv(nil))
    capability.power_adjustment_capability.try(&.first.max_duration).should eq(3_600_u32)
    DEM::PowerAdjustEndEvent.from_tlv(
      DEM::PowerAdjustEndEvent.new(DEM::EndCause::Cancelled, 3_u32, 1_i64).to_tlv(nil)
    ).energy_use.should eq(1_i64)
  end

  it "rejects unsupported feature bits and invalid host power limits" do
    expect_raises(ArgumentError) do
      build(DEM, esa_type: DEM::ESAType::WaterHeating, can_generate: false,
        abs_min_power: 0_i64, abs_max_power: 5_000_i64,
        feature_map: DEM::Feature::StartTimeAdjustment)
    end
    expect_raises(ArgumentError) do
      build(DEM, esa_type: DEM::ESAType::WaterHeating, can_generate: false,
        abs_min_power: 6_000_i64, abs_max_power: 5_000_i64)
    end
    expect_raises(ArgumentError) { DEM::PowerAdjust.new(4_000_i64, 1_000_i64, 1_u32, 2_u32) }
    expect_raises(ArgumentError) { DEM::PowerAdjust.new(1_000_i64, 4_000_i64, 3_u32, 2_u32) }
    expect_raises(ArgumentError) do
      DEM::PowerAdjustCapability.new(Array.new(9) { DEM::PowerAdjust.new(1_i64, 2_i64, 1_u32, 2_u32) },
        DEM::PowerAdjustReason::NoAdjustment)
    end
  end

  it "copies the capability list across host and reader boundaries" do
    ranges = [DEM::PowerAdjust.new(1_000_i64, 4_000_i64, 1_u32, 10_u32)]
    cluster = build(DEM, esa_type: DEM::ESAType::WaterHeating, can_generate: false,
      abs_min_power: 0_i64, abs_max_power: 5_000_i64,
      power_adjustment_capability: DEM::PowerAdjustCapability.new(ranges,
        DEM::PowerAdjustReason::NoAdjustment))
    ranges.clear
    cluster.power_adjustment_capability.try(&.power_adjustment_capability).try(&.size).should eq(1)
    cluster.power_adjustment_capability.try(&.power_adjustment_capability).try(&.clear)
    cluster.power_adjustment_capability.try(&.power_adjustment_capability).try(&.size).should eq(1)
  end

  it "keeps the capability reason aligned with the active session and rate limits reports" do
    expect_raises(ArgumentError) do
      build(DEM, esa_type: DEM::ESAType::WaterHeating, can_generate: false,
        abs_min_power: 0_i64, abs_max_power: 5_000_i64,
        power_adjustment_capability: DEM::PowerAdjustCapability.new(
          [DEM::PowerAdjust.new(1_i64, 2_i64, 1_u32, 2_u32)],
          DEM::PowerAdjustReason::GridOptimizationAdjustment))
    end
    cluster = dem
    changed = [] of UInt32
    cluster.on_attribute_changed = ->(_ep : UInt16, _cl : UInt32, id : UInt32) { changed << id; nil }
    first_version = cluster.data_version
    cluster.report_power_adjustment_capability(dem_capability)
    cluster.report_power_adjustment_capability(dem_capability)
    cluster.data_version.should eq(first_version + 2)
    changed.should eq([DEM::ATTR_POWER_ADJUSTMENT_CAPABILITY])
    cluster.report_power_adjustment_capability(nil)
    changed.should eq([DEM::ATTR_POWER_ADJUSTMENT_CAPABILITY, DEM::ATTR_POWER_ADJUSTMENT_CAPABILITY])
  end

  it "validates PA bounds, online state, and opt-out before calling the host" do
    cluster = dem
    calls = 0
    cluster.on_power_adjust do |_request, _fabric|
      calls += 1
      DEMStatus.success
    end
    cluster.on_cancel_power_adjust { |_fabric| DEMStatus.success }
    expect_status(invoke(cluster, DEM::CMD_POWER_ADJUST_REQUEST,
      dem_request(999_i64)), DEMCode::ConstraintError)
    expect_status(invoke(cluster, DEM::CMD_POWER_ADJUST_REQUEST,
      dem_request(2_000_i64, 3_601_u32)), DEMCode::ConstraintError)
    cluster.report_opt_out_state(DEM::OptOutState::LocalOptOut)
    expect_status(invoke(cluster, DEM::CMD_POWER_ADJUST_REQUEST,
      dem_request), DEMCode::InvalidInState)
    cluster.report_opt_out_state(DEM::OptOutState::NoOptOut)
    cluster.report_esa_state(DEM::ESAState::Offline)
    expect_status(invoke(cluster, DEM::CMD_POWER_ADJUST_REQUEST,
      dem_request), DEMCode::InvalidInState)
    calls.should eq(0)
  end

  it "commits host-approved adjustment, replacement, and cancellation with events" do
    node = Matter::Node.new
    endpoint1 = Matter::Endpoint.new(endpoint(1))
    cluster = dem
    endpoint1.add_cluster(cluster)
    node.add_endpoint(endpoint1)
    fabrics = [] of UInt8?
    cluster.on_power_adjust do |_request, fabric|
      fabrics << fabric
      DEMStatus.success
    end
    cluster.on_cancel_power_adjust do |fabric|
      fabrics << fabric
      DEMStatus.success
    end
    expect_success(invoke(cluster, DEM::CMD_POWER_ADJUST_REQUEST, dem_request,
      is_case_session: true, fabric_index: 2_u8))
    cluster.esa_state.should eq(DEM::ESAState::PowerAdjustActive)
    expect_success(invoke(cluster, DEM::CMD_POWER_ADJUST_REQUEST,
      dem_request(3_000_i64, 30_u32, DEM::AdjustmentCause::GridOptimization),
      is_case_session: true, fabric_index: 2_u8))
    expect_success(invoke(cluster, DEM::CMD_CANCEL_POWER_ADJUST_REQUEST,
      is_case_session: true, fabric_index: 2_u8))
    cluster.esa_state.should eq(DEM::ESAState::Online)
    fabrics.should eq([2_u8, 2_u8, 2_u8])
    starts = node.event_journal.query([Matter::InteractionModel::EventPath.new(
      cluster: DEM::CLUSTER_ID, event: DEM::EVENT_POWER_ADJUST_START)])
    ends = node.event_journal.query([Matter::InteractionModel::EventPath.new(
      cluster: DEM::CLUSTER_ID, event: DEM::EVENT_POWER_ADJUST_END)])
    starts.size.should eq(2)
    ends.size.should eq(2)
    DEM::PowerAdjustEndEvent.from_tlv(ends.last.data).cause.should eq(DEM::EndCause::Cancelled)
  end

  it "keeps state unchanged on host rejection and ends on a new user opt-out" do
    cluster = dem
    cluster.on_power_adjust { |_request, _fabric| DEMStatus.invalid_in_state }
    cluster.on_cancel_power_adjust { |_fabric| DEMStatus.success }
    expect_status(invoke(cluster, DEM::CMD_POWER_ADJUST_REQUEST, dem_request), DEMCode::InvalidInState)
    cluster.esa_state.should eq(DEM::ESAState::Online)
    cluster.on_power_adjust { |_request, _fabric| DEMStatus.success }
    expect_success(invoke(cluster, DEM::CMD_POWER_ADJUST_REQUEST, dem_request))
    cluster.report_opt_out_state(DEM::OptOutState::LocalOptOut)
    cluster.esa_state.should eq(DEM::ESAState::Online)
    cluster.power_adjustment_capability.try(&.cause).should eq(DEM::PowerAdjustReason::NoAdjustment)
  end

  it "ends a short adjustment at its duration and starts fresh after restart" do
    cluster = dem
    cluster.on_power_adjust { |_request, _fabric| DEMStatus.success }
    observed_fabrics = [] of UInt8?
    cluster.on_cancel_power_adjust do |fabric|
      observed_fabrics << fabric
      raise "synthetic host timeout rejection"
    end
    expect_success(invoke(cluster, DEM::CMD_POWER_ADJUST_REQUEST, dem_request(2_000_i64, 1_u32),
      is_case_session: true, fabric_index: 4_u8))
    sleep 1.1.seconds
    cluster.esa_state.should eq(DEM::ESAState::Online)
    observed_fabrics.should eq([4_u8])
    cluster.save_state.should be_nil
    dem.esa_state.should eq(DEM::ESAState::Online)
  end

  it "does not let an older expiration end a replacement adjustment" do
    cluster = dem
    cluster.on_power_adjust { |_request, _fabric| DEMStatus.success }
    cluster.on_cancel_power_adjust { |_fabric| DEMStatus.success }
    expect_success(invoke(cluster, DEM::CMD_POWER_ADJUST_REQUEST, dem_request(2_000_i64, 1_u32)))
    sleep 0.5.seconds
    expect_success(invoke(cluster, DEM::CMD_POWER_ADJUST_REQUEST, dem_request(3_000_i64, 2_u32)))
    sleep 0.7.seconds
    cluster.esa_state.should eq(DEM::ESAState::PowerAdjustActive)
    expect_success(invoke(cluster, DEM::CMD_CANCEL_POWER_ADJUST_REQUEST))
  end
end
