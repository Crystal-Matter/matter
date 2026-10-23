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
    expect_raises(ArgumentError) { build(Pump, feature_map: Pump::Feature::ConstantFlow) }
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
