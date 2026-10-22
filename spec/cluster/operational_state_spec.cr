require "../spec_helper"

private alias OpState = Matter::Cluster::OperationalState
private alias OpCode = Matter::InteractionModel::StatusCode

private def op_response(cluster : OpState, command : UInt32) : OpState::OperationalCommandResponse
  response = invoke(cluster, command).as(Matter::Cluster::CommandResponse)
  response.command_id.should eq(OpState::CMD_OPERATIONAL_COMMAND_RESPONSE)
  OpState::OperationalCommandResponse.from_tlv(response.response.as(TLV::Any))
end

describe Matter::Cluster::OperationalState do
  it "advertises the revision-three monitor-only schema and mandatory critical error event" do
    cluster = build(OpState)
    cluster.cluster_id.id.should eq(0x0060_u32)
    cluster.cluster_revision.should eq(3_u16)
    attribute_ids(cluster).should contain(OpState::ATTR_PHASE_LIST)
    attribute_ids(cluster).should contain(OpState::ATTR_CURRENT_PHASE)
    attribute_ids(cluster).should_not contain(OpState::ATTR_COUNTDOWN_TIME)
    attribute_ids(cluster).should contain(OpState::ATTR_OPERATIONAL_STATE_LIST)
    attribute_ids(cluster).should contain(OpState::ATTR_OPERATIONAL_STATE)
    attribute_ids(cluster).should contain(OpState::ATTR_OPERATIONAL_ERROR)
    read(cluster, OpState::ATTR_PHASE_LIST).should be_nil
    read(cluster, OpState::ATTR_CURRENT_PHASE).should be_nil
    accepted_command_ids(cluster).should be_empty
    generated_command_ids(cluster).should be_empty
    cluster.get_event_metadata(OpState::EVENT_OPERATIONAL_ERROR).as(Matter::Cluster::EventMetadata).priority.should eq(Matter::InteractionModel::EventPriority::Critical)
    expect_status(invoke(cluster, OpState::CMD_START), OpCode::UnsupportedCommand)
  end

  it "advertises only configured commands and their common response" do
    cluster = build(OpState, supported_commands: [OpState::Command::Start, OpState::Command::Stop], countdown_time: 90_u32)
    accepted_command_ids(cluster).should eq([OpState::CMD_STOP, OpState::CMD_START])
    generated_command_ids(cluster).should eq([OpState::CMD_OPERATIONAL_COMMAND_RESPONSE])
    read(cluster, OpState::ATTR_COUNTDOWN_TIME).should eq(90_u32)
    expect_status(invoke(cluster, OpState::CMD_PAUSE), OpCode::UnsupportedCommand)
    expect_raises(ArgumentError, /Start.*Stop/) { build(OpState, supported_commands: [OpState::Command::Start]) }
    expect_raises(ArgumentError, /Pause.*Resume/) { build(OpState, supported_commands: [OpState::Command::Pause]) }
  end

  it "keeps phase indexes and state/error lists valid" do
    cluster = build(OpState)
    expect_raises(ArgumentError, /CurrentPhase/) { cluster.update_phases(["wash"], 1_u8) }
    expect_raises(ArgumentError, /PhaseList/) { cluster.update_phases(nil, 0_u8) }
    cluster.update_phases(["wash", "rinse"], 1_u8)
    read(cluster, OpState::ATTR_CURRENT_PHASE).should eq(1_u8)
    cluster.update_phases([] of String, nil)
    read(cluster, OpState::ATTR_CURRENT_PHASE).should be_nil
    expect_raises(ArgumentError, /CountdownTime/) { cluster.update_countdown(259_201_u32) }
    expect_raises(ArgumentError, /Error/) do
      build(OpState, states: [OpState::StateDescription.new(OpState::STOPPED)])
    end
    expect_raises(ArgumentError, /label/) do
      OpState::StateDescription.new(0x80_u8)
    end
  end

  it "suppresses ordinary countdown ticks but reports zero, null and increases" do
    cluster = build(OpState, countdown_time: 10_u32)
    changes = capture_changes(cluster) { cluster.update_countdown(9_u32, reportable: false) }
    changes.should be_empty
    changes = capture_changes(cluster) { cluster.update_countdown(0_u32, reportable: false) }
    changes.map(&.attribute).should contain(OpState::ATTR_COUNTDOWN_TIME)
    changes = capture_changes(cluster) { cluster.update_countdown(nil, reportable: false) }
    changes.map(&.attribute).should contain(OpState::ATTR_COUNTDOWN_TIME)
    changes = capture_changes(cluster) { cluster.update_countdown(15_u32, reportable: false) }
    changes.map(&.attribute).should contain(OpState::ATTR_COUNTDOWN_TIME)
  end

  it "honors host decisions and the normative command transition matrix" do
    cluster = build(OpState, supported_commands: OpState::Command.values)
    calls = [] of OpState::Command
    cluster.on_command do |command|
      calls << command
      OpState::ErrorState.new(OpState::NO_ERROR)
    end

    op_response(cluster, OpState::CMD_PAUSE).command_response_state.error_state_id.should eq(OpState::COMMAND_INVALID_IN_STATE)
    calls.should be_empty
    op_response(cluster, OpState::CMD_START).command_response_state.error_state_id.should eq(OpState::NO_ERROR)
    read(cluster, OpState::ATTR_OPERATIONAL_STATE).should eq(OpState::RUNNING)
    op_response(cluster, OpState::CMD_START).command_response_state.error_state_id.should eq(OpState::NO_ERROR)
    calls.should eq([OpState::Command::Start])
    op_response(cluster, OpState::CMD_PAUSE).command_response_state.error_state_id.should eq(OpState::NO_ERROR)
    read(cluster, OpState::ATTR_OPERATIONAL_STATE).should eq(OpState::PAUSED)
    op_response(cluster, OpState::CMD_PAUSE).command_response_state.error_state_id.should eq(OpState::NO_ERROR)
    calls.should eq([OpState::Command::Start, OpState::Command::Pause])
    op_response(cluster, OpState::CMD_RESUME).command_response_state.error_state_id.should eq(OpState::NO_ERROR)
    read(cluster, OpState::ATTR_OPERATIONAL_STATE).should eq(OpState::RUNNING)
    op_response(cluster, OpState::CMD_STOP).command_response_state.error_state_id.should eq(OpState::NO_ERROR)
    read(cluster, OpState::ATTR_OPERATIONAL_STATE).should eq(OpState::STOPPED)
    op_response(cluster, OpState::CMD_RESUME).command_response_state.error_state_id.should eq(OpState::COMMAND_INVALID_IN_STATE)
  end

  it "does not change state when the host denies a command" do
    cluster = build(OpState, supported_commands: [OpState::Command::Start, OpState::Command::Stop])
    op_response(cluster, OpState::CMD_START).command_response_state.error_state_id.should eq(OpState::UNABLE_TO_START_OR_RESUME)
    cluster.on_command { |_command| OpState::ErrorState.new(OpState::UNABLE_TO_START_OR_RESUME, details: "door open") }
    response = op_response(cluster, OpState::CMD_START)
    response.command_response_state.error_state_id.should eq(OpState::UNABLE_TO_START_OR_RESUME)
    response.command_response_state.error_state_details.should eq("door open")
    read(cluster, OpState::ATTR_OPERATIONAL_STATE).should eq(OpState::STOPPED)
  end

  it "uses the command-specific response code when a host returns an unrelated error" do
    cluster = build(OpState, supported_commands: [OpState::Command::Start, OpState::Command::Stop])
    cluster.on_command { |_command| OpState::ErrorState.new(OpState::UNABLE_TO_COMPLETE_OPERATION) }
    op_response(cluster, OpState::CMD_START).command_response_state.error_state_id.should eq(OpState::UNABLE_TO_START_OR_RESUME)
    cluster.report_state(OpState::RUNNING)
    op_response(cluster, OpState::CMD_STOP).command_response_state.error_state_id.should eq(OpState::COMMAND_INVALID_IN_STATE)
    read(cluster, OpState::ATTR_OPERATIONAL_STATE).should eq(OpState::RUNNING)
  end

  it "reports errors and completion with typed event payloads" do
    cluster = build(OpState)
    events = [] of {UInt32, TLV::Any}
    cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, event : UInt32, _priority : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) do
      events << {event, data}
      nil
    end
    cluster.report_error(OpState::ErrorState.new(OpState::UNABLE_TO_COMPLETE_OPERATION, details: "jammed"))
    read(cluster, OpState::ATTR_OPERATIONAL_STATE).should eq(OpState::ERROR)
    events.first[0].should eq(OpState::EVENT_OPERATIONAL_ERROR)
    OpState::OperationalErrorEvent.from_tlv(events.first[1]).error_state.error_state_details.should eq("jammed")
    cluster.report_state(OpState::STOPPED)
    OpState::ErrorState.from_tlv(read_tlv(cluster, OpState::ATTR_OPERATIONAL_ERROR)).error_state_id.should eq(OpState::NO_ERROR)
    cluster.report_completion(OpState::NO_ERROR, 180_u32, 30_u32)
    events.last[0].should eq(OpState::EVENT_OPERATION_COMPLETION)
    completion = OpState::OperationCompletionEvent.from_tlv(events.last[1])
    completion.completion_error_code.should eq(OpState::NO_ERROR)
    completion.total_operational_time.should eq(180_u32)
    completion.paused_time.should eq(30_u32)
  end
end
