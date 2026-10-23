require "../spec_helper"

private alias RvcState = Matter::Cluster::RvcOperationalState
private alias BaseState = Matter::Cluster::OperationalState

private def rvc_response(cluster : RvcState, command : UInt32) : RvcState::OperationalCommandResponse
  response = invoke(cluster, command).as(Matter::Cluster::CommandResponse)
  response.command_id.should eq(RvcState::CMD_OPERATIONAL_COMMAND_RESPONSE)
  RvcState::OperationalCommandResponse.from_tlv(response.response.as(TLV::Any))
end

describe RvcState do
  it "advertises revision three, derived states, and no Start or Stop" do
    cluster = build(RvcState, supported_commands: [RvcState::Command::Pause, RvcState::Command::Resume])
    cluster.cluster_id.id.should eq(0x0061_u32)
    cluster.cluster_revision.should eq(3_u16)
    cluster.operational_state_list.map(&.operational_state_id).should contain(RvcState::SEEKING_CHARGER)
    cluster.operational_state_list.map(&.operational_state_id).should contain(RvcState::CHARGING)
    cluster.operational_state_list.map(&.operational_state_id).should contain(RvcState::DOCKED)
    accepted_command_ids(cluster).should eq([RvcState::CMD_PAUSE, RvcState::CMD_RESUME])
    expect_status(invoke(cluster, 0x01_u32), Matter::InteractionModel::StatusCode::UnsupportedCommand)
    expect_status(invoke(cluster, 0x02_u32), Matter::InteractionModel::StatusCode::UnsupportedCommand)
    expect_raises(ArgumentError) { build(RvcState, supported_commands: [RvcState::Command::Pause]) }
  end

  it "isolates host-assigned phase and state lists from later mutation" do
    cluster = build(RvcState)
    phases = ["start", "clean"]
    states = cluster.operational_state_list
    cluster.phase_list = phases
    cluster.operational_state_list = states
    phases.clear
    states.clear
    cluster.phase_list.should eq(["start", "clean"])
    cluster.operational_state_list.size.should eq(7)
  end

  it "pauses from SeekingCharger but rejects Pause from Charging and Docked" do
    cluster = build(RvcState, supported_commands: [RvcState::Command::Pause, RvcState::Command::Resume])
    cluster.on_command { |_command| RvcState::ErrorState.new(RvcState::NO_ERROR) }
    cluster.report_state(RvcState::SEEKING_CHARGER)
    rvc_response(cluster, RvcState::CMD_PAUSE).command_response_state.error_state_id.should eq(RvcState::NO_ERROR)
    cluster.operational_state.should eq(RvcState::PAUSED)
    rvc_response(cluster, RvcState::CMD_RESUME).command_response_state.error_state_id.should eq(RvcState::NO_ERROR)
    cluster.operational_state.should eq(RvcState::SEEKING_CHARGER)
    cluster.report_state(RvcState::CHARGING)
    rvc_response(cluster, RvcState::CMD_PAUSE).command_response_state.error_state_id.should eq(RvcState::COMMAND_INVALID_IN_STATE)
    cluster.report_state(RvcState::DOCKED)
    rvc_response(cluster, RvcState::CMD_PAUSE).command_response_state.error_state_id.should eq(RvcState::COMMAND_INVALID_IN_STATE)
  end

  it "resumes from dock only when an operating cycle can resume" do
    cluster = build(RvcState, supported_commands: [RvcState::Command::Pause, RvcState::Command::Resume])
    cluster.on_command { |_command| RvcState::ErrorState.new(RvcState::NO_ERROR) }
    cluster.report_state(RvcState::CHARGING)
    rvc_response(cluster, RvcState::CMD_RESUME).command_response_state.error_state_id.should eq(RvcState::COMMAND_INVALID_IN_STATE)
    cluster.report_state(RvcState::RUNNING)
    cluster.report_state(RvcState::CHARGING)
    rvc_response(cluster, RvcState::CMD_RESUME).command_response_state.error_state_id.should eq(RvcState::NO_ERROR)
    cluster.operational_state.should eq(RvcState::RUNNING)
  end

  it "acknowledges Resume while already Running without invoking the host" do
    cluster = build(RvcState, supported_commands: [RvcState::Command::Pause, RvcState::Command::Resume])
    calls = 0
    cluster.on_command do |_command|
      calls += 1
      RvcState::ErrorState.new(RvcState::NO_ERROR)
    end
    cluster.report_state(RvcState::RUNNING)

    rvc_response(cluster, RvcState::CMD_RESUME).command_response_state.error_state_id.should eq(RvcState::NO_ERROR)
    cluster.operational_state.should eq(RvcState::RUNNING)
    calls.should eq(0)
  end

  it "retains a resumable cleaning cycle when it docks after being paused" do
    cluster = build(RvcState, supported_commands: [RvcState::Command::Pause, RvcState::Command::Resume])
    cluster.on_command { |_command| RvcState::ErrorState.new(RvcState::NO_ERROR) }
    cluster.report_state(RvcState::RUNNING)
    cluster.report_state(RvcState::PAUSED)
    cluster.report_state(RvcState::CHARGING)
    rvc_response(cluster, RvcState::CMD_RESUME).command_response_state.error_state_id.should eq(RvcState::NO_ERROR)
    cluster.operational_state.should eq(RvcState::RUNNING)
  end

  it "retains a resumable cycle while seeking a charger for an interrupted operation" do
    cluster = build(RvcState, supported_commands: [RvcState::Command::Pause, RvcState::Command::Resume])
    cluster.on_command { |_command| RvcState::ErrorState.new(RvcState::NO_ERROR) }
    cluster.report_state(RvcState::RUNNING)
    cluster.report_state(RvcState::SEEKING_CHARGER)
    cluster.report_state(RvcState::CHARGING)
    rvc_response(cluster, RvcState::CMD_RESUME).command_response_state.error_state_id.should eq(RvcState::NO_ERROR)
    cluster.operational_state.should eq(RvcState::RUNNING)
  end

  it "handles GoHome idempotently and reports derived errors" do
    cluster = build(RvcState, go_home: true)
    cluster.on_go_home { RvcState::ErrorState.new(RvcState::NO_ERROR) }
    rvc_response(cluster, RvcState::CMD_GO_HOME).command_response_state.error_state_id.should eq(RvcState::NO_ERROR)
    cluster.operational_state.should eq(RvcState::SEEKING_CHARGER)
    rvc_response(cluster, RvcState::CMD_GO_HOME).command_response_state.error_state_id.should eq(RvcState::NO_ERROR)
    cluster.report_state(RvcState::DOCKED)
    rvc_response(cluster, RvcState::CMD_GO_HOME).command_response_state.error_state_id.should eq(RvcState::COMMAND_INVALID_IN_STATE)
    error = RvcState::ErrorState.new(RvcState::STUCK)
    cluster.report_error(error)
    cluster.operational_error.error_state_id.should eq(RvcState::STUCK)
    cluster.operational_state.should eq(RvcState::ERROR)
    expect_raises(ArgumentError) { RvcState::ErrorState.new(0x4F_u8) }
  end

  it "sets Run Mode Idle after successful docking but cancels that action after an error" do
    modes = [
      Matter::Cluster::ModeBase::Option.new("Idle", 0_u8, [Matter::Cluster::ModeBase::Tag.new(Matter::Cluster::RvcRunMode::ModeTag::Idle.value)]),
      Matter::Cluster::ModeBase::Option.new("Clean", 1_u8, [Matter::Cluster::ModeBase::Tag.new(Matter::Cluster::RvcRunMode::ModeTag::Cleaning.value)]),
    ]
    run = build(Matter::Cluster::RvcRunMode, supported_modes: modes, current_mode: 1_u8)
    cluster = build(RvcState, go_home: true, run_mode: run)
    cluster.on_go_home { RvcState::ErrorState.new(RvcState::NO_ERROR) }

    cluster.go_home.command_response_state.error_state_id.should eq(RvcState::NO_ERROR)
    cluster.report_error(RvcState::ErrorState.new(RvcState::STUCK))
    cluster.report_state(RvcState::DOCKED)
    run.current_mode.should eq(1_u8)

    cluster.report_state(RvcState::RUNNING)
    cluster.go_home.command_response_state.error_state_id.should eq(RvcState::NO_ERROR)
    cluster.report_state(RvcState::DOCKED)
    run.current_mode.should eq(0_u8)
  end
end
