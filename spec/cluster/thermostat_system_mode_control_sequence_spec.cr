require "../spec_helper"

private alias ModeThermostat = Matter::Cluster::Thermostat
private alias ModeStatus = Matter::InteractionModel::StatusCode

# Matter 1.6 §4.3.11.22 limits SystemMode by the fixed
# ControlSequenceOfOperation, even when the corresponding feature is present.
describe "Thermostat SystemMode control sequence" do
  features = ModeThermostat::Feature::Heating | ModeThermostat::Feature::Cooling |
             ModeThermostat::Feature::Automode | ModeThermostat::Feature::Events

  {
    {ModeThermostat::ControlSequenceOfOperation::HeatingOnly, ModeThermostat::SystemMode::Cool},
    {ModeThermostat::ControlSequenceOfOperation::HeatingWithReheat, ModeThermostat::SystemMode::Precooling},
    {ModeThermostat::ControlSequenceOfOperation::CoolingOnly, ModeThermostat::SystemMode::Heat},
    {ModeThermostat::ControlSequenceOfOperation::CoolingWithReheat, ModeThermostat::SystemMode::EmergencyHeat},
  }.each do |sequence, forbidden_mode|
    it "rejects #{forbidden_mode} with #{sequence} without changing state" do
      cluster = build(ModeThermostat, feature_map: features, control_sequence_of_operation: sequence)
      version = cluster.data_version
      events = 0
      cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, _id : UInt32, _priority : Matter::InteractionModel::EventPriority, _data : TLV::Any, _fabric : UInt8?) do
        events += 1
        nil
      end

      result = cluster.write_attribute(ModeThermostat::ATTR_SYSTEM_MODE,
        TLV::Serializable.serialize_value(forbidden_mode, nil))

      result.status.should eq(ModeStatus::ConstraintError)
      cluster.system_mode.should eq(ModeThermostat::SystemMode::Off)
      cluster.data_version.should eq(version)
      events.should eq(0)
    end
  end

  it "still permits an allowed heating mode" do
    cluster = build(ModeThermostat, feature_map: features,
      control_sequence_of_operation: ModeThermostat::ControlSequenceOfOperation::HeatingOnly)

    result = cluster.write_attribute(ModeThermostat::ATTR_SYSTEM_MODE,
      TLV::Serializable.serialize_value(ModeThermostat::SystemMode::Heat, nil))

    result.status.should eq(ModeStatus::Success)
    cluster.system_mode.should eq(ModeThermostat::SystemMode::Heat)
  end

  it "permits heating when the combined-with-reheat sequence reports all modes" do
    cluster = build(ModeThermostat, feature_map: features,
      control_sequence_of_operation: ModeThermostat::ControlSequenceOfOperation::CoolingAndHeatingWithReheat)

    result = cluster.write_attribute(ModeThermostat::ATTR_SYSTEM_MODE,
      TLV::Serializable.serialize_value(ModeThermostat::SystemMode::Heat, nil))

    result.status.should eq(ModeStatus::Success)
    cluster.system_mode.should eq(ModeThermostat::SystemMode::Heat)
  end
end
