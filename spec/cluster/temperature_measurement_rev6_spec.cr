require "../spec_helper"

private alias Temperature = Matter::Cluster::TemperatureMeasurement
private alias IMCode = Matter::InteractionModel::StatusCode

describe "Matter 1.6 Temperature Measurement revision 6" do
  it "advertises revision 6 and fixed quality for capability attributes" do
    cluster = build(Temperature, tolerance: 0_u16)
    cluster.cluster_revision.should eq(6_u16)
    [Temperature::ATTR_MIN_MEASURED_VALUE, Temperature::ATTR_MAX_MEASURED_VALUE,
     Temperature::ATTR_TOLERANCE].each do |id|
      cluster.attributes.find!(&.id.id.==(id)).fixed?.should be_true
    end
    cluster.attributes.find!(&.id.id.==(Temperature::ATTR_MEASURED_VALUE)).fixed?.should be_false
  end

  it "reports nullable capability bounds while keeping all mandatory attributes visible" do
    cluster = build(Temperature, measured_value: 2250_i16,
      min_measured_value: nil, max_measured_value: nil)
    cluster.attributes.map(&.id.id).should eq([
      Temperature::ATTR_MEASURED_VALUE, Temperature::ATTR_MIN_MEASURED_VALUE,
      Temperature::ATTR_MAX_MEASURED_VALUE,
    ])
    read(cluster, Temperature::ATTR_MIN_MEASURED_VALUE).should be_nil
    read(cluster, Temperature::ATTR_MAX_MEASURED_VALUE).should be_nil
    cluster.update_temperature(32767_i16)
    cluster.update_temperature(-27315_i16)
    expect_raises(ArgumentError) { cluster.update_temperature(-27316_i16) }
  end

  it "enforces each known bound and rejects invalid fixed capability ranges" do
    lower_unknown = build(Temperature, min_measured_value: nil, max_measured_value: 3000_i16)
    lower_unknown.update_temperature(-27315_i16)
    expect_raises(ArgumentError) { lower_unknown.update_temperature(3001_i16) }
    upper_unknown = build(Temperature, min_measured_value: 1500_i16, max_measured_value: nil)
    upper_unknown.update_temperature(32767_i16)
    expect_raises(ArgumentError) { upper_unknown.update_temperature(1499_i16) }
    expect_raises(ArgumentError) { build(Temperature, min_measured_value: 32767_i16) }
    expect_raises(ArgumentError) do
      build(Temperature, min_measured_value: 1500_i16, max_measured_value: 1500_i16)
    end
    build(Temperature, min_measured_value: nil,
      max_measured_value: -27315_i16).max_measured_value.should eq(-27315_i16)
  end

  it "rejects an invalid direct host MeasuredValue assignment without changing state" do
    cluster = build(Temperature, measured_value: 2000_i16,
      min_measured_value: 1500_i16, max_measured_value: 3000_i16)
    version = cluster.data_version
    expect_raises(ArgumentError) { cluster.measured_value = 3001_i16 }
    cluster.measured_value.should eq(2000_i16)
    cluster.data_version.should eq(version)
  end

  it "rejects host changes to fixed capabilities without changing DataVersion" do
    cluster = build(Temperature, min_measured_value: 1000_i16,
      max_measured_value: 3000_i16, tolerance: 25_u16)
    version = cluster.data_version

    expect_raises(ArgumentError, /fixed temperature/) { cluster.min_measured_value = 1100_i16 }
    expect_raises(ArgumentError, /fixed temperature/) { cluster.max_measured_value = 2900_i16 }
    expect_raises(ArgumentError, /fixed temperature/) { cluster.tolerance = 26_u16 }

    cluster.min_measured_value.should eq(1000_i16)
    cluster.max_measured_value.should eq(3000_i16)
    cluster.tolerance.should eq(25_u16)
    cluster.data_version.should eq(version)
  end

  it "distinguishes absent optional Tolerance from a supported nonnullable zero" do
    absent = build(Temperature)
    read_status(absent, Temperature::ATTR_TOLERANCE).status.should eq(IMCode::UnsupportedAttribute)
    absent.tolerance.should eq(0_u16)
    present = build(Temperature, tolerance: 0_u16)
    present.attributes.find!(&.id.id.==(Temperature::ATTR_TOLERANCE)).fixed?.should be_true
    read(present, Temperature::ATTR_TOLERANCE).should eq(0_u16)
    expect_raises(ArgumentError) { build(Temperature, tolerance: 2049_u16) }
  end

  it "starts with configured fixed bounds and volatile MeasuredValue after restore" do
    source = build(Temperature, measured_value: 2000_i16,
      min_measured_value: 1000_i16, max_measured_value: 3000_i16, tolerance: 25_u16)
    saved = source.save_state
    restored = build(Temperature, min_measured_value: nil,
      max_measured_value: nil, tolerance: 0_u16)
    if document = saved
      restored.restore_state(document)
    end
    restored.measured_value.should be_nil
    restored.min_measured_value.should be_nil
    restored.max_measured_value.should be_nil
    restored.tolerance.should eq(0_u16)
  end
end
