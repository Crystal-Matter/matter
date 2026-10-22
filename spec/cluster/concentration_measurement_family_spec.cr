require "../spec_helper"
require "../../src/matter/cluster"

describe "Matter 1.6 concentration measurement family" do
  it "advertises CO2 revision 5 and the gated medium and critical level features" do
    sensor = build(Matter::Cluster::CarbonDioxideConcentrationMeasurement,
      level_value: Matter::Cluster::CarbonDioxideConcentrationMeasurement::LevelValue::Critical)

    Matter::Cluster::CarbonDioxideConcentrationMeasurement::CLUSTER_REVISION.should eq(5_u16)
    sensor.feature_map.to_u32.should eq(0b1110_u32)
  end

  it "rejects numeric readings outside fixed measurement bounds" do
    sensor = build(Matter::Cluster::CarbonDioxideConcentrationMeasurement,
      measured_value: 400.0_f32, min_measured_value: 0.0_f32,
      max_measured_value: 5000.0_f32,
      measurement_unit: Matter::Cluster::CarbonDioxideConcentrationMeasurement::MeasurementUnit::Ppm)

    expect_raises(ArgumentError) { sensor.update_measured_value(5001.0_f32) }
    sensor.measured_value.should eq(400.0_f32)
  end

  {% for pair in [
                   {Matter::Cluster::CarbonMonoxideConcentrationMeasurement, 0x040C_u32},
                   {Matter::Cluster::CarbonDioxideConcentrationMeasurement, 0x040D_u32},
                   {Matter::Cluster::NitrogenDioxideConcentrationMeasurement, 0x0413_u32},
                   {Matter::Cluster::OzoneConcentrationMeasurement, 0x0415_u32},
                   {Matter::Cluster::Pm25ConcentrationMeasurement, 0x042A_u32},
                   {Matter::Cluster::FormaldehydeConcentrationMeasurement, 0x042B_u32},
                   {Matter::Cluster::Pm1ConcentrationMeasurement, 0x042C_u32},
                   {Matter::Cluster::Pm10ConcentrationMeasurement, 0x042D_u32},
                   {Matter::Cluster::TotalVolatileOrganicCompoundsConcentrationMeasurement, 0x042E_u32},
                   {Matter::Cluster::RadonConcentrationMeasurement, 0x042F_u32},
                 ] %}
    it "exposes {{ pair[0] }} at its canonical wire ID" do
      sensor = build({{ pair[0] }}, level_value: {{ pair[0] }}::LevelValue::Low)

      {{ pair[0] }}::CLUSTER_ID.should eq({{ pair[1] }})
      Matter::Cluster::Registry.for({{ pair[1] }}).should eq({{ pair[0] }})
      sensor.cluster_revision.should eq(5_u16)
      read(sensor, {{ pair[0] }}::ATTR_MEASUREMENT_MEDIUM).should eq(0_u8)
      sensor.attributes.map(&.id.id).should contain(0x000A_u32)
      sensor.attributes.map(&.id.id).should_not contain(0x0000_u32)
    end
  {% end %}

  it "permits nullable numeric readings and bounded peak windows" do
    sensor = build(Matter::Cluster::CarbonDioxideConcentrationMeasurement,
      measurement_unit: Matter::Cluster::CarbonDioxideConcentrationMeasurement::MeasurementUnit::Ppm,
      min_measured_value: 0.0_f32, max_measured_value: 5000.0_f32,
      peak_measured_value_window: 604_800_u32)

    sensor.numeric_measurement_enabled?.should be_true
    sensor.peak_measurement_enabled?.should be_true
    read(sensor, Matter::Cluster::CarbonDioxideConcentrationMeasurement::ATTR_MEASURED_VALUE).should be_nil
    read(sensor, Matter::Cluster::CarbonDioxideConcentrationMeasurement::ATTR_PEAK_MEASURED_VALUE).should be_nil
    sensor.update_measured_value(400.0_f32)
    sensor.update_measured_value(nil)
    sensor.measured_value.should be_nil
  end

  it "rejects invalid bounds and peak values without changing state" do
    expect_raises(ArgumentError, /min_measured_value/) do
      build(Matter::Cluster::CarbonDioxideConcentrationMeasurement,
        measurement_unit: Matter::Cluster::CarbonDioxideConcentrationMeasurement::MeasurementUnit::Ppm,
        min_measured_value: 5.0_f32, max_measured_value: 4.0_f32)
    end
    sensor = build(Matter::Cluster::CarbonDioxideConcentrationMeasurement,
      measurement_unit: Matter::Cluster::CarbonDioxideConcentrationMeasurement::MeasurementUnit::Ppm,
      min_measured_value: 0.0_f32, max_measured_value: 5.0_f32,
      peak_measured_value_window: 10_u32)
    expect_raises(ArgumentError) { sensor.update_peak_measured_value(6.0_f32) }
    sensor.peak_measured_value.should be_nil
  end

  it "declares the fixed and conditional attributes from Matter 1.6" do
    klass = Matter::Cluster::CarbonDioxideConcentrationMeasurement
    sensor = build(klass,
      measurement_unit: Matter::Cluster::CarbonDioxideConcentrationMeasurement::MeasurementUnit::Ppm,
      min_measured_value: 0.0_f32, max_measured_value: 5000.0_f32,
      uncertainty: 10.0_f32,
      level_value: Matter::Cluster::CarbonDioxideConcentrationMeasurement::LevelValue::Low,
      peak_measured_value_window: 20_u32,
      average_measured_value_window: 30_u32)

    sensor.feature_map.to_u32.should eq(0b11_1111_u32)
    [0x0001_u32, 0x0002_u32, 0x0007_u32, 0x0008_u32, 0x0009_u32].each do |id|
      sensor.attributes.find! { |attr| attr.id.id == id }.fixed?.should be_true
    end
    sensor.attributes.map(&.id.id).should contain(0x0003_u32)
    sensor.attributes.map(&.id.id).should contain(0x0005_u32)
    read(sensor, Matter::Cluster::CarbonDioxideConcentrationMeasurement::ATTR_LEVEL_VALUE).should eq(1_u8)
  end

  it "keeps nullable readings and rejects nonfinite input" do
    klass = Matter::Cluster::CarbonDioxideConcentrationMeasurement
    sensor = build(klass, measurement_unit: Matter::Cluster::CarbonDioxideConcentrationMeasurement::MeasurementUnit::Ppm,
      min_measured_value: 0.0_f32, max_measured_value: 5.0_f32)
    expect_raises(ArgumentError) { sensor.update_measured_value(Float32::NAN) }
    expect_raises(ArgumentError) { sensor.update_measured_value(Float32::INFINITY) }
    sensor.measured_value.should be_nil
    expect_raises(ArgumentError) do
      build(klass, measurement_unit: Matter::Cluster::CarbonDioxideConcentrationMeasurement::MeasurementUnit::Ppm,
        min_measured_value: Float32::NAN)
    end
  end
end
