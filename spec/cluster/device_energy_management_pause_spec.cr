require "../spec_helper"
require "../../src/matter/cluster/device_energy_management"

private alias PauseDEM = Matter::Cluster::DeviceEnergyManagement
private alias PauseStatus = Matter::InteractionModel::Status
private alias PauseCode = Matter::InteractionModel::StatusCode

private def pause_dem : PauseDEM
  build(PauseDEM, esa_type: PauseDEM::ESAType::WashingMachine,
    can_generate: false, abs_min_power: 0_i64, abs_max_power: 5_000_i64,
    feature_map: PauseDEM::Feature::PowerForecastReporting | PauseDEM::Feature::Pausable)
end

private def pause_forecast : PauseDEM::Forecast
  slot = PauseDEM::Slot.new(600_u32, 1_800_u32, 1_200_u32, 60_u32, 1_140_u32,
    nominal_power: 2_000_i64, min_power: 1_000_i64, max_power: 3_000_i64,
    nominal_energy: 667_i64, slot_is_pausable: true,
    min_pause_duration: 1_u32, max_pause_duration: 60_u32)
  PauseDEM::Forecast.new(1_u32, 0_u16, 100_u32, 1_300_u32,
    true, [slot], PauseDEM::ForecastUpdateReason::InternalOptimization)
end

private def pause_request(duration : UInt32 = 30_u32,
                          cause = PauseDEM::AdjustmentCause::LocalOptimization)
  PauseDEM::PauseRequest.new(duration, cause)
end

describe "Matter 1.6 Device Energy Management PAU" do
  it "advertises only the PFR+PAU profile with typed slot, command and event schema" do
    cluster = pause_dem
    cluster.feature_map.should eq(PauseDEM::Feature::PowerForecastReporting | PauseDEM::Feature::Pausable)
    cluster.commands.map(&.id.id).should eq([PauseDEM::CMD_PAUSE_REQUEST, PauseDEM::CMD_RESUME_REQUEST])
    cluster.events.map(&.id.id).should eq([PauseDEM::EVENT_PAUSED, PauseDEM::EVENT_RESUMED])
    cluster.report_forecast(pause_forecast)
    slot = cluster.forecast.try(&.slots.first) || raise "missing forecast slot"
    slot.slot_is_pausable?.should be_true
    slot.min_pause_duration.should eq(1_u32)
    slot.max_pause_duration.should eq(60_u32)
    encoded = slot.to_tlv(nil).value.as(TLV::Structure)
    encoded[5_u8].value.should be_true
    encoded[6_u8].value.should eq(1_u32)
    encoded[7_u8].value.should eq(60_u32)
    PauseDEM::PauseRequest.from_tlv(pause_request.to_tlv(nil)).duration.should eq(30_u32)
    expect_raises(ArgumentError) do
      build(PauseDEM, esa_type: PauseDEM::ESAType::WashingMachine,
        can_generate: false, abs_min_power: 0_i64, abs_max_power: 5_000_i64,
        feature_map: PauseDEM::Feature::Pausable)
    end
  end

  it "validates pause fields and forecast-wide pausable flag" do
    cluster = pause_dem
    forecast = pause_forecast
    slot = forecast.slots.first
    expect_raises(ArgumentError) do
      PauseDEM::Slot.new(600_u32, 1_800_u32, 1_200_u32, 0_u32, 1_200_u32,
        nominal_power: 2_000_i64, min_power: 1_000_i64, max_power: 3_000_i64,
        nominal_energy: 667_i64, slot_is_pausable: true,
        min_pause_duration: 60_u32, max_pause_duration: 1_u32)
    end
    expect_raises(ArgumentError) do
      cluster.report_forecast(PauseDEM::Forecast.new(1_u32, 0_u16, 100_u32, 1_300_u32,
        false, [slot], PauseDEM::ForecastUpdateReason::InternalOptimization))
    end
    expect_raises(ArgumentError) do
      cluster.report_forecast(PauseDEM::Forecast.new(1_u32, 0_u16, 100_u32, 1_300_u32,
        true, [PauseDEM::Slot.new(600_u32, 1_800_u32, 1_200_u32, 0_u32, 1_200_u32,
        nominal_power: 2_000_i64, min_power: 1_000_i64, max_power: 3_000_i64,
        nominal_energy: 667_i64)], PauseDEM::ForecastUpdateReason::InternalOptimization))
    end
  end

  it "pauses only after host approval and resumes with fabric and events" do
    node = Matter::Node.new
    ep = Matter::Endpoint.new(endpoint(1))
    cluster = pause_dem
    ep.add_cluster(cluster)
    node.add_endpoint(ep)
    cluster.report_forecast(pause_forecast)
    fabrics = [] of UInt8?
    cluster.on_pause do |_request, fabric|
      fabrics << fabric
      PauseStatus.success
    end
    cluster.on_resume do |fabric|
      fabrics << fabric
      PauseStatus.success
    end
    expect_success(invoke(cluster, PauseDEM::CMD_PAUSE_REQUEST, pause_request,
      is_case_session: true, fabric_index: 3_u8))
    cluster.esa_state.should eq(PauseDEM::ESAState::Paused)
    expect_success(invoke(cluster, PauseDEM::CMD_RESUME_REQUEST,
      is_case_session: true, fabric_index: 3_u8))
    cluster.esa_state.should eq(PauseDEM::ESAState::Online)
    fabrics.should eq([3_u8, 3_u8])
    paused = node.event_journal.query([Matter::InteractionModel::EventPath.new(
      cluster: PauseDEM::CLUSTER_ID, event: PauseDEM::EVENT_PAUSED)])
    resumed = node.event_journal.query([Matter::InteractionModel::EventPath.new(
      cluster: PauseDEM::CLUSTER_ID, event: PauseDEM::EVENT_RESUMED)])
    paused.size.should eq(1)
    resumed.size.should eq(1)
    PauseDEM::ResumedEvent.from_tlv(resumed.first.data).cause.should eq(PauseDEM::EndCause::Cancelled)
  end

  it "rejects invalid duration, inactive slot, opt-out and host refusal" do
    cluster = pause_dem
    cluster.report_forecast(pause_forecast)
    calls = 0
    cluster.on_pause do |_request, _fabric|
      calls += 1
      PauseStatus.invalid_in_state
    end
    cluster.on_resume { |_fabric| PauseStatus.success }
    expect_status(invoke(cluster, PauseDEM::CMD_PAUSE_REQUEST,
      pause_request(0_u32)), PauseCode::ConstraintError)
    expect_status(invoke(cluster, PauseDEM::CMD_PAUSE_REQUEST,
      pause_request(61_u32)), PauseCode::ConstraintError)
    calls.should eq(0)
    expect_status(invoke(cluster, PauseDEM::CMD_PAUSE_REQUEST,
      pause_request), PauseCode::InvalidInState)
    calls.should eq(1)
    cluster.report_opt_out_state(PauseDEM::OptOutState::LocalOptOut)
    expect_status(invoke(cluster, PauseDEM::CMD_PAUSE_REQUEST,
      pause_request), PauseCode::InvalidInState)
    calls.should eq(1)
  end

  it "ends an active pause on opt-out even if the host rejects cancellation" do
    cluster = pause_dem
    cluster.report_forecast(pause_forecast)
    cluster.on_pause { |_request, _fabric| PauseStatus.success }
    cluster.on_resume { |_fabric| raise "synthetic host rejection" }
    expect_success(invoke(cluster, PauseDEM::CMD_PAUSE_REQUEST, pause_request(30_u32)))
    cluster.report_opt_out_state(PauseDEM::OptOutState::LocalOptOut)
    cluster.esa_state.should eq(PauseDEM::ESAState::Online)
  end

  it "expires a pause and ignores an old timer after early resume and a new pause" do
    cluster = pause_dem
    cluster.report_forecast(pause_forecast)
    cluster.on_pause { |_request, _fabric| PauseStatus.success }
    cluster.on_resume { |_fabric| PauseStatus.success }
    expect_success(invoke(cluster, PauseDEM::CMD_PAUSE_REQUEST, pause_request(1_u32)))
    sleep 0.5.seconds
    expect_success(invoke(cluster, PauseDEM::CMD_RESUME_REQUEST))
    expect_success(invoke(cluster, PauseDEM::CMD_PAUSE_REQUEST, pause_request(2_u32)))
    sleep 0.7.seconds
    cluster.esa_state.should eq(PauseDEM::ESAState::Paused)
    expect_success(invoke(cluster, PauseDEM::CMD_RESUME_REQUEST))
    cluster.save_state.should be_nil
    pause_dem.esa_state.should eq(PauseDEM::ESAState::Online)
  end

  it "ends at the deadline despite a host callback exception" do
    cluster = pause_dem
    cluster.report_forecast(pause_forecast)
    cluster.on_pause { |_request, _fabric| PauseStatus.success }
    cluster.on_resume { |_fabric| raise "synthetic timeout rejection" }
    expect_success(invoke(cluster, PauseDEM::CMD_PAUSE_REQUEST, pause_request(1_u32)))
    sleep 1.1.seconds
    cluster.esa_state.should eq(PauseDEM::ESAState::Online)
  end

  it "leaves Paused when the host reports a fault" do
    cluster = pause_dem
    cluster.report_forecast(pause_forecast)
    cluster.on_pause { |_request, _fabric| PauseStatus.success }
    cluster.on_resume { |_fabric| PauseStatus.success }
    expect_success(invoke(cluster, PauseDEM::CMD_PAUSE_REQUEST, pause_request))
    cluster.report_esa_state(PauseDEM::ESAState::Fault)
    cluster.esa_state.should eq(PauseDEM::ESAState::Fault)
    expect_success(invoke(cluster, PauseDEM::CMD_RESUME_REQUEST))
    cluster.esa_state.should eq(PauseDEM::ESAState::Fault)
  end
end
