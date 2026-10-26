require "../spec_helper"

private alias ControlThermostat = Matter::Cluster::Thermostat
private alias ControlStatus = Matter::InteractionModel::StatusCode

# Matter 1.6 §4.3.11.21: writes are accepted for legacy clients but do not
# change the thermostat's operating capabilities.
describe "Thermostat ControlSequenceOfOperation" do
  it "silently ignores a valid interaction-model write without changing its data version" do
    cluster = build(ControlThermostat,
      control_sequence_of_operation: ControlThermostat::ControlSequenceOfOperation::HeatingOnly)
    version = cluster.data_version
    requested = ControlThermostat::ControlSequenceOfOperation::CoolingOnly

    result = cluster.write_attribute(ControlThermostat::ATTR_CONTROL_SEQUENCE_OF_OPERATION,
      TLV::Serializable.serialize_value(requested, nil))

    result.status.should eq(ControlStatus::Success)
    cluster.control_sequence_of_operation.should eq(ControlThermostat::ControlSequenceOfOperation::HeatingOnly)
    cluster.data_version.should eq(version)
    wire = cluster.read_attribute(ControlThermostat::ATTR_CONTROL_SEQUENCE_OF_OPERATION, nil).as(TLV::Any)
    wire.value.should eq(ControlThermostat::ControlSequenceOfOperation::HeatingOnly.value.to_u64)
  end
end
