require "../spec_helper"

private alias OvenState = Matter::Cluster::OvenCavityOperationalState
private alias BaseState = Matter::Cluster::OperationalState

private def oven_state_response(cluster : OvenState, command : UInt32) : BaseState::OperationalCommandResponse
  response = invoke(cluster, command).as(Matter::Cluster::CommandResponse)
  response.command_id.should eq(OvenState::CMD_OPERATIONAL_COMMAND_RESPONSE)
  BaseState::OperationalCommandResponse.from_tlv(response.response.as(TLV::Any))
end

describe OvenState do
  it "advertises revision two, base attributes, and no Pause or Resume" do
    cluster = build(OvenState)
    cluster.cluster_id.id.should eq(0x0048_u32)
    cluster.cluster_revision.should eq(2_u16)
    cluster.attributes.map(&.id.id).should eq([
      OvenState::ATTR_PHASE_LIST, OvenState::ATTR_CURRENT_PHASE,
      OvenState::ATTR_OPERATIONAL_STATE_LIST, OvenState::ATTR_OPERATIONAL_STATE,
      OvenState::ATTR_OPERATIONAL_ERROR,
    ])
    cluster.events.map(&.id.id).should contain(OvenState::EVENT_OPERATIONAL_ERROR)
    accepted_command_ids(cluster).should be_empty
    expect_status(invoke(cluster, 0x00_u32), Matter::InteractionModel::StatusCode::UnsupportedCommand)
    expect_status(invoke(cluster, 0x03_u32), Matter::InteractionModel::StatusCode::UnsupportedCommand)
  end

  it "permits Start only with Stop and emits the common operational response" do
    expect_raises(ArgumentError) { build(OvenState, supported_commands: [OvenState::Command::Start]) }
    expect_raises(ArgumentError) { build(OvenState, supported_commands: [OvenState::Command::Pause]) }
    cluster = build(OvenState, supported_commands: [OvenState::Command::Stop, OvenState::Command::Start])
    accepted_command_ids(cluster).should eq([OvenState::CMD_STOP, OvenState::CMD_START])
    generated_command_ids(cluster).should eq([OvenState::CMD_OPERATIONAL_COMMAND_RESPONSE])
    oven_state_response(cluster, OvenState::CMD_START).command_response_state.error_state_id.should eq(BaseState::UNABLE_TO_START_OR_RESUME)
    cluster.on_command { |_command| BaseState::ErrorState.new(BaseState::NO_ERROR) }
    oven_state_response(cluster, OvenState::CMD_START).command_response_state.error_state_id.should eq(BaseState::NO_ERROR)
    cluster.operational_state.should eq(BaseState::RUNNING)
    oven_state_response(cluster, OvenState::CMD_STOP).command_response_state.error_state_id.should eq(BaseState::NO_ERROR)
    cluster.operational_state.should eq(BaseState::STOPPED)
    expect_status(invoke(cluster, 0x00_u32), Matter::InteractionModel::StatusCode::UnsupportedCommand)
    expect_status(invoke(cluster, 0x03_u32), Matter::InteractionModel::StatusCode::UnsupportedCommand)
  end

  it "reports physical errors and completion with inherited wire payloads" do
    cluster = build(OvenState)
    events = [] of {UInt32, TLV::Any}
    cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, event : UInt32, _priority : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) do
      events << {event, data}
      nil
    end
    cluster.report_error(BaseState::ErrorState.new(BaseState::UNABLE_TO_COMPLETE_OPERATION, details: "overheat"))
    cluster.operational_state.should eq(BaseState::ERROR)
    events.first[0].should eq(OvenState::EVENT_OPERATIONAL_ERROR)
    cluster.report_state(BaseState::STOPPED)
    cluster.report_completion(BaseState::NO_ERROR, 120_u32)
    events.last[0].should eq(OvenState::EVENT_OPERATION_COMPLETION)
    completion = BaseState::OperationCompletionEvent.from_tlv(events.last[1])
    completion.total_operational_time.should eq(120_u32)
  end

  it "validates phase and countdown changes without exposing disabled commands" do
    cluster = build(OvenState, phase_list: ["preheat", "cook"], current_phase: 0_u8, countdown_time: 90_u32)
    read(cluster, OvenState::ATTR_COUNTDOWN_TIME).should eq(90_u32)
    expect_raises(ArgumentError) { cluster.update_phases(["cook"], 1_u8) }
    expect_raises(ArgumentError) { cluster.update_countdown(259_201_u32) }
    cluster.update_phases(["preheat", "cook"], 1_u8)
    cluster.update_countdown(30_u32)
    read(cluster, OvenState::ATTR_CURRENT_PHASE).should eq(1_u8)
    read(cluster, OvenState::ATTR_COUNTDOWN_TIME).should eq(30_u32)
    accepted_command_ids(cluster).should be_empty
  end

  it "keeps reported phase and state lists isolated from callers" do
    phases = ["preheat", "cook"]
    states = [
      BaseState::StateDescription.new(BaseState::STOPPED),
      BaseState::StateDescription.new(BaseState::RUNNING),
      BaseState::StateDescription.new(BaseState::ERROR),
    ]
    cluster = build(OvenState, phase_list: phases, current_phase: 1_u8, states: states)
    phases.clear
    states.clear
    cluster.phase_list.try(&.clear)
    cluster.operational_state_list.clear
    cluster.phase_list.should eq(["preheat", "cook"])
    cluster.operational_state_list.map(&.operational_state_id).should eq([
      BaseState::STOPPED, BaseState::RUNNING, BaseState::ERROR,
    ])
    cluster.report_state(BaseState::RUNNING)
    cluster.operational_state.should eq(BaseState::RUNNING)
  end

  it "copies phase and state lists assigned after construction" do
    cluster = build(OvenState)
    phases = ["preheat", "cook"]
    states = [
      BaseState::StateDescription.new(BaseState::STOPPED),
      BaseState::StateDescription.new(BaseState::RUNNING),
      BaseState::StateDescription.new(BaseState::ERROR),
    ]

    cluster.phase_list = phases
    cluster.operational_state_list = states
    phases.clear
    states.clear

    cluster.phase_list.should eq(["preheat", "cook"])
    cluster.operational_state_list.map(&.operational_state_id).should eq([
      BaseState::STOPPED, BaseState::RUNNING, BaseState::ERROR,
    ])
    cluster.report_state(BaseState::RUNNING)
    cluster.operational_state.should eq(BaseState::RUNNING)
  end
end
