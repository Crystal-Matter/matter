require "../spec_helper"

describe "Matter 1.6 foundation cluster coverage" do
  it "exposes writable locale choice constrained to supported locales and persists it" do
    cluster = build(Matter::Cluster::LocalizationConfiguration,
      active_locale: "en-US", supported_locales: ["en-US", "fr-FR"])
    cluster.cluster_id.id.should eq(0x002B_u32)
    write(cluster, Matter::Cluster::LocalizationConfiguration::ATTR_ACTIVE_LOCALE,
      "de-DE").status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    write(cluster, Matter::Cluster::LocalizationConfiguration::ATTR_ACTIVE_LOCALE,
      "fr-FR").status.should eq(Matter::InteractionModel::StatusCode::Success)
    restored = build(Matter::Cluster::LocalizationConfiguration,
      active_locale: "en-US", supported_locales: ["en-US", "fr-FR"])
    restored.restore_state(cluster.save_state.as(Matter::Storage::Document))
    restored.active_locale.should eq("fr-FR")
  end

  it "gates temperature unit attributes by feature and accepts only advertised units" do
    unsupported = build(Matter::Cluster::UnitLocalization,
      feature_map: Matter::Cluster::UnitLocalization::Feature::None)
    read_status(unsupported, Matter::Cluster::UnitLocalization::ATTR_TEMPERATURE_UNIT).status
      .should eq(Matter::InteractionModel::StatusCode::UnsupportedAttribute)

    supported = [Matter::Cluster::UnitLocalization::TempUnit::Fahrenheit,
                 Matter::Cluster::UnitLocalization::TempUnit::Celsius]
    cluster = build(Matter::Cluster::UnitLocalization,
      feature_map: Matter::Cluster::UnitLocalization::Feature::TemperatureUnit,
      temperature_unit: Matter::Cluster::UnitLocalization::TempUnit::Fahrenheit,
      supported_temperature_units: supported)
    cluster.cluster_id.id.should eq(0x002D_u32)
    write(cluster, Matter::Cluster::UnitLocalization::ATTR_TEMPERATURE_UNIT,
      Matter::Cluster::UnitLocalization::TempUnit::Kelvin.value).status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    write(cluster, Matter::Cluster::UnitLocalization::ATTR_TEMPERATURE_UNIT,
      Matter::Cluster::UnitLocalization::TempUnit::Celsius.value).status.should eq(Matter::InteractionModel::StatusCode::Success)
  end

  it "reports power source endpoints with a bounded source list" do
    sources = [1_u16, 2_u16]
    cluster = build(Matter::Cluster::PowerSourceConfiguration, sources: sources)
    cluster.cluster_id.id.should eq(0x002E_u32)
    cluster.sources.should eq([1_u16, 2_u16])
    sources << 3_u16
    cluster.sources.should eq([1_u16, 2_u16])
    expect_raises(ArgumentError, /at most 6/) do
      build(Matter::Cluster::PowerSourceConfiguration,
        sources: [1_u16, 2_u16, 3_u16, 4_u16, 5_u16, 6_u16, 7_u16])
    end
  end

  it "keeps a nullable flow reading inside fixed measurement bounds" do
    cluster = build(Matter::Cluster::FlowMeasurement,
      min_measured_value: 10_u16, max_measured_value: 100_u16)
    cluster.cluster_id.id.should eq(0x0404_u32)
    read(cluster, Matter::Cluster::FlowMeasurement::ATTR_MEASURED_VALUE).should be_nil
    cluster.update_flow(50_u16)
    read(cluster, Matter::Cluster::FlowMeasurement::ATTR_MEASURED_VALUE).should eq(50_u16)
    expect_raises(ArgumentError, /outside measurable range/) { cluster.update_flow(101_u16) }
  end

  it "advertises only air quality levels supported by its feature map" do
    cluster = build(Matter::Cluster::AirQuality)
    cluster.cluster_id.id.should eq(0x005B_u32)
    cluster.update_quality(Matter::Cluster::AirQuality::Level::Poor)
    expect_raises(ArgumentError, /Fair/) do
      cluster.update_quality(Matter::Cluster::AirQuality::Level::Fair)
    end
    fair = build(Matter::Cluster::AirQuality,
      feature_map: Matter::Cluster::AirQuality::Feature::Fair)
    fair.update_quality(Matter::Cluster::AirQuality::Level::Fair)
    fair.air_quality.should eq(Matter::Cluster::AirQuality::Level::Fair)
  end
end
