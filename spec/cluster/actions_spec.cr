require "../spec_helper"

private alias Actions = Matter::Cluster::Actions
private alias IMStatus = Matter::InteractionModel::Status
private alias IMCode = Matter::InteractionModel::StatusCode

private def actions_fixture : Actions
  endpoints = [Actions::EndpointList.new(7_u16, "Living room", Actions::EndpointListType::Room, [2_u16])]
  entries = [Actions::Action.new(3_u16, "Evening", Actions::ActionType::Scene, 7_u16,
    Actions::CommandBits::InstantAction | Actions::CommandBits::StartAction | Actions::CommandBits::StopAction,
    Actions::ActionState::Inactive)]
  build(Actions, action_list: entries, endpoint_lists: endpoints)
end

describe Matter::Cluster::Actions do
  it "advertises the mandatory revision-one data model and read-only lists" do
    cluster = actions_fixture
    cluster.cluster_id.id.should eq(0x0025_u32)
    cluster.cluster_revision.should eq(1_u16)
    read_tlv(cluster, Actions::ATTR_ACTION_LIST).as_list.size.should eq(1)
    read_tlv(cluster, Actions::ATTR_ENDPOINT_LISTS).as_list.size.should eq(1)
    read_status(cluster, Actions::ATTR_SETUP_URL).status.should eq(IMCode::UnsupportedAttribute)
    Actions::CMD_DISABLE_ACTION_WITH_DURATION.should eq(0x0B_u32)
    cluster.commands.map(&.id.id).should eq([
      Actions::CMD_INSTANT_ACTION, Actions::CMD_START_ACTION, Actions::CMD_STOP_ACTION,
    ])
    cluster.get_event_metadata(Actions::EVENT_STATE_CHANGED).should_not be_nil
    cluster.get_event_metadata(Actions::EVENT_ACTION_FAILED).should_not be_nil
  end

  it "validates unique identifiers, references, command bits and bounded names" do
    expect_raises(ArgumentError, /duplicate/) do
      build(Actions, action_list: [] of Actions::Action,
        endpoint_lists: [Actions::EndpointList.new(1_u16, "A", Actions::EndpointListType::Room, [] of UInt16),
                         Actions::EndpointList.new(1_u16, "B", Actions::EndpointListType::Zone, [] of UInt16)])
    end
    expect_raises(ArgumentError, /EndpointListID/) do
      build(Actions, action_list: [Actions::Action.new(1_u16, "A", Actions::ActionType::Scene,
        9_u16, Actions::CommandBits::InstantAction, Actions::ActionState::Inactive)],
        endpoint_lists: [] of Actions::EndpointList)
    end
    expect_raises(ArgumentError, /name/) do
      Actions::EndpointList.new(1_u16, "a" * 129, Actions::EndpointListType::Room, [] of UInt16)
    end
  end

  it "returns NotFound and InvalidCommand without invoking the host" do
    cluster = actions_fixture
    calls = 0
    cluster.on_execute do |_action, _command, _invoke_id, _parameter|
      calls += 1
      IMStatus.success
    end
    expect_status(invoke(cluster, Actions::CMD_INSTANT_ACTION, Actions::ActionRequest.new(99_u16)), IMCode::NotFound)
    expect_status(invoke(cluster, Actions::CMD_PAUSE_ACTION, Actions::ActionRequest.new(3_u16)), IMCode::UnsupportedCommand)
    cluster.action_list = cluster.action_list + [Actions::Action.new(4_u16, "Pause", Actions::ActionType::Scene,
      7_u16, Actions::CommandBits::PauseAction, Actions::ActionState::Active)]
    expect_status(invoke(cluster, Actions::CMD_PAUSE_ACTION, Actions::ActionRequest.new(3_u16)), IMCode::InvalidCommand)
    calls.should eq(0)
  end

  it "runs an advertised action only through an explicit host callback and emits feedback with InvokeID" do
    cluster = actions_fixture
    event_ids = [] of UInt32
    payloads = [] of TLV::Any
    cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, event : UInt32, _priority : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) do
      event_ids << event
      payloads << data
      nil
    end
    expect_status(invoke(cluster, Actions::CMD_START_ACTION, Actions::ActionRequest.new(3_u16, 15_u32)), IMCode::InvalidInState)
    cluster.action_list.first.state.should eq(Actions::ActionState::Inactive)
    cluster.on_execute do |_action, command, invoke_id, _parameter|
      command.should eq(Actions::ActionCommand::StartAction)
      invoke_id.should eq(15_u32)
      IMStatus.success
    end
    expect_success(invoke(cluster, Actions::CMD_START_ACTION, Actions::ActionRequest.new(3_u16, 15_u32)))
    cluster.action_list.first.state.should eq(Actions::ActionState::Active)
    event_ids.should eq([Actions::EVENT_STATE_CHANGED])
    Actions::StateChangedEvent.from_tlv(payloads.first).invoke_id.should eq(15_u32)
  end

  it "encodes the optional InvokeID and required duration at the canonical tags" do
    request = Actions::DurationRequest.new(3_u16, 42_u32)
    fields = request.to_tlv(nil).as_structure
    fields.keys.should eq([0_u8, 2_u8])
    Actions::DurationRequest.from_tlv(request.to_tlv(nil)).duration.should eq(42_u32)
    timed = Actions::TransitionRequest.new(3_u16, 25_u16, 9_u32)
    Actions::TransitionRequest.from_tlv(timed.to_tlv(nil)).invoke_id.should eq(9_u32)
  end

  it "does not emit progress events without InvokeID and reports host failures" do
    cluster = actions_fixture
    events = [] of UInt32
    cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, event : UInt32, _priority : Matter::InteractionModel::EventPriority, _data : TLV::Any, _fabric : UInt8?) do
      events << event
      nil
    end
    cluster.on_execute do |_action, _command, _invoke_id, _parameter|
      IMStatus.failure
    end
    expect_status(invoke(cluster, Actions::CMD_INSTANT_ACTION, Actions::ActionRequest.new(3_u16, 8_u32)), IMCode::Failure)
    events.should eq([Actions::EVENT_ACTION_FAILED])
    cluster.action_list.first.state.should eq(Actions::ActionState::Inactive)
    events.clear
    cluster.on_execute do |_action, _command, _invoke_id, _parameter|
      IMStatus.success
    end
    expect_success(invoke(cluster, Actions::CMD_START_ACTION, Actions::ActionRequest.new(3_u16)))
    events.should be_empty
  end

  it "calls the host again on duration expiry before changing state" do
    endpoints = [Actions::EndpointList.new(7_u16, "Room", Actions::EndpointListType::Room, [2_u16])]
    action = Actions::Action.new(3_u16, "Transition", Actions::ActionType::Scene, 7_u16,
      Actions::CommandBits::InstantActionWithTransition, Actions::ActionState::Inactive)
    cluster = build(Actions, action_list: [action], endpoint_lists: endpoints)
    commands = [] of Actions::ActionCommand
    cluster.on_execute do |_action, command, _invoke_id, _parameter|
      commands << command
      IMStatus.success
    end
    expect_success(invoke(cluster, Actions::CMD_INSTANT_ACTION_WITH_TRANSITION,
      Actions::TransitionRequest.new(3_u16, 0_u16, 1_u32)))
    cluster.action_list.first.state.should eq(Actions::ActionState::Active)
    sleep 0.05.seconds
    commands.should eq([Actions::ActionCommand::InstantActionWithTransition, Actions::ActionCommand::StopAction])
    cluster.action_list.first.state.should eq(Actions::ActionState::Inactive)
  end

  it "restores an inactive state after a timed disable of a paused action" do
    endpoints = [Actions::EndpointList.new(7_u16, "Room", Actions::EndpointListType::Room, [2_u16])]
    action = Actions::Action.new(3_u16, "Routine", Actions::ActionType::Automation, 7_u16,
      Actions::CommandBits::DisableActionWithDuration, Actions::ActionState::Paused)
    cluster = build(Actions, action_list: [action], endpoint_lists: endpoints)
    cluster.on_execute do |_action, _command, _invoke_id, _parameter|
      IMStatus.success
    end
    expect_success(invoke(cluster, Actions::CMD_DISABLE_ACTION_WITH_DURATION,
      Actions::DurationRequest.new(3_u16, 0_u32)))
    cluster.action_list.first.state.should eq(Actions::ActionState::Disabled)
    sleep 0.05.seconds
    cluster.action_list.first.state.should eq(Actions::ActionState::Inactive)
  end
end
