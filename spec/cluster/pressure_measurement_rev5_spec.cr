require "../spec_helper"
require "../../src/matter/cluster/pressure_measurement"

describe "Pressure Measurement revision 5" do
  it "advertises revision 5 and fixed sensor capabilities" do
    cluster = build(Matter::Cluster::PressureMeasurement, tolerance: 0_u16)
    Matter::Cluster::PressureMeasurement::CLUSTER_REVISION.should eq(5_u16)
    [0x0001_u32, 0x0002_u32, 0x0003_u32].each do |id|
      cluster.attributes.find! { |attr| attr.id.id == id }.fixed?.should be_true
    end
    cluster.attributes.find! { |attr| attr.id.id == 0x0000_u32 }.fixed?.should be_false
    read(cluster, 0x0003_u32).should eq(0)
  end

  it "keeps unknown bounds nullable and requires strictly increasing known bounds" do
    cluster = build(Matter::Cluster::PressureMeasurement, max_measured_value: Int16::MIN)
    read(cluster, 0x0001_u32).should be_nil
    read(cluster, 0x0002_u32).should eq(Int16::MIN)
    expect_raises(ArgumentError, /min_measured_value must be < max_measured_value/) do
      build(Matter::Cluster::PressureMeasurement, min_measured_value: 100_i16, max_measured_value: 100_i16)
    end
  end

  it "validates direct host assignments before changing the reading or data version" do
    cluster = build(Matter::Cluster::PressureMeasurement,
      measured_value: 100_i16, min_measured_value: 50_i16, max_measured_value: 150_i16)
    version = cluster.data_version
    expect_raises(ArgumentError, /above maximum/) { cluster.measured_value = 151_i16 }
    cluster.measured_value.should eq(100_i16)
    cluster.data_version.should eq(version)
  end

  it "exposes the complete Extended group only when enabled" do
    base = build(Matter::Cluster::PressureMeasurement)
    (0x0010_u32..0x0014_u32).each do |id|
      read_status(base, id).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAttribute)
    end

    extended = build(Matter::Cluster::PressureMeasurement,
      feature_map: Matter::Cluster::PressureMeasurement::Feature::Extended,
      scaled_value: 1000_i16, min_scaled_value: 900_i16, max_scaled_value: 1100_i16,
      scaled_tolerance: 0_u16, scale: 1_i8)
    extended.feature_map.extended?.should be_true
    read(extended, 0x0010_u32).should eq(1000)
    read(extended, 0x0011_u32).should eq(900)
    read(extended, 0x0012_u32).should eq(1100)
    read(extended, 0x0013_u32).should eq(0)
    read(extended, 0x0014_u32).should eq(1)
    [0x0011_u32, 0x0012_u32, 0x0013_u32, 0x0014_u32].each do |id|
      extended.attributes.find! { |attr| attr.id.id == id }.fixed?.should be_true
    end
    extended.attributes.find! { |attr| attr.id.id == 0x0010_u32 }.fixed?.should be_false
  end

  it "supports nullable scaled bounds and an optional nonnullable scaled tolerance" do
    extended = build(Matter::Cluster::PressureMeasurement,
      feature_map: Matter::Cluster::PressureMeasurement::Feature::Extended,
      max_scaled_value: Int16::MIN)
    read(extended, 0x0010_u32).should be_nil
    read(extended, 0x0011_u32).should be_nil
    read(extended, 0x0012_u32).should eq(Int16::MIN)
    read_status(extended, 0x0013_u32).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAttribute)
    expect_raises(ArgumentError, /min_scaled_value must be < max_scaled_value/) do
      build(Matter::Cluster::PressureMeasurement,
        feature_map: Matter::Cluster::PressureMeasurement::Feature::Extended,
        min_scaled_value: 100_i16, max_scaled_value: 100_i16)
    end
    expect_raises(ArgumentError, /scale must be >= -127/) do
      build(Matter::Cluster::PressureMeasurement,
        feature_map: Matter::Cluster::PressureMeasurement::Feature::Extended, scale: Int8::MIN)
    end
    expect_raises(ArgumentError, /scaled_tolerance must be <= 2048/) do
      build(Matter::Cluster::PressureMeasurement,
        feature_map: Matter::Cluster::PressureMeasurement::Feature::Extended, scaled_tolerance: 2049_u16)
    end
  end

  it "validates scaled host updates and keeps readings volatile" do
    cluster = build(Matter::Cluster::PressureMeasurement,
      feature_map: Matter::Cluster::PressureMeasurement::Feature::Extended,
      measured_value: 100_i16, scaled_value: 1000_i16,
      min_scaled_value: 900_i16, max_scaled_value: 1100_i16)
    version = cluster.data_version
    expect_raises(ArgumentError, /outside measurable range/) { cluster.scaled_value = 1200_i16 }
    cluster.scaled_value.should eq(1000_i16)
    cluster.data_version.should eq(version)
    cluster.update_scaled_pressure(nil)
    cluster.scaled_value.should be_nil
    cluster.save_state.should be_nil
  end
end
