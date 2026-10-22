require "../spec_helper"

private alias Occupancy = Matter::Cluster::OccupancySensing

private struct OccupancyEventWire
  include TLV::Serializable

  @[TLV::Field(tag: 0)]
  getter occupancy : UInt8

  def initialize(@occupancy : UInt8)
  end
end

describe "Matter 1.6 Occupancy Sensing revision 7" do
  it "advertises revision 7 and requires a sensing modality" do
    sensor = build(Occupancy)
    sensor.cluster_revision.should eq(7_u16)
    expect_raises(ArgumentError, /sensing modality/) do
      build(Occupancy, feature_map: Occupancy::Feature::None)
    end
  end

  it "derives legacy sensor type fields from the selected modalities" do
    ultrasound = build(Occupancy, feature_map: Occupancy::Feature::Ultrasonic)
    ultrasound.occupancy_sensor_type.should eq(Occupancy::OccupancySensorType::Ultrasonic)
    ultrasound.occupancy_sensor_type_bitmap.should eq(0x02_u8)

    contact = build(Occupancy, feature_map: Occupancy::Feature::PhysicalContact)
    contact.occupancy_sensor_type.should eq(Occupancy::OccupancySensorType::PhysicalContact)
    contact.occupancy_sensor_type_bitmap.should eq(0x04_u8)

    both = build(Occupancy,
      feature_map: Occupancy::Feature::PassiveInfrared | Occupancy::Feature::Ultrasonic)
    both.occupancy_sensor_type.should eq(Occupancy::OccupancySensorType::PIRAndUltrasonic)
    both.occupancy_sensor_type_bitmap.should eq(0x03_u8)
  end

  it "keeps fixed sensor type fields and HoldTimeLimits immutable after construction" do
    sensor = build(Occupancy, hold_time: 60_u16)
    limits = sensor.hold_time_limits
    version = sensor.data_version

    expect_raises(ArgumentError, /fixed/) do
      sensor.occupancy_sensor_type = Occupancy::OccupancySensorType::Ultrasonic
    end
    expect_raises(ArgumentError, /fixed/) { sensor.occupancy_sensor_type_bitmap = 0x02_u8 }
    expect_raises(ArgumentError, /fixed/) do
      sensor.hold_time_limits = Occupancy::HoldTimeLimits.new(10_u16, 120_u16, 60_u16)
    end

    sensor.occupancy_sensor_type.should eq(Occupancy::OccupancySensorType::PIR)
    sensor.occupancy_sensor_type_bitmap.should eq(0x01_u8)
    sensor.hold_time_limits.should eq(limits)
    sensor.data_version.should eq(version)
  end

  it "omits HoldTime and modality timing attributes when HoldTime is absent" do
    sensor = build(Occupancy)
    [0x0003_u32, 0x0004_u32, 0x0010_u32, 0x0011_u32, 0x0012_u32].each do |id|
      read_status(sensor, id).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAttribute)
    end
  end

  it "exposes fixed HoldTimeLimits and rejects out-of-range HoldTime writes" do
    sensor = build(Occupancy, hold_time: 60_u16)
    read_tlv(sensor, 0x0003_u32).as_u64.should eq(60_u64)
    limits = read_tlv(sensor, 0x0004_u32)
    limits.as_structure.size.should eq(3)
    limits.as_structure[0_u8].as_u64.should eq(1_u64)
    limits.as_structure[1_u8].as_u64.should eq(600_u64)
    limits.as_structure[2_u8].as_u64.should eq(60_u64)
    write(sensor, 0x0003_u32, 0_u16).status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    write(sensor, 0x0003_u32, 601_u16).status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    write(sensor, 0x0003_u32, 120_u16).status.should eq(Matter::InteractionModel::StatusCode::Success)
    sensor.hold_time.should eq(120_u16)
    expect_raises(ArgumentError, /hold_time/) { build(Occupancy, hold_time: 0_u16) }
    write(sensor, 0x0003_u32, nil).status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
  end

  it "validates fixed HoldTimeLimits and supports a custom range" do
    expect_raises(ArgumentError, /hold_time_min/) { Occupancy::HoldTimeLimits.new(0_u16, 10_u16, 1_u16) }
    expect_raises(ArgumentError, /hold_time_max/) { Occupancy::HoldTimeLimits.new(2_u16, 9_u16, 2_u16) }
    expect_raises(ArgumentError, /hold_time_default/) { Occupancy::HoldTimeLimits.new(2_u16, 20_u16, 1_u16) }

    limits = Occupancy::HoldTimeLimits.new(10_u16, 20_u16, 15_u16)
    sensor = build(Occupancy, hold_time: 15_u16, hold_time_limits: limits)
    write(sensor, 0x0003_u32, 9_u16).status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    write(sensor, 0x0003_u32, 20_u16).status.should eq(Matter::InteractionModel::StatusCode::Success)
  end

  it "keeps HoldTime and legacy occupied-to-unoccupied delays equivalent" do
    features = Occupancy::Feature::PassiveInfrared |
               Occupancy::Feature::Ultrasonic |
               Occupancy::Feature::PhysicalContact
    sensor = build(Occupancy, hold_time: 60_u16, feature_map: features)
    [0x0010_u32, 0x0020_u32, 0x0030_u32].each do |id|
      read(sensor, id).should eq(60_u16)
    end

    write(sensor, 0x0010_u32, 30_u16).status.should eq(Matter::InteractionModel::StatusCode::Success)
    [0x0003_u32, 0x0010_u32, 0x0020_u32, 0x0030_u32].each do |id|
      read(sensor, id).should eq(30_u16)
    end

    sensor.hold_time = 90_u16
    [0x0010_u32, 0x0020_u32, 0x0030_u32].each do |id|
      read(sensor, id).should eq(90_u16)
    end
    write(sensor, 0x0020_u32, 0_u16).status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    write(sensor, 0x0030_u32, 601_u16).status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)

    version = sensor.data_version
    expect_raises(ArgumentError, /hold time limits/) { sensor.pir_occupied_to_unoccupied_delay = 0_u16 }
    expect_raises(ArgumentError, /hold_time/) { sensor.hold_time = 601_u16 }
    sensor.data_version.should eq(version)
    sensor.hold_time.should eq(90_u16)
  end

  it "rejects conflicting initial legacy delays when HoldTime is selected" do
    expect_raises(ArgumentError, /equivalent to hold_time/) do
      build(Occupancy, hold_time: 60_u16, pir_occupied_to_unoccupied_delay: 30_u16)
    end
  end

  it "exposes only HoldTime-compatible modality timing and bounds thresholds" do
    sensor = build(Occupancy, hold_time: 60_u16,
      feature_map: Occupancy::Feature::PassiveInfrared)
    [0x0010_u32, 0x0011_u32, 0x0012_u32].each do |id|
      sensor.get_attribute_metadata(id).should_not be_nil
    end
    [0x0020_u32, 0x0021_u32, 0x0022_u32].each do |id|
      sensor.get_attribute_metadata(id).should be_nil
    end
    write(sensor, 0x0012_u32, 0_u8).status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    write(sensor, 0x0012_u32, 255_u8).status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
  end

  it "gates ultrasonic, physical-contact and legacy PIR timing by modality" do
    ultrasound = build(Occupancy, hold_time: 60_u16, feature_map: Occupancy::Feature::Ultrasonic)
    ultrasound.get_attribute_metadata(0x0020_u32).should_not be_nil
    ultrasound.get_attribute_metadata(0x0010_u32).should be_nil

    contact = build(Occupancy, hold_time: 60_u16, feature_map: Occupancy::Feature::PhysicalContact)
    contact.get_attribute_metadata(0x0031_u32).should_not be_nil
    contact.get_attribute_metadata(0x0010_u32).should be_nil

    legacy = build(Occupancy, hold_time: 60_u16, feature_map: Occupancy::Feature::Radar)
    legacy.get_attribute_metadata(0x0010_u32).should_not be_nil
  end

  it "emits occupancy changes only when the OccupancyEvent feature is selected" do
    without_event = build(Occupancy)
    without_event.get_event_metadata(0x00_u32).should be_nil

    with_event = build(Occupancy,
      feature_map: Occupancy::Feature.from_value(0x202_u32))
    with_event.get_event_metadata(0x00_u32).should_not be_nil
    records = [] of TLV::Any
    with_event.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, event : UInt32, _priority : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) do
      event.should eq(0x00_u32)
      records << data
      nil
    end
    with_event.occupancy = 1_u8
    with_event.update_occupancy(true)
    with_event.update_occupancy(false)
    records.map { |item| OccupancyEventWire.from_tlv(item).occupancy }.should eq([1_u8, 0_u8])
  end

  it "keeps occupancy volatile while retaining configured timing values" do
    sensor = build(Occupancy, occupancy: 1_u8, hold_time: 60_u16)
    write(sensor, 0x0010_u32, 30_u16).status.should eq(Matter::InteractionModel::StatusCode::Success)
    document = sensor.save_state.as(Matter::Storage::Document)
    document.keys.should_not contain("occupancy")
    restored = build(Occupancy, hold_time: 60_u16)
    restored.restore_state(document)
    restored.occupancy.should eq(0_u8)
    restored.pir_occupied_to_unoccupied_delay.should eq(30_u16)
  end
end
