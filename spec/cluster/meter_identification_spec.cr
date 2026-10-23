require "../spec_helper"

private alias MeterIdentification = Matter::Cluster::MeterIdentification
private alias MeterStatus = Matter::InteractionModel::StatusCode

describe MeterIdentification do
  it "declares revision-one required nullable meter attributes" do
    meter = build(MeterIdentification)
    meter.cluster_id.id.should eq(0x0B06_u32)
    meter.cluster_revision.should eq(1_u16)
    meter.feature_map.should eq(MeterIdentification::Feature::None)
    meter.attributes.map(&.id.id).should eq([
      MeterIdentification::ATTR_METER_TYPE,
      MeterIdentification::ATTR_POINT_OF_DELIVERY,
      MeterIdentification::ATTR_METER_SERIAL_NUMBER,
    ])
    read(meter, MeterIdentification::ATTR_METER_TYPE).should be_nil
    read(meter, MeterIdentification::ATTR_POINT_OF_DELIVERY).should be_nil
    read(meter, MeterIdentification::ATTR_METER_SERIAL_NUMBER).should be_nil
    read_status(meter, MeterIdentification::ATTR_PROTOCOL_VERSION).status.should eq(MeterStatus::UnsupportedAttribute)
    read_status(meter, MeterIdentification::ATTR_POWER_THRESHOLD).status.should eq(MeterStatus::UnsupportedAttribute)
  end

  it "advertises configured optional metadata and PowerThreshold only with its feature" do
    threshold = MeterIdentification::PowerThreshold.new(
      power_threshold: 12_000_i64,
      apparent_power_threshold: 15_000_i64,
      power_threshold_source: MeterIdentification::PowerThresholdSource::Contract)
    meter = build(MeterIdentification,
      feature_map: MeterIdentification::Feature::PowerThreshold,
      meter_type: MeterIdentification::MeterType::Utility,
      point_of_delivery: "AU-NSW-001",
      meter_serial_number: "MTR-2026-001",
      protocol_version: "DLMS/COSEM 1.0",
      power_threshold: threshold)
    meter.attributes.map(&.id.id).should eq((0x0000_u32..0x0004_u32).to_a)
    read(meter, MeterIdentification::ATTR_METER_TYPE).should eq(MeterIdentification::MeterType::Utility.value)
    read(meter, MeterIdentification::ATTR_POINT_OF_DELIVERY).should eq("AU-NSW-001")
    MeterIdentification::PowerThreshold.from_tlv(
      read_tlv(meter, MeterIdentification::ATTR_POWER_THRESHOLD)).power_threshold.should eq(12_000_i64)
    write(meter, MeterIdentification::ATTR_POINT_OF_DELIVERY, "other").status.should eq(MeterStatus::UnsupportedWrite)
  end

  it "encodes PowerThreshold with optional values and a required nullable source" do
    threshold = MeterIdentification::PowerThreshold.new(
      power_threshold: 12_000_i64,
      power_threshold_source: nil)
    wire = threshold.to_tlv(nil)
    wire.as_structure.keys.should eq([0_u8, 2_u8])
    wire.as_structure[2_u8].value.should be_nil
    decoded = MeterIdentification::PowerThreshold.from_tlv(wire)
    decoded.power_threshold.should eq(12_000_i64)
    decoded.apparent_power_threshold.should be_nil
    decoded.power_threshold_source.should be_nil
  end

  it "rejects meter strings beyond 64 UTF-8 octets" do
    expect_raises(ArgumentError) { build(MeterIdentification, point_of_delivery: "x" * 65) }
    expect_raises(ArgumentError) { build(MeterIdentification, meter_serial_number: "x" * 65) }
    expect_raises(ArgumentError) { build(MeterIdentification, protocol_version: "x" * 65) }
    expect_raises(ArgumentError) { build(MeterIdentification, point_of_delivery: "é" * 33) }
  end

  it "requires the feature before accepting power threshold data" do
    expect_raises(ArgumentError) do
      build(MeterIdentification, power_threshold: MeterIdentification::PowerThreshold.new(
        power_threshold: 12_000_i64))
    end
    meter = build(MeterIdentification,
      feature_map: MeterIdentification::Feature::PowerThreshold)
    read(meter, MeterIdentification::ATTR_POWER_THRESHOLD).should be_nil
  end

  it "registers the Electrical Utility Meter device type with its required cluster" do
    device_type = Matter::DeviceType.for(Matter::DeviceType::ELECTRICAL_UTILITY_METER)
    device_type.name.should eq("Electrical Utility Meter")
    device_type.revision.should eq(1_u16)
    device_type.required_server_clusters.should contain(MeterIdentification::CLUSTER_ID)
  end
end
