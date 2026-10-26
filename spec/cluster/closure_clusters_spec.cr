require "../spec_helper"

private alias Control = Matter::Cluster::ClosureControl
private alias Dimension = Matter::Cluster::ClosureDimension
private alias IMCode = Matter::InteractionModel::StatusCode

describe Control do
  it "declares revision-one mandatory state and timed MoveTo" do
    cluster = build(Control)
    cluster.cluster_id.id.should eq(0x0104_u32)
    cluster.cluster_revision.should eq(1_u16)
    attribute_ids(cluster).should contain(Control::ATTR_MAIN_STATE)
    attribute_ids(cluster).should contain(Control::ATTR_CURRENT_ERROR_LIST)
    attribute_ids(cluster).should contain(Control::ATTR_OVERALL_CURRENT_STATE)
    accepted_command_ids(cluster).should contain(Control::CMD_MOVE_TO)
    metadata = cluster.get_command_metadata(Control::CMD_MOVE_TO).as(Matter::Cluster::CommandMetadata)
    metadata.timed?.should be_true
    metadata.access.should eq(Matter::InteractionModel::EntryPrivilege::Operate)
    expect_raises(ArgumentError) { build(Control, feature_map: Control::Feature::None) }
  end

  it "gates Stop and Calibrate and updates target only after admission" do
    cluster = build(Control, feature_map: Control::Feature::Positioning | Control::Feature::Calibration)
    accepted_command_ids(cluster).should contain(Control::CMD_STOP)
    accepted_command_ids(cluster).should contain(Control::CMD_CALIBRATE)
    cluster.on_move_to { |_request| false }
    expect_status(invoke(cluster, Control::CMD_MOVE_TO,
      Control::MoveToRequest.new(Control::TargetPosition::MoveToFullyOpen)), IMCode::InvalidInState)
    read(cluster, Control::ATTR_OVERALL_TARGET_STATE).should be_nil
    cluster.on_move_to { |_request| true }
    expect_success(invoke(cluster, Control::CMD_MOVE_TO,
      Control::MoveToRequest.new(Control::TargetPosition::MoveToFullyOpen)))
    cluster.overall_target_state.try(&.position).should eq(Control::TargetPosition::MoveToFullyOpen)
    expect_success(invoke(cluster, Control::CMD_STOP))
    cluster.main_state.should eq(Control::MainState::Stopped)
    instantaneous = build(Control, feature_map: Control::Feature::Positioning | Control::Feature::Instantaneous)
    expect_status(invoke(instantaneous, Control::CMD_STOP), IMCode::UnsupportedCommand)
  end
end

describe Dimension do
  it "declares revision-one fixed 100ths-percent resolution and timed commands" do
    cluster = build(Dimension)
    cluster.cluster_id.id.should eq(0x0105_u32)
    cluster.cluster_revision.should eq(1_u16)
    read(cluster, Dimension::ATTR_RESOLUTION).should eq(1_u16)
    read(cluster, Dimension::ATTR_STEP_VALUE).should eq(1_u16)
    [Dimension::CMD_SET_TARGET, Dimension::CMD_STEP].each do |id|
      metadata = cluster.get_command_metadata(id).as(Matter::Cluster::CommandMetadata)
      metadata.timed?.should be_true
      metadata.access.should eq(Matter::InteractionModel::EntryPrivilege::Operate)
    end
    expect_raises(ArgumentError) { build(Dimension, feature_map: Dimension::Feature::None) }
  end

  it "rounds a target to resolution and steps from the previous target" do
    cluster = build(Dimension, resolution: 100_u16, step_value: 500_u16)
    cluster.on_set_target { |_request| true }
    expect_success(invoke(cluster, Dimension::CMD_SET_TARGET, Dimension::SetTargetRequest.new(1234_u16)))
    cluster.target_state.try(&.position).should eq(1200_u16)
    expect_success(invoke(cluster, Dimension::CMD_STEP,
      Dimension::StepRequest.new(Dimension::StepDirection::Increase, 2_u16)))
    cluster.target_state.try(&.position).should eq(2200_u16)
    expect_status(invoke(cluster, Dimension::CMD_STEP,
      Dimension::StepRequest.new(Dimension::StepDirection::Increase, 0_u16)), IMCode::ConstraintError)
  end
end

describe "Closure feature and wire conformance" do
  it "encodes unknown control state members as Null only when their feature is present" do
    positioning = build(Control, feature_map: Control::Feature::Positioning,
      overall_current_state: Control::CurrentState.new,
      overall_target_state: Control::TargetState.new)
    [Control::ATTR_OVERALL_CURRENT_STATE, Control::ATTR_OVERALL_TARGET_STATE].each do |id|
      fields = positioning.read_attribute(id).as(TLV::Any).as_structure
      fields.keys.should eq(id == Control::ATTR_OVERALL_CURRENT_STATE ? [0_u8, 3_u8] : [0_u8])
      fields[0_u8].header.element_type.null?.should be_true
    end

    latching = build(Control, feature_map: Control::Feature::MotionLatching,
      overall_current_state: Control::CurrentState.new,
      overall_target_state: Control::TargetState.new)
    [Control::ATTR_OVERALL_CURRENT_STATE, Control::ATTR_OVERALL_TARGET_STATE].each do |id|
      fields = latching.read_attribute(id).as(TLV::Any).as_structure
      fields.keys.should eq(id == Control::ATTR_OVERALL_CURRENT_STATE ? [1_u8, 3_u8] : [1_u8])
      fields[1_u8].header.element_type.null?.should be_true
    end

    both = build(Control, feature_map: Control::Feature::Positioning | Control::Feature::MotionLatching,
      overall_current_state: Control::CurrentState.new,
      overall_target_state: Control::TargetState.new)
    [Control::ATTR_OVERALL_CURRENT_STATE, Control::ATTR_OVERALL_TARGET_STATE].each do |id|
      fields = both.read_attribute(id).as(TLV::Any).as_structure
      fields.keys.should eq(id == Control::ATTR_OVERALL_CURRENT_STATE ? [0_u8, 1_u8, 3_u8] : [0_u8, 1_u8])
      fields[0_u8].header.element_type.null?.should be_true
      fields[1_u8].header.element_type.null?.should be_true
    end
    both.report_state(Control::CurrentState.new(Control::CurrentPosition::FullyClosed, false))
    fields = both.read_attribute(Control::ATTR_OVERALL_CURRENT_STATE).as(TLV::Any).as_structure
    fields[0_u8].header.element_type.null?.should be_false
    fields[1_u8].header.element_type.null?.should be_false
    both.overall_current_state.try(&.latch).should be_false
  end

  it "encodes unknown dimension state members as Null only when their feature is present" do
    positioning = build(Dimension, feature_map: Dimension::Feature::Positioning | Dimension::Feature::Translation,
      current_state: Dimension::State.new, target_state: Dimension::State.new)
    latching = build(Dimension, feature_map: Dimension::Feature::MotionLatching,
      current_state: Dimension::State.new, target_state: Dimension::State.new)
    both = build(Dimension, feature_map: Dimension::Feature::Positioning | Dimension::Feature::Translation |
                                         Dimension::Feature::MotionLatching,
      current_state: Dimension::State.new, target_state: Dimension::State.new)
    { {positioning, [0_u8]}, {latching, [1_u8]}, {both, [0_u8, 1_u8]} }.each do |cluster, expected|
      [Dimension::ATTR_CURRENT_STATE, Dimension::ATTR_TARGET_STATE].each do |id|
        fields = cluster.read_attribute(id).as(TLV::Any).as_structure
        fields.keys.should eq(expected)
        expected.each { |tag| fields[tag].header.element_type.null?.should be_true }
      end
    end
    both.report_state(Dimension::State.new(500_u16, false))
    fields = both.read_attribute(Dimension::ATTR_CURRENT_STATE).as(TLV::Any).as_structure
    fields[0_u8].header.element_type.null?.should be_false
    fields[1_u8].header.element_type.null?.should be_false
  end

  it "hides conditional members and rejects impossible feature combinations" do
    latch_control = build(Control, feature_map: Control::Feature::MotionLatching,
      latch_control_modes: Control::REMOTE_LATCHING | Control::REMOTE_UNLATCHING)
    attribute_ids(latch_control).should contain(Control::ATTR_LATCH_CONTROL_MODES)
    attribute_ids(latch_control).should_not contain(Control::ATTR_COUNTDOWN_TIME)
    expect_status(invoke(latch_control, Control::CMD_CALIBRATE), IMCode::UnsupportedCommand)
    expect_raises(ArgumentError) do
      build(Control, feature_map: Control::Feature::Speed | Control::Feature::MotionLatching)
    end
    expect_raises(ArgumentError) do
      build(Dimension, feature_map: Dimension::Feature::Speed | Dimension::Feature::MotionLatching)
    end
    expect_raises(ArgumentError) { build(Dimension, feature_map: Dimension::Feature::Positioning) }
    expect_raises(ArgumentError) do
      build(Dimension, feature_map: Dimension::Feature::Positioning |
                                    Dimension::Feature::Translation | Dimension::Feature::Rotation)
    end
    expect_raises(ArgumentError) do
      build(Dimension, feature_map: Dimension::Feature::Positioning |
                                    Dimension::Feature::Translation | Dimension::Feature::Limitation,
        resolution: 100_u16,
        step_value: 100_u16,
        limit_range: Dimension::PercentRange.new(50_u16, 9000_u16))
    end
    limited = build(Dimension, feature_map: Dimension::Feature::Positioning |
                                            Dimension::Feature::Translation | Dimension::Feature::Limitation,
      resolution: 100_u16, step_value: 100_u16)
    expect_raises(ArgumentError) { limited.limit_range = Dimension::PercentRange.new(50_u16, 9000_u16) }
  end

  it "serializes feature-present closure fields with canonical context tags" do
    control = Control::CurrentState.new(Control::CurrentPosition::FullyOpened,
      true, Control::Speed::High, true)
    control.to_tlv(nil).as_structure.keys.should eq([0_u8, 1_u8, 2_u8, 3_u8])
    parsed = Control::CurrentState.from_tlv(control.to_tlv(nil))
    parsed.secure_state.should be_true
    # SecureState is always required but nullable, so nil is an explicit TLV null.
    Control::CurrentState.new.to_tlv(nil).as_structure.keys.should eq([3_u8])
    dimension = Dimension::State.new(1234_u16, false, Dimension::Speed::Low)
    dimension.to_tlv(nil).as_structure.keys.should eq([0_u8, 1_u8, 2_u8])
    Dimension::State.from_tlv(dimension.to_tlv(nil)).position.should eq(1234_u16)
    Dimension::SetTargetRequest.new(1234_u16).to_tlv(nil).as_structure.keys.should eq([0_u8])
  end

  it "does not modify the target when the host refuses a panel request" do
    panel = build(Dimension)
    panel.on_set_target { |_request| false }
    expect_status(invoke(panel, Dimension::CMD_SET_TARGET,
      Dimension::SetTargetRequest.new(2300_u16)), IMCode::InvalidInState)
    read(panel, Dimension::ATTR_TARGET_STATE).should be_nil
  end

  it "saturates large down steps at zero without arithmetic underflow" do
    panel = build(Dimension, resolution: 100_u16, step_value: 500_u16,
      current_state: Dimension::State.new(100_u16))
    panel.on_set_target { |_request| true }
    expect_success(invoke(panel, Dimension::CMD_STEP,
      Dimension::StepRequest.new(Dimension::StepDirection::Decrease, 20_u16)))
    panel.target_state.try(&.position).should eq(0_u16)
  end
end

describe "Matter 1.6 closure device type declarations" do
  it "keeps control and dimension on their designated device types" do
    closure = Matter::DeviceType.for(Matter::DeviceType::CLOSURE)
    panel = Matter::DeviceType.for(Matter::DeviceType::CLOSURE_PANEL)
    closure.revision.should eq(1_u16)
    panel.revision.should eq(1_u16)
    closure.required_server_clusters.should contain(Control::CLUSTER_ID)
    closure.required_server_clusters.should_not contain(Dimension::CLUSTER_ID)
    panel.required_server_clusters.should contain(Dimension::CLUSTER_ID)
    panel.required_server_clusters.should_not contain(Control::CLUSTER_ID)
  end
end

describe "Closure latching and optional fields" do
  it "applies a false latch request when remote unlatching is allowed" do
    cluster = build(Control, feature_map: Control::Feature::MotionLatching,
      latch_control_modes: Control::REMOTE_UNLATCHING)
    cluster.on_move_to { |_request| true }
    expect_success(invoke(cluster, Control::CMD_MOVE_TO, Control::MoveToRequest.new(latch: false)))
    cluster.overall_target_state.try(&.latch).should be_false
    expect_status(invoke(cluster, Control::CMD_MOVE_TO,
      Control::MoveToRequest.new(latch: true)), IMCode::InvalidInState)
    cluster.overall_target_state.try(&.latch).should be_false
  end

  it "does not advertise a Step command for latch-only panels" do
    panel = build(Dimension, feature_map: Dimension::Feature::MotionLatching,
      latch_control_modes: Dimension::REMOTE_LATCHING)
    attribute_ids(panel).should_not contain(Dimension::ATTR_RESOLUTION)
    expect_status(invoke(panel, Dimension::CMD_STEP,
      Dimension::StepRequest.new(Dimension::StepDirection::Increase, 1_u16)), IMCode::UnsupportedCommand)
  end
end

describe "Closure Control events" do
  it "emits an empty MovementCompleted payload after a reported position change" do
    cluster = build(Control, overall_current_state: Control::CurrentState.new(Control::CurrentPosition::FullyClosed))
    records = [] of {UInt32, TLV::Any}
    cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, event : UInt32, _priority : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) do
      records << {event, data}
      nil
    end
    cluster.report_state(Control::CurrentState.new(Control::CurrentPosition::FullyOpened))
    records.map(&.[0]).should eq([Control::EVENT_MOVEMENT_COMPLETED])
    records[0][1].as_structure.should be_empty
  end

  it "emits operational errors and manual engagement changes with canonical payloads" do
    cluster = build(Control, feature_map: Control::Feature::Positioning | Control::Feature::ManuallyOperable)
    records = [] of {UInt32, TLV::Any}
    cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, event : UInt32, _priority : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) do
      records << {event, data}
      nil
    end
    cluster.report_errors([Control::ClosureError::PhysicallyBlocked])
    cluster.report_engaged(false)
    records.map(&.[0]).should eq([Control::EVENT_OPERATIONAL_ERROR, Control::EVENT_ENGAGE_STATE_CHANGED])
    Control::OperationalErrorEvent.from_tlv(records[0][1]).error_state.should eq([Control::ClosureError::PhysicallyBlocked])
    Control::EngageStateChangedEvent.from_tlv(records[1][1]).engage_value?.should be_false
    expect_raises(ArgumentError) do
      cluster.report_errors([Control::ClosureError::PhysicallyBlocked, Control::ClosureError::PhysicallyBlocked])
    end
  end
end

describe "Closure unsupported command fields" do
  it "accepts and ignores fields for unsupported optional features" do
    control = build(Control)
    expect_success(invoke(control, Control::CMD_MOVE_TO,
      Control::MoveToRequest.new(speed: Control::Speed::High)))
    control.overall_target_state.should be_nil
    panel = build(Dimension)
    expect_success(invoke(panel, Dimension::CMD_SET_TARGET,
      Dimension::SetTargetRequest.new(speed: Dimension::Speed::High)))
    panel.target_state.should be_nil
  end
end
