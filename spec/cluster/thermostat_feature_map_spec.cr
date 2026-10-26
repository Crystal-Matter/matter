require "../spec_helper"

private alias FeatureThermostat = Matter::Cluster::Thermostat

describe "Thermostat base feature conformance" do
  it "requires a heating or cooling capability" do
    expect_raises(ArgumentError, "Thermostat requires HEAT or COOL") do
      build(FeatureThermostat, feature_map: FeatureThermostat::Feature::None)
    end
  end

  it "requires both heating and cooling when AUTO is advertised" do
    {FeatureThermostat::Feature::Automode,
     FeatureThermostat::Feature::Automode | FeatureThermostat::Feature::Heating,
     FeatureThermostat::Feature::Automode | FeatureThermostat::Feature::Cooling}.each do |features|
      expect_raises(ArgumentError, "AUTO requires HEAT and COOL") do
        build(FeatureThermostat, feature_map: features)
      end
    end
  end

  it "derives a compatible control sequence when the caller omits it" do
    {
      {FeatureThermostat::Feature::Heating, FeatureThermostat::ControlSequenceOfOperation::HeatingOnly},
      {FeatureThermostat::Feature::Cooling, FeatureThermostat::ControlSequenceOfOperation::CoolingOnly},
      {FeatureThermostat::Feature::Heating | FeatureThermostat::Feature::Cooling,
       FeatureThermostat::ControlSequenceOfOperation::CoolingAndHeating},
    }.each do |features, sequence|
      cluster = build(FeatureThermostat, feature_map: features)
      cluster.control_sequence_of_operation.should eq(sequence)
      cluster.system_mode.should eq(FeatureThermostat::SystemMode::Off)
    end
  end

  it "keeps an explicitly selected compatible control sequence" do
    cluster = build(FeatureThermostat, feature_map: FeatureThermostat::Feature::Heating,
      control_sequence_of_operation: FeatureThermostat::ControlSequenceOfOperation::HeatingWithReheat)
    cluster.control_sequence_of_operation.should eq(FeatureThermostat::ControlSequenceOfOperation::HeatingWithReheat)
  end

  it "keeps SystemMode and DataVersion unchanged after a disallowed mode write" do
    cluster = build(FeatureThermostat, feature_map: FeatureThermostat::Feature::Heating)
    version = cluster.data_version
    result = cluster.write_attribute(FeatureThermostat::ATTR_SYSTEM_MODE,
      TLV::Serializable.serialize_value(FeatureThermostat::SystemMode::Cool, nil))
    result.status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    cluster.system_mode.should eq(FeatureThermostat::SystemMode::Off)
    cluster.data_version.should eq(version)
  end

  it "rejects an incompatible control sequence without constructing mutable state" do
    expect_raises(ArgumentError, "ControlSequenceOfOperation requires COOL") do
      build(FeatureThermostat, feature_map: FeatureThermostat::Feature::Heating,
        control_sequence_of_operation: FeatureThermostat::ControlSequenceOfOperation::CoolingOnly)
    end
    expect_raises(ArgumentError, "ControlSequenceOfOperation requires HEAT") do
      build(FeatureThermostat, feature_map: FeatureThermostat::Feature::Cooling,
        control_sequence_of_operation: FeatureThermostat::ControlSequenceOfOperation::HeatingOnly)
    end
    expect_raises(ArgumentError, "ControlSequenceOfOperation requires HEAT and COOL") do
      build(FeatureThermostat, feature_map: FeatureThermostat::Feature::Heating,
        control_sequence_of_operation: FeatureThermostat::ControlSequenceOfOperation::CoolingAndHeating)
    end
  end

  it "requires a combined control sequence when AUTO is advertised" do
    features = FeatureThermostat::Feature::Heating | FeatureThermostat::Feature::Cooling |
               FeatureThermostat::Feature::Automode
    {FeatureThermostat::ControlSequenceOfOperation::HeatingOnly,
     FeatureThermostat::ControlSequenceOfOperation::CoolingOnly}.each do |sequence|
      expect_raises(ArgumentError, "AUTO requires a combined control sequence") do
        build(FeatureThermostat, feature_map: features, control_sequence_of_operation: sequence,
          system_mode: FeatureThermostat::SystemMode::Auto)
      end
    end
  end

  it "normalizes a legacy heat-only saved combined sequence before restoring running mode" do
    source = build(FeatureThermostat, feature_map: FeatureThermostat::Feature::Heating)
    saved = source.save_state.as(Matter::Storage::Document)
    saved["control_sequence_of_operation"] = "CoolingAndHeating"

    restored = build(FeatureThermostat, feature_map: FeatureThermostat::Feature::Heating)
    restored.restore_state(saved)
    restored.control_sequence_of_operation.should eq(FeatureThermostat::ControlSequenceOfOperation::HeatingOnly)
    restored.save_state.as(Matter::Storage::Document)["control_sequence_of_operation"].should eq("HeatingOnly")
  end

  it "clears a saved SystemMode that is invalid after sequence normalization" do
    source = build(FeatureThermostat, feature_map: FeatureThermostat::Feature::Heating)
    saved = source.save_state.as(Matter::Storage::Document)
    saved["control_sequence_of_operation"] = "CoolingAndHeating"
    saved["system_mode"] = "Cool"

    restored = build(FeatureThermostat, feature_map: FeatureThermostat::Feature::Heating)
    restored.restore_state(saved)
    restored.control_sequence_of_operation.should eq(FeatureThermostat::ControlSequenceOfOperation::HeatingOnly)
    restored.system_mode.should eq(FeatureThermostat::SystemMode::Off)
  end

  it "normalizes an incompatible saved cooling-only sequence" do
    source = build(FeatureThermostat, feature_map: FeatureThermostat::Feature::Cooling)
    saved = source.save_state.as(Matter::Storage::Document)
    saved["control_sequence_of_operation"] = "HeatingOnly"

    restored = build(FeatureThermostat, feature_map: FeatureThermostat::Feature::Cooling)
    restored.restore_state(saved)
    restored.control_sequence_of_operation.should eq(FeatureThermostat::ControlSequenceOfOperation::CoolingOnly)
  end

  it "normalizes a legacy AUTO saved unidirectional sequence while preserving Auto mode" do
    features = FeatureThermostat::Feature::Heating | FeatureThermostat::Feature::Cooling |
               FeatureThermostat::Feature::Automode
    source = build(FeatureThermostat, feature_map: features, system_mode: FeatureThermostat::SystemMode::Auto)
    saved = source.save_state.as(Matter::Storage::Document)
    saved["control_sequence_of_operation"] = "CoolingOnly"

    restored = build(FeatureThermostat, feature_map: features)
    restored.restore_state(saved)
    restored.control_sequence_of_operation.should eq(FeatureThermostat::ControlSequenceOfOperation::CoolingAndHeating)
    restored.system_mode.should eq(FeatureThermostat::SystemMode::Auto)
  end

  it "preserves a compatible saved explicit sequence" do
    features = FeatureThermostat::Feature::Heating | FeatureThermostat::Feature::Cooling
    source = build(FeatureThermostat, feature_map: features,
      control_sequence_of_operation: FeatureThermostat::ControlSequenceOfOperation::HeatingWithReheat)
    restored = build(FeatureThermostat, feature_map: features)
    restored.restore_state(source.save_state.as(Matter::Storage::Document))
    restored.control_sequence_of_operation.should eq(FeatureThermostat::ControlSequenceOfOperation::HeatingWithReheat)
  end
end
