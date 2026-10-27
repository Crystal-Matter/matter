require "../spec_helper"

private alias Pump = Matter::Cluster::PumpConfigurationControl
private alias IMCode = Matter::InteractionModel::StatusCode

describe Pump do
  it "declares the Matter 1.6 speed pump profile and mandatory attributes" do
    pump = build(Pump, max_speed: 3_600_u16, min_const_speed: 400_u16,
      max_const_speed: 3_600_u16)
    pump.cluster_id.id.should eq(0x0200_u32)
    pump.cluster_revision.should eq(5_u16)
    read(pump, Pump::GLOBAL_FEATURE_MAP).should eq(Pump::Feature::ConstantSpeed.value)
    [Pump::ATTR_MAX_PRESSURE, Pump::ATTR_MAX_SPEED, Pump::ATTR_MAX_FLOW,
     Pump::ATTR_MIN_CONST_SPEED, Pump::ATTR_MAX_CONST_SPEED,
     Pump::ATTR_EFFECTIVE_OPERATION_MODE, Pump::ATTR_EFFECTIVE_CONTROL_MODE,
     Pump::ATTR_CAPACITY, Pump::ATTR_OPERATION_MODE].each do |id|
      attribute_ids(pump).should contain(id)
    end
    read(pump, Pump::ATTR_MAX_SPEED).should eq(3_600_u16)
    read(pump, Pump::ATTR_MAX_PRESSURE).should be_nil
    read(pump, Pump::ATTR_CONTROL_MODE).should eq(Pump::ControlMode::ConstantSpeed.value)
    pump.events.should be_empty
    read_status(pump, Pump::ATTR_MIN_CONST_FLOW).status.should eq(IMCode::UnsupportedAttribute)
    pump.get_attribute_metadata(Pump::ATTR_OPERATION_MODE).as(Matter::Cluster::AttributeMetadata).write_access.should eq(Matter::InteractionModel::EntryPrivilege::Manage)
    pump.get_attribute_metadata(Pump::ATTR_CONTROL_MODE).as(Matter::Cluster::AttributeMetadata).write_access.should eq(Matter::InteractionModel::EntryPrivilege::Manage)
  end

  it "rejects unadvertised and unsupported modes without changing its state" do
    pump = build(Pump)
    expect_status(write(pump, Pump::ATTR_CONTROL_MODE, Pump::ControlMode::ConstantFlow.value), IMCode::ConstraintError)
    expect_status(write(pump, Pump::ATTR_OPERATION_MODE, Pump::OperationMode::Local.value), IMCode::ConstraintError)
    pump.on_apply_mode { |_operation, _control| Matter::InteractionModel::Status.success }
    expect_success(write(pump, Pump::ATTR_OPERATION_MODE, Pump::OperationMode::Minimum.value))
    read(pump, Pump::ATTR_OPERATION_MODE).should eq(Pump::OperationMode::Minimum.value)
    read(pump, Pump::ATTR_EFFECTIVE_OPERATION_MODE).should eq(Pump::OperationMode::Normal.value)
    pump.report_operation(Pump::OperationMode::Minimum, Pump::ControlMode::ConstantSpeed, 400_u16, nil)
    read(pump, Pump::ATTR_EFFECTIVE_OPERATION_MODE).should eq(Pump::OperationMode::Minimum.value)
    read(pump, Pump::ATTR_SPEED).should eq(400_u16)
  end

  it "requires host acceptance and validates reported telemetry" do
    pump = build(Pump, max_speed: 1_000_u16)
    expect_status(write(pump, Pump::ATTR_OPERATION_MODE, Pump::OperationMode::Maximum.value), IMCode::InvalidInState)
    pump.on_apply_mode { |_operation, _control| Matter::InteractionModel::Status.invalid_in_state }
    expect_status(write(pump, Pump::ATTR_OPERATION_MODE, Pump::OperationMode::Maximum.value), IMCode::InvalidInState)
    read(pump, Pump::ATTR_OPERATION_MODE).should eq(Pump::OperationMode::Normal.value)
    expect_raises(ArgumentError) do
      pump.report_operation(Pump::OperationMode::Maximum, Pump::ControlMode::ConstantSpeed, 1_001_u16, nil)
    end
    read(pump, Pump::ATTR_EFFECTIVE_OPERATION_MODE).should eq(Pump::OperationMode::Normal.value)
    expect_raises(ArgumentError) do
      pump.report_operation(Pump::OperationMode::Local, Pump::ControlMode::ConstantSpeed, nil, nil)
    end
  end

  it "requires a supported regulation feature and consistent fixed limits" do
    expect_raises(ArgumentError) { build(Pump, feature_map: Pump::Feature::None) }
    expect_raises(ArgumentError) { build(Pump, min_const_speed: 500_u16, max_const_speed: 400_u16) }
    expect_raises(ArgumentError) { build(Pump, feature_map: Pump::Feature::Automatic) }
  end

  it "keeps the advertised pump profile fixed after construction" do
    pump = build(Pump)
    expect_raises(ArgumentError) { pump.feature_map = Pump::Feature::Automatic }
    expect_raises(ArgumentError) { pump.feature_map = Pump::Feature::ConstantFlow }
    read(pump, Pump::GLOBAL_FEATURE_MAP).should eq(Pump::Feature::ConstantSpeed.value)
  end

  it "selects and validates each advertised regulation mode" do
    profiles = {
      {Pump::Feature::ConstantPressure, Pump::ControlMode::ConstantPressure},
      {Pump::Feature::CompensatedPressure, Pump::ControlMode::ProportionalPressure},
      {Pump::Feature::ConstantFlow, Pump::ControlMode::ConstantFlow},
      {Pump::Feature::ConstantTemperature, Pump::ControlMode::ConstantTemperature},
    }
    profiles.each do |feature, control|
      pump = build(Pump, feature_map: feature)
      read(pump, Pump::ATTR_CONTROL_MODE).should eq(control.value)
      read(pump, Pump::ATTR_EFFECTIVE_CONTROL_MODE).should eq(control.value)
      expect_status(write(pump, Pump::ATTR_OPERATION_MODE, Pump::OperationMode::Minimum.value), IMCode::ConstraintError)
      expect_status(write(pump, Pump::ATTR_CONTROL_MODE, Pump::ControlMode::ConstantSpeed.value), IMCode::ConstraintError)
      pump.on_apply_mode { |_operation, _control| Matter::InteractionModel::Status.success }
      pump.report_operation(Pump::OperationMode::Normal, control, nil, 123_i16)
      read(pump, Pump::ATTR_CAPACITY).should eq(123_i16)
    end
  end

  it "supports advertised automatic and local modes without broadening speed-only defaults" do
    features = Pump::Feature::ConstantFlow | Pump::Feature::Automatic | Pump::Feature::LocalOperation
    pump = build(Pump, feature_map: features, min_const_flow: 20_u16, max_const_flow: 200_u16)
    attribute_ids(pump).should contain(Pump::ATTR_MIN_CONST_FLOW)
    pump.on_apply_mode { |_operation, _control| Matter::InteractionModel::Status.success }
    expect_success(write(pump, Pump::ATTR_CONTROL_MODE, Pump::ControlMode::Automatic.value))
    expect_success(write(pump, Pump::ATTR_OPERATION_MODE, Pump::OperationMode::Local.value))
    pump.report_operation(Pump::OperationMode::Local, Pump::ControlMode::Automatic, nil, nil)
    read(pump, Pump::ATTR_EFFECTIVE_OPERATION_MODE).should eq(Pump::OperationMode::Local.value)
    restored = build(Pump, feature_map: features)
    restored.restore_state(pump.save_state)
    read(restored, Pump::ATTR_OPERATION_MODE).should eq(Pump::OperationMode::Local.value)
    read(restored, Pump::ATTR_CONTROL_MODE).should eq(Pump::ControlMode::Automatic.value)
  end

  it "switches between two advertised regulation modes only after host acceptance" do
    features = Pump::Feature::ConstantSpeed | Pump::Feature::ConstantPressure
    pump = build(Pump, feature_map: features)
    read(pump, Pump::ATTR_CONTROL_MODE).should eq(Pump::ControlMode::ConstantSpeed.value)
    pump.on_apply_mode { |_operation, _control| Matter::InteractionModel::Status.invalid_in_state }
    expect_status(write(pump, Pump::ATTR_CONTROL_MODE, Pump::ControlMode::ConstantPressure.value), IMCode::InvalidInState)
    read(pump, Pump::ATTR_CONTROL_MODE).should eq(Pump::ControlMode::ConstantSpeed.value)
    pump.on_apply_mode { |_operation, _control| Matter::InteractionModel::Status.success }
    expect_success(write(pump, Pump::ATTR_CONTROL_MODE, Pump::ControlMode::ConstantPressure.value))
    pump.report_operation(Pump::OperationMode::Normal, Pump::ControlMode::ConstantPressure, nil, nil)
    read(pump, Pump::ATTR_EFFECTIVE_CONTROL_MODE).should eq(Pump::ControlMode::ConstantPressure.value)
  end

  it "validates independent fixed ranges and reported capability limits" do
    expect_raises(ArgumentError) do
      build(Pump, feature_map: Pump::Feature::ConstantFlow, min_const_flow: 300_u16, max_const_flow: 200_u16)
    end
    expect_raises(ArgumentError) do
      build(Pump, feature_map: Pump::Feature::ConstantTemperature, min_const_temp: 100_i16, max_const_temp: 0_i16)
    end
    pump = build(Pump, feature_map: Pump::Feature::ConstantFlow, max_flow: 200_u16)
    expect_raises(ArgumentError) do
      pump.report_operation(Pump::OperationMode::Minimum, Pump::ControlMode::ConstantFlow, nil, nil)
    end
  end

  it "advertises and emits only selected optional fault events" do
    pump = build(Pump, fault_events: Set{Pump::Fault::DryRunning, Pump::Fault::SensorFailure})
    pump.events.map(&.id.id).should eq([Pump::EVENT_DRY_RUNNING, Pump::EVENT_SENSOR_FAILURE])
    pump.get_event_metadata(Pump::EVENT_PUMP_BLOCKED).should be_nil
    recorded = [] of Tuple(UInt32, Matter::InteractionModel::EventPriority, TLV::Any)
    pump.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, id : UInt32, priority : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) do
      recorded << {id, priority, data}
      nil
    end
    pump.report_fault(Pump::Fault::DryRunning)
    pump.report_fault(Pump::Fault::SensorFailure)
    recorded.map(&.[0]).should eq([Pump::EVENT_DRY_RUNNING, Pump::EVENT_SENSOR_FAILURE])
    recorded[0][1].should eq(Matter::InteractionModel::EventPriority::Critical)
    recorded[1][1].should eq(Matter::InteractionModel::EventPriority::Info)
    expect_raises(ArgumentError) { pump.report_fault(Pump::Fault::PumpBlocked) }
  end

  it "restores the requested modes and lifetime counters" do
    pump = build(Pump)
    pump.on_apply_mode { |_operation, _control| Matter::InteractionModel::Status.success }
    expect_success(write(pump, Pump::ATTR_OPERATION_MODE, Pump::OperationMode::Maximum.value))
    expect_success(write(pump, Pump::ATTR_LIFETIME_RUNNING_HOURS, 10_u32))
    expect_success(write(pump, Pump::ATTR_LIFETIME_ENERGY_CONSUMED, 22_u32))
    restored = build(Pump)
    restored.restore_state(pump.save_state)
    read(restored, Pump::ATTR_OPERATION_MODE).should eq(Pump::OperationMode::Maximum.value)
    read(restored, Pump::ATTR_LIFETIME_RUNNING_HOURS).should eq(10_u32)
    read(restored, Pump::ATTR_LIFETIME_ENERGY_CONSUMED).should eq(22_u32)
  end
end
