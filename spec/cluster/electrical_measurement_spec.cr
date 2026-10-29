require "../spec_helper"

private alias Electrical = Matter::Cluster::ElectricalMeasurement
private alias Power = Matter::Cluster::ElectricalPowerMeasurement
private alias Energy = Matter::Cluster::ElectricalEnergyMeasurement
private alias Topology = Matter::Cluster::PowerTopology
private alias EndpointNumber = Matter::DataType::EndpointNumber

private def electrical_accuracy(measurement_type : Electrical::MeasurementType) : Electrical::Accuracy
  range = Electrical::AccuracyRange.new(-1000_i64, 1000_i64, percent_max: 100_u16)
  Electrical::Accuracy.new(measurement_type, true, -1000_i64, 1000_i64, [range])
end

describe "Matter 1.6 electrical measurement clusters" do
  it "exposes mandatory power measurement attributes with the 1.6 revision and typed accuracy wire format" do
    accuracy = electrical_accuracy(Electrical::MeasurementType::ActivePower)
    cluster = Power.new(EndpointNumber.new(1_u16), feature_map: Power::Feature::DirectCurrent,
      power_mode: Power::PowerMode::DC, accuracy: [accuracy])
    cluster.cluster_revision.should eq(3_u16)
    cluster.number_of_measurement_types.should eq(1_u8)
    [Power::ATTR_POWER_MODE, Power::ATTR_NUMBER_OF_MEASUREMENT_TYPES,
     Power::ATTR_ACCURACY, Power::ATTR_ACTIVE_POWER].each do |id|
      cluster.get_attribute_metadata(id).should_not be_nil
    end
    wire = read_tlv(cluster, Power::ATTR_ACCURACY)
    decoded = TLV.parse(wire.to_slice)
    decoded.header.element_type.should eq(TLV::ElementType::Array)
    decoded[0][0_u8].as_u8.should eq(Electrical::MeasurementType::ActivePower.value)
    decoded[0][4_u8][0][2_u8].as_u16.should eq(100_u16)
  end

  it "requires a current type and AC for harmonic and polyphase features" do
    accuracy = [electrical_accuracy(Electrical::MeasurementType::ActivePower)]
    expect_raises(ArgumentError) do
      Power.new(EndpointNumber.new(1_u16), feature_map: Power::Feature::None,
        power_mode: Power::PowerMode::Unknown, accuracy: accuracy)
    end
    expect_raises(ArgumentError) do
      Power.new(EndpointNumber.new(1_u16), feature_map: Power::Feature::Harmonics,
        power_mode: Power::PowerMode::AC, accuracy: accuracy)
    end
    ac = Power.new(EndpointNumber.new(1_u16),
      feature_map: Power::Feature::AlternatingCurrent | Power::Feature::Harmonics,
      power_mode: Power::PowerMode::AC, accuracy: accuracy)
    ac.get_attribute_metadata(Power::ATTR_HARMONIC_CURRENTS).should_not be_nil
    ac.get_attribute_metadata(Power::ATTR_HARMONIC_PHASES).should be_nil
    ac.get_attribute_metadata(Power::ATTR_REACTIVE_POWER).should_not be_nil
    expect_raises(ArgumentError) do
      Power.new(EndpointNumber.new(1_u16), feature_map: Power::Feature::DirectCurrent,
        power_mode: Power::PowerMode::AC, accuracy: accuracy)
    end
  end

  it "rejects malformed accuracy ranges and duplicate measurement types" do
    expect_raises(ArgumentError) { Electrical::AccuracyRange.new(0_i64, 10_i64) }
    expect_raises(ArgumentError) { Electrical::AccuracyRange.new(10_i64, 0_i64, percent_max: 100_u16) }
    accuracy = electrical_accuracy(Electrical::MeasurementType::ActivePower)
    expect_raises(ArgumentError) do
      Power.new(EndpointNumber.new(1_u16), feature_map: Power::Feature::DirectCurrent,
        power_mode: Power::PowerMode::DC, accuracy: [accuracy, accuracy])
    end
  end

  it "publishes MeasurementPeriodRanges with a TLV array through the compatibility API" do
    accuracy = [electrical_accuracy(Electrical::MeasurementType::ActivePower)]
    cluster = Power.new(EndpointNumber.new(1_u16), feature_map: Power::Feature::DirectCurrent,
      power_mode: Power::PowerMode::DC, accuracy: accuracy)
    emitted = [] of TLV::Any
    cluster.on_event_emitted = ->(_endpoint : UInt16, _cluster : UInt32, event : UInt32, _priority : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) do
      event.should eq(Power::EVENT_MEASUREMENT_PERIOD_RANGES)
      emitted << data
      nil
    end
    range = Power::MeasurementRange.new(Electrical::MeasurementType::ActivePower,
      -1000_i64, 1000_i64)
    cluster.update_ranges([range])
    emitted.size.should eq(1)
    Power::MeasurementPeriodRangesEvent.from_tlv(emitted.first).ranges.first.max.should eq(1000_i64)
    cluster.update_ranges([] of Power::MeasurementRange)
    cluster.ranges.should be_empty
    emitted.size.should eq(1)
  end

  it "emits one range snapshot per completed period, including equal consecutive periods" do
    accuracy = [electrical_accuracy(Electrical::MeasurementType::ActivePower)]
    cluster = Power.new(EndpointNumber.new(1_u16), feature_map: Power::Feature::DirectCurrent,
      power_mode: Power::PowerMode::DC, accuracy: accuracy)
    emitted = [] of TLV::Any
    cluster.on_event_emitted = ->(_endpoint : UInt16, _cluster : UInt32, event : UInt32, _priority : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) do
      event.should eq(Power::EVENT_MEASUREMENT_PERIOD_RANGES)
      emitted << data
      nil
    end
    range = Power::MeasurementRange.new(Electrical::MeasurementType::ActivePower,
      -1000_i64, 1000_i64)
    input = [range]

    cluster.ranges = input
    emitted.should be_empty # A direct attribute update is not a completed period.
    input.clear
    cluster.ranges.size.should eq(1)
    cluster.ranges.clear
    cluster.ranges.size.should eq(1)
    cluster.complete_measurement_period([range])
    cluster.complete_measurement_period([range])
    emitted.size.should eq(2)
    emitted.each do |event|
      Power::MeasurementPeriodRangesEvent.from_tlv(event).ranges.should eq(cluster.ranges)
    end
  end

  it "rejects invalid ranges before publishing a completed period" do
    accuracy = [electrical_accuracy(Electrical::MeasurementType::ActivePower),
                electrical_accuracy(Electrical::MeasurementType::Voltage)]
    cluster = Power.new(EndpointNumber.new(1_u16), feature_map: Power::Feature::DirectCurrent,
      power_mode: Power::PowerMode::DC, accuracy: accuracy)
    range = Power::MeasurementRange.new(Electrical::MeasurementType::ActivePower,
      -1000_i64, 1000_i64)
    unmatched = Power::MeasurementRange.new(Electrical::MeasurementType::Frequency,
      -1000_i64, 1000_i64)
    emitted = 0
    cluster.on_event_emitted = ->(_endpoint : UInt16, _cluster : UInt32, _event : UInt32, _priority : Matter::InteractionModel::EventPriority, _data : TLV::Any, _fabric : UInt8?) do
      emitted += 1
      nil
    end
    expect_raises(ArgumentError) { cluster.complete_measurement_period([] of Power::MeasurementRange) }
    expect_raises(ArgumentError) { cluster.ranges = [range, range] }
    expect_raises(ArgumentError) { cluster.ranges = [unmatched] }
    cluster.ranges.should be_empty
    emitted.should eq(0)
  end

  it "requires imported/exported and cumulative/periodic feature choices" do
    accuracy = electrical_accuracy(Electrical::MeasurementType::ElectricalEnergy)
    expect_raises(ArgumentError) do
      Energy.new(EndpointNumber.new(1_u16), feature_map: Energy::Feature::ImportedEnergy,
        accuracy: accuracy)
    end
    expect_raises(ArgumentError) do
      Energy.new(EndpointNumber.new(1_u16), feature_map: Energy::Feature::CumulativeEnergy,
        accuracy: accuracy)
    end
    cluster = Energy.new(EndpointNumber.new(1_u16),
      feature_map: Energy::Feature::ImportedEnergy | Energy::Feature::CumulativeEnergy,
      accuracy: accuracy)
    cluster.cluster_revision.should eq(2_u16)
    cluster.get_attribute_metadata(Energy::ATTR_CUMULATIVE_ENERGY_IMPORTED).should_not be_nil
    cluster.get_attribute_metadata(Energy::ATTR_CUMULATIVE_ENERGY_EXPORTED).should be_nil
    cluster.get_event_metadata(Energy::EVENT_CUMULATIVE_ENERGY_MEASURED).should_not be_nil
    cluster.get_event_metadata(Energy::EVENT_PERIODIC_ENERGY_MEASURED).should be_nil
  end

  it "reports cumulative imported energy with a typed event" do
    accuracy = electrical_accuracy(Electrical::MeasurementType::ElectricalEnergy)
    cluster = Energy.new(EndpointNumber.new(1_u16),
      feature_map: Energy::Feature::ImportedEnergy | Energy::Feature::CumulativeEnergy,
      accuracy: accuracy)
    emitted = [] of TLV::Any
    cluster.on_event_emitted = ->(_endpoint : UInt16, _cluster : UInt32, event : UInt32, _priority : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) do
      event.should eq(Energy::EVENT_CUMULATIVE_ENERGY_MEASURED)
      emitted << data
      nil
    end
    measurement = Energy::EnergyMeasurement.new(12345_i64)
    cluster.record_cumulative(imported: measurement)
    cluster.cumulative_energy_imported.should eq(measurement)
    emitted.size.should eq(1)
    Energy::CumulativeEnergyMeasuredEvent.from_tlv(emitted.first).energy_imported
      .as(Energy::EnergyMeasurement).energy.should eq(12345_i64)
  end

  it "reports both directions in periodic events and enforces advertised energy fields" do
    accuracy = electrical_accuracy(Electrical::MeasurementType::ElectricalEnergy)
    cluster = Energy.new(EndpointNumber.new(1_u16),
      feature_map: Energy::Feature::ImportedEnergy | Energy::Feature::ExportedEnergy |
                   Energy::Feature::PeriodicEnergy | Energy::Feature::ApparentEnergy,
      accuracy: accuracy)
    emitted = [] of TLV::Any
    cluster.on_event_emitted = ->(_endpoint : UInt16, _cluster : UInt32, _event : UInt32, _priority : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) do
      emitted << data
      nil
    end
    imported = Energy::EnergyMeasurement.new(20_i64, apparent_energy: 30_i64)
    exported = Energy::EnergyMeasurement.new(10_i64, apparent_energy: 15_i64)
    expect_raises(ArgumentError) { cluster.record_periodic(imported: imported) }
    expect_raises(ArgumentError) { cluster.record_periodic(imported: Energy::EnergyMeasurement.new(20_i64), exported: exported) }
    cluster.record_periodic(imported: imported, exported: exported)
    emitted.size.should eq(1)
    payload = Energy::PeriodicEnergyMeasuredEvent.from_tlv(emitted.first)
    payload.energy_imported.as(Energy::EnergyMeasurement).apparent_energy.should eq(30_i64)
    payload.energy_exported.as(Energy::EnergyMeasurement).energy.should eq(10_i64)
    cluster.get_event_metadata(Energy::EVENT_PERIODIC_ENERGY_MEASURED).should_not be_nil
  end

  it "exposes fixed set endpoints and gated dynamic power flow" do
    node = Topology.new(EndpointNumber.new(1_u16), feature_map: Topology::Feature::NodeTopology)
    node.cluster_revision.should eq(1_u16)
    node.get_attribute_metadata(Topology::ATTR_AVAILABLE_ENDPOINTS).should be_nil
    expect_raises(ArgumentError) do
      Topology.new(EndpointNumber.new(1_u16), feature_map: Topology::Feature::DynamicPowerFlow)
    end
    tree = Topology.new(EndpointNumber.new(1_u16),
      feature_map: Topology::Feature::SetTopology | Topology::Feature::DynamicPowerFlow,
      available_endpoints: [2_u16, 3_u16], active_endpoints: [2_u16])
    tree.available_endpoints.should eq([2_u16, 3_u16])
    tree.get_attribute_metadata(Topology::ATTR_ACTIVE_ENDPOINTS).should_not be_nil
    expect_raises(ArgumentError) { tree.update_active_endpoints([4_u16]) }
    tree.update_active_endpoints([3_u16])
    tree.active_endpoints.should eq([3_u16])
    expect_raises(ArgumentError) do
      Topology.new(EndpointNumber.new(1_u16),
        feature_map: Topology::Feature::NodeTopology | Topology::Feature::SetTopology)
    end
    expect_raises(ArgumentError) do
      Topology.new(EndpointNumber.new(1_u16), feature_map: Topology::Feature::SetTopology,
        available_endpoints: [2_u16, 2_u16])
    end
  end
end
