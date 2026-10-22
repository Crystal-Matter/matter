require "../spec_helper"
require "../../src/matter/cluster/soil_measurement"

private alias Soil = Matter::Cluster::SoilMeasurement
private alias Accuracy = Matter::Cluster::ElectricalMeasurement

private def soil_accuracy(minimum : Int64 = 0_i64, maximum : Int64 = 100_i64,
                          percent_max : UInt16 = 500_u16) : Accuracy::Accuracy
  range = Accuracy::AccuracyRange.new(minimum, maximum, percent_max: percent_max)
  Accuracy::Accuracy.new(Accuracy::MeasurementType::SoilMoisture, true,
    minimum, maximum, [range])
end

describe Soil do
  it "publishes Matter 1.6 revision 1 and a fixed typed accuracy structure" do
    cluster = build(Soil, accuracy: soil_accuracy, measured_value: 42_u8)

    cluster.cluster_id.id.should eq(0x0430_u32)
    cluster.cluster_revision.should eq(1_u16)
    cluster.get_attribute_metadata(Soil::ATTR_SOIL_MOISTURE_MEASUREMENT_LIMITS)
      .as(Matter::Cluster::AttributeMetadata).fixed?.should be_true
    cluster.get_attribute_metadata(Soil::ATTR_SOIL_MOISTURE_MEASURED_VALUE)
      .as(Matter::Cluster::AttributeMetadata).writable?.should be_false
    attribute_ids(cluster).should contain(Soil::ATTR_SOIL_MOISTURE_MEASUREMENT_LIMITS)
    attribute_ids(cluster).should contain(Soil::ATTR_SOIL_MOISTURE_MEASURED_VALUE)

    limits = Accuracy::Accuracy.from_tlv(read_tlv(cluster, Soil::ATTR_SOIL_MOISTURE_MEASUREMENT_LIMITS))
    limits.measurement_type.should eq(Accuracy::MeasurementType::SoilMoisture)
    limits.min_measured_value.should eq(0_i64)
    limits.max_measured_value.should eq(100_i64)
    limits.accuracy_ranges.first.percent_max.should eq(500_u16)
    read(cluster, Soil::ATTR_SOIL_MOISTURE_MEASURED_VALUE).should eq(42_u8)
  end

  it "rejects invalid soil accuracy limits and extra accuracy ranges" do
    build(Soil, accuracy: soil_accuracy(0_i64, 100_i64, 1000_u16))
    expect_raises(ArgumentError) { build(Soil, accuracy: soil_accuracy(-1_i64, 100_i64)) }
    expect_raises(ArgumentError) { build(Soil, accuracy: soil_accuracy(0_i64, 101_i64)) }
    expect_raises(ArgumentError) { build(Soil, accuracy: soil_accuracy(10_i64, 10_i64)) }
    expect_raises(ArgumentError) { build(Soil, accuracy: soil_accuracy(0_i64, 100_i64, 1001_u16)) }

    wrong_type = Accuracy::Accuracy.new(Accuracy::MeasurementType::Voltage, true,
      0_i64, 100_i64, [Accuracy::AccuracyRange.new(0_i64, 100_i64, percent_max: 500_u16)])
    expect_raises(ArgumentError) { build(Soil, accuracy: wrong_type) }

    ranges = [Accuracy::AccuracyRange.new(0_i64, 50_i64, percent_max: 500_u16),
              Accuracy::AccuracyRange.new(51_i64, 100_i64, percent_max: 500_u16)]
    extra_ranges = Accuracy::Accuracy.new(Accuracy::MeasurementType::SoilMoisture, true,
      0_i64, 100_i64, ranges)
    expect_raises(ArgumentError) { build(Soil, accuracy: extra_ranges) }

    wrong_span = Accuracy::Accuracy.new(Accuracy::MeasurementType::SoilMoisture, true,
      0_i64, 100_i64, [Accuracy::AccuracyRange.new(10_i64, 90_i64, percent_max: 500_u16)])
    expect_raises(ArgumentError) { build(Soil, accuracy: wrong_span) }
  end

  it "keeps fixed accuracy limits independent of caller-owned arrays" do
    configured = soil_accuracy
    cluster = build(Soil, accuracy: configured)
    configured.accuracy_ranges << Accuracy::AccuracyRange.new(0_i64, 100_i64, percent_max: 100_u16)
    observed = cluster.soil_moisture_measurement_limits
    observed.accuracy_ranges << Accuracy::AccuracyRange.new(0_i64, 100_i64, percent_max: 100_u16)

    read_limits = Accuracy::Accuracy.from_tlv(read_tlv(cluster, Soil::ATTR_SOIL_MOISTURE_MEASUREMENT_LIMITS))
    read_limits.accuracy_ranges.size.should eq(1)
    read_limits.accuracy_ranges.first.percent_max.should eq(500_u16)
  end

  it "accepts null readings, reports changes, and rejects out-of-range readings" do
    cluster = build(Soil, accuracy: soil_accuracy(10_i64, 90_i64))
    changes = [] of Tuple(UInt8?, UInt8?)
    cluster.on_soil_moisture_measured_value_changed do |old_value, new_value|
      changes << {old_value, new_value}
    end
    read(cluster, Soil::ATTR_SOIL_MOISTURE_MEASURED_VALUE).should be_nil
    original_version = cluster.data_version

    cluster.update_soil_moisture(10_u8)
    cluster.data_version.should_not eq(original_version)
    cluster.update_soil_moisture(90_u8)
    cluster.update_soil_moisture(nil)
    changes.should eq([{nil, 10_u8}, {10_u8, 90_u8}, {90_u8, nil}])

    expect_raises(ArgumentError) { cluster.update_soil_moisture(9_u8) }
    expect_raises(ArgumentError) { cluster.soil_moisture_measured_value = 91_u8 }
    cluster.soil_moisture_measured_value.should be_nil
  end

  it "rejects interaction-model writes to both read-only attributes" do
    cluster = build(Soil, accuracy: soil_accuracy)
    write(cluster, Soil::ATTR_SOIL_MOISTURE_MEASURED_VALUE, 30_u8).status
      .should eq(Matter::InteractionModel::StatusCode::UnsupportedWrite)
    write(cluster, Soil::ATTR_SOIL_MOISTURE_MEASUREMENT_LIMITS, soil_accuracy).status
      .should eq(Matter::InteractionModel::StatusCode::UnsupportedWrite)
  end
end
